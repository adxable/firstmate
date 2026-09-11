#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes both invoke this script with no arguments, so this owner selects
# the context-appropriate rule set without duplicating lint configuration.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks and source
# following. CI, main, and merge-base-less runs keep --norc --external-sources
# with full dataflow over the whole canonical set. An ordinary local branch
# (changed-file mode, including the no-mistakes lint step) drops
# --external-sources, keeps dataflow, and excludes SC1091, SC2034, SC2153,
# and SC2329, the codes that need library context. Those codes still run in
# CI over the whole set. Explicit paths keep --external-sources with the
# selected dataflow mode.
# Tests stop source analysis at imported production modules because CI analyzes
# every production shell separately as a canonical, source-aware root.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# With no explicit paths, the file set and source-following posture depend
# on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh, with
#     --external-sources and full dataflow. This is what CI always runs, so
#     CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). That local pass drops --external-sources and excludes SC1091,
#     SC2034, SC2153, and SC2329. A branch with zero matching changed files
#     skips ShellCheck and prints a "no changed lint targets" note, then
#     still validates workflows.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. FM_LINT_JOBS=1
# runs the same shards serially with byte-identical diagnostics and exit selection.
#
# Every canonical run also applies one structural rule ShellCheck does not model:
# the Bash 3.2 command-substitution heredoc parse defect (issues #166, #945, #958,
# #1069). Bash 3.2, the stock macOS /bin/bash, scans a command substitution for its
# closing paren textually and keeps lexing quote, escape, and paren state straight
# through any heredoc body nested inside it, so a body that leaves that state
# unbalanced swallows the rest of the script. The guard reports the bodies that
# break, not the construct; two shapes it does not model are noted at the guard.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --parse-guard [path]... run only the Bash 3.2 parse guard
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
# Cross-file codes that need --external-sources. Local changed-file mode
# cannot judge them, so they stay CI-only.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output invocation_rc rc=0
  local -a roots shellcheck_args
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    shellcheck_args=(--norc)
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      shellcheck_args+=(--external-sources)
    fi
    if [ -n "${FM_LINT_INTERNAL_EXCLUDE:-}" ]; then
      shellcheck_args+=(--exclude="$FM_LINT_INTERNAL_EXCLUDE")
    fi
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      shellcheck_args+=(--extended-analysis=false)
    fi
    : > "$output.out"
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "${roots[@]}" >> "$output.out" 2>&1 &
      FM_LINT_WORKER_SHELLCHECK_PID=$!
      wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
      FM_LINT_WORKER_SHELLCHECK_PID=
    else
      for path in "${roots[@]}"; do
        invocation_rc=0
        "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "$path" >> "$output.out" 2>&1 &
        FM_LINT_WORKER_SHELLCHECK_PID=$!
        wait "$FM_LINT_WORKER_SHELLCHECK_PID" || invocation_rc=$?
        FM_LINT_WORKER_SHELLCHECK_PID=
        if [ "$rc" -eq 0 ] && [ "$invocation_rc" -ne 0 ]; then
          rc=$invocation_rc
        fi
      done
    fi
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
LIST_FILES=0
PARSE_GUARD_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --parse-guard)
      PARSE_GUARD_ONLY=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
FOLLOW_SOURCES=1
EXCLUDE_CODES=
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
if [ "$CHANGED_MODE" -eq 1 ] && [ "$FAST" -eq 0 ]; then
  FOLLOW_SOURCES=0
  EXCLUDE_CODES=$LOCAL_NOX_EXCLUDE
  ANALYSIS_MODE=local
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

