#!/usr/bin/env bash
# tests/fm-tmux-target-fallback-live-e2e.test.sh - opt-in drift guard for the
# tmux named-target fallback that proof-grade endpoint existence is built on
# (fm_backend_target_proven, bin/fm-backend.sh).
#
# Why this file exists: the vendor surface under version control here is tmux
# itself. How tmux resolves an absent `<session>:<name>` target is a behavior
# its release notes can change, and firstmate's worktree-ownership guard is
# correct only because that resolution is known: a bare read of an absent
# named target answers about the client's active window instead of failing, so
# only a session inventory can establish that a recorded endpoint is gone.
#
# This guard runs the exact commands recorded in
# docs/verification/runtime-backends.md "Named-target fallback" against the
# INSTALLED tmux, prints what it observed, and fails naming the version when
# the recorded behavior no longer holds. It is the command that refreshes that
# record after a tmux upgrade.
#
# It refuses to pass without checking anything: an absent tmux fails here
# rather than skipping. The portable counterpart in
# tests/fm-tmux-target-proof.test.sh pins the logic in CI, where tmux may be
# absent and skipping is correct.
set -u

if [ "${FM_TMUX_TARGET_FALLBACK_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_TMUX_TARGET_FALLBACK_DRIFT=1 to run the installed-tmux named-target fallback guard"
  exit 0
fi

REAL_TMUX=
SOCKET="fm-target-fallback-$$"
SESSION=sess

cleanup_all() {
  [ -n "$REAL_TMUX" ] || return 0
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found; this guard cannot pass without checking a real tmux"
REAL_TMUX=$(command -v tmux)
TMUX_VERSION=$("$REAL_TMUX" -V 2>/dev/null || printf 'unknown')

note "tmux version: $TMUX_VERSION"
note "uname: $(uname -sm)"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n fm-real 'sleep 300' \
  || fail "could not start a private tmux server with $TMUX_VERSION"

PRESENT_OUT=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-real" '#{pane_id}' 2>&1)
PRESENT_STATUS=$?
ABSENT_OUT=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-does-not-exist" '#{pane_id}' 2>&1)
ABSENT_STATUS=$?
INVENTORY=$("$REAL_TMUX" -L "$SOCKET" list-windows -t "$SESSION" -F '#{window_name}' 2>&1)
INVENTORY_STATUS=$?

note "display-message on the present window: status=$PRESENT_STATUS output=$PRESENT_OUT"
note "display-message on the absent window:  status=$ABSENT_STATUS output=$ABSENT_OUT"
note "list-windows inventory: status=$INVENTORY_STATUS output=$(printf '%s' "$INVENTORY" | tr '\n' ' ')"

[ "$PRESENT_STATUS" -eq 0 ] || fail "$TMUX_VERSION could not read the window that exists"
pass "the present window reads back on $TMUX_VERSION"

if [ "$ABSENT_STATUS" -ne 0 ]; then
  fail "$TMUX_VERSION no longer falls back to the active window for an absent named target; re-derive the recorded evidence and re-check every caller that reasons about endpoint absence"
fi
[ "$ABSENT_OUT" = "$PRESENT_OUT" ] || \
  fail "$TMUX_VERSION answered the absent target with '$ABSENT_OUT' rather than the active window's '$PRESENT_OUT'; the recorded evidence no longer describes this tmux"
pass "an absent named target is indistinguishable from the present one on $TMUX_VERSION"

[ "$INVENTORY_STATUS" -eq 0 ] || fail "$TMUX_VERSION could not list the session's windows"
printf '%s\n' "$INVENTORY" | grep -Fqx fm-real \
  || fail "$TMUX_VERSION omitted the present window from its own inventory"
if printf '%s\n' "$INVENTORY" | grep -Fqx fm-does-not-exist; then
  fail "$TMUX_VERSION listed a window that was never created"
fi
pass "the session inventory still separates the present window from the absent one on $TMUX_VERSION"

echo "# all fm-tmux-target-fallback live tests passed"
