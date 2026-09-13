#!/usr/bin/env bash
# fm-treehouse-root.sh - the single owner of "which treehouse pool root does
# this firstmate home use". Prints one absolute path on stdout, or nothing at
# all when this home needs no root of its own.
#
# Usage: fm-treehouse-root.sh
#        FM_HOME=/path/to/home fm-treehouse-root.sh
#
# WHY THIS EXISTS. Treehouse keys a pool by the repository's REMOTE URL, not by
# the clone path: `<root>/.treehouse/<basename-of-clone-dir>-<hash-of-remote>`.
# Two firstmate homes that each hold their own clone of one repository therefore
# resolve to the SAME pool under one root, and a slot that pool hands out may be
# a linked worktree of the OTHER home's clone. That slot passes fm-spawn.sh's
# isolation and ownership guards (it is a real worktree, it is not this
# project, and its git dir is not this project's common dir), so the collision
# surfaces later and less legibly:
#   - a claude spawn is refused by bin/fm-claude-trust.sh's scope test, whose
#     common-dir comparison is the one check that sees the wrong clone, and the
#     home cannot start anything at all;
#   - on a harness with no such pre-registration the worker branches and commits
#     inside the other clone's object store, and this home's teardown then does
#     not recognize the slot as a pool slot at all (fm-teardown.sh's
#     is_treehouse_pool_slot requires a matching common dir), so the lease is
#     never returned.
# Giving each home its own root makes the two pools distinct directories even
# though the remote hash is identical, so a home can only ever be handed a slot
# backed by its own clone.
#
# RESOLUTION. There is nothing to configure; a home's root follows from what the
# home IS.
#   - A secondmate home gets its own root: $HOME/.treehouse-homes/<home id>,
#     where <home id> is the registered secondmate id its .fm-secondmate-home
#     identity marker holds - the id bin/fm-home-seed.sh writes and the registry
#     key in data/secondmates.md. Whether this home IS a secondmate is not
#     decided here: bin/fm-primary-scope-lib.sh's fm_root_is_secondmate_home
#     owns that question for the whole repository, and a marker it rejects makes
#     this home a primary here exactly as it does everywhere else.
#     The id, not the home's PATH, is what keys the root: a secondmate home is
#     itself a slot in the primary's firstmate pool, that slot is returned when
#     the home is retired, and treehouse hands the same slot path
#     (<pool>/2/firstmate) to the next home. A path-derived key would therefore
#     make the next home inherit the retired home's pool; the registered id is
#     unique among live homes and is not recycled with the slot. An id that
#     cannot be one path segment would name a directory other than this home's
#     own, so it is refused rather than used.
#   - Any other home: nothing is printed and it is left alone. No TREEHOUSE_ROOT
#     is forced anywhere, so treehouse's own resolution stands and a project that
#     configures its own root in treehouse.toml keeps it. A primary home
#     therefore does not move: no migration, no disturbance to secondmate homes
#     already leased inside the primary's pool, and work in flight keeps its
#     pool.
#
# SCOPE. This governs the pools a home's PROJECT worktrees come from. It does
# not govern the firstmate-repo lease a secondmate HOME itself occupies: that
# slot belongs to the primary that seeded it (bin/fm-home-seed.sh) and is
# returned by the primary (bin/fm-teardown.sh), both through treehouse's own
# default resolution, so a root resolved here never strands a live home.
#
# Consumers: bin/fm-spawn.sh prefixes the pane's `treehouse get` with the
# resolved root and records it as treehouse_root= in state/<id>.meta, and sends
# the bare `treehouse get` with no record when nothing is printed;
# bin/fm-teardown.sh returns a slot against that recorded value, and against
# treehouse's own default when a task has no record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

SECONDMATE_MARKER=".fm-secondmate-home"
HOMES_DIRNAME=".treehouse-homes"

die() { echo "error: fm-treehouse-root.sh: $1" >&2; exit 1; }

[ "$#" -eq 0 ] || die "takes no arguments"

# Detection lives in an upstream-tracked file, so a rename there must be loud.
# Reporting no root is not a safe answer to "could not tell": it is exactly the
# answer that puts a secondmate home back on the shared pool.
SCOPE_LIB="$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCOPE_LIB" \
  || die "could not load '$SCOPE_LIB', which owns secondmate-home detection"
declare -F fm_root_is_secondmate_home >/dev/null \
  || die "'$SCOPE_LIB' defines no fm_root_is_secondmate_home, so this home's identity cannot be established"

# A secondmate home gets its own root, keyed by its registered id.
MARKER="$FM_HOME/$SECONDMATE_MARKER"
if fm_root_is_secondmate_home "$FM_HOME"; then
  [ -n "${HOME:-}" ] \
    || die "HOME is not set, so this secondmate home's own worktree pool root cannot be built"
  home_id=
  IFS= read -r home_id < "$MARKER" || true
  home_id=${home_id//[[:space:]]/}
  case $home_id in
    . | .. | */*)
      die "'$MARKER' must hold one secondmate id usable as a directory name, got '$home_id'" ;;
  esac
  printf '%s/%s/%s\n' "$HOME" "$HOMES_DIRNAME" "$home_id"
  exit 0
fi

# Any other home: nothing, so treehouse's own resolution stands and a primary
# home never moves.
exit 0