# Bash 3.2 command-substitution heredoc parse guard.
#
# Bash 3.2 (stock macOS /bin/bash) resolves `$( ... )` by scanning forward for the
# matching `)` and lexing everything in between, including any heredoc body nested
# inside it, as ordinary shell text. Quote, escape, comment, and paren state
# therefore leak out of that body: one unpaired apostrophe leaves a single quote
# open, and the rest of the file is consumed as quoted text. `bash -n` then fails
# far from the real cause, and only on Bash 3.2, so a modern shell and CI can both
# look green while a stock macOS run of the same script is dead.
#
# The Perl below models that lexer and reports only the nested bodies that would
# actually leave the state unbalanced, so a body whose quotes and parens already
# pair is left alone. The macos-stock-bash CI job stays the authoritative
# cross-version proof; this guard turns the same defect into a local, explained
# failure before the push.
#
# Known boundary: the lexer below deliberately does not model backtick command
# substitution. An unpaired backtick in a nested heredoc body carries the same
# Bash 3.2 hazard as an unpaired apostrophe, confirmed against 3.2.57: the body
# opens a backtick substitution that consumes the rest of the file. It is left
# unmodelled because no script in the canonical file set uses backticks as shell
# command substitution and ShellCheck's SC2006 keeps it that way, while many
# nested heredoc bodies carry literal backticks as Markdown code spans and
# JavaScript template literals, whose `${...}`, quotes and parens would then be
# re-lexed as shell and reported as breaks that Bash 3.2 parses fine. A guard
# that cries wolf on working scripts gets switched off, which would cost more
# than the case it covers. The macos-stock-bash CI job runs
# `/bin/bash -n` over the whole `--list-files` inventory and still catches a real
# backtick break, so this guard is defence in depth rather than the backstop.
#
# Second known boundary: a heredoc is analysed only when the scan reads every
# character of its delimiter word as a literal one. Bash applies only quote removal
# to a delimiter word and expands nothing, so however such a word is spelled - bare,
# backslash-escaped, single- or double-quoted, or any mix of those - the terminator
# is known exactly, and `cat <<EOF`, `cat <<'EOF'`, `cat <<\EOF` and `cat <<EO"F"`
# all end at a line reading `EOF`. A word stops being readable the moment the scan
# meets something this guard does not model: an unquoted `$` or a backtick, or a
# quote the line never closes. Such a word is skipped rather than guessed at,
# because a delimiter this scan cannot read is one it cannot find the end of a body
# with. A skipped body
# is consumed verbatim, so nothing inside it is checked and nothing it opens can
# leak into the file, and scanning resumes the moment the word reappears; a word
# that never reappears leaves the remainder of that file unchecked. Every heredoc
# in the canonical file set uses a bare or single-quoted word, so nothing there is
# skipped today, and the macos-stock-bash CI job covers what a skip would miss.
fm_lint_parse_guard() {  # <path>...
  local perl_bin
  if ! perl_bin=$(command -v perl); then
    printf 'fm-lint.sh: perl is required for the Bash 3.2 parse guard.\n' >&2
    return 127
  fi
  "$perl_bin" - "$@" <<'PERL'
use strict;
use warnings;

# Lex one line, advancing the shared command-substitution and quote state. Heredoc
# operators are only recognized when $allow_heredoc is set, because Bash 3.2 does
# not start a further heredoc from inside a body it is already scanning.
sub lex_line {
  my ($line, $frames, $quote_ref, $heredocs, $allow_heredoc) = @_;
  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($$quote_ref eq "'") {
      $$quote_ref = '' if $char eq "'";
      next;
    }
    # Inside `$'...'` a backslash escapes the next character, including the closing
    # quote, so the state has to be unwound here rather than by the plain `'` branch.
    if ($$quote_ref eq "\$'") {
      $i++ if $char eq '\\';
      $$quote_ref = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($$quote_ref eq '"' && $char eq '"') {
      $$quote_ref = '';
      next;
    }
    if ($char eq "'" && $$quote_ref eq '') {
      $$quote_ref = "'";
      next;
    }
    if ($char eq '"' && $$quote_ref eq '') {
      $$quote_ref = '"';
      next;
    }
    # Bash 3.2 only starts a comment at the beginning of the text it is scanning,
    # after a newline, or after a blank. Treating any other `#` as a comment would
    # skip the rest of the line and miss the state-opening characters after it.
    if ($char eq '#' && $$quote_ref eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[ \t]/)) {
      last;
    }
    # `$'...'` is ANSI-C quoting, where a backslash escapes the closing quote, so it
    # cannot be lexed as a plain single-quoted string. It is carried in the shared
    # quote state because Bash 3.2 lets it span lines like the other quotes do.
    if ($char eq '$' && $$quote_ref eq '' && substr($line, $i + 1, 1) eq "'") {
      $$quote_ref = "\$'";
      $i++;
      next;
    }
    # `$"..."` is a localized string that otherwise lexes as a double-quoted one.
    if ($char eq '$' && substr($line, $i + 1, 1) eq '"') {
      next;
    }
    # `$(( ... ))` and a bare `(( ... ))` are arithmetic, where `<<` is a left
    # shift rather than a heredoc operator. Tracking them keeps a shift such as
    # `$(( x * (1 << n) ))` from opening a heredoc that never terminates, which
    # would silently disable the guard for the whole rest of the file.
    if ($char eq '$' && substr($line, $i + 1, 2) eq '((') {
      push @$frames, { depth => 2, quote => $$quote_ref, arith => 1 };
      $$quote_ref = '';
      $i += 2;
      next;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @$frames, { depth => 1, quote => $$quote_ref, arith => 0 };
      $$quote_ref = '';
      $i++;
      next;
    }
    if ($$quote_ref eq '' && $char eq '(' && substr($line, $i + 1, 1) eq '(') {
      push @$frames, { depth => 2, quote => $$quote_ref, arith => 1 };
      $i++;
      next;
    }
    if (@$frames && $$quote_ref eq '' && $char eq '(') {
      $frames->[-1]{depth}++;
      next;
    }
    if (@$frames && $$quote_ref eq '' && $char eq ')') {
      $frames->[-1]{depth}--;
      if ($frames->[-1]{depth} == 0) {
        my $frame = pop @$frames;
        $$quote_ref = $frame->{quote};
      }
      next;
    }
    next unless $$quote_ref eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    # `<<<` is a here-string, not a heredoc, and Bash 3.2 parses it normally.
    if (substr($line, $i + 2, 1) eq '<') {
      $i += 2;
      next;
    }
    # A left shift inside arithmetic, and a `<<` inside a body Bash 3.2 is already
    # scanning, both stay redirections-that-aren't.
    if (!$allow_heredoc || (@$frames && $frames->[-1]{arith})) {
      $i++;
      next;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    # The one rule that decides whether this heredoc is analysed at all: every
    # character of the word has to be one the scan reads as a literal. Quoting and
    # escaping stay readable, so `EOF`, `'EOF'`, `\EOF` and `EO"F"` are all the
    # same word. What is not readable is a construct this guard does not model.
    my $readable = 1;
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $readable = 0 if $token eq '`' && $delimiter_quote eq '"';
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      $readable = 0 if $token eq '$' || $token eq '`';
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @$heredocs, {
      delimiter => $delimiter,
      readable => ($readable && $delimiter_quote eq '') ? 1 : 0,
      strip_tabs => $strip_tabs,
      line => $.,
    };
    $i = $j - 1;
  }
}

# Bash 3.2 begins a body with whatever state the operator line ended in, and a
# second heredoc on the same line begins with the state the first one left, so the
# entry snapshot is taken when the body starts rather than at the `<<` token.
sub signature {
  my ($frames, $quote) = @_;
  return join(',', map { $_->{depth} } @$frames) . "|$quote";
}

sub reason {
  my ($entry_quote, $quote) = @_;
  return 'leaves a single quote open (an unpaired apostrophe)' if $quote eq "'";
  return 'leaves a double quote open' if $quote eq '"';
  return "leaves a \$'...' quote open" if $quote eq "\$'";
  return 'closes a quote that was already open' if $quote ne $entry_quote;
  return 'leaves an unbalanced parenthesis';
}

# A root the guard cannot read is reported rather than skipped, so a mistyped or
# unopenable path can never be mistaken for a clean result, and so one bad root
# cannot abort the sweep and leave every later root silently unchecked.
sub report_unreadable {
  my ($path) = @_;
  printf STDERR "fm-lint.sh: %s: not a readable file for the Bash 3.2 parse guard.\n", $path;
  return undef;
}

sub check_file {
  my ($path) = @_;
  my $source;
  open $source, '<', $path or return report_unreadable($path);
  my @frames;
  my @heredocs;
  my $quote = '';
  my $findings = 0;

  while (my $line = <$source>) {
    if (@heredocs) {
      my $pending = $heredocs[0];
      my $candidate = $line;
      $candidate =~ s/\r?\n\z//;
      $candidate =~ s/^\t+// if $pending->{strip_tabs};
      # A delimiter outside the three readable forms leaves no way to know where
      # the body ends, so the body is consumed verbatim: nothing in it is checked
      # and nothing it opens reaches the rest of the file. Scanning resumes if the
      # word turns up again.
      if (!$pending->{readable}) {
        shift @heredocs if $candidate eq $pending->{delimiter};
        next;
      }
      if (!exists $pending->{entry}) {
        $pending->{nested} = scalar(@frames) ? 1 : 0;
        $pending->{entry} = signature(\@frames, $quote);
        $pending->{entry_quote} = $quote;
        $pending->{entry_frames} = [map { {%$_} } @frames];
      }
      if ($candidate eq $pending->{delimiter}) {
        shift @heredocs;
        if ($pending->{nested} && signature(\@frames, $quote) ne $pending->{entry}) {
          printf STDERR "%s:%d: heredoc body inside \$( ) %s; Bash 3.2 then parses the rest of the file as that leftover state.\n",
            $path, $pending->{line}, reason($pending->{entry_quote}, $quote);
          $findings++;
          @frames = @{ $pending->{entry_frames} };
          $quote = $pending->{entry_quote};
        }
        next;
      }
      # Only a body nested in a command substitution is lexed by Bash 3.2; an
      # ordinary heredoc body is read verbatim and cannot leak any state.
      lex_line($line, \@frames, \$quote, \@heredocs, 0) if $pending->{nested};
      next;
    }
    lex_line($line, \@frames, \$quote, \@heredocs, 1);
  }
  close $source;
  # A heredoc whose delimiter never arrives means the guard mis-read the file and
  # scanned the remainder as a phantom body. Reporting that keeps a mis-parse from
  # quietly disabling the rule for everything below it.
  for my $pending (@heredocs) {
    next unless $pending->{readable};
    printf STDERR "%s:%d: the Bash 3.2 parse guard found no `%s` terminator for this heredoc and could not check the rest of the file.\n",
      $path, $pending->{line}, $pending->{delimiter};
    $findings++;
  }
  return $findings;
}

my $findings = 0;
my $errors = 0;
for my $path (@ARGV) {
  if (!-f $path) {
    report_unreadable($path);
    $errors++;
    next;
  }
  my $result = check_file($path);
  if (!defined $result) {
    $errors++;
    next;
  }
  $findings += $result;
}
if ($findings) {
  print STDERR <<'EXPLANATION';
fm-lint.sh: Bash 3.2 (stock macOS /bin/bash) resolves $( ... ) by scanning for the
  matching ) and keeps tracking quote and paren state through any heredoc nested
  inside it. State the body leaves open therefore escapes into the rest of the
  script: one apostrophe in `VAR=$(cat <<EOF ... EOF)` silently swallows every
  later line, so `bash -n` fails at end of file with no hint of the real cause.
  A modern Bash parses the same file cleanly, so this breaks only on macOS.
  Fix the shape rather than the prose - drop the $( ) wrapper, for example
  `IFS= read -r -d '' VAR <<EOF || true` - so no future wording can reintroduce it.
  Known boundary: this check does not model backtick command substitution. An
  unpaired backtick in such a body breaks Bash 3.2 exactly like an apostrophe, but
  modelling it would re-lex the Markdown code spans and JavaScript template
  literals these bodies legitimately carry and report breaks that Bash 3.2 parses
  fine. The macos-stock-bash CI job parses every file in --list-files under stock
  /bin/bash and still catches a real backtick break.
  Second boundary: a heredoc is checked only when every character of its delimiter
  word reads as a literal one, however it is quoted or escaped. A word carrying an
  unquoted $ or a backtick, or a quote the line never closes, is skipped, its body
  read verbatim and unchecked, and scanning resumes where the word reappears.
EXPLANATION
}
exit 1 if $findings || $errors;
exit 0;
PERL
}

