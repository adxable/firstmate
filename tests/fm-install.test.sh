#!/usr/bin/env bash
# Behavior tests for bin/fm-install.sh.
#
# The installer stands firstmate up on a machine from either starting state, so
# the cases drive it through both: a machine with no checkout, where it clones
# one, and an existing checkout, where it uses that one. A third run over an
# already-finished machine pins idempotency by comparing a manifest of every
# file it could have touched before and after.
#
# Tools come from bin/fm-bootstrap.sh rather than from a list inside the
# installer, so the tool cases drive the real bootstrap against a fake PATH:
# absent and present-but-below-its-floor are two inputs to that one owner, and
# the cases assert both reach the same install call. quota-axi is the tool used
# for the floor case because bootstrap gates its installed version.
#
# Consent is asserted in both directions, including that a run with no answer
# available installs nothing, and the captain style rules are asserted to be
# checked and never written: the memory-file case holds content the installer
# does not own and is compared byte for byte afterwards.
#
# Every case runs against a throwaway HOME, CLAUDE_CONFIG_DIR, PATH, and
# checkout, so the machine's real toolchain, memory file, and firstmate home are
# never read or written.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-install)

INSTALLER_REL=bin/fm-install.sh

# One template checkout, copied per case. It carries the real bin/ - the
# installer drives the real bootstrap and the real captain-style check, not
# stand-ins for them - plus the two files that make a directory a firstmate
# checkout.
TEMPLATE="$TMP_ROOT/template"
build_template() {
  mkdir -p "$TEMPLATE/docs"
  cp -R "$ROOT/bin" "$TEMPLATE/bin"
  cp "$ROOT/docs/styl-kapitanski.md" "$TEMPLATE/docs/styl-kapitanski.md"
  cp "$ROOT/AGENTS.md" "$TEMPLATE/AGENTS.md"
  git -C "$TEMPLATE" init -q
  git -C "$TEMPLATE" add -A >/dev/null
  git -C "$TEMPLATE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'template checkout' >/dev/null
}
build_template

# A fake toolchain where every tool bootstrap requires is present, gh is
# authenticated, and npm records what it was asked to install instead of
# reaching the network. quota-axi answers the version in FM_FAKE_QUOTA_AXI_VERSION
# so a case can drive it below bootstrap's floor.
make_fake_toolchain() {
  local dir=$1 fakebin real_git
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/fakebin-quota"
  fm_fake_exit0 "$fakebin" node tmux chrome-devtools-axi
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  # quota-axi sits in its own directory so a case can drop it from PATH without
  # writing a second toolchain: on macOS every newly created executable pays a
  # first-exec system check, which is most of what a fresh fake toolchain costs.
  fm_fake_version_tool "$dir/fakebin-quota" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.29
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.2.4'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$FM_FAKE_NPM_LOG"
exit 0
SH
  # git is the one real tool a case needs: the installer clones with it.
  real_git=$(command -v git) || fail 'git is required for the installer tests'
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin"/gh "$fakebin"/treehouse "$fakebin"/no-mistakes \
    "$fakebin"/tasks-axi "$fakebin"/npm "$fakebin"/git
  printf '%s\n' "$fakebin"
}

# One fake toolchain for the whole file, in the shared fixture directory.
FIXTURE="$TMP_ROOT/fixture"
mkdir -p "$FIXTURE"
make_fake_toolchain "$FIXTURE" >/dev/null
FAKEBIN="$FIXTURE/fakebin"
FAKEBIN_QUOTA="$FIXTURE/fakebin-quota"

# One case's world: an empty HOME, an npm log, its own PATH, and a checkout.
# The checkout is the shared template by default, because the installer writes
# nothing into a checkout it did not clone - the idempotency case proves that
# against a private copy, and sharing one everywhere else keeps a case from
# paying to copy the whole toolbelt again.
new_case() {
  local dir private=${1:-}
  dir=$(mktemp -d "$TMP_ROOT/case-XXXXXX") || fail 'could not create a case directory'
  mkdir -p "$dir/home/.claude"
  if [ "$private" = private ]; then
    cp -R "$TEMPLATE" "$dir/checkout"
  else
    ln -s "$TEMPLATE" "$dir/checkout"
  fi
  : > "$dir/npm.log"
  printf '%s\n' "$FAKEBIN_QUOTA:$FAKEBIN:$BASE_PATH" > "$dir/path"
  printf '%s\n' "$dir"
}

