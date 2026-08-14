#!/usr/bin/env bash
# Behavior tests for bin/fm-retro.sh, the read-only pipeline retrospective.
#
# Every case runs against synthetic fixtures, never the operator's live fleet:
# the real home changes while the suite runs, so live data cannot pin behavior.
#
# The fixture database declares only the columns the tool actually selects. That
# is the dependency contract - upstream may add columns freely, and the tool
# breaks only if one of these disappears, which the coverage section reports.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETRO="$ROOT/bin/fm-retro.sh"
TMP_ROOT=$(fm_test_tmproot fm-retro)

command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

make_db() {  # <path>
  local db=$1
  sqlite3 "$db" "
    create table runs (id text primary key, branch text, status text, error text);
    create table step_results (id text primary key, run_id text, step_name text,
                               status text, duration_ms integer);
    create table step_rounds (id text primary key, step_result_id text,
                              trigger_type text, duration_ms integer, fix_summary text);
  "
}

# add_run <db> <run-id> <branch> <status> <error>
add_run() {
  sqlite3 "$1" "insert into runs values ('$2','$3','$4','$5');"
}

# add_step <db> <step-id> <run-id> <step-name> <status> <duration-ms>
add_step() {
  sqlite3 "$1" "insert into step_results values ('$2','$3','$4','$5',$6);"
}

# add_round <db> <round-id> <step-id> <trigger> <duration-ms> <fix-summary>
add_round() {
  sqlite3 "$1" "insert into step_rounds values ('$2','$3','$4',$5,'$6');"
}

# add_decision <home> <task> <key> <body>
add_decision() {
  mkdir -p "$1/data/$2"
  printf '%s\n' "$4" > "$1/data/$2/decision-$3.md"
}

run_retro() {  # <home> <db>
  FM_HOME="$1" FM_RETRO_DB="$2" "$RETRO" 2>&1
}

# A task whose extra passes all carry a recorded cause must not be counted as
# unexplained, and a task whose pipeline burned time the records cannot account
# for must be - that separation is the whole point of the headline metric.
test_classification_separates_recorded_causes_from_unrecoverable_ones() {
  local home db out
  home=$(make_home classify)
  db="$home/state.sqlite"
  make_db "$db"

  # clean: one run, straight through.
  add_run "$db" r-clean fm/zadanie-czyste completed ''
  add_step "$db" s-clean r-clean review completed 600000

  # explained: one repair round that says what it fixed.
  add_run "$db" r-fix fm/zadanie-z-naprawa completed ''
  add_step "$db" s-fix r-fix review completed 1200000
  add_round "$db" rd-fix s-fix auto_fix 600000 'closed the null guard'

  # unexplained by an empty fix summary.
  add_run "$db" r-mute fm/zadanie-bez-opisu completed ''
  add_step "$db" s-mute r-mute review completed 1200000
  add_round "$db" rd-mute s-mute auto_fix 600000 ''

  # unexplained by a bare exit status: the record names the gate, not the cause.
  add_run "$db" r-bare fm/zadanie-goly-kod failed 'step review failed: agent review: claude exited: exit status 1: '
  add_step "$db" s-bare r-bare review failed 1800000

  # hard recovery: a second run after a failure whose error names a real cause.
  add_run "$db" r-hard1 fm/zadanie-wznowione failed 'step push failed: remote rejected: permission denied'
  add_step "$db" s-hard1 r-hard1 push failed 300000
  add_run "$db" r-hard2 fm/zadanie-wznowione completed ''
  add_step "$db" s-hard2 r-hard2 push completed 300000

  out=$(run_retro "$home" "$db")

  assert_contains "$out" '1  czyste' 'the single-pass task must classify as clean'
  assert_contains "$out" '1  wyjaśnione' 'a repair round with a fix summary is explained'
  assert_contains "$out" '1  twarde wznowienie' 'a named failure plus a second run is hard recovery'
  assert_contains "$out" '2  NIEWYJAŚNIONE' 'an empty fix summary and a bare exit status are both unexplained'
  assert_contains "$out" 'zadanie-bez-opisu' 'the unexplained list must name the task with no fix summary'
  assert_contains "$out" 'zadanie-goly-kod' 'the unexplained list must name the task with only a gate name'
  assert_not_contains "$out" 'zadanie-czyste  (' 'a clean task must not appear in the unexplained list'
  pass 'classification separates recorded causes from unrecoverable ones'
}

