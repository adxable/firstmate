#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs every canonical shell root with ShellCheck's default severity, extended
# analysis, ambient configuration disabled, and one exact ShellCheck version.
# CI and no-mistakes both invoke this script with no arguments, so the file set,
# rule set, version, bounded execution, and diagnostics ordering cannot drift.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
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
# unbalanced swallows the rest of the script. The guard reports exactly the bodies
# that would break, which is why safe existing nesting stays untouched.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the canonical file set
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --parse-guard [path]... run only the Bash 3.2 parse guard
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the canonical file set
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
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
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output rc=0
  local -a roots
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
    "$FM_LINT_SHELLCHECK" --norc --external-sources -- "${roots[@]}" > "$output.out" 2>&1 &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
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
  sed -n '2,35{s/^# \{0,1\}//;p;}' "$SELF"
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
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

if [ "$#" -gt 0 ]; then
  ROOTS=("$@")
else
  ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  printf '%s\n' "${ROOTS[@]}"
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
# Second known boundary: a heredoc whose delimiter word is not literal - an
# unquoted parameter expansion such as `cat <<$D`, a `${...}`, or a substitution -
# names a terminator that only exists after expansion, and this guard deliberately
# resolves no variable and models no expansion. Bash 3.2 parses such a file fine,
# so treating the unexpanded word as a missing terminator would fail a working
# script. The guard instead stops reading that file at the operator line: every
# heredoc above it is still checked, nothing below it is, and nothing is reported.
# The macos-stock-bash CI job covers what the guard then leaves unchecked.
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
    # A `$` or a backtick the delimiter word neither quotes nor escapes makes the
    # real terminator an expansion result, which this guard cannot know. Quoting
    # any part of the word makes Bash take the whole delimiter literally, so only
    # the bare form is unknowable.
    my $expanded = 0;
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
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
      last if $token =~ /[\s;|&()<>]/;
      $expanded = 1 if $token =~ /[\$`]/;
      $delimiter .= $token;
    }
    push @$heredocs,
      { delimiter => $delimiter, strip_tabs => $strip_tabs, line => $., expanded => $expanded };
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
      # The terminator of an expanded delimiter is only known after expansion, so
      # the body has no recognizable end and every later line is unreadable too.
      # Stopping here keeps the guard silent on a file Bash 3.2 parses fine.
      last if $pending->{expanded};
      if (!exists $pending->{entry}) {
        $pending->{nested} = scalar(@frames) ? 1 : 0;
        $pending->{entry} = signature(\@frames, $quote);
        $pending->{entry_quote} = $quote;
        $pending->{entry_frames} = [map { {%$_} } @frames];
      }
      my $candidate = $line;
      $candidate =~ s/\r?\n\z//;
      $candidate =~ s/^\t+// if $pending->{strip_tabs};
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
    last if $pending->{expanded};
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
  Second boundary: a heredoc whose delimiter is not a literal word, such as
  `cat <<$D`, names a terminator that only exists after expansion. This check
  resolves no variable, so it stops reading that file at the operator line and
  reports nothing there rather than failing a script Bash 3.2 parses fine.
EXPLANATION
}
exit 1 if $findings || $errors;
exit 0;
PERL
}

if [ "$PARSE_GUARD_ONLY" -eq 1 ]; then
  fm_lint_parse_guard "${ROOTS[@]}"
  exit $?
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
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
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
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
        env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
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
  source_followed=$((source_directives - source_boundaries))
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

exit "$overall_rc"
