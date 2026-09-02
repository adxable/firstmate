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
# Measured against Claude Code 2.1.247, confirming the mechanisms this wiring
# rests on: an @import path is followed after ~ expansion; user-level memory
# follows an import whose target lives outside the config directory; an import
# line carrying one trailing space is followed, and so is a CR-terminated one;
# an import fenced in a ``` code block is not followed, while removing that
# fence in the same directory makes it load; and an import indented by four
# spaces is not followed, nor is one indented by a tab, while the same line at
# column zero is. Each of those is a tested case, not a general rule about
# whitespace or markdown. The ~/-relative form is preferred
# whenever the repo sits under $HOME, because it also survives a different
# username or a relocated home directory; a clone outside $HOME gets an absolute
# path. Re-run --check after moving either.
#
# Usage:
#   fm-captain-style.sh                 report the memory file's state and, when
#                                       it holds no import that loads, print the
#                                       line and the file to paste it into
#   fm-captain-style.sh --check         read-only: report whether the line is
#                                       already wired in and whether it still
#                                       reaches the style file; never writes
#   fm-captain-style.sh --verify        alias for --check
#   fm-captain-style.sh --print-import  print the import line alone
#   fm-captain-style.sh --help          print this header
#
# One classification decides what is true about the memory file, and every mode
# reads that same verdict: unreadable, absent, not wired, indented only, broken,
# ambiguous, or wired. A mode chooses only how much of it to print and on which
# stream, never what it says, so no two modes can report one file differently.
#
# That verdict follows the measurements above: it counts the occurrences that
# load, meaning the ones at column zero, outside any fenced code block. A line
# carrying trailing spaces or a CR from a CRLF editor is one of them and is
# reported as wired. An indented occurrence is not, so it never pads the
# competing-imports count; it is named as indentation when it is all the file
# has, and mentioned as context beside a working import otherwise. An @import
# inside a fenced code block is a documentation example and counts for nothing.
#
# Exit status follows the verdict alone: 0 when exactly one import loads and
# reaches the style file, and non-zero for every other state, because every
# other state needs a human to act. Both modes therefore exit the same way on
# the same memory file, including on a fresh machine, where nothing is wired yet
# and the default mode exits non-zero while printing the line and the file to
# put it in. That first run is phrased as the step to take rather than as a
# failure, and the exit status is stated here rather than in what it prints.
#
# Every state offers exactly one remedy, because two would let an operator
# follow both and end with competing imports. The paste block is offered where
# the file holds no import at all; an indented occurrence is shown beside the
# column-zero form that same line should take, since the line is already there
# and only its column is wrong; the broken and ambiguous reports carry their own
# tailored replacement line; settled wiring is offered nothing. An unreadable
# memory file is the one place the modes differ in how much they say: neither
# printed value needs that file read, so the default mode still supplies them,
# while --check refuses to advise on a file it could not measure.
#
# A checkout missing its own copy of the style file is reported where that
# changes the advice - beside an import line this checkout could not supply. A
# run that ends in working wiring stays silent on stderr and exits 0, mentioning
# the local gap only as context on the note about which checkout the line
# reaches.
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

# Reduce a path to what it physically is, so two spellings of one file compare
# equal. Read-only, and no readlink -f, which macOS does not ship: the directory
# is resolved by entering it, and an unreachable one falls back to the path as
# written.
physical_path() {
  local dir base real
  case "$1" in
    */*) dir=${1%/*}; base=${1##*/} ;;
    *) dir=.; base=$1 ;;
  esac
  [ -n "$dir" ] || dir=/
  if real=$(cd "$dir" 2>/dev/null && pwd -P); then
    printf '%s\n' "${real%/}/$base"
  else
    printf '%s\n' "$1"
  fi
}

