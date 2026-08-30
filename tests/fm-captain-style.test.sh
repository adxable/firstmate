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
test_more_than_one_import_is_reported_as_ambiguous
test_no_mode_ever_writes_to_the_memory_file
test_a_symlinked_memory_file_is_never_touched
test_a_missing_style_file_does_not_block_the_check
test_success_goes_to_stdout_and_diagnostics_go_to_stderr
test_help_documents_the_modes_and_a_bad_flag_fails
test_printed_import_matches_the_check_resolution
