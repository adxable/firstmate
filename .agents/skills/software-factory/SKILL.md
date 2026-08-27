---
name: software-factory
description: >-
  Gated feature workflow (Product, Architecture, Program Design, Vertical Slices) run by firstmate through one scout, Lavish gate reviews, and sliced ship tasks.
  Use when the captain invokes /software-factory or explicitly asks for the gated workflow, or when a feature-sized request has open product or design questions that could change what gets built and the captain accepts the one-question offer at intake.
user-invocable: true
metadata:
  internal: true
---

# Software factory - firstmate edition

Dex Horthy's 4-gate rule, kept intact: every important decision is made **before** implementation code exists, where changing it costs a sentence instead of a rewrite.
The execution model is firstmate's own: firstmate runs the gates and owns every captain contact, a scout produces the gate content, slice workers produce the code, and no worker ever addresses the captain.
This skill adds no new machinery - it composes `fm-brief.sh --scout`, Lavish with the `process-event-sources` Lavish adapter, `captain-hold-lifecycle`, and ordinary sliced ship tasks.

## When to run

- The captain invoked `/software-factory` or asked for the gated workflow in their own words, or
- at intake, a feature-sized request has open product or design questions that could materially change whether or what to build - the same test AGENTS.md section 7 already applies to scouts - and the captain accepted one concise offer: "Feature-sized with open questions - run the gates, or ship directly?"

Never run the gates for work the captain asked to just ship, never in parallel with a likely-enough direct solution, and never as a default for large diffs alone.

## Shape

- **Gates 1-3 and the Gate 4 slice plan are ONE scout task.**
  Deliverables live under `data/<id>/`: `report.md` (running summary and final slice plan), `gates/01-product.md`, `gates/mockups/*.html`, `gates/02-architecture.md`, `gates/03-program-design.md`, `gates/04-slices.md`, and the Lavish artifacts `gates/*.html`.
  The scout's brief must explicitly extend its write permission to `data/<id>/` beyond the report, and must carry the gate templates below in its `{TASK}` section.
- **Gate state is the backlog item note plus decision holds** - there is no separate status file.
  Record each approval as `gateN=approved <date>` in the task note when it lands.
- **Each approved slice becomes one ship task with one PR**, chained with tasks-axi dependencies, under the project's registered delivery mode and yolo posture.
  Trivially small adjacent slices may be batched into one task when the captain approves the batching at Gate 4.
- **The approved gate docs enter the project repo in slice 1's PR** under `docs/plans/<feature-slug>/`, committed by the slice worker as the plan-of-record snapshot.
  Until then `data/<id>/` is the single live copy; firstmate never writes them into the project.

## The approval loop (firstmate-owned, once per gate)

1. The scout writes the gate doc plus its Lavish artifact, appends `needs-decision [key=gate-N]: gate N ready for review`, and waits.
2. Firstmate opens the artifact with `lavish-axi data/<id>/gates/<file>.html`, then loads `process-event-sources` and arms `bin/fm-procevent-lavish.sh arm data/<id>/gates/<file>.html`.
   Never run `lavish-axi poll` in a conversational turn; the armed source wakes firstmate when the captain responds.
3. Artifact requirements per gate - open each matching Lavish playbook before writing HTML:
   - Gate 1: `plan` + `input`; one mockup file per screen, rendered in the product's own design system per `lavish-axi design` priority; no technical vocabulary anywhere on the surface.
   - Gate 2: `diagram` (Mermaid, whiteboard-editable in review) + `plan` + `input`.
   - Gate 3: `code` (types and signatures, no bodies) + `plan` + `input`.
   - Gate 4: `table` or `plan` + `input` over the slice list and build order.

   Every artifact ends with one `input` control set - "Approve Gate N" / "Change: ..." - so the verdict returns as a structured queued answer, not loose prose.
4. On the resulting `check:` wake, route the captured result by the captain's verdict on the gate rather than by how the session ended - a verdict that arrives together with the session ending is a valid verdict, so an approval sent that way is an approval and never feedback to revise:
   - **changes requested** -> translate them into one steer to the scout through `fm-send` (long feedback goes into a file); the scout revises doc and artifact and re-signals.
   - **approved** -> record it durably in the backlog note, `resolved` the gate's key, and steer the scout to the next gate.
   - **open questions instead of a verdict** -> the questions stay as decision holds; re-ask in plain chat at the next natural contact; never reopen the session uninvited.

   A result carrying no verdict at all means re-opening the artifact and re-arming it, or asking the captain in plain chat when the session is gone, never leaving the scout parked on an open decision with nothing armed to wake firstmate.
   `process-event-sources` owns the durable result read, the adapter classification call, source lifecycle, and the handled acknowledgement.
5. An approval counts only once it is in a durable record (backlog note or resolved hold).
   The published Lavish poll destructively clears feedback, so the durable record - never the poll bytes or conversation memory - is the source of truth.
6. Unresolved captain calls follow `captain-hold-lifecycle` as they appear during the gates, not in a sweep at the end.
7. **Backtracking:** if later work shows an approved gate wrong, hold the affected slice tasks, revise the gate doc through the current worker's report or a follow-up scout, and re-run this loop for that gate before continuing.

## Gate content templates (carried into the scout's brief)

- **Gate 1 - Product.**
  The problem in the end-user's words; one success metric tied to a real number; the 3-6 sentence announcement ("the blog post before the feature" - if it cannot be written, the wrong thing is being built); the screens list.
  Technical vocabulary is banned at this gate; anything technical moves to Gate 2.
- **Gate 2 - Architecture.**
  Fit with existing modules; endpoints; data and the queries that will hit it; the end-to-end flow of the main path; external dependencies with env var names, never values.
  Before designing, the scout runs the recon step: exercise the touched surfaces and state the verdict - works / works differently / absent - never design against an imagined or merely-read codebase.
- **Gate 3 - Program design.**
  Every file created or changed, one line on why it lives there; types and method signatures with no implementation bodies; the call stack per main flow; the test plan as named cases with what each asserts; the least-confident decisions, numbered, while changing them is free.
- **Gate 4 - Slices.**
  One line per slice in build order.
  Slice 1 is the tracer bullet: wired end to end, mocked or hardcoded where needed, and visibly runs.
  Slice 2 replaces the mocks with the real happy path.
  Each later slice adds one capability - a business rule, error handling, an edge case, polish - and ends in a working, testable state.
  Horizontal building (all schema, then all services, then all UI) is banned.

## After the gates

- Once the report and holds pass the shared completion gate, settle slice 1 while the scout task is still alive: if it already spiked working code, promote it into slice 1 through `bin/fm-promote.sh`, otherwise tear it down and dispatch a fresh slice 1.
  Dispatch the remaining slice tasks after that; each brief carries the absolute home path to `data/<id>/gates/`, the slices run in the home that owns the scout's data directory, and slice 1's brief requires committing `docs/plans/<feature-slug>/` in its PR.
- Each slice ships through the project's selected delivery path, and the gates add no extra reviewer and no per-slice manual gate on top of it; AGENTS.md section 7 owns that rule.
  The PR, its checks, and the standing merge authority are the gate, and the per-slice "prove it works" is the captain's visual proof: a screenshot or short clip plus two or three sentences.
- "Continue or re-steer?" is the natural intake of the next queued slice: an unchanged plan continues silently under the standing authority; a captain correction rewrites the remaining slice tasks - they are only backlog items, so re-steering stays cheap by design.
- A gate decision that outlives the feature is recorded through the project's existing decision-record convention (for example its ADR directory) inside the same slice PR, never as a deferred follow-up task.
