#!/usr/bin/env bash
# fm-retro.sh - read-only pipeline retrospective over this home's own records.
#
# PROTOTYPE. It answers exactly one question: what did the extra pipeline passes
# cost, and which cause keeps coming back? It is deliberately the smallest thing
# that answers that question on real fleet data, so the captain can judge whether
# a fuller classifier is worth building. It is not a general reporting surface.
#
# What stops being done by hand, per section:
#   coverage      - reading a number without knowing which records it came from.
#   classification- opening every task's records to ask "did this go through in one pass".
#   cost          - adding up pipeline durations by hand to size the rework.
#   recurrence    - reading thousands of status-log lines to notice that three
#                   differently-named gate findings were one cause wearing three
#                   disguises.
#
# READ-ONLY. It opens the no-mistakes database read-only, never writes to the
# fleet home, never touches a project, and takes no locks.
#
# Sources, all local:
#   $FM_RETRO_DB (default ~/.no-mistakes/state.sqlite)
#                        runs, step_results, step_rounds - the only source of
#                        pass and duration data.
#   $FM_HOME/state/<id>.status
#                        keyed `needs-decision [key=...]` rounds. Teardown deletes
#                        these, so they cover live tasks only.
#   $FM_HOME/data/<id>/decision-<key>.md
#                        firstmate's own decision records. These SURVIVE teardown
#                        and carry the key in the filename, which is what makes
#                        recurrence answerable for finished tasks at all.
#
# Defensive by contract: the status format and bin/fm-classify-lib.sh belong to
# upstream and may change. Everything this tool could not parse is reported in the
# final section instead of being silently dropped, and no number is printed whose
# coverage is not stated.
#
# Environment:
#   FM_HOME              fleet home (default: this repo)
#   FM_STATE_OVERRIDE    state directory (default: $FM_HOME/state)
#   FM_DATA_OVERRIDE     data directory  (default: $FM_HOME/data)
#   FM_RETRO_DB          no-mistakes sqlite path
#
# Usage:
#   fm-retro.sh          print the Polish retrospective
#   fm-retro.sh --help   usage
#
# Output is Polish because the captain reads it; the code is English.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DB="${FM_RETRO_DB:-$HOME/.no-mistakes/state.sqlite}"

# A term must span at least this many distinct decision keys of one task before it
# counts as a recurring topic, and must stay under the fleet-wide spread below or
# it is treated as vocabulary rather than a cause.
MIN_KEYS=2
MAX_SPREAD=3
TOP_PER_TASK=5
TAB_CH=$(printf '\t')

usage() {
  sed -n '2,49p' "$SCRIPT_DIR/fm-retro.sh" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) printf 'fm-retro.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-retro.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

WARN="$TMP/warn"
: > "$WARN"
warn() { printf '%s\n' "$1" >> "$WARN"; }

# --- source 1: the no-mistakes database -------------------------------------
#
# Opened read-only via the sqlite URI so a retrospective can never mutate or
# lock the live pipeline database. Tabs and newlines are flattened inside SQL
# because the extract is tab-separated.

: > "$TMP/facts.tsv"
DB_OK=0
if ! command -v sqlite3 >/dev/null 2>&1; then
  warn 'sqlite3 nie jest zainstalowany - bez niego nie ma klasyfikacji ani kosztu.'
elif [ ! -r "$DB" ]; then
  warn "baza no-mistakes nieczytelna lub nieobecna: $DB"
else
  flat() { printf "replace(replace(coalesce(%s,''), char(9),' '), char(10),' ')" "$1"; }
  ERR_SQL=$(flat error)
  FIX_SQL=$(flat rd.fix_summary)
  if sqlite3 -separator "$TAB_CH" "file:$DB?mode=ro" \
       "select 'R', id, branch, status, $ERR_SQL from runs;
        select 'D', sr.run_id, sr.step_name, rd.trigger_type, coalesce(rd.duration_ms,0), $FIX_SQL
          from step_rounds rd join step_results sr on sr.id = rd.step_result_id;
        select 'S', run_id, step_name, status, coalesce(duration_ms,-1) from step_results;" \
       > "$TMP/facts.tsv" 2> "$TMP/dberr" && [ -s "$TMP/facts.tsv" ]; then
    DB_OK=1
  else
    warn "baza no-mistakes nie dała się odczytać: $(tr '\n' ' ' < "$TMP/dberr")"
  fi
