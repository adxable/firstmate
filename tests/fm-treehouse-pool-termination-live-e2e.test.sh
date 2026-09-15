#!/usr/bin/env bash
# tests/fm-treehouse-pool-termination-live-e2e.test.sh - drift guard for
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
# The acquire cases pin the pool tool's own documented reuse contract, which
# treehouse v2.3.0 deliberately narrowed: a slot is reused only when it is
# "idle, unleased, clean, and HEAD merged into the exact reset target"
# (README "How It Works"), so a slot holding unlanded work is now skipped
# instead of reclaimed and reset (release v2.3.0, "get: skip reclaiming a pool
# slot that holds unlanded work", kunchenguid/treehouse#104, fixing #79).
# That narrowing applies to the acquire path only. The return path still resets
# an unlanded commit away, which is the asymmetry discard_refused_endpoint rests
# on and which the normal-exit case asserts directly.
#
# Every worktree here lives inside a throwaway repo whose treehouse.toml sets
# root = "./", so the pool is created under the lab directory and no real pool
# is touched. tmux runs on a private socket for the same reason.
#
# Standard CI has no treehouse binary, so the shared gate skips this there and
# it runs wherever both binaries are installed. Run it after a treehouse
# upgrade and before trusting the dated record in
# docs/verification/runtime-backends.md "Endpoint kill and worktree-pool safety".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_TREEHOUSE_POOL_TERMINATION_DRIFT tmux treehouse jq

REAL_TMUX=
SOCKET="fm-pool-termination-$$"
LAB=
SESSION=pool

