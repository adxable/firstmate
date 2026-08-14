---
name: pipeline-retro
description: >-
  Answer "what did the extra pipeline passes cost, and which cause keeps coming back" from this home's own records.
  Use when the captain invokes /pipeline-retro or asks about rework cost, repeated gate findings, or a cause that returned.
user-invocable: true
metadata:
  internal: true
---

# pipeline-retro

Run `bin/fm-retro.sh` in the active home and read its report.
It writes to nothing you own: not the fleet home, not a project, not the no-mistakes database file.
Reading a WAL database does write a read-mark into the `-shm` sidecar beside it and hold a shared lock while the query runs; the database and its `-wal` come out byte-identical, and the read-mark never blocks the daemon.

The report is already Polish and already phrased as outcomes, so relay it as it stands.
Do not restate its numbers in your own words and do not add a number it did not print.

## What it is and is not

A prototype answering exactly one question.
It classifies finished tasks, prices the extra passes as excess over the median clean run, and names causes that appear in more than one decision round of one task.

Two of its sections are evidence, not verdicts.

- Classification and cost are deterministic from the records.
- Recurring causes are a heuristic over decision text: it reads compound names (finding ids, code identifiers, slugs) and misses a cause described only in prose.
  Read the decision keys it prints before treating a candidate as real.

The `NIEWYJAŚNIONE` count is the headline, not a defect count.
It measures how much of the pipeline's own history is no longer readable, which is why a gate name without a reason counts as unexplained: it says where, not why.

## Boundaries

`CZEGO NIE UMIAŁEM ODCZYTAĆ` is part of the answer.
Relay it whenever you relay a number, and never present a figure whose source that section reports as unread.

A recurring cause is a finding, not authorization to change anything.
Route it through ordinary intake, and prefer `diagnostic-reasoning` over stacking another targeted fix on a symptom that already came back.

Growing this tool past its one question is a captain decision, not a follow-on edit.
