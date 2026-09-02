#!/usr/bin/env bash
# Behavior tests for bin/fm-captain-style.sh.
#
# The script prints the wiring a human pastes in and never writes to the memory
# file, so these cases assert two things: the printed values are correct for the
# machine they were computed on, and every run leaves the memory file untouched
# byte for byte. Every case runs against a throwaway HOME and CLAUDE_CONFIG_DIR,
# so the machine's real user-level memory file is never read or written.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-style)

SCRIPT="$ROOT/bin/fm-captain-style.sh"

# Build a self-contained fake checkout so a case can place the style file
# inside or outside the fake HOME and observe which import form is printed.
make_checkout() {
  local dest=$1
  mkdir -p "$dest/bin" "$dest/docs"
  cp "$SCRIPT" "$dest/bin/fm-captain-style.sh"
  chmod +x "$dest/bin/fm-captain-style.sh"
  printf '# Captain-Facing Communication Contract\n\nAnswer the captain in Polish.\n' \
    >"$dest/docs/styl-kapitanski.md"
}

# Combined streams: what an operator sees in a terminal.
run_style() {
  local checkout=$1 home=$2
  shift 2
  env HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    "$checkout/bin/fm-captain-style.sh" "$@" 2>&1
}

# Streams kept apart, so a case can tell a success line on stdout from a
# diagnostic on stderr.
run_style_split() {
  local checkout=$1 home=$2 errfile=$3
  shift 3
  env HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    "$checkout/bin/fm-captain-style.sh" "$@" 2>"$errfile"
}

# The script reports physically resolved paths, which differ from the fixture
# path whenever the temp root sits behind a symlink (/tmp on macOS).
real_dir() {
  (cd "$1" && pwd -P)
}

# A byte-exact copy of the memory file, taken before the run. Capturing the
# content with command substitution would strip trailing newlines, so a run that
# appended a blank line or dropped the final newline would compare equal.
SNAPSHOT_DIR="$TMP_ROOT/snapshots"
mkdir -p "$SNAPSHOT_DIR"
SNAPSHOT_SEQ=0
snapshot_file() {
  local dest
  SNAPSHOT_SEQ=$((SNAPSHOT_SEQ + 1))
  dest="$SNAPSHOT_DIR/snapshot-$SNAPSHOT_SEQ"
  cp "$1" "$dest" || fail "could not snapshot $1"
  printf '%s\n' "$dest"
}

# The installer used to own this file. Nothing does now, so every case that
# touches a memory file pins that it came back unchanged.
assert_memory_untouched() {
  local file=$1 before=$2 label=$3
  cmp -s "$file" "$before" || fail "$label: the run modified $file"
}

# The wiring a human is told to paste must be usable exactly as printed. This
# is the round trip the whole script exists for.
test_printed_line_pasted_verbatim_verifies() {
  local home checkout memory line out
  home="$TMP_ROOT/verbatim/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  printf '# My own notes\n\nKeep me.\n' >"$memory"

  line=$(run_style "$checkout" "$home" --print-import) || fail "--print-import failed: $line"
  # Paste it the way an operator would: appended, unmodified.
  printf '%s\n' "$line" >>"$memory"

  out=$(run_style "$checkout" "$home" --check) || fail "--check rejected its own printed line: $out"
  assert_contains "$out" "wired" "--check did not report the pasted line as wired"
  assert_grep 'Keep me.' "$memory" "the operator's own content disappeared"
  pass "fm-captain-style.sh: the printed line verifies after a verbatim paste"
}

