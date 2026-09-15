#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the silence sentry
# (bin/fm-silence-sentry.sh, armed from bin/fm-watch.sh's own close).
#
# The sentry exists to notice a home that stopped watching when NO turn ever
# ends, so quota exhaustion cannot hide behind a Stop boundary that never comes.
# Everything about its verdict is pinned portably in tests/fm-silence-sentry.test.sh.
# Exactly one fact in the mechanism is harness-dependent, and no fixture can
# confirm it because a stub could only repeat the assumption written into it:
#
#   A sentry forked from a watcher that a REAL Claude primary's Stop-owned
#   auto-arm brought up SURVIVES Claude tearing that process tree down and
#   ending the session.
#
# If it does not survive, the whole mechanism is inert exactly when it is needed:
# the sentry would die with the session whose silence it is there to report.
# The neighbouring bin/fm-guard-last-resort-arm.sh proves the same class of fact
# for the watcher it spawns inside a synchronous Stop hook.
#
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, session, or watcher is touched:
# the only processes this test signals are the ones its own home recorded.
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

LAB="$ROOT/.silence-sentry-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)
SENTRY_PID=

# Retire ONLY the processes this test's own home recorded in its own records.
# Never a pattern match: every firstmate home on this machine runs the same
# scripts, and a sibling home's watcher must stay unreachable from here.
retire_pid() { # <pid>
  local pid=$1 i=0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  return 0
}

# Order matters: a watcher ARMS a sentry as it closes, so the sentry record must
# be read only after the watcher is actually gone. Reading both up front would
# capture the record as it was before the close and miss the sentry that close
# created.
stop_recorded_processes() {
  retire_pid "$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)"
  retire_pid "$(awk -F '\t' 'NR == 1 { print $1 }' "$HOME_DIR/state/.silence-sentry" 2>/dev/null || true)"
}

# Reap BEFORE the lab is removed, or the sentry this test detached on purpose is
# left running against a deleted path - one survivor per run, which is exactly
# the leak the sentry itself must not have.
cleanup() {
  stop_recorded_processes
  retire_pid "${SENTRY_PID:-}"
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the neighbouring live E2Es).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# Already actionable before the session starts, so the watcher the auto-arm
# brings up closes while Claude is still alive. That close is what forks the
# sentry, and it forks it from inside Claude's own process tree - which is the
# only way this test can put survival to the question at all.
printf 'needs-decision: which option\n' > "$HOME_DIR/state/task.status"

# Hold the sentry's own evaluation well outside this session: what is under test
# is that the process survives, not what it decides, which the portable suite
# owns. The daemon's own notifier seam makes a real desktop notification
# impossible either way.
RECORDER="$LAB/alarm-recorder.sh"
cat > "$RECORDER" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$RECORDER"

PROMPT='Reply with exactly READY and stop. Whenever a Stop hook feedback message wakes you, reply with exactly ACK and stop. Never use any tool.'
(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" \
  FM_SILENCE_POLL_SECS=900 FM_SILENCE_ALARM_SECS=3600 FM_WEDGE_ALARM_EXEC="$RECORDER" \
  CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude silence-sentry session failed: $(tail -20 "$TRANSCRIPT")"

# Claude is gone. Everything asserted from here is about what outlived it.
[ -e "$HOME_DIR/state/.silence-sentry" ] \
  || fail "Claude $CLAUDE_VERSION: no watcher cycle in this session armed a sentry at its close"

SENTRY_PID=$(awk -F '\t' 'NR == 1 { print $1 }' "$HOME_DIR/state/.silence-sentry" 2>/dev/null || true)
case "$SENTRY_PID" in
  ''|*[!0-9]*) fail "Claude $CLAUDE_VERSION: the sentry record names no process" ;;
esac
kill -0 "$SENTRY_PID" 2>/dev/null \
  || fail "Claude $CLAUDE_VERSION: the sentry (pid $SENTRY_PID) did not survive Claude tearing its process tree down"

# Read the command line from the process table rather than reusing the recorded
# identity field: fm_pid_identity hex-encodes the command line wherever /proc is
# readable, so the recorded form carries no matchable script name off macOS.
SENTRY_COMMAND=$(ps -p "$SENTRY_PID" -o command= 2>/dev/null || true)
case "$SENTRY_COMMAND" in
  *fm-silence-sentry.sh*--watch*) ;;
  *) fail "Claude $CLAUDE_VERSION: the surviving process is not the sentry's own watch loop: $SENTRY_COMMAND" ;;
esac

# The wake it is holding must be a real one this session's watcher queued, not a
# value the test handed it.
SENTRY_SEQ=$(awk -F '\t' 'NR == 1 { print $3 }' "$HOME_DIR/state/.silence-sentry" 2>/dev/null || true)
case "$SENTRY_SEQ" in
  ''|*[!0-9]*) fail "Claude $CLAUDE_VERSION: the sentry is watching no wake sequence" ;;
esac
awk -F '\t' -v want="$SENTRY_SEQ" 'NF >= 5 && $2 == want { hit = 1 } END { exit(hit ? 0 : 1) }' \
  "$HOME_DIR/state/.wake-queue" 2>/dev/null \
  || fail "Claude $CLAUDE_VERSION: wake $SENTRY_SEQ is not in this home's durable queue"

# It must not have reported anything: this session was never silent.
[ -e "$HOME_DIR/state/.silence-alarm" ] \
  && fail "Claude $CLAUDE_VERSION: the sentry reported silence during a live, responding session"

# A live test that leaves a process running has not finished, it has escaped.
# Reap what this test detached, then prove it is gone before reporting ok, so a
# regression that made the sentry unkillable could never pass here.
#
# The pid asserted on above must be retired BY NAME, not merely by re-reading
# the record: retiring the watcher closes it, and that close arms a FRESH
# sentry which overwrites the record, so a reaper that only follows the record
# would kill the successor and leave this one running. That is precisely the
# per-close accumulation this whole mechanism must not have.
stop_recorded_processes
retire_pid "$SENTRY_PID"
kill -0 "$SENTRY_PID" 2>/dev/null \
  && fail "Claude $CLAUDE_VERSION: the sentry (pid $SENTRY_PID) survived this test's own reaping"

printf 'ok - Claude %s live E2E: a watcher close inside the session armed the silence sentry over wake %s, and it outlived Claude tearing the session down, then reaped cleanly (pid %s)\n' \
  "$CLAUDE_VERSION" "$SENTRY_SEQ" "$SENTRY_PID"
