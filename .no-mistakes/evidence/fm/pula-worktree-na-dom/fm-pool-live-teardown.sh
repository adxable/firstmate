#!/usr/bin/env bash
# Live teardown: a secondmate home's live task is torn down and its slot goes
# back to the pool root its record names, leaving the shared pool alone.
set -u
FM=$1; LAB=$(cd -P -- "$2" && pwd -P); SOCK=fm-pool-td
REAL_TMUX=$(command -v tmux)
export HOME="$LAB/user-home"; mkdir -p "$HOME"
export FM_GATE_REFUSE_BYPASS=1
say() { printf '\n=== %s ===\n' "$*"; }

FAKE="$LAB/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L $SOCK "\$@"
SH
cat > "$FAKE/codex" <<'SH'
#!/usr/bin/env bash
echo "fake codex harness running in $PWD"
exec sleep 600
SH
for t in gh gh-axi pi claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"; done
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"

git init -q --bare "$LAB/remote.git"
git -C "$LAB/remote.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$LAB/seed"
printf 'hello\n' > "$LAB/seed/README.md"
git -C "$LAB/seed" add README.md
git -C "$LAB/seed" -c user.email=fmlab@example.invalid -c user.name=fmlab commit -qm baseline
git -C "$LAB/seed" remote add origin "$LAB/remote.git"
git -C "$LAB/seed" push -q origin main
rm -rf "$LAB/seed"
git clone -q "$LAB/remote.git" "$LAB/homeA/adx-worker"
git clone -q "$LAB/remote.git" "$LAB/homeB/adx-worker"

mk_home() {
  local h=$1 kind=$2; shift 2
  mkdir -p "$h/state" "$h/config" "$h/data" "$h/projects"
  printf 'codex\n' > "$h/config/crew-harness"
  touch "$h/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$h/data/$id"
    printf '# Task\n## Captain'"'"'s intent\nlive pool-root lab\n\n## Firstmate spec\nExercise the spawn path.\n' > "$h/data/$id/brief.md"
  done
  [ "$kind" != secondmate ] || printf '%s\n' "$(basename "$h")" > "$h/.fm-secondmate-home"
}
mk_home "$LAB/homeA/fm" primary wa
mk_home "$LAB/homeB/mate-live" secondmate wb

fmenv() {  # <home>
  local home=$1
  printf 'FM_ROOT_OVERRIDE=;FM_HOME=%s;FM_STATE_OVERRIDE=%s/state;FM_DATA_OVERRIDE=%s/data;FM_PROJECTS_OVERRIDE=%s/projects;FM_CONFIG_OVERRIDE=%s/config' \
    "$home" "$home" "$home" "$home" "$home"
}
run_spawn() {
  local home=$1 id=$2 proj=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 "$FM/bin/fm-spawn.sh" "$id" "$proj" --scout 2>&1
}

"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
"$REAL_TMUX" -L $SOCK new-session -d -s firstmate -c "$LAB"

run_spawn "$LAB/homeA/fm" wa "$LAB/homeA/adx-worker" | tail -1
run_spawn "$LAB/homeB/mate-live" wb "$LAB/homeB/adx-worker" | tail -1

say "both pools before teardown"
echo "shared pool (home A):"; ( cd "$LAB/homeA/adx-worker" && treehouse status ) 2>&1 | tail -4
echo "home B's own pool:"; ( cd "$LAB/homeB/adx-worker" && TREEHOUSE_ROOT="$HOME/.treehouse-homes/mate-live" treehouse status ) 2>&1 | tail -4
echo "wb record:"; grep -E '^(worktree|treehouse_root)=' "$LAB/homeB/mate-live/state/wb.meta"

say "teardown of the live task wb"
FM_ROOT_OVERRIDE='' FM_HOME="$LAB/homeB/mate-live" \
  FM_STATE_OVERRIDE="$LAB/homeB/mate-live/state" FM_DATA_OVERRIDE="$LAB/homeB/mate-live/data" \
  FM_CONFIG_OVERRIDE="$LAB/homeB/mate-live/config" FM_PROJECTS_OVERRIDE="$LAB/homeB/mate-live/projects" \
  "$FM/bin/fm-teardown.sh" wb --force 2>&1 | tail -8

say "both pools after teardown"
echo "home B's own pool (the slot must be back, not destroyed):"
( cd "$LAB/homeB/adx-worker" && TREEHOUSE_ROOT="$HOME/.treehouse-homes/mate-live" treehouse status ) 2>&1 | tail -4
echo "shared pool (home A's live task must be untouched):"
( cd "$LAB/homeA/adx-worker" && treehouse status ) 2>&1 | tail -4
echo "record gone: $([ -f "$LAB/homeB/mate-live/state/wb.meta" ] && echo no || echo yes)"

"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
