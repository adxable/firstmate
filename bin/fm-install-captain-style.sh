#!/usr/bin/env bash
# Wire docs/styl-kapitanski.md into user-level Claude memory on this machine.
#
# Why this script exists: user-level memory lives outside the repo, at
# ~/.claude/CLAUDE.md, and reaches the style rules through an @import line that
# names a path. A path hand-written on one machine names a directory that does
# not exist on the next one, and a Claude Code @import whose target is missing
# is dropped in silence - no warning, no stderr, exit 0 - so the style rules
# stop loading with nothing to notice. This script derives the path from its own
# location instead, so setting firstmate up on a new machine never involves
# guessing one.
#
# Measured against Claude Code 2.1.220: ~/.claude/CLAUDE.md resolves an @import
# written as an absolute path, as a ~/-relative path, and as a path relative to
# the importing file's own directory. This script prefers the ~/-relative form
# whenever the repo sits under $HOME, because that form also survives a
# different username or a relocated home directory, and falls back to an
# absolute path for a clone outside $HOME. Run --verify after any move.
#
# The memory file belongs to its owner, not to this script. Every line before
# the BEGIN marker and after the END marker is passed through unchanged, the
# block is refreshed where it already sits rather than moved to the end, and a
# repeat run is byte-identical. The single deliberate exception is the legacy
# machine-specific @import of this same style file, which is what this script
# replaces, and every such line is named in the run output.
#
# Nothing is skipped quietly and the extent of the block is never guessed. When
# the memory file cannot be read, when its BEGIN marker has no matching END
# marker, or when the file cannot be written, nothing is written at all and the
# exact import line and target file are printed as an explicit manual step.
#
# A memory file that is a symlink stays a symlink: the content is written to the
# file the link resolves to, that real path is printed, and a dangling link is
# refused rather than quietly replaced with a regular file.
#
# Usage:
#   fm-install-captain-style.sh [--dry-run]   install or refresh the block
#   fm-install-captain-style.sh --check       resolve the installed import line,
#                                             confirm it reaches a real file,
#                                             report, and never write
#   fm-install-captain-style.sh --verify      alias for --check
#   fm-install-captain-style.sh --print-import  print the import line only
#   fm-install-captain-style.sh --uninstall   remove the block
#   fm-install-captain-style.sh --help        print this header
#
# Honors CLAUDE_CONFIG_DIR, matching Claude Code's own override, and falls back
# to $HOME/.claude.
set -eu

BEGIN_MARK='<!-- firstmate:captain-style begin -->'
END_MARK='<!-- firstmate:captain-style end -->'
STYLE_REL='docs/styl-kapitanski.md'

usage() {
  cat >&2 <<'EOF'
usage: fm-install-captain-style.sh [--dry-run|--check|--verify|--print-import|--uninstall|--help]
EOF
}

# This script's header is its documentation, so --help prints the header on
# stdout the way bin/fm-test-run.sh does. A usage error keeps the one-line form
# on stderr and a non-zero exit.
help_text() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

MODE=install
case "${1:-}" in
  '') ;;
  --dry-run) MODE=dry-run ;;
  --check) MODE=check ;;
  --verify) MODE=verify ;;
  --print-import) MODE=print-import ;;
  --uninstall) MODE=uninstall ;;
  -h|--help) help_text; exit 0 ;;
  *) usage; exit 1 ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
STYLE_ABS="$ROOT/$STYLE_REL"

[ -f "$STYLE_ABS" ] || {
  echo "error: style file not found: $STYLE_ABS" >&2
  echo "hint: run this script from a complete firstmate checkout" >&2
  exit 1
}

[ -n "${HOME:-}" ] || { echo "error: HOME is not set" >&2; exit 1; }
HOME_ABS=$(cd "$HOME" 2>/dev/null && pwd -P) || {
  echo "error: HOME is not a readable directory: $HOME" >&2
  exit 1
}

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
MEMORY_FILE="$CONFIG_DIR/CLAUDE.md"

