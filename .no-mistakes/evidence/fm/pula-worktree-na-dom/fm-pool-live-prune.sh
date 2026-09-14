#!/usr/bin/env bash
# Live: the cost the docs name for a RETIRED secondmate home, and the exact
# reclamation command docs/configuration.md gives the operator.
set -u
FM=$1; LAB=$(cd -P -- "$2" && pwd -P); SOCK=fm-pool-prune
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
git clone -q "$LAB/remote.git" "$LAB/retired/adx-worker"

H="$LAB/retired/mate-old"
mkdir -p "$H/state" "$H/config" "$H/data/w1" "$H/projects"
printf 'codex\n' > "$H/config/crew-harness"
touch "$H/state/.last-watcher-beat"
printf '# Task\n## Captain'"'"'s intent\nlab\n\n## Firstmate spec\nlab\n' > "$H/data/w1/brief.md"
printf 'mate-old\n' > "$H/.fm-secondmate-home"

"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
"$REAL_TMUX" -L $SOCK new-session -d -s firstmate -c "$LAB"

FM_ROOT_OVERRIDE='' FM_HOME="$H" CLAUDE_CONFIG_DIR='' FM_STATE_OVERRIDE="$H/state" \
  FM_DATA_OVERRIDE="$H/data" FM_PROJECTS_OVERRIDE="$H/projects" FM_CONFIG_OVERRIDE="$H/config" \
  FM_SPAWN_NO_GUARD=1 "$FM/bin/fm-spawn.sh" w1 "$LAB/retired/adx-worker" --scout 2>&1 | tail -1

ROOT_DIR="$HOME/.treehouse-homes/mate-old"
say "the retired home's pool before retirement"
( cd "$LAB/retired/adx-worker" && TREEHOUSE_ROOT="$ROOT_DIR" treehouse status ) 2>&1 | tail -4

say "the home is retired: its window, its home directory and its clone all go"
"$REAL_TMUX" -L $SOCK kill-window -t firstmate:fm-w1 2>/dev/null || true
sleep 2
rm -rf "$LAB/retired"
printf 'pool tree survives retirement: %s\n' "$([ -d "$ROOT_DIR" ] && echo yes || echo no)"
du -sh "$ROOT_DIR" 2>/dev/null

say "the documented reclamation command, as a dry run"
treehouse prune --root "$ROOT_DIR" --all --prune-orphans 2>&1 | tail -12
printf 'still on disk after the dry run: %s\n' "$([ -d "$ROOT_DIR/adx-worker"* ] 2>/dev/null && echo yes || ls "$ROOT_DIR" 2>/dev/null | tr '\n' ' ')"

say "the same command with --yes"
treehouse prune --root "$ROOT_DIR" --all --prune-orphans --yes 2>&1 | tail -12
printf 'pool contents after: [%s]\n' "$(ls "$ROOT_DIR"/*/ 2>/dev/null | tr '\n' ' ')"

"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
