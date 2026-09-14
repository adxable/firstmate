#!/usr/bin/env bash
# Drives the two operator-facing recipes the new docs hand out, against the real
# treehouse binary: reclaiming a retired home's orphaned pool, and the pinned
# installer the required CI lane uses.
set -u
ROOT_REPO=${1:?usage: driver.sh <repo-root>}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pool-housekeeping.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/user-home"; mkdir -p "$HOME"
hdr() { printf '\n========== %s ==========\n' "$*"; }
say() { printf '  %s\n' "$*"; }
scrub() { sed "s|$TMP|<tmp>|g"; }

git init -q --bare "$TMP/remote.git"; git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$TMP/seed"; printf 'x\n' > "$TMP/seed/README.md"; git -C "$TMP/seed" add README.md
git -C "$TMP/seed" -c user.name=t -c user.email=t@e.invalid commit -qm base
git -C "$TMP/seed" remote add origin "$TMP/remote.git"; git -C "$TMP/seed" push -q origin main

# retire_and_prune <case> <return-lease?>: build a second mate home with its own
# pool root, retire the home, then run the reclaim recipe the docs hand out.
retire_and_prune() {  # <case> <yes|no>
  local case=$1 returned=$2 mate_home clone root slot
  mate_home="$TMP/$case/homes/mate-$case"; clone="$mate_home/projects/adx-worker"
  root="$HOME/.treehouse-homes/mate-$case"
  mkdir -p "$mate_home/projects" "$root"
  git clone -q "$TMP/remote.git" "$clone"
  slot=$( cd "$clone" && TREEHOUSE_ROOT="$root" treehouse get --lease --lease-holder "fm-$case" 2>/dev/null )
  say "pool slot under the home's own root: $(printf '%s' "$slot" | scrub)"
  if [ "$returned" = yes ]; then
    say "its task is torn down first, so teardown returns the lease"
    ( cd "$clone" && TREEHOUSE_ROOT="$root" treehouse return --force "$slot" >/dev/null 2>&1 )
  else
    say "its task is NOT torn down, so the slot stays leased"
  fi
  say "the home is retired: its directory and the clone its worktrees link to are gone"
  rm -rf "$mate_home"
  say "docs recipe, dry run:"
  ( cd "$TMP" && treehouse prune --root "$root" --all --prune-orphans 2>&1 ) | scrub | sed 's/^/      /'
  say "docs recipe, with --yes:"
  ( cd "$TMP" && treehouse prune --root "$root" --all --prune-orphans --yes 2>&1 ) | scrub | sed 's/^/      /'
  say "worktree still on disk afterwards: $([ -d "$slot" ] && echo YES || echo no)"
}

hdr "S8  reclaiming a retired second mate's pool, the way the docs say"
say "-- the ordinary retirement: fm-teardown returned the task's lease first --"
retire_and_prune returned yes
say ""
say "-- the leftover: a slot still leased when the home went away --"
retire_and_prune leased no

hdr "S9  the pinned installer the required CI lane uses"
DEST="$TMP/pinned-bin"
if "$ROOT_REPO/bin/fm-install-treehouse.sh" "$DEST" 2>&1 | scrub | sed 's/^/    /'; then
  say "installed: $("$DEST/treehouse" --version 2>&1 | tr -d '[:space:]')"
  if "$DEST/treehouse" get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--root([^[:alnum:]_-]|$)'; then
    say "the pinned build advertises --root, so the capability probe says supported"
  else
    say "the pinned build does NOT advertise --root  <-- FAIL, every second mate spawn would be refused"
  fi
else
  say "installer failed"
fi
echo
echo "driver finished"