# What the explained class has in common is a RECOVERABLE CAUSE, not that repair
# rounds happened: a single run that aborted with a named reason and no repair
# round belongs there too. The label must not claim rounds the same report then
# accounts for as an aborted run.
test_a_single_aborted_run_with_a_named_reason_is_classed_as_explained() {
  local home db out
  home=$(make_home aborted)
  db="$home/state.sqlite"
  make_db "$db"

  add_run "$db" c1 fm/czysty completed ''
  add_step "$db" sc1 c1 review completed 600000

  # One run, one named terminal error, zero auto_fix rounds.
  add_run "$db" f1 fm/jeden-bieg-padl failed 'step push failed: remote rejected: permission denied'
  add_step "$db" sf1 f1 push failed 1800000

  out=$(run_retro "$home" "$db")

  assert_contains "$out" '1  wyjaśnione - nadprogramowy przebieg z nazwaną przyczyną' \
    'an aborted run with a named reason is explained, and the label must say only that'
  assert_not_contains "$out" 'rundy naprawcze, każda' \
    'the class label must not claim repair rounds that never happened'
  assert_contains "$out" 'przerwany bieg' \
    'the cost section must still account for it as an aborted run'
  pass 'a single aborted run with a named reason is classed as explained'
}

# A branch whose pipeline was run twice had a second pass by definition, even
# when both runs completed and no repair round was recorded. Letting it into the
# clean sample would price that pass at zero AND lift the median - the sum of
# both runs - that every other number in the report is measured against. With no
# record of WHY it ran again, the pass is unreadable history, which is what the
# headline metric counts, so it must reach that figure and not sit beside it.
test_a_task_run_twice_is_never_clean_even_when_every_run_completed() {
  local home db out
  home=$(make_home tworuns)
  db="$home/state.sqlite"
  make_db "$db"

  # The genuinely clean baseline: one run, 10 minutes.
  add_run "$db" c1 fm/jeden-bieg completed ''
  add_step "$db" sc1 c1 review completed 600000

  # Two completed runs of one branch, 10 minutes each, zero repair rounds.
  add_run "$db" d1 fm/dwa-biegi completed ''
  add_step "$db" sd1 d1 review completed 600000
  add_run "$db" d2 fm/dwa-biegi completed ''
  add_step "$db" sd2 d2 review completed 600000

  out=$(run_retro "$home" "$db")

  assert_contains "$out" '1  czyste' 'only the single-run task may count as clean'
  assert_contains "$out" '1  NIEWYJAŚNIONE' \
    'a second pass with no record of why it happened is unreadable history'
  assert_contains "$out" 'Mediana czystego przebiegu: 10 min (z 1 czystych zadań).' \
    'the twice-run task must not enter the median sample or inflate it to 20 min'
  assert_contains "$out" 'bez ani jednego zapisu przyczyny: 1' \
    'the causeless re-run must be disclosed as its own coverage figure'
  assert_contains "$out" 'dwa-biegi' 'the task must be named in the unexplained list'
  # 20 min total against a 10 min median: the whole 10 min excess is unexplained,
  # so the headline figure must carry it rather than report it beside the table.
  assert_contains "$out" 'Metryka główna: 10 min z tej nadwyżki jest NIEWYJAŚNIONE.' \
    'the excess of a causeless second pass must land in the headline metric'
  pass 'a task run twice is never clean even when every run completed'
}

# The cost model is a comparison, not a stopwatch: a task is only expensive
# relative to what a clean pass of this fleet actually costs.
test_second_pass_cost_is_excess_over_the_median_clean_run() {
  local home db out
  home=$(make_home cost)
  db="$home/state.sqlite"
  make_db "$db"

  # Three clean tasks at 5, 10 and 15 minutes: the median is 10.
  add_run "$db" c1 fm/czysty-a completed ''; add_step "$db" sc1 c1 review completed 300000
  add_run "$db" c2 fm/czysty-b completed ''; add_step "$db" sc2 c2 review completed 600000
  add_run "$db" c3 fm/czysty-c completed ''; add_step "$db" sc3 c3 review completed 900000

  # One task at 40 minutes with a single explained review round: 30 over median.
  add_run "$db" x1 fm/drogi completed ''
  add_step "$db" sx1 x1 review completed 2400000
  add_round "$db" rx1 sx1 auto_fix 2400000 'reworked the parser'

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'Mediana czystego przebiegu: 10 min (z 3 czystych zadań).' \
    'the median must come from the clean tasks and state its sample size'
  assert_contains "$out" '30 min  100%  bramka review' \
    'the excess over the median must be attributed to the gate that consumed it'
  pass 'second-pass cost is excess over the median clean run'
}

