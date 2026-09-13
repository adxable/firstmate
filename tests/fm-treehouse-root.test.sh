#!/usr/bin/env bash
# Behavior tests for the per-home treehouse pool root: bin/fm-treehouse-root.sh,
# the root bin/fm-spawn.sh records, and the root bin/fm-teardown.sh returns to.
#
# THE BUG THIS PINS. Treehouse keys a pool by the repository's REMOTE URL, not by
# the clone path, so two firstmate homes that each hold their own clone of one
# repository resolve to the SAME pool under one root. When that pool has a free
# slot the OTHER clone created, it hands it over: a real, isolated worktree whose
# git common dir belongs to the other home's clone. fm-spawn's isolation and
# ownership guards accept it, and the spawn dies further along in
# bin/fm-claude-trust.sh's scope test, which is the one check that compares
# common dirs - so the second home can start nothing at all.
#
# The regression case below reproduces exactly that, then proves the per-home
# root flips it. It needs the real treehouse binary and skips without it, because
# which slot a pool hands out is the pool tool's own behavior and a stub could
# only confirm the assumption written into the stub. The resolution and teardown
# cases beside it are portable and run everywhere.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_git_identity fmtest fmtest@example.invalid

RESOLVE="$ROOT/bin/fm-treehouse-root.sh"
TRUST="$ROOT/bin/fm-claude-trust.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-root)

# A fake $HOME per case, so no assertion depends on the developer's own home and
# nothing here can write into it.
FAKE_HOME="$TMP_ROOT/user-home"
mkdir -p "$FAKE_HOME"

