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
# Writes only its own marker-delimited block. Any other content in the memory
# file is preserved byte for byte, and a repeat run replaces the block rather
# than appending a second one. When the file cannot be written, the exact
# import line and target file are printed as an explicit manual step, never
# skipped quietly.
#
# Usage:
#   fm-install-captain-style.sh [--dry-run]   install or refresh the block
#   fm-install-captain-style.sh --check       report status, do not write
#   fm-install-captain-style.sh --verify      resolve the installed line and
#                                             confirm it reaches a real file
#   fm-install-captain-style.sh --print-import  print the import line only
#   fm-install-captain-style.sh --uninstall   remove the block
#
# Honors CLAUDE_CONFIG_DIR, matching Claude Code's own override, and falls back
# to $HOME/.claude.
set -eu

BEGIN_MARK='<!-- firstmate:captain-style begin -->'
END_MARK='<!-- firstmate:captain-style end -->'
STYLE_REL='docs/styl-kapitanski.md'

usage() {
  cat >&2 <<'EOF'
usage: fm-install-captain-style.sh [--dry-run|--check|--verify|--print-import|--uninstall]
EOF
}

MODE=install
case "${1:-}" in
  '') ;;
  --dry-run) MODE=dry-run ;;
  --check) MODE=check ;;
  --verify) MODE=verify ;;
  --print-import) MODE=print-import ;;
  --uninstall) MODE=uninstall ;;
  -h|--help) usage; exit 0 ;;
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

installed_import_line() {
  [ -f "$MEMORY_FILE" ] || return 1
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock && /^@/ { print; found = 1 }
    END { exit found ? 0 : 1 }
  ' "$MEMORY_FILE"
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

# Body of the memory file with the managed block and any legacy unmanaged
# import of this same style file removed. Trailing blank lines are trimmed so
# repeated runs converge instead of growing the file.
strip_managed() {
  if [ ! -f "$MEMORY_FILE" ]; then
    return 0
  fi
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock { next }
    # The pre-installer wiring was a bare heading plus one absolute @import.
    /^@.*\/docs\/styl-kapitanski\.md[[:space:]]*$/ { legacy = 1; next }
    { print }
  ' "$MEMORY_FILE" | awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  '
}

legacy_lines() {
  [ -f "$MEMORY_FILE" ] || return 0
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock { next }
    /^@.*\/docs\/styl-kapitanski\.md[[:space:]]*$/ { print }
  ' "$MEMORY_FILE"
}

report_status() {
  local line target
  if ! line=$(installed_import_line); then
    echo "captain-style: NOT INSTALLED (no managed block in $MEMORY_FILE)"
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

case "$MODE" in
  check|verify)
    if report_status; then exit 0; else exit 1; fi
    ;;
esac

if [ "$MODE" = dry-run ]; then
  echo "would write to: $MEMORY_FILE"
  legacy_lines | while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "would replace legacy import: $l"
  done
  echo "--- managed block ---"
  render_block
  exit 0
fi

manual_fallback() {
  cat >&2 <<EOF
error: could not write $MEMORY_FILE

Do this by hand instead - the style rules do not load until it is done:

  1. Create or open $MEMORY_FILE
  2. Add these lines:

$(render_block | sed 's/^/     /')

  3. Confirm with: $0 --verify
EOF
  exit 1
}

mkdir -p "$CONFIG_DIR" 2>/dev/null || manual_fallback

TMP="$MEMORY_FILE.fm-style.$$"
trap 'rm -f "$TMP"' EXIT

REMOVED_LEGACY=$(legacy_lines || true)

if [ "$MODE" = uninstall ]; then
  { strip_managed; } >"$TMP" 2>/dev/null || manual_fallback
  if [ -s "$TMP" ]; then
    printf '\n' >>"$TMP"
    mv "$TMP" "$MEMORY_FILE" 2>/dev/null || manual_fallback
  else
    rm -f "$TMP"
    rm -f "$MEMORY_FILE" 2>/dev/null || manual_fallback
  fi
  trap - EXIT
  echo "captain-style: removed from $MEMORY_FILE"
  exit 0
fi

{
  BODY=$(strip_managed)
  if [ -n "$BODY" ]; then
    printf '%s\n\n' "$BODY"
  fi
  render_block
} >"$TMP" 2>/dev/null || manual_fallback

mv "$TMP" "$MEMORY_FILE" 2>/dev/null || manual_fallback
trap - EXIT

if [ -n "$REMOVED_LEGACY" ]; then
  printf '%s\n' "$REMOVED_LEGACY" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "captain-style: replaced legacy import: $l"
  done
fi
report_status
