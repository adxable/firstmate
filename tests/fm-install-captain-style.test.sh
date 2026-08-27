#!/usr/bin/env bash
# Behavior tests for bin/fm-install-captain-style.sh.
# Every case runs against a throwaway HOME and CLAUDE_CONFIG_DIR, so the
# machine's real user-level memory file is never read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-install-captain-style)

SCRIPT="$ROOT/bin/fm-install-captain-style.sh"

# Build a self-contained fake checkout so a case can place the style file
# inside or outside the fake HOME and observe which import form is written.
make_checkout() {
  local dest=$1
  mkdir -p "$dest/bin" "$dest/docs"
  cp "$SCRIPT" "$dest/bin/fm-install-captain-style.sh"
  chmod +x "$dest/bin/fm-install-captain-style.sh"
  printf '# Captain-Facing Communication Contract\n\nAnswer the captain in Polish.\n' \
    >"$dest/docs/styl-kapitanski.md"
}

run_install() {
  local checkout=$1 home=$2
  shift 2
  env HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    "$checkout/bin/fm-install-captain-style.sh" "$@" 2>&1
}

# Same invocation, but with the streams kept apart: stderr lands in <errfile> so
# a case can tell "documented on stdout" from "usage error on stderr".
run_install_split() {
  local checkout=$1 home=$2 errfile=$3
  shift 3
  env HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    "$checkout/bin/fm-install-captain-style.sh" "$@" 2>"$errfile"
}

# The part of the written memory file that sits above the managed block, i.e.
# everything the installer had to carry over from what was already there.
memory_outside_block() {
  awk '/firstmate:captain-style begin/ { exit } { print }' "$1"
}

test_install_inside_home_writes_home_relative_import() {
  local home checkout out memory
  home="$TMP_ROOT/inside/home"
  checkout="$home/src/firstmate"
  mkdir -p "$home"
  make_checkout "$checkout"

  out=$(run_install "$checkout" "$home") || fail "install failed: $out"
  memory="$home/.claude/CLAUDE.md"
  assert_present "$memory" "user-level memory file was not created"
  assert_grep '@~/src/firstmate/docs/styl-kapitanski.md' "$memory" \
    "a checkout under HOME did not get a home-relative import line"
  assert_no_grep "$home" "$memory" \
    "the import line hardcoded this machine's absolute home path"
  assert_contains "$out" "captain-style: installed" "install did not report success"
  pass "fm-install-captain-style.sh: a checkout under HOME gets a home-relative import"
}

test_install_outside_home_writes_absolute_import() {
  local home checkout real out memory
  home="$TMP_ROOT/outside/home"
  checkout="$TMP_ROOT/outside/opt/firstmate"
  mkdir -p "$home"
  make_checkout "$checkout"

  out=$(run_install "$checkout" "$home") || fail "install failed: $out"
  memory="$home/.claude/CLAUDE.md"
  # The script writes the physically resolved path, which can differ from the
  # fixture path when the temp root sits behind a symlink (/tmp on macOS).
  real=$(cd "$checkout" && pwd -P)
  assert_grep "@$real/docs/styl-kapitanski.md" "$memory" \
    "a checkout outside HOME did not fall back to an absolute import line"
  pass "fm-install-captain-style.sh: a checkout outside HOME falls back to an absolute import"
}

test_home_relative_import_survives_a_relocated_home() {
  local home moved checkout real out
  home="$TMP_ROOT/relocate/home-first"
  moved="$TMP_ROOT/relocate/home-second"
  checkout="$home/firstmate"
  mkdir -p "$home"
  make_checkout "$checkout"
  run_install "$checkout" "$home" >/dev/null || fail "install failed"

  # The whole home moves, exactly as it does on a different machine or account.
  mv "$home" "$moved"
  out=$(env HOME="$moved" CLAUDE_CONFIG_DIR="$moved/.claude" \
    "$moved/firstmate/bin/fm-install-captain-style.sh" --verify 2>&1) \
    || fail "verify failed after the home moved: $out"
  real=$(cd "$moved" && pwd -P)
  assert_contains "$out" "$real/firstmate/docs/styl-kapitanski.md" \
    "verify did not resolve the import against the new home"
  pass "fm-install-captain-style.sh: the written import still resolves after HOME moves"
}

