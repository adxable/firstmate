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
  assert_contains "$out" '1  z naprawami' 'a repair round with a fix summary is explained'
  assert_contains "$out" '1  twarde wznowienie' 'a named failure plus a second run is hard recovery'
  assert_contains "$out" '2  NIEWYJAŚNIONE' 'an empty fix summary and a bare exit status are both unexplained'
  assert_contains "$out" 'zadanie-bez-opisu' 'the unexplained list must name the task with no fix summary'
  assert_contains "$out" 'zadanie-goly-kod' 'the unexplained list must name the task with only a gate name'
  assert_not_contains "$out" 'zadanie-czyste  (' 'a clean task must not appear in the unexplained list'
  pass 'classification separates recorded causes from unrecoverable ones'
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

# Usage must be answerable without a home, a database, or a fleet.
test_help_needs_no_fleet_state() {
  local out rc=0
  out=$("$RETRO" --help 2>&1) || rc=$?
  expect_code 0 "$rc" 'help'
  assert_contains "$out" 'fm-retro.sh' 'help must name the tool'
  assert_contains "$out" 'READ-ONLY' 'help must state the read-only contract'

  rc=0
  "$RETRO" --nonsense >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" 'unknown argument'
  pass 'help needs no fleet state'
}

test_classification_separates_recorded_causes_from_unrecoverable_ones
test_second_pass_cost_is_excess_over_the_median_clean_run
test_a_task_below_the_median_contributes_no_negative_cost
test_one_cause_is_found_across_three_differently_named_decision_keys
test_self_reference_and_shared_key_naming_are_not_reported_as_recurrence
test_unreadable_input_is_reported_instead_of_silently_dropped
test_the_run_leaves_the_home_and_the_database_untouched
test_help_needs_no_fleet_state

echo "# all fm-retro tests passed"
