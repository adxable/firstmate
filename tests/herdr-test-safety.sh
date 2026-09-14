#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_lab_home <dir>: a lab-owned $HOME for spawns this suite drives.
#
# bin/fm-treehouse-root.sh resolves a marker-bearing home's worktree pool root
# under $HOME, so a spawn with FM_HOME pointing at a secondmate-shaped fixture
# and an unpinned HOME builds a real pool inside the operator's own home, under
# an id that can name a live secondmate. Pinning HOME moves only that root:
# herdr resolves a named session under $HOME/.config/herdr and an explicit
# --session ignores HERDR_SOCKET_PATH, and git reads $HOME/.gitconfig, so both
# are linked through to the real home. Echoes the path.
herdr_lab_home() {  # <dir>
  local dir=$1 real=${HOME:-}
  [ -n "$real" ] || {
    printf 'herdr_lab_home: HOME is not set, so the lab home cannot reach the real herdr config\n' >&2
    return 1
  }
  [ -d "$real/.config/herdr" ] || {
    printf 'herdr_lab_home: %s does not exist, so a spawn under the lab home would not find the lab session; start herdr once first\n' \
      "$real/.config/herdr" >&2
    return 1
  }
  mkdir -p "$dir/.config" || return 1
  [ -e "$dir/.config/herdr" ] || ln -s "$real/.config/herdr" "$dir/.config/herdr" || return 1
  [ ! -f "$real/.gitconfig" ] || [ -e "$dir/.gitconfig" ] \
    || ln -s "$real/.gitconfig" "$dir/.gitconfig"
  printf '%s\n' "$dir"
}

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
