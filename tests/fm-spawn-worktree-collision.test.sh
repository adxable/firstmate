#!/usr/bin/env bash
# Regression test for fm-spawn.sh's worktree-ownership guard
# (bin/fm-spawn.sh, worktree_owner_conflict + validate_spawn_worktree).
#
# A worktree pool decides a slot is free from process presence inside the slot
# directory, so a worker parked elsewhere (a shell sitting in the validation
# pipeline's own directory) leaves its slot reading `available` while it still
# owns the worktree. Handing that slot to a second task lets the newcomer reset
# the branch out from under work that has not landed. The guard therefore
# refuses a spawn onto a worktree that another task's state/<id>.meta already
# records as its own while that task's endpoint is still there, and it must
# refuse BEFORE the launch brief reaches the pane, since the branch is created
# by the worker that reads the brief.
#
# A stale record must not hold a slot hostage: when the recorded endpoint is
# gone, the same collision spawns normally.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-collision)

# make_collision_fakebin <dir>: a fake tmux that
#   - reports the settled worktree as the new pane's cwd,
#   - answers the endpoint-existence probe (`display-message -p -t <target>
#     '#{pane_id}'`) with failure for the targets listed in FM_FAKE_DEAD_TARGETS
#     and success for every other target,
#   - logs every send-keys payload to FM_FAKE_SENDLOG so the test can prove what
#     did (and did not) reach the pane.
make_collision_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_id}"*)
    # Endpoint-existence probe: fail only for a target declared gone.
    target=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-t" ] && target=$a
      prev=$a
    done
    case " ${FM_FAKE_DEAD_TARGETS:-} " in
      *" $target "*) exit 1 ;;
    esac
    printf '%%1\n'
    exit 0
    ;;
esac
case "${1:-}" in
  send-keys)
    printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:?FM_FAKE_SENDLOG unset}"
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_collision_case <name> <new-id> <holder-id>: build a home whose <holder-id>
# already records the shared worktree, plus the project and that worktree.
make_collision_case() {
  local name=$1 id=$2 holder=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_collision_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "fm/$holder"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/$holder.meta" \
    "window=firstmate:fm-$holder" \
    "endpoint_task_id=$holder" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/sendlog"
}

read_collision_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SENDLOG <<EOF
$1
EOF
}

# run_collision_spawn <id> <dead-targets>: spawn <id> with the fake tmux, where
# <dead-targets> is the space-separated set of endpoints that are gone.
run_collision_spawn() {
  local id=$1 dead=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_DEAD_TARGETS="$dead" \
    FM_FAKE_SENDLOG="$SENDLOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The incident: the pool hands out a slot another live task still owns.
test_live_owner_blocks_spawn() {
  local rec id holder out status head_before head_after
  id=collide-new-k1
  holder=collide-holder-k2
  rec=$(make_collision_case collide-live "$id" "$holder")
  read_collision_record "$rec"
  head_before=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)

  out=$(run_collision_spawn "$id" "")
  status=$?

  expect_code 1 "$status" "spawn onto a live task's worktree should refuse"
  assert_contains "$out" "$id" "refusal did not name the spawning task"
  assert_contains "$out" "$holder" "refusal did not name the owning task"
  assert_contains "$out" "$WT_DIR" "refusal did not name the contested worktree path"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn still recorded task metadata"

  # The branch is created by the worker that reads the brief, so the refusal is
  # only worth anything if it lands before the brief does. The `treehouse get`
  # line proves the log captured what DID reach the pane, so the brief
  # assertion cannot pass merely because nothing was ever logged.
  assert_grep "treehouse get" "$SENDLOG" "refused spawn never reached the pane at all"
  assert_no_grep "brief for $id" "$SENDLOG" \
    "refused spawn still sent the launch brief to the pane"
  head_after=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)
  [ "$head_after" = "$head_before" ] || \
    fail "refused spawn changed the contested worktree's branch: $head_before -> $head_after"

  pass "a worktree still owned by a live task refuses the spawn before the brief is sent"
}

# The stale-record half: the same recorded collision must not hold the slot
# forever once the owner's endpoint is gone.
test_dead_owner_does_not_block_spawn() {
  local rec id holder out status
  id=collide-new-k3
  holder=collide-holder-k4
  rec=$(make_collision_case collide-dead "$id" "$holder")
  read_collision_record "$rec"

  out=$(run_collision_spawn "$id" "firstmate:fm-$holder")
  status=$?

  expect_code 0 "$status" "spawn should proceed when the recording task's endpoint is gone"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the reclaimed worktree"
  pass "a stale worktree record whose endpoint is gone does not block the slot"
}

# A spawn that collides with nothing must be unaffected by the guard, and must
# leave the pool alone: the guard only reads durable records.
test_uncontested_spawn_is_unaffected() {
  local rec id holder out status
  id=collide-free-k5
  holder=collide-elsewhere-k6
  rec=$(make_collision_case collide-free "$id" "$holder")
  read_collision_record "$rec"
  # Same live holder, but it owns a DIFFERENT worktree.
  fm_write_meta "$HOME_DIR/state/$holder.meta" \
    "window=firstmate:fm-$holder" \
    "endpoint_task_id=$holder" \
    "worktree=$PROJ_DIR-other" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_collision_spawn "$id" "")
  status=$?

  expect_code 0 "$status" "an uncontested worktree should spawn normally"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  # Proves the send log is live, so the release assertion below is not vacuous.
  assert_grep "treehouse get" "$SENDLOG" "spawn never reached the pane at all"
  assert_no_grep "release" "$SENDLOG" "spawn sent a pool-releasing command"
  pass "an uncontested spawn is unaffected by the ownership guard"
}

test_live_owner_blocks_spawn
test_dead_owner_does_not_block_spawn
test_uncontested_spawn_is_unaffected

echo "# all fm-spawn-worktree-collision tests passed"
