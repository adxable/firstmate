#!/usr/bin/env bash
# Behavior tests for the silence sentry (bin/fm-silence-sentry.sh).
#
# The sentry reports when a home stops watching and no turn ever finishes
# handling the wake - the quota-exhaustion shape, where no turn ever ENDS, so
# every Stop-boundary recovery path is structurally inert
# (docs/watcher-continuity.md "Silence with no Stop boundary").
#
# The fault and the healthy handling shape are driven through the REAL
# bin/fm-watch.sh as a real process and the REAL bin/fm-wake-drain.sh, including
# its post-handling acknowledgement, because the signal under test is a durable
# record those two produce and a stand-in could only repeat the assumption
# written into it. The claim the drain writes at the START of handling is
# deliberately exercised WITHOUT that acknowledgement: that is the quota shape,
# and a sentry that retired on the claim would go blind for the rest of the turn.
# The remaining cases assert the gates directly over the same durable records.
#
# The alarm runs its real dispatch path, through the daemon's one-shot entry and
# its own FM_WEDGE_ALARM_EXEC notifier seam, which is redirected to a recorder
# here so no case can post a real desktop notification.
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
export FM_WEDGE_ALARM_EXEC="$RECORDER"
# `auto` resolves to no channel off macOS, so name one explicitly and the whole
# dispatch path - the sentry's exec of the daemon, the daemon's one-shot --alarm
# entry, its directive parsing and its emit - runs on every platform. The seam
# above replaces the notifier itself, so nothing reaches Notification Center.
export FM_WEDGE_ALARM_CHANNEL=osascript

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

