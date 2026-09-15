#!/usr/bin/env bash
# Silence sentry - this home notices when IT stopped watching and nothing came back.
#
# THE GAP THIS CLOSES
#
# Every recovery path a Claude primary has is triggered by a Stop event, and the
# only unattended source of a Stop event is the rewake an arming path produces
# (docs/watcher-continuity.md "Last-resort arm at the Stop boundary"). When a
# session runs out of quota mid-turn the turn never completes, so no Stop event
# is ever emitted: the auto-arm ledger does not advance, the turn-end guard's own
# block record is never created, and bin/fm-guard-last-resort-arm.sh never runs,
# because all three act AT a Stop boundary and this shape has none. Observed
# 2026-09-14: a watcher closed cleanly at 10:30:21 (exit 0, reason
# actionable-stale), the woken session hit its session limit, and the home stayed
# unwatched for 71 minutes while one worker's validation failed unobserved and a
# second sat stopped mid-gate. Nothing inside the home noticed; the supervision
# layer one level up did, from outside.
#
# This sentry is therefore deliberately NOT a turn-end mechanism. It is its own
# detached process, armed by the watcher's own close, and it needs neither a turn
# to end nor the model to be alive.
#
# IT ONLY REPORTS. It never starts a watcher, relaunches an agent, re-arms
# supervision, retries a request, or resumes work. A home whose quota is still
# exhausted must not resurrect itself into a loop nobody asked for, and a
# mechanism that quietly restarts things is exactly what nobody can supervise.
# bin/fm-guard-last-resort-arm.sh remains the only backstop that arms anything,
# and it stays bound to the Stop boundary where "no watcher" is unambiguous.
#
# WHAT IT KEYS ON, AND WHY NOT THE OBVIOUS SIGNALS
#
# A home is legitimately quiet in several ways, and a detector that cannot tell
# them from the fault is worse than nothing - the first thing anyone does with a
# noisy alarm is ignore it. Two tempting signals were measured and rejected:
#
#   Elapsed unwatched time alone. Under the autoarm supervision model the
#   watcher runs only BETWEEN turns, so "no watcher" is the healthy mid-turn
#   state and says nothing on its own.
#
#   Harness CPU time. Measured 2026-09-14 across the twelve Claude Code
#   processes then live on one machine, sampled once a minute for four minutes:
#   every real TUI burned between 0.74% and 4.79% of a core CONTINUOUSLY,
#   whether it was running a turn or parked at a prompt. No threshold separates
#   working from idle, so cumulative CPU cannot carry this verdict.
#
# What does separate them is the durable wake record, and specifically its END,
# not its beginning. The watcher appends every actionable wake to
# state/.wake-queue before it exits, and the row stays queued until the handling
# turn acknowledges it AFTER handling it (AGENTS.md section 8). The claim the
# drain writes at the START of handling is deliberately NOT the signal: it is
# written before the turn does any work, so retiring on it would leave the whole
# remainder of the turn unwatched - which is exactly where quota is consumed,
# and exactly the shape of the incident above. A row that is gone from the queue
# means a turn finished handling it; a row that outlives the deadline means none
# ever did.
#
# The sentry reports only when ALL of these hold for the whole deadline:
#   1. supervision is still needed here (bin/fm-supervision-lib.sh owns that),
#   2. no live, identity-matched watcher holds this home's lock with a fresh
#      beacon (fm_watcher_healthy),
#   3. the wake it was armed over is still queued, i.e. unacknowledged,
#   4. away mode is inactive, because the away daemon owns supervision then.
#
# Each healthy shape trips a different one of those and stays silent:
#   idle home, no work at all          -> (1) is false; also nothing arms it.
#   watcher parked on a long wait      -> (2) is false; the watcher is beating.
#   a turn that handles the wake       -> (3) goes false at its acknowledgement;
#                                         and when that turn ends, the Stop-owned
#                                         auto-arm brings a watcher back, so (2)
#                                         goes false too and the sentry retires.
#
# The deadline is generous on purpose. Any turn that ENDS re-arms the watcher and
# retires this sentry through condition 2, so the only shape the deadline has to
# outlast is a single turn that runs past it without ever finishing the wake it
# was handed. A turn that does run past it IS reported, and that residual is
# named and costed in docs/watcher-continuity.md rather than left here. The
# default and where its number comes from sit with the value below; every home
# can lower it, and it is floored at the watcher grace so it can never be more
# eager than the staleness bound the rest of the stack already applies.
#
# HOME SCOPING IS ABSOLUTE. Every path derives from this home's FM_HOME /
# FM_STATE_OVERRIDE. This script signals no process at all - not even its own
# child - and never scans for, matches, or touches a watcher by name, so it
# cannot reach a sibling firstmate home sharing this machine.
#
# Usage:
#   bin/fm-silence-sentry.sh --arm     arm a detached sentry and return at once
#                                      (called from bin/fm-watch.sh's close)
#   bin/fm-silence-sentry.sh --watch   the polling loop itself; --arm forks this
#   bin/fm-silence-sentry.sh --check   print this home's deadline, then evaluate
#                                      the four conditions once and exit 0 when
#                                      the home is in silence, 1 when not
#
# Environment:
#   FM_SILENCE_ALARM_SECS  deadline before reporting, overriding this home's
#                          config/silence-deadline; floored at the guard grace
#   FM_SILENCE_POLL_SECS   how often the loop re-evaluates (default 30)
#   FM_WEDGE_ALARM_EXEC    bin/fm-supervise-daemon.sh's own notifier seam, which
#                          this reporter inherits with its channels; a test sets
#                          it to a recorder so no suite posts a real notification
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WATCH="$SCRIPT_DIR/fm-watch.sh"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

