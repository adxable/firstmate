#!/usr/bin/env bash
# Live "after" half + the guards, driven by the CHANGE under test against real
# tmux panes and the real treehouse binary.
set -u
FM=$1; LAB=$2; SOCK=fm-pool-after
REAL_TMUX=$(command -v tmux)
REAL_TH=$(command -v treehouse)
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

# A treehouse that ADVERTISES --root but IGNORES TREEHOUSE_ROOT: the divergent
# worker shell (a root-capable tool answers the probe, an older one leases).
DEAF="$LAB/deafbin"; mkdir -p "$DEAF"
cat > "$DEAF/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = get ] && [ "\${2:-}" = --help ]; then exec "$REAL_TH" "\$@"; fi
exec env -u TREEHOUSE_ROOT "$REAL_TH" "\$@"
SH
# A treehouse whose own help lists no --root at all: the build that predates it.
OLD="$LAB/oldbin"; mkdir -p "$OLD"
cat > "$OLD/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = get ] && [ "\${2:-}" = --help ]; then
  printf 'Acquire a worktree from the pool\n\nFlags:\n      --lease   Take a durable lease\n'; exit 0
fi
exec env -u TREEHOUSE_ROOT "$REAL_TH" "\$@"
SH
chmod +x "$DEAF/treehouse" "$OLD/treehouse"

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
mk_home "$LAB/homeA/fm" primary wa wdeaf
mk_home "$LAB/homeB/mate-live" secondmate wb wdeaf wgone wretry

run_spawn() {  # <home> <id> <project> [PATH-override]
  local home=$1 id=$2 proj=$3 pathv=${4:-$PATH}
  env -i HOME="$HOME" PATH="$pathv" TERM=xterm SHELL=/bin/bash \
    FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE='' FM_HOME="$home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 "$FM/bin/fm-spawn.sh" "$id" "$proj" --scout 2>&1
}
windows() { "$REAL_TMUX" -L $SOCK list-windows -a -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' '; echo; }

"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
"$REAL_TMUX" -L $SOCK new-session -d -s firstmate -c "$LAB"

say "S1a  home A takes the shared pool's slot, then its window closes and the slot is free"
run_spawn "$LAB/homeA/fm" wa "$LAB/homeA/adx-worker" | tail -2
"$REAL_TMUX" -L $SOCK kill-window -t firstmate:fm-wa 2>/dev/null || true
sleep 2
( cd "$LAB/homeA/adx-worker" && treehouse status ) 2>&1 | tail -3

say "S1b  home B spawns into its own clone of the SAME repository"
run_spawn "$LAB/homeB/mate-live" wb "$LAB/homeB/adx-worker" | tail -2
WTB=$(sed -n 's/^worktree=//p' "$LAB/homeB/mate-live/state/wb.meta" | head -1)
printf 'home B worktree        : %s\n' "$WTB"
printf 'home B wt common dir   : %s\n' "$(git -C "$WTB" rev-parse --path-format=absolute --git-common-dir)"
printf 'home A clone           : %s\n' "$(git -C "$LAB/homeA/adx-worker" rev-parse --path-format=absolute --git-common-dir)"
printf 'home B clone           : %s\n' "$(git -C "$LAB/homeB/adx-worker" rev-parse --path-format=absolute --git-common-dir)"
printf 'recorded treehouse_root: [%s]\n' "$(sed -n 's/^treehouse_root=//p' "$LAB/homeB/mate-live/state/wb.meta" | head -1)"
store="$LAB/trust"; mkdir -p "$store"
CLAUDE_CONFIG_DIR="$store" HOME="$store" "$FM/bin/fm-claude-trust.sh" "$WTB" "$LAB/homeB/adx-worker" 2>&1 \
  && echo "trust: ACCEPTED - home B can start work" || echo "trust: REFUSED"

say "S2   the two pools on disk"
( cd "$LAB/homeA/adx-worker" && echo "home A pool:" && treehouse status ) 2>&1 | tail -3
( cd "$LAB/homeB/adx-worker" && echo "home B pool:" && TREEHOUSE_ROOT="$HOME/.treehouse-homes/mate-live" treehouse status ) 2>&1 | tail -3

say "S3   a slot that came back to the pool the record names"
"$REAL_TMUX" -L $SOCK kill-window -t firstmate:fm-wb 2>/dev/null || true
sleep 1
env -i HOME="$HOME" PATH="$PATH" TERM=xterm FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE='' \
  FM_HOME="$LAB/homeB/mate-live" FM_STATE_OVERRIDE="$LAB/homeB/mate-live/state" \
  FM_DATA_OVERRIDE="$LAB/homeB/mate-live/data" FM_CONFIG_OVERRIDE="$LAB/homeB/mate-live/config" \
  FM_PROJECTS_OVERRIDE="$LAB/homeB/mate-live/projects" \
  "$FM/bin/fm-teardown.sh" wb --force 2>&1 | tail -6
echo "-- home B's own pool after teardown:"
( cd "$LAB/homeB/adx-worker" && TREEHOUSE_ROOT="$HOME/.treehouse-homes/mate-live" treehouse status ) 2>&1 | tail -3
echo "-- the shared pool, which this teardown must not have touched:"
( cd "$LAB/homeA/adx-worker" && treehouse status ) 2>&1 | tail -3

say "S4   a worker shell whose treehouse ignores the root (windows before: $(windows))"
run_spawn "$LAB/homeB/mate-live" wretry "$LAB/homeB/adx-worker" "$DEAF:$PATH" | tail -3
echo "windows after refusal: $(windows)"
echo "the retry the message prescribes, with a root-honouring treehouse:"
run_spawn "$LAB/homeB/mate-live" wretry "$LAB/homeB/adx-worker" | tail -2

say "S5   no treehouse on the spawn's PATH at all (windows before: $(windows))"
NOTH="$LAB/nothbin"; mkdir -p "$NOTH"
cp "$FAKE/tmux" "$FAKE/codex" "$FAKE/gh" "$FAKE/gh-axi" "$FAKE/pi" "$FAKE/claude" "$NOTH/"
run_spawn "$LAB/homeB/mate-live" wgone "$LAB/homeB/adx-worker" "$NOTH:/usr/bin:/bin" | tail -2
echo "windows after refusal: $(windows)"

say "S6   a treehouse that lists no --root at all, asked by a home that HAS a root"
run_spawn "$LAB/homeB/mate-live" wdeaf "$LAB/homeB/adx-worker" "$OLD:/usr/bin:/bin" | tail -2

say "S7   control: a home with NO root of its own, same degraded treehouse"
run_spawn "$LAB/homeA/fm" wdeaf "$LAB/homeA/adx-worker" "$OLD:$PATH" | tail -2
printf 'recorded treehouse_root for home A: [%s]\n' \
  "$(sed -n 's/^treehouse_root=//p' "$LAB/homeA/fm/state/wdeaf.meta" 2>/dev/null | head -1)"

"$REAL_TMUX" -L $SOCK kill-server 2>/dev/null || true