# The durable state a watcher close leaves: one queued wake no turn has handled.
# The sequence counter moves with it, so a later real append (the sentry's own
# report) takes the next sequence instead of colliding with this row.
queue_one_unhandled_wake() { # <home>
  printf '%s\t1\tsignal\ttask1.status\tneeds-decision: which option\n' "$(date +%s)" \
    > "$1/state/.wake-queue"
  printf '1\n' > "$1/state/.wake-queue.seq"
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

# The two halves of handling a wake, as AGENTS.md section 8 defines them and as
# the real drain implements them: the claim at the START of handling, and the
# acknowledgement AFTER it. They are separate calls here because the whole
# verdict under test turns on which of the two retires a sentry.
drain_wake() { # <home>
  local dir=$1
  FM_HOME="$dir" "$dir/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" || true
}

acknowledge_wake() { # <home>
  local dir=$1 seq generation
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' \
    "$dir/drain.err" | tail -1)
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' \
    "$dir/drain.err" | tail -1)
  [ -n "$seq" ] && [ -n "$generation" ] \
    || fail "the real drain demanded no acknowledgement (said: $(cat "$dir/drain.err" 2>/dev/null))"
  FM_HOME="$dir" "$dir/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" \
    >/dev/null 2>&1 || fail "the real post-handling acknowledgement failed"
}

# grep -c prints 0 AND exits 1 on no match, so the count must be captured rather
# than chained, or the fallback doubles it.
alarm_count() {
  local n
  n=$(grep -c . "$ALARM_LOG" 2>/dev/null) || n=0
  printf '%s\n' "${n:-0}"
}

# The alarms THIS home raised, found by the home path every summary carries.
# The log is shared by every fixture, and a home this suite deliberately leaves
# unwatched keeps its own sentry armed, so it can report while a later case is
# running; only a per-home count decides anything after that point.
alarm_count_for() { # <home>
  local n
  n=$(grep -c -F "$1" "$ALARM_LOG" 2>/dev/null) || n=0
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
  assert_contains "$(cat "$ALARM_LOG")" "osascript" \
    "the alarm must reach the home's configured channel through the real dispatch"

  # The durable half needs a reader, and the wake queue is the one this home
  # already presents. Assert it through the real drain rather than the file.
  drain_wake "$dir"
  assert_contains "$(cat "$dir/drain.out")" "has not been watched" \
    "the report must be presented to the next turn by the real drain"

  home_is_watched "$dir" && fail "the sentry started a watcher; it must only report"
  [ -d "$dir/state/.watch.lock" ] && fail "a watcher lock reappeared after the report"
  pass "fm-silence-sentry: reports a home whose wake no turn took, and starts nothing"
}

# The reported incident's exact shape: the woken turn began - it claimed the row
# at its opening drain - and then died at its usage limit without ever finishing.
# There is no Stop event, no watcher, and no later claim to observe, so a sentry
# that retired at the claim would be blind for the whole remainder of the turn,
# which is precisely where quota is consumed.
test_reports_a_wake_a_turn_claimed_but_never_finished() {
  local dir record
  dir=$(make_home quota-mid-turn)
  : > "$ALARM_LOG"
  run_watcher_to_actionable_close "$dir"
  [ -n "$(sentry_pid "$dir")" ] || fail "the watcher's close armed no sentry"

  drain_wake "$dir"
  [ -s "$dir/state/.main-eligible-rows" ] || fail "the real drain claimed no rows"
  # No acknowledgement follows: this turn never gets that far.

  wait_for_sentry_exit "$dir" || fail "the sentry never finished"
  [ -e "$dir/state/.silence-alarm" ] \
    || fail "a turn that claimed the wake and then died was never reported"
  record=$(cat "$dir/state/.silence-alarm")
  assert_contains "$record" "never acknowledged by any turn" \
    "the record must name the acknowledgement that never came"
  [ "$(alarm_count)" -eq 1 ] || fail "expected exactly one alarm, got $(alarm_count)"
  home_is_watched "$dir" && fail "the sentry started a watcher; it must only report"
  pass "fm-silence-sentry: reports a wake a turn claimed and never finished"
}

# --- healthy shapes ---------------------------------------------------------

# A turn that finishes acknowledges the wake after handling it, which is the one
# durable record that says a turn actually got to the end of something.
test_silent_once_the_handling_turn_acknowledges_the_wake() {
  local dir out
  dir=$(make_home healthy-turn)
  : > "$ALARM_LOG"
  run_watcher_to_actionable_close "$dir"
  [ -n "$(sentry_pid "$dir")" ] || fail "the watcher's close armed no sentry"

  drain_wake "$dir"
  [ -s "$dir/state/.main-eligible-rows" ] || fail "the real drain claimed no rows"
  acknowledge_wake "$dir"

  wait_for_sentry_exit "$dir" || fail "the sentry did not retire after the acknowledgement"
  [ -e "$dir/state/.silence-alarm" ] && fail "a handled wake was reported as silence"
  [ "$(alarm_count)" -eq 0 ] || fail "the sentry alarmed on a home whose turn finished"

  # And nothing is left for a later close to arm over.
  out=$(FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --check) && \
    fail "a home with no unhandled wake was reported as silence: $out"
  assert_contains "$out" "no unhandled wake" "a fully handled queue must say so"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -e "$dir/state/.silence-sentry" ] && fail "a fully handled queue armed a sentry"
  pass "fm-silence-sentry: silent once the handling turn acknowledges the wake"
}

# An idle home with no work is a healthy resting state and must never be reported.
test_never_arms_on_an_idle_home() {
  local dir
  dir=$(make_home idle)
  rm -f "$dir/state/task1.meta"
  queue_one_unhandled_wake "$dir"
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
  queue_one_unhandled_wake "$dir"
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
  queue_one_unhandled_wake "$dir"

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
  queue_one_unhandled_wake "$dir"
  : > "$ALARM_LOG"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -n "$(sentry_pid "$dir")" ] || fail "arm recorded no sentry"
  sleep 4
  [ -e "$dir/state/.silence-alarm" ] && fail "reported silence before the deadline elapsed"
  [ "$(alarm_count_for "$dir")" -eq 0 ] || fail "alarmed before the deadline elapsed"
  # The condition itself is already true; only the deadline holds the report back.
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --check >/dev/null \
    || fail "this home is unwatched with an unhandled wake, so --check must say so"
  pass "fm-silence-sentry: an unwatched home is not reported until the deadline elapses"
}

