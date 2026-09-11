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
#
# What this fake CANNOT check, stated so nobody counts it as coverage: neither
# the harness worker nor the real worktree pool ever runs here, so nothing in
# this file can observe the contested worktree's branch move, and no assertion
# about its HEAD would be capable of failing. The branch reset is a property of
# the real worker and of `treehouse get`, and the pool tool's own termination
# behavior is pinned separately against real binaries in
# tests/fm-treehouse-pool-termination-live-e2e.test.sh. What this file does pin
# about the refusal's ordering is the durable record and the wire: no
# state/<id>.meta is written and no launch command reaches the pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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
      # The foreground command a relaunch's agent-free check reads; a shell name
      # is what makes an adopted endpoint eligible for a replacement agent.
      *'#{pane_current_command}'*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}" ;;
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
  fm_test_spawn_brief "$home" "$id"
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
  local rec id holder out status
  id=collide-new-k1
  holder=collide-holder-k2
  rec=$(make_collision_case collide-live "$id" "$holder")
  read_collision_record "$rec"
  open_window "fm-$holder"

  out=$(run_collision_spawn "$id")
  status=$?

  expect_code 1 "$status" "spawn onto a live task's worktree should refuse"
  assert_contains "$out" "$id" "refusal did not name the spawning task"
  assert_contains "$out" "$holder" "refusal did not name the owning task"
  assert_contains "$out" "$WT_DIR" "refusal did not name the contested worktree path"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn still recorded task metadata"

  # The branch is created by the worker the launch command starts, so the
  # refusal is only worth anything if it lands before that command does. What
  # goes on the wire is the harness invocation carrying the rendered
  # launch-brief PATH, so that path is what a launch send would really log; the
  # allowed retry below sends it into this same log, which is what proves this
  # assertion can fail. It must be launch-brief.md and not the brief.md the
  # captain wrote: fm-spawn renders the launch brief and sends only that, so
  # pinning brief.md here would never match and the assertion would pass
  # vacuously on a refusal that had in fact already launched.
  assert_grep "treehouse get" "$SENDLOG" "refused spawn never reached the pane at all"
  assert_no_grep "$HOME_DIR/data/$id/launch-brief.md" "$SENDLOG" \
    "refused spawn still sent the launch command to the pane"

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
  assert_grep "$HOME_DIR/data/$id/launch-brief.md" "$SENDLOG" \
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

# run_collision_relaunch <id>: relaunch <id> onto its own recorded endpoint.
run_collision_relaunch() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_WINDOWS="$WINDOWS" \
    FM_FAKE_SENDLOG="$SENDLOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1
}

# A relaunch creates no endpoint and acquires no worktree: it adopts the ones
# its own record already names, holding whatever the previous agent left there.
# So when the ownership guard refuses on that path, the refusal is the whole
# remedy - it must end nothing, because the endpoint under it belongs to the
# task being relaunched, not to this spawn. That a kill IS visible through this
# same window inventory is what test_live_owner_blocks_spawn pins on the fresh
# path, where the guard does take its own pane back down.
test_relaunch_refusal_leaves_the_adopted_endpoint_alone() {
  local rec id holder out status
  id=collide-relaunch-m4
  holder=collide-relaunch-holder-m5
  rec=$(make_collision_case collide-relaunch "$id" "$holder")
  read_collision_record "$rec"
  open_window "fm-$holder"
  open_window "fm-$id"
  # A refused relaunch sends nothing at all, so the log the send assertion below
  # reads has to exist before the run for that assertion to be readable.
  : > "$SENDLOG"
  # The task being relaunched: same worktree as the holder, its own endpoint
  # still standing, and no agent in it (the fake pane reports a bare shell).
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_collision_relaunch "$id")
  status=$?

  expect_code 1 "$status" "relaunch onto a worktree another live task owns should refuse"
  assert_contains "$out" "$holder" "relaunch refusal did not name the owning task"
  assert_contains "$out" "$WT_DIR" "relaunch refusal did not name the contested worktree path"
  window_is_open "fm-$id" \
    || fail "the relaunch refusal ended the endpoint it had only adopted, killing the relaunched task's own terminal"
  window_is_open "fm-$holder" || fail "the relaunch refusal killed the OWNING task's endpoint"
  assert_no_grep "$HOME_DIR/data/$id/launch-brief.md" "$SENDLOG" \
    "refused relaunch still sent the launch command to the pane"
  # No pool acquisition ran here, so the worktree stands on the branch the
  # holder's agent left it on; a note telling the operator otherwise would send
  # them to inspect a branch move that never happened.
  assert_not_contains "$out" "already detached that worktree" \
    "the relaunch refusal claimed a detach no acquisition on this path performed"
  pass "the ownership refusal on a relaunch leaves the adopted endpoint and worktree exactly as they stood"
}