test_checkout_inside_home_prints_home_relative_import() {
  local home checkout out rc
  home="$TMP_ROOT/inside/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"

  out=$(run_style "$checkout" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "print mode exited 0 on a machine with nothing wired: $out"
  assert_contains "$out" '@~/src/firstmate/docs/styl-kapitanski.md' \
    "a checkout under HOME did not get a home-relative import line"
  assert_not_contains "$out" "$home/src/firstmate/docs" \
    "the printed line hardcoded this machine's absolute home path"
  assert_contains "$out" "$home/.claude/CLAUDE.md" \
    "print mode did not name the file to paste into"
  pass "fm-captain-style.sh: a checkout under HOME gets a home-relative import"
}

test_checkout_outside_home_prints_absolute_import() {
  local home checkout real out rc
  home="$TMP_ROOT/outside/home"
  checkout="$TMP_ROOT/outside/opt/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  real=$(cd "$checkout" && pwd -P)

  out=$(run_style "$checkout" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "print mode exited 0 on a machine with nothing wired: $out"
  assert_contains "$out" "@$real/docs/styl-kapitanski.md" \
    "a checkout outside HOME did not fall back to an absolute import"
  pass "fm-captain-style.sh: a checkout outside HOME falls back to an absolute import"
}

# The point of the home-relative form: the same pasted line keeps resolving
# when the home directory itself is renamed or moved.
test_home_relative_import_survives_a_relocated_home() {
  local home checkout memory line moved out
  home="$TMP_ROOT/relocate/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n' "$line" >"$memory"

  moved="$TMP_ROOT/relocate/other-user"
  mv "$home" "$moved"

  out=$(run_style "$moved/src/firstmate" "$moved" --check) \
    || fail "the pasted line stopped resolving after the home moved: $out"
  assert_contains "$out" "wired" "--check did not confirm the relocated wiring"
  assert_contains "$out" "$(real_dir "$moved")/src/firstmate/docs/styl-kapitanski.md" \
    "--check did not resolve the import against the new home"
  pass "fm-captain-style.sh: the pasted import still resolves after HOME moves"
}

# Counterfactual for the case above: the check must actually be able to fail,
# or its success proves nothing.
test_check_reports_a_broken_import_and_names_the_replacement() {
  local home checkout memory line out rc
  home="$TMP_ROOT/broken/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n' "$line" >"$memory"
  mv "$checkout" "$home/src/firstmate-moved"

  out=$(run_style "$home/src/firstmate-moved" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported success for a dangling import: $out"
  assert_contains "$out" "BROKEN" "--check did not report the dangling import"
  assert_contains "$out" '@~/src/firstmate-moved/docs/styl-kapitanski.md' \
    "--check did not name the line that would fix the wiring"
  pass "fm-captain-style.sh: --check reports a dangling import and names the fix"
}

test_check_reports_a_missing_import_and_prints_the_instructions() {
  local home checkout memory before out rc
  home="$TMP_ROOT/missing/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  printf '# Only my own notes\n' >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported success with no import present: $out"
  assert_contains "$out" "NOT WIRED" "--check did not report the missing import"
  assert_contains "$out" '@~/src/firstmate/docs/styl-kapitanski.md' \
    "--check did not print the line to paste"
  assert_memory_untouched "$memory" "$before" "check-missing"
  pass "fm-captain-style.sh: --check reports a missing import and prints what to paste"
}

test_check_reports_an_absent_memory_file() {
  local home checkout out rc
  home="$TMP_ROOT/nofile/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported success with no memory file: $out"
  assert_contains "$out" "NOT WIRED" "--check did not report the absent memory file"
  assert_absent "$home/.claude/CLAUDE.md" "--check created the memory file"
  pass "fm-captain-style.sh: --check reports an absent memory file without creating it"
}

# An indented paste is the failure the previous marker-based design misreported
# as "not installed". It has to be named for what it is.
test_an_indented_import_is_diagnosed_as_indentation() {
  local home checkout memory line before out rc
  home="$TMP_ROOT/indented/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '# notes\n    %s\n' "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check accepted an indented import: $out"
  assert_contains "$out" "INDENTED" "--check did not name indentation as the problem"
  assert_not_contains "$out" "NOT WIRED" "--check misreported an indented line as absent"
  assert_memory_untouched "$memory" "$before" "indented"
  pass "fm-captain-style.sh: an indented import is diagnosed as indentation"
}

# Trailing whitespace does not stop the loader from following the import, so it
# must not be reported as the one thing that does: indentation.
test_a_trailing_space_is_not_reported_as_indentation() {
  local home checkout memory line before out
  home="$TMP_ROOT/trailing/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s \n' "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home" --check) \
    || fail "--check rejected a wired line carrying one trailing space: $out"
  assert_contains "$out" "wired" "--check did not report the trailing-space line as wired"
  assert_not_contains "$out" "INDENTED" "trailing whitespace was misreported as indentation"
  assert_memory_untouched "$memory" "$before" "trailing-space"
  pass "fm-captain-style.sh: a trailing space leaves a wired import wired"
}

# Same reasoning for the CR a CRLF editor leaves at the end of the line.
test_a_cr_terminated_import_is_reported_as_wired() {
  local home checkout memory line before out
  home="$TMP_ROOT/crlf/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\r\n' "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home" --check) \
    || fail "--check rejected a CR-terminated wired line: $out"
  assert_contains "$out" "wired" "--check did not report the CR-terminated line as wired"
  assert_not_contains "$out" "INDENTED" "a CR was misreported as indentation"
  assert_contains "$out" "$(real_dir "$checkout")/docs/styl-kapitanski.md" \
    "--check resolved the CR-terminated line to something other than the style file"
  assert_memory_untouched "$memory" "$before" "crlf"
  pass "fm-captain-style.sh: a CR-terminated import is wired, not indented"
}

# The ~/-relative and absolute spellings of one file are one target, so only a
# line reaching a different file earns the different-checkout note.
test_the_different_checkout_note_follows_the_target_not_the_spelling() {
  local home checkout other memory out
  home="$TMP_ROOT/spelling/home"
  checkout="$home/src/firstmate"
  other="$home/src/other-firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  make_checkout "$other"
  memory="$home/.claude/CLAUDE.md"

  printf '@%s/docs/styl-kapitanski.md\n' "$(real_dir "$checkout")" >"$memory"
  out=$(run_style "$checkout" "$home" --check) \
    || fail "--check rejected an absolute import of this very checkout: $out"
  assert_contains "$out" "wired" "--check did not report the absolute-form line as wired"
  assert_not_contains "$out" "different checkout" \
    "an absolute import of this checkout was annotated as another checkout"

  printf '@~/src/other-firstmate/docs/styl-kapitanski.md\n' >"$memory"
  out=$(run_style "$checkout" "$home" --check) \
    || fail "--check rejected a working import of another checkout: $out"
  assert_contains "$out" "wired" "--check did not report the other checkout's line as wired"
  assert_contains "$out" "different checkout" \
    "--check stayed silent about a line reaching a different checkout"
  pass "fm-captain-style.sh: the different-checkout note follows the resolved target"
}

# Computing the line and the path to paste it into reads nothing, so bad
# permissions on the memory file must not cost the operator the instructions.
test_an_unreadable_memory_file_still_prints_the_wiring() {
  local home checkout memory out rc prc
  if [ "$(id -u)" = "0" ]; then
    pass "fm-captain-style.sh: unreadable memory file (skipped: root reads anything)"
    return 0
  fi
  home="$TMP_ROOT/unreadable/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  printf '# My own notes\n' >"$memory"
  chmod 000 "$memory"

  out=$(run_style "$checkout" "$home")
  prc=$?
  [ "$prc" -ne 0 ] || fail "print mode exited 0 on a memory file it could not read: $out"
  assert_contains "$out" '@~/src/firstmate/docs/styl-kapitanski.md' \
    "print mode withheld the import line over a permissions problem"
  assert_contains "$out" "$memory" "print mode withheld the file to paste into"
  assert_contains "$out" "could not be read" "print mode hid the permissions problem"

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported on a memory file it could not read: $out"
  expect_code "$rc" "$prc" "default mode and --check on an unreadable memory file"
  assert_not_contains "$out" "NOT WIRED" \
    "--check treated an unreadable memory file as one with no import"
  chmod 600 "$memory"
  assert_grep '# My own notes' "$memory" "the runs modified the unreadable memory file"
  pass "fm-captain-style.sh: an unreadable memory file still yields the wiring, and --check refuses"
}

# Measured on Claude Code 2.1.247: an import fenced in ``` is not followed, and
# unfencing the same line in the same directory makes it load. So a fenced line
# is a documentation example, and reporting it as wiring would manufacture the
# silent non-loading this script exists to expose.
test_a_fenced_import_is_not_wiring() {
  local home checkout memory line out rc
  home="$TMP_ROOT/fenced/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  # shellcheck disable=SC2016 # Literal markdown fences, not an expansion.
  printf '# how to wire it\n\n```\n%s\n```\n' "$line" >"$memory"

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported a fenced example as wiring: $out"
  assert_contains "$out" "NOT WIRED" "--check did not report the fenced-only file as unwired"
  pass "fm-captain-style.sh: an import inside a code fence is not wiring"
}

# The compound case: a documentation example beside the real thing must not
# turn one working import into two competing ones.
test_a_fenced_example_does_not_compete_with_a_real_import() {
  local home checkout memory line out
  home="$TMP_ROOT/fenced-plus/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  # shellcheck disable=SC2016 # Literal markdown fences, not an expansion.
  printf 'For example:\n\n```text\n%s\n```\n\n%s\n' "$line" "$line" >"$memory"

  out=$(run_style "$checkout" "$home" --check) \
    || fail "--check rejected a real import sitting beside a fenced example: $out"
  assert_contains "$out" "wired" "--check did not report the real import as wired"
  assert_not_contains "$out" "AMBIGUOUS" "a fenced example was counted as a competing import"
  pass "fm-captain-style.sh: a fenced example does not compete with a real import"
}

# Same treatment for a ~~~ fence.
test_tilde_fences_are_not_wiring() {
  local home checkout memory line out rc
  home="$TMP_ROOT/fence-forms/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)

  printf '~~~\n%s\n~~~\n' "$line" >"$memory"
  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported a ~~~-fenced example as wiring: $out"
  assert_contains "$out" "NOT WIRED" "a tilde fence was not treated like a backtick fence"
  pass "fm-captain-style.sh: a tilde fence is an example, not wiring"
}

# An unterminated fence has no closing line to guess at, so it opens a block
# that runs to end of file - and must not swallow what came before it.
test_an_unterminated_fence_runs_to_end_of_file() {
  local home checkout memory line out
  home="$TMP_ROOT/unterminated/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n\n```\n%s\n' "$line" "$line" >"$memory"

  out=$(run_style "$checkout" "$home" --check) \
    || fail "--check lost a real import sitting above an unterminated fence: $out"
  assert_contains "$out" "wired" "--check did not see the import above the unterminated fence"
  assert_not_contains "$out" "AMBIGUOUS" \
    "an example below an unterminated fence was counted as a second import"
  pass "fm-captain-style.sh: an unterminated fence runs to end of file"
}

# Measured on Claude Code 2.1.247: an import indented by four spaces or by a tab
# is not followed, while the same line at column zero is. A stray indented copy
# therefore competes with nothing, and must not turn a loading file into a
# failure whose hint would have the operator keep the copy that does not load.
test_an_indented_copy_does_not_compete_with_a_loading_import() {
  local home checkout memory line before errfile out rc
  home="$TMP_ROOT/indented-copy/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  errfile="$TMP_ROOT/indented-copy/err"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n\n# an old note\n\t%s\n' "$line" "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style_split "$checkout" "$home" "$errfile" --check)
  rc=$?
  expect_code 0 "$rc" "a loading import beside an indented copy"
  assert_contains "$out" "wired" "--check did not report the column-zero import as wired"
  assert_not_contains "$out" "AMBIGUOUS" "an indented copy was counted as a competing import"
  assert_contains "$out" "do not load" "--check did not mention the indented copy at all"
  [ ! -s "$errfile" ] || fail "a healthy --check wrote to stderr: $(cat "$errfile")"
  assert_memory_untouched "$memory" "$before" "indented-copy"
  pass "fm-captain-style.sh: an indented copy is context, not a competing import"
}

# The two rules meet: with the only column-zero occurrence fenced away, what is
# left is an indented line, and the verdict must be that one condition rather
# than a mix of both.
test_a_fenced_import_and_an_indented_one_agree_on_one_verdict() {
  local home checkout memory line out rc
  home="$TMP_ROOT/fence-indent/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  # shellcheck disable=SC2016 # Literal markdown fences, not an expansion.
  printf '```\n%s\n```\n\n    %s\n' "$line" "$line" >"$memory"

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported a fenced plus indented file as wiring: $out"
  assert_contains "$out" "INDENTED" "--check did not name the one condition the file has"
  assert_not_contains "$out" "AMBIGUOUS" "a fenced example padded the count beside an indented line"
  assert_not_contains "$out" "wired" "--check called a file with no loading import wired"
  pass "fm-captain-style.sh: a fenced and an indented occurrence give one verdict"
}

# Print mode against a file that is already wired: printing the paste
# instructions here would walk the operator into a second column-zero import,
# which is exactly the AMBIGUOUS state --check reports.
test_print_mode_asks_for_no_paste_when_the_import_is_already_there() {
  local home checkout memory line before out rc check
  home="$TMP_ROOT/already-wired/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '# My own notes\n\n%s\n' "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home")
  rc=$?
  expect_code 0 "$rc" "print mode against an already-wired memory file"
  assert_contains "$out" "already in $memory" \
    "print mode did not say the import is already there"
  assert_contains "$out" "Nothing to paste" "print mode did not say nothing needs doing"
  assert_not_contains "$out" "Add the style rules" \
    "print mode told the operator to paste a second import"
  assert_not_contains "$out" "unindented and on its" \
    "print mode still printed the paste instructions"
  assert_contains "$out" "--check" "print mode did not point at --check for confirmation"
  assert_memory_untouched "$memory" "$before" "already-wired print"

  # Following that output must leave the wiring in the state --check calls
  # wired, not the ambiguous one two imports produce.
  check=$(run_style "$checkout" "$home" --check) \
    || fail "--check rejected the memory file print mode declared done: $check"
  assert_contains "$check" "wired" "--check disagreed with print mode about the wiring"
  assert_not_contains "$check" "AMBIGUOUS" "print mode left a competing import behind"
  pass "fm-captain-style.sh: print mode asks for no paste when the import is already there"
}

# The state this whole change exists for: the checkout moved, so the recorded
# import loads nothing. Default mode must not call that wiring in place, and
# must not disagree with --check about the same memory file.
test_print_mode_reports_an_import_left_behind_by_a_moved_checkout() {
  local home checkout moved memory before out rc check crc
  home="$TMP_ROOT/print-moved/home"
  checkout="$home/src/firstmate"
  moved="$home/src/firstmate-moved"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  printf '%s\n' "$(run_style "$checkout" "$home" --print-import)" >"$memory"
  mv "$checkout" "$moved"
  before=$(snapshot_file "$memory")

  out=$(run_style "$moved" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "print mode exited 0 on an import that resolves to nothing: $out"
  assert_contains "$out" "BROKEN" "print mode did not report the stale import"
  assert_not_contains "$out" "Nothing to paste" \
    "print mode called a stale import working wiring"
  assert_contains "$out" '@~/src/firstmate-moved/docs/styl-kapitanski.md' \
    "print mode did not print the line this checkout would use"
  assert_contains "$out" "$memory" \
    "the BROKEN report never named the file holding the line to replace"
  assert_memory_untouched "$memory" "$before" "print-moved"

  check=$(run_style "$moved" "$home" --check)
  crc=$?
  expect_code "$crc" "$rc" "default mode and --check on a stale import"
  assert_contains "$check" "BROKEN" "--check disagreed with print mode about the stale import"
  pass "fm-captain-style.sh: print mode reports an import a moved checkout left behind"
}

# Two loading imports are the AMBIGUOUS state, whichever mode meets them.
test_print_mode_reports_competing_imports_instead_of_declaring_done() {
  local home checkout memory line before out rc check crc
  home="$TMP_ROOT/print-ambiguous/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n@~/elsewhere/docs/styl-kapitanski.md\n' "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "print mode exited 0 with two competing imports: $out"
  assert_contains "$out" "AMBIGUOUS" "print mode did not report the competing imports"
  assert_not_contains "$out" "nothing to change" \
    "print mode declared a file with two imports settled"
  assert_contains "$out" '@~/elsewhere/docs/styl-kapitanski.md' \
    "print mode did not list the competing import"
  assert_contains "$out" "$line" "print mode did not print the line this checkout would use"
  assert_memory_untouched "$memory" "$before" "print-ambiguous"

  check=$(run_style "$checkout" "$home" --check)
  crc=$?
  expect_code "$crc" "$rc" "default mode and --check on competing imports"
  assert_contains "$check" "AMBIGUOUS" "--check disagreed with print mode about the competing imports"
  pass "fm-captain-style.sh: print mode reports competing imports instead of declaring done"
}

# An indented-only file is a broken paste, not a blank slate: the default mode
# has to name it and fail on it exactly as --check does, while still supplying
# the line to put at column zero.
test_print_mode_reports_an_indented_only_memory_file() {
  local home checkout memory line before out rc check crc
  home="$TMP_ROOT/print-indented/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '# notes\n    %s\n' "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "print mode exited 0 on a file whose only import is indented: $out"
  assert_contains "$out" "INDENTED" "print mode did not name the indented occurrence"
  assert_contains "$out" "  remove line 2:     $line" \
    "the remedy did not name the indented occurrence by its line number"
  assert_contains "$out" "  append line at end of file: $line" \
    "the remedy did not name the column-zero line to end up with"
  assert_memory_untouched "$memory" "$before" "print-indented"

  check=$(run_style "$checkout" "$home" --check)
  crc=$?
  expect_code "$crc" "$rc" "default mode and --check on an indented-only file"
  assert_contains "$check" "INDENTED" "--check disagreed with print mode about the indented line"
  assert_contains "$check" "  append line at end of file: $line" \
    "--check printed a different remedy than the default mode did"
  pass "fm-captain-style.sh: an indented-only memory file gets exactly one remedy"
}

# Carry out, mechanically, the operations a run printed, one at a time and in
# printed order. Nothing here decides what the remedy should have been, and a
# removal is applied by the line number the step names rather than by matching
# its text, which is the only way two identical occurrences can be told apart.
apply_remedy() {
  local out=$1 memory=$2
  printf '%s\n' "$out" | while IFS= read -r step; do
    case "$step" in
      '  restore file: '*|'  create file: '*)
        path=${step#*: }
        mkdir -p "$(dirname "$path")"
        [ -e "$path" ] || : >"$path"
        ;;
      '  make readable: '*)
        chmod u+rw "${step#*: }"
        ;;
      '  remove line '*)
        victim=${step#'  remove line '}
        victim=${victim%%:*}
        awk -v drop="$victim" 'NR != drop' "$memory" >"$memory.applied"
        mv "$memory.applied" "$memory"
        ;;
      '  append line at end of file: '*)
        printf '%s\n' "${step#*: }" >>"$memory"
        ;;
    esac
  done
}

# Build one memory-file state, by hand, the way an operator could have left it.
build_memory_state() {
  local state=$1 memory=$2 line=$3 checkout=$4
  case "$state" in
    absent) rm -f "$memory" ;;
    not-wired) printf '# only my own notes\n' >"$memory" ;;
    indented) printf '# notes\n    %s\n' "$line" >"$memory" ;;
    indented-stale) printf '# notes\n    @~/old-checkout/docs/styl-kapitanski.md\n' >"$memory" ;;
    two-indented) printf '    %s\n\t@~/other/docs/styl-kapitanski.md\n' "$line" >"$memory" ;;
    broken) printf '@~/gone/docs/styl-kapitanski.md\n' >"$memory" ;;
    ambiguous) printf '%s\n@~/elsewhere/docs/styl-kapitanski.md\n' "$line" >"$memory" ;;
    # The likeliest way to reach two imports: the line pasted twice. No step
    # naming content could tell these two apart.
    duplicate-identical) printf '# notes\n%s\n%s\n' "$line" "$line" >"$memory" ;;
    duplicate-identical-stale)
      printf '@~/gone/docs/styl-kapitanski.md\n@~/gone/docs/styl-kapitanski.md\n' >"$memory"
      ;;
    broken-plus-indented)
      printf '# notes\n    %s\n@~/gone/docs/styl-kapitanski.md\n' "$line" >"$memory"
      ;;
    style-missing)
      printf '# only my own notes\n' >"$memory"
      rm -f "$checkout/docs/styl-kapitanski.md"
      ;;
    unreadable)
      printf '# notes nobody may read\n' >"$memory"
      chmod 000 "$memory"
      ;;
  esac
}