# A task below the fleet median still had a second pass, but it cost no extra
# time. Counting a negative excess as a saving would understate the total.
test_a_task_below_the_median_contributes_no_negative_cost() {
  local home db out
  home=$(make_home below)
  db="$home/state.sqlite"
  make_db "$db"

  add_run "$db" c1 fm/czysty-a completed ''; add_step "$db" sc1 c1 review completed 1200000
  add_run "$db" c2 fm/czysty-b completed ''; add_step "$db" sc2 c2 review completed 1200000

  add_run "$db" q1 fm/szybki completed ''
  add_step "$db" sq1 q1 review completed 60000
  add_round "$db" rq1 sq1 auto_fix 30000 'trivial rename'

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'zmieściły się PONIŻEJ mediany: 1' \
    'a below-median task with a second pass must be disclosed, not silently dropped'
  assert_contains "$out" '0 min         RAZEM' \
    'no positive cost may be invented from a below-median task'
  pass 'a task below the median contributes no negative cost'
}

# The acceptance case, reproduced with the real shape of the 2026-08-13/14
# incident: one cause returned three times inside one task, each time filed
# under a differently named decision key, so key equality alone cannot find it.
test_one_cause_is_found_across_three_differently_named_decision_keys() {
  local home db out
  home=$(make_home recurrence)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" r1 fm/rejestr-testow completed ''
  add_step "$db" s1 r1 review completed 600000

  # Each round names the cause the way the real records do: through a gate
  # finding id or a code identifier, never as bare prose.
  add_decision "$home" rejestr-testow review-pierwsza-runda \
    'Finding registry-covers-by-test-name: --check treats a change as covered when a row shares the test name.'
  add_decision "$home" rejestr-testow carveout-subject-changed \
    'Second round: registryCovers is blind to its own draft rows, the same hole we closed for approved rows.'
  add_decision "$home" rejestr-testow manual-row-blanket-coverage \
    'Third time now: manual-pending-row-still-blanket-covers-a-test, so change A silences weakening B.'

  # Three other tasks sharing one word, so the stop list is derived from the data
  # rather than from a hardcoded word list.
  add_decision "$home" inne-zadanie klucz-jeden 'The pipeline pending-review row needs a decision.'
  add_decision "$home" inne-zadanie klucz-dwa 'Another pending-review row question.'
  add_decision "$home" trzecie-zadanie klucz-trzy 'Yet another pending-review row question.'
  add_decision "$home" trzecie-zadanie klucz-cztery 'And one more pending-review row question.'
  add_decision "$home" czwarte-zadanie klucz-piec 'A pending-review row here as well.'
  add_decision "$home" czwarte-zadanie klucz-szesc 'And a final pending-review row.'

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'rejestr-testow' 'the task carrying the recurring cause must be named'
  # The evidence column must show all three keys, which is what proves the tool
  # linked three disguises rather than matching one key against itself.
  printf '%s\n' "$out" | grep -F 'covers' | grep -F 'review-pierwsza-runda' \
    | grep -F 'carveout-subject-changed' | grep -F 'manual-row-blanket-coverage' >/dev/null \
    || fail "the recurring cause must be reported spanning all three decision keys"$'\n'"--- output ---"$'\n'"$out"
  assert_not_contains "$out" 'pending-review' \
    'a word used across several tasks is fleet vocabulary, not a recurring cause'
  pass 'one cause is found across three differently named decision keys'
}

# A term that only recurs because the decision keys are named alike proves
# nothing. Neither does a task quoting its own id.
test_self_reference_and_shared_key_naming_are_not_reported_as_recurrence() {
  local home db out
  home=$(make_home selfref)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" r1 fm/panel-blackscreen completed ''
  add_step "$db" s1 r1 review completed 600000

  add_decision "$home" panel-blackscreen przeglad-runda-jeden \
    'Task panel-blackscreen, round one: the przeglad-runda-jeden gate parked here.'
  add_decision "$home" panel-blackscreen przeglad-runda-dwa \
    'Task panel-blackscreen, round two: the przeglad-runda-dwa gate parked again.'

  out=$(run_retro "$home" "$db")

  assert_not_contains "$out" 'panel-blackscreen        w ' \
    'a task quoting its own id is self-reference, not a recurring cause'
  assert_not_contains "$out" 'przeglad                 w ' \
    'a word the decision keys already share is naming, not recurrence'
  pass 'self-reference and shared key naming are not reported as recurrence'
}