if [ "$PARSE_GUARD_ONLY" -eq 1 ]; then
  # Changed-file selection can legitimately yield an empty set, and Bash 3.2 -
  # the very shell this guard exists for - treats "${ROOTS[@]}" as unset under
  # `set -u`, so the empty case has to end here rather than in the expansion.
  if [ "$ROOT_COUNT" -eq 0 ]; then
    printf 'fm-lint.sh: no changed lint targets\n'
    exit 0
  fi
  fm_lint_parse_guard "${ROOTS[@]}"
  exit $?
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
elif [ "$FOLLOW_SOURCES" -eq 0 ]; then
  printf 'fm-lint.sh: local changed-file mode; ShellCheck source following disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

index=1
: > "$WEIGHTS"
for path in "${ROOTS[@]}"; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
  if [ -f "$path" ]; then
    weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  else
    weight=1
  fi
  case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
  printf '%s\t%s\t%s\n' "$weight" "$index" "$path" >> "$WEIGHTS"
  index=$((index + 1))
done

# Largest-first deterministic greedy assignment keeps the two bounded workers
# balanced without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
      FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
      FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# Replay both stable shards in deterministic order and select the first nonzero
# shard status. ShellCheck processes every root in a shard after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

# The structural guard replays after both shards so ShellCheck diagnostics keep
# their deterministic order, and contributes to the same exit selection.
fm_lint_parse_guard "${ROOTS[@]}" || {
  guard_rc=$?
  [ "$overall_rc" -ne 0 ] || overall_rc=$guard_rc
}

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in "${ROOTS[@]}"; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  if [ "$FOLLOW_SOURCES" -eq 1 ]; then
    source_followed=$((source_directives - source_boundaries))
  else
    source_followed=0
  fi
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
