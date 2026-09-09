#!/usr/bin/env bash
# Stand firstmate up on a machine with one command, from any starting state.
#
# One command covers both starting states because the run detects which one it
# is in rather than asking the operator to pick a mode: with no checkout yet it
# clones one, and standing in an existing checkout it uses that one. Re-running
# it on a machine that is already set up changes nothing and exits 0, so it is
# safe to run again after a partial or interrupted first attempt.
#
# From a checkout:
#   bin/fm-install.sh
#
# On a machine with no checkout, piped from a repository this account can read:
#   gh api repos/adxable/firstmate/contents/bin/fm-install.sh \
#     -H 'Accept: application/vnd.github.raw' | bash -s --
#
# The `-s --` is what makes that form carry flags: bash reads anything before
# the `--` as an option of its own, so a flag for this script goes after it.
#
# What that command clones is DEFAULT_REPO below, not the repository the script
# itself was fetched from: a piped run has no way to learn where it came from.
# Installing from a fork means passing --repo with that fork's clone URL:
#   gh api repos/me/firstmate/contents/bin/fm-install.sh \
#     -H 'Accept: application/vnd.github.raw' \
#     | bash -s -- --repo https://github.com/me/firstmate.git
#
# Usage:
#   fm-install.sh [--dir <path>] [--repo <url>] [--yes]
#   fm-install.sh --help
#   ... | bash -s -- [--dir <path>] [--repo <url>] [--yes]
#
#   --dir <path>   where the checkout lives, or is cloned to. Default: the
#                  checkout this run is already standing in - the one holding
#                  this script, or the working directory - else ./firstmate
#   --repo <url>   what to clone when there is no checkout yet. Default: the
#                  origin of the checkout this run is standing in, else
#                  DEFAULT_REPO below
#   --yes          install missing tools without asking. For unattended runs
#                  only: an ordinary run always asks first
#
# What it owns, and what it deliberately does not:
#
# Tools are not this script's list. bin/fm-bootstrap.sh already owns WHICH tools
# a home needs, WHICH versions are too old, and HOW each one is installed, and
# firstmate reads its lines at every session start. This script runs bootstrap's
# read-only detection, hands the tools it reports as missing straight back to
# `fm-bootstrap.sh install`, and re-runs the detection afterwards to report what
# is still missing. A second tool list here would drift out of step with that
# one, and a tool that is installed but below its floor is reported as MISSING
# by bootstrap, so it is upgraded here by the same path as an absent one with no
# separate rule.
#
# Consent is required before anything is installed onto the machine, and the
# quiet path is the one that installs nothing: a run with no answer available -
# a closed stdin, a pipe with no terminal behind it - declines and reports the
# install as still to do. --yes is the only way to install without being asked.
# Cloning the checkout is the action the operator invoked this script to get, so
# it is announced rather than prompted for; installing tools system-wide is not,
# so it is prompted for.
#
# The captain style rules are checked, never written. bin/fm-captain-style.sh
# owns that wiring and deliberately does not write to the user-level memory file
# it does not own; this script runs its read-only --check and reports the exact
# line and file as a step for a human. This script itself writes to no file
# outside the checkout directory it clones; the tools it installs once consent
# was given are put on the machine by fm-bootstrap.sh, wherever each tool's own
# installer puts it, and the closing summary says so.
#
# Steps no script can take - choosing an agent harness and signing in to it,
# and giving that account access to the repositories the crew will work on -
# are listed at the end of every run rather than left unsaid.
#
# Exit status: 0 when nothing is left to do, 1 when the run finished with steps
# still outstanding (each one named, with its command), and 2 when it could not
# proceed at all.
set -u

DEFAULT_REPO=https://github.com/adxable/firstmate.git
DEFAULT_DIR=firstmate

usage() {
  cat >&2 <<'EOF'
usage: fm-install.sh [--dir <path>] [--repo <url>] [--yes]
       fm-install.sh --help
       ... | bash -s -- [--dir <path>] [--repo <url>] [--yes]
EOF
}