# The invariant this script is held to: whatever the memory file holds, the
# operations a run prints must, carried out literally, leave it wired. Six
# earlier rounds fixed one state at a time; this fixes the rule, so a remedy
# that is right for the common case and wrong for a stale path, a second
# indented copy or a line pasted twice fails here rather than in a captain's
# terminal.
test_the_printed_remedy_reaches_wired_from_every_state() {
  local states state mode home checkout memory line out rc passes allowed
  states='absent not-wired indented indented-stale two-indented broken ambiguous'
  states="$states duplicate-identical duplicate-identical-stale"
  states="$states broken-plus-indented style-missing"
  # Root reads anything, so the unmeasurable state only exists for a normal user.
  if [ "$(id -u)" != "0" ]; then
    states="$states unreadable"
  fi

  for state in $states; do
    for mode in print check; do
      home="$TMP_ROOT/remedy/$state-$mode/home"
      checkout="$home/src/firstmate"
      mkdir -p "$home/.claude"
      make_checkout "$checkout"
      memory="$home/.claude/CLAUDE.md"
      line=$(run_style "$checkout" "$home" --print-import)
      build_memory_state "$state" "$memory" "$line" "$checkout"

      # One application of the printed list has to be enough. Only the
      # unreadable state legitimately needs a second: its one step makes the
      # file measurable, and what it holds is unknown until then.
      allowed=1
      if [ "$state" = unreadable ]; then
        allowed=2
      fi
      passes=0
      while :; do
        if [ "$mode" = print ]; then
          out=$(run_style "$checkout" "$home")
        else
          out=$(run_style "$checkout" "$home" --check)
        fi
        rc=$?
        if [ "$rc" -eq 0 ]; then
          break
        fi
        passes=$((passes + 1))
        if [ "$passes" -gt "$allowed" ]; then
          fail "$state/$mode: the printed remedy did not reach wired in $allowed pass(es): $out"
        fi
        apply_remedy "$out" "$memory"
      done

      # Both modes have to agree the file is settled, not just the one that
      # printed the remedy.
      out=$(run_style "$checkout" "$home" --check)
      rc=$?
      expect_code 0 "$rc" "$state/$mode: --check after carrying out the printed remedy"
      assert_contains "$out" "captain-style: wired" \
        "$state/$mode: the remedy left the file in some state other than wired"
      out=$(run_style "$checkout" "$home")
      rc=$?
      expect_code 0 "$rc" "$state/$mode: default mode after carrying out the printed remedy"
    done
  done
  pass "fm-captain-style.sh: the printed remedy reaches wired from every state"
}

