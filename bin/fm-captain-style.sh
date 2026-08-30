#!/usr/bin/env bash
# Print the line that wires docs/styl-kapitanski.md into user-level Claude memory.
#
# This script never writes to the memory file. It works out the two
# machine-specific values a human needs - which line to paste, and which file to
# paste it into - and prints them. Wiring the rules in stays a deliberate human
# edit, so nothing here can rewrite, reorder, truncate, or relink a file this
# script does not own.
#
# Why it exists: user-level memory lives outside the repo, at
# ~/.claude/CLAUDE.md, and reaches the style rules through an @import line that
# names a path. A path hand-written on one machine names a directory that does
# not exist on the next one, and a Claude Code @import whose target is missing is
# dropped in silence - no warning, no stderr, exit 0 - so the style rules stop
# loading with nothing to notice. Deriving the path from this script's own
# location removes the guessing, and --check turns that silent failure into a
# visible one.
#
# Measured against Claude Code 2.1.247, confirming the two mechanisms this wiring
# rests on: an @import path is followed after ~ expansion, and user-level memory
# follows an import whose target lives outside the config directory. The
# ~/-relative form is preferred whenever the repo sits under $HOME, because it
# also survives a different username or a relocated home directory; a clone
# outside $HOME gets an absolute path. Re-run --check after moving either.
#
# Usage:
#   fm-captain-style.sh                 print the line, the file to paste it
#                                       into, and where in that file it goes
#   fm-captain-style.sh --check         read-only: report whether the line is
#                                       already wired in and whether it still
#                                       reaches the style file; never writes
#   fm-captain-style.sh --verify        alias for --check
#   fm-captain-style.sh --print-import  print the import line alone
#   fm-captain-style.sh --help          print this header
#
# Exit status is 0 when the wiring is in place (or, in the default mode, when
# the instructions were printed), and non-zero for every state that needs a
# human to act.
#
# Honors CLAUDE_CONFIG_DIR, matching Claude Code's own override, and falls back
# to $HOME/.claude.
set -eu

STYLE_REL='docs/styl-kapitanski.md'

usage() {
  cat >&2 <<'EOF'
usage: fm-captain-style.sh [--check|--verify|--print-import|--help]
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

MODE=print
case "${1:-}" in
  '') ;;
  --check|--verify) MODE=check ;;
  --print-import) MODE=print-import ;;
  -h|--help) help_text; exit 0 ;;
  *) usage; exit 1 ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
STYLE_ABS="$ROOT/$STYLE_REL"

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

# Resolve an import path the way the memory loader does, so --check measures the
# line that is actually written rather than restating the value just computed.
# Matching a literal leading tilde in the written line, never expanding one.
# shellcheck disable=SC2088
resolve_import() {
  case "$1" in
    '~/'*) printf '%s\n' "$HOME_ABS/${1#'~/'}" ;;
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$CONFIG_DIR/$1" ;;
  esac
}

# Every import of this style file, whatever path form it uses. Leading
# whitespace is matched deliberately so an indented paste is found and named
# rather than silently reported as absent.
style_imports() {
  [ -f "$MEMORY_FILE" ] || return 0
  grep -E '^[[:space:]]*@.*styl-kapitanski\.md[[:space:]]*$' "$MEMORY_FILE" 2>/dev/null || true
}

instructions() {
  printf 'Paste this line into: %s\n' "$MEMORY_FILE"
  printf '\n'
  printf '%s\n' "$IMPORT_LINE"
  printf '\n'
  printf 'Put it on its own line with no indentation. Anywhere in the file works,\n'
  printf 'and everything already in that file can stay exactly as it is.\n'
  printf 'Then confirm with: %s --check\n' "$0"
}

if [ ! -f "$STYLE_ABS" ]; then
  echo "error: style file not found: $STYLE_ABS" >&2
  echo "hint: run this script from a complete firstmate checkout" >&2
  STYLE_MISSING=1
else
  STYLE_MISSING=0
fi

if [ -e "$MEMORY_FILE" ] && { [ ! -f "$MEMORY_FILE" ] || [ ! -r "$MEMORY_FILE" ]; }; then
  echo "error: $MEMORY_FILE exists but could not be read" >&2
  echo "hint: fix its permissions, then re-run this script" >&2
  exit 1
fi

IMPORTS=$(style_imports)
if [ -z "$IMPORTS" ]; then
  IMPORT_COUNT=0
else
  IMPORT_COUNT=$(printf '%s\n' "$IMPORTS" | wc -l | tr -d ' ')
fi

if [ "$MODE" = print ]; then
  if [ "$IMPORT_COUNT" -ge 1 ]; then
    printf 'captain-style: an import of the style file is already in %s\n' "$MEMORY_FILE"
    printf 'Run %s --check to see whether it still reaches the file.\n' "$0"
    printf '\n'
  fi
  instructions
  [ "$STYLE_MISSING" -eq 0 ] || exit 1
  exit 0
fi

# --check from here down. Read-only in every branch.
if [ ! -e "$MEMORY_FILE" ]; then
  echo "captain-style: NOT WIRED  $MEMORY_FILE does not exist" >&2
  instructions >&2
  exit 1
fi

if [ "$IMPORT_COUNT" -eq 0 ]; then
  echo "captain-style: NOT WIRED  no import of the style file in $MEMORY_FILE" >&2
  instructions >&2
  exit 1
fi

if [ "$IMPORT_COUNT" -gt 1 ]; then
  echo "captain-style: AMBIGUOUS  $MEMORY_FILE has $IMPORT_COUNT imports of the style file:" >&2
  printf '%s\n' "$IMPORTS" | sed 's/^/  /' >&2
  echo "hint: keep exactly one of them and delete the rest" >&2
  exit 1
fi

# Exactly one. Strip surrounding whitespace so an indented paste is diagnosed
# as indentation rather than as a broken path.
FOUND_RAW=$IMPORTS
FOUND=$(printf '%s\n' "$FOUND_RAW" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ "$FOUND_RAW" != "$FOUND" ]; then
  echo "captain-style: INDENTED  the import line in $MEMORY_FILE is not at the start of its line:" >&2
  printf '%s\n' "$FOUND_RAW" | sed 's/^/  /' >&2
  echo "hint: remove the leading whitespace so the line begins with @" >&2
  exit 1
fi

TARGET=$(resolve_import "${FOUND#@}")
if [ ! -f "$TARGET" ]; then
  echo "captain-style: BROKEN  import=$FOUND  resolves=$TARGET (missing)" >&2
  if [ "$STYLE_MISSING" -eq 0 ]; then
    echo "hint: the style file moved; replace that line with:" >&2
    printf '  %s\n' "$IMPORT_LINE" >&2
  else
    # Pointing at this checkout's own copy would name a file that is equally
    # absent, so say what is actually wrong instead of advising a dead path.
    echo "hint: $STYLE_ABS is missing too, so this checkout cannot supply the" >&2
    echo "      style file; restore it, or re-run from a complete checkout" >&2
  fi
  exit 1
fi

if [ "$FOUND" = "$IMPORT_LINE" ]; then
  echo "captain-style: wired  import=$FOUND  resolves=$TARGET"
else
  echo "captain-style: wired  import=$FOUND  resolves=$TARGET"
  echo "note: that line points at a different checkout than this one; this checkout would use $IMPORT_LINE"
fi
exit 0
