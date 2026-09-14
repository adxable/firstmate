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
# What does separate them is the durable wake record. The watcher appends every
# actionable wake to state/.wake-queue before it exits, and the handling turn
# claims that row into its actor's claim file at the START of handling, before
# it reads anything or starts work (AGENTS.md section 8). So a claimed row means
# a handling turn began; an unclaimed row that outlives the deadline means one
# never did. The length of the turn AFTER the drain is irrelevant, which is what
# keeps an arbitrarily long healthy turn silent.
#
# The sentry reports only when ALL of these hold for the whole deadline:
#   1. supervision is still needed here (bin/fm-supervision-lib.sh owns that),
#   2. no live, identity-matched watcher holds this home's lock with a fresh
#      beacon (fm_watcher_healthy),
#   3. the wake it was armed over is still queued AND claimed by no actor,
#   4. away mode is inactive, because the away daemon owns supervision then.
#
# Each healthy shape trips a different one of those and stays silent:
#   idle home, no work at all          -> (1) is false; also nothing arms it.
#   watcher parked on a long wait      -> (2) is false; the watcher is beating.
#   a turn genuinely running           -> (3) goes false at the handling drain;
#                                         and when that turn ends, the Stop-owned
#                                         auto-arm brings a watcher back, so (2)
#                                         goes false too and the sentry retires.
#
# The deadline is generous on purpose. Any turn that ENDS re-arms the watcher and
# retires this sentry through condition 2, so the only shape the deadline has to
# outlast is a single turn that runs past it without ever draining. The default
# is 30 minutes, floored at the watcher grace so it can never be more eager than
# the staleness bound the rest of the stack already applies.
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
#   bin/fm-silence-sentry.sh --status  print this home's current sentry state
#   bin/fm-silence-sentry.sh --check   evaluate the four conditions once and exit
#                                      0 when the home is in silence, 1 when not
#
# Environment:
#   FM_SILENCE_ALARM_SECS  deadline before reporting (default 1800, floored at
#                          the guard grace)
#   FM_SILENCE_POLL_SECS   how often the loop re-evaluates (default 30)
#   FM_SILENCE_ALARM_EXEC  replaces the alarm dispatch with this command; the
#                          test seam, so no suite can post a real notification
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCH="$SCRIPT_DIR/fm-watch.sh"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

SENTRY_RECORD="$STATE/.silence-sentry"
ALARM_MARKER="$STATE/.silence-alarm"
QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
MAIN_ROWS="$STATE/.main-eligible-rows"
BRANCH_ROWS="$STATE/.branch-eligible-rows"

GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=300 ;; esac

DEADLINE_SECS=${FM_SILENCE_ALARM_SECS:-1800}
case "$DEADLINE_SECS" in ''|*[!0-9]*|0) DEADLINE_SECS=1800 ;; esac
# Never more eager than the staleness bound the rest of the stack already uses.
[ "$DEADLINE_SECS" -ge "$GRACE" ] || DEADLINE_SECS=$GRACE

POLL_SECS=${FM_SILENCE_POLL_SECS:-30}
case "$POLL_SECS" in ''|*[!0-9]*|0) POLL_SECS=30 ;; esac

# The lowest queued sequence that no actor has claimed, i.e. the oldest wake
# nobody has picked up, or nothing when every queued row is claimed. Claim files
# hold one sequence per line; a row missing its five fields or its numeric
# sequence is unclaimable by contract and is ignored here too, because main
# retires those rather than handling them.
oldest_unclaimed_row() {
  [ -s "$QUEUE" ] || return 1
  awk -F '\t' -v main="$MAIN_ROWS" -v branch="$BRANCH_ROWS" '
    BEGIN {
      while ((getline line < main) > 0) if (line ~ /^[0-9]+$/) claimed[line] = 1
      while ((getline line < branch) > 0) if (line ~ /^[0-9]+$/) claimed[line] = 1
    }
    NF >= 5 && $2 ~ /^[0-9]+$/ && !($2 in claimed) {
      if (best == "" || $2 + 0 < best + 0) { best = $2; stamp = $1; kind = $3; key = $4 }
    }
    END { if (best != "") printf "%s\t%s\t%s\t%s\n", best, stamp, kind, key }
  ' "$QUEUE"
}

