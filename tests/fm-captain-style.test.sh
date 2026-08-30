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

# The installer used to own this file. Nothing does now, so every case that
# touches a memory file pins that it came back unchanged.
assert_memory_untouched() {
  local file=$1 before=$2 label=$3
  [ "$(cat "$file")" = "$before" ] || fail "$label: the run modified $file"
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
  local home checkout out
  home="$TMP_ROOT/inside/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"

  out=$(run_style "$checkout" "$home") || fail "print mode failed: $out"
  assert_contains "$out" '@~/src/firstmate/docs/styl-kapitanski.md' \
    "a checkout under HOME did not get a home-relative import line"
  assert_not_contains "$out" "$home/src/firstmate/docs" \
    "the printed line hardcoded this machine's absolute home path"
  assert_contains "$out" "$home/.claude/CLAUDE.md" \
    "print mode did not name the file to paste into"
  pass "fm-captain-style.sh: a checkout under HOME gets a home-relative import"
}

test_checkout_outside_home_prints_absolute_import() {
  local home checkout real out
  home="$TMP_ROOT/outside/home"
  checkout="$TMP_ROOT/outside/opt/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  real=$(cd "$checkout" && pwd -P)

  out=$(run_style "$checkout" "$home") || fail "print mode failed: $out"
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
  before=$(cat "$memory")

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
  before=$(cat "$memory")

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
  before=$(cat "$memory")

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
  before=$(cat "$memory")

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
  local home checkout memory out rc
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

  out=$(run_style "$checkout" "$home") || true
  assert_contains "$out" '@~/src/firstmate/docs/styl-kapitanski.md' \
    "print mode withheld the import line over a permissions problem"
  assert_contains "$out" "$memory" "print mode withheld the file to paste into"
  assert_contains "$out" "could not be read" "print mode hid the permissions problem"

  out=$(run_style "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check reported on a memory file it could not read: $out"
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
  before=$(cat "$memory")

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

test_more_than_one_import_is_reported_as_ambiguous() {
  local home checkout memory line before out rc
  home="$TMP_ROOT/ambiguous/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  line=$(run_style "$checkout" "$home" --print-import)
  printf '%s\n@~/elsewhere/docs/styl-kapitanski.md\n' "$line" >"$memory"
  before=$(cat "$memory")

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
  before=$(cat "$memory")

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
  before=$(cat "$target")

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
  assert_not_contains "$out" "replace that line with" \
    "--check advised pasting a line pointing at the same missing file"
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
test_no_mode_ever_writes_to_the_memory_file
test_a_symlinked_memory_file_is_never_touched
test_a_missing_style_file_does_not_block_the_check
test_a_working_check_says_nothing_on_stderr
test_success_goes_to_stdout_and_diagnostics_go_to_stderr
test_help_documents_the_modes_and_a_bad_flag_fails
test_printed_import_matches_the_check_resolution