# Drop quota-axi from a case's PATH, which is how a case models a tool that is
# not installed at all.
drop_quota_axi() {
  printf '%s\n' "$FAKEBIN:$BASE_PATH" > "$1/path"
}

# Run one installer script with nothing of the host environment reaching it but
# the paths this case owns, from a chosen working directory. Combined streams:
# what an operator sees. <answer> is fed on stdin, which is where the installer
# reads an answer from when it was not itself piped in.
run_script() {
  local dir=$1 script=$2 cwd=$3 answer=$4
  shift 4
  printf '%s' "$answer" | (cd "$cwd" && env -i \
    PATH="$(cat "$dir/path")" \
    HOME="$dir/home" \
    CLAUDE_CONFIG_DIR="$dir/home/.claude" \
    TMPDIR="${TMPDIR:-/tmp}" \
    FM_FAKE_NPM_LOG="$dir/npm.log" \
    FM_FAKE_QUOTA_AXI_VERSION="${FM_FAKE_QUOTA_AXI_VERSION:-0.1.29}" \
    bash "$script" "$@" 2>&1)
}

# The ordinary run: the installer inside this case's own checkout.
run_installer() {
  local dir=$1 answer=$2
  shift 2
  run_script "$dir" "$dir/checkout/$INSTALLER_REL" "$dir" "$answer" "$@"
}

# The import line this case's checkout would use, computed by the owner of that
# wiring rather than re-derived here.
import_line_for() {
  local dir=$1
  env -i PATH="$BASE_PATH" HOME="$dir/home" CLAUDE_CONFIG_DIR="$dir/home/.claude" \
    bash "$dir/checkout/bin/fm-captain-style.sh" --print-import
}

wire_style() {
  local dir=$1
  import_line_for "$dir" > "$dir/home/.claude/CLAUDE.md"
}

# Every path under a case's checkout and home, with its size and content hash,
# so an idempotency case can prove a second run changed nothing rather than
# only that it printed the same words.
manifest() {
  local dir=$1
  (cd "$dir" && find checkout home -print0 2>/dev/null \
    | LC_ALL=C sort -z \
    | while IFS= read -r -d '' path; do
        if [ -f "$path" ] && [ ! -L "$path" ]; then
          printf '%s %s\n' "$path" "$(cksum < "$path")"
        else
          printf '%s dir-or-link\n' "$path"
        fi
      done)
}

# --- a machine with no checkout ---------------------------------------------

# The script on its own, outside any checkout, run from an empty directory: the
# shape a machine has before firstmate is on it at all.
case_dir=$(new_case)
mkdir -p "$case_dir/standalone" "$case_dir/fresh"
cp "$case_dir/checkout/$INSTALLER_REL" "$case_dir/standalone/fm-install.sh"
out=$(run_script "$case_dir" "$case_dir/standalone/fm-install.sh" "$case_dir/fresh" '' \
  --repo "$case_dir/checkout")
code=$?
assert_present "$case_dir/fresh/firstmate/AGENTS.md" \
  'fresh machine: the installer did not produce a checkout'
assert_contains "$out" "cloned from $case_dir/checkout" \
  'fresh machine: the report does not say the checkout was cloned'
assert_contains "$out" 'tools: every tool firstmate requires is already present' \
  'fresh machine: the toolchain was not reported'
expect_code 1 "$code" 'fresh machine: the unwired style rules should leave one step outstanding'
pass 'a machine with no checkout gets one cloned, and the run reports it'

# The one-command shape: the script arrives on stdin rather than as a file on
# disk, which is the run that has no checkout to be inside of. --yes carries the
# consent here because a piped run has no stdin left to read an answer from.
case_dir=$(new_case)
mkdir -p "$case_dir/piped"
out=$( (cd "$case_dir/piped" && env -i \
  PATH="$(cat "$case_dir/path")" \
  HOME="$case_dir/home" \
  CLAUDE_CONFIG_DIR="$case_dir/home/.claude" \
  TMPDIR="${TMPDIR:-/tmp}" \
  FM_FAKE_NPM_LOG="$case_dir/npm.log" \
  bash -s -- --repo "$case_dir/checkout" --yes \
    < "$case_dir/checkout/$INSTALLER_REL" 2>&1) )