# This script's header is its documentation, so --help prints the header on
# stdout the way bin/fm-captain-style.sh does.
help_text() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF_FILE"
}

# Where this script is on disk, when it is on disk at all. A run piped into bash
# has no file to read, which is also the run that has no checkout yet and the
# one whose stdin is the script rather than the operator, so both later
# decisions - which checkout to use, and where an answer can be read from - come
# from this one fact.
SELF_FILE=
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
fi

DIR_ARG=
REPO_ARG=
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      shift
      [ $# -gt 0 ] || { usage; exit 2; }
      DIR_ARG=$1
      ;;
    --dir=*) DIR_ARG=${1#--dir=} ;;
    --repo)
      shift
      [ $# -gt 0 ] || { usage; exit 2; }
      REPO_ARG=$1
      ;;
    --repo=*) REPO_ARG=${1#--repo=} ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help)
      # The header is the documentation, and a run piped into bash has no file
      # to read it from, so that run gets the usage lines instead of an error.
      if [ -n "$SELF_FILE" ]; then
        help_text
      else
        usage
      fi
      exit 0
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Every accumulator is a newline-separated list rather than an array, so the
# report can print it and count it the same way whatever produced it.
DONE_ITEMS=
TODO_ITEMS=
NOTES=

add_done() { DONE_ITEMS="${DONE_ITEMS}$1"$'\n'; }
add_todo() { TODO_ITEMS="${TODO_ITEMS}$1"$'\n'; }
add_note() { NOTES="${NOTES}$1"$'\n'; }
# A blank line before a new group of notes, so two unrelated ones do not read as
# one paragraph. Nothing is added before the first group.
begin_notes() { [ -z "$NOTES" ] || NOTES="${NOTES}"$'\n'; }

# A directory is a firstmate checkout when it carries the operating contract and
# the two scripts this run drives. A directory holding some of that is not one,
# and is left alone rather than cloned over.
is_checkout() {
  [ -d "$1" ] \
    && [ -f "$1/AGENTS.md" ] \
    && [ -f "$1/bin/fm-bootstrap.sh" ] \
    && [ -f "$1/bin/fm-captain-style.sh" ]
}

dir_is_empty() {
  [ -d "$1" ] || return 1
  ! find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

# The nearest checkout at or above a directory, so a run standing anywhere
# inside one finds it. Walking up rather than asking git keeps a checkout that
# carries no .git of its own - a copy, an export - answering the same way.
enclosing_checkout() {
  local dir
  dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  while :; do
    if is_checkout "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" != / ] || return 1
    dir=$(dirname "$dir")
  done
}

# The checkout this run is already standing in, if there is one: the one holding
# this script when it was run from a file, and otherwise the one enclosing the
# working directory, which is the only checkout a run piped into bash can see.
# Both are the same starting state - a machine that already has firstmate on it
# - so both resolve here rather than leaving the piped form to clone a second
# checkout inside the first one.
CONTAINING=
if [ -n "$SELF_FILE" ]; then
  candidate=$(cd "$(dirname "$SELF_FILE")/.." 2>/dev/null && pwd -P) || candidate=
  if [ -n "$candidate" ] && is_checkout "$candidate"; then
    CONTAINING=$candidate
  fi
fi
if [ -z "$CONTAINING" ]; then
  CONTAINING=$(enclosing_checkout "$PWD") || CONTAINING=
fi

if [ -n "$DIR_ARG" ]; then
  TARGET=$DIR_ARG
elif [ -n "$CONTAINING" ]; then
  TARGET=$CONTAINING
else
  TARGET="$PWD/$DEFAULT_DIR"
fi

REPO=$REPO_ARG
if [ -z "$REPO" ] && [ -n "$CONTAINING" ]; then
  REPO=$(git -C "$CONTAINING" remote get-url origin 2>/dev/null) || REPO=
fi
[ -n "$REPO" ] || REPO=$DEFAULT_REPO

say 'firstmate installer'
say

# --- the checkout ------------------------------------------------------------

if is_checkout "$TARGET"; then
  TARGET=$(cd "$TARGET" && pwd -P)
  add_done "checkout: $TARGET (already present)"
elif [ -e "$TARGET" ] && ! dir_is_empty "$TARGET"; then
  err "error: $TARGET already exists and is not a firstmate checkout"
  err "Point --dir somewhere else, or clear that path yourself; this run will not touch it."
  exit 2
else
  if ! command -v git >/dev/null 2>&1; then
    err 'error: git is required to clone the checkout and is not installed'
    err 'Install git, then run this again.'
    exit 2
  fi
  say "Cloning $REPO into $TARGET"
  if ! git clone "$REPO" "$TARGET"; then
    err "error: could not clone $REPO into $TARGET"
    err 'If that repository is private, authenticate first with: gh auth login'
    err 'then run this again.'
    exit 2
  fi
  if ! is_checkout "$TARGET"; then
    err "error: $REPO cloned into $TARGET but is not a firstmate checkout"
    exit 2
  fi
  TARGET=$(cd "$TARGET" && pwd -P)
  add_done "checkout: $TARGET (cloned from $REPO)"
fi

BOOTSTRAP="$TARGET/bin/fm-bootstrap.sh"
STYLE="$TARGET/bin/fm-captain-style.sh"
STYLE_MEMORY="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/CLAUDE.md"

# --- the toolchain, as bootstrap reports it ----------------------------------

# Read-only detection: FM_BOOTSTRAP_DETECT_ONLY keeps bootstrap's mutating
# session-start sweeps out of an install run, so this reports the machine
# without changing anything on it.
# FM_BOOTSTRAP_NETWORK is pinned rather than inherited because this run reads
# bootstrap's answers as complete: it reports a tool as present, and GitHub as
# authenticated, from the ABSENCE of a line about it. Bootstrap emits its tool
# lines only in the local phase and NEEDS_GH_AUTH only in the network one, so a
# shell that exported `skip` or `only` would turn a check that never ran into a
# check that passed. `all` is the value under which every line this script reads
# is actually produced.
# Bootstrap's own stderr is left on stderr rather than captured, so a notice it
# prints there - an auto-detected runtime backend, say - reaches the operator
# instead of being swallowed by a run that only wanted its diagnostic lines.
run_detect() {
  local out rc
  out=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=all bash "$BOOTSTRAP")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || err "$out"
    err "error: the toolchain check failed (exit $rc); see its output above"
    return 1
  fi
  printf '%s\n' "$out"
}

