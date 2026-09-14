#!/usr/bin/env bash
# Live driver for the per-home treehouse worktree pool.
# Runs the real bin/fm-treehouse-root.sh, bin/fm-spawn.sh, bin/fm-teardown.sh,
# bin/fm-bootstrap.sh and bin/fm-claude-trust.sh against the REAL treehouse
# binary on this machine, and prints a transcript of what each scenario did.
set -u

ROOT_REPO=${1:?usage: driver.sh <repo-root>}
cd "$ROOT_REPO"
# shellcheck source=tests/fixtures.sh
. "$ROOT_REPO/tests/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

RESOLVE="$ROOT/bin/fm-treehouse-root.sh"
TRUST="$ROOT/bin/fm-claude-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-live)
FAKE_HOME="$TMP_ROOT/user-home"; mkdir -p "$FAKE_HOME"

hdr() { printf '\n========== %s ==========\n' "$*"; }
say() { printf '  %s\n' "$*"; }

echo "treehouse under test: $(command -v treehouse) $(treehouse --version 2>&1 | tr -d '[:space:]')"
echo "repo under test:      $ROOT_REPO ($(git rev-parse --short HEAD))"

short() { printf '%s' "${1#"$TMP_ROOT"/}"; }

# ---------------------------------------------------------------- world -------
make_two_clone_world() {
  local dir=$1/w seed=$1/w/seed
  mkdir -p "$dir"
  git init -q --bare "$dir/remote.git"
  git -C "$dir/remote.git" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$seed"
  printf 'hello\n' > "$seed/README.md"
  git -C "$seed" add README.md; git -C "$seed" commit -qm baseline
  git -C "$seed" remote add origin "$dir/remote.git"; git -C "$seed" push -q origin main
  rm -rf "$seed"
  git clone -q "$dir/remote.git" "$dir/main-home/adx-worker"
  git clone -q "$dir/remote.git" "$dir/mate-home/adx-worker"
}
lease() { ( cd "$2" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$1" treehouse get --lease --lease-holder "$3" 2>/dev/null ); }
unlease() { ( cd "$2" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$1" treehouse return --force "$3" >/dev/null 2>&1 ); }
common_dir_of() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }
pool_dir_of() { ( cd "$1" && cd ../.. && pwd -P ); }
can_spawn_into() {
  local store="$TMP_ROOT/trust-$RANDOM"; mkdir -p "$store"
  CLAUDE_CONFIG_DIR="$store" HOME="$store" "$TRUST" "$1" "$2" >/dev/null 2>&1
}
make_home() {
  local home="$TMP_ROOT/homes/$1"
  mkdir -p "$home/config" "$home/state" "$home/data"
  [ "${2:-primary}" != secondmate ] || printf '%s\n' "$1" > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}
resolve() { HOME="$FAKE_HOME" FM_HOME="$1" "$RESOLVE"; }

# =============================================================== S1 ===========
hdr "S1  the reported field failure, and the same fleet after the change"
S1=$TMP_ROOT/s1; mkdir -p "$S1"; make_two_clone_world "$S1"
CA=$S1/w/main-home/adx-worker   # main home's own clone of adx-worker
CB=$S1/w/mate-home/adx-worker   # second mate's own clone of the same repository

say "main home clone: $(short "$CA")"
say "mate home clone: $(short "$CB")"
say "same remote:     $(git -C "$CA" remote get-url origin | sed "s|$TMP_ROOT/||")"

say ""
say "-- BEFORE: one shared pool root, exactly the 2026-09-13 incident --"
SHARED=$S1/shared-root; mkdir -p "$SHARED"
SLOT_A=$(lease "$SHARED" "$CA" fm-main)
say "main home leases and frees a slot:  $(short "$SLOT_A")"
unlease "$SHARED" "$CA" "$SLOT_A"
SLOT_B=$(lease "$SHARED" "$CB" fm-mate)
say "second mate is then handed:         $(short "$SLOT_B")"
say "that slot is backed by the clone:   $(short "$(common_dir_of "$SLOT_B")")"
if can_spawn_into "$SLOT_B" "$CB"; then
  say "RESULT: the second mate COULD start work  <-- bug did not reproduce"
else
  say "RESULT: fm-claude-trust.sh REFUSES the spawn; the second mate can start nothing"
fi

say ""
say "-- AFTER: each home resolves its own pool root --"
MAIN=$(make_home main-home); MATE=$(make_home mate-9821 secondmate)
R_MAIN=$(resolve "$MAIN"); R_MATE=$(resolve "$MATE")
say "main home resolves:   '${R_MAIN}'  (empty = treehouse's own resolution, unchanged)"
say "mate home resolves:   $(printf '%s' "$R_MATE" | sed "s|$FAKE_HOME|\$HOME|")"
R_MAIN_EFF=$S1/main-root; mkdir -p "$R_MAIN_EFF"   # stands in for the main home's existing ~/.treehouse
SLOT_A2=$(lease "$R_MAIN_EFF" "$CA" fm-main2); unlease "$R_MAIN_EFF" "$CA" "$SLOT_A2"
SLOT_B2=$(lease "$R_MATE" "$CB" fm-mate2)
say "main home pool dir:   $(short "$(pool_dir_of "$SLOT_A2")")"
say "mate home pool dir:   $(printf '%s' "$(pool_dir_of "$SLOT_B2")" | sed "s|$FAKE_HOME|\$HOME|")"
say "mate slot is backed by the clone:   $(short "$(common_dir_of "$SLOT_B2")")"
if can_spawn_into "$SLOT_B2" "$CB"; then
  say "RESULT: the second mate CAN start work on its own clone"
else
  say "RESULT: the second mate still could not start work  <-- FAIL"
fi
unlease "$R_MATE" "$CB" "$SLOT_B2"; unlease "$SHARED" "$CB" "$SLOT_B"

# =============================================================== S2/S3/S5 =====
write_treehouse_stub() {
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != get ] || [ "${2:-}" != --help ]; then exit 0; fi
printf 'Acquire a worktree from the pool and open a subshell\n\nFlags:\n      --lease   Take a durable lease\n'
SH
  [ "$2" != yes ] || printf '\nprintf '"'"'\\nGlobal Flags:\\n      --root string   Worktree root directory\\n'"'"'\n' >> "$1/treehouse"
  chmod +x "$1/treehouse"
}
make_spawn_case() {  # <name> <id> <kind> <root-support>
  local name=$1 id=$2 kind=$3 supports=$4 case_dir home project pool fakebin sha
  case_dir="$TMP_ROOT/spawn-$name"; home=$case_dir/home; project=$case_dir/project; pool=$case_dir/pool
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  write_treehouse_stub "$fakebin" "$supports"
  mkdir -p "$home/state" "$home/config" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"; touch "$home/state/.last-watcher-beat"
  [ "$kind" != secondmate ] || printf '%s\n' "$name" > "$home/.fm-secondmate-home"
  git init -q -b main "$project"; printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md; git -C "$project" commit -qm initial
  sha=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add -q --detach "$pool" "$sha"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        case $prev in -t) ;; *) [ "$a" = Enter ] || [ "$a" = -l ] || [ "$a" = -t ] \
          || [ "$a" = send-keys ] || printf '%s\n' "$a" >> "$FM_FAKE_PANE_LOG" ;; esac
        prev=$a
      done
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s|%s|%s|%s\n' "$home" "$project" "$pool" "$fakebin"
}
run_spawn() {  # <name> <id> <kind> <root-support>
  local rec home project pool fakebin out rc
  rec=$(make_spawn_case "$@")
  IFS='|' read -r home project pool fakebin <<EOF
$rec
EOF
  out=$(FM_FAKE_PANE_LOG="$home/pane.log" fm_test_run_spawn "$home" "$pool" "$fakebin" "$2" "$project" --scout 2>&1) && rc=0 || rc=$?
  SPAWN_HOME=$home; SPAWN_RC=$rc; SPAWN_OUT=$out
}