# True while sequence $1 is still queued and still claimed by no actor.
row_still_unclaimed() { # <seq>
  local seq=$1 found
  found=$(oldest_unclaimed_row) || return 1
  [ -n "$found" ] || return 1
  # A BEGIN "exit 1" would still run END, whose own exit() would override the
  # status, so the claim is carried as a flag and decided once in END.
  awk -F '\t' -v want="$seq" -v main="$MAIN_ROWS" -v branch="$BRANCH_ROWS" '
    BEGIN {
      while ((getline line < main) > 0) if (line == want) claimed = 1
      while ((getline line < branch) > 0) if (line == want) claimed = 1
    }
    NF >= 5 && $2 == want { queued = 1 }
    END { exit((queued && !claimed) ? 0 : 1) }
  ' "$QUEUE"
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
  if ! row_still_unclaimed "$seq"; then
    echo "wake $seq picked up or retired"
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
  local summary=$1 override=${FM_SILENCE_ALARM_EXEC:-}
  case "$override" in
    '') ;;
    discard) return 0 ;;
    *) "$override" silence "$summary" >/dev/null 2>&1 || true; return 0 ;;
  esac
  [ -x "$DAEMON" ] || return 0
  # Pass this home's config override through, or a home that relocates its
  # config would silently fall back to the platform default channel instead of
  # the captain's configured one.
  FM_HOME="$FM_HOME" ${FM_CONFIG_OVERRIDE:+FM_CONFIG_OVERRIDE="$FM_CONFIG_OVERRIDE"} \
    "$DAEMON" --alarm "$summary" "$ALARM_MARKER" >/dev/null 2>&1 || true
}

report_silence() { # <target-seq> <queued-epoch> <kind> <key> <silent-secs>
  local seq=$1 stamp=$2 kind=$3 key=$4 silent=$5 summary mins
  mins=$(( silent / 60 ))
  summary="firstmate home $FM_HOME has not been watched for ${mins}m: it delivered a ${kind} wake about ${key} and no turn ever picked it up. Quota exhaustion or a dead session will look exactly like this. Nothing was restarted - check the session."
  {
    printf 'silence detected at %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'home=%s\n' "$FM_HOME"
    printf 'unwatched-seconds=%s\n' "$silent"
    printf 'wake-sequence=%s\n' "$seq"
    printf 'wake-queued-epoch=%s\n' "$stamp"
    printf 'wake-kind=%s\n' "$kind"
    printf 'wake-key=%s\n' "$key"
    printf 'note=%s\n' "no watcher, supervision still needed, and this wake was never claimed by any actor"
    printf 'note=%s\n' "nothing was restarted: this sentry only reports"
  } > "$ALARM_MARKER" 2>/dev/null || true
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
  # retire it itself. The marker must always mean "this home is silent now".
  rm -f "$ALARM_MARKER" 2>/dev/null || true
  # Away mode transfers supervision ownership to the away daemon; never watch
  # underneath it.
  [ -e "$STATE/.afk" ] && return 0
  fm_supervision_needed "$STATE" "$GRACE" || return 0
  # A home that is watched right now needs no sentry. The watcher's own close
  # normally satisfies this by construction; checking anyway keeps a defensive
  # or racing caller from starting a process whose only job would be to retire
  # itself on its first poll.
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0

  # Nothing unclaimed means no wake is waiting on a turn, so there is nothing
  # this sentry could ever report. An idle home never arms one.
  row=$(oldest_unclaimed_row) || return 0
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
      # The home is healthy again. Retire the marker so it always means "this
      # home is in silence right now", never "it was once".
      rm -f "$ALARM_MARKER" "$SENTRY_RECORD" 2>/dev/null || true
      return 0
    fi
    sleep "$POLL_SECS"
  done
}

print_status() {
  local row seq recorded
  printf 'home=%s\n' "$FM_HOME"
  printf 'deadline-seconds=%s\n' "$DEADLINE_SECS"
  recorded=$(awk -F '\t' 'NR == 1 { print $1 }' "$SENTRY_RECORD" 2>/dev/null || true)
  if fm_pid_alive "$recorded"; then
    printf 'sentry=live pid=%s\n' "$recorded"
  else
    printf 'sentry=none\n'
  fi
  row=$(oldest_unclaimed_row) || row=''
  if [ -n "$row" ]; then
    seq=$(printf '%s' "$row" | cut -f1)
    printf 'oldest-unclaimed-wake=%s\n' "$seq"
  else
    printf 'oldest-unclaimed-wake=none\n'
  fi
  if [ -e "$ALARM_MARKER" ]; then
    printf 'alarm=raised\n'
  else
    printf 'alarm=none\n'
  fi
}

case "${1:---status}" in
  --arm) arm ;;
  --watch)
    shift
    [ "$#" -ge 4 ] || { echo "silence-sentry: --watch needs <seq> <epoch> <kind> <key>" >&2; exit 2; }
    watch_loop "$1" "$2" "$3" "$4"
    ;;
  --check)
    row=$(oldest_unclaimed_row) || row=''
    if [ -z "$row" ]; then
      echo "no unclaimed wake"
      exit 1
    fi
    seq=$(printf '%s' "$row" | cut -f1)
    if reason=$(evaluate_silence "$seq"); then
      echo "in silence: wake $seq unclaimed and no watcher"
      exit 0
    fi
    echo "$reason"
    exit 1
    ;;
  --status) print_status ;;
  -h|--help) sed -n '1,95p' "${BASH_SOURCE[0]}" | sed -n '/^# Usage:/,$p' | sed 's/^# \{0,1\}//' ;;
  *) echo "silence-sentry: unknown argument: $1" >&2; exit 2 ;;
esac
