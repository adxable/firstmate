#!/usr/bin/env bash
# tests/fm-treehouse-pool-termination-live-e2e.test.sh - opt-in drift guard for
# the worktree-pool facts fm-spawn.sh's ownership refusal rests on
# (discard_refused_endpoint, bin/fm-spawn.sh).
#
# Why this file exists: the refusal fires after `treehouse get` has already
# entered the pane's worktree, and it takes that pane back down with
# tmux kill-window. Whether that is safe depends entirely on what the pool tool
# does when its subshell is hung up rather than exited - a behavior the pool
# tool owns and can change in any release. If a future treehouse ran its
# return-and-reset path on SIGHUP, the refusal would detach the CONTESTED
# worktree off the holder's branch, which is the exact harm the guard exists to
# prevent. This guard establishes that by running both real binaries rather
# than assuming either answer.
#
# The normal-exit case is the contrast that keeps the file honest: it proves
# this lab really drives the pool tool's return path, so a green kill case
# cannot mean the guard simply failed to observe anything.
#
# Every worktree here lives inside a throwaway repo whose treehouse.toml sets
# root = "./", so the pool is created under the lab directory and no real pool
# is touched. tmux runs on a private socket for the same reason.
#
# Standard CI has no treehouse binary, so this is opt-in and on-demand. Run it
# after a treehouse upgrade and before trusting the dated record in
# docs/verification/runtime-backends.md "Endpoint kill and worktree-pool safety".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_TREEHOUSE_POOL_TERMINATION_DRIFT tmux treehouse jq

REAL_TMUX=
SOCKET="fm-pool-termination-$$"
LAB=
SESSION=pool

