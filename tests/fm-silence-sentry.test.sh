#!/usr/bin/env bash
# Behavior tests for the silence sentry (bin/fm-silence-sentry.sh).
#
# The sentry reports when a home stops watching and no turn ever picks the wake
# up - the quota-exhaustion shape, where no turn ever ENDS, so every
# Stop-boundary recovery path is structurally inert
# (docs/watcher-continuity.md "Silence with no Stop boundary").
#
# The fault and the "a turn is genuinely running" healthy shape are driven
# through the REAL bin/fm-watch.sh as a real process and the REAL
# bin/fm-wake-drain.sh, because the signal under test is a durable record those
# two produce and a stand-in could only repeat the assumption written into it.
# The remaining cases assert the gates directly over the same durable records.
#
# The alarm dispatch is redirected to a recorder through FM_SILENCE_ALARM_EXEC,
# so no case here can post a real desktop notification.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-silence-sentry)
fm_git_identity fmtest fmtest@example.invalid

# A one-second watcher poll keeps the beacon warm inside the grace, so
# fm_watcher_healthy stays decidable while the suite runs. The sentry deadline is
# floored at the grace by contract, so both move together.
export FM_POLL=1
export FM_GUARD_GRACE=10
export FM_SILENCE_ALARM_SECS=10
export FM_SILENCE_POLL_SECS=1

# A loaded machine can take well over half a minute to complete a watcher's first
# cycles, so every real-process wait here is generous rather than tight.
WATCHER_CLOSE_TIMEOUT=180

RECORDER="$TMP_ROOT/alarm-recorder.sh"
ALARM_LOG="$TMP_ROOT/alarms.log"
mkdir -p "$TMP_ROOT"
: > "$ALARM_LOG"
cat > "$RECORDER" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$ALARM_LOG"
EOF
chmod +x "$RECORDER"
export FM_SILENCE_ALARM_EXEC="$RECORDER"

# Fixture homes are recorded in a FILE, not a shell array: make_home is called
# from a command substitution, so an array append would happen in that subshell
# and never reach this one, leaving the reaper below with nothing to reap.
# tests/lib.sh's own cleanup registries work this way for the same reason.
FIXTURE_HOME_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-silence-sentry-homes.$$.XXXXXX")

# This suite detaches real sentry processes on purpose, so it must reap them:
# one survivor per run is exactly the leak the sentry itself must not have.
# Only processes a fixture home recorded in its OWN records are signalled -
# never a pattern match, because every firstmate home on this machine runs
# these same scripts and a sibling home must stay unreachable from here.
retire_pid() { # <pid>
  local pid=$1 i=0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  return 0
}

reap_fixture_processes() {
  local dir
  [ -f "$FIXTURE_HOME_REGISTRY" ] || return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    # Order matters: a watcher ARMS a sentry as it closes, so the sentry record
    # must be read only after the watcher is actually gone. Reading both up
    # front would capture the record as it was before the close and miss the
    # sentry that close created.
    retire_pid "$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)"
    retire_pid "$(awk -F '\t' 'NR == 1 { print $1 }' "$dir/state/.silence-sentry" 2>/dev/null || true)"
  done < "$FIXTURE_HOME_REGISTRY"
  rm -f "$FIXTURE_HOME_REGISTRY"
}

# Chained, never replaced: a bare `trap ... EXIT` here would drop tests/lib.sh's
# own fm_test_cleanup and leak every fixture temp root this suite creates.
trap 'reap_fixture_processes; fm_test_cleanup' EXIT