fi

# --- source 2 and 3: keyed decision rounds ----------------------------------
#
# One row per decision round: task, key, origin, text. Both sources are merged
# because neither is complete on its own - the status log has the full round
# text but dies at teardown, the decision file survives teardown but exists only
# where firstmate wrote one.

: > "$TMP/decisions.tsv"
DEC_FILES=0
STATUS_FILES=0
STATUS_LINES=0
STATUS_UNKEYED=0
STATUS_MALFORMED=0

for f in "$DATA"/*/decision-*.md; do
  [ -f "$f" ] || continue
  task=$(basename "$(dirname "$f")")
  key=$(basename "$f" .md)
  key=${key#decision-}
  DEC_FILES=$((DEC_FILES + 1))
  printf '%s\t%s\tzapis-decyzji\t%s\n' "$task" "$key" "$(tr '\n\t' '  ' < "$f")" >> "$TMP/decisions.tsv"
done

for f in "$STATE"/*.status; do
  [ -f "$f" ] || continue
  task=$(basename "$f" .status)
  STATUS_FILES=$((STATUS_FILES + 1))
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      needs-decision*) ;;
      *) continue ;;
    esac
    STATUS_LINES=$((STATUS_LINES + 1))
    key=$(printf '%s\n' "$line" | sed -n 's/^needs-decision \[key=\([^]]*\)\]:.*$/\1/p')
    if [ -n "$key" ]; then
      printf '%s\t%s\tdziennik-statusu\t%s\n' "$task" "$key" "$line" >> "$TMP/decisions.tsv"
      continue
    fi
    # Defensive: the key belongs BEFORE the colon. A key after the colon is the
    # known malformed shape and is reported rather than folded into one bucket.
    case $line in
      needs-decision:*\[key=*)
        STATUS_MALFORMED=$((STATUS_MALFORMED + 1))
        warn "$task: klucz zapisany PO dwukropku, więc runda nie ma czytelnej tożsamości: $(printf '%.90s' "$line")"
        ;;
      *)
        STATUS_UNKEYED=$((STATUS_UNKEYED + 1))
        ;;
    esac
  done < "$f"
done

# --- classification and per-event cost --------------------------------------
#
# An "event to explain" is either an auto_fix round or a run that ended without
# success. Its explanation grade is what the records actually recover:
#   nazwana       - the substrate says WHAT was wrong (a fix summary, a specific error)
#   tylko-miejsce - only WHICH gate died; the pipeline recorded a bare exit status
#   brak          - nothing at all
# "tylko-miejsce" and "brak" both count as unexplained, because a gate name is a
# location, not a cause.

: > "$TMP/model.tsv"
if [ "$DB_OK" -eq 1 ]; then
  awk -F'\t' -v OFS='\t' '
    $1 == "R" {
      run = $2; branch = $3; st = $4; err = $5
      task = branch
      if (substr(task, 1, 3) == "fm/") task = substr(task, 4)
      else nonfm[branch] = 1
      run_task[run] = task
      run_err[run] = err
      tasks[task] = 1
      runs_total++
      runs_n[task]++
      if (st == "completed") completed_n[task]++
      else if (st == "failed" || st == "cancelled") term_bad[run] = 1
      else { open_n[task]++; if (st != "running" && st != "pending") unknown_run_status[st]++ }
      next
    }
    $1 == "D" {
      if ($4 != "auto_fix") next
      nr++; rd_run[nr] = $2; rd_step[nr] = $3; rd_dur[nr] = $5; rd_fix[nr] = $6
      if (rd_fix[nr] == "") rounds_nofix++; else rounds_fix++
      next
    }
    $1 == "S" {
      run = $2; d = $5
      if (d < 0) { steps_null++; next }
      steps_set++
      run_dur[run] += d
      next
    }
    END {
      for (i = 1; i <= nr; i++) {
        task = run_task[rd_run[i]]
        if (task == "") { orphan_rounds++; continue }
        events_n[task]++
        if (rd_fix[i] == "") {
          unexplained_n[task]++
          bucket = "niewyjaśnione"
        } else {
          bucket = "bramka " rd_step[i]
        }
        print "EVENT", task, bucket, rd_dur[i]
      }
      for (run in run_task) {
        if (!(run in term_bad)) continue
        task = run_task[run]
        err = run_err[run]
        events_n[task]++
        if (err == "") {
          grade = "brak"; unexplained_n[task]++; bucket = "niewyjaśnione"
        } else if (err ~ /exit status [0-9]+: *$/) {
          grade = "tylko-miejsce"; unexplained_n[task]++; bucket = "niewyjaśnione"
        } else {
          grade = "nazwana"; bucket = "przerwany bieg"
        }
        grade_n[grade]++
        print "EVENT", task, bucket, run_dur[run] + 0
      }
      for (task in tasks) {
        dur = 0
        for (run in run_task) if (run_task[run] == task) dur += run_dur[run] + 0
        e = events_n[task] + 0; u = unexplained_n[task] + 0
        if (open_n[task] + 0 > 0) cls = "w locie"
        else if (e == 0 && completed_n[task] + 0 > 0) cls = "czyste"
        else if (u > 0) cls = "NIEWYJAŚNIONE"
        else if (runs_n[task] + 0 > 1) cls = "twarde wznowienie"
        else cls = "z naprawami"
        print "TASK", task, cls, runs_n[task] + 0, e, u, dur
      }
      print "COV", "runs", runs_total + 0
      print "COV", "steps_set", steps_set + 0
      print "COV", "steps_null", steps_null + 0
      print "COV", "rounds_fix", rounds_fix + 0
      print "COV", "rounds_nofix", rounds_nofix + 0
      print "COV", "grade_named", grade_n["nazwana"] + 0
      print "COV", "grade_place", grade_n["tylko-miejsce"] + 0
      print "COV", "grade_none", grade_n["brak"] + 0
      for (s in unknown_run_status) print "WARN", "nieznany stan biegu \"" s "\" w " unknown_run_status[s] " rekordach - policzony jako niezakończony"
      for (b in nonfm) print "WARN", "gałąź \"" b "\" nie ma przedrostka fm/, więc tożsamość zadania jest zgadywana"
      if (orphan_rounds + 0 > 0) print "WARN", orphan_rounds " rund naprawczych wskazuje bieg, którego nie ma w tabeli biegów - pominięte"
    }
  ' "$TMP/facts.tsv" > "$TMP/model.tsv"
  awk -F'\t' '$1=="WARN"{print $2}' "$TMP/model.tsv" >> "$WARN"
fi

cov() { awk -F'\t' -v k="$1" '$1=="COV" && $2==k {print $3; found=1} END{if(!found) print 0}' "$TMP/model.tsv"; }

# Median total pipeline duration over clean tasks. The whole cost model hangs on
# this one number, so it is printed with the sample size that produced it.
awk -F'\t' '$1=="TASK" && $3=="czyste" {print $7}' "$TMP/model.tsv" | sort -n > "$TMP/clean.txt"
CLEAN_N=$(wc -l < "$TMP/clean.txt" | tr -d ' ')
MEDIAN=0
if [ "$CLEAN_N" -gt 0 ]; then
  MEDIAN=$(awk 'NR==int((n+1)/2){print}' n="$CLEAN_N" "$TMP/clean.txt")
  [ -n "$MEDIAN" ] || MEDIAN=0
fi

# --- report ------------------------------------------------------------------

ms_min() { awk -v v="$1" 'BEGIN{printf "%d", (v+30000)/60000}'; }

printf 'RETROSPEKTYWA POTOKU (prototyp)\n'
printf 'dom: %s\n' "$FM_HOME"
printf '\n'

printf '== POKRYCIE DANYCH ==\n'
if [ "$DB_OK" -eq 1 ]; then
  ROUNDS_ALL=$(( $(cov rounds_fix) + $(cov rounds_nofix) ))
  printf '  zapisy potoku      : %s\n' "$DB"
  printf '                       biegów: %s, kroków zmierzonych: %s, rund naprawczych: %s\n' \
    "$(cov runs)" "$(cov steps_set)" "$ROUNDS_ALL"
  printf '  czas kroku         : zmierzonych: %s, pustych: %s\n' "$(cov steps_set)" "$(cov steps_null)"
  printf '                       (puste to kroki, które nigdy nie ruszyły - liczone jako zero, nie zgadywane)\n'
  printf '  powód rundy        : z opisem naprawy: %s z %s\n' "$(cov rounds_fix)" "$ROUNDS_ALL"
  printf '  powód przerwania   : nazwanych: %s, tylko z nazwą bramki: %s, bez komunikatu: %s\n' \
    "$(cov grade_named)" "$(cov grade_place)" "$(cov grade_none)"
  printf '                       (sama nazwa bramki mówi GDZIE, nie DLACZEGO - liczy się jako niewyjaśnione)\n'
else
  printf '  zapisy potoku      : BRAK - klasyfikacji i kosztu NIE LICZĘ\n'
fi
printf '  dzienniki statusu  : plików: %s, rund z decyzją: %s\n' "$STATUS_FILES" "$STATUS_LINES"
printf '                       (sprzątanie zadania je kasuje, więc to tylko zadania jeszcze żywe)\n'
printf '  zapisy decyzji     : plików: %s\n' "$DEC_FILES"
printf '                       (data/<zadanie>/decision-<klucz>.md, przeżywają sprzątanie)\n'
if [ "$STATUS_UNKEYED" -gt 0 ]; then
  printf '  rundy bez klucza   : %s - nie wchodzą do analizy nawrotowości\n' "$STATUS_UNKEYED"
fi
if [ "$STATUS_MALFORMED" -gt 0 ]; then
  printf '  rundy z klucz. po dwukropku: %s - wypisane niżej\n' "$STATUS_MALFORMED"
fi
printf '\n'

printf '== KLASYFIKACJA ZAKOŃCZONYCH ZADAŃ ==\n'
if [ "$DB_OK" -eq 1 ]; then
  # Counts lead the line: the labels carry Polish diacritics and awk pads by
  # bytes, so a column of padded labels would not line up.
  awk -F'\t' '$1=="TASK"{n[$3]++} END{
    order[1]="czyste"; order[2]="z naprawami"; order[3]="twarde wznowienie"
    order[4]="NIEWYJAŚNIONE"; order[5]="w locie"
    desc["czyste"]="jeden bieg, zero rund naprawczych"
    desc["z naprawami"]="rundy naprawcze, każda z nazwaną przyczyną"
    desc["twarde wznowienie"]="potok trzeba było uruchomić od nowa, przyczyna nazwana"
    desc["NIEWYJAŚNIONE"]="jest nadprogramowy przebieg, którego przyczyny NIE DA SIĘ dziś odtworzyć"
    desc["w locie"]="jeszcze trwa, pominięte w rachunku kosztu"
    for (i=1;i<=5;i++) { k=order[i]; printf "  %4d  %s - %s\n", n[k]+0, k, desc[k]; tot+=n[k]+0 }
    printf "  %4d  razem\n", tot
  }' "$TMP/model.tsv"
  awk -F'\t' '$1=="TASK" && $3=="NIEWYJAŚNIONE"{printf "%d\t%s\t%d\t%d\n", $7, $2, $5, $6}' "$TMP/model.tsv" \
    | sort -rn | head -10 > "$TMP/unexplained.tsv"
  if [ -s "$TMP/unexplained.tsv" ]; then
    printf '\n  Zadania niewyjaśnione, od najdroższego:\n'
    awk -F'\t' '{printf "    %5d min  %s  (zdarzeń: %d, w tym bez odtwarzalnej przyczyny: %d)\n", ($1+30000)/60000, $2, $3, $4}' \
      "$TMP/unexplained.tsv"
  fi
else
  printf '  (pominięta - brak zapisów potoku)\n'
fi
printf '\n'

printf '== KOSZT DRUGICH PRZEBIEGÓW ==\n'
if [ "$DB_OK" -eq 1 ] && [ "$CLEAN_N" -gt 0 ]; then
  printf '  Mediana czystego przebiegu: %s min (z %s czystych zadań).\n' "$(ms_min "$MEDIAN")" "$CLEAN_N"
  printf '  Nadwyżka = czas zadania minus ta mediana, nigdy poniżej zera.\n'
  printf '  Rozdzielona między przyczyny proporcjonalnie do zmierzonego czasu zdarzeń.\n\n'
  awk -F'\t' -v median="$MEDIAN" '
    $1=="TASK" { dur[$2]=$7; cls[$2]=$3; next }
    $1=="EVENT" { n=++cnt; et[n]=$2; eb[n]=$3; ed[n]=$4; sumd[$2]+=$4; sumn[$2]++ }
    END {
      for (i=1;i<=cnt;i++) {
        t=et[i]
        if (cls[t]=="w locie" || cls[t]=="czyste") continue
        excess = dur[t] - median
        if (excess <= 0) { belowmed[t]=1; continue }
        share = (sumd[t] > 0) ? ed[i]/sumd[t] : 1.0/sumn[t]
        bucket[eb[i]] += excess * share
        total += excess * share
      }
      for (b in bucket) printf "%d\t%s\n", bucket[b], b
      printf "%d\t__TOTAL__\n", total
      nb=0; for (t in belowmed) nb++
      printf "%d\t__BELOW__\n", nb
    }
  ' "$TMP/model.tsv" > "$TMP/cost.tsv"
  TOTAL=$(awk -F'\t' '$2=="__TOTAL__"{print $1}' "$TMP/cost.tsv")
  BELOW=$(awk -F'\t' '$2=="__BELOW__"{print $1}' "$TMP/cost.tsv")
  UNEXP=$(awk -F'\t' '$2=="niewyjaśnione"{print $1}' "$TMP/cost.tsv")
  [ -n "$UNEXP" ] || UNEXP=0
  # Field-exact so a bucket or task name that happens to contain "__" is never
  # mistaken for a sentinel row.
  awk -F'\t' '$2 !~ /^__[A-Z]+__$/' "$TMP/cost.tsv" | sort -rn \
    | awk -F'\t' -v tot="$TOTAL" '{pct = tot>0 ? 100*$1/tot : 0; printf "    %5d min  %3.0f%%  %s\n", ($1+30000)/60000, pct, $2}'
  printf '    %5d min         RAZEM\n' "$(ms_min "$TOTAL")"
  printf '\n'
  printf '  Metryka główna: %s min z tej nadwyżki jest NIEWYJAŚNIONE.\n' "$(ms_min "$UNEXP")"
  printf '  To czas, który potok naprawdę zużył, a jego przyczyny nikt już nie odtworzy.\n'
  if [ "${BELOW:-0}" -gt 0 ]; then
    printf '  Zadań z nadprogramowym przebiegiem, które zmieściły się PONIŻEJ mediany: %s.\n' "$BELOW"
    printf '  Ich nadwyżki nie liczę - ujemna nadwyżka to nie oszczędność.\n'
  fi
else
  printf '  (pominięty - brak zapisów potoku albo zero czystych zadań, więc mediana nie ma podstawy)\n'
fi
printf '\n'

printf '== PRZYCZYNY, KTÓRE WRACAJĄ ==\n'
if [ ! -s "$TMP/decisions.tsv" ]; then
  printf '  (brak rund z decyzją w zapisach tego domu)\n'
else
  # Signal A: the same key reopened. Precise, no heuristic.
  awk -F'\t' '$3=="dziennik-statusu"{c[$1 "\t" $2]++} END{for (k in c) if (c[k]>1) printf "%d\t%s\n", c[k], k}' \
    "$TMP/decisions.tsv" | sort -rn > "$TMP/rekeys.tsv"
  if [ -s "$TMP/rekeys.tsv" ]; then
    printf '  Ten sam klucz decyzji otwarty ponownie:\n'
    awk -F'\t' '{printf "    %-42s %-30s %d razy\n", $2, $3, $1}' "$TMP/rekeys.tsv"
  else
    printf '  Ten sam klucz decyzji otwarty ponownie: nie zdarzyło się.\n'
  fi
  printf '\n'
  # Signal B: one topic wearing several key names inside one task.
  awk -F'\t' -v minkeys="$MIN_KEYS" -v maxspread="$MAX_SPREAD" -v top="$TOP_PER_TASK" '
    function trim(s,   t){ t=s; gsub(/^[^a-z0-9]+/,"",t); gsub(/[^a-z0-9]+$/,"",t); return t }
    function note(task, key, t) {
      if (length(t) < 6 || length(t) > 40) return
      if (t ~ /^[0-9._-]+$/) return
      if (t ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]/) return
      if ((task SUBSEP t) in taskword) return
      if ((task SUBSEP t) in taskkey) return
      if (t in seen) return
      seen[t] = 1
      if (!((task SUBSEP t SUBSEP key) in kseen)) {
        kseen[task SUBSEP t SUBSEP key] = 1
        keys[task SUBSEP t]++
        klist[task SUBSEP t] = klist[task SUBSEP t] " " key
        if ((key SUBSEP t) in keyword) keyshare[task SUBSEP t]++
      }
      if (!((t SUBSEP task) in tseen)) { tseen[t SUBSEP task] = 1; spread[t]++ }
    }
    # Index the words that the task id and the decision keys are themselves made
    # of. A word the names already share is naming, not evidence of recurrence.
    function index_name(task, key, s,   p, m, j, w) {
      # The whole name, then every word it is built from. A task id or a decision
      # key quoted inside its own decision text is self-reference, not a cause
      # that came back.
      if (key == "") taskword[task SUBSEP tolower(s)] = 1
      else taskkey[task SUBSEP tolower(s)] = 1
      p = s; gsub(/[A-Z]/, " &", p); gsub(/[-_.]+/, " ", p)
      m = split(tolower(p), w, " ")
      for (j = 1; j <= m; j++) {
        if (key == "") taskword[task SUBSEP trim(w[j])] = 1
        else keyword[key SUBSEP trim(w[j])] = 1
      }
    }
    # Pass one indexes every name in the file, so a key introduced by a LATER
    # round still suppresses its own mentions in an earlier one. Pass two, over
    # the same file, extracts terms against that complete index.
    NR == FNR {
      task=$1; key=$2
      if (!((task SUBSEP "") in idxdone)) { idxdone[task SUBSEP ""]=1; index_name(task, "", task) }
      if (!((task SUBSEP key) in idxdone)) { idxdone[task SUBSEP key]=1; index_name(task, key, key) }
      next
    }
    {
      task=$1; key=$2; text=$4
      gsub(/[^A-Za-z0-9_.-]+/, " ", text)
      n = split(text, w, " ")
      delete seen
      for (i = 1; i <= n; i++) {
        raw = w[i]
        t = trim(tolower(raw))
        compound = (t ~ /[-_.]/)
        camel = (raw ~ /[a-z][A-Z]/)
        if (!compound && !camel) continue
        note(task, key, t)
        p = raw; gsub(/[A-Z]/, " &", p); gsub(/[-_.]+/, " ", p)
        m = split(tolower(p), parts, " ")
        if (m > 1) for (j = 1; j <= m; j++) note(task, key, trim(parts[j]))
      }
    }
    END {
      nk = 0
      for (k in keys) {
        split(k, a, SUBSEP); task = a[1]; t = a[2]
        if (keys[k] < minkeys) continue
        if (spread[t] >= maxspread) { vocab++; continue }
        if (keyshare[k] + 0 >= 2) { tauto++; continue }
        nk++; ktask[nk] = task; kterm[nk] = t; kn[nk] = keys[k]; kl[nk] = substr(klist[k], 2)
      }
      # Collapse near-duplicates: "software" and "factory" alongside
      # "software-factory" are one topic reported three times. The longer term
      # wins whenever it is at least as recurrent.
      for (i = 1; i <= nk; i++)
        for (j = 1; j <= nk; j++)
          if (i != j && ktask[i] == ktask[j] && kterm[i] != kterm[j] &&
              index(kterm[j], kterm[i]) > 0 && kn[j] >= kn[i]) { drop[i] = 1; dup++ }
      for (i = 1; i <= nk; i++)
        if (!(i in drop)) printf "%d\t%s\t%s\t%s\n", kn[i], ktask[i], kterm[i], kl[i]
      printf "%d\t__VOCAB__\t\t\n", vocab + 0
      printf "%d\t__TAUTO__\t\t\n", tauto + 0
      printf "%d\t__DUP__\t\t\n", dup + 0
    }
  ' "$TMP/decisions.tsv" "$TMP/decisions.tsv" | sort -t"$TAB_CH" -k2,2 -k1,1nr > "$TMP/terms.tsv"

  VOCAB=$(awk -F'\t' '$2=="__VOCAB__"{print $1}' "$TMP/terms.tsv")
  TAUTO=$(awk -F'\t' '$2=="__TAUTO__"{print $1}' "$TMP/terms.tsv")
  DUP=$(awk -F'\t' '$2=="__DUP__"{print $1}' "$TMP/terms.tsv")
  awk -F'\t' '$2 !~ /^__[A-Z]+__$/' "$TMP/terms.tsv" > "$TMP/hits.tsv"
  HITS=$(wc -l < "$TMP/hits.tsv" | tr -d ' ')
  if [ "${HITS:-0}" -eq 0 ]; then
    printf '  Żaden temat nie pojawił się w więcej niż jednej rundzie decyzyjnej tego samego zadania.\n'
  else
    printf '  Temat w więcej niż jednej rundzie tego samego zadania\n'
    printf '  (heurystyka po treści decyzji, nie werdykt - lista kluczy obok jest dowodem do przeczytania):\n'
    # Two passes again so each task's suppressed-candidate count is printed with
    # that task, never as an unattributed tail. A bounded list that hides its own
    # truncation reads as complete coverage when it is not.
    awk -F'\t' -v top="$TOP_PER_TASK" '
      NR == FNR { total[$2]++; next }
      $2 != last { last = $2; c = 0; printf "\n  %s\n", $2 }
      {
        c++
        if (c <= top) printf "    %-24s w %d rundach: %s\n", $3, $1, $4
        if (c == top && total[$2] > top) printf "    ... pominiętych słabszych kandydatów: %d\n", total[$2] - top
      }' "$TMP/hits.tsv" "$TMP/hits.tsv"
    printf '\n'
  fi
  printf '  Odrzuconych jako słownictwo floty (temat w co najmniej %s zadaniach): %s.\n' "$MAX_SPREAD" "${VOCAB:-0}"
  printf '  Odrzuconych jako nazewnictwo (słowo, które same klucze już dzielą): %s.\n' "${TAUTO:-0}"
  printf '  Zwiniętych jako to samo słowo w dłuższej postaci: %s.\n' "${DUP:-0}"
fi
printf '\n'

# Two separate things, kept apart on purpose: a record this run actually failed
# to read, and a limit that holds on every run no matter how clean the data is.
printf '== CZEGO NIE UMIAŁEM ODCZYTAĆ ==\n'
if [ -s "$WARN" ]; then
  sort -u "$WARN" | sed 's/^/  - /'
else
  printf '  Nic - każdy napotkany rekord dał się sparsować.\n'
fi
printf '\n'

printf '== GRANICE TEGO POMIARU ==\n'
if [ "$DB_OK" -eq 1 ] && [ "$DEC_FILES" -gt 0 ]; then
  awk -F'\t' '$1=="TASK"{print $2}' "$TMP/model.tsv" | sort -u > "$TMP/dbtasks.txt"
  awk -F'\t' '{print $1}' "$TMP/decisions.tsv" | sort -u > "$TMP/dectasks.txt"
  ONLY_DEC=$(comm -13 "$TMP/dbtasks.txt" "$TMP/dectasks.txt" | wc -l | tr -d ' ')
  if [ "$ONLY_DEC" -gt 0 ]; then
    printf '  - Zadań z zapisanymi decyzjami, ale bez biegów potoku w bazie: %s.\n' "$ONLY_DEC"
    printf '    Wchodzą do nawrotowości, nie wchodzą do klasyfikacji ani kosztu.\n'
  fi
fi
printf '  - Zakończone zadania tracą dziennik statusu przy sprzątaniu, więc nawrotowość\n'
printf '    dla nich stoi wyłącznie na plikach decyzji, których firstmate nie zawsze pisze.\n'
printf '  - Nawrotowość czyta tylko nazwy złożone: identyfikatory znalezisk, nazwy z kodu,\n'
printf '    slugi. Przyczyna opisana wyłącznie zdaniem, bez ani jednej takiej nazwy,\n'
printf '    NIE zostanie znaleziona. To świadoma granica prototypu, nie awaria.\n'
