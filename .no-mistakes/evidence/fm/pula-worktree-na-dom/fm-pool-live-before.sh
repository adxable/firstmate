#!/usr/bin/env bash
# Live "before" half: the SAME two-home world driven by the BASE commit's
# fm-spawn (no per-home pool root). Home A leases and frees a slot; home B then
# spawns and is handed a worktree of home A's clone.
set -u
BASE=$1; LAB=$2; SOCK=fm-pool-before
REAL_TMUX=$(command -v tmux)
rm -rf "$LAB"; mkdir -p "$LAB"
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
  local h=$1 kind=$2 id=$3
  mkdir -p "$h/state" "$h/config" "$h/data" "$h/projects"
  printf 'codex\n' > "$h/config/crew-harness"
  touch "$h/state/.last-watcher-beat"
  mkdir -p "$h/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nlive pool-root lab\n\n## Firstmate spec\nExercise the spawn path.\n' > "$h/data/$id/brief.md"
  [ "$kind" != secondmate ] || printf '%s\n' "$(basename "$h")" > "$h/.fm-secondmate-home"
}
mk_home "$LAB/homeA/fm" primary wa
mk_home "$LAB/homeB/mate-live" secondmate wb

run_spawn() {
  local home=$1 id=$2 proj=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 "$BASE/bin/fm-spawn.sh" "$id" "$proj" --scout 2>&1
}

"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
"$REAL_TMUX" -L $SOCK new-session -d -s firstmate -c "$LAB"

say "BASE commit, home A spawns and takes the only pool slot"
run_spawn "$LAB/homeA/fm" wa "$LAB/homeA/adx-worker" | tail -3
WTA=$(sed -n 's/^worktree=//p' "$LAB/homeA/fm/state/wa.meta" | head -1)

say "home A's work ends: its window closes and the slot goes back to the pool"
"$REAL_TMUX" -L $SOCK kill-window -t firstmate:fm-wa 2>/dev/null || true
sleep 2
( cd "$LAB/homeA/adx-worker" && treehouse status ) 2>&1 | tail -5

say "BASE commit, home B spawns into ITS OWN clone of the same repository"
run_spawn "$LAB/homeB/mate-live" wb "$LAB/homeB/adx-worker" | tail -3
WTB=$(sed -n 's/^worktree=//p' "$LAB/homeB/mate-live/state/wb.meta" | head -1)

say "the slot home B was handed"
printf 'home B worktree     : %s\n' "$WTB"
printf 'home B wt common dir: %s\n' "$(git -C "$WTB" rev-parse --path-format=absolute --git-common-dir)"
printf 'home B own clone    : %s\n' "$(git -C "$LAB/homeB/adx-worker" rev-parse --path-format=absolute --git-common-dir)"
printf 'home A own clone    : %s\n' "$(git -C "$LAB/homeA/adx-worker" rev-parse --path-format=absolute --git-common-dir)"
printf 'recorded treehouse_root: [%s]\n' "$(sed -n 's/^treehouse_root=//p' "$LAB/homeB/mate-live/state/wb.meta" | head -1)"

say "what a claude spawn makes of that slot (bin/fm-claude-trust.sh, the check that refused in the field)"
store="$LAB/trust"; mkdir -p "$store"
if CLAUDE_CONFIG_DIR="$store" HOME="$store" "$BASE/bin/fm-claude-trust.sh" "$WTB" "$LAB/homeB/adx-worker" 2>&1; then
  echo "trust: ACCEPTED"
else
  echo "trust: REFUSED (exit $?) - home B cannot start anything at all"
fi
"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