# Prefer the ~/-relative form: it keeps working when the home directory itself
# moves or is named differently, which an absolute path does not.
case "$STYLE_ABS" in
  "$HOME_ABS"/*)
    # A literal tilde is the point: the memory loader expands it, not this shell.
    # shellcheck disable=SC2088
    IMPORT_PATH="~/${STYLE_ABS#"$HOME_ABS"/}"
    ;;
  *)
    IMPORT_PATH="$STYLE_ABS"
    ;;
esac
IMPORT_LINE="@$IMPORT_PATH"

if [ "$MODE" = print-import ]; then
  printf '%s\n' "$IMPORT_LINE"
  exit 0
fi

# Resolve an import path the way the memory loader does, so --verify measures
# the written line rather than restating the value this run just computed.
# Matching a literal leading tilde in the written line, never expanding one.
# shellcheck disable=SC2088
resolve_import() {
  case "$1" in
    '~/'*) printf '%s\n' "$HOME_ABS/${1#'~/'}" ;;
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$CONFIG_DIR/$1" ;;
  esac
}

# Follow a symlink chain by hand: macOS ships no readlink -f, and the point is
# to learn the real path so the write lands on it instead of on the link.
resolve_link() {
  local path=$1 target depth=0
  while [ -L "$path" ]; do
    depth=$((depth + 1))
    [ "$depth" -le 40 ] || return 1
    target=$(readlink "$path") || return 1
    case "$target" in
      /*) path=$target ;;
      *) path="$(dirname "$path")/$target" ;;
    esac
  done
  printf '%s\n' "$path"
}

render_block() {
  printf '%s\n' "$BEGIN_MARK"
  printf '%s\n' '<!-- Managed by bin/fm-install-captain-style.sh. Edit the style file, not this block. -->'
  printf '\n'
  printf '%s\n' '# Styl odpowiedzi'
  printf '\n'
  printf '%s\n' "$IMPORT_LINE"
  printf '%s\n' "$END_MARK"
}

installed_import_line() {
  [ -f "$MEMORY_TARGET" ] || return 1
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock && /^@/ { print; found = 1 }
    END { exit found ? 0 : 1 }
  ' "$MEMORY_TARGET"
}

# Report on the markers without changing anything. A BEGIN with no END means the
# block has no knowable extent, so this prints why and exits non-zero rather
# than letting a rewrite guess and swallow the rest of the file.
# shellcheck disable=SC2016 # $0 and NR belong to awk, not to this shell.
VALIDATE_AWK='
  $0 == b {
    if (inblock) {
      bad = "a second BEGIN marker at line " NR " opens inside the block that began at line " bl
      exit 2
    }
    inblock = 1
    bl = NR
    next
  }
  $0 == e {
    if (!inblock) {
      bad = "an END marker at line " NR " has no BEGIN marker above it"
      exit 2
    }
    inblock = 0
    next
  }
  END {
    if (bad == "" && inblock) {
      bad = "the BEGIN marker at line " bl " has no matching END marker"
    }
    if (bad != "") {
      print bad
      exit 2
    }
  }
'

# Rewrite the file as prefix + block + suffix. The block is re-rendered where it
# already sits, so nothing outside the markers moves; with no block present it
# is appended after the existing content. blockfile empty means uninstall: the
# block region is dropped and nothing replaces it.
# shellcheck disable=SC2016 # $0 and NR belong to awk, not to this shell.
SPLICE_AWK='
  function put_block(   line) {
    if (blockfile == "") return
    while ((getline line < blockfile) > 0) print line
    close(blockfile)
  }
  $0 == b {
    inblock = 1
    if (!seen) {
      seen = 1
      put_block()
    }
    next
  }
  $0 == e { inblock = 0; next }
  inblock { next }
  # The pre-installer wiring was one machine-specific @import of this same file.
  /^@.*\/docs\/styl-kapitanski\.md[[:space:]]*$/ { next }
  { print }
  END {
    if (!seen && blockfile != "") {
      if (NR > 0) print ""
      put_block()
    }
  }
'

memory_readable() {
  [ ! -e "$MEMORY_TARGET" ] && return 0
  [ -f "$MEMORY_TARGET" ] && [ -r "$MEMORY_TARGET" ]
}

legacy_lines() {
  [ -e "$MEMORY_TARGET" ] || return 0
  memory_readable || return 1
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock { next }
    /^@.*\/docs\/styl-kapitanski\.md[[:space:]]*$/ { print }
  ' "$MEMORY_TARGET"
}

report_status() {
  local line target
  if ! line=$(installed_import_line); then
    echo "captain-style: NOT INSTALLED (no managed block in $MEMORY_TARGET)"
    return 1
  fi
  target=$(resolve_import "${line#@}")
  if [ -f "$target" ]; then
    echo "captain-style: installed  import=$line  resolves=$target"
    return 0
  fi
  echo "captain-style: BROKEN  import=$line  resolves=$target (missing)" >&2
  echo "hint: re-run fm-install-captain-style.sh from the current checkout" >&2
  return 1
}

manual_step() {
  cat >&2 <<EOF

Do this by hand instead - the style rules do not load until it is done:

  1. Create or open $MEMORY_TARGET
  2. Add these lines:

$(render_block | sed 's/^/     /')

  3. Confirm with: $0 --verify
EOF
}

# Refusing here keeps the pass-through promise: a memory file this run cannot
# read is a file whose content this run cannot carry over, so it is left exactly
# as it is and nothing is written anywhere.
memory_unreadable() {
  echo "error: $MEMORY_TARGET exists but could not be read" >&2
  echo "Nothing was written and the existing file is untouched." >&2
  manual_step
  exit 1
}

memory_block_corrupt() {
  cat >&2 <<EOF
error: the managed block in $MEMORY_TARGET is corrupt: $1

Nothing was written and the existing file is untouched. This script owns only
the region between these two lines and refuses to guess where it ends:

  $BEGIN_MARK
  $END_MARK

Fix it by hand - either restore the missing marker or delete the block and its
body outright - then re-run: $0
EOF
  exit 1
}

memory_link_broken() {
  cat >&2 <<EOF
error: $MEMORY_FILE is a symlink that cannot be written through: $1

Nothing was written. Replacing the link with a regular file would detach it from
wherever it points, so this script refuses instead.
EOF
  manual_step
  exit 1
}

memory_unwritable() {
  echo "error: could not write $MEMORY_TARGET" >&2
  manual_step
  exit 1
}

# Writes land on the file the link resolves to, never on the link itself, so a
# memory file kept in a dotfiles repo stays wired to that repo.
MEMORY_TARGET=$MEMORY_FILE
if [ -L "$MEMORY_FILE" ]; then
  MEMORY_TARGET=$(resolve_link "$MEMORY_FILE") ||
    memory_link_broken "the chain is unreadable or longer than 40 links"
  LINK_DIR=$(cd "$(dirname "$MEMORY_TARGET")" 2>/dev/null && pwd -P) ||
    memory_link_broken "it points into $(dirname "$MEMORY_TARGET"), which does not exist"
  MEMORY_TARGET="$LINK_DIR/$(basename "$MEMORY_TARGET")"
  [ -e "$MEMORY_TARGET" ] ||
    memory_link_broken "it points at $MEMORY_TARGET, which does not exist"
fi

memory_readable || memory_unreadable

if [ -e "$MEMORY_TARGET" ]; then
  BLOCK_PROBLEM=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" "$VALIDATE_AWK" "$MEMORY_TARGET") ||
    memory_block_corrupt "$BLOCK_PROBLEM"
fi

case "$MODE" in
  check|verify)
    if report_status; then exit 0; else exit 1; fi
    ;;
esac

if [ "$MODE" = dry-run ]; then
  echo "would write to: $MEMORY_TARGET"
  if [ "$MEMORY_TARGET" != "$MEMORY_FILE" ]; then
    echo "would write through the symlink at: $MEMORY_FILE"
  fi
  legacy_lines | while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "would replace legacy import: $l"
  done
  echo "--- managed block ---"
  render_block
  exit 0
fi

mkdir -p "$CONFIG_DIR" 2>/dev/null || memory_unwritable

if [ -e "$MEMORY_TARGET" ] && [ ! -w "$MEMORY_TARGET" ]; then
  memory_unwritable
fi

# Both temporaries sit beside the resolved target, so the rename that publishes
# the new content stays within one filesystem.
TMP="$MEMORY_TARGET.fm-style.$$"
BLOCK_TMP="$MEMORY_TARGET.fm-style-block.$$"
trap 'rm -f "$TMP" "$BLOCK_TMP"' EXIT

REMOVED_LEGACY=$(legacy_lines) || memory_unreadable

report_removed_legacy() {
  local label=$1 l
  [ -n "$REMOVED_LEGACY" ] || return 0
  printf '%s\n' "$REMOVED_LEGACY" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "captain-style: $label legacy import: $l"
  done
}

if [ "$MODE" = uninstall ]; then
  : >"$BLOCK_TMP" 2>/dev/null || memory_unwritable
  BLOCK_ARG=
else
  render_block >"$BLOCK_TMP" 2>/dev/null || memory_unwritable
  BLOCK_ARG=$BLOCK_TMP
fi

# An existing target seeds the temporary file so the rename keeps the mode the
# operator gave it instead of resetting it to whatever the umask says.
if [ -e "$MEMORY_TARGET" ]; then
  cp "$MEMORY_TARGET" "$TMP" 2>/dev/null || memory_unwritable
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v blockfile="$BLOCK_ARG" \
    "$SPLICE_AWK" "$MEMORY_TARGET" >"$TMP" 2>/dev/null || memory_unwritable
else
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v blockfile="$BLOCK_ARG" \
    "$SPLICE_AWK" /dev/null >"$TMP" 2>/dev/null || memory_unwritable
fi

if [ "$MODE" = uninstall ] && [ ! -s "$TMP" ] && [ "$MEMORY_TARGET" = "$MEMORY_FILE" ]; then
  rm -f "$TMP" "$BLOCK_TMP"
  rm -f "$MEMORY_TARGET" 2>/dev/null || memory_unwritable
  trap - EXIT
  # --uninstall unwires completely, legacy lines included. Say which ones went,
  # so removing content this script never wrote is never silent.
  report_removed_legacy removed
  echo "captain-style: removed from $MEMORY_TARGET"
  exit 0
fi

mv "$TMP" "$MEMORY_TARGET" 2>/dev/null || memory_unwritable
rm -f "$BLOCK_TMP"
trap - EXIT

if [ "$MEMORY_TARGET" != "$MEMORY_FILE" ]; then
  echo "captain-style: wrote $MEMORY_TARGET through the symlink at $MEMORY_FILE"
fi

if [ "$MODE" = uninstall ]; then
  report_removed_legacy removed
  echo "captain-style: removed from $MEMORY_TARGET"
  exit 0
fi

report_removed_legacy replaced
report_status
