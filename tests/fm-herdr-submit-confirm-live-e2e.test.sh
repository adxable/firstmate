#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It fails naming the harness and version rather than degrading
# quietly.
#
# It also drives the away daemon's own escalate_flush with a buffer shaped like
# the 2026-09-24 overnight wedge (one ~9 KB status span plus shorter events):
# every digest must fit one terminal read and land, and a digest whose wrapped
# row starts with `#` must land too. Claude runs with no tools in a scratch
# directory, so a digest-shaped prompt cannot act on anything.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" or "Typed payload size" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$PROJECT"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$PROJECT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --tools '' --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in
    idle|done) idle=1; break ;;
    blocked)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it and keep
      # waiting for a real idle composer. The prompt preselects "No, exit", so
      # move to "Yes" before confirming; a bare Enter quits Claude.
      case "$(lab pane read "$PANE" --source visible 2>/dev/null || true)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt" ;;
      esac
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

wait_idle() {
  local i=0 st
  while [ "$i" -lt 90 ]; do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) return 0 ;; esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

rendered() {  # <token>
  local i=0
  while [ "$i" -lt 45 ]; do
    lab pane read "$PANE" --source recent --lines 400 2>/dev/null | grep -F -q "$1" && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Typed payload size: a payload within one terminal read is shown whole; the
# over-read observation is printed for the verification record, not asserted.
proof_shown() {  # <bytes> -> yes|no
  local want=$1 body='Reply with nothing. ' enc content shown=no
  while :; do
    fm_operational_input_encode away-supervisor "$body" enc
    [ "$(printf '%s' "$enc" | LC_ALL=C wc -c | tr -d ' ')" -ge "$want" ] && break
    body="${body}x"
  done
  wait_idle || fail "Claude Code ($VERSION) on $HERDR_VER never returned to idle before the size probe"
  fm_backend_herdr_send_literal "$TARGET" "$enc" || fail "size probe could not type into Claude Code ($VERSION)"
  sleep 1
  content=$(fm_backend_herdr_composer_content "$TARGET" "$(fm_backend_herdr_proof_lines "$enc")" || true)
  fm_backend_herdr_composer_payload_shown "$enc" "$content" && shown=yes
  fm_backend_herdr_composer_clear "$TARGET" "$enc" \
    || fail "Claude Code ($VERSION) on $HERDR_VER: the size probe composer did not clear"
  printf '%s' "$shown"
}
[ "$(proof_shown 900)" = yes ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a 900-byte payload, the away digest ceiling, did not arrive whole"
pass "live Herdr typed payload: Claude Code ($VERSION) on $HERDR_VER shows a 900-byte payload whole"
printf 'measure: Claude Code (%s) on %s over one terminal read: 1100-byte payload shown whole=%s\n' \
  "$VERSION" "$HERDR_VER" "$(proof_shown 1100)"

# The away daemon's own flush path, with the overnight buffer shape.
DAEMON_STATE="$TMP_ROOT/state"
mkdir -p "$DAEMON_STATE" "$TMP_ROOT/home"
printf 'away\n' > "$DAEMON_STATE/.afk"
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$DAEMON_STATE" FM_SUPERVISOR_TARGET="$TARGET" \
  FM_SUPERVISOR_BACKEND=herdr FM_DAEMON_PRIMARY_HARNESS=claude LOG="$TMP_ROOT/daemon.log"
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
HEAD_TOKEN="FMDIGESTHEAD$$_$RANDOM"
TAIL_TOKEN="FMDIGESTTAIL$$_$RANDOM"
escalate_add "$DAEMON_STATE" "lab-fixture.status: done [key=span]: $HEAD_TOKEN $(printf 'lab fixture span record, no action - wdrożenie gotowe; %.0s' $(seq 1 160))"
for i in 1 2 3; do
  escalate_add "$DAEMON_STATE" "lab-fixture.status: done [key=child-pr-$i]: child lab-$i done: PR https://example.invalid/pull/40$i ready, fixture text only, no action needed #40$i"
done
escalate_add "$DAEMON_STATE" "lab-fixture.status: needs-decision [key=pick]: fixture decision, no action needed $TAIL_TOKEN"
flushes=0
while [ -s "$DAEMON_STATE/.subsuper-escalations" ] && [ "$flushes" -lt 12 ]; do
  wait_idle || fail "Claude Code ($VERSION) on $HERDR_VER never returned to idle between away digests"
  flushes=$((flushes + 1))
  escalate_flush "$DAEMON_STATE" || sleep 2
done
[ ! -s "$DAEMON_STATE/.subsuper-escalations" ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: overnight-shaped away digests were not all delivered after $flushes flushes: $(cat "$LOG" 2>/dev/null)"
if grep -F -q 'inject failed' "$LOG" 2>/dev/null; then
  fail "Claude Code ($VERSION) on $HERDR_VER: an away digest submit failed: $(grep -F 'inject failed' "$LOG")"
fi
rendered "$HEAD_TOKEN" || fail "Claude Code ($VERSION) on $HERDR_VER: the cut status span never rendered"
rendered "$TAIL_TOKEN" || fail "Claude Code ($VERSION) on $HERDR_VER: the last buffered event never rendered"
pass "live Herdr away digests: Claude Code ($VERSION) on $HERDR_VER receives an overnight-shaped buffer as bounded digests ($flushes flushes)"

HASH_TOKEN="FMHASHWRAP$$_$RANDOM"
hash_items="lab-fixture.status: done: merged fixture PRs"
for i in $(seq 400 430); do hash_items="$hash_items #$i"; done
escalate_add "$DAEMON_STATE" "$hash_items $HASH_TOKEN"
wait_idle || fail "Claude Code ($VERSION) on $HERDR_VER never returned to idle before the wrapped digest"
escalate_flush "$DAEMON_STATE" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a digest whose wrapped rows start with '#' was refused: $(tail -1 "$LOG" 2>/dev/null)"
rendered "$HASH_TOKEN" || fail "Claude Code ($VERSION) on $HERDR_VER: the '#'-wrapped digest never rendered"
pass "live Herdr away digests: Claude Code ($VERSION) on $HERDR_VER receives a digest whose wrapped rows start with '#'"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
