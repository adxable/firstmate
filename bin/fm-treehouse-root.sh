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
# RESOLUTION ORDER.
#   1. $FM_HOME/config/treehouse-root, when it is a regular, single-linked file
#      whose first line is a non-empty absolute path. Home-local operator
#      override; LOCAL, gitignored, and deliberately NOT inherited into
#      secondmate homes, because inheriting one root is what recreates the
#      collision (bin/fm-config-inherit-lib.sh owns that exclusion).
#   2. A secondmate home gets its own root: $HOME/.treehouse-homes/<home id>,
#      where <home id> is the registered secondmate id its .fm-secondmate-home
#      identity marker holds - the same marker bin/fm-bootstrap.sh and
#      bin/fm-backend-hometag-lib.sh already read to answer this question, the
#      id bin/fm-home-seed.sh writes, and the registry key in
#      data/secondmates.md. The id, not the home's PATH, is what keys the root:
#      a secondmate home is itself a slot in the primary's firstmate pool, that
#      slot is returned when the home is retired, and treehouse hands the same
#      slot path (<pool>/2/firstmate) to the next home. A path-derived key would
#      therefore make the next home inherit the retired home's pool; the
#      registered id is unique among live homes and is not recycled with the
#      slot. A marker that holds no usable id is refused rather than keyed on
#      something weaker, because the fallback would be a root shared with
#      another home.
#   3. Otherwise nothing is printed and this home is left alone: no
#      TREEHOUSE_ROOT is forced anywhere, so treehouse's own resolution stands
#      and a project that configures its own root in treehouse.toml keeps it. A
#      primary home therefore does not move: no migration, no disturbance to
#      secondmate homes already leased inside the primary's pool, and work in
#      flight keeps its pool.
#
# SCOPE. This governs the pools a home's PROJECT worktrees come from. It does
# not govern the firstmate-repo lease a secondmate HOME itself occupies: that
# slot belongs to the primary that seeded it (bin/fm-home-seed.sh) and is
# returned by the primary (bin/fm-teardown.sh), both through treehouse's own
# default resolution, so an override set here never strands a live home.
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
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

SECONDMATE_MARKER=".fm-secondmate-home"
HOMES_DIRNAME=".treehouse-homes"

die() { echo "error: fm-treehouse-root.sh: $1" >&2; exit 1; }

[ "$#" -eq 0 ] || die "takes no arguments"
[ -n "${HOME:-}" ] || die "HOME is not set, so no treehouse root can be resolved"

# Leg 1: the home-local operator override.
#
# The file is read only when it is a regular, single-linked file, the same
# safety shape the other single-value config readers in bin/ apply, so a
# symlink or a special file cannot redirect a home's whole worktree pool. A
# present but malformed file is an error rather than a silent fall-through to
# the default: falling through would put the home back on the shared pool this
# override exists to leave.
OVERRIDE="$CONFIG/treehouse-root"
if [ -f "$OVERRIDE" ] && [ ! -L "$OVERRIDE" ]; then
  # A directory whose contents an attacker controls is not a concern here (the
  # whole home is captain-private), but a config/ replaced by a symlink is
  # exactly the shape the other readers refuse, so refuse it the same way.
  [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] \
    || die "'$CONFIG' is not a plain directory, so '$OVERRIDE' cannot be trusted"
  # `read` reports failure at EOF even after assigning a final line that has no
  # trailing newline, so the value it read is kept; an empty or unreadable file
  # leaves the variable empty and reaches the '' arm below.
  override_value=
  IFS= read -r override_value < "$OVERRIDE" || true
  # Strip surrounding whitespace, including the CR an editor may leave.
  override_value=${override_value%%$'\r'*}
  override_value="${override_value#"${override_value%%[![:space:]]*}"}"
  override_value="${override_value%"${override_value##*[![:space:]]}"}"
  case $override_value in
    /*) printf '%s\n' "$override_value"; exit 0 ;;
    '') die "'$OVERRIDE' is empty; remove it to use the default root, or write one absolute path" ;;
    *) die "'$OVERRIDE' must hold one absolute path, got '$override_value'" ;;
  esac
fi

# Leg 2: a secondmate home gets its own root, keyed by its registered id.
MARKER="$FM_HOME/$SECONDMATE_MARKER"
if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
  home_id=
  IFS= read -r home_id < "$MARKER" || true
  home_id=${home_id%%$'\r'*}
  home_id="${home_id#"${home_id%%[![:space:]]*}"}"
  home_id="${home_id%"${home_id##*[![:space:]]}"}"
  # The id names one directory under $HOME/.treehouse-homes, so it must be a
  # single safe path segment. Anything else is refused by name rather than
  # coerced: the only fallback available is a root some other home already uses.
  [ -n "$home_id" ] \
    || die "'$MARKER' holds no secondmate id, so this home has no identity to key its own worktree pool on"
  case $home_id in
    . | .. | *[!A-Za-z0-9._-]*)
      die "'$MARKER' must hold one secondmate id usable as a directory name, got '$home_id'" ;;
  esac
  printf '%s/%s/%s\n' "$HOME" "$HOMES_DIRNAME" "$home_id"
  exit 0
fi

# Leg 3: nothing, so treehouse's own resolution stands and a primary home never
# moves.
exit 0
