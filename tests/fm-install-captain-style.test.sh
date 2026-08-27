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
  local home checkout memory out count
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
  pass "fm-install-captain-style.sh: a legacy machine-specific import is replaced, not duplicated"
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
  pass "fm-install-captain-style.sh: --dry-run writes nothing and --uninstall removes only its block"
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

test_style_file_states_the_polish_answer_rule() {
  local doc
  doc="$ROOT/docs/styl-kapitanski.md"
  assert_present "$doc" "the captain style contract is missing"
  assert_grep 'Answer the captain in Polish' "$doc" \
    "the style contract no longer states the Polish answer rule"
  assert_grep 'commit messages' "$doc" \
    "the style contract no longer routes commit messages to English"
  pass "fm-install-captain-style.sh: the installed contract keeps the Polish answer rule"
}

test_install_inside_home_writes_home_relative_import
test_install_outside_home_writes_absolute_import
test_home_relative_import_survives_a_relocated_home
test_repeat_run_is_idempotent_and_keeps_other_content
test_legacy_absolute_import_is_replaced_not_duplicated
test_check_reports_missing_and_broken_wiring
test_dry_run_and_uninstall_leave_expected_state
test_refuses_a_checkout_without_the_style_file
test_style_file_states_the_polish_answer_rule