# make_home <name> [secondmate]: a firstmate home directory, optionally carrying
# the .fm-secondmate-home identity marker. Echoes its path.
make_home() {  # <name> [secondmate]
  local name=$1 kind=${2:-primary} home
  home="$TMP_ROOT/homes/$name"
  mkdir -p "$home/config" "$home/state" "$home/data"
  [ "$kind" != secondmate ] || printf '%s\n' "$name" > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

# resolve <home>: the pool root that home resolves to, against the fake $HOME.
resolve() {  # <home>
  HOME="$FAKE_HOME" FM_HOME="$1" "$RESOLVE"
}

# refuse_reason <home> <what-the-home-holds>: the resolver's combined output when
# it refuses; fails the test when it succeeded instead.
refuse_reason() {  # <home> <what-the-home-holds>
  local out rc
  out=$(HOME="$FAKE_HOME" FM_HOME="$1" "$RESOLVE" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "$2 was accepted instead of refused (printed '$out')"
  [ -n "$out" ] || fail "$2 was refused with no diagnostic"
  printf '%s\n' "$out"
}

# A home that needs no root of its own is left alone: nothing is printed, so
# fm-spawn forces no TREEHOUSE_ROOT and treehouse's own resolution stands,
# including a root the project configures for itself.
test_a_home_without_its_own_root_is_left_alone() {
  local home root
  home=$(make_home primary-legacy)
  root=$(resolve "$home")
  [ -z "$root" ] \
    || fail "a home with no root of its own printed '$root' instead of leaving treehouse's resolution alone"
  pass "a home with no root of its own resolves to nothing, so no root is forced anywhere"
}

test_secondmate_home_gets_its_own_root() {
  local secondmate secondmate_root
  secondmate=$(make_home mate-own-root secondmate)
  secondmate_root=$(resolve "$secondmate")
  [ -n "$secondmate_root" ] \
    || fail "a secondmate home was left on treehouse's own resolution, which is the primary's pool"
  case $secondmate_root in
    "$FAKE_HOME"/*) ;;
    *) fail "a secondmate home's root escaped \$HOME: '$secondmate_root'" ;;
  esac
  [ "$(resolve "$secondmate")" = "$secondmate_root" ] \
    || fail "a secondmate home's root is not stable across resolutions"
  pass "a marker-bearing secondmate home resolves to its own stable root under \$HOME"
}

# The realistic collision: secondmate homes are slots in the primary's firstmate
# pool, so <pool>/2/firstmate and <pool>/3/firstmate share a basename. Only the
# registered id each marker holds tells them apart.
test_two_secondmate_homes_get_two_roots() {
  local pool one two root_one root_two
  pool="$TMP_ROOT/homes/shared-pool"
  mkdir -p "$pool/2" "$pool/3"
  one="$pool/2/firstmate"
  two="$pool/3/firstmate"
  mkdir -p "$one/config" "$two/config"
  printf 'mate-a\n' > "$one/.fm-secondmate-home"
  printf 'mate-b\n' > "$two/.fm-secondmate-home"
  [ "$(basename "$one")" = "$(basename "$two")" ] \
    || fail "fixture is vacuous: the two secondmate homes must share a basename"
  root_one=$(resolve "$one")
  root_two=$(resolve "$two")
  [ "$root_one" != "$root_two" ] \
    || fail "two secondmate homes with different registered ids collapsed onto one root '$root_one'"
  pass "two secondmate homes leased from one pool are kept apart by their registered ids"
}

# treehouse recycles slot paths: retiring a secondmate home returns
# <pool>/2/firstmate to the primary's firstmate pool, and the next home is handed
# the same path. Two homes that occupy it in turn must not share a worktree pool,
# because the first home's state and worktrees name a clone that no longer exists.
test_a_recycled_home_slot_does_not_inherit_the_previous_root() {
  local slot first second
  slot="$TMP_ROOT/homes/recycled-pool/2/firstmate"
  mkdir -p "$slot/config"
  printf 'mate-retired\n' > "$slot/.fm-secondmate-home"
  first=$(resolve "$slot")
  # The home is retired and treehouse hands its slot to a different secondmate:
  # the path is byte-identical and only the registered identity changed.
  printf 'mate-successor\n' > "$slot/.fm-secondmate-home"
  second=$(resolve "$slot")
  [ "$first" != "$second" ] \
    || fail "a home leased into a retired home's slot path inherited its pool root '$first'"
  pass "two homes occupying one recycled slot path in turn resolve to two different roots"
}

# The id names one directory under $HOME/.treehouse-homes, so an id that is not a
# single path segment would name a directory other than this home's own. There is
# no safe fallback - every other root belongs to some other home - so it refuses.
test_an_id_that_is_not_one_path_segment_refuses() {
  local home out
  home="$TMP_ROOT/homes/mate-dot-marker"
  mkdir -p "$home/config"
  printf '.\n' > "$home/.fm-secondmate-home"
  out=$(refuse_reason "$home" "a secondmate id of '.'")
  case $out in
    *.fm-secondmate-home*) ;;
    *) fail "the refusal did not name the marker: $out" ;;
  esac

  printf '..\n' > "$home/.fm-secondmate-home"
  refuse_reason "$home" "a secondmate id of '..'" >/dev/null
  pass "a secondmate id that cannot be one path segment refuses instead of naming another directory"
}

# Detection has ONE owner: fm_root_is_secondmate_home in bin/fm-primary-scope-lib.sh.
# A marker that predicate rejects makes the home a primary here, exactly as it
# already does for every other consumer, rather than a second opinion in this file.
test_a_marker_the_shared_predicate_rejects_leaves_the_home_alone() {
  local home lib
  lib="$ROOT/bin/fm-primary-scope-lib.sh"
  home="$TMP_ROOT/homes/mate-unreadable-marker"
  mkdir -p "$home/config"
  : > "$home/.fm-secondmate-home"
  # shellcheck source=bin/fm-primary-scope-lib.sh
  ( . "$lib" && fm_root_is_secondmate_home "$home" ) \
    && fail "fixture is vacuous: the shared predicate accepted an empty marker"
  [ -z "$(resolve "$home")" ] \
    || fail "a marker the shared predicate rejects still resolved a secondmate root"
  pass "a marker the shared predicate rejects leaves the home on treehouse's own resolution"
}

# --- the reported bug -------------------------------------------------------

# make_two_clone_world <name>: a bare remote plus two clones of it at different
# paths, both named the same, standing in for two homes' own project clones.
# Echoes "<dir>|<cloneA>|<cloneB>".
make_two_clone_world() {  # <name>
  local name=$1 dir seed
  dir="$TMP_ROOT/$name"
  seed="$dir/seed"
  mkdir -p "$dir"
  git init -q --bare "$dir/remote.git"
  git -C "$dir/remote.git" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$seed"
  printf 'hello\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm "baseline"
  git -C "$seed" remote add origin "$dir/remote.git"
  git -C "$seed" push -q origin main
  rm -rf "$seed"
  git clone -q "$dir/remote.git" "$dir/homeA/adx-worker"
  git clone -q "$dir/remote.git" "$dir/homeB/adx-worker"
  printf '%s|%s|%s\n' "$dir" "$dir/homeA/adx-worker" "$dir/homeB/adx-worker"
}

# An empty <root> means "force nothing", the shape a home with no root of its own
# produces; treehouse then resolves the root itself, against the fake $HOME.
lease() {  # <root> <clone> <holder> -> the leased worktree path
  if [ -n "$1" ]; then
    ( cd "$2" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$1" treehouse get --lease --lease-holder "$3" 2>/dev/null )
  else
    ( cd "$2" && HOME="$FAKE_HOME" env -u TREEHOUSE_ROOT treehouse get --lease --lease-holder "$3" 2>/dev/null )
  fi
}

unlease() {  # <root> <clone> <worktree>
  if [ -n "$1" ]; then
    ( cd "$2" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$1" treehouse return --force "$3" >/dev/null 2>&1 )
  else
    ( cd "$2" && HOME="$FAKE_HOME" env -u TREEHOUSE_ROOT treehouse return --force "$3" >/dev/null 2>&1 )
  fi
}

common_dir_of() {  # <dir>
  git -C "$1" rev-parse --path-format=absolute --git-common-dir
}

pool_dir_of() {  # <worktree> -> the pool directory the slot belongs to
  ( cd "$1" && cd ../.. && pwd -P )
}

# can_spawn_into <worktree> <project>: whether a claude spawn would be allowed to
# launch into that worktree for that project. bin/fm-claude-trust.sh is the check
# that actually refused in the field, so the verdict is read from it directly.
can_spawn_into() {  # <worktree> <project>
  local store="$TMP_ROOT/trust-store-$RANDOM"
  mkdir -p "$store"
  CLAUDE_CONFIG_DIR="$store" HOME="$store" "$TRUST" "$1" "$2" >/dev/null 2>&1
}

# The half of the fault that needs no pool tool: whatever hands a home a
# worktree of ANOTHER clone of the same repository, the spawn is refused. This
# runs everywhere, including the portable CI lanes that install no treehouse.
test_a_worktree_of_another_clone_is_refused() {
  local rec dir cloneA cloneB wt_a
  rec=$(make_two_clone_world foreign-worktree)
  IFS='|' read -r dir cloneA cloneB <<EOF
$rec
EOF
  wt_a="$dir/wt-of-clone-a"
  git -C "$cloneA" worktree add -q --detach "$wt_a" main

  can_spawn_into "$wt_a" "$cloneA" \
    || fail "fixture is vacuous: a worktree of its own clone was already refused"
  can_spawn_into "$wt_a" "$cloneB" \
    && fail "a worktree of another clone of the same repository was accepted for this home's project"
  pass "a worktree belonging to another clone of the same repository is refused, whichever pool handed it over"
}

test_two_homes_two_clones_do_not_share_a_pool() {
  local rec dir cloneA cloneB shared root_a root_b slot slot_b_shared slot_b_own
  rec=$(make_two_clone_world two-clone)
  IFS='|' read -r dir cloneA cloneB <<EOF
$rec
EOF

  # The bug as reported: one shared root. Home A creates the pool and frees its
  # slot, then home B asks for a worktree and is handed A's.
  shared="$dir/shared-root"
  mkdir -p "$shared"
  slot=$(lease "$shared" "$cloneA" fm-a)
  [ -n "$slot" ] || fail "the shared-root fixture could not lease a slot for home A"
  unlease "$shared" "$cloneA" "$slot"
  slot_b_shared=$(lease "$shared" "$cloneB" fm-b)
  [ -n "$slot_b_shared" ] || fail "the shared-root fixture could not lease a slot for home B"
  [ "$(common_dir_of "$slot_b_shared")" = "$(common_dir_of "$cloneA")" ] \
    || fail "fixture is vacuous: home B was not handed a worktree of home A's clone"
  can_spawn_into "$slot_b_shared" "$cloneB" \
    && fail "the reported bug did not reproduce: home B was allowed to spawn into home A's worktree"

  # The fix: the two homes no longer resolve to one root, so the pools are
  # different directories even though the remote hash they are keyed by is
  # identical. Home A keeps treehouse's own resolution and home B gets its own.
  root_a=$(resolve "$(make_home repro-primary)")
  root_b=$(resolve "$(make_home repro-mate secondmate)")
  [ "$root_a" != "$root_b" ] || fail "the two homes resolved to one root"
  slot=$(lease "$root_a" "$cloneA" fm-a2)
  [ -n "$slot" ] || fail "home A could not lease from its own root"
  unlease "$root_a" "$cloneA" "$slot"
  slot_b_own=$(lease "$root_b" "$cloneB" fm-b2)
  [ -n "$slot_b_own" ] || fail "home B could not lease from its own root"

  [ "$(pool_dir_of "$slot")" != "$(pool_dir_of "$slot_b_own")" ] \
    || fail "the two homes still landed in one pool directory $(pool_dir_of "$slot")"
  [ "$(common_dir_of "$slot_b_own")" = "$(common_dir_of "$cloneB")" ] \
    || fail "home B's own-root worktree is still backed by another clone"
  can_spawn_into "$slot_b_own" "$cloneB" \
    || fail "home B still could not spawn into a worktree from its own pool"

  unlease "$root_b" "$cloneB" "$slot_b_own"
  unlease "$shared" "$cloneB" "$slot_b_shared"
  pass "two homes with their own clone of one repository get two pool directories, and the second can spawn"
}

# --- the spawn records the root it leased from ------------------------------

# make_spawn_case <name> <id> [secondmate]: a home, a project clone and a pooled
# worktree, wired for the real spawn path with a fake terminal.
# Echoes "<home>|<project>|<pool>|<fakebin>".
make_spawn_case() {  # <name> <id> [secondmate]
  local name=$1 id=$2 kind=${3:-primary} case_dir home project pool fakebin sha
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/state" "$home/config" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  [ "$kind" != secondmate ] || printf '%s\n' "$name" > "$home/.fm-secondmate-home"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -qm initial
  sha=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$sha"

  # Replace the fixture's tmux with one that also records every plain send-keys
  # payload, so the acquisition line the pane is asked to run can be replayed.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        case $prev in -t) ;; *) [ "$a" = Enter ] || [ "$a" = -l ] || [ "$a" = -t ] \
          || [ "$a" = send-keys ] || printf '%s\n' "$a" >> "$FM_FAKE_PANE_LOG" ;;
        esac
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  printf '%s|%s|%s|%s\n' "$home" "$project" "$pool" "$fakebin"
}

# spawned_root <name> <id> [secondmate]: run one spawn and echo
# "<recorded root>|<root the resolver reports for that home>".
spawned_root() {  # <name> <id> [secondmate]
  local rec home project pool fakebin out recorded expected
  rec=$(make_spawn_case "$@")
  IFS='|' read -r home project pool fakebin <<EOF
$rec
EOF
  out=$(FM_FAKE_PANE_LOG="$home/pane.log" \
    fm_test_run_spawn "$home" "$pool" "$fakebin" "$2" "$project" --scout) \
    || fail "spawn failed for $1: $out"
  recorded=$(sed -n 's/^treehouse_root=//p' "$home/state/$2.meta" | head -1)
  expected=$(HOME="$home/user-home" FM_HOME="$home" "$RESOLVE")
  printf '%s|%s|%s\n' "$recorded" "$expected" "$home"
}

# leased_root_of_pane <home>: replay the worktree-acquisition line the spawn asked
# the pane to run, against a treehouse stub that reports the root it ran under.
# This reads the wire the pane really uses rather than the record beside it.
leased_root_of_pane() {  # <home>
  local home=$1 stub line
  stub="$home/pane-stub"
  mkdir -p "$stub"
  cat > "$stub/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TREEHOUSE_ROOT-UNSET}"
SH
  chmod +x "$stub/treehouse"
  line=$(grep -F 'treehouse get' "$home/pane.log" | head -1) \
    || fail "the spawn never asked its pane to acquire a worktree"
  [ -n "$line" ] || fail "the spawn never asked its pane to acquire a worktree"
  PATH="$stub:$PATH" env -u TREEHOUSE_ROOT bash -c "$line"
}

test_spawn_leases_and_records_its_own_homes_root() {
  local primary_rec mate_rec
  local primary_recorded primary_expected primary_home mate_recorded mate_expected mate_home
  primary_rec=$(spawned_root primary-record th-root-primary)
  IFS='|' read -r primary_recorded primary_expected primary_home <<EOF
$primary_rec
EOF
  mate_rec=$(spawned_root mate-record th-root-mate secondmate)
  IFS='|' read -r mate_recorded mate_expected mate_home <<EOF
$mate_rec
EOF

  # The home with no root of its own: nothing recorded and nothing forced on the
  # pane, so treehouse's own resolution stands exactly as it did before.
  [ -z "$primary_expected" ] \
    || fail "fixture is vacuous: the rootless home resolved to a root of its own '$primary_expected'"
  [ -z "$primary_recorded" ] \
    || fail "a spawn from a home with no root of its own recorded treehouse_root='$primary_recorded'"
  [ "$(leased_root_of_pane "$primary_home")" = UNSET ] \
    || fail "a spawn from a home with no root of its own still forced TREEHOUSE_ROOT on its pane"

  [ -n "$mate_expected" ] \
    || fail "fixture is vacuous: the secondmate home resolved to no root of its own"
  [ "$mate_recorded" = "$mate_expected" ] \
    || fail "a secondmate spawn recorded root '$mate_recorded', not its home's '$mate_expected'"
  [ "$(leased_root_of_pane "$mate_home")" = "$mate_expected" ] \
    || fail "the secondmate's pane was asked to acquire a worktree from a different root than its record names"
  # A home's first spawn under its own root meets a root directory that does not
  # exist yet; the spawn must not depend on the pool tool to create it.
  [ -d "$mate_expected" ] \
    || fail "the first spawn in a secondmate home left its pool root '$mate_expected' missing"
  pass "a spawn records and acquires from its own home's pool root, and forces nothing when the home has none"
}

# leased_by_pane <home> <project> <holder>: run the pane's own acquisition line
# against the REAL treehouse, adding only the non-interactive lease flags a bare
# `treehouse get` would otherwise open a subshell for. Echoes the worktree handed
# over, so where that line lands is the pool tool's own verdict, not a stub's.
leased_by_pane() {  # <home> <project> <holder>
  local home=$1 project=$2 holder=$3 shim line real
  real=$(command -v treehouse)
  shim="$home/pane-real"
  mkdir -p "$shim"
  cat > "$shim/treehouse" <<'SH'
#!/usr/bin/env bash
exec "$FM_TEST_REAL_TREEHOUSE" "$@" --lease --lease-holder "$FM_TEST_LEASE_HOLDER"
SH
  chmod +x "$shim/treehouse"
  line=$(grep -F 'treehouse get' "$home/pane.log" | head -1)
  [ -n "$line" ] || fail "the spawn never asked its pane to acquire a worktree"
  ( cd "$project" \
    && FM_TEST_REAL_TREEHOUSE="$real" FM_TEST_LEASE_HOLDER="$holder" \
       HOME="$home/user-home" PATH="$shim:$PATH" \
       env -u TREEHOUSE_ROOT bash -c "$line" 2>/dev/null )
}

# A project that configures its own pool root keeps it. The spawning home has no
# root of its own, so the spawn forces nothing and treehouse's own precedence -
# which reads the project's treehouse.toml - decides where the slot comes from.
# Needs the real pool tool, because that precedence is treehouse's own behavior.
test_a_projects_own_root_survives_a_home_without_one() {
  local rec home project pool fakebin out lab leased
  rec=$(make_spawn_case project-root th-root-project)
  IFS='|' read -r home project pool fakebin <<EOF
$rec
EOF
  lab="$TMP_ROOT/spawn-project-root/lab-pool"
  mkdir -p "$lab"
  printf 'max_trees = 4\nroot = "%s"\n' "$lab" > "$project/treehouse.toml"
  git -C "$project" add treehouse.toml
  git -C "$project" commit -qm "the project configures its own pool root"

  out=$(FM_FAKE_PANE_LOG="$home/pane.log" \
    fm_test_run_spawn "$home" "$pool" "$fakebin" th-root-project "$project" --scout) \
    || fail "spawn failed: $out"

  leased=$(leased_by_pane "$home" "$project" fm-project-root)
  [ -n "$leased" ] || fail "the pane's own acquisition line leased no worktree"
  case $leased in
    "$lab"/*) ;;
    *) fail "the pane leased '$leased', outside the pool root the project configured at '$lab'" ;;
  esac
  # treehouse keeps its own update-check file under $HOME whatever the root is,
  # so what must be absent there is a POOL: pools are directories, that is a file.
  [ -z "$(find "$home/user-home/.treehouse" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ] \
    || fail "the spawn built a worktree pool under \$HOME instead of the project's own configured pool"
  unlease "" "$project" "$leased"
  pass "a project's own treehouse.toml root still wins when the spawning home has none"
}

# --- teardown returns to the recorded root ----------------------------------

# make_teardown_case <name>: a project clone with one task worktree, a state dir,
# and a fake treehouse that records the TREEHOUSE_ROOT its return ran under.
# Echoes the case dir.
make_teardown_case() {  # <name>
  local case_dir fakebin
  case_dir="$TMP_ROOT/teardown-$1"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# Records the root each `treehouse return` ran under: the literal value when the
# variable is set, and the sentinel UNSET when it is not, so "treehouse resolves
# it itself" is distinguishable from "an empty value was forced".
printf '%s\n' "${TREEHOUSE_ROOT-UNSET}" >> "$FM_FAKE_TREEHOUSE_ROOT_LOG"
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# run_teardown_case <case-dir> [extra meta line...]: write the task record with
# the supplied extra lines, tear the task down, and echo the recorded root.
run_teardown_case() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=treehouse-root-test-task-x1" \
    "$@"
  : > "$case_dir/treehouse-roots.log"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_TREEHOUSE_ROOT_LOG="$case_dir/treehouse-roots.log" \
  PATH="$case_dir/fakebin:$PATH" \
    env -u TREEHOUSE_ROOT \
    "$TEARDOWN" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "teardown failed: $(cat "$case_dir/stderr")"
  cat "$case_dir/treehouse-roots.log"
}

test_task_without_a_recorded_root_tears_down_as_before() {
  local case_dir recorded
  case_dir=$(make_teardown_case legacy)
  recorded=$(run_teardown_case "$case_dir")
  [ "$recorded" = UNSET ] \
    || fail "a task with no recorded root forced TREEHOUSE_ROOT='$recorded' instead of leaving treehouse's own resolution alone"
  pass "a task spawned before the per-home root was recorded still returns against treehouse's own default"
}

test_task_returns_to_its_recorded_root() {
  local case_dir recorded chosen
  case_dir=$(make_teardown_case recorded)
  chosen="$TMP_ROOT/recorded-pool-root"
  recorded=$(run_teardown_case "$case_dir" "treehouse_root=$chosen")
  [ "$recorded" = "$chosen" ] \
    || fail "teardown returned the slot against '$recorded', not its recorded root '$chosen'"
  pass "a task returns its worktree to the pool root its record names"
}

test_a_home_without_its_own_root_is_left_alone
test_secondmate_home_gets_its_own_root
test_two_secondmate_homes_get_two_roots
test_a_recycled_home_slot_does_not_inherit_the_previous_root
test_an_id_that_is_not_one_path_segment_refuses
test_a_marker_the_shared_predicate_rejects_leaves_the_home_alone
test_a_worktree_of_another_clone_is_refused
if command -v treehouse >/dev/null 2>&1; then
  test_two_homes_two_clones_do_not_share_a_pool
  test_a_projects_own_root_survives_a_home_without_one
else
  echo "skip: treehouse not found; the two-clone pool regression needs the real pool tool"
fi
test_spawn_leases_and_records_its_own_homes_root
test_task_without_a_recorded_root_tears_down_as_before
test_task_returns_to_its_recorded_root