test_repeat_run_is_idempotent_and_keeps_other_content() {
  local home checkout memory before after count
  home="$TMP_ROOT/idempotent/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  printf '# My own notes\n\nAlways run the tests.\n' >"$home/.claude/CLAUDE.md"

  run_install "$checkout" "$home" >/dev/null || fail "first install failed"
  memory="$home/.claude/CLAUDE.md"
  before=$(cat "$memory")
  run_install "$checkout" "$home" >/dev/null || fail "second install failed"
  after=$(cat "$memory")

  [ "$before" = "$after" ] || fail "a repeat run changed the memory file"
  count=$(grep -c 'firstmate:captain-style begin' "$memory")
  [ "$count" -eq 1 ] || fail "a repeat run left $count managed blocks"
  assert_grep 'Always run the tests.' "$memory" \
    "installing discarded unrelated user-level memory content"
  pass "fm-install-captain-style.sh: repeat runs converge and preserve unrelated content"
}

test_legacy_absolute_import_is_replaced_not_duplicated() {
  local home checkout memory out count outside
  home="$TMP_ROOT/legacy/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  # The pre-installer wiring: a bare heading plus one machine-specific path.
  printf '# Styl odpowiedzi\n\n@/Users/someone-else/Projects/firstmate/docs/styl-kapitanski.md\n' \
    >"$home/.claude/CLAUDE.md"

  out=$(run_install "$checkout" "$home") || fail "install failed: $out"
  memory="$home/.claude/CLAUDE.md"
  assert_no_grep 'someone-else' "$memory" "the stale machine-specific import survived"
  assert_contains "$out" "replaced legacy import" "install did not report the replacement"
  count=$(grep -c '^@' "$memory")
  [ "$count" -eq 1 ] || fail "expected exactly one import line, found $count"
  # The line the installer targets is the import itself. Everything the operator
  # wrote around it, heading included, is not this script's to touch.
  outside=$(memory_outside_block "$memory")
  assert_contains "$outside" '# Styl odpowiedzi' \
    "install deleted a heading it did not write"
  pass "fm-install-captain-style.sh: a legacy machine-specific import is replaced, not duplicated"
}

# Everything the installer found after its own END marker, which it has no
# business rewriting.
memory_after_block() {
  awk '/firstmate:captain-style end/ { seen = 1; next } seen { print }' "$1"
}

test_content_around_an_existing_block_survives_byte_for_byte() {
  local home checkout memory out prefix suffix first second
  home="$TMP_ROOT/inplace/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  # A block already sits in the middle of the file, with the operator's own
  # sections on both sides of it and a stale import inside it.
  prefix='# My notes

Read the checklist first.
'
  suffix='
# Tail section

Tail content that must not move.
'
  printf '%s<!-- firstmate:captain-style begin -->\n# Styl odpowiedzi\n\n@/Users/someone-else/Projects/firstmate/docs/styl-kapitanski.md\n<!-- firstmate:captain-style end -->\n%s' \
    "$prefix" "$suffix" >"$memory"

  out=$(run_install "$checkout" "$home") || fail "install failed: $out"
  assert_grep '@~/firstmate/docs/styl-kapitanski.md' "$memory" \
    "the block was not refreshed with the current import line"
  [ "$(memory_outside_block "$memory")" = "$(printf '%s' "$prefix")" ] ||
    fail "content above the block changed:"$'\n'"$(memory_outside_block "$memory")"
  [ "$(memory_after_block "$memory")" = "$(printf '%s' "$suffix")" ] ||
    fail "content below the block changed:"$'\n'"$(memory_after_block "$memory")"

  first=$(cat "$memory")
  run_install "$checkout" "$home" >/dev/null || fail "second install failed"
  second=$(cat "$memory")
  [ "$first" = "$second" ] || fail "a repeat run over an in-place block changed the file"
  pass "fm-install-captain-style.sh: content around an existing block survives byte for byte"
}