# The parity itself, pinned state by state. One classification decides what is
# true about the memory file, so the mode that reads it cannot change the
# answer: same file, same exit status, whichever mode asked.
test_every_memory_state_gets_the_same_exit_status_from_both_modes() {
  local home checkout memory line states state before pout prc cout crc
  home="$TMP_ROOT/parity/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)

  states='absent not-wired indented broken ambiguous wired'
  # Root reads anything, so the unmeasurable state only exists for a normal user.
  if [ "$(id -u)" != "0" ]; then
    states="$states unreadable"
  fi

  for state in $states; do
    case "$state" in
      absent) rm -f "$memory" ;;
      not-wired) printf '# only my own notes\n' >"$memory" ;;
      indented) printf '# notes\n    %s\n' "$line" >"$memory" ;;
      broken) printf '@~/gone/docs/styl-kapitanski.md\n' >"$memory" ;;
      ambiguous) printf '%s\n@~/elsewhere/docs/styl-kapitanski.md\n' "$line" >"$memory" ;;
      wired) printf '%s\n' "$line" >"$memory" ;;
      unreadable) printf '# notes nobody may read\n' >"$memory" ;;
    esac
    before=''
    [ "$state" = absent ] || before=$(snapshot_file "$memory")
    if [ "$state" = unreadable ]; then
      chmod 000 "$memory"
    fi

    pout=$(run_style "$checkout" "$home")
    prc=$?
    cout=$(run_style "$checkout" "$home" --check)
    crc=$?
    if [ "$state" = unreadable ]; then
      chmod 600 "$memory"
    fi
    expect_code "$crc" "$prc" "default mode and --check on a $state memory file"
    if [ "$state" = wired ]; then
      expect_code 0 "$prc" "both modes on a correctly wired memory file"
    else
      [ "$prc" -ne 0 ] \
        || fail "both modes exited 0 on a $state memory file: $pout"
    fi
    if [ "$state" = absent ]; then
      assert_absent "$memory" "a run created the memory file in the $state case"
    else
      assert_memory_untouched "$memory" "$before" "parity $state"
    fi
    [ -n "$cout" ] || fail "--check said nothing about a $state memory file"
  done
  pass "fm-captain-style.sh: both modes return one exit status per memory state"
}