# A home running this project's real scripts, with one in-flight task so
# supervision is genuinely needed.
make_home() { # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/bin/backends"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp "$ROOT"/bin/*.sh "$dir/bin/"
  cp "$ROOT"/bin/*.mjs "$dir/bin/" 2>/dev/null || true
  cp "$ROOT"/bin/backends/*.sh "$dir/bin/backends/" 2>/dev/null || true
  chmod +x "$dir"/bin/*.sh
  printf 'project=fixture\nwindow=fixture:0\nbackend=tmux\n' > "$dir/state/task1.meta"
  : > "$dir/state/task1.status"
  printf '%s\n' "$dir" >> "$FIXTURE_HOME_REGISTRY"
  printf '%s\n' "$dir"
}

# The durable state a watcher close leaves: one queued wake no actor has claimed.
queue_one_unclaimed_wake() { # <home>
  printf '%s\t1\tsignal\ttask1.status\tneeds-decision: which option\n' "$(date +%s)" \
    > "$1/state/.wake-queue"
}

stop_home_watcher() { # <home>
  local dir=$1 pid i=0
  pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
}

# The same evidence fm_watcher_healthy requires: a live pid, the full lock
# identity a watcher publishes just after claiming, and a warm beacon. A bare
# live pid is not enough - a watcher between those two writes is not yet
# something the sentry may treat as supervision.
home_is_watched() { # <home>
  local dir=$1 pid beat now f
  pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  for f in fm-home watcher-path pid-identity; do
    [ -s "$dir/state/.watch.lock/$f" ] || return 1
  done
  [ -e "$dir/state/.last-watcher-beat" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    beat=$(/usr/bin/stat -f %m "$dir/state/.last-watcher-beat" 2>/dev/null) || return 1
  else
    beat=$(stat -c %Y "$dir/state/.last-watcher-beat" 2>/dev/null) || return 1
  fi
  now=$(date +%s)
  [ "$(( now - beat ))" -lt "$FM_GUARD_GRACE" ]
}

sentry_pid() { # <home>
  awk -F '\t' 'NR == 1 { print $1 }' "$1/state/.silence-sentry" 2>/dev/null || true
}

wait_for_sentry_exit() { # <home>
  local pid i=0
  pid=$(sentry_pid "$1")
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  while [ "$i" -lt 900 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

# Sets WATCHER_PID. Deliberately not a command substitution: that would launch
# the watcher from a subshell and leave this shell without a job to wait on.
WATCHER_PID=
start_watcher() { # <home>
  local dir=$1 i=0
  FM_HOME="$dir" "$dir/bin/fm-watch.sh" > "$dir/watch.out" 2>&1 &
  WATCHER_PID=$!
  while [ "$i" -lt "$((WATCHER_CLOSE_TIMEOUT * 4))" ] && ! home_is_watched "$dir"; do
    kill -0 "$WATCHER_PID" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
  done
  home_is_watched "$dir" \
    || fail "the real watcher never published this home's lock (said: $(cat "$dir/watch.out" 2>/dev/null))"
}

# Start the real watcher, trip it with a real actionable crew event, and wait for
# its own close. That close is what arms the sentry, and it leaves exactly the
# durable state the reported incident left: no watcher, and a queued wake no
# actor has claimed.
run_watcher_to_actionable_close() { # <home>
  local dir=$1 wpid i=0
  start_watcher "$dir"
  wpid=$WATCHER_PID
  printf 'needs-decision: which option\n' >> "$dir/state/task1.status"
  while [ "$i" -lt "$((WATCHER_CLOSE_TIMEOUT * 4))" ] && kill -0 "$wpid" 2>/dev/null; do
    sleep 0.25
    i=$((i + 1))
  done
  kill -0 "$wpid" 2>/dev/null && fail "the watcher never closed on its actionable wake"
  wait "$wpid" 2>/dev/null || true
  [ -s "$dir/state/.wake-queue" ] || fail "the watcher close queued no durable wake"

  # The close launches the sentry detached and deliberately does NOT wait for it,
  # because that trap runs inside a watcher process its callers bound with
  # `timeout`. So the record appears shortly AFTER the watcher exits, not before.
  i=0
  while [ "$i" -lt 200 ] && [ -z "$(sentry_pid "$dir")" ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# grep -c prints 0 AND exits 1 on no match, so the count must be captured rather
# than chained, or the fallback doubles it.
alarm_count() {
  local n
  n=$(grep -c . "$ALARM_LOG" 2>/dev/null) || n=0
  printf '%s\n' "${n:-0}"
}

# --- the fault --------------------------------------------------------------

# The captain's boundary rides along in this case on purpose: detect and report,
# never resume. A home whose quota is still exhausted must not resurrect itself.
test_reports_a_home_whose_wake_no_turn_ever_took() {
  local dir record
  dir=$(make_home fault)
  : > "$ALARM_LOG"
  run_watcher_to_actionable_close "$dir"

  [ -n "$(sentry_pid "$dir")" ] || fail "the watcher's close armed no sentry"
  [ "$(alarm_count)" -eq 0 ] || fail "the sentry alarmed before its deadline elapsed"

  wait_for_sentry_exit "$dir" || fail "the sentry never finished"
  [ -e "$dir/state/.silence-alarm" ] || fail "no durable silence record was written"
  record=$(cat "$dir/state/.silence-alarm")
  assert_contains "$record" "wake-kind=signal" "the record must name the wake nobody took"
  assert_contains "$record" "nothing was restarted" \
    "the record must state that nothing was restarted"
  [ "$(alarm_count)" -eq 1 ] || fail "expected exactly one alarm, got $(alarm_count)"
  assert_contains "$(cat "$ALARM_LOG")" "has not been watched" \
    "the alarm summary must say the home stopped being watched"

  home_is_watched "$dir" && fail "the sentry started a watcher; it must only report"
  [ -d "$dir/state/.watch.lock" ] && fail "a watcher lock reappeared after the report"
  pass "fm-silence-sentry: reports a home whose wake no turn took, and starts nothing"
}

# --- healthy shapes ---------------------------------------------------------

# A turn that is genuinely running claims the wake into its actor's file at the
# START of handling, so an arbitrarily long turn after that point stays silent.
test_silent_once_the_handling_turn_drains_the_wake() {
  local dir
  dir=$(make_home healthy-turn)
  : > "$ALARM_LOG"
  run_watcher_to_actionable_close "$dir"
  [ -n "$(sentry_pid "$dir")" ] || fail "the watcher's close armed no sentry"

  FM_HOME="$dir" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  [ -s "$dir/state/.main-eligible-rows" ] || fail "the real drain claimed no rows"

  wait_for_sentry_exit "$dir" || fail "the sentry did not retire after the drain"
  [ -e "$dir/state/.silence-alarm" ] && fail "a drained wake was reported as silence"
  [ "$(alarm_count)" -eq 0 ] || fail "the sentry alarmed on a home whose turn began"
  pass "fm-silence-sentry: silent once the handling turn claims the wake"
}

# An idle home with no work is a healthy resting state and must never be reported.
test_never_arms_on_an_idle_home() {
  local dir
  dir=$(make_home idle)
  rm -f "$dir/state/task1.meta"
  queue_one_unclaimed_wake "$dir"
  : > "$ALARM_LOG"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero on an idle home"
  [ -e "$dir/state/.silence-sentry" ] && fail "an idle home armed a sentry"
  [ "$(alarm_count)" -eq 0 ] || fail "an idle home produced an alarm"
  pass "fm-silence-sentry: an idle home with no work never arms one"
}

# Away mode transfers supervision ownership to the away daemon.
test_never_arms_under_away_mode() {
  local dir
  dir=$(make_home away)
  queue_one_unclaimed_wake "$dir"
  : > "$dir/state/.afk"
  : > "$ALARM_LOG"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero under away mode"
  [ -e "$dir/state/.silence-sentry" ] && fail "away mode armed a sentry underneath the daemon"
  [ "$(alarm_count)" -eq 0 ] || fail "away mode produced an alarm"
  pass "fm-silence-sentry: never arms underneath the away daemon"
}

# A watcher parked on a long external wait is alive and beating: the healthy
# shape the sentry must never read as a fault.
test_silent_while_a_watcher_is_live() {
  local dir out status attempt=0 proved=1
  dir=$(make_home parked)
  : > "$ALARM_LOG"
  start_watcher "$dir"
  queue_one_unclaimed_wake "$dir"

  # The real watcher is a live process and may legitimately close at any moment
  # (an actionable reason, its own heartbeat). Only a home that is STILL watched
  # at the instant of each read can prove this gate, so the evidence and the
  # watcher's liveness are read together and a watcher that closed first is
  # restarted rather than reported as a failure nothing observed.
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    if ! home_is_watched "$dir"; then
      stop_home_watcher "$dir"
      rm -f "$dir/state/.silence-sentry"
      start_watcher "$dir"
      continue
    fi

    out=$(FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --check); status=$?
    home_is_watched "$dir" || continue
    if [ "$status" -eq 0 ]; then
      stop_home_watcher "$dir"
      fail "a home watched at the moment of the check was reported as silence: $out"
    fi
    assert_contains "$out" "watcher live" "the live watcher must be the stated reason"

    rm -f "$dir/state/.silence-sentry"
    FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || true
    home_is_watched "$dir" || continue
    if [ -e "$dir/state/.silence-sentry" ]; then
      stop_home_watcher "$dir"
      fail "a home watched at the moment of the arm armed a sentry anyway"
    fi
    proved=0
    break
  done

  stop_home_watcher "$dir"
  [ "$proved" -eq 0 ] \
    || fail "the watcher never stayed live long enough to exercise this gate (said: $(cat "$dir/watch.out" 2>/dev/null))"
  [ "$(alarm_count)" -eq 0 ] || fail "a live watcher produced an alarm"
  pass "fm-silence-sentry: silent while this home's own watcher is live"
}

# The deadline is the whole difference between this and a bare "no watcher"
# alarm, which would fire on every healthy mid-turn gap.
test_no_report_before_the_deadline_elapses() {
  local dir
  dir=$(make_home patient)
  queue_one_unclaimed_wake "$dir"
  : > "$ALARM_LOG"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -n "$(sentry_pid "$dir")" ] || fail "arm recorded no sentry"
  sleep 4
  [ -e "$dir/state/.silence-alarm" ] && fail "reported silence before the deadline elapsed"
  [ "$(alarm_count)" -eq 0 ] || fail "alarmed before the deadline elapsed"
  # The condition itself is already true; only the deadline holds the report back.
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --check >/dev/null \
    || fail "this home is unwatched with an unclaimed wake, so --check must say so"
  pass "fm-silence-sentry: an unwatched home is not reported until the deadline elapses"
}

# --- lifecycle --------------------------------------------------------------

test_marker_is_retired_once_the_home_cycles_again() {
  local dir
  dir=$(make_home recovered)
  queue_one_unclaimed_wake "$dir"
  printf 'stale record\n' > "$dir/state/.silence-alarm"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -e "$dir/state/.silence-alarm" ] \
    && fail "a completed watcher cycle left the previous silence record standing"
  pass "fm-silence-sentry: a new watcher cycle retires the previous silence record"
}

test_arm_is_a_singleton_per_home() {
  local dir first second
  dir=$(make_home singleton)
  queue_one_unclaimed_wake "$dir"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "first arm failed"
  first=$(sentry_pid "$dir")
  [ -n "$first" ] || fail "the first arm recorded no sentry"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "second arm failed"
  second=$(sentry_pid "$dir")
  [ "$first" = "$second" ] || fail "a second sentry was started ($first then $second)"
  pass "fm-silence-sentry: one sentry per home, never a second"
}

test_reports_nothing_when_every_queued_wake_is_claimed() {
  local dir out status
  dir=$(make_home claimed)
  queue_one_unclaimed_wake "$dir"
  printf '1\n' > "$dir/state/.main-eligible-rows"
  out=$(FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --check); status=$?
  [ "$status" -eq 0 ] && fail "a claimed wake was reported as silence: $out"
  assert_contains "$out" "no unclaimed wake" "a fully claimed queue must say so"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -e "$dir/state/.silence-sentry" ] && fail "a fully claimed queue armed a sentry"
  pass "fm-silence-sentry: a queue whose rows are all claimed arms nothing"
}

# The deadline is floored at the watcher grace, so the sentry can never be more
# eager than the staleness bound the rest of the stack already applies.
test_deadline_is_floored_at_the_watcher_grace() {
  local dir out
  dir=$(make_home floored)
  out=$(FM_SILENCE_ALARM_SECS=1 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --status)
  assert_contains "$out" "deadline-seconds=$FM_GUARD_GRACE" \
    "a deadline below the grace must be raised to the grace, not honoured"
  out=$(FM_SILENCE_ALARM_SECS=4242 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --status)
  assert_contains "$out" "deadline-seconds=4242" \
    "a deadline above the grace must be honoured as configured"
  pass "fm-silence-sentry: the report deadline is floored at the watcher grace"
}

# --- termination: a sentry must never outlive its subject --------------------

# A sentry is armed on EVERY watcher close, so one that survives what it watches
# is not a stray process but one stray process per close, accumulating for as
# long as the home runs and each holding a stale generation.
test_exits_when_its_home_is_deleted() {
  local dir pid i=0
  dir=$(make_home vanishing)
  queue_one_unclaimed_wake "$dir"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm \
    || fail "arm exited nonzero"
  pid=$(sentry_pid "$dir")
  [ -n "$pid" ] || fail "arm recorded no sentry"
  kill -0 "$pid" 2>/dev/null || fail "the sentry was not running to begin with"

  rm -rf "$dir"
  while [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "the sentry outlived the home it was watching"
  fi
  pass "fm-silence-sentry: a sentry exits when the home it watches is deleted"
}

# A superseded generation must stand down rather than report, or retire records
# the current sentry owns.
test_exits_when_superseded_by_a_newer_sentry() {
  local dir first second i=0
  dir=$(make_home superseded)
  queue_one_unclaimed_wake "$dir"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm \
    || fail "first arm failed"
  first=$(sentry_pid "$dir")
  [ -n "$first" ] || fail "the first arm recorded no sentry"

  # Drop the record so the singleton gate lets a second generation start, which
  # is exactly the state a superseding arm produces.
  rm -f "$dir/state/.silence-sentry"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm \
    || fail "second arm failed"
  second=$(sentry_pid "$dir")
  [ -n "$second" ] || fail "the second arm recorded no sentry"
  [ "$first" != "$second" ] || fail "the second arm did not start a new sentry"

  while [ "$i" -lt 150 ] && kill -0 "$first" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$first" 2>/dev/null; then
    kill -KILL "$first" 2>/dev/null || true
    fail "the superseded sentry ($first) kept running beside its successor ($second)"
  fi
  kill -0 "$second" 2>/dev/null || fail "the current sentry stood down instead of the superseded one"
  [ "$(sentry_pid "$dir")" = "$second" ] \
    || fail "the superseded sentry retired the current sentry's record on its way out"
  pass "fm-silence-sentry: a superseded sentry stands down and leaves the current one alone"
}

test_reports_a_home_whose_wake_no_turn_ever_took
test_silent_once_the_handling_turn_drains_the_wake
test_never_arms_on_an_idle_home
test_never_arms_under_away_mode
test_silent_while_a_watcher_is_live
test_no_report_before_the_deadline_elapses
test_marker_is_retired_once_the_home_cycles_again
test_arm_is_a_singleton_per_home
test_reports_nothing_when_every_queued_wake_is_claimed
test_deadline_is_floored_at_the_watcher_grace
test_exits_when_its_home_is_deleted
test_exits_when_superseded_by_a_newer_sentry
