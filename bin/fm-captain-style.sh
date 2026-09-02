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
# Every state that needs a human prints exactly one remedy, and that remedy is
# derived from the state the file has to end in rather than from the shape of
# whatever was found: one import of the style file, at column zero, naming a
# style file that exists. Carrying out its printed steps literally lands on the
# wired verdict from every state, which is what stops a remedy from being right
# for the common case and wrong for a stale path, a second indented copy, or a
# checkout with no style file of its own. Settled wiring is given no remedy at
# all, and an unreadable file is given the single step that makes it measurable,
# because nothing else about it can be decided.
#
# The steps are operations - restore file, create file, make readable, remove
# line, append line at end of file - and every step that acts on a line names it
# by number rather than by its content, because two occurrences can be the same
# bytes and a content-named removal would take both. Line numbers are the ones
# the file had when the run read it, so removals are printed from the highest
# down: carried out in printed order, no step shifts a number a later step still
# depends on.
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
      # The line number travels with the line, tab-separated: a repair step has
      # to name which line it acts on, and two occurrences can be identical.
      if (probe ~ /^[ \t]*@.*styl-kapitanski\.md[ \t]*$/) printf "%d\t%s\n", NR, $0
    }
  ' "$MEMORY_FILE" 2>/dev/null || true
}

# The line number and the line itself, split on the first tab only, so a
# tab-indented occurrence keeps its indentation intact.
occurrence_number() {
  awk '{ print substr($0, 1, index($0, "\t") - 1) }'
}

occurrence_text() {
  awk '{ print substr($0, index($0, "\t") + 1) }'
}

# How an occurrence is shown wherever it is named, verdict or repair step.
show_occurrences() {
  awk -v prefix="$1" '
    {
      tab = index($0, "\t")
      printf "  %s line %s: %s\n", prefix, substr($0, 1, tab - 1), substr($0, tab + 1)
    }
  '
}

if [ ! -f "$STYLE_ABS" ]; then
  STYLE_MISSING=1
else
  STYLE_MISSING=0
fi

if [ -e "$MEMORY_FILE" ] && { [ ! -f "$MEMORY_FILE" ] || [ ! -r "$MEMORY_FILE" ]; }; then
  echo "error: $MEMORY_FILE exists but could not be read" >&2
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
  LOADING=$(printf '%s\n' "$IMPORTS" | awk 'substr($0, index($0, "\t") + 1) !~ /^[ \t]/')
  INDENTED=$(printf '%s\n' "$IMPORTS" | awk 'substr($0, index($0, "\t") + 1) ~ /^[ \t]/')
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
FOUND_LINE=''
TARGET=''
if [ "$LOADING_COUNT" -eq 1 ]; then
  FOUND=$(printf '%s\n' "$LOADING" | occurrence_text | sed 's/[[:space:]]*$//')
  FOUND_LINE=$(printf '%s\n' "$LOADING" | occurrence_number)
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
    printf '%s\n' "$INDENTED" | show_occurrences found
  fi
  if [ "$(physical_path "$TARGET")" != "$(physical_path "$STYLE_ABS")" ]; then
    if [ "$STYLE_MISSING" -eq 0 ]; then
      echo "note: that line points at a different checkout than this one; this checkout would use $IMPORT_LINE"
    else
      echo "note: that line points at a different checkout than this one, which has no $STYLE_REL to offer"
    fi
  fi
}

# The diagnosis: what the file holds, said the same way in every mode. Settled
# wiring is the answer and goes to stdout, and every state that needs a human is
# a diagnostic and goes to stderr.
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
      echo "captain-style: INDENTED  no import in $MEMORY_FILE starts at column zero:" >&2
      printf '%s\n' "$INDENTED" | show_occurrences found >&2
      ;;
    ambiguous)
      echo "captain-style: AMBIGUOUS  $MEMORY_FILE has $LOADING_COUNT imports of the style file:" >&2
      printf '%s\n' "$LOADING" | show_occurrences found >&2
      ;;
    broken)
      echo "captain-style: BROKEN  the import in $MEMORY_FILE reaches nothing:" >&2
      echo "  found line $FOUND_LINE: $FOUND  resolves=$TARGET (missing)" >&2
      ;;
    wired)
      echo "captain-style: wired  import=$FOUND  resolves=$TARGET"
      report_working_notes
      ;;
  esac
}

