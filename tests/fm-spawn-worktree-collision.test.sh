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
# gone, the same collision spawns normally. That direction is the one a lenient
# tmux probe gets wrong, so the fake tmux below models the real one: a
# display-message read of an ABSENT named target still succeeds, because tmux
# falls back to the client's active window. Window existence lives only in the
# inventory the fake keeps, exactly as it does in a real tmux server. The
# fallback itself is pinned against a real tmux server in
# tests/fm-tmux-target-proof.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-collision)

# make_collision_fakebin <dir>: a fake tmux that
#   - reports the settled worktree as the new pane's cwd,
#   - answers every `display-message -p -t <target>` read successfully, the way
#     a real tmux answers about its active window when the named target is gone,
#   - keeps the session's window inventory in FM_FAKE_WINDOWS, which new-window
#     extends and kill-window prunes, so `list-windows` is the only place window
#     existence can be read from,
#   - logs every send-keys payload to FM_FAKE_SENDLOG so the test can prove what
#     did (and did not) reach the pane.
make_collision_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
WINFILE=${FM_FAKE_WINDOWS:?FM_FAKE_WINDOWS unset}

# arg_after <flag> <argv...>: the value following <flag>, empty when absent.
arg_after() {
  local flag=$1 prev="" a
  shift
  for a in "$@"; do
    if [ "$prev" = "$flag" ]; then
      printf '%s\n' "$a"
      return 0
    fi
    prev=$a
  done
  return 1
}

case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac

case "${1:-}" in
  display-message)
    case "$*" in
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%0\n' ;;
    esac
    exit 0
    ;;
  list-windows)
    fmt=$(arg_after -F "$@") || fmt='#{window_name}'
    pat_name='#{window_name}'
    pat_id='#{window_id}'
    pat_index='#{window_index}'
    i=0
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      i=$((i + 1))
      line=${fmt//$pat_name/$w}
      line=${line//$pat_id/@$i}
      line=${line//$pat_index/$i}
      printf '%s\n' "$line"
    done < "$WINFILE"
    exit 0
    ;;
  new-window)
    name=$(arg_after -n "$@") || name=""
    [ -z "$name" ] || printf '%s\n' "$name" >> "$WINFILE"
    printf '@9\n'
    exit 0
    ;;
  kill-window)
    target=$(arg_after -t "$@") || target=""
    name=${target#*:}
    name=${name#=}
    if [ -n "$name" ]; then
      grep -Fxv -- "$name" "$WINFILE" > "$WINFILE.next" || :
      mv "$WINFILE.next" "$WINFILE"
    fi
    exit 0
    ;;
  send-keys)
    printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:?FM_FAKE_SENDLOG unset}"
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_collision_case <name> <new-id> <holder-id>: build a home whose <holder-id>
# already records the shared worktree, plus the project and that worktree. The
# session inventory starts with the captain's own window only; a case that wants
# the holder's endpoint to still exist adds it.
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
  printf 'captain\n' > "$case_dir/windows"
  fm_write_meta "$home/state/$holder.meta" \
    "window=firstmate:fm-$holder" \
    "endpoint_task_id=$holder" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/sendlog|$case_dir/windows"
}

read_collision_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SENDLOG WINDOWS <<EOF
$1
EOF
}

# open_window <name>: the endpoint exists in the session inventory.
open_window() {
  printf '%s\n' "$1" >> "$WINDOWS"
}

window_is_open() {  # <name>
  grep -Fqx -- "$1" "$WINDOWS"
}

# run_collision_spawn <id>: spawn <id> with the fake tmux.
run_collision_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_WINDOWS="$WINDOWS" \
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
  open_window "fm-$holder"
  head_before=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)

  out=$(run_collision_spawn "$id")
  status=$?

  expect_code 1 "$status" "spawn onto a live task's worktree should refuse"
  assert_contains "$out" "$id" "refusal did not name the spawning task"
  assert_contains "$out" "$holder" "refusal did not name the owning task"
  assert_contains "$out" "$WT_DIR" "refusal did not name the contested worktree path"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn still recorded task metadata"

  # The branch is created by the worker the launch command starts, so the
  # refusal is only worth anything if it lands before that command does. What
  # goes on the wire is the harness invocation carrying the brief PATH, so that
  # path is what a launch send would really log; the allowed retry below sends
  # it into this same log, which is what proves this assertion can fail.
  assert_grep "treehouse get" "$SENDLOG" "refused spawn never reached the pane at all"
  assert_no_grep "$HOME_DIR/data/$id/brief.md" "$SENDLOG" \
    "refused spawn still sent the launch command to the pane"
  head_after=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)
  [ "$head_after" = "$head_before" ] || \
    fail "refused spawn changed the contested worktree's branch: $head_before -> $head_after"

  # The refusal must not leave its own pane parked in the contested worktree,
  # and the owner's endpoint is none of its business.
  window_is_open "fm-$holder" || fail "refusal killed the OWNING task's endpoint"
  ! window_is_open "fm-$id" || \
    fail "refusal left its own pane orphaned inside the contested worktree"

  # The natural operator response: resolve the ownership and re-run the same
  # task id. A refusal that poisons its own retry is not a working refusal.
  rm -f "$HOME_DIR/state/$holder.meta"
  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "re-running the refused task id should work once the collision is gone"
  assert_contains "$out" "spawned $id" "retry after a refusal did not report success"
  assert_grep "$HOME_DIR/data/$id/brief.md" "$SENDLOG" \
    "the allowed retry sent no launch command, so the refused-spawn assertion above pins nothing"

  pass "a worktree still owned by a live task refuses the spawn before the launch command is sent"
  pass "a refusal takes its own endpoint back down, so re-running the same id works"
}

# The stale-record half: the same recorded collision must not hold the slot
# forever once the owner's endpoint is gone. The record still names
# firstmate:fm-<holder>, and a bare display-message read of that absent target
# still succeeds - only the session inventory can tell the window is gone.
test_dead_owner_does_not_block_spawn() {
  local rec id holder out status
  id=collide-new-k3
  holder=collide-holder-k4
  rec=$(make_collision_case collide-dead "$id" "$holder")
  read_collision_record "$rec"

  out=$(run_collision_spawn "$id")
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
  open_window "fm-$holder"
  # Same live holder, but it owns a DIFFERENT worktree.
  fm_write_meta "$HOME_DIR/state/$holder.meta" \
    "window=firstmate:fm-$holder" \
    "endpoint_task_id=$holder" \
    "worktree=$PROJ_DIR-other" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_collision_spawn "$id")
  status=$?

  expect_code 0 "$status" "an uncontested worktree should spawn normally"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  # `treehouse get` is the pool command this spawn DOES send, so the log is
  # live; `treehouse return` is the one that would hand a slot back, and it is
  # the command a regression here would actually emit.
  assert_grep "treehouse get" "$SENDLOG" "spawn never reached the pane at all"
  assert_no_grep "treehouse return" "$SENDLOG" "spawn returned a slot to the pool"
  pass "an uncontested spawn is unaffected by the ownership guard"
}

test_live_owner_blocks_spawn
test_dead_owner_does_not_block_spawn
test_uncontested_spawn_is_unaffected

echo "# all fm-spawn-worktree-collision tests passed"
