---
name: night-shift
description: >-
  Run a bounded overnight gnhf loop on at most three already-decided backlog items, ending in local branches and a morning review, never a push or merge.
  Use when the captain invokes /night-shift or asks for night mode or to run work overnight; the invocation is that night's explicit order and is never carried to another night.
user-invocable: true
metadata:
  internal: true
---

# Night shift

The captain invokes `/night-shift` each evening, and that invocation is the only order for that one night.
A night ends with local `gnhf/...` branches and a morning report; nothing leaves the machine overnight.
In the morning firstmate sends the branches whose verdict is merge through each project's ordinary delivery path under that project's standing merge authority.
This skill adds no machinery: it composes backlog reads, `quota-axi`, one ordinary scout per owning home, `bin/fm-procevent-quota.sh`, `/afk`, and ordinary ship tasks.

## Refuse the night

Say which condition failed and start nothing when any of these holds:

- The Claude quota cannot be read.
  Reading it needs the captain's one-time Keychain approval (`quota-axi --allow-keychain-prompt`, "Always Allow"); that is the captain's credential step, so name it and never run it yourself.
- Less than 40 percent of the weekly Claude window remains.
- The tightest Claude window is already at or below the night's stop threshold (weekly remaining at start minus 10 percentage points).
  The budget source below watches the tightest window, so it would fire at once; name the binding window and its reset time.
- No item passes the selection filter.

## Evening: select

Read every home's backlog with full notes, this home and each registered secondmate home, read-only through `tasks-axi` (`--file` for another home's backlog).
Never select from `tasks-axi ready`: it counts items whose notes still wait on a decision or sign-off.
An item goes on the night only when it passes all six:

- **K1** The decision is made: the note leaves nothing for the captain or anyone else to decide.
- **K2** Nothing is waiting: no hold, live blocker, or sign-off, including a change to a test already on the default branch.
- **K3** Closed, small scope with a named remedy that fits six iterations and is not systemic.
- **K4** Verification is mechanical in the copy (tests, typecheck, lint, grep), with no pilot machine, shared channel, or shared port.
- **K5** Outside sensitive areas: security, authentication, secrets, customer data, deployment and infrastructure, deleting customer material, and firstmate itself.
- **K6** The result is a code change, not knowledge.

## Evening: plan

Read `quota-axi --provider claude` and propose one plan in plain chat:

- At most three items, in run order, each with its owning home, goal, expected file area, verification commands, limits (6 iterations, 30,000,000 tokens), and a stop condition derived from its note.
  Make the stop condition structural and checkable in the copy, never "the agent says it is done".
- The night budget: weekly remaining now, the stop threshold, and the morning time the night ends by.

Nothing starts until the captain says yes or strikes items.

## Evening: hand off to the owning home

The owning home is the home whose backlog holds the items; route by marked request (`bin/fm-send.sh` header, `secondmate-provisioning`) when it is a secondmate, and act directly when it is this home.
One host per home, so a plan spanning homes launches one host in each.
The owning home, in order:

1. Files one host item, `night-<YYYY-MM-DD>`, citing the captain's evening yes; the spawn gate needs a backlog item for the host's own id.
2. Adds one line to each night item's note, `Night YYYY-MM-DD: limits 6 iterations / 30M tokens, stop condition <condition>`, and blocks the item on the host item with `tasks-axi block`, because an away session may dispatch queued unblocked work and must not start a second worker on a night item.
   No other file layout under `data/`.
3. Scaffolds a scout brief (`bin/fm-brief.sh <host-id> <repo> --scout`), fills it from the template below, and spawns it with `bin/fm-spawn.sh <host-id> <project-dir> --scout --harness claude`; the design fixes Claude, so that harness is the per-task override ahead of any dispatch profile.
4. Arms the budget backstop: `bin/fm-procevent-quota.sh arm --provider claude --threshold <stop threshold>` (load `process-event-sources`).

The captain then enters `/afk`, and the night runs under ordinary supervision.

## Host brief template

`## Captain's intent`: the captain's evening yes in their own words, plus the approved plan's substance (items, goals, stop conditions, limits, morning time).

`## Firstmate spec`, filled per night:

````markdown
You are the night host.
You run the approved items one after another in this copy with gnhf, review each result yourself, and write one morning report.
This copy is not scratch for the night: gnhf's `gnhf/...` branches are the product, so keep every one of them, detached.
Outside this copy, besides the report and status file, you may write only under `<home>/data/<host-id>/` (call it NIGHT_DIR).

Setup, once:

1. Version gate: run `"$g" --version` for every distinct entry of `which -a gnhf`.
   Any entry below 0.1.49 or unreadable: append `blocked:` naming it and stop; the night does not start.
2. Hook shim.
   gnhf's `claude -p` runs in this copy and would fire this worker's own busy and turn-end hooks on every iteration, which supervision reads as the host stopping.
   Create `NIGHT_DIR/bin/claude`, a shell script that runs `exec '<absolute path of command -v claude>' --setting-sources user,project "$@"`, make it executable, and put NIGHT_DIR/bin first on gnhf's PATH only.
3. Record BASE=`git rev-parse HEAD` and the quota before (`quota-axi --provider claude`: weekly and 5-hour remaining).
   An unreadable quota means the night does not start: append `blocked:` and stop.
4. Append once: `paused [at=<epoch>]: night loop, <n> items, until <morning YYYY-MM-DDTHH:MMZ>`.