# --- herdr: the refusal closes nothing, and says so --------------------------
#
# The pool is the worktree provider for herdr too, and only tmux's pane
# termination has been shown to leave an acquired worktree alone, so the
# ownership refusal must close no herdr endpoint - including on the DEFAULT
# projected layout, whose projection-abort cleanup would otherwise close the
# same pane from the exit trap. The single dimension under test is whether a
# `pane close` reaches the herdr CLI, so every scene below reads the same fake
# CLI log, and the last scene is a refusal that DOES close, which is what makes
# the "closed nothing" assertions capable of failing.
#
# The fake herdr CLI keeps its workspace/tab/pane inventory in a JSON state file
# and answers the reads bin/backends/herdr.sh makes, following the stateful
# fake in tests/fm-backend-herdr.test.sh. No real herdr is started here.
make_herdr_fakebin() {  # <dir> <state-file>
  local dir=$1 state=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '{"next":10,"workspaces":[{"workspace_id":"w1","label":"%s","focused":true,"active_tab_id":"w1:t1"}],"tabs":[{"tab_id":"w1:t1","label":"captain","workspace_id":"w1","pane_id":"w1:p1","focused":true}]}\n' \
    firstmate > "$state"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE=${FM_FAKE_HERDR_STATE:?}
LOG=${FM_FAKE_HERDR_LOG:?}
printf '%s\n' "$*" >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

ws=""; label=""; prev=""
for a in "$@"; do
  case "$prev" in
    --workspace) ws=$a ;;
    --label) label=$a ;;
  esac
  prev=$a
done

case "${1:-} ${2:-}" in
  "status --json")
    # A running server reports its OWN release, and the presentation floor is
    # composed from both sides (bin/backends/herdr.sh
    # fm_backend_herdr_presentation_release_supported): a server whose release
    # cannot be read is indeterminate and drops the spawn to the flat layout,
    # which would leave the projected scenes below testing nothing.
    printf '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true,"version":"0.8.0","protocol":19}}\n'
    ;;
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\n' \
      "${HERDR_SESSION:-default}" "${FM_FAKE_HERDR_SOCKET:?}"
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "w$n:t$dn" --arg paneid "w$n:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel, focused:false, active_tab_id:$tabid}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid, focused:false}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"w%s:t%s"},"root_pane":{"pane_id":"w%s:p%s"}}}\n' \
      "$wsid" "$label" "$n" "$dn" "$n" "$dn"
    ;;
  "workspace move")
    printf '{"result":{}}\n'
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, focused:false}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "tab get")
    jq_state --arg t "${3:-}" '{result:{tab:(.tabs[]|select(.tab_id==$t)|{tab_id, workspace_id})}}'
    ;;
  "tab focus")
    printf '{"result":{}}\n'
    ;;
  "tab close")
    jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id, tab_id}]}}'
    ;;
  "pane get")
    pane=${3:-}
    if jq_state -e --arg p "$pane" '[.tabs[]|select(.pane_id==$p)] | length == 1' >/dev/null; then
      jq_state --arg p "$pane" --arg cwd "${FM_FAKE_PANE_PATH:-}" \
        '(.tabs[]|select(.pane_id==$p)) as $t
         | {result:{pane:{pane_id:$t.pane_id, tab_id:$t.tab_id, workspace_id:$t.workspace_id, foreground_cwd:$cwd}}}'
    else
      # Real herdr answers a closed pane with this business-logic error body and
      # a nonzero status; both are load-bearing here, one for the pool-safety
      # instrumentation and one for the endpoint-existence probe.
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$pane"
      exit 1
    fi
    ;;
  "pane close")
    jq_state --arg p "${3:-}" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "pane run"|"pane send-text")
    printf '%s\n' "${4:-}" >> "${FM_FAKE_SENDLOG:?}"
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found","message":"no agent"}}\n'
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_herdr_case <name> <new-id> <holder-id> <projection: on|off>
# Builds a home on backend=herdr whose <holder-id> records the shared worktree
# on a herdr endpoint the fake reports as present.
make_herdr_case() {
  local name=$1 id=$2 holder=$3 projection=$4 case_dir home proj wt fakebin state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  state="$case_dir/herdr-state.json"
  mkdir -p "$case_dir"
  fakebin=$(make_herdr_fakebin "$case_dir/fake" "$state")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'herdr\n' > "$home/config/backend"
  [ "$projection" = on ] || printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$proj" "$wt" "fm/$holder"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  # The holder's endpoint is a pane the fake knows about, so the guard's
  # existence probe proves ownership rather than guessing it.
  jq '.tabs += [{tab_id:"w1:t9", label:"holder", workspace_id:"w1", pane_id:"w1:p9", focused:false}]' \
    "$state" > "$state.seed" && mv "$state.seed" "$state"
  fm_write_meta "$home/state/$holder.meta" \
    "window=fmtest:w1:p9" \
    "endpoint_task_id=$holder" \
    "backend=herdr" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/sendlog|$state|$case_dir/herdr.log"
}