test_more_than_one_import_is_reported_as_ambiguous() {
  local home checkout memory line before out rc
  home="$TMP_ROOT/ambiguous/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n@~/elsewhere/docs/styl-kapitanski.md\n' "$line" >"$memory"
  before=$(snapshot_file "$memory")

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check accepted two competing imports: $out"
  assert_contains "$out" "AMBIGUOUS" "--check did not report competing imports"
  assert_contains "$out" '@~/elsewhere/docs/styl-kapitanski.md' \
    "--check did not list the competing import it found"
  assert_memory_untouched "$memory" "$before" "ambiguous"
  pass "fm-captain-style.sh: competing imports are reported, not silently picked"
}

# The capability that was cut. No mode may write, create, or delete anything.
test_no_mode_ever_writes_to_the_memory_file() {
  local home checkout memory before mode out
  home="$TMP_ROOT/readonly/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  printf '# My own notes\n\nKeep me.\n' >"$memory"
  before=$(snapshot_file "$memory")

  for mode in "" --check --verify --print-import --help; do
    if [ -z "$mode" ]; then
      out=$(run_style "$checkout" "$home") || true
    else
      out=$(run_style "$checkout" "$home" "$mode") || true
    fi
    assert_memory_untouched "$memory" "$before" "mode '${mode:-default}'"
  done

  # Repeat the whole sweep: still byte-identical, and no stray files appeared.
  assert_memory_untouched "$memory" "$before" "after every mode"
  [ "$(find "$home/.claude" -type f | wc -l | tr -d ' ')" = "1" ] \
    || fail "a run created extra files in the config directory"
  pass "fm-captain-style.sh: no mode writes to the memory file"
}