SENTRY_RECORD="$STATE/.silence-sentry"
ALARM_MARKER="$STATE/.silence-alarm"
QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
# The key this reporter's own queued wake carries, so a standing report can be
# told from the wakes it reports about.
REPORT_WAKE_KEY=silence-sentry
ALARM_TITLE='firstmate: home stopped watching'

GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=300 ;; esac

# 45 minutes, and the number is a judgement rather than a measurement, so its
# provenance stands with it. Below it the detector lies about long turns: on
# 2026-09-15 this home ran stretches of roughly nineteen minutes with nothing
# beating while work was genuinely in progress, and an alarm that cried wolf
# every four minutes for an hour that night is exactly how a domain learns to
# ignore a task's alarms. Above it detection costs real time: at 45 minutes the
# 2026-09-14 failure would have reported at 11:15, against the 11:42 a human
# actually noticed it. A home whose turns are shorter is entitled to go lower
# through config/silence-deadline, which is why this is a per-home number and
# not a constant.
DEADLINE_DEFAULT=2700
DEADLINE_SECS=${FM_SILENCE_ALARM_SECS:-}
[ -n "$DEADLINE_SECS" ] \
  || DEADLINE_SECS=$(head -n 1 "$CONFIG/silence-deadline" 2>/dev/null || true)
case "$DEADLINE_SECS" in ''|*[!0-9]*|0) DEADLINE_SECS=$DEADLINE_DEFAULT ;; esac
# Never more eager than the staleness bound the rest of the stack already uses.
[ "$DEADLINE_SECS" -ge "$GRACE" ] || DEADLINE_SECS=$GRACE

POLL_SECS=${FM_SILENCE_POLL_SECS:-30}
case "$POLL_SECS" in ''|*[!0-9]*|0) POLL_SECS=30 ;; esac

# The lowest queued sequence, i.e. the oldest wake no turn has finished handling,
# or nothing when the queue holds none. A row missing its five fields or its
# numeric sequence can never be presented or acknowledged by contract and is
# ignored here too, because main retires those rather than handling them. This
# sentry's own standing report is skipped as well: it is a report waiting to be
# read, not a wake waiting on a turn, and a home that already holds an unread
# one needs no second report naming the first as the thing nobody handled.
oldest_queued_row() {
  [ -s "$QUEUE" ] || return 1
  awk -F '\t' -v report="$REPORT_WAKE_KEY" '
    NF >= 5 && $2 ~ /^[0-9]+$/ && !($3 == "check" && $4 == report) {
      if (best == "" || $2 + 0 < best + 0) { best = $2; stamp = $1; kind = $3; key = $4 }
    }
    END { if (best != "") printf "%s\t%s\t%s\t%s\n", best, stamp, kind, key }
  ' "$QUEUE"
}

# True while sequence $1 is still queued, i.e. no turn has acknowledged it.
row_still_queued() { # <seq>
  local seq=$1
  awk -F '\t' -v want="$seq" '
    NF >= 5 && $2 == want { queued = 1 }
    END { exit(queued ? 0 : 1) }
  ' "$QUEUE" 2>/dev/null
}

# True while a report this sentry published is still queued for the captain.
report_still_queued() {
  awk -F '\t' -v want="$REPORT_WAKE_KEY" '
    NF >= 5 && $3 == "check" && $4 == want { queued = 1 }
    END { exit(queued ? 0 : 1) }
  ' "$QUEUE" 2>/dev/null
}

# A silence report stands until a turn has actually consumed it from the wake
# queue. Retiring it on the next watcher close would erase it at exactly the
# moment supervision comes back, which is when the captain would look.
retire_presented_alarm() {
  report_still_queued && return 0
  rm -f "$ALARM_MARKER" 2>/dev/null || true
}