read_herdr_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SENDLOG HERDR_STATE HERDR_LOG <<EOF
$1
EOF
}

# run_herdr_spawn <id> <pane-cwd>: spawn <id> on the fake herdr, with the pane
# settling into <pane-cwd>.
#
# The launcher identity is pinned, never inherited. fm-spawn refuses to place a
# worker whose parent pane belongs to a different herdr server than the session
# it targets, so an ambient HERDR_PANE_ID/HERDR_SOCKET_PATH - which every run
# inside a real herdr pane has - would refuse this fixture for a reason that has
# nothing to do with worktree ownership.
run_herdr_spawn() {
  local id=$1 pane_path=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='' HERDR_SESSION=fmtest \
    HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$HOME_DIR/herdr.sock" \
    FM_FAKE_PANE_PATH="$pane_path" FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" FM_FAKE_SENDLOG="$SENDLOG" \
    FM_FAKE_HERDR_SOCKET="$HOME_DIR/herdr.sock" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# herdr_task_pane <output>: the pane id this spawn's own endpoint resolved to,
# read from the message that names it, so both sides of the close dimension are
# judged on the same exact pane rather than on any close at all - the seeded
# default tab is closed during every projection create.
herdr_task_pane() {
  printf '%s\n' "$1" \
    | sed -n 's/.*[Ii]nspect target fmtest:\([^ ]*\).*/\1/p;s/.*[Ii]nspect window fmtest:\([^ ]*\).*/\1/p;s/.*left the herdr endpoint fmtest:\([^ ]*\) open.*/\1/p' \
    | head -1
}

herdr_pane_was_closed() {  # <pane-id>
  grep -Fq "pane close $1 " "$HERDR_LOG"
}

herdr_pane_still_present() {  # <pane-id>
  jq -e --arg p "$1" '[.tabs[] | select(.pane_id == $p)] | length == 1' "$HERDR_STATE" >/dev/null
}

# Every sentence the refusal prints has to be true on the surface it printed on.
# Two classes of sentence cannot be: an instruction to perform the close this
# same code withholds as unverified, and a promise about a later run, which no
# record backs because a refusal writes no state/<id>.meta at all. These are
# read out of the text the spawn actually emitted, not out of its source.
assert_refusal_claims_only_what_holds() {  # <output> <label>
  local out=$1 label=$2 fragment
  for fragment in "by hand" "Close " "re-run" "rerun" "will refuse"; do
    case "$out" in
      *"$fragment"*)
        fail "$label: the refusal printed \"$fragment\", which is either an instruction to perform the close it declines as unverified or a promise about a later run that nothing records"$'\n'"--- output ---"$'\n'"$out"
        ;;
    esac
  done
}

assert_herdr_refusal_left_the_endpoint() {  # <output> <id> <holder> <label>
  local out=$1 id=$2 holder=$3 label=$4 pane
  assert_contains "$out" "$holder" "$label: refusal did not name the owning task"
  assert_contains "$out" "$WT_DIR" "$label: refusal did not name the contested worktree"
  assert_contains "$out" "left the herdr endpoint" "$label: refusal did not report the endpoint it left open"
  assert_contains "$out" "holding worktree '$WT_DIR'" "$label: refusal did not name the worktree that endpoint is holding"
  assert_refusal_claims_only_what_holds "$out" "$label"
  assert_absent "$HOME_DIR/state/$id.meta" "$label: refused spawn still recorded task metadata"
  pane=$(herdr_task_pane "$out")
  [ -n "$pane" ] || fail "$label: could not read the endpoint pane out of the refusal"
  ! herdr_pane_was_closed "$pane" || fail "$label: the refusal closed its herdr pane $pane"
  herdr_pane_still_present "$pane" || fail "$label: the herdr pane $pane is gone from the session"
}