test_a_symlinked_memory_file_is_never_touched() {
  local home checkout link target before out
  home="$TMP_ROOT/symlink/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude" "$home/dotfiles"
  make_checkout "$checkout"
  link="$home/.claude/CLAUDE.md"
  target="$home/dotfiles/claude.md"
  printf '# Dotfiles notes\n\nKeep me.\n' >"$target"
  ln -s "$target" "$link"
  before=$(snapshot_file "$target")

  out=$(run_style "$checkout" "$home" --check) || true
  [ -L "$link" ] || fail "the memory file is no longer a symlink"
  assert_memory_untouched "$target" "$before" "symlink target"
  assert_contains "$out" "NOT WIRED" "--check did not read through the symlink"
  pass "fm-captain-style.sh: a symlinked memory file is read, never rewritten"
}

# The precondition used to run before mode dispatch, so a missing style file
# made --check refuse instead of reporting the very state it exists to report.
test_a_missing_style_file_does_not_block_the_check() {
  local home checkout memory line out rc
  home="$TMP_ROOT/nostyle/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n' "$line" >"$memory"
  rm "$checkout/docs/styl-kapitanski.md"

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported success with the style file gone: $out"
  assert_contains "$out" "BROKEN" "--check did not report the state it exists to report"
  assert_contains "$out" "  restore file: $(real_dir "$checkout")/docs/styl-kapitanski.md" \
    "the remedy named a line to add without restoring the file it would reach"
  pass "fm-captain-style.sh: a missing style file is reported, not a refusal to look"
}