# Evaluate the four conditions once. Prints the reason this home is NOT in
# silence on stdout when it is healthy. Exit 0 = in silence, 1 = healthy.
evaluate_silence() { # <target-seq>
  local seq=$1
  if [ -e "$STATE/.afk" ]; then
    echo "away mode owns supervision"
    return 1
  fi
  if ! fm_supervision_needed "$STATE" "$GRACE"; then
    echo "no supervision need"
    return 1
  fi
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    echo "watcher live pid=$FM_WATCHER_HEALTHY_PID"
    return 1
  fi
  if ! row_still_queued "$seq"; then
    echo "wake $seq handled or retired"
    return 1
  fi
  return 0
}

# Fire the home's configured alarm channels. config/wedge-alarm is this
# repository's only channel that reaches a person outside the terminal pane
# without the model's participation, and bin/fm-supervise-daemon.sh owns its
# directive parsing, platform default, bounded dispatch, and argv safety. This
# execs that owner's one-shot entry rather than restating the contract; a
# sourced daemon is structurally pinned to "discard", so exec is the only way a
# real notification can fire. Best effort: a channel failure must never stop the
# durable marker from standing.
raise_alarm() { # <summary>
  local summary=$1
  [ -x "$DAEMON" ] || return 0
  # Pass this home's config override through, or a home that relocates its
  # config would silently fall back to the platform default channel instead of
  # the captain's configured one. Assigned unconditionally: a conditional
  # prefix expands to an unquoted word, so a config path containing a space
  # would be split and disable the alarm entirely. The daemon resolves an empty
  # value back to its own default.
  FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" \
    "$DAEMON" --alarm "$summary" "$ALARM_MARKER" "$ALARM_TITLE" >/dev/null 2>&1 || true
}

report_silence() { # <target-seq> <queued-epoch> <kind> <key> <silent-secs>
  local seq=$1 stamp=$2 kind=$3 key=$4 silent=$5 summary mins
  mins=$(( silent / 60 ))
  summary="firstmate home $FM_HOME has not been watched for ${mins}m: it delivered a ${kind} wake about ${key} and no turn ever finished handling it. Quota exhaustion or a dead session will look exactly like this. Nothing was restarted - check the session."
  {
    printf 'silence detected at %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'home=%s\n' "$FM_HOME"
    printf 'unwatched-seconds=%s\n' "$silent"
    printf 'wake-sequence=%s\n' "$seq"
    printf 'wake-queued-epoch=%s\n' "$stamp"
    printf 'wake-kind=%s\n' "$kind"
    printf 'wake-key=%s\n' "$key"
    printf 'note=%s\n' "no watcher, supervision still needed, and this wake was never acknowledged by any turn"
    printf 'note=%s\n' "nothing was restarted: this sentry only reports"
  } > "$ALARM_MARKER" 2>/dev/null || true
  # Give the durable half a reader. The wake queue is this home's existing
  # captain-facing channel: it is presented at session start and at every drain,
  # and a row stays queued until a turn acknowledges it after handling. A queued
  # row starts nothing on its own, so the report-only boundary holds.
  fm_wake_append check "$REPORT_WAKE_KEY" "$summary" >/dev/null 2>&1 || true
  raise_alarm "$summary"
  printf 'silence-sentry: SILENT HOME - %s\n' "$summary"
}