# A report that is still waiting to be read is not a wake waiting on a turn.
# The queue can hold one alone: a turn acknowledges through the cutoff its own
# drain computed, and the report published after that presentation is above it,
# so it survives the acknowledgement. Arming over it would produce a second
# SILENT HOME naming the first report as the thing nobody handled.
test_never_arms_over_its_own_standing_report() {
  local dir out
  dir=$(make_home self-report)
  queue_one_unhandled_wake "$dir"
  : > "$ALARM_LOG"

  # The turn begins, and then runs past the deadline without finishing.
  drain_wake "$dir"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -n "$(sentry_pid "$dir")" ] || fail "arm recorded no sentry"
  wait_for_sentry_exit "$dir" || fail "the sentry never finished"
  [ -e "$dir/state/.silence-alarm" ] || fail "no durable silence record was written"

  # The turn ends and acknowledges what it was presented, leaving the report.
  acknowledge_wake "$dir"

  out=$(FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --check) && \
    fail "a home whose only queued row is its own standing report was called silent: $out"
  assert_contains "$out" "no unhandled wake" \
    "a standing report is not a wake this home is waiting on"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "the next arm exited nonzero"
  [ -e "$dir/state/.silence-sentry" ] \
    && fail "the sentry armed over its own standing report"
  [ "$(alarm_count_for "$dir")" -eq 1 ] \
    || fail "expected the single report, got $(alarm_count_for "$dir") alarms"
  pass "fm-silence-sentry: never arms over its own standing report"
}

# --- lifecycle --------------------------------------------------------------

test_marker_is_retired_once_the_home_cycles_again() {
  local dir
  dir=$(make_home recovered)
  queue_one_unhandled_wake "$dir"
  printf 'stale record\n' > "$dir/state/.silence-alarm"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -e "$dir/state/.silence-alarm" ] \
    && fail "a completed watcher cycle left the previous silence record standing"
  pass "fm-silence-sentry: a new watcher cycle retires the previous silence record"
}

test_arm_is_a_singleton_per_home() {
  local dir first second
  dir=$(make_home singleton)
  queue_one_unhandled_wake "$dir"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "first arm failed"
  first=$(sentry_pid "$dir")
  [ -n "$first" ] || fail "the first arm recorded no sentry"
  FM_SILENCE_ALARM_SECS=3600 FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "second arm failed"
  second=$(sentry_pid "$dir")
  [ "$first" = "$second" ] || fail "a second sentry was started ($first then $second)"
  pass "fm-silence-sentry: one sentry per home, never a second"
}

# A standing report is the captain's, not the sentry's, to retire: supervision
# coming back is exactly when he would look, so the next watcher cycle must not
# erase it. Only a turn consuming it from the queue does.
test_report_stands_until_a_turn_consumes_it() {
  local dir
  dir=$(make_home standing-report)
  queue_one_unhandled_wake "$dir"
  : > "$ALARM_LOG"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "arm exited nonzero"
  [ -n "$(sentry_pid "$dir")" ] || fail "arm recorded no sentry"
  wait_for_sentry_exit "$dir" || fail "the sentry never finished"
  [ -e "$dir/state/.silence-alarm" ] || fail "no durable silence record was written"

  # Supervision returns: a watcher cycles and arms again over what is queued.
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "the next arm exited nonzero"
  [ -e "$dir/state/.silence-alarm" ] \
    || fail "the watcher cycle after the report erased it before anyone read it"
  retire_pid "$(sentry_pid "$dir")"
  rm -f "$dir/state/.silence-sentry"

  drain_wake "$dir"
  acknowledge_wake "$dir"
  FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --arm || fail "the final arm exited nonzero"
  [ -e "$dir/state/.silence-alarm" ] \
    && fail "a report a turn already consumed was left standing"
  pass "fm-silence-sentry: a report stands until a turn consumes it, then retires"
}