assert_present "$case_dir/piped/firstmate/AGENTS.md" \
  'piped run: the installer did not produce a checkout beside the working directory'
assert_contains "$out" "cloned from $case_dir/checkout" \
  'piped run: the report does not say the checkout was cloned'
pass 'the script piped into bash clones into the working directory it was run from'

# --- an existing checkout ----------------------------------------------------

case_dir=$(new_case)
wire_style "$case_dir"
out=$(run_installer "$case_dir" '')
code=$?
assert_contains "$out" '(already present)' \
  'existing checkout: the run did not report the checkout it was run from'
assert_not_contains "$out" 'Cloning' 'existing checkout: the run cloned instead of using it'
expect_code 0 "$code" 'existing checkout with everything in place should exit 0'
pass 'an existing checkout is used as it stands, with no clone'

# --- a second run over a finished machine ------------------------------------

case_dir=$(new_case private)
wire_style "$case_dir"
first=$(run_installer "$case_dir" '')
expect_code 0 "$?" 'idempotency: the first run should already be complete'
before=$(manifest "$case_dir")
second=$(run_installer "$case_dir" '')
code=$?
after=$(manifest "$case_dir")
expect_code 0 "$code" 'idempotency: the second run must exit 0'
[ "$before" = "$after" ] || fail 'idempotency: the second run changed files on disk'
[ "$first" = "$second" ] || fail 'idempotency: the second run reported something different'
assert_not_contains "$second" 'Still to do on this machine' \
  'idempotency: a finished machine should have nothing outstanding'
assert_contains "$second" 'Nothing on this machine is outstanding.' \
  'idempotency: a finished machine should say so'
pass 'a second run over a finished machine changes nothing and exits 0'

# --- a tool that is absent ---------------------------------------------------