# The default layout: projection ON, so the exit trap's projection-abort
# cleanup is armed and would close the very pane sitting in the contested
# worktree.
test_herdr_projected_refusal_closes_nothing() {
  local rec id holder out status
  id=collide-herdr-k7
  holder=collide-herdr-holder-k8
  rec=$(make_herdr_case collide-herdr-projected "$id" "$holder" on)
  read_herdr_record "$rec"

  out=$(run_herdr_spawn "$id" "$WT_DIR")
  status=$?

  expect_code 1 "$status" "projected herdr spawn onto a live task's worktree should refuse"
  assert_herdr_refusal_left_the_endpoint "$out" "$id" "$holder" "projected herdr"
  pass "the refusal on the default projected herdr layout closes no pane and reports what it left open"
}

# The same refusal without projection, where nothing but this guard could have
# closed the pane.
test_herdr_flat_refusal_closes_nothing() {
  local rec id holder out status
  id=collide-herdr-k9
  holder=collide-herdr-holder-m1
  rec=$(make_herdr_case collide-herdr-flat "$id" "$holder" off)
  read_herdr_record "$rec"

  out=$(run_herdr_spawn "$id" "$WT_DIR")
  status=$?

  expect_code 1 "$status" "flat herdr spawn onto a live task's worktree should refuse"
  assert_herdr_refusal_left_the_endpoint "$out" "$id" "$holder" "flat herdr"
  pass "the refusal on a herdr spawn without projection closes no pane either"
}

# The other side of the same dimension, through the same log: an isolation
# refusal on the projected layout still closes its pane. This is deliberately
# unchanged by this work, and it is what proves the "closed nothing" assertions
# above can fail.
#
# Which of the two isolation refusals this reaches is fixed by construction
# rather than chosen, and the constraint is specific to the route this case
# drives. Here the worktree is discovered from the pane by `treehouse get`:
# WT starts empty and the discovery poll screens every read with the same
# spawn_worktree_isolated predicate validate_spawn_worktree applies
# (bin/fm-spawn.sh), so the poll can never adopt a path the guard would then
# reject. A pane path that is no worktree at all is therefore refused by the
# poll giving up, and on THIS route the guard's own isolation branch cannot be
# reached at all. Other routes do reach it - orca sets WT from its own
# `orca worktree create` result and is never screened by the poll, which is
# the branch tests/fm-backend-orca.test.sh exercises, and a relaunch validates
# the worktree it adopts - but neither of those opens the projected pane whose
# close this case exists to observe. The refusal named below is the settle
# poll's, pinned by its own sentence so a rewording shows up here instead of
# being absorbed by a phrase both refusals share.
test_herdr_projected_isolation_refusal_still_closes() {
  local rec id holder out status stray pane
  id=collide-herdr-m2
  holder=collide-herdr-holder-m3
  rec=$(make_herdr_case collide-herdr-isolation "$id" "$holder" on)
  read_herdr_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  stray="$TMP_ROOT/collide-herdr-isolation/not-a-worktree"
  mkdir -p "$stray"

  out=$(run_herdr_spawn "$id" "$stray")
  status=$?

  expect_code 1 "$status" "a pane path that never becomes a worktree should refuse"
  assert_contains "$out" "treehouse get did not enter an isolated worktree" \
    "the settle poll's isolation refusal did not fire"
  pane=$(herdr_task_pane "$out")
  [ -n "$pane" ] || fail "could not read the endpoint pane out of the isolation refusal"
  herdr_pane_was_closed "$pane" \
    || fail "no close of $pane was observed on the isolation refusal, so the collision scenes above prove nothing"
  ! herdr_pane_still_present "$pane" \
    || fail "the isolation refusal logged a close of $pane that the session never applied"
  pass "the isolation refusal still closes its projected pane, so a close is visible through this same instrumentation"
}

test_live_owner_blocks_spawn
test_dead_owner_does_not_block_spawn
test_uncontested_spawn_is_unaffected
test_relaunch_refusal_leaves_the_adopted_endpoint_alone

# The herdr scenes speak the backend's JSON through the fake CLI, so without jq
# they would fail on the ownership assertions rather than on the missing tool.
# The tmux scenes above need no JSON and always run.
if command -v jq >/dev/null 2>&1; then
  test_herdr_projected_refusal_closes_nothing
  test_herdr_flat_refusal_closes_nothing
  test_herdr_projected_isolation_refusal_still_closes
else
  echo "skip: jq not found (the herdr scenes need it to drive the fake herdr CLI)"
fi

echo "# all fm-spawn-worktree-collision tests passed"