# Every import of this style file, whatever path form it uses. Leading
# whitespace is matched deliberately so an indented paste is found and named
# rather than silently reported as absent. A candidate line holds nothing but
# the import, so prose that merely quotes one is never a candidate; a line inside
# a fenced code block can hold nothing else and still be an example the loader
# does not evaluate, so fenced lines are skipped - counting one would report
# wiring that loads nothing. An unterminated fence opens a block that runs to
# end of file.
style_imports() {
  [ -f "$MEMORY_FILE" ] || return 0
  awk '
    {
      probe = $0
      sub(/\r$/, "", probe)
      marker = probe
      sub(/^[ \t]*/, "", marker)

      fence = ""
      if (marker ~ /^```/) fence = "`"
      else if (marker ~ /^~~~/) fence = "~"

      if (fence != "") {
        run = 0
        while (substr(marker, run + 1, 1) == fence) run++
        rest = substr(marker, run + 1)
        if (in_fence) {
          # A closing fence repeats the opening character, is at least as long,
          # and carries no info string; anything else is block content.
          if (fence == fence_char && run >= fence_len && rest ~ /^[ \t]*$/) in_fence = 0
        } else {
          in_fence = 1
          fence_char = fence
          fence_len = run
        }
        next
      }

      if (in_fence) next
      if (probe ~ /^[ \t]*@.*styl-kapitanski\.md[ \t]*$/) print $0
    }
  ' "$MEMORY_FILE" 2>/dev/null || true
}

instructions() {
  printf 'Add the style rules to Claude by putting this line, unindented and on its\n'
  printf 'own line, anywhere in %s:\n' "$MEMORY_FILE"
  printf '\n'
  printf '%s\n' "$IMPORT_LINE"
  printf '\n'
  printf 'Everything already in that file stays exactly as it is.\n'
  printf 'Then confirm with: %s --check\n' "$0"
}

if [ ! -f "$STYLE_ABS" ]; then
  STYLE_MISSING=1
else
  STYLE_MISSING=0
fi

# Said only where it changes what the operator is being told to do: alongside an
# import line that would name a file this checkout cannot supply. A --check that
# ends in working wiring is not such a place.
report_style_missing() {
  if [ "$STYLE_MISSING" -eq 1 ]; then
    echo "error: style file not found: $STYLE_ABS" >&2
    echo "hint: run this script from a complete firstmate checkout" >&2
  fi
}

if [ -e "$MEMORY_FILE" ] && { [ ! -f "$MEMORY_FILE" ] || [ ! -r "$MEMORY_FILE" ]; }; then
  echo "error: $MEMORY_FILE exists but could not be read" >&2
  echo "hint: fix its permissions, then re-run this script" >&2
  MEMORY_UNREADABLE=1
else
  MEMORY_UNREADABLE=0
fi

# An unreadable file is never scanned, so its imports stay unknown rather than
# being reported as none.
if [ "$MEMORY_UNREADABLE" -eq 0 ]; then
  IMPORTS=$(style_imports)
else
  IMPORTS=''
fi
# Only a column-zero occurrence loads, so the two classes decide different
# things: the loading ones decide the state, the indented ones are reported when
# they are all there is and are context otherwise.
if [ -z "$IMPORTS" ]; then
  LOADING=''
  INDENTED=''
else
  LOADING=$(printf '%s\n' "$IMPORTS" | grep -v '^[[:space:]]' || true)
  INDENTED=$(printf '%s\n' "$IMPORTS" | grep '^[[:space:]]' || true)
fi
if [ -z "$LOADING" ]; then
  LOADING_COUNT=0
else
  LOADING_COUNT=$(printf '%s\n' "$LOADING" | wc -l | tr -d ' ')
fi
if [ -z "$INDENTED" ]; then
  INDENTED_COUNT=0
else
  INDENTED_COUNT=$(printf '%s\n' "$INDENTED" | wc -l | tr -d ' ')
fi

# The one loading line, resolved once. Whitespace after the path - including the
# CR a CRLF editor leaves - does not stop the loader, and is trimmed before
# resolving.
FOUND=''
TARGET=''
if [ "$LOADING_COUNT" -eq 1 ]; then
  FOUND=$(printf '%s\n' "$LOADING" | sed 's/[[:space:]]*$//')
  TARGET=$(resolve_import "${FOUND#@}")
fi

# What is true about the memory file is decided here, once, for every mode. A
# mode chooses how much of the verdict to print and on which stream; it decides
# nothing about the verdict itself, and the exit status follows the verdict
# alone, so no two modes can report one file differently.
classify_memory() {
  if [ "$MEMORY_UNREADABLE" -eq 1 ]; then
    printf 'unreadable\n'
  elif [ ! -e "$MEMORY_FILE" ]; then
    printf 'absent\n'
  elif [ "$LOADING_COUNT" -gt 1 ]; then
    printf 'ambiguous\n'
  elif [ "$LOADING_COUNT" -eq 1 ]; then
    if [ -f "$TARGET" ]; then
      printf 'wired\n'
    else
      printf 'broken\n'
    fi
  elif [ "$INDENTED_COUNT" -ge 1 ]; then
    printf 'indented\n'
  else
    printf 'not-wired\n'
  fi
}

VERDICT=$(classify_memory)
if [ "$VERDICT" = wired ]; then
  STATUS=0
else
  STATUS=1
fi

# Context beside working wiring, never a verdict: these lines change neither the
# outcome nor the exit status. Which checkout the line names is a question about
# the file it reaches, not about how the path is spelled, so the ~/-relative and
# absolute forms of one file are the same target and get no note.
report_working_notes() {
  if [ "$INDENTED_COUNT" -ge 1 ]; then
    echo "note: $MEMORY_FILE also holds indented occurrences of the import, which do not load:"
    printf '%s\n' "$INDENTED" | sed 's/^/  /'
  fi
  if [ "$(physical_path "$TARGET")" != "$(physical_path "$STYLE_ABS")" ]; then
    if [ "$STYLE_MISSING" -eq 0 ]; then
      echo "note: that line points at a different checkout than this one; this checkout would use $IMPORT_LINE"
    else
      echo "note: that line points at a different checkout than this one, which has no $STYLE_REL to offer"
    fi
  fi
}

# The diagnosis, said the same way in every mode: settled wiring is the answer
# and goes to stdout, and every state that needs a human is a diagnostic and
# goes to stderr.
report_verdict() {
  case "$VERDICT" in
    unreadable)
      # Already named on stderr where the file was found unreadable.
      ;;
    absent)
      # The default mode answers a first run with the step to take, not with a
      # verdict label; --check is the mode asked for the label.
      [ "$MODE" = print ] || echo "captain-style: NOT WIRED  $MEMORY_FILE does not exist" >&2
      ;;
    not-wired)
      [ "$MODE" = print ] || echo "captain-style: NOT WIRED  no import of the style file in $MEMORY_FILE" >&2
      ;;
    indented)
      echo "captain-style: INDENTED  the import line in $MEMORY_FILE does not start at column zero:" >&2
      printf '%s\n' "$INDENTED" |
        awk '{ shape = $0; sub(/^[ \t]*/, "", shape); printf "  found:  %s\n  needed: %s\n", $0, shape }' >&2
      echo "hint: strip the leading whitespace from that line so it begins with @" >&2
      echo "hint: nothing has to be added, and adding a second copy would leave two competing imports" >&2
      ;;
    ambiguous)
      echo "captain-style: AMBIGUOUS  $MEMORY_FILE has $LOADING_COUNT imports of the style file:" >&2
      printf '%s\n' "$LOADING" | sed 's/^/  /' >&2
      echo "hint: keep exactly one of them and delete the rest" >&2
      if [ "$STYLE_MISSING" -eq 0 ]; then
        echo "hint: this checkout would use:" >&2
        printf '  %s\n' "$IMPORT_LINE" >&2
      fi
      ;;
    broken)
      echo "captain-style: BROKEN  the import in $MEMORY_FILE reaches nothing:" >&2
      echo "  import=$FOUND  resolves=$TARGET (missing)" >&2
      if [ "$STYLE_MISSING" -eq 0 ]; then
        echo "hint: the style file moved; replace that line in $MEMORY_FILE with:" >&2
        printf '  %s\n' "$IMPORT_LINE" >&2
      else
        # Pointing at this checkout's own copy would name a file that is equally
        # absent, so say what is actually wrong instead of advising a dead path.
        echo "hint: $STYLE_ABS is missing too, so this checkout cannot supply the" >&2
        echo "      style file; restore it, or re-run from a complete checkout" >&2
      fi
      ;;
    wired)
      echo "captain-style: wired  import=$FOUND  resolves=$TARGET"
      report_working_notes
      ;;
  esac
}

# What the operator does next, which is the only thing a mode may vary: the
# default mode is asked which line to paste and which file to paste it into, so
# it answers on stdout, while --check keeps every unsettled report on stderr.
# The broken and ambiguous reports carry their own tailored replacement line and
# do not repeat this block.
offer_next_step() {
  case "$VERDICT" in
    wired)
      if [ "$MODE" = print ]; then
        printf 'Nothing to paste and nothing to change: that import is already in %s.\n' "$MEMORY_FILE"
        printf 'Re-check it at any time with: %s --check\n' "$0"
      fi
      return 0
      ;;
    absent|not-wired) ;;
    unreadable)
      # Neither printed value needs the memory file read, so the default mode
      # still supplies them; --check refuses to advise on a file it could not
      # measure.
      [ "$MODE" = print ] || return 0
      ;;
    # The indented, broken and ambiguous states already hold the line; each
    # carries its own single remedy, and repeating this block beside one would
    # offer a second, competing import.
    *) return 0 ;;
  esac
  report_style_missing
  if [ "$MODE" = check ]; then
    instructions >&2
  else
    instructions
  fi
}

report_verdict
offer_next_step
exit "$STATUS"
