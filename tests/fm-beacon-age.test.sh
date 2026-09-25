#!/usr/bin/env bash
# tests/fm-beacon-age.test.sh - watcher beacon age measured from the later of
# the beacon's last touch and the last system wake (bin/fm-wake-lib.sh
# fm_beacon_age / fm_last_wake_epoch). A machine that slept keeps its wall clock
# moving while no watcher can run, so a live watcher's beacon must not read as
# stale right after a wake, while a watcher hung past the grace with the machine
# awake still must. The wake source is injected through FM_LAST_WAKE_EPOCH.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
GRACE=300

TMP_ROOT=$(fm_test_tmproot fm-beacon-age-tests)

beacon_age() {  # <state> <beacon> [wake-epoch|unset]
  if [ "${3-unset}" = unset ]; then
    env -u FM_LAST_WAKE_EPOCH FM_STATE_OVERRIDE="$1" \
      bash -c '. "$1"; fm_beacon_age "$2"' _ "$LIB" "$2"
  else
    FM_LAST_WAKE_EPOCH=$3 FM_STATE_OVERRIDE="$1" \
      bash -c '. "$1"; fm_beacon_age "$2"' _ "$LIB" "$2"
  fi
}

test_wake_newer_than_beacon_is_fresh_within_grace_then_stale() {
  local dir state beat now age
  dir=$(make_case wake-grace)
  state="$dir/state"
  beat="$state/.last-watcher-beat"
  now=$(date +%s)
  fm_touch_epoch "$((now - 2000))" "$beat"

  age=$(beacon_age "$state" "$beat" "$((now - 10))")
  [ "$age" -lt "$GRACE" ] || fail "a beacon older than the grace read stale ${age}s after a wake 10s ago"
  [ "$age" -ge 10 ] || fail "age after a wake 10s ago must count from the wake, got ${age}s"

  age=$(beacon_age "$state" "$beat" "$((now - GRACE - 100))")
  [ "$age" -ge "$GRACE" ] || fail "a beacon untouched for longer than the grace after the wake read fresh (${age}s)"
  pass "a wake newer than the beacon reads fresh within the grace and stale once it elapses"
}

test_wake_older_than_beacon_keeps_mtime_age() {
  local dir state beat now age
  dir=$(make_case wake-older)
  state="$dir/state"
  beat="$state/.last-watcher-beat"
  now=$(date +%s)
  fm_touch_epoch "$((now - 500))" "$beat"
  age=$(beacon_age "$state" "$beat" "$((now - 5000))")
  [ "$age" -ge 500 ] || fail "a wake before the last touch must not shorten the age (${age}s)"
  pass "a wake older than the beacon leaves plain mtime age"
}

test_unusable_wake_source_falls_back_to_mtime_age() {
  local dir state beat now age wake
  dir=$(make_case wake-fallback)
  state="$dir/state"
  beat="$state/.last-watcher-beat"
  now=$(date +%s)
  fm_touch_epoch "$((now - 2000))" "$beat"
  for wake in '' 'garbage' '-5' "$((now + 3600))"; do
    age=$(beacon_age "$state" "$beat" "$wake")
    [ "$age" -ge 2000 ] || fail "unusable wake time '$wake' did not fall back to mtime age (${age}s)"
  done
  age=$(beacon_age "$state" "$state/.no-such-beat" "$((now - 1))")
  assert_equals 999999 "$age" "a missing beacon must stay ancient whatever the wake time"
  pass "an empty, unparseable, negative, or future wake time falls back to mtime age, never fresh"
}

test_platform_wake_source() {
  local dir state beat now out status age
  dir=$(make_case wake-platform)
  state="$dir/state"
  beat="$state/.last-watcher-beat"
  now=$(date +%s)
  status=0
  out=$(env -u FM_LAST_WAKE_EPOCH FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1"; fm_last_wake_epoch' _ "$LIB") || status=$?
  if [ "$(uname)" = Darwin ]; then
    expect_code 0 "$status" "kern.waketime read"
    case "$out" in ''|*[!0-9]*) fail "kern.waketime did not parse to epoch seconds: '$out'" ;; esac
    [ "$out" -le "$now" ] || fail "kern.waketime is in the future: $out > $now"
  else
    [ "$status" -ne 0 ] || fail "a platform without a last-wake source must report none, got '$out'"
    fm_touch_epoch "$((now - 2000))" "$beat"
    age=$(beacon_age "$state" "$beat" unset)
    [ "$age" -ge 2000 ] || fail "without a wake source the age must be plain mtime age (${age}s)"
  fi
  pass "the platform wake source is readable where it exists and absent elsewhere"
}

test_supervision_status_uses_wake_age_and_keeps_raw_description() {
  local dir state now out
  dir=$(make_case wake-supervision)
  state="$dir/state"
  now=$(date +%s)
  fm_touch_epoch "$((now - 2000))" "$state/.last-watcher-beat"
  out=$(FM_LAST_WAKE_EPOCH=$((now - 10)) FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_status "$2" 300
    printf "%s|%s\n" "$FM_SUP_WATCHER_FRESH" "$FM_SUP_BEACON_DESC"' _ "$ROOT" "$state")
  case "$out" in
    true\|*s\ ago) : ;;
    *) fail "a beacon touched before a wake 10s ago must read fresh: '$out'" ;;
  esac
  [ "${out#true|}" != "10s ago" ] || fail "the beat description must keep the real time since the last touch: '$out'"
  pass "supervision status judges freshness from the wake and still reports the raw beat age"
}

run_watch_behind_live_holder() {  # <case> <wake-epoch>; prints exit status
  local dir state status
  dir=$(make_case "$1")
  state="$dir/state"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  fm_touch_epoch "$(( $(date +%s) - 2000 ))" "$state/.last-watcher-beat"
  status=0
  PATH="$dir/fakebin:$PATH" FM_LAST_WAKE_EPOCH=$2 FM_STATE_OVERRIDE="$state" \
    FM_WATCHER_STALE_GRACE=$GRACE FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" || status=$?
  printf '%s %s\n' "$status" "$dir"
}

test_watch_behind_live_holder_after_wake() {
  local now res status dir
  now=$(date +%s)
  res=$(run_watch_behind_live_holder watch-after-wake "$((now - 5))")
  status=${res%% *}; dir=${res#* }
  expect_code 0 "$status" "watcher behind a live holder right after a wake"
  assert_grep 'already running' "$dir/watch.out" "a live watcher must not be refused as stale right after a wake"

  res=$(run_watch_behind_live_holder watch-hung-awake "$((now - GRACE - 100))")
  status=${res%% *}; dir=${res#* }
  [ "$status" -ne 0 ] || fail "a holder silent for longer than the grace while awake was accepted"
  assert_grep 'heartbeat is stale' "$dir/watch.err" "a hung-while-awake holder must still be reported stale"
  pass "the watcher defers to a live holder after a wake and still refuses one hung while awake"
}

test_wake_newer_than_beacon_is_fresh_within_grace_then_stale
test_wake_older_than_beacon_keeps_mtime_age
test_unusable_wake_source_falls_back_to_mtime_age
test_platform_wake_source
test_supervision_status_uses_wake_age_and_keeps_raw_description
test_watch_behind_live_holder_after_wake