# The remedy, and there is only ever one: it is derived from the state the file
# has to end in, never from the shape of whatever line was found, so carrying
# out its steps literally leaves the file wired from any state. That target is
# one import of the style file, at column zero, naming a style file that exists,
# which is reached by removing the occurrences that are not it and adding the
# line this checkout would use. An unmeasurable file gets the one step that
# makes it measurable, because nothing else about it can be decided.
#
# A step that acts on a line names it by number, never by its content: two
# occurrences can be the same bytes, and an instruction that says which text to
# remove would then delete both and leave the file holding none. Removals are
# printed from the highest line number down, so carrying the list out in the
# order it is printed never shifts a number a later step still depends on.
report_remedy() {
  local keeper
  if [ "$VERDICT" = unreadable ]; then
    printf 'remedy: make %s readable, then run this again, because nothing about\n' "$MEMORY_FILE"
    printf 'what it holds can be decided until then.\n'
    printf '  make readable: %s\n' "$MEMORY_FILE"
    printf 'note: the line this checkout would use is %s\n' "$IMPORT_LINE"
    return 0
  fi
  case "$VERDICT" in
    absent)
      printf 'Add the style rules to Claude: %s does not exist yet, so create it,\n' "$MEMORY_FILE"
      printf 'along with the directory holding it, containing this one line.\n'
      ;;
    not-wired)
      printf 'Add the style rules to Claude by putting this line in %s,\n' "$MEMORY_FILE"
      printf 'unindented and on its own line.\n'
      ;;
    *)
      printf 'remedy: leave %s holding exactly one import of the style file, at\n' "$MEMORY_FILE"
      printf 'column zero, by carrying out these steps in the order they are printed.\n'
      ;;
  esac
  # A line naming this checkout reaches nothing while this checkout has no copy
  # of the style file, so restoring it comes before anything written down.
  if [ "$STYLE_MISSING" -eq 1 ]; then
    printf '  restore file: %s\n' "$STYLE_ABS"
  fi
  if [ "$VERDICT" = absent ]; then
    printf '  create file: %s\n' "$MEMORY_FILE"
  fi
  # An occurrence that is already the line this checkout would use, at column
  # zero, is the one to keep: removing it and adding it back would be a pair of
  # steps whose order decides whether the file ends up wired.
  keeper=0
  if [ -n "$IMPORTS" ] && printf '%s\n' "$IMPORTS" | occurrence_text | grep -qxF "$IMPORT_LINE"; then
    keeper=1
  fi
  if [ -n "$IMPORTS" ]; then
    printf '%s\n' "$IMPORTS" | awk -v keep="$IMPORT_LINE" -v has="$keeper" '
      {
        tab = index($0, "\t")
        count++
        num[count] = substr($0, 1, tab - 1)
        text[count] = substr($0, tab + 1)
        same[text[count]]++
      }
      END {
        kept = 0
        if (has == 1) {
          for (i = 1; i <= count; i++) {
            if (text[i] == keep) { kept = i; break }
          }
        }
        for (i = count; i >= 1; i--) {
          if (i == kept) continue
          note = ""
          if (same[text[i]] > 1) {
            note = sprintf("  (one of %d identical occurrences)", same[text[i]])
          }
          printf "  remove line %s: %s%s\n", num[i], text[i], note
        }
      }
    '
  fi
  if [ "$keeper" -eq 0 ]; then
    printf '  append line at end of file: %s\n' "$IMPORT_LINE"
  fi
  if [ "$VERDICT" != absent ]; then
    printf 'Everything else in that file stays exactly as it is.\n'
  fi
  printf 'Then confirm with: %s --check\n' "$0"
}

report_verdict
# The mode decides where the remedy goes and whether settled wiring gets a
# closing word, never what the remedy is.
if [ "$VERDICT" = wired ]; then
  if [ "$MODE" = print ]; then
    printf 'Nothing to paste and nothing to change: that import is already in %s.\n' "$MEMORY_FILE"
    printf 'Re-check it at any time with: %s --check\n' "$0"
  fi
elif [ "$MODE" = check ]; then
  report_remedy >&2
else
  report_remedy
fi
exit "$STATUS"