# Nothing the tool failed to read may be swallowed, and no number may be printed
# whose source could not be read.
test_unreadable_input_is_reported_instead_of_silently_dropped() {
  local home db out
  home=$(make_home unreadable)
  db="$home/state.sqlite"
  printf 'this is not a sqlite database at all\n' > "$db"

  # The malformed shape: the key belongs BEFORE the colon, so a key written
  # after it leaves the round without a readable identity.
  cat > "$home/state/zadanie.status" <<'EOF'
working: started
needs-decision: [key=po-dwukropku] the key is on the wrong side of the colon
needs-decision: no key at all on this one
EOF

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'CZEGO NIE UMIAŁEM ODCZYTAĆ' 'the report must always carry the unreadable section'
  assert_contains "$out" 'GRANICE TEGO POMIARU' 'standing limits must stay separate from this run failures'
  assert_not_contains "$out" 'Nic - każdy napotkany rekord' 'a run with parse failures must not claim a clean read'
  assert_contains "$out" 'klucz zapisany PO dwukropku' 'a key after the colon must be reported, not folded into one bucket'
  assert_contains "$out" 'rundy bez klucza   : 1' 'an unkeyed decision round must be counted and disclosed'
  assert_contains "$out" 'nie dała się odczytać' 'a corrupt database must be reported'
  assert_contains "$out" '(pominięta - brak zapisów potoku)' 'classification must be refused, not guessed'
  assert_contains "$out" '(pominięty - brak zapisów potoku' 'cost must be refused, not guessed'
  assert_not_contains "$out" 'Mediana czystego przebiegu' 'no median may be printed without runs to compute it from'
  pass 'unreadable input is reported instead of silently dropped'
}

# The status line grammar belongs to upstream (bin/fm-classify-lib.sh), which
# opens a keyed decision on `blocked` exactly as on `needs-decision` and tolerates
# leading whitespace. Reading it more strictly drops real rounds from the coverage
# count and from the recurrence signal without a word.
test_keyed_blocked_and_indented_rounds_are_read_like_upstream_reads_them() {
  local home db out
  home=$(make_home grammar)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" r1 fm/zadanie completed ''
  add_step "$db" s1 r1 review completed 600000

  cat > "$home/state/zadanie.status" <<'EOF'
working: started
blocked [key=zablokowane]: the gate cannot proceed
resolved [key=zablokowane]: unblocked
blocked [key=zablokowane]: blocked again by the very same thing
  needs-decision  [key=dwie-spacje]: indented, two spaces before the key token
  needs-decision  [key=dwie-spacje]: and the same key a second time
blocked: this one carries no key at all
needs-decision: [key=po-dwukropku] the key is on the wrong side of the colon
EOF

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'rund z decyzją: 6' \
    'blocked rounds must be counted as decision rounds, resolved must not'
  printf '%s\n' "$out" | grep -F 'zablokowane' | grep -F '2 razy' >/dev/null \
    || fail "a reopened blocked key must surface as a recurrence"$'\n'"--- output ---"$'\n'"$out"
  printf '%s\n' "$out" | grep -F 'dwie-spacje' | grep -F '2 razy' >/dev/null \
    || fail "an indented round with extra spacing before the key must keep its key"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" 'rundy bez klucza   : 1' 'a keyless blocked round must be counted and disclosed'
  assert_contains "$out" 'klucz zapisany PO dwukropku' \
    'the malformed key-after-colon shape must stay visible, not be normalised away'
  pass 'keyed blocked and indented rounds are read like upstream reads them'
}

# "I cannot read this right now" and "there is nothing recorded" are different
# facts, and the second must never be printed when the first is true.
test_a_readable_database_with_no_records_reports_zero_coverage_not_a_failed_read() {
  local home db out
  home=$(make_home emptydb)
  db="$home/state.sqlite"
  make_db "$db"

  out=$(run_retro "$home" "$db")

  assert_not_contains "$out" 'nie dała się odczytać' \
    'a database that read perfectly must not be called unreadable'
  assert_contains "$out" 'BAZA ODCZYTANA POPRAWNIE' 'an empty record set must be named as zero coverage'
  assert_contains "$out" 'biegów: 0' 'zero coverage is a number the report may print'
  assert_not_contains "$out" 'Mediana czystego przebiegu' \
    'no median may be computed from an empty record set'
  pass 'a readable database with no records reports zero coverage not a failed read'
}