# The deadline the home will actually apply, read off the only mode that
# evaluates it. --check exits 1 on this idle fixture, which is the verdict, not
# a failure to answer.
checked_deadline() { # <home> [env assignments...]
  local dir=$1
  shift
  env "$@" FM_HOME="$dir" "$dir/bin/fm-silence-sentry.sh" --check 2>/dev/null || true
}

# The deadline is floored at the watcher grace, so the sentry can never be more
# eager than the staleness bound the rest of the stack already applies.
test_deadline_is_floored_at_the_watcher_grace() {
  local dir out
  dir=$(make_home floored)
  out=$(checked_deadline "$dir" FM_SILENCE_ALARM_SECS=1)
  assert_contains "$out" "deadline-seconds=$FM_GUARD_GRACE" \
    "a deadline below the grace must be raised to the grace, not honoured"
  out=$(checked_deadline "$dir" FM_SILENCE_ALARM_SECS=4242)
  assert_contains "$out" "deadline-seconds=4242" \
    "a deadline above the grace must be honoured as configured"
  pass "fm-silence-sentry: the report deadline is floored at the watcher grace"
}

# One machine runs several homes, so the threshold cannot live in the ambient
# environment alone: a home whose turns are shorter has to be able to lower it
# on its own, and one that sets nothing gets the 45-minute default.
test_deadline_is_settable_per_home() {
  local dir out
  dir=$(make_home tuned)
  out=$(checked_deadline "$dir" FM_SILENCE_ALARM_SECS=)
  assert_contains "$out" "deadline-seconds=2700" \
    "a home that configures nothing must get the 45-minute default"

  printf '900\n' > "$dir/config/silence-deadline"
  out=$(checked_deadline "$dir" FM_SILENCE_ALARM_SECS=)
  assert_contains "$out" "deadline-seconds=900" \
    "this home's own config/silence-deadline must be what it applies"

  printf 'whenever\n' > "$dir/config/silence-deadline"
  out=$(checked_deadline "$dir" FM_SILENCE_ALARM_SECS=)
  assert_contains "$out" "deadline-seconds=2700" \
    "an unreadable threshold must fall back to the default, never to no deadline"

  printf '900\n' > "$dir/config/silence-deadline"
  out=$(checked_deadline "$dir" FM_SILENCE_ALARM_SECS=1200)
  assert_contains "$out" "deadline-seconds=1200" \
    "an explicit environment override must win over the file"
  pass "fm-silence-sentry: the report deadline is settable per home"
}

# --- termination: a sentry must never outlive its subject --------------------

# A sentry is armed on EVERY watcher close, so one that survives what it watches
# is not a stray process but one stray process per close, accumulating for as
# long as the home runs and each holding a stale generation.
test_exits_when_its_home_is_deleted() {
  local dir pid i=0
  dir=$(make_home vanishing)
  queue_one_unhandled_wake "$dir"
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
  queue_one_unhandled_wake "$dir"
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
test_reports_a_wake_a_turn_claimed_but_never_finished
test_silent_once_the_handling_turn_acknowledges_the_wake
test_never_arms_on_an_idle_home
test_never_arms_under_away_mode
test_silent_while_a_watcher_is_live
test_no_report_before_the_deadline_elapses
test_never_arms_over_its_own_standing_report
test_marker_is_retired_once_the_home_cycles_again
test_arm_is_a_singleton_per_home
test_report_stands_until_a_turn_consumes_it
test_deadline_is_floored_at_the_watcher_grace
test_deadline_is_settable_per_home
test_exits_when_its_home_is_deleted
test_exits_when_superseded_by_a_newer_sentry