cleanup_all() {
  [ -z "$REAL_TMUX" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf "$LAB"
}
trap cleanup_all EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

REAL_TMUX=$(command -v tmux)
TMUX_VERSION=$("$REAL_TMUX" -V 2>/dev/null || printf 'unknown')
TREEHOUSE_VERSION=$(treehouse --version 2>/dev/null || printf 'unknown')
note "tmux version: $TMUX_VERSION"
note "treehouse version: $TREEHOUSE_VERSION"
note "uname: $(uname -sm)"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pool-termination.XXXXXX")
REPO="$LAB/repo"
mkdir -p "$REPO"
git init -q "$REPO" || fail "could not create the throwaway repo"
git -C "$REPO" config user.email fm-test@example.invalid
git -C "$REPO" config user.name "fm test"
printf 'seed\n' > "$REPO/seed.txt"

# One slot only, so every acquire below lands on the SAME worktree and each
# case observes the one the previous case left behind.
printf 'max_trees = 1\nroot = "./"\n' > "$REPO/treehouse.toml"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "seed" || fail "could not seed the throwaway repo"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n captain -c "$REPO" \
  || fail "could not start the private tmux server"

# acquire_in_pane <window>: run `treehouse get` in a fresh pane and print the
# worktree the pool handed out, read from the settled pane cwd - the same signal
# fm-spawn.sh's settle loop uses.
acquire_in_pane() {
  local window=$1 i=0 path=""
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$window" -c "$REPO" || return 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$window" 'treehouse get' Enter || return 1
  while [ "$i" -lt 60 ]; do
    path=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "=$SESSION:=$window" '#{pane_current_path}' 2>/dev/null)
    case "$path" in
      */.treehouse/*) printf '%s\n' "$path"; return 0 ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# stage_holder_state <worktree> <branch>: make the acquired worktree look like a
# live task's - on its own branch, with its own commit.
stage_holder_state() {
  local wt=$1 branch=$2
  git -C "$wt" checkout -q -b "$branch" || return 1
  printf 'unlanded\n' > "$wt/$branch-work.txt"
  git -C "$wt" add -A || return 1
  git -C "$wt" commit -qm "$branch work" || return 1
}

branch_of() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unreadable'; }

# --- the fact the refusal depends on: hang-up leaves the worktree alone -------
KILL_WT=$(acquire_in_pane fm-kill) || fail "treehouse $TREEHOUSE_VERSION did not hand out a worktree for the kill case"
note "kill case worktree: $KILL_WT"
stage_holder_state "$KILL_WT" holder-kill || fail "could not stage the holder state in $KILL_WT"
KILL_SHA=$(git -C "$KILL_WT" rev-parse HEAD)

"$REAL_TMUX" -L "$SOCKET" kill-window -t "=$SESSION:=fm-kill" || fail "could not kill the task window"
sleep 5

[ "$(branch_of "$KILL_WT")" = holder-kill ] \
  || fail "treehouse $TREEHOUSE_VERSION detached the worktree off holder-kill when its pane was killed; fm-spawn.sh's ownership refusal must stop taking its own endpoint down that way"
[ "$(git -C "$KILL_WT" rev-parse HEAD)" = "$KILL_SHA" ] \
  || fail "treehouse $TREEHOUSE_VERSION moved the worktree's HEAD when its pane was killed"
[ -f "$KILL_WT/holder-kill-work.txt" ] \
  || fail "treehouse $TREEHOUSE_VERSION discarded the worktree's content when its pane was killed"
pass "a killed pane leaves the acquired worktree on its branch, with its content, on $TREEHOUSE_VERSION"

# --- the boundary the refusal cannot move: the acquire itself resets ---------
# The pool decides occupancy from processes inside the slot, so the worktree the
# killed pane left on holder-kill reads free and is handed straight back out.
ACQ_WT=$(acquire_in_pane fm-acquire) || fail "treehouse $TREEHOUSE_VERSION did not hand out the single-slot worktree again"
[ "$ACQ_WT" = "$KILL_WT" ] || fail "the single-slot pool handed out $ACQ_WT rather than $KILL_WT, so the cases below no longer observe the same worktree"
if [ "$(branch_of "$ACQ_WT")" = holder-kill ]; then
  fail "treehouse $TREEHOUSE_VERSION no longer resets a worktree when it acquires one; the dated record's claim that the destructive step happens at acquire time no longer describes this pool"
fi
pass "the acquire itself resets the worktree it hands out, which is why the refusal cannot undo that step"

# --- the contrast that proves this lab drives the real return path -----------
stage_holder_state "$ACQ_WT" holder-exit || fail "could not stage the holder state in $ACQ_WT"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "=$SESSION:=fm-acquire" 'exit' Enter || fail "could not exit the task subshell"
sleep 5

if [ "$(branch_of "$ACQ_WT")" = holder-exit ]; then
  fail "treehouse $TREEHOUSE_VERSION no longer resets the worktree when its subshell exits normally; this lab can no longer tell a return apart from a no-op, so the kill case above proves nothing"
fi
pass "a normally exited subshell does return and reset the worktree, so the kill case is a real observation"

# --- the same boundary on the non-interactive acquire ------------------------
# The lease form is the one an ownership check would have to use to resolve a
# path before opening any pane, so the record's claim that it resets too is what
# rules that route out. It is also a live firstmate call path (bin/fm-home-seed.sh).
stage_holder_state "$ACQ_WT" holder-lease || fail "could not stage the holder state in $ACQ_WT"
LEASE_WT=$(cd "$REPO" && treehouse get --lease --lease-holder fm-pool-termination-probe 2>/dev/null) \
  || fail "treehouse $TREEHOUSE_VERSION could not lease the single-slot worktree"
[ "$LEASE_WT" = "$ACQ_WT" ] || fail "the single-slot pool leased $LEASE_WT rather than $ACQ_WT, so this case no longer observes the staged worktree"
if [ "$(branch_of "$LEASE_WT")" = holder-lease ]; then
  fail "treehouse $TREEHOUSE_VERSION no longer resets a worktree when it leases one; the dated record's claim that no pre-acquire ownership check can avoid the first detach no longer describes this pool"
fi
pass "the non-interactive lease acquire resets the worktree it hands out as well, so no pre-acquire check avoids that detach"

# --- what the acquire-time detach does NOT cost ------------------------------
# The record only calls that detach survivable because unlanded edits are never
# handed out in the first place. Dirtiness therefore has to be the ONLY reason
# the pool can skip this worktree here, so the lease taken above is released
# first while the worktree is still clean: a leased worktree is skipped by every
# later acquire whatever its contents, which would explain the skip below on its
# own. This case runs LAST because it deliberately leaves a slot dirty, which
# breaks the same-worktree invariant the cases above depend on.
pool_status_of() {  # <worktree>
  (cd "$REPO" && treehouse status --json 2>/dev/null) \
    | jq -r --arg p "$1" '.[]? | select(.path == $p) | .status' 2>/dev/null
}

(cd "$REPO" && treehouse return "$LEASE_WT" >/dev/null 2>&1) \
  || fail "could not release the lease on $LEASE_WT while it was still clean, so a later skip could not be attributed to dirtiness"

# Room for a second slot, so a skip is a choice the pool can make rather than
# one the cap forces on it.
printf 'max_trees = 2\nroot = "./"\n' > "$REPO/treehouse.toml"

# The contrast this case rests on: with the cap already raised, the pool hands
# THIS worktree back out while it is clean and unleased instead of creating the
# second slot. Without that observation the skip below would prove nothing,
# because a pool that never reuses a slot would look identical.
CLEAN_ACQ=$(cd "$REPO" && treehouse get --lease --lease-holder fm-pool-termination-clean 2>/dev/null) \
  || fail "treehouse $TREEHOUSE_VERSION could not acquire at all once the lease was released"
[ "$CLEAN_ACQ" = "$LEASE_WT" ] \
  || fail "the pool built $CLEAN_ACQ rather than reusing the clean unleased $LEASE_WT, so the dirty skip below would not be attributable to dirtiness"
(cd "$REPO" && treehouse return "$CLEAN_ACQ" >/dev/null 2>&1) \
  || fail "could not release the contrast lease on $CLEAN_ACQ"
pass "the pool reuses this worktree while it is clean and unleased, which is the contrast that makes the dirty case falsifiable"

printf 'unlanded edit\n' > "$LEASE_WT/holder-dirty.txt"
DIRTY_SHA=$(git -C "$LEASE_WT" rev-parse HEAD)
[ -n "$(git -C "$LEASE_WT" status --porcelain)" ] \
  || fail "the dirty case could not leave uncommitted changes in $LEASE_WT"
[ "$(pool_status_of "$LEASE_WT")" = dirty ] \
  || fail "treehouse $TREEHOUSE_VERSION reports $LEASE_WT as '$(pool_status_of "$LEASE_WT")' rather than dirty while it carries uncommitted changes; the record's dirty row needs re-deriving"
pass "the pool reads a worktree carrying uncommitted changes as dirty"

DIRTY_ACQ=$(cd "$REPO" && treehouse get --lease --lease-holder fm-pool-termination-dirty 2>/dev/null) \
  || fail "treehouse $TREEHOUSE_VERSION refused to acquire at all while the only existing slot was dirty; the record's dirty row needs re-deriving"
note "acquire with that worktree dirty and unleased handed out: $DIRTY_ACQ"
[ "$DIRTY_ACQ" != "$LEASE_WT" ] \
  || fail "treehouse $TREEHOUSE_VERSION handed out the worktree carrying uncommitted changes, which it had reused while clean; the record's claim that this detach costs branch position rather than unlanded edits no longer holds"
[ -f "$LEASE_WT/holder-dirty.txt" ] \
  || fail "treehouse $TREEHOUSE_VERSION discarded the uncommitted file in the dirty worktree"
[ "$(git -C "$LEASE_WT" rev-parse HEAD)" = "$DIRTY_SHA" ] \
  || fail "treehouse $TREEHOUSE_VERSION moved the dirty worktree's HEAD while acquiring elsewhere"
pass "the same worktree it reused while clean is skipped and left untouched once dirty, which is what bounds the acquire-time detach"

echo "# all fm-treehouse-pool-termination live tests passed"