hdr "S2  a second mate's spawn acquires from, and records, its own pool root"
run_spawn mate-spawn th-mate secondmate yes
say "spawn exit: $SPAWN_RC"
say "line the pane is asked to run:"
printf '    %s\n' "$(grep -F 'treehouse get' "$SPAWN_HOME/pane.log" | head -1 | sed "s|$TMP_ROOT|<tmp>|g")"
say "task record ($(basename "$SPAWN_HOME")/state/th-mate.meta):"
printf '    %s\n' "$(grep -E '^(worktree|treehouse_root|project|kind)=' "$SPAWN_HOME/state/th-mate.meta" | sed "s|$TMP_ROOT|<tmp>|g")"

hdr "S3  a home with no pool root of its own is untouched"
run_spawn primary-spawn th-primary primary yes
say "spawn exit: $SPAWN_RC"
say "line the pane is asked to run:"
printf '    %s\n' "$(grep -F 'treehouse get' "$SPAWN_HOME/pane.log" | head -1)"
if grep -q '^treehouse_root=' "$SPAWN_HOME/state/th-primary.meta"; then
  say "task record: treehouse_root= PRESENT  <-- FAIL, the home should not have moved"
else
  say "task record: no treehouse_root= line, so teardown keeps treehouse's own resolution"