test_an_unterminated_block_is_refused_without_touching_the_file() {
  local home checkout memory out rc before
  home="$TMP_ROOT/unterminated/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  # A hand edit that lost the END marker: the block has no knowable extent, so
  # rewriting the file would have to guess and would swallow the tail.
  printf 'note one\n\n<!-- firstmate:captain-style begin -->\n# Styl odpowiedzi\n\n@~/firstmate/docs/styl-kapitanski.md\n# My own notes\nKeep me.\n' \
    >"$memory"
  before=$(cat "$memory")

  out=$(run_install "$checkout" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "install reported success over an unterminated block: $out"
  [ "$(cat "$memory")" = "$before" ] || fail "a refused run still rewrote the memory file"
  assert_contains "$out" "line 3" "the refusal did not name the line of the BEGIN marker"
  assert_contains "$out" "no matching END marker" \
    "the refusal did not say which marker is missing"
  assert_contains "$out" "$memory" "the refusal did not name the memory file"
  pass "fm-install-captain-style.sh: an unterminated block is refused and nothing is written"
}

# The installer reports the physically resolved path, which differs from the
# fixture path whenever the temp root sits behind a symlink (/tmp on macOS).
real_path() {
  printf '%s\n' "$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
}

test_a_symlinked_memory_file_is_written_through() {
  local home checkout link target out
  home="$TMP_ROOT/symlink/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude" "$home/dotfiles"
  make_checkout "$checkout"
  link="$home/.claude/CLAUDE.md"
  target="$home/dotfiles/claude.md"
  printf '# Dotfiles notes\n\nKeep me.\n' >"$target"
  ln -s "$target" "$link"

  out=$(run_install "$checkout" "$home") || fail "install failed: $out"
  [ -L "$link" ] || fail "the memory file is no longer a symlink"
  assert_grep 'firstmate:captain-style begin' "$target" \
    "the block was not written to the file the symlink points at"
  assert_grep 'Keep me.' "$target" "the dotfiles content was discarded"
  assert_contains "$out" "$(real_path "$target")" \
    "the run did not print the real path it wrote"
  pass "fm-install-captain-style.sh: a symlinked memory file is written through, not replaced"
}

test_a_dangling_symlink_is_refused() {
  local home checkout link target out rc
  home="$TMP_ROOT/dangling/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude" "$home/dotfiles"
  make_checkout "$checkout"
  link="$home/.claude/CLAUDE.md"
  target="$home/dotfiles/claude.md"
  ln -s "$target" "$link"

  out=$(run_install "$checkout" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "install succeeded through a dangling symlink: $out"
  [ -L "$link" ] || fail "the dangling symlink was replaced with a regular file"
  assert_absent "$target" "a refused run still created the missing link target"
  assert_contains "$out" "$(real_path "$target")" \
    "the refusal did not name the missing target"
  pass "fm-install-captain-style.sh: a dangling symlink is refused, not replaced"
}

test_an_unwritable_symlink_target_is_refused() {
  local home checkout link target out rc before
  home="$TMP_ROOT/readonly-target/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude" "$home/dotfiles"
  make_checkout "$checkout"
  link="$home/.claude/CLAUDE.md"
  target="$home/dotfiles/claude.md"
  printf '# Dotfiles notes\n\nKeep me.\n' >"$target"
  ln -s "$target" "$link"
  before=$(cat "$target")

  chmod 444 "$target"
  if [ -w "$target" ]; then
    chmod 644 "$target"
    pass "fm-install-captain-style.sh: unwritable-target refusal not exercised (file stayed writable)"
    return 0
  fi

  out=$(run_install "$checkout" "$home")
  rc=$?
  chmod 644 "$target"
  [ "$rc" -ne 0 ] || fail "install succeeded onto an unwritable symlink target: $out"
  [ -L "$link" ] || fail "the symlink was replaced with a regular file"
  [ "$(cat "$target")" = "$before" ] || fail "the unwritable target was rewritten"
  assert_contains "$out" "$(real_path "$target")" \
    "the refusal did not name the target it could not write"
  pass "fm-install-captain-style.sh: an unwritable symlink target is refused, not detached"
}

test_unreadable_memory_file_is_refused_without_losing_content() {
  local home checkout memory out rc before
  home="$TMP_ROOT/unreadable/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  printf '# My own notes\n\nKeep me.\n' >"$memory"
  before=$(cat "$memory")

  chmod 000 "$memory"
  if [ -r "$memory" ]; then
    # Running as root, where no permission bits make a file unreadable.
    chmod 644 "$memory"
    pass "fm-install-captain-style.sh: unreadable-memory refusal not exercised (file stayed readable)"
    return 0
  fi

  out=$(run_install "$checkout" "$home")
  rc=$?
  chmod 644 "$memory"
  [ "$rc" -ne 0 ] || fail "install reported success over an unreadable memory file: $out"
  assert_contains "$out" "$memory" "the refusal did not name the memory file"
  [ "$(cat "$memory")" = "$before" ] || fail "the unreadable memory file was overwritten"
  assert_no_grep 'firstmate:captain-style' "$memory" \
    "install replaced unreadable content with its own block"
  pass "fm-install-captain-style.sh: an unreadable memory file is refused, not overwritten"
}

test_help_documents_the_modes_and_a_bad_flag_fails() {
  local home checkout err out rc
  home="$TMP_ROOT/help/home"
  checkout="$home/firstmate"
  mkdir -p "$home"
  make_checkout "$checkout"
  err="$TMP_ROOT/help/stderr.txt"

  out=$(run_install_split "$checkout" "$home" "$err" --help)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--help exited $rc"
  assert_contains "$out" "--print-import" "--help did not document the modes on stdout"
  assert_contains "$out" "--uninstall" "--help did not document --uninstall on stdout"
  [ ! -s "$err" ] || fail "--help wrote to stderr: $(cat "$err")"
  assert_absent "$home/.claude/CLAUDE.md" "--help wrote a memory file"

  out=$(run_install_split "$checkout" "$home" "$err" --no-such-flag)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a bad flag exited 0"
  [ -z "$out" ] || fail "a usage error wrote to stdout: $out"
  assert_grep 'usage:' "$err" "a usage error did not print usage on stderr"
  pass "fm-install-captain-style.sh: --help documents the modes and a bad flag fails loudly"
}

test_check_reports_missing_and_broken_wiring() {
  local home checkout out rc
  home="$TMP_ROOT/check/home"
  checkout="$home/firstmate"
  mkdir -p "$home"
  make_checkout "$checkout"

  out=$(run_install "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check passed before anything was installed"
  assert_contains "$out" "NOT INSTALLED" "--check did not report missing wiring"

  run_install "$checkout" "$home" >/dev/null || fail "install failed"
  out=$(run_install "$checkout" "$home" --check)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--check failed right after a successful install: $out"

  # A silently missing target is the exact failure this wiring must surface.
  rm -f "$checkout/docs/styl-kapitanski.md"
  out=$(env HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    "$SCRIPT" --check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--check passed while the import target was missing"
  assert_contains "$out" "BROKEN" "--check did not name a dangling import as broken"
  pass "fm-install-captain-style.sh: --check reports missing and dangling wiring"
}

test_dry_run_and_uninstall_leave_expected_state() {
  local home checkout out memory
  home="$TMP_ROOT/dryrun/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  printf '# My own notes\n\nKeep me.\n' >"$home/.claude/CLAUDE.md"
  memory="$home/.claude/CLAUDE.md"

  out=$(run_install "$checkout" "$home" --dry-run) || fail "--dry-run failed: $out"
  assert_contains "$out" "firstmate:captain-style begin" "--dry-run did not show the block"
  assert_no_grep 'firstmate:captain-style' "$memory" "--dry-run wrote to the memory file"

  run_install "$checkout" "$home" >/dev/null || fail "install failed"
  run_install "$checkout" "$home" --uninstall >/dev/null || fail "--uninstall failed"
  assert_no_grep 'firstmate:captain-style' "$memory" "--uninstall left the managed block behind"
  assert_grep 'Keep me.' "$memory" "--uninstall discarded unrelated content"
  pass "fm-install-captain-style.sh: --dry-run writes nothing and --uninstall keeps unrelated content"
}

test_uninstall_unwires_legacy_imports_and_says_so() {
  local home checkout memory out outside
  home="$TMP_ROOT/uninstall-legacy/home"
  checkout="$home/firstmate"
  mkdir -p "$home/.claude"
  make_checkout "$checkout"
  memory="$home/.claude/CLAUDE.md"
  # Uninstalling straight over the pre-installer wiring: unwiring is meant to be
  # complete, so the hand-written import goes too - but never silently.
  printf '# Styl odpowiedzi\n\n@/Users/someone-else/Projects/firstmate/docs/styl-kapitanski.md\n\n# My own notes\n\nKeep me.\n' \
    >"$memory"

  out=$(run_install "$checkout" "$home" --uninstall) || fail "--uninstall failed: $out"
  assert_contains "$out" \
    "removed legacy import: @/Users/someone-else/Projects/firstmate/docs/styl-kapitanski.md" \
    "--uninstall removed a hand-written import without reporting it"
  assert_no_grep 'someone-else' "$memory" "--uninstall left the legacy import wired up"
  assert_grep 'Keep me.' "$memory" "--uninstall discarded unrelated content"
  assert_grep '# Styl odpowiedzi' "$memory" "--uninstall deleted a heading it did not write"
  pass "fm-install-captain-style.sh: --uninstall unwires legacy imports and reports each one"
}

test_refuses_a_checkout_without_the_style_file() {
  local home checkout out rc
  home="$TMP_ROOT/nostyle/home"
  checkout="$home/firstmate"
  mkdir -p "$home"
  make_checkout "$checkout"
  rm -f "$checkout/docs/styl-kapitanski.md"

  out=$(run_install "$checkout" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "install succeeded from a checkout with no style file"
  assert_contains "$out" "style file not found" "the refusal did not name the missing file"
  assert_absent "$home/.claude/CLAUDE.md" "a refused install still wrote a memory file"
  pass "fm-install-captain-style.sh: refuses a checkout that has no style file"
}

test_install_inside_home_writes_home_relative_import
test_install_outside_home_writes_absolute_import
test_home_relative_import_survives_a_relocated_home
test_repeat_run_is_idempotent_and_keeps_other_content
test_legacy_absolute_import_is_replaced_not_duplicated
test_content_around_an_existing_block_survives_byte_for_byte
test_an_unterminated_block_is_refused_without_touching_the_file
test_a_symlinked_memory_file_is_written_through
test_a_dangling_symlink_is_refused
test_an_unwritable_symlink_target_is_refused
test_unreadable_memory_file_is_refused_without_losing_content
test_help_documents_the_modes_and_a_bad_flag_fails
test_check_reports_missing_and_broken_wiring
test_dry_run_and_uninstall_leave_expected_state
test_uninstall_unwires_legacy_imports_and_says_so
test_refuses_a_checkout_without_the_style_file