arm() {
  local row seq stamp kind key pid identity recorded

  [ -d "$STATE" ] || return 0
  [ -x "$WATCH" ] || return 0
  # A watcher just completed a cycle in this home, so whatever silence a previous
  # sentry reported is over. Retire that marker here as well as on the loop's own
  # healthy exit, because a sentry that already alarmed has exited and cannot
  # retire it itself - but only once its queued report has actually reached a
  # turn, or the first cycle after supervision returns would erase the record
  # before anyone read it.
  retire_presented_alarm
  # Away mode transfers supervision ownership to the away daemon; never watch
  # underneath it.
  [ -e "$STATE/.afk" ] && return 0
  fm_supervision_needed "$STATE" "$GRACE" || return 0
  # A home that is watched right now needs no sentry. The watcher's own close
  # normally satisfies this by construction; checking anyway keeps a defensive
  # or racing caller from starting a process whose only job would be to retire
  # itself on its first poll.
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0

  # An empty queue means no wake is waiting on a turn, so there is nothing this
  # sentry could ever report. An idle home never arms one.
  row=$(oldest_queued_row) || return 0
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r seq stamp kind key <<< "$row"
  case "$seq" in ''|*[!0-9]*) return 0 ;; esac

  # Singleton: one sentry per home. A recorded sentry whose process is gone, or
  # whose pid has been recycled onto an unrelated process, is not one.
  if [ -r "$SENTRY_RECORD" ]; then
    recorded=$(awk -F '\t' 'NR == 1 { print $1 }' "$SENTRY_RECORD" 2>/dev/null || true)
    if fm_pid_alive "$recorded"; then
      identity=$(awk -F '\t' 'NR == 1 { print $2 }' "$SENTRY_RECORD" 2>/dev/null || true)
      if [ "$identity" = "$(fm_pid_identity "$recorded" 2>/dev/null || true)" ]; then
        return 0
      fi
    fi
  fi

  local monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    nohup "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" --watch "$seq" "$stamp" "$kind" "$key" \
    >/dev/null 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  # The child is the sole writer of its own record, because only it can read its
  # identity without racing its own visibility in the process table: a parent
  # that loses that race would publish an empty identity, and the next arm would
  # read the record as unverifiable and start a SECOND sentry, which is a
  # duplicate report. Wait, bounded, for the child to publish, so the singleton
  # window closes before this returns to the watcher's exit path.
  local waited=0
  while [ "$waited" -lt 40 ]; do
    recorded=$(awk -F '\t' 'NR == 1 { print $1 }' "$SENTRY_RECORD" 2>/dev/null || true)
    [ "$recorded" = "$pid" ] && return 0
    fm_pid_alive "$pid" || return 0
    sleep 0.05
    waited=$((waited + 1))
  done
  return 0
}

watch_loop() { # <seq> <queued-epoch> <kind> <key>
  local seq=$1 stamp=$2 kind=$3 key=$4 armed now reason me identity silent
  fm_current_pid me || return 1
  identity=$(fm_pid_identity "$me" 2>/dev/null || true)
  printf '%s\t%s\t%s\t%s\n' "$me" "$identity" "$seq" "$(date +%s)" > "$SENTRY_RECORD" 2>/dev/null || true
  armed=$(date +%s)

  while :; do
    # Terminate when this sentry's SUBJECT is gone, before evaluating anything
    # about it. A sentry is armed on every watcher close, so one that outlives
    # what it watches is not a stray process but one stray process per close,
    # accumulating for as long as the home runs. Two ways the subject can go:
    #
    #   the home itself is deleted underneath it - nothing left to report on,
    #   and every path below would be reading a directory that no longer exists;
    #
    #   a newer sentry superseded this one - the record names another process,
    #   or no process at all, so this generation is no longer the home's sentry
    #   and must not report or retire records the current one owns.
    #
    # Neither is left to fall out of the conditions below by accident: an exit
    # that happens incidentally is one a later change can silently remove.
    if [ ! -d "$STATE" ]; then
      return 0
    fi
    if [ "$(awk -F '\t' 'NR == 1 { print $1 }' "$SENTRY_RECORD" 2>/dev/null || true)" != "$me" ]; then
      return 0
    fi
    if reason=$(evaluate_silence "$seq"); then
      now=$(date +%s)
      silent=$(( now - armed ))
      if [ "$silent" -ge "$DEADLINE_SECS" ]; then
        report_silence "$seq" "$stamp" "$kind" "$key" "$silent"
        rm -f "$SENTRY_RECORD" 2>/dev/null || true
        return 0
      fi
    else
      # The home is healthy again. Retire a previous report once a turn has
      # consumed it, so a standing marker always means "a silence report is
      # still waiting for the captain", never "it was once silent".
      retire_presented_alarm
      rm -f "$SENTRY_RECORD" 2>/dev/null || true
      return 0
    fi
    sleep "$POLL_SECS"
  done
}

case "${1:---help}" in
  --arm) arm ;;
  --watch)
    shift
    [ "$#" -ge 4 ] || { echo "silence-sentry: --watch needs <seq> <epoch> <kind> <key>" >&2; exit 2; }
    watch_loop "$1" "$2" "$3" "$4"
    ;;
  --check)
    printf 'deadline-seconds=%s\n' "$DEADLINE_SECS"
    row=$(oldest_queued_row) || row=''
    if [ -z "$row" ]; then
      echo "no unhandled wake"
      exit 1
    fi
    seq=$(printf '%s' "$row" | cut -f1)
    if reason=$(evaluate_silence "$seq"); then
      echo "in silence: wake $seq unhandled and no watcher"
      exit 0
    fi
    echo "$reason"
    exit 1
    ;;
  -h|--help) sed -n '/^# Usage:/,/^[^#]/p' "${BASH_SOURCE[0]}" | sed -n '/^#/p' | sed 's/^# \{0,1\}//' ;;
  *) echo "silence-sentry: unknown argument: $1" >&2; exit 2 ;;
esac