missing_tools() {
  awk '$1 == "MISSING:" { print $2 }' | awk '!seen[$0]++'
}

missing_lines() {
  grep '^MISSING: ' || true
}

manual_lines() {
  grep '^MISSING_MANUAL: ' || true
}

# Bootstrap reports more than the steps that stand a machine up: facts about a
# fleet already running on one, defects in local configuration the operator owns
# and this script does not, and whatever it learns to report next. None of those
# mean the machine is not set up, so none of them may hold the run back from
# reporting a finished one. The lines below are the ones this script recognizes
# as setup steps, and only they decide the exit status. An allowlist rather than
# a list of prefixes to skip, so the next line bootstrap learns to report lands
# on the harmless side.
SETUP_LINE_RE='^(MISSING|MISSING_MANUAL|BACKEND_INVALID|TANGLE): |^NEEDS_GH_AUTH$'

backend_lines() {
  grep '^BACKEND_INVALID: ' || true
}

tangle_lines() {
  grep '^TANGLE: ' || true
}

# Everything else bootstrap reported, minus its completed no-action facts.
# Passed through verbatim rather than re-worded, because bootstrap's line is the
# authority on what it found, and reported as a note rather than a step, because
# a line this script does not recognize is not one it can claim is outstanding.
other_lines() {
  grep -Ev "$SETUP_LINE_RE" \
    | grep -v '^BOOTSTRAP_INFO: ' \
    | grep -v '^[[:space:]]*$' || true
}

