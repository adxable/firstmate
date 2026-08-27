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
# than appending a second one. When the memory file cannot be read, nothing is
# written at all; when it cannot be written, the exact import line and target
# file are printed as an explicit manual step. Neither case is skipped quietly.
#
# The pre-installer wiring - a bare "# Styl odpowiedzi" heading plus one
# machine-specific @import of the same style file - is replaced rather than
# left beside the managed block, and the heading goes with it when the removal
# leaves it with no body of its own.
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
# import of this same style file removed. A "# Styl odpowiedzi" heading that the
# removal leaves with no body of its own goes too, so the pre-installer layout
# does not survive as an empty duplicate section. Trailing blank lines are
# trimmed so repeated runs converge instead of growing the file.
#
# Returns non-zero when the memory file exists but cannot be read or parsed. An
# empty stdout means "there is nothing to keep" only when this succeeds; every
# caller must check, or an unreadable file reads as an empty one and its content
# is lost on the next write.
strip_managed() {
  if [ ! -e "$MEMORY_FILE" ]; then
    return 0
  fi
  [ -f "$MEMORY_FILE" ] && [ -r "$MEMORY_FILE" ] || return 1
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock { next }
    # The pre-installer wiring was a bare heading plus one absolute @import.
    /^@.*\/docs\/styl-kapitanski\.md[[:space:]]*$/ { cut[n] = 1; next }
    { out[++n] = $0 }
    END {
      # A legacy import removed after out[p] orphans the heading above it only
      # when nothing but blank lines separated them and nothing but blank lines
      # follows before the next heading or the end of the file.
      for (p in cut) {
        h = p + 0
        while (h > 0 && out[h] ~ /^[[:space:]]*$/) h--
        if (h == 0 || out[h] !~ /^#+[[:space:]]*Styl odpowiedzi[[:space:]]*$/) continue
        j = p + 1
        while (j <= n && out[j] ~ /^[[:space:]]*$/) j++
        if (j <= n && out[j] !~ /^#/) continue
        for (k = h; k <= p; k++) drop[k] = 1
      }
      last = n
      while (last > 0 && (out[last] ~ /^[[:space:]]*$/ || (last in drop))) last--
      for (k = 1; k <= last; k++) {
        if (!(k in drop)) print out[k]
      }
    }
  ' "$MEMORY_FILE"
}

legacy_lines() {
  [ -e "$MEMORY_FILE" ] || return 0
  [ -f "$MEMORY_FILE" ] && [ -r "$MEMORY_FILE" ] || return 1
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

# Refusing here keeps the "preserved byte for byte" promise: an existing memory
# file this run cannot read is a file whose content this run cannot carry over,
# so it is left exactly as it is and nothing is written anywhere.
memory_unreadable() {
  cat >&2 <<EOF
error: $MEMORY_FILE exists but could not be read

Nothing was written and the existing file is untouched, because its content
cannot be carried over into the new memory file.

Fix its permissions and re-run, or wire the rules by hand:

  1. Make $MEMORY_FILE readable and writable, then re-run: $0
  2. Or add these lines to it yourself:

$(render_block | sed 's/^/     /')

  3. Confirm with: $0 --verify
EOF
  exit 1
}

if [ -e "$MEMORY_FILE" ] && { [ ! -f "$MEMORY_FILE" ] || [ ! -r "$MEMORY_FILE" ]; }; then
  memory_unreadable
fi

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

REMOVED_LEGACY=$(legacy_lines) || memory_unreadable

report_removed_legacy() {
  local label=$1 l
  [ -n "$REMOVED_LEGACY" ] || return 0
  printf '%s\n' "$REMOVED_LEGACY" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "captain-style: $label legacy import: $l"
  done
}

# Kept out of the redirected group below so a read failure is reported and
# refused, never captured as an empty body that then overwrites the file.
BODY=$(strip_managed) || memory_unreadable

if [ "$MODE" = uninstall ]; then
  if [ -n "$BODY" ]; then
    printf '%s\n' "$BODY" >"$TMP" 2>/dev/null || manual_fallback
    mv "$TMP" "$MEMORY_FILE" 2>/dev/null || manual_fallback
  else
    rm -f "$TMP"
    rm -f "$MEMORY_FILE" 2>/dev/null || manual_fallback
  fi
  trap - EXIT
  # --uninstall unwires completely, legacy lines included. Say which ones went,
  # so removing content this script never wrote is never silent.
  report_removed_legacy removed
  echo "captain-style: removed from $MEMORY_FILE"
  exit 0
fi

{
  if [ -n "$BODY" ]; then
    printf '%s\n\n' "$BODY"
  fi
  render_block
} >"$TMP" 2>/dev/null || manual_fallback

mv "$TMP" "$MEMORY_FILE" 2>/dev/null || manual_fallback
trap - EXIT

report_removed_legacy replaced
report_status
