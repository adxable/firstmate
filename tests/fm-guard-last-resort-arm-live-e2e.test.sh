#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the turn-end guard's last-resort
# arm (bin/fm-turnend-guard.sh --claude + bin/fm-guard-last-resort-arm.sh).
#
# The auto-arm's claim micro-mutex is reclaimed only from a DEAD pid, so a
# recycled pid worn by any live process holds it forever and the Stop auto-arm
# stands down silently on every firing. Reproduced 2026-09-14 in an isolated
# home: five consecutive Stop events produced five blocks and zero watchers,
# and Claude's own consecutive-block override then ends such a turn blind.
#
# Two facts here are harness-dependent and a fixture can confirm neither, because
# a stub can only repeat the assumption written into it:
#   1. Claude runs the guard SYNCHRONOUSLY on Stop and delivers its exit-2
#      stderr, so the restored-supervision banner actually reaches the model.
#   2. A watcher the guard spawns from inside that synchronous hook SURVIVES
#      Claude tearing the hook down and outlives the session.
# Both are asserted against the real installed Claude Code, the real tracked
# hook registration, and this project's real bin/fm-watch.sh.
#
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, session, or watcher is touched:
# the only process this test signals is the one its own home recorded.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.guard-last-resort-arm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/claude.jsonl"
WEDGE_PID=
CLAUDE_VERSION=$(claude --version)

# Stop ONLY the watcher this test's own home recorded in its own lock. Never a
# pattern match: every firstmate home on this machine runs the same script.
stop_recorded_watcher() {
  local pid i=0
  pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
}

cleanup() {
  stop_recorded_watcher
  [ -z "$WEDGE_PID" ] || kill "$WEDGE_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the auto-arm live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"

# A live process wearing the claim mutex's recorded pid, exactly as a recycled
# pid does. While it lives the Stop auto-arm can never take the mutex, so it
# never claims, never arms, and never writes a ledger entry.
sleep 300 &
WEDGE_PID=$!
WEDGE_OWNER="$HOME_DIR/state/.claude-autoarm.lock.owner.wedged"
mkdir -p "$WEDGE_OWNER"
printf '%s\n' "$WEDGE_PID" > "$WEDGE_OWNER/pid"
ln -s "$WEDGE_OWNER" "$HOME_DIR/state/.claude-autoarm.lock"

PROMPT='Reply with exactly READY and stop. Whenever a Stop hook feedback message wakes you, reply with exactly ACK and stop. Never use any tool.'
(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude guard-arm session failed: $(tail -20 "$TRANSCRIPT")"

kill "$WEDGE_PID" 2>/dev/null || true
wait "$WEDGE_PID" 2>/dev/null || true
WEDGE_PID=

[ ! -e "$HOME_DIR/state/.claude-autoarm-epoch" ] \
  || fail "the auto-arm claimed despite a wedged mutex, so this run proved nothing about the guard's own arm"
grep -q 'SUPERVISION RESTORED BY THE TURN-END GUARD' "$TRANSCRIPT" \
  || fail "the synchronous guard never reported restoring supervision: $(tail -20 "$TRANSCRIPT")"
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "the guard claimed the turn ends blind after it had already armed a watcher"

WATCHER=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
case "$WATCHER" in
  ''|*[!0-9]*) fail "no watcher held the home after the session ended: the guard's arm did not survive Claude" ;;
esac
kill -0 "$WATCHER" 2>/dev/null \
  || fail "the guard-armed watcher (pid $WATCHER) did not survive Claude tearing the Stop hook down"

BEAT_AT=$( (stat -f %m "$HOME_DIR/state/.last-watcher-beat" 2>/dev/null \
  || stat -c %Y "$HOME_DIR/state/.last-watcher-beat" 2>/dev/null) || true)
case "$BEAT_AT" in
  ''|*[!0-9]*) fail "the guard-armed watcher never wrote a liveness beacon" ;;
esac
BEAT_AGE=$(( $(date +%s) - BEAT_AT ))
[ "$BEAT_AGE" -lt 300 ] \
  || fail "the guard-armed watcher stopped beating ${BEAT_AGE}s ago"

printf 'ok - Claude %s live E2E: the turn-end guard restored supervision over a wedged auto-arm claim mutex, and its watcher outlived the session (beacon %ss)\n' \
  "$CLAUDE_VERSION" "$BEAT_AGE"