if ! DETECT=$(run_detect); then
  exit 2
fi

MISSING=$(printf '%s\n' "$DETECT" | missing_tools)

# --- consent, then install ---------------------------------------------------

# The answer comes from the terminal when this script itself arrived on stdin,
# and from stdin otherwise. A run with neither gets no answer, which is a
# decline: nothing is installed and the report says so.
ask_yes_no() {
  local prompt=$1 answer=
  printf '%s [y/N] ' "$prompt"
  if [ -z "$SELF_FILE" ]; then
    if [ -r /dev/tty ]; then
      read -r answer </dev/tty || answer=
    else
      answer=
    fi
  else
    read -r answer || answer=
  fi
  printf '\n'
  case "$answer" in
    y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

INSTALL_RAN=0
CONSENT_DECLINED=0
if [ -n "$MISSING" ]; then
  say 'These tools are missing or below the version firstmate requires:'
  printf '%s\n' "$DETECT" | missing_lines | sed 's/^MISSING: /  /'
  say
  if [ "$ASSUME_YES" -eq 1 ]; then
    INSTALL_RAN=1
  elif ask_yes_no 'Install them now?'; then
    INSTALL_RAN=1
  else
    CONSENT_DECLINED=1
  fi
  if [ "$INSTALL_RAN" -eq 1 ]; then
    # Word splitting is the point: one detected tool per argument.
    # shellcheck disable=SC2086
    bash "$BOOTSTRAP" install $MISSING || true
    say
    if ! DETECT=$(run_detect); then
      exit 2
    fi
    MISSING=$(printf '%s\n' "$DETECT" | missing_tools)
  fi
fi

# A tool bootstrap can only point at instructions for is still a tool this
# machine does not have, and it is listed as an outstanding step below, so it
# holds the done line back the same way a tool with an install command does.
# Nothing installs it here: the whole reason it is reported separately is that
# there is no command to run for it.
MANUAL=$(printf '%s\n' "$DETECT" | manual_lines)

if [ -z "$MISSING" ] && [ -z "$MANUAL" ]; then
  if [ "$INSTALL_RAN" -eq 1 ]; then
    add_done 'tools: every tool firstmate requires is now present'
  else
    add_done 'tools: every tool firstmate requires is already present'
  fi
fi

if [ -n "$MISSING" ]; then
  if [ "$CONSENT_DECLINED" -eq 1 ]; then
    begin_notes
    add_note 'Nothing was installed: the install was declined, or no answer was available.'
    add_note 'Run this again and answer y, or run it with --yes, to install these.'
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    add_todo "${line#MISSING: }"
  done < <(printf '%s\n' "$DETECT" | missing_lines)
fi

while IFS= read -r line; do
  [ -n "$line" ] || continue
  add_todo "${line#MISSING_MANUAL: }"
done < <(printf '%s\n' "$MANUAL")

if printf '%s\n' "$DETECT" | grep -q '^NEEDS_GH_AUTH$'; then
  add_todo 'GitHub is not authenticated (run: gh auth login)'
else
  add_done 'GitHub: authenticated'
fi

while IFS= read -r line; do
  [ -n "$line" ] || continue
  add_todo "$line"
done < <(printf '%s\n' "$DETECT" | backend_lines)

# A tangled checkout is a setup step this run can name a command for but must
# not take. Bootstrap's read-only wording deliberately leaves the repair to
# whichever session holds the fleet lock, and this run does not hold it - a
# firstmate session may be live on this machine right now, and claiming the lock
# to get a better-worded line would be a false claim on exactly the machine
# where it matters. So bootstrap's line is relayed as it stands, and the command
# is named beside it together with the one condition that makes it safe to run.
TANGLE_LINES=$(printf '%s\n' "$DETECT" | tangle_lines)
if [ -n "$TANGLE_LINES" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    add_todo "$line"
  done < <(printf '%s\n' "$TANGLE_LINES")
  # The default branch comes from the same owner bootstrap used to decide the
  # checkout is tangled at all, including its fallback, so the branch named here
  # is the branch named in the line above it.
  TANGLE_DEFAULT=$(. "$TARGET/bin/fm-tangle-lib.sh" && fm_default_branch "$TARGET") || TANGLE_DEFAULT=
  [ -n "$TANGLE_DEFAULT" ] || TANGLE_DEFAULT=main
  add_todo "when no firstmate session is running on this machine, put that checkout back on its default branch (run: git -C $TARGET checkout $TANGLE_DEFAULT)"
fi

OTHER_LINES=$(printf '%s\n' "$DETECT" | other_lines)
if [ -n "$OTHER_LINES" ]; then
  begin_notes
  add_note 'The toolchain check also reported this, which is not a step this installer'
  add_note 'recognizes as part of standing a machine up:'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    add_note "  $line"
  done < <(printf '%s\n' "$OTHER_LINES")
fi

# --- the captain style rules, checked and never written ----------------------

# A wired verdict can carry notes beside it - an import that reaches a different
# checkout than this one, or occurrences that are indented and so never load -
# and those are states a human still has to settle. Only the verdict line is a
# completed step; a note goes to the notes block, and an import pointing at
# another checkout is named as an outstanding step so the run does not report
# this machine as finished.
STYLE_OUT=$(bash "$STYLE" --check 2>&1)
STYLE_RC=$?
if [ "$STYLE_RC" -eq 0 ]; then
  STYLE_VERDICT=$(printf '%s\n' "$STYLE_OUT" | grep '^captain-style: ' | sed -n '1p')
  STYLE_NOTES=$(printf '%s\n' "$STYLE_OUT" | grep -v '^captain-style: ' | grep -v '^[[:space:]]*$' || true)
  add_done "captain style rules: ${STYLE_VERDICT#captain-style: wired  }"
  if [ -n "$STYLE_NOTES" ]; then
    if printf '%s\n' "$STYLE_NOTES" | grep -q 'different checkout'; then
      add_todo "the captain style import in $STYLE_MEMORY points at a different checkout than $TARGET"
    fi
    begin_notes
    add_note 'The captain style check reported this beside the wiring it found:'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      add_note "  $line"
    done < <(printf '%s\n' "$STYLE_NOTES")
  fi
else
  add_todo "the captain style rules are not wired into Claude's user-level memory yet"
  begin_notes
  add_note 'The captain style rules load through one line in a memory file this installer'
  add_note 'does not own and never writes to. The check below names the exact line and'
  add_note 'the exact file, so add it by hand:'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    add_note "  $line"
  done < <(printf '%s\n' "$STYLE_OUT")
fi

# --- the report --------------------------------------------------------------

print_list() {
  printf '%s' "$1" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  - %s\n' "$line"
  done
}

say 'Done:'
print_list "$DONE_ITEMS"
say

if [ -n "$TODO_ITEMS" ]; then
  say 'Still to do on this machine:'
  print_list "$TODO_ITEMS"
  say
else
  say 'Nothing on this machine is outstanding.'
  say
fi

if [ -n "$NOTES" ]; then
  printf '%s' "$NOTES"
  say
fi

say 'Steps this installer cannot take for you:'
say '  - choose an agent harness, sign in to it, and launch it from the checkout:'
say "      cd $TARGET"
say '      claude            # or: grok --trust, or: pi'
say '  - give that account access to the repositories the crew will work on.'
say
if [ "$INSTALL_RAN" -eq 1 ]; then
  say "Beyond the tools installed above, this run wrote nothing outside $TARGET."
else
  say "Nothing outside $TARGET was written."
fi

[ -z "$TODO_ITEMS" ] || exit 1
exit 0
