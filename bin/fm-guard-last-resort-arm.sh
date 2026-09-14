#!/usr/bin/env bash
# Last-resort watcher arm for the synchronous Claude turn-end guard.
#
# Under a Claude primary the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh)
# owns arming, and bin/fm-turnend-guard.sh --claude cooperates with it. This
# script is NOT a second arming owner: the guard runs it only after it has
# already concluded that nothing owns recovery for this Stop event - no live
# identity-matched watcher, no open auto-arm generation claim, no legacy
# lock-holding claim, and no fresh terminal outcome. In that state the guard's
# only remaining lever was exit 2, a forced continuation that asks the MODEL to
# repair supervision; when the harness's own consecutive-block override finally
# allows the stop, or when the auto-arm stands down silently on every firing,
# the home ends the turn with nothing watching and no later Stop event to try
# again (docs/watcher-continuity.md "Last-resort arm at the Stop boundary").
#
# Why this is safe to do at the Stop boundary and nowhere else: between turns
# under the auto-arm model a home is LEGITIMATELY unwatched while the model
# runs, so an aging beacon mid-turn is healthy and must never be armed over.
# At a Stop a turn is by definition ending, so "supervision is needed and no
# watcher exists" is unambiguous. This script therefore only ever runs from a
# turn-end hook.
#
# It launches this home's own bin/fm-watch.sh, verifies it with the same
# honesty gate the arm layer uses (fm_watcher_healthy: a live, identity-matched
# watcher process holding THIS home's lock with a fresh beacon), and reports:
#   guard-arm: started pid=<N>   - it launched one and confirmed it
#   guard-arm: present pid=<N>   - a healthy watcher already held this home
#   guard-arm: FAILED - <reason> - it could not establish one
# Exit 0 means a confirmed live watcher holds this home now; exit 1 means not.
#
# The watcher is launched nohup, with stdio detached, in its OWN process group
# (the same three-way detach bin/fm-startup-network.sh documents), so the
# harness tearing down the synchronous hook's process group cannot take the
# replacement watcher with it. Its wake reason is not lost by detaching stdout:
# bin/fm-watch.sh appends every wake to the durable state/.wake-queue before it
# exits, and the next Stop-owned cycle presents it.
#
# Home scoping is absolute. Every path is derived from this home's FM_HOME /
# FM_STATE_OVERRIDE, and the only process this script ever signals is the child
# it forked itself. It never scans for, matches, or kills a watcher by name, so
# it can never reach a sibling firstmate home's watcher.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=300 ;; esac

# The confirmation budget is the arm layer's own, from the same OSTYPE switch
# bin/fm-watch-arm.sh uses: Git Bash/MSYS pays a much higher fork cost while the
# watcher completes its pre-lock migration. A tighter hand-set window gives up
# on a watcher the arm layer would have confirmed.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) CONFIRM_DEFAULT=30 ;;
  *) CONFIRM_DEFAULT=10 ;;
esac
CONFIRM=${FM_CLAUDE_GUARD_ARM_CONFIRM:-$CONFIRM_DEFAULT}
case "$CONFIRM" in ''|*[!0-9]*|0) CONFIRM=$CONFIRM_DEFAULT ;; esac

[ -x "$WATCH" ] || { echo "guard-arm: FAILED - no watcher script at $WATCH"; exit 1; }
[ -d "$STATE" ] || { echo "guard-arm: FAILED - no state directory"; exit 1; }

# Away mode transfers supervision ownership to the away-mode daemon, which runs
# the watcher one-shot itself. Never arm underneath it.
[ -e "$STATE/.afk" ] && { echo "guard-arm: FAILED - away mode owns supervision"; exit 1; }

# Defensive: the guard already established the need, but an arm that runs with
# nothing to supervise would start a watcher that immediately exits.
fm_supervision_needed "$STATE" "$GRACE" \
  || { echo "guard-arm: FAILED - no supervision need"; exit 1; }

if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  echo "guard-arm: present pid=$FM_WATCHER_HEALTHY_PID"
  exit 0
fi

monitor_was_on=0
case $- in *m*) monitor_was_on=1 ;; esac
set -m 2>/dev/null || true
nohup "$WATCH" >/dev/null 2>&1 </dev/null &
child=$!
[ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

# date(1) exposes whole seconds, so add one rounding second: a confirmation
# budget must not collapse when the launch lands just before a second boundary.
deadline=$(( $(date +%s) + CONFIRM + 1 ))
while :; do
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    # Either our child took the singleton, or another watcher legitimately won
    # the race and ours stood down. Both mean this home is watched again.
    echo "guard-arm: started pid=$FM_WATCHER_HEALTHY_PID"
    exit 0
  fi
  if ! fm_pid_alive "$child"; then
    break
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

# Unconfirmed: retire the child this script forked, exactly as the arm layer
# retires its own unconfirmed child, so no unverified process is left behind.
# Only this pid is ever signalled, and it is this process's own fork.
if fm_pid_alive "$child"; then
  kill -TERM "$child" 2>/dev/null || true
fi
echo "guard-arm: FAILED - no live watcher with a fresh beacon"
exit 1