fi

hdr "S3b a project that configures its own pool root keeps it (real treehouse)"
S3=$TMP_ROOT/s3; mkdir -p "$S3"; make_two_clone_world "$S3"
PC=$S3/w/main-home/adx-worker
OWN=$S3/project-own-root; mkdir -p "$OWN"
printf 'root = "%s"\n' "$OWN" > "$PC/treehouse.toml"
git -C "$PC" add treehouse.toml >/dev/null 2>&1; git -C "$PC" commit -qm "own pool root" >/dev/null 2>&1
SLOT_OWN=$( cd "$PC" && HOME="$FAKE_HOME" env -u TREEHOUSE_ROOT treehouse get --lease --lease-holder fm-own 2>/dev/null )
case $SLOT_OWN in
  "$OWN"/*) say "slot came from the project's own configured root: $(short "$SLOT_OWN")" ;;
  *)        say "slot came from $(short "$SLOT_OWN") instead of the project's configured root" ;;
esac
( cd "$PC" && HOME="$FAKE_HOME" env -u TREEHOUSE_ROOT treehouse return --force "$SLOT_OWN" >/dev/null 2>&1 )

hdr "S5  a pool tool that ignores the root is refused, not silently obeyed"
run_spawn mate-old th-mate-old secondmate no
say "spawn exit: $SPAWN_RC (0 would mean the worker silently joined another home's pool)"
say "what the operator sees:"
printf '    %s\n' "$(printf '%s' "$SPAWN_OUT" | grep -i treehouse | head -2 | sed "s|$TMP_ROOT|<tmp>|g")"
if [ -f "$SPAWN_HOME/state/th-mate-old.meta" ] && grep -q '^treehouse_root=' "$SPAWN_HOME/state/th-mate-old.meta"; then
  say "task record: treehouse_root= recorded anyway  <-- FAIL"
else
  say "task record: none written, so no teardown can later return against a pool it never used"
fi

hdr "S5b the same old tool does not block a home that sends no root"
run_spawn primary-old th-primary-old primary no
say "spawn exit: $SPAWN_RC (0 expected: this home forces nothing on the pane)"

# =============================================================== S6 ===========
hdr "S6  session start tells a root-resolving home to upgrade the pool tool"
bootstrap_case() {  # <name> <kind> <root-support>
  local case_dir home fakebin
  case_dir=$TMP_ROOT/boot-$1; home=$case_dir/home
  mkdir -p "$home/config"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'herdr\n' > "$home/config/backend"
  fakebin=$(fm_fakebin "$case_dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi herdr jq
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = get ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  [ "$3" != yes ] || printf '%s\n' 'Global Flags:  --root string  Worktree root directory'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  [ "$2" != secondmate ] || printf 'mate-boot\n' > "$home/.fm-secondmate-home"
  PATH="$fakebin:$PATH" HOME="$FAKE_HOME" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 | grep -E 'MISSING: treehouse' || true
}
say "second mate home, pool tool WITHOUT --root:"
printf '    %s\n' "$(bootstrap_case mate-no secondmate no || true)"
say "second mate home, pool tool WITH --root:"
printf '    [%s]\n' "$(bootstrap_case mate-yes secondmate yes || true)"
say "home with no root of its own, same old pool tool WITHOUT --root:"
printf '    [%s]\n' "$(bootstrap_case primary-no primary no || true)"

# =============================================================== S7 ===========
hdr "S7  an identity marker that cannot name this home's own directory refuses"
for bad_id in . ..; do
  BAD=$(make_home "mate-bad-$(printf '%s' "$bad_id" | tr -c 'a-z' d)" secondmate)
  printf '%s\n' "$bad_id" > "$BAD/.fm-secondmate-home"
  out=$(HOME="$FAKE_HOME" FM_HOME="$BAD" "$RESOLVE" 2>&1) && rc=0 || rc=$?
  say "marker holding '$bad_id' -> resolver exit $rc (non-zero required: an empty answer would put this home back on the shared pool)"
  printf '    %s\n' "$(printf '%s' "$out" | sed "s|$TMP_ROOT|<tmp>|g")"
done
run_spawn_bad() {
  local rec home project pool fakebin out rc
  rec=$(make_spawn_case mate-bad-id th-bad secondmate yes)
  IFS='|' read -r home project pool fakebin <<EOF
$rec
EOF
  printf '.\n' > "$home/.fm-secondmate-home"
  out=$(FM_FAKE_PANE_LOG="$home/pane.log" fm_test_run_spawn "$home" "$pool" "$fakebin" th-bad "$project" --scout 2>&1) && rc=0 || rc=$?
  say "a spawn from that home exits $rc rather than leasing from somewhere else:"
  printf '    %s\n' "$(printf '%s' "$out" | grep -i 'pool root' | head -1 | sed "s|$TMP_ROOT|<tmp>|g")"
  if [ -f "$home/pane.log" ] && grep -qF 'treehouse get' "$home/pane.log"; then
    say "    the pane was still asked to acquire a worktree  <-- FAIL"
  else
    say "    the pane was never asked to acquire a worktree"
  fi
}
run_spawn_bad


# =============================================================== S4 ===========
hdr "S4  teardown returns the slot to the pool root the task record names (real treehouse)"
TEARDOWN_BIN="$ROOT/bin/fm-teardown.sh"
make_td_case() {  # <name> -> case dir with a project clone and a per-home pool root
  local case_dir=$TMP_ROOT/td-$1
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$case_dir/fakebin" "$case_dir/pool-root"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}
run_td() {  # <case-dir> [extra meta lines...]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" HOME="$FAKE_HOME" \
  PATH="$case_dir/fakebin:$PATH" env -u TREEHOUSE_ROOT \
    "$TEARDOWN_BIN" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr"
}
TD=$(make_td_case recorded)
TD_ROOT=$TD/pool-root
SLOT=$( cd "$TD/project" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$TD_ROOT" treehouse get --lease --lease-holder fm-task-x1 2>/dev/null )
say "the task's worktree, leased from this home's own root: $(short "$SLOT")"
say "lease state before teardown:"
printf '    %s\n' "$( cd "$TD/project" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$TD_ROOT" treehouse status 2>&1 | grep -i "$(basename "$(dirname "$SLOT")")" | head -2 | sed "s|$TMP_ROOT|<tmp>|g" )"
fm_write_meta "$TD/state/task-x1.meta" "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$SLOT" "project=$TD/project" "kind=ship" "mode=local-only" "spawn_gen=live-td" \
  "treehouse_root=$TD_ROOT"
if run_td "$TD"; then
  say "teardown exit: 0"
else
  say "teardown exit: $? -- stderr: $(tail -2 "$TD/stderr")"
fi
say "lease state after teardown:"
printf '    %s\n' "$( cd "$TD/project" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$TD_ROOT" treehouse status 2>&1 | grep -i "$(basename "$(dirname "$SLOT")")" | head -2 | sed "s|$TMP_ROOT|<tmp>|g" )"

say ""
say "-- work in flight: a task spawned BEFORE this change, whose record names no root --"
TD2=$(make_td_case norecord)
TD2_ROOT=$TD2/pool-root
SLOT2=$( cd "$TD2/project" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$TD2_ROOT" treehouse get --lease --lease-holder fm-task-x1 2>/dev/null )
say "its worktree: $(short "$SLOT2")"
fm_write_meta "$TD2/state/task-x1.meta" "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$SLOT2" "project=$TD2/project" "kind=ship" "mode=local-only" "spawn_gen=live-td2"
if run_td "$TD2"; then
  say "teardown exit: 0"
else
  say "teardown exit: non-zero -- $(grep -i treehouse "$TD2/stderr" | head -1 | sed "s|$TMP_ROOT|<tmp>|g")"
fi
say "lease state after teardown:"
printf '    %s\n' "$( cd "$TD2/project" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$TD2_ROOT" treehouse status 2>&1 | grep -i "$(basename "$(dirname "$SLOT2")")" | head -2 | sed "s|$TMP_ROOT|<tmp>|g" )"
say "so a task already in flight when this change lands still tears down and still frees its slot"

echo
echo "driver finished"

# =============================================================== S10 ==========
hdr "S10 reseeding under a retired id meets that id's leftover pool, and says so"
S10=$TMP_ROOT/s10; mkdir -p "$S10"
git init -q --bare "$S10/remote.git"; git -C "$S10/remote.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$S10/seed"; printf 'x\n' > "$S10/seed/README.md"
git -C "$S10/seed" add README.md; git -C "$S10/seed" commit -qm base
git -C "$S10/seed" remote add origin "$S10/remote.git"; git -C "$S10/seed" push -q origin main
RETIRED_CLONE=$S10/retired-home/adx-worker
mkdir -p "$S10/retired-home"; git clone -q "$S10/remote.git" "$RETIRED_CLONE"
LEFTOVER_ROOT=$S10/leftover-root
ORPHAN=$( cd "$RETIRED_CLONE" && HOME="$FAKE_HOME" TREEHOUSE_ROOT="$LEFTOVER_ROOT" treehouse get --lease --lease-holder fm-retired 2>/dev/null )
say "the retired id's leftover slot: $(short "$ORPHAN")"
rm -rf "$S10/retired-home"
say "the clone it is linked to is gone with the retired home"
rec=$(make_spawn_case reseeded th-reseed secondmate yes)
IFS='|' read -r home project pool fakebin <<EOF
$rec
EOF
out=$(FM_FAKE_PANE_LOG="$home/pane.log" fm_test_run_spawn "$home" "$ORPHAN" "$fakebin" th-reseed "$project" --scout 2>&1) && rc=0 || rc=$?
say "the reseeded home's spawn is handed that slot; spawn exit: $rc"
printf '    %s\n' "$(printf '%s' "$out" | grep -i 'isolated worktree' | head -1 | sed "s|$TMP_ROOT|<tmp>|g")"