# A run that ends in working wiring must not narrate an error on the way there.
# This checkout has no style file of its own, but the memory file reaches a
# complete one, so the local gap is context on the note - not a failure.
test_a_working_check_says_nothing_on_stderr() {
  local home complete bare memory errfile out rc
  home="$TMP_ROOT/quiet/home"
  complete="$home/src/firstmate"
  bare="$home/src/firstmate-bare"
  mkdir -p "$home/.claude"
  make_checkout "$complete"
  make_checkout "$bare"
  rm "$bare/docs/styl-kapitanski.md"
  memory="$home/.claude/CLAUDE.md"
  errfile="$TMP_ROOT/quiet/err"
  printf '@~/src/firstmate/docs/styl-kapitanski.md\n' >"$memory"

  out=$(run_style_split "$bare" "$home" "$errfile" --check)
  rc=$?
  expect_code 0 "$rc" "a --check that found working wiring"
  assert_contains "$out" "wired" "--check did not report the resolving import as wired"
  assert_contains "$out" "different checkout" \
    "--check did not say which checkout the working line reaches"
  [ ! -s "$errfile" ] \
    || fail "a --check that succeeded wrote to stderr: $(cat "$errfile")"
  pass "fm-captain-style.sh: a --check that succeeds writes nothing to stderr"
}