case_dir=$(new_case)
wire_style "$case_dir"
drop_quota_axi "$case_dir"
out=$(run_installer "$case_dir" 'y
')
code=$?
assert_contains "$out" 'quota-axi (install: npm install -g quota-axi)' \
  'absent tool: bootstrap install command was not shown before asking'
assert_contains "$out" 'Install them now?' 'absent tool: consent was not requested'
assert_grep 'npm install -g quota-axi' "$case_dir/npm.log" \
  'absent tool: the approved install did not run'
expect_code 1 "$code" 'absent tool: the stub is still absent afterwards, so a step remains'
pass 'an absent tool is offered with bootstrap install command, then installed on consent'

# --- a tool that is present but below its floor ------------------------------

case_dir=$(new_case)
wire_style "$case_dir"
out=$(FM_FAKE_QUOTA_AXI_VERSION=0.1.20 run_installer "$case_dir" 'y
')
assert_contains "$out" 'missing or below the version firstmate requires' \
  'below-floor tool: the run did not report it'
assert_contains "$out" 'quota-axi (install: npm install -g quota-axi)' \
  'below-floor tool: it was not offered the same way an absent one is'
assert_grep 'npm install -g quota-axi' "$case_dir/npm.log" \
  'below-floor tool: the approved upgrade did not run'
pass 'a tool below its version floor is upgraded by the same path as an absent one'

# --- consent, declined -------------------------------------------------------

case_dir=$(new_case)
wire_style "$case_dir"
out=$(FM_FAKE_QUOTA_AXI_VERSION=0.1.20 run_installer "$case_dir" 'n
')
code=$?
assert_contains "$out" 'Install them now?' 'declined consent: consent was not requested'
assert_no_grep 'npm' "$case_dir/npm.log" 'declined consent: something was installed anyway'
assert_contains "$out" 'Nothing was installed' 'declined consent: the decline was not reported'
assert_contains "$out" 'Still to do on this machine:' \
  'declined consent: the install was not left as an outstanding step'
expect_code 1 "$code" 'declined consent: the run must not report a finished machine'
pass 'a declined install installs nothing and stays an outstanding step'

# --- consent, with no answer available ---------------------------------------

case_dir=$(new_case)
wire_style "$case_dir"
out=$(FM_FAKE_QUOTA_AXI_VERSION=0.1.20 run_installer "$case_dir" '')
code=$?
assert_no_grep 'npm' "$case_dir/npm.log" \
  'no answer available: a run that could not ask installed anyway'
expect_code 1 "$code" 'no answer available: the run must report the step as outstanding'
pass 'a run with no answer available installs nothing'

# --- the explicit unattended flag --------------------------------------------

case_dir=$(new_case)
wire_style "$case_dir"
out=$(FM_FAKE_QUOTA_AXI_VERSION=0.1.20 run_installer "$case_dir" '' --yes)
assert_not_contains "$out" 'Install them now?' '--yes: the run still asked'
assert_grep 'npm install -g quota-axi' "$case_dir/npm.log" '--yes: nothing was installed'
pass '--yes installs without asking, and only --yes does'

# --- the captain style rules, wired and not wired ----------------------------

case_dir=$(new_case)
out=$(run_installer "$case_dir" '')
code=$?
import=$(import_line_for "$case_dir")
assert_contains "$out" 'the captain style rules are not wired' \
  'unwired style: the gap was not reported'
assert_contains "$out" "$import" 'unwired style: the exact line to paste was not printed'
assert_contains "$out" "$case_dir/home/.claude/CLAUDE.md" \
  'unwired style: the exact file to paste it into was not printed'
expect_code 1 "$code" 'unwired style: the run must not report a finished machine'
assert_absent "$case_dir/home/.claude/CLAUDE.md" \
  'unwired style: the installer created the memory file it does not own'
pass 'unwired style rules are reported with the exact line and file, and nothing is written'

case_dir=$(new_case)
wire_style "$case_dir"
out=$(run_installer "$case_dir" '')
expect_code 0 "$?" 'wired style: a wired machine should have nothing outstanding'
assert_contains "$out" 'captain style rules:' 'wired style: the wiring was not reported'
assert_not_contains "$out" 'not wired' 'wired style: a wired file was reported as a gap'
pass 'wired style rules are reported as done'

# --- a memory file the installer does not own --------------------------------

case_dir=$(new_case)
memory="$case_dir/home/.claude/CLAUDE.md"
cat > "$memory" <<'EOF'
# My own memory

Notes I wrote, and an import of something else entirely.

@~/other-project/notes.md
EOF
cp "$memory" "$case_dir/memory-before"
out=$(run_installer "$case_dir" '' --yes)
code=$?
cmp -s "$memory" "$case_dir/memory-before" \
  || fail 'foreign memory file: the run modified a file it does not own'
assert_contains "$out" 'the captain style rules are not wired' \
  'foreign memory file: the gap was not reported'
assert_contains "$out" 'never writes to' \
  'foreign memory file: the run did not say the wiring is a human step'
expect_code 1 "$code" 'foreign memory file: the wiring step must stay outstanding'
pass 'a memory file holding other content is reported on and left byte for byte'

# --- a target that is not a firstmate checkout -------------------------------

case_dir=$(new_case)
occupied="$case_dir/occupied"
mkdir -p "$occupied"
printf 'not firstmate\n' > "$occupied/README.md"
cp "$occupied/README.md" "$case_dir/occupied-before"
out=$(run_installer "$case_dir" '' --dir "$occupied")
code=$?
expect_code 2 "$code" 'occupied target: the run should refuse rather than proceed'
assert_contains "$out" 'is not a firstmate checkout' 'occupied target: the refusal was not explained'
cmp -s "$occupied/README.md" "$case_dir/occupied-before" \
  || fail 'occupied target: the run wrote into a directory it refused'
pass 'a target holding something else is refused and left alone'

# --- the manual steps no script can take -------------------------------------

case_dir=$(new_case)
wire_style "$case_dir"
out=$(run_installer "$case_dir" '')
assert_contains "$out" 'Steps this installer cannot take for you:' \
  'manual steps: the closing list is missing'
assert_contains "$out" 'sign in to it' 'manual steps: signing in to a harness is not listed'
assert_contains "$out" 'access to the repositories' \
  'manual steps: repository access is not listed'
pass 'the steps no script can take are listed on every run, including a finished one'