Per item, in plan order:

1. `git status --porcelain` must be empty; otherwise end the night and report it, never clean or discard.
   Then `git checkout --detach "$BASE"`.
2. Write the item's prompt to `NIGHT_DIR/items/<item>/prompt.md`: the goal from its note, the stop condition, the prohibitions below, and "stop and report, without editing it, when the goal would need a change to a test that already exists on the default branch".
3. Run gnhf as a background command and wait for its completion notification; never poll it, never run it in the foreground:

   ```sh
   PATH="$NIGHT_DIR/bin:$PATH" GNHF_TELEMETRY=0 \
   GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl \
   GIT_CONFIG_VALUE_0=/nonexistent/night-shift-forbids-push \
   "$(command -v gnhf)" --agent claude --model sonnet \
     --max-iterations 6 --max-tokens 30000000 --max-rate-limit-wait 0 \
     --stop-when "<stop condition>" --prevent-sleep on --meteor-frequency 0 \
     "$(cat "$NIGHT_DIR/items/<item>/prompt.md")" \
     < /dev/null > "$NIGHT_DIR/items/<item>/gnhf-output.log" 2>&1
   ```

   Never add `--push`, `--current-branch`, `--worktree`, or `--fallback-model`.
   gnhf adds `.gnhf/runs/` to the repository's shared `info/exclude` on its first run there; that one ignore line is expected.
4. Review the branch yourself (RUN is the newest `.gnhf/runs/*/`):
   - branch `git branch --show-current`; if HEAD is still detached at BASE, gnhf made no branch, so record that and skip to step 6;
   - commits `git rev-list --count "$BASE..HEAD"`, files and lines `git diff --stat "$BASE..HEAD"`;
   - scope: `git diff --name-only "$BASE..HEAD"` against the expected area, and `git diff --name-only --diff-filter=MDR "$BASE..HEAD"` for files that existed on the base, where any test means a test already on the default branch was touched;
   - run the item's verification commands yourself and check the stop condition yourself; gnhf's "stop condition met" is only the agent's claim.
5. Copy `RUN/end-state.json`, `RUN/notes.md`, and the `run:complete` line of `RUN/gnhf.log` (token totals with cache breakdown) into `NIGHT_DIR/items/<item>/`, because `.gnhf/runs/` is ignored and disappears with this copy.
   Record the head SHA, then `git checkout --detach` so cleanup cannot delete the branch.
6. Decide whether the night continues:
   - a usage-limit stop, from `end-state.json` or the output log, ends the night at once;
   - a persistent agent error (login, credit) is `blocked:` naming the credential needed, and ends the night;
   - read the quota again; when it is unreadable, the weekly remaining is at or below the stop threshold, or any window is exhausted, end the night;
   - otherwise start the next item.

Never, whatever the away words say: push or open a PR, merge or land, deploy or ssh, change a test already on the default branch, touch data, records, or secrets, delete customer material, use shared channels or ports, kill other processes, change gnhf, Claude, or global configuration, create backlog items, answer decisions, clean up or tear down, use `--force`, or touch anything in firstmate.
Nothing destructive, irreversible, or security-touching in any form.
If firstmate interrupts you because the night budget ran out, stop your own running gnhf, review what is committed, and close the night.

Close the night: write the morning report to the scout report path, append `done [at=<epoch>]: night <date>: <n> run, verdicts <...>`, and stay alive; firstmate cleans up after the morning decision.

Morning report, per item:
- item, home, branch, base, head SHA, commit count, files and lines;
- stop reason from `end-state.json` (`stopCondition`, not `status`), iterations succeeded and failed, tokens with cache breakdown;
- the independent verification commands and results, and whether the stop condition truly holds;
- scope: files outside the expected area, touched tests already on the default branch;
- verdict merge / another round / do not merge, with one sentence why;
- next step: send through the pipeline, one bounded fix round naming the gap, or deleting the branch (the last only on the captain's word, because it is unlanded work).

For the whole night: quota before and after (weekly and 5-hour), total tokens, elapsed time, items run and items skipped with the reason.
````

## During the night

A turn-end notification may surface when the host starts each background wait; its current state reads as the declared pause, so acknowledge it and keep supervising.
On the quota source's wake, interrupt the host with `bin/fm-control.sh <host-id> interrupt`, then steer it through `bin/fm-send.sh` to stop its running gnhf and close the night.
A crashed host is resumed or relaunched through `stuck-crewmate-recovery`, never torn down.

## Morning

Main does step 1; the owning home does the rest, on main's marked request when it is a secondmate.

1. Relay the night report in the away-return report: per item the verdict with its one sentence, the branch, and the next step, plus the night's quota before and after.
2. Retire the budget source if it never fired (`bin/fm-procevent-quota.sh retire --provider claude`) and `tasks-axi unblock` each night item from the host item.
3. Each merge-verdict item ships as an ordinary ship task under its own item id, through the project's registered delivery mode and yolo posture; its brief names the `gnhf/...` branch and head SHA as the change to carry onto the ship branch.
   The host is not promoted: its own id is the host item, so a promoted host would land a night item's change under the wrong backlog item.
4. Another round and do not merge wait for the captain's word in the morning report; deleting a night branch needs that word.
5. Clean up the host through ordinary teardown only after the morning decision.
   Teardown deletes only the branch a copy has checked out, so detached night branches survive it (`bin/fm-teardown.sh`); recheck that after every upstream sync.