cleanup_all() {
  [ -z "$REAL_TMUX" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf "$LAB"
  fm_test_cleanup
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

pool_status_of() {  # <worktree>
  (cd "$REPO" && treehouse status --json 2>/dev/null) \
    | jq -r --arg p "$1" '.[]? | select(.path == $p) | .status' 2>/dev/null
}

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

# --- what the acquire will NOT reclaim: a slot holding unlanded work ---------
# treehouse changed this deliberately in v2.3.0: release v2.3.0 lists
# "get: skip reclaiming a pool slot that holds unlanded work"
# (kunchenguid/treehouse#104, fixing #79), and the README's "How It Works"
# acquire step now reads "idle, unleased, clean, and HEAD merged into the exact
# reset target; skip if safety is unprovable".
# Before that, occupancy alone decided reuse: the worktree the killed pane left
# on holder-kill read idle and clean, so the next acquire took it and reset
# holder-kill's commit away. The pool now refuses it instead.
# The status read is what makes this a statement about unlanded work rather than
# about occupancy - the pool still reports the slot free, and still will not
# hand it out.
KILL_POOL_STATUS=$(pool_status_of "$KILL_WT")
[ "$KILL_POOL_STATUS" = available ] \
  || fail "treehouse $TREEHOUSE_VERSION reports the killed pane's worktree as '$KILL_POOL_STATUS' rather than available, so the refusal below would be occupancy rather than the unlanded commit and this case proves nothing"
if (cd "$REPO" && treehouse get --lease --lease-holder fm-pool-termination-unlanded >/dev/null 2>&1); then
  fail "treehouse $TREEHOUSE_VERSION handed out the single-slot worktree while it still carried holder-kill's unlanded commit; that reclaim resets the slot, so the unlanded-work protection v2.3.0 added in kunchenguid/treehouse#104 is gone and a dead task's committed work can be discarded at acquire time again"
fi
[ "$(branch_of "$KILL_WT")" = holder-kill ] \
  || fail "treehouse $TREEHOUSE_VERSION moved the worktree off holder-kill while refusing to hand it out"
[ "$(git -C "$KILL_WT" rev-parse HEAD)" = "$KILL_SHA" ] \
  || fail "treehouse $TREEHOUSE_VERSION moved the worktree's HEAD while refusing to hand it out"
pass "the acquire skips the single slot while it holds an unlanded commit, even though the pool reads it free, on $TREEHOUSE_VERSION"

# --- the contrast that makes that skip falsifiable, and keeps the record honest
# Landing holder-kill's commit into the ref the reset resolves to is the ONLY
# thing that changes between the refusal above and the reuse here, so the skip
# is attributable to the unlanded commit and to nothing else - not to the
# max_trees cap, which is identical in both halves.
# It also re-establishes the fact the dated record's acquire row rests on: the
# pool still detaches what it DOES hand out, before the caller can inspect it.
# This is the non-interactive lease form on purpose, because that is the one an
# ownership check would have to use to resolve a path before opening any pane,
# and it is a live firstmate call path (bin/fm-home-seed.sh). So no pre-acquire
# ownership check avoids that detach; v2.3.0 only bounds what it can cost.
git -C "$REPO" merge -q --ff-only "$KILL_SHA" \
  || fail "could not land holder-kill's commit into the default branch, so the reuse contrast cannot run"
LANDED_TIP=$(git -C "$REPO" rev-parse HEAD)
ACQ_WT=$(cd "$REPO" && treehouse get --lease --lease-holder fm-pool-termination-landed 2>/dev/null) \
  || fail "treehouse $TREEHOUSE_VERSION still refused the single-slot worktree after its only commit was landed; the skip above can no longer be attributed to unlanded work, so this guard can no longer tell that protection apart from a pool that never reuses a slot"
[ "$ACQ_WT" = "$KILL_WT" ] || fail "the single-slot pool handed out $ACQ_WT rather than $KILL_WT, so the cases below no longer observe the same worktree"
if [ "$(branch_of "$ACQ_WT")" = holder-kill ]; then
  fail "treehouse $TREEHOUSE_VERSION no longer resets a worktree when it acquires one; the dated record's claim that the destructive step happens at acquire time no longer describes this pool"
fi
[ "$(git -C "$ACQ_WT" rev-parse HEAD)" = "$LANDED_TIP" ] \
  || fail "treehouse $TREEHOUSE_VERSION reused the slot without resetting it to the landed default-branch tip, so the reset target the record names is no longer the one the acquire uses"
(cd "$REPO" && treehouse return "$ACQ_WT" >/dev/null 2>&1) \
  || fail "could not release the contrast lease on $ACQ_WT"
pass "landing that commit is the only change needed to get the same slot handed back out, reset to the default-branch tip"

# --- the same detach, on the interactive acquire form ------------------------
# The record's acquire row claims BOTH forms detach, and the interactive
# `treehouse get` is the one fm-spawn.sh sends into the worker's own pane, so it
# is pinned directly here rather than inferred from the lease form above.
# The returned slot is already detached, which would leave a pane acquire
# nothing to take away, so it is put back on a branch first. That branch sits at
# the landed tip and carries no edits, so it is clean and its HEAD IS the reset
# target: v2.3.0's narrowed rule permits the reuse, and branch position is the
# only thing left for the acquire to detach.
git -C "$ACQ_WT" checkout -q -b probe-interactive "$LANDED_TIP" \
  || fail "could not put the returned slot on a clean branch at the landed tip, so the interactive acquire case cannot run"
[ -z "$(git -C "$ACQ_WT" status --porcelain)" ] \
  || fail "the interactive acquire case started with uncommitted changes in $ACQ_WT, so the pool could skip it for dirtiness and a detach below would not be attributable to the acquire"

# --- the contrast that proves this lab drives the real return path -----------
# The return path did NOT gain the acquire path's protection: an unlanded commit
# is still reset away when the subshell exits. That asymmetry is exactly what
# discard_refused_endpoint rests on, so it is asserted rather than implied - the
# orphaned pane an operator would close is still the termination that costs the
# contested worktree its work, which is why the refusal takes its own tmux
# endpoint down instead of leaving it parked.
ACQ_WT=$(acquire_in_pane fm-acquire) || fail "treehouse $TREEHOUSE_VERSION did not hand out the clean, landed single-slot worktree to a pane"
[ "$ACQ_WT" = "$KILL_WT" ] || fail "the single-slot pool handed out $ACQ_WT rather than $KILL_WT, so the cases below no longer observe the same worktree"
[ "$(branch_of "$ACQ_WT")" != probe-interactive ] \
  || fail "the interactive treehouse get handed the pane its worktree still on probe-interactive; the record's claim that BOTH acquire forms detach before the caller can inspect the worktree no longer holds for the form fm-spawn.sh sends into the worker's own pane"
[ "$(git -C "$ACQ_WT" rev-parse HEAD)" = "$LANDED_TIP" ] \
  || fail "the interactive treehouse get reused the slot without resetting it to the landed default-branch tip, so the reset target the record names is not the one the interactive acquire uses"
pass "the interactive treehouse get detaches the worktree it hands out as well, not only the non-interactive lease form"

stage_holder_state "$ACQ_WT" holder-exit || fail "could not stage the holder state in $ACQ_WT"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "=$SESSION:=fm-acquire" 'exit' Enter || fail "could not exit the task subshell"
sleep 5

if [ "$(branch_of "$ACQ_WT")" = holder-exit ]; then
  fail "treehouse $TREEHOUSE_VERSION no longer resets the worktree when its subshell exits normally; this lab can no longer tell a return apart from a no-op, so the kill case above proves nothing"
fi
[ ! -f "$ACQ_WT/holder-exit-work.txt" ] \
  || fail "treehouse $TREEHOUSE_VERSION now preserves an unlanded commit through the return path as well; discard_refused_endpoint's reason for taking its own tmux endpoint down rather than leaving an orphaned pane no longer holds and must be re-derived"
pass "a normally exited subshell does return and reset the worktree, discarding the unlanded commit the acquire path now protects"

# --- what the acquire-time detach does NOT cost ------------------------------
# The uncommitted half of the same boundary. The unlanded-commit case above is
# what v2.3.0 changed; this one has always held, and it is still what bounds the
# detach for edits that were never committed at all.
# Dirtiness has to be the ONLY reason the pool can skip this worktree here, so
# the worktree is left unleased and clean going in: a leased worktree is skipped
# by every later acquire whatever its contents, and so now is one holding an
# unlanded commit, and either would explain the skip below on its own. The exit
# above already returned it, so it is clean and at the landed tip.
# This case runs LAST because it deliberately leaves a slot dirty, which breaks
# the same-worktree invariant the cases above depend on.
[ -z "$(git -C "$ACQ_WT" status --porcelain)" ] \
  || fail "the dirty case started with uncommitted changes already in $ACQ_WT, so a skip below could not be attributed to the ones it stages"
[ "$(pool_status_of "$ACQ_WT")" = available ] \
  || fail "the dirty case started with $ACQ_WT reading '$(pool_status_of "$ACQ_WT")' rather than available, so a skip below could not be attributed to dirtiness"

# Room for a second slot, so a skip is a choice the pool can make rather than
# one the cap forces on it.
printf 'max_trees = 2\nroot = "./"\n' > "$REPO/treehouse.toml"

# The contrast this case rests on: with the cap already raised, the pool hands
# THIS worktree back out while it is clean and unleased instead of creating the
# second slot. Without that observation the skip below would prove nothing,
# because a pool that never reuses a slot would look identical.
CLEAN_ACQ=$(cd "$REPO" && treehouse get --lease --lease-holder fm-pool-termination-clean 2>/dev/null) \
  || fail "treehouse $TREEHOUSE_VERSION could not acquire at all once the lease was released"
[ "$CLEAN_ACQ" = "$ACQ_WT" ] \
  || fail "the pool built $CLEAN_ACQ rather than reusing the clean unleased $ACQ_WT, so the dirty skip below would not be attributable to dirtiness"
(cd "$REPO" && treehouse return "$CLEAN_ACQ" >/dev/null 2>&1) \
  || fail "could not release the contrast lease on $CLEAN_ACQ"
pass "the pool reuses this worktree while it is clean and unleased, which is the contrast that makes the dirty case falsifiable"

printf 'unlanded edit\n' > "$ACQ_WT/holder-dirty.txt"
DIRTY_SHA=$(git -C "$ACQ_WT" rev-parse HEAD)
[ -n "$(git -C "$ACQ_WT" status --porcelain)" ] \
  || fail "the dirty case could not leave uncommitted changes in $ACQ_WT"
[ "$(pool_status_of "$ACQ_WT")" = dirty ] \
  || fail "treehouse $TREEHOUSE_VERSION reports $ACQ_WT as '$(pool_status_of "$ACQ_WT")' rather than dirty while it carries uncommitted changes; the record's dirty row needs re-deriving"
pass "the pool reads a worktree carrying uncommitted changes as dirty"

DIRTY_ACQ=$(cd "$REPO" && treehouse get --lease --lease-holder fm-pool-termination-dirty 2>/dev/null) \
  || fail "treehouse $TREEHOUSE_VERSION refused to acquire at all while the only existing slot was dirty; the record's dirty row needs re-deriving"
note "acquire with that worktree dirty and unleased handed out: $DIRTY_ACQ"
[ "$DIRTY_ACQ" != "$ACQ_WT" ] \
  || fail "treehouse $TREEHOUSE_VERSION handed out the worktree carrying uncommitted changes, which it had reused while clean; the record's claim that this detach costs branch position rather than unlanded edits no longer holds"
[ -f "$ACQ_WT/holder-dirty.txt" ] \
  || fail "treehouse $TREEHOUSE_VERSION discarded the uncommitted file in the dirty worktree"
[ "$(git -C "$ACQ_WT" rev-parse HEAD)" = "$DIRTY_SHA" ] \
  || fail "treehouse $TREEHOUSE_VERSION moved the dirty worktree's HEAD while acquiring elsewhere"
pass "the same worktree it reused while clean is skipped and left untouched once dirty, which is what bounds the acquire-time detach"

echo "# all fm-treehouse-pool-termination live tests passed"