test_success_goes_to_stdout_and_diagnostics_go_to_stderr() {
  local home checkout memory line errfile out
  home="$TMP_ROOT/streams/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  errfile="$TMP_ROOT/streams/err"
  line=$(run_style "$checkout" "$home" --print-import)

  printf '%s\n' "$line" >"$memory"
  out=$(run_style_split "$checkout" "$home" "$errfile" --check) \
    || fail "--check failed on a healthy file: $out"
  assert_contains "$out" "wired" "the success line did not go to stdout"
  [ ! -s "$errfile" ] || fail "a healthy --check wrote to stderr: $(cat "$errfile")"

  printf '# nothing wired\n' >"$memory"
  out=$(run_style_split "$checkout" "$home" "$errfile" --check) || true
  [ -z "$out" ] || fail "a failing --check wrote its diagnostic to stdout: $out"
  assert_grep "NOT WIRED" "$errfile" "the failure diagnostic did not go to stderr"
  pass "fm-captain-style.sh: success on stdout, every diagnostic on stderr"
}

test_help_documents_the_modes_and_a_bad_flag_fails() {
  local home checkout errfile out rc
  home="$TMP_ROOT/help/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  errfile="$TMP_ROOT/help/err"

  out=$(run_style_split "$checkout" "$home" "$errfile" --help) || fail "--help failed"
  assert_contains "$out" "--check" "--help did not document the check mode"
  assert_contains "$out" "never writes" "--help did not state that it never writes"

  out=$(run_style_split "$checkout" "$home" "$errfile" --bogus)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown flag exited 0"
  assert_grep "usage:" "$errfile" "the usage error did not go to stderr"
  pass "fm-captain-style.sh: --help documents the modes and a bad flag fails loudly"
}

test_printed_import_matches_the_check_resolution() {
  local home checkout line out
  home="$TMP_ROOT/agree/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"

  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n' "$line" >"$home/.claude/CLAUDE.md"
  out=$(run_style "$checkout" "$home" --check) || fail "--check disagreed with --print-import: $out"
  assert_contains "$out" "$line" "--check reported a different line than --print-import printed"
  pass "fm-captain-style.sh: --print-import and --check agree on the same line"
}

test_printed_line_pasted_verbatim_verifies
test_checkout_inside_home_prints_home_relative_import
test_checkout_outside_home_prints_absolute_import
test_home_relative_import_survives_a_relocated_home
test_check_reports_a_broken_import_and_names_the_replacement
test_check_reports_a_missing_import_and_prints_the_instructions
test_check_reports_an_absent_memory_file
test_an_indented_import_is_diagnosed_as_indentation
test_a_trailing_space_is_not_reported_as_indentation
test_a_cr_terminated_import_is_reported_as_wired
test_the_different_checkout_note_follows_the_target_not_the_spelling
test_an_unreadable_memory_file_still_prints_the_wiring
test_a_fenced_import_is_not_wiring
test_a_fenced_example_does_not_compete_with_a_real_import
test_tilde_fences_are_not_wiring
test_an_unterminated_fence_runs_to_end_of_file
test_an_indented_copy_does_not_compete_with_a_loading_import
test_a_fenced_import_and_an_indented_one_agree_on_one_verdict
test_more_than_one_import_is_reported_as_ambiguous
test_print_mode_asks_for_no_paste_when_the_import_is_already_there
test_print_mode_reports_an_import_left_behind_by_a_moved_checkout
test_print_mode_reports_competing_imports_instead_of_declaring_done
test_print_mode_reports_an_indented_only_memory_file
test_every_memory_state_gets_the_same_exit_status_from_both_modes
test_the_printed_remedy_reaches_wired_from_every_state
test_no_mode_ever_writes_to_the_memory_file
test_a_symlinked_memory_file_is_never_touched
test_a_missing_style_file_does_not_block_the_check
test_a_working_check_says_nothing_on_stderr
test_success_goes_to_stdout_and_diagnostics_go_to_stderr
test_help_documents_the_modes_and_a_bad_flag_fails
test_printed_import_matches_the_check_resolution
