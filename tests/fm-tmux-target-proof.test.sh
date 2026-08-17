#!/usr/bin/env bash
# tests/fm-tmux-target-proof.test.sh - portable regression for proof-grade tmux
# endpoint existence (fm_backend_target_proven in bin/fm-backend.sh, backed by
# fm_backend_tmux_target_exists_exact in bin/backends/tmux.sh).
#
# It runs REAL processes in a REAL tmux server on a private socket (`-L`), and
# needs no harness and no credentials, so it runs everywhere CI runs tmux. The
# installed-tmux counterpart is tests/fm-tmux-target-fallback-live-e2e.test.sh.
#
# The defect it exists for: fm-spawn.sh refuses to seat a task in a worktree
# another task's metadata still claims, and asked the cheap existence probe
# whether that other endpoint was still there. On tmux that probe cannot answer
# the question - an absent NAME target silently resolves to the client's active
# window and the read succeeds - so a task whose window was closed without a
# teardown probed as present and blocked its pool slot forever.
#
# This file pins only what stays correct whatever tmux does: the same target
# must read proven-present while its window exists and released once it is gone,
# and neither an absent session nor a surviving session whose name the recorded
# one prefixes may answer for it. Those cases cannot go quietly vacuous, because
# one target is observed flipping verdict across a real kill-window.
# The fallback itself is a current tmux behavior rather than a guarantee, so the
# assertion that it still happens lives in the env-gated
# tests/fm-tmux-target-fallback-live-e2e.test.sh: a tmux that stopped falling
# back would leave this file and the ownership guard correct, and must not turn
# CI red.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
TMUX_VERSION=$("$REAL_TMUX" -V 2>/dev/null || printf 'unknown')
SOCKET="fm-target-proof-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-target-proof.XXXXXX")
SESSION=proof

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so bin/backends/tmux.sh's bare `tmux` calls reach the
# private socket and never touch the host's real sessions.
mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# The session's own window stays the ACTIVE one, so an absent named target has
# somewhere to fall back to - the shape a live captain session always has.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n captain -c "$LAB/wt" \
  -- "$SLEEP_BIN" 900 \
  || fail "could not start the private tmux server"

# A task window whose foreground is an ordinary long-running command and NOT a
# harness: this is the incident's own shape, a worker parked at a validation
# gate with the pipeline in the foreground. It still owns its worktree.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n fm-present -c "$LAB/wt" \
  -- "$SLEEP_BIN" 900 \
  || fail "could not create the present task window"

PRESENT="$SESSION:fm-present"
ABSENT="$SESSION:fm-torn-down"

# --- proof-grade existence ---------------------------------------------------
fm_backend_target_proven tmux "$PRESENT" \
  || fail "a window that really exists was not proven present on $TMUX_VERSION"
pass "an existing window with no agent in it is proven present, so it keeps its worktree"

if fm_backend_target_proven tmux "$ABSENT"; then
  fail "an absent window was reported present on $TMUX_VERSION; a stale record would block its pool slot forever"
fi
pass "a window that is gone is not proven present, so its record releases the slot"

"$REAL_TMUX" -L "$SOCKET" kill-window -t "=$SESSION:=fm-present" \
  || fail "could not close the task window"
if fm_backend_target_proven tmux "$PRESENT"; then
  fail "a closed window was still reported present on $TMUX_VERSION"
fi
pass "closing the window flips the same target from proven-present to released"

if fm_backend_target_proven tmux "no-such-session:fm-present"; then
  fail "a target in a session that does not exist was reported present"
fi
pass "a target whose session is gone is not proven present"

# The same falsehood one level up: tmux resolves a target-session by exact
# match, then fnmatch, then start-of-name, so a recorded session that is gone
# can silently resolve into a surviving session whose name it prefixes. The
# surviving session even holds a window of the recorded name, which is what
# makes the wrong answer look right.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION-survivor" -n fm-holder -c "$LAB/wt" \
  -- "$SLEEP_BIN" 900 \
  || fail "could not start the surviving session"

fm_backend_target_proven tmux "$SESSION-survivor:fm-holder" \
  || fail "the surviving session's own window was not proven present on $TMUX_VERSION"
pass "the surviving session's own endpoint is proven present"

if fm_backend_target_proven tmux "$SESSION-surv:fm-holder"; then
  fail "a gone session was resolved into the surviving session it prefixes on $TMUX_VERSION; that record would block its pool slot forever"
fi
pass "a gone session is not answered for by a surviving session whose name it prefixes"

echo "# all fm-tmux-target-proof tests passed"