# A WAL database cannot be opened read-only without its -shm sidecar, which is
# exactly the state a stopped pipeline daemon leaves behind. Refusing there would
# cost both headline sections, and creating the sidecar would write beside
# somebody else's database - so the tool reads its own copy instead.
test_a_wal_database_is_still_read_when_no_sidecar_allows_a_read_only_open() {
  local home db out dbdir before after
  home=$(make_home walstopped)
  dbdir="$home/dbdir"
  mkdir -p "$dbdir"
  db="$dbdir/state.sqlite"
  make_db "$db"
  sqlite3 "$db" "pragma journal_mode=wal;" >/dev/null
  add_run "$db" r1 fm/zadanie-czyste completed ''
  add_step "$db" s1 r1 review completed 600000
  # The daemon-stopped shape: the database stays in WAL mode, the sidecars are
  # gone, and a direct read-only open therefore cannot succeed.
  rm -f "$db-wal" "$db-shm"

  before=$(find "$dbdir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
  out=$(run_retro "$home" "$db")
  after=$(find "$dbdir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)

  assert_contains "$out" '1  czyste' 'classification must survive a WAL database with no sidecars'
  assert_not_contains "$out" 'nie dała się odczytać' 'the copy fallback must not report a failed read'
  assert_contains "$out" 'odczytane z kopii roboczej' 'reading from a copy must be disclosed'
  [ "$before" = "$after" ] || fail "the read created files beside the source database: $after"
  pass 'a WAL database is still read when no sidecar allows a read-only open'
}

# The other half of the same boundary: a live pipeline holds an open WAL writer,
# leaving both sidecars in place. The direct read-only open works there, and must
# be taken - reading a copy would be needless work and a staler snapshot.
test_a_wal_database_with_a_live_writer_is_read_directly() {
  local home db out dbdir fifo before after
  home=$(make_home walrunning)
  dbdir="$home/dbdir"
  mkdir -p "$dbdir"
  db="$dbdir/state.sqlite"
  make_db "$db"
  sqlite3 "$db" "pragma journal_mode=wal;" >/dev/null
  add_run "$db" r1 fm/zadanie-czyste completed ''
  add_step "$db" s1 r1 review completed 600000

  # A writer holding an open transaction is what a running daemon looks like on
  # disk: both sidecars present and the write lock taken.
  fifo="$TMP_ROOT/walrunning.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  sqlite3 "$db" < "$fifo" >/dev/null 2>&1 &
  local writer=$! waited=0
  exec 9> "$fifo"
  printf 'begin immediate;\ninsert into runs values ("r2","fm/w-locie","running","");\n' >&9

  # The writer opens the sidecars asynchronously, and the tool keys on exactly
  # that on-disk state, so the fixture must be in it before the run - otherwise
  # the test races the setup rather than pinning the behavior.
  while { [ ! -e "$db-wal" ] || [ ! -e "$db-shm" ]; } && [ "$waited" -lt 200 ]; do
    waited=$((waited + 1))
    sleep 0.05
  done
  [ -e "$db-wal" ] && [ -e "$db-shm" ] || fail "the writer never opened the WAL sidecars"

  before=$(find "$dbdir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
  out=$(run_retro "$home" "$db")
  after=$(find "$dbdir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)

  printf 'rollback;\n.quit\n' >&9
  exec 9>&-
  wait "$writer" 2>/dev/null || true
  rm -f "$fifo"

  assert_contains "$out" '1  czyste' 'a live writer must not block the retrospective'
  assert_not_contains "$out" 'nie dała się odczytać' 'a WAL database with its sidecars must read directly'
  assert_not_contains "$out" 'odczytane z kopii roboczej' \
    'the copy fallback must not be taken when a direct read-only open works'
  [ "$before" = "$after" ] || fail "the read changed the files beside the source database: $after"
  pass 'a WAL database with a live writer is read directly'
}

# A status file that is itself a symlink may point anywhere outside the state
# directory, so it is refused before any read and said out loud.
test_a_symlinked_status_file_is_refused_and_named() {
  local home db out
  home=$(make_home symlink)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" r1 fm/zadanie completed ''
  add_step "$db" s1 r1 review completed 600000

  printf 'needs-decision [key=obcy-klucz]: a round from outside the state directory\n' \
    > "$TMP_ROOT/elsewhere.status"
  ln -s "$TMP_ROOT/elsewhere.status" "$home/state/podstawione.status"

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'dzienniki statusu  : plików: 0' 'a symlinked status file must not be read'
  assert_not_contains "$out" 'obcy-klucz' 'no line from outside the state directory may reach the report'
  assert_contains "$out" 'dziennik statusu jest dowiązaniem' 'the refusal must be reported, not silent'
  pass 'a symlinked status file is refused and named'
}

# Every bounded list in the report announces what it cut: ten entries read as the
# whole set unless the report says otherwise.
test_the_unexplained_list_announces_the_entries_it_cut() {
  local home db out i
  home=$(make_home truncation)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" c1 fm/czysty completed ''
  add_step "$db" sc1 c1 review completed 600000

  # Thirteen unexplained tasks, each a bare exit status: the list shows ten.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    add_run "$db" "b$i" "fm/bez-przyczyny-$i" failed 'step review failed: agent review: claude exited: exit status 1: '
    add_step "$db" "sb$i" "b$i" review failed $((1800000 + i * 60000))
  done

  out=$(run_retro "$home" "$db")

  assert_contains "$out" '13  NIEWYJAŚNIONE' 'every unexplained task must be counted'
  assert_contains "$out" 'pominiętych tańszych zadań niewyjaśnionych: 3' \
    'a truncated list must state how many entries it cut'
  pass 'the unexplained list announces the entries it cut'
}

# The collapse figure is one of the tool's self-reported coverage numbers, so it
# must count terms it dropped, not the comparisons that dropped them: a short term
# swallowed by two longer supersets is still one collapse.
test_the_collapse_figure_counts_dropped_terms_not_comparisons() {
  local home db out
  home=$(make_home collapse)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" r1 fm/zadanie-fabryka completed ''
  add_step "$db" s1 r1 review completed 600000

  # Both rounds carry the same nest of names, so "software" and "factory" are each
  # swallowed by TWO longer supersets and "software-factory" by one: three dropped
  # terms across five (i,j) comparisons.
  add_decision "$home" zadanie-fabryka runda-jedna \
    'The software-factory-gate rejected it, the software-factory rule fired again.'
  add_decision "$home" zadanie-fabryka runda-druga \
    'Once more the software-factory-gate tripped on the software-factory rule.'

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'Zwiniętych jako to samo słowo w dłuższej postaci: 3.' \
    'the collapse figure must count each dropped term once, not once per comparison'
  pass 'the collapse figure counts dropped terms not comparisons'
}

# When a direct read-only open fails, the reason printed must be the one sqlite
# actually gave. Naming an unobserved cause is the exact failure this tool exists
# to avoid, and the reason must also reach the section that lists what it could
# not read.
test_the_copy_fallback_states_the_reason_it_actually_observed() {
  local home db out dbdir
  home=$(make_home observedreason)
  dbdir="$home/dbdir"
  mkdir -p "$dbdir"
  db="$dbdir/state.sqlite"
  make_db "$db"
  sqlite3 "$db" "pragma journal_mode=wal;" >/dev/null
  add_run "$db" r1 fm/zadanie-czyste completed ''
  add_step "$db" s1 r1 review completed 600000
  # The -shm is PRESENT but unreadable, so the direct open fails for a reason that
  # has nothing to do with a missing sidecar.
  [ -e "$db-shm" ] || sqlite3 "$db" "select count(*) from runs;" >/dev/null
  chmod 000 "$db-shm"

  out=$(run_retro "$home" "$db")
  chmod 600 "$db-shm" 2>/dev/null || true

  assert_contains "$out" '1  czyste' 'the fallback must still produce the report'
  assert_contains "$out" 'odczytane z kopii roboczej' 'reading from a copy must be disclosed'
  assert_not_contains "$out" 'bez pliku -shm' \
    'a cause that was not observed must never be printed as the reason'
  assert_not_contains "$out" 'Nic - każdy napotkany rekord' \
    'the failed direct open must reach the section listing what could not be read'
  assert_contains "$out" 'nie dało się otworzyć wprost tylko do odczytu' \
    'the disclosure must name what actually failed'
  pass 'the copy fallback states the reason it actually observed'
}

# Committed rows can live in the -wal and not in the main file, so a copy without
# it is a different database. The report must show what the source really holds.
test_rows_living_only_in_the_wal_survive_the_copy_fallback() {
  local home db out dbdir fifo writer n before after
  home=$(make_home walrows)
  dbdir="$home/dbdir"
  mkdir -p "$dbdir/src" "$dbdir/live"
  db="$dbdir/live/state.sqlite"

  make_db "$dbdir/src/state.sqlite"
  sqlite3 "$dbdir/src/state.sqlite" "pragma journal_mode=wal; pragma wal_autocheckpoint=0;" >/dev/null
  add_run "$dbdir/src/state.sqlite" r1 fm/w-glownym-pliku completed ''
  add_step "$dbdir/src/state.sqlite" s1 r1 review completed 600000

  # A writer that has committed but not closed leaves its rows in the -wal. The
  # pair is snapshotted without the -shm, which is the shape a stopped daemon
  # leaves and the shape that forces the copy path.
  fifo="$TMP_ROOT/walrows.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  sqlite3 "$dbdir/src/state.sqlite" < "$fifo" >/dev/null 2>&1 &
  writer=$!
  exec 8> "$fifo"
  printf 'pragma wal_autocheckpoint=0;\ninsert into runs values ("r2","fm/tylko-w-wal","completed","");\ninsert into step_results values ("s2","r2","review","completed",600000);\nselect count(*) from runs;\n' >&8
  n=0
  while [ ! -s "$dbdir/src/state.sqlite-wal" ] && [ "$n" -lt 200 ]; do
    n=$((n + 1))
    sleep 0.05
  done
  [ -s "$dbdir/src/state.sqlite-wal" ] || fail "the writer never left rows in the -wal"
  cp "$dbdir/src/state.sqlite" "$db"
  cp "$dbdir/src/state.sqlite-wal" "$db-wal"
  printf '.quit\n' >&8
  exec 8>&-
  wait "$writer" 2>/dev/null || true
  rm -f "$fifo"

  before=$(find "$dbdir/live" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
  out=$(run_retro "$home" "$db")
  after=$(find "$dbdir/live" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)

  assert_contains "$out" 'biegów: 2' 'a run committed only into the -wal must be counted'
  assert_contains "$out" 'odczytane z kopii roboczej' 'reading from a copy must be disclosed'
  [ "$before" = "$after" ] || fail "the read created files beside the source database: $after"
  pass 'rows living only in the wal survive the copy fallback'
}

# An empty step duration is only "the step never started" if the step's own state
# says so. The report states the split it observed, and names any empty duration
# that does not mean not-yet-started instead of explaining it away.
test_empty_step_durations_are_reported_by_their_observed_state() {
  local home db out
  home=$(make_home nullsteps)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" r1 fm/zadanie completed ''
  add_step "$db" s1 r1 review completed 600000
  add_step "$db" s2 r1 push pending NULL
  # The exception: a step recorded as finished yet carrying no duration at all.
  add_step "$db" s3 r1 lint completed NULL

  out=$(run_retro "$home" "$db")

  assert_contains "$out" 'puste wg ZAOBSERWOWANEGO stanu kroku: completed: 1, pending: 1' \
    'the split of empty durations must be the one observed in the records'
  assert_contains "$out" 'nieuruchomionych: 1 z 2' \
    'only the states that really mean not-yet-started may be counted as such'
  assert_contains "$out" 'kroków bez zmierzonego czasu w stanie "completed": 1' \
    'an empty duration on a finished step must be named, not explained away'
  assert_not_contains "$out" 'Nic - każdy napotkany rekord' \
    'that exception must reach the section listing what could not be read'
  pass 'empty step durations are reported by their observed state'
}

# The tool is a retrospective: reading it must never change the fleet it reads.
test_the_run_leaves_the_home_and_the_database_untouched() {
  local home db out before after
  home=$(make_home readonly)
  db="$home/state.sqlite"
  make_db "$db"
  add_run "$db" r1 fm/zadanie completed ''
  add_step "$db" s1 r1 review completed 600000
  printf 'working: setup\n' > "$home/state/zadanie.status"
  add_decision "$home" zadanie klucz 'A decision body.'

  before=$(find "$home" -type f -exec shasum {} \; | LC_ALL=C sort)
  out=$(run_retro "$home" "$db")
  after=$(find "$home" -type f -exec shasum {} \; | LC_ALL=C sort)

  [ "$before" = "$after" ] || fail "the retrospective changed files under the home"
  assert_contains "$out" 'RETROSPEKTYWA POTOKU' 'the report must still have been produced'
  pass 'the run leaves the home and the database untouched'
}

# The precise half of the read-only promise, on the path almost every run takes.
# Reading a WAL database DOES write a read-mark into the -shm sidecar, so the
# claim that survives is the narrow one: the database file and its -wal come out
# byte-identical. That is what is pinned here, and nothing wider.
test_a_wal_database_and_its_wal_are_byte_identical_after_a_run() {
  local home db out dbdir fifo writer n before_db before_wal after_db after_wal
  home=$(make_home walbytes)
  dbdir="$home/dbdir"
  mkdir -p "$dbdir"
  db="$dbdir/state.sqlite"
  make_db "$db"
  sqlite3 "$db" "pragma journal_mode=wal; pragma wal_autocheckpoint=0;" >/dev/null
  add_run "$db" r1 fm/zadanie-czyste completed ''
  add_step "$db" s1 r1 review completed 600000

  # A writer that keeps the sidecars open and has advanced the WAL since the last
  # reader: the shape the live daemon leaves, and the one where the read really
  # does touch the -shm.
  fifo="$TMP_ROOT/walbytes.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  sqlite3 "$db" < "$fifo" >/dev/null 2>&1 &
  writer=$!
  exec 7> "$fifo"
  printf 'pragma wal_autocheckpoint=0;\ninsert into runs values ("r2","fm/drugie","completed","");\ninsert into step_results values ("s2","r2","review","completed",600000);\n' >&7
  n=0
  while { [ ! -s "$db-wal" ] || [ ! -e "$db-shm" ]; } && [ "$n" -lt 200 ]; do
    n=$((n + 1))
    sleep 0.05
  done
  [ -s "$db-wal" ] && [ -e "$db-shm" ] || fail "the writer never opened the WAL sidecars"

  before_db=$(shasum "$db" | cut -d' ' -f1)
  before_wal=$(shasum "$db-wal" | cut -d' ' -f1)
  out=$(run_retro "$home" "$db")
  after_db=$(shasum "$db" | cut -d' ' -f1)
  after_wal=$(shasum "$db-wal" | cut -d' ' -f1)

  printf '.quit\n' >&7
  exec 7>&-
  wait "$writer" 2>/dev/null || true
  rm -f "$fifo"

  assert_contains "$out" 'RETROSPEKTYWA POTOKU' 'the report must still have been produced'
  [ "$before_db" = "$after_db" ] || fail "the retrospective changed the database file itself"
  [ "$before_wal" = "$after_wal" ] || fail "the retrospective changed the database -wal"
  pass 'a wal database and its wal are byte-identical after a run'
}

# Usage must be answerable without a home, a database, or a fleet.
test_help_needs_no_fleet_state() {
  local out rc=0
  out=$("$RETRO" --help 2>&1) || rc=$?
  expect_code 0 "$rc" 'help'
  assert_contains "$out" 'fm-retro.sh' 'help must name the tool'
  # The contract help states must be the true one: what stays untouched, and the
  # side effect a WAL read really has. A blanket no-locks claim is what this
  # replaced, so help must not carry it back.
  assert_contains "$out" 'shared lock' 'help must disclose the lock a WAL read holds'
  assert_contains "$out" 'byte-identical' 'help must state which files really come out unchanged'
  assert_not_contains "$out" 'takes no locks' 'help must not restate the blanket no-locks claim'
  assert_not_contains "$out" 'set -u' 'help must stop at the end of the header, not spill into code'

  rc=0
  "$RETRO" --nonsense >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" 'unknown argument'
  pass 'help needs no fleet state'
}

test_classification_separates_recorded_causes_from_unrecoverable_ones
test_a_single_aborted_run_with_a_named_reason_is_classed_as_explained
test_a_task_run_twice_is_never_clean_even_when_every_run_completed
test_second_pass_cost_is_excess_over_the_median_clean_run
test_a_task_below_the_median_contributes_no_negative_cost
test_one_cause_is_found_across_three_differently_named_decision_keys
test_self_reference_and_shared_key_naming_are_not_reported_as_recurrence
test_unreadable_input_is_reported_instead_of_silently_dropped
test_keyed_blocked_and_indented_rounds_are_read_like_upstream_reads_them
test_a_readable_database_with_no_records_reports_zero_coverage_not_a_failed_read
test_a_wal_database_is_still_read_when_no_sidecar_allows_a_read_only_open
test_a_wal_database_with_a_live_writer_is_read_directly
test_the_copy_fallback_states_the_reason_it_actually_observed
test_rows_living_only_in_the_wal_survive_the_copy_fallback
test_empty_step_durations_are_reported_by_their_observed_state
test_the_collapse_figure_counts_dropped_terms_not_comparisons
test_a_symlinked_status_file_is_refused_and_named
test_the_unexplained_list_announces_the_entries_it_cut
test_the_run_leaves_the_home_and_the_database_untouched
test_a_wal_database_and_its_wal_are_byte_identical_after_a_run
test_help_needs_no_fleet_state

echo "# all fm-retro tests passed"
