# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts`, omp's `.omp/extensions/fm-primary-omp-watch.ts`, and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`: `session_shutdown` changes the current generation's durable extension marker from `active` to `handoff` but keeps its established arm child alive, then the owning `session_start` publishes a distinct active generation and commits its tracked replacement arm before that arm retires the predecessor.
A state-scoped replacement handoff carries every actionable close whose delivery overlapped `session_shutdown`, including a main follow-up Pi accepted but had not yet consumed, branch handling, and a retiring child that reports after the successor claim.
A handoff marker never satisfies the extension-ownership tolerance, so a running Pi process whose replacement did not load this extension is reported as missing rather than borrowing stale load evidence from its predecessor.
A main follow-up counts as delivered once Pi accepts it, never once the model reads it, because a follow-up queued while main is streaming joins the running run without a `before_agent_start`; the extension header owns how consumption is observed and why it only decides what a replacement replays.
omp's replacement follows its own generation-owner contract in `.omp/extensions/fm-primary-omp-watch.ts`, whose header owns its differences from Pi: it retires the predecessor arm at replacement shutdown instead of retaining it across the handoff, and it reports no shutdown reason, so every shutdown with a pending actionable close persists the handoff for the next owning `session_start` to replay.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its Pi-host stand-down, loop bounds, and supersession baton.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner the session does not own, an absent lock, or a malformed lock keeps the competing hook inert.
Whether the session owns that lock is the shared `fm_session_lock_owned_by_self` verdict in `bin/fm-session-lock-lib.sh`, which accepts a recorded pid inside the current harness ancestry or a live lock recorded under this same trusted Claude session id, so a background session keeps arming after its transient helper chain is recycled.
[`turnend-guard.md`](turnend-guard.md#guard-predicates) owns the Claude guard's behavior when that live owner is genuinely another session.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher commits one last-resort notice for the continuous failure episode; a refused notice commit stays silent for a later retry, and after a successful notice later Stop cycles exit 2 without repeating it until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns that notice commit contract, the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.
A home opted into the supervision host runs `bin/fm-supervision-host.sh` in that arm's place; it owns successive watcher cycles through the same arm, starts and confirms each successor before its engine handles an away wake, and stops its cycle before handing a wake back, so the recovery and acknowledgement contracts below apply unchanged ([supervision-host.md](supervision-host.md)).

## Last-resort arm at the Stop boundary

Every arming path under a Claude primary is triggered by a Stop event, and the only unattended source of a Stop event is the rewake an arming path produces.
A Stop that ends with no watcher therefore ends the chain: nothing fires again until a human sends a message.
Three shapes reach that state, and all three were reproduced against the real scripts in an isolated home on 2026-09-14.
The claim micro-mutex is held by a live process that is not a claimant, so the hook stands down silently on every firing and never writes a ledger entry at all.
The current claim reads open while its owner is hung, so both Stop participants defer to a promise nothing is keeping.
The hook's exit-2 rewake is never delivered, which upstream issue 4209 reports independently and which leaves the same durable state a healthy running turn leaves.

`bin/fm-turnend-guard.sh --claude` therefore owns a last-resort arm, implemented by `bin/fm-guard-last-resort-arm.sh`.
It runs only after the guard has already concluded that nothing owns recovery for this Stop event, so it never competes with the Stop-owned auto-arm and is a backstop rather than a second arming owner.
It launches this home's own `bin/fm-watch.sh`, detached in its own process group so tearing down the synchronous hook cannot take the replacement with it, and confirms it against the same `fm_watcher_healthy` honesty gate the arm layer uses, inside the arm layer's own `FM_ARM_CONFIRM_TIMEOUT` window over the same OSTYPE default `bin/fm-watch-arm.sh` reads.
The arm itself is never budget-limited; only the follow-up block is, so an exhausted block budget now ends the turn with a watcher running instead of ending it blind.
That confirmation runs synchronously inside Claude's Stop hook, so it is bounded by the `timeout` that hook entry declares in `.claude/settings.json` (180 seconds), and a `FM_ARM_CONFIRM_TIMEOUT` raised near or past that ceiling is cut off by the harness rather than honoured.
Being cut off there is not the same failure as no arm at all: the watcher is launched detached in its own process group before the confirmation wait, so the home stays watched, and what is lost is the guard's exit-2 continuation - the turn ends without handing the cycle back to the Stop-owned auto-arm.
The only process it ever signals is the child it forked, so it can never reach a sibling home's watcher.

The boundary matters as much as the arm.
Between turns under the auto-arm model a home is legitimately unwatched while the model runs, and an aging beacon mid-turn is the healthy state, indistinguishable in durable state from the undelivered-rewake wedge.
At a Stop a turn is by definition ending, so "supervision is needed and no watcher exists" is unambiguous there and nowhere else.
Nothing in this path runs mid-turn, and an aging beacon is never treated as a fault on its own.

An `arming` claim is a promise that a watcher is on its way, and the stuck proof bounds how long that promise is credited while nothing is beating.
That bound is the arm layer's own confirmation window through `fm_autoarm_arming_stuck`, not the watcher beacon grace: `bin/fm-watch-arm.sh` confirms or fails a watcher inside `FM_ARM_CONFIRM_TIMEOUT`, and the hook makes at most `FM_CLAUDE_AUTOARM_ATTEMPTS` attempts, so a beaconless claim older than those attempts can honestly take - `FM_CLAUDE_AUTOARM_ATTEMPTS` times the confirm-plus-successor phases, with a 60s floor - is hung rather than slow.
The budget is clamped to the grace, so the proof is strictly more willing to declare a claim stuck than the grace-only form it replaces and never less.
A claim declared stuck too eagerly costs at most one extra arm the watcher singleton dedupes; the reverse mistake costs the home its supervision.

This fork carries the guard's arm while upstream PR 4208 is unmerged; that PR pairs the same guard arm with keying lock-holder liveness on process start time, which cures the wedged claim mutex itself rather than its symptom.
Reading the shared `FM_ARM_CONFIRM_TIMEOUT` here is deliberate, and adopting upstream's own `FM_CLAUDE_GUARD_ARM_CONFIRM` spelling if that PR lands is a rename rather than an oversight.
Until it lands, a mutex wedged by a recycled pid keeps the home watched through this arm but leaves the automatic rewake unowned, and the watcher's wake waits in the durable queue for the next turn.

Two residuals are named rather than claimed closed, because both require a Stop event that never arrives.
A claim taken seconds before a hung arm is still inside its arming budget, so that Stop allows correctly and only the next one recovers; when no next Stop comes, the home stays unwatched.
An exit-2 rewake that the harness never delivers produces no turn at all, so no later Stop boundary exists for the guard to act at; upstream issue 4209 owns delivering a wake to an idle home, and this change does not address it.
Every shape where Stop events keep arriving is covered, which is every attended session and every home with a live lane.
Neither residual is repaired by the silence sentry below, but both stop being invisible: the sentry reports the resulting unwatched home within its deadline instead of leaving it indefinitely silent.

## Silence with no Stop boundary

Every arming and recovery path above is triggered by a Stop event.
A session that runs out of quota mid-turn never completes that turn, so it emits no Stop at all: the auto-arm ledger does not advance, the turn-end guard's block record is never created, and the last-resort arm never runs, because all three act AT a boundary this shape does not have.
Observed 2026-09-14 on a Claude primary: a watcher closed cleanly at 10:30:21 (exit 0, reason actionable-stale), the woken session hit its session limit, and the home stayed unwatched for 71 minutes while one worker's validation failed unobserved and a second sat stopped mid-gate.
Nothing inside the home noticed; the supervision layer one level up did, from outside.

`bin/fm-silence-sentry.sh` closes the noticing half only.
It is a detached process armed by the watcher's own close, so it needs neither a turn to end nor the model to be alive, and it starts nothing: no watcher, no agent, no retry, no resumed work.
That boundary is deliberate rather than a simplification, because a home whose quota is still exhausted would resurrect itself into a loop nobody asked for, and the last-resort arm above remains the only backstop that arms anything.

The signal is the durable wake record, and specifically its end rather than its beginning.
A watcher appends every actionable wake to `state/.wake-queue` before it exits, and the row stays queued until the handling turn acknowledges it after handling it.
A row gone from the queue therefore means a turn finished with it, and a row that outlives the deadline means none ever did.
The claim the drain writes at the start of handling is deliberately not the signal: it is written before the turn does any work, so retiring on it would leave the whole remainder of the turn unwatched, which is exactly where quota is consumed and exactly the shape of the incident above.
Two signals that look plausible were measured and rejected: elapsed unwatched time alone says nothing, because under the autoarm model no watcher is the healthy mid-turn state, and harness CPU time cannot carry the verdict either, because on 2026-09-14 all twelve live Claude Code processes on one machine burned between 0.74% and 4.79% of a core continuously whether they were running a turn or parked at a prompt.

The sentry reports only when supervision is still needed here, no live identity-matched watcher holds this home's lock with a fresh beacon, the wake it was armed over is still queued and unacknowledged, and away mode is inactive, for the whole deadline.
Each healthy shape trips a different one of those: an idle home fails the need test and never arms a sentry at all, a watcher parked on a long external wait is alive and beating, and a turn that handles the wake acknowledges it when it is done.
A turn that merely ENDS also retires the sentry, because the Stop-owned auto-arm brings a watcher back.
The deadline therefore only has to outlast a single turn that runs past it without ever finishing the wake it was handed; it defaults to 45 minutes, is settable per home in `config/silence-deadline` (seconds, `FM_SILENCE_ALARM_SECS` overrides it), and is floored at the watcher grace, so it is never more eager than the staleness bound the rest of the stack already applies.

That default is a judgement, and its two bounds are recorded so the next reader moves it on evidence rather than instinct.
Below it the detector lies: on 2026-09-15 this home ran stretches of roughly nineteen minutes with nothing beating while work was genuinely in progress, and an alarm that cried wolf every four minutes for an hour that night is exactly how a domain learns to ignore that task's alarms.
Above it detection costs real time: at 45 minutes the 2026-09-14 failure would have reported at 11:15, against the 11:42 a human actually noticed it.
A home whose turns are reliably shorter is entitled to lower it and get the earlier detection.

A third residual follows from that number, and it is a false report rather than a missed one.
A turn that genuinely runs longer than the deadline without acknowledging its wake is reported as silence: the captain gets the `SILENT HOME` banner, the durable `state/.silence-alarm`, and a queued `check` wake, all naming quota exhaustion or a dead session, about a session that is alive and working.
The cost is the detector's credibility, which is why the number is set where a turn rarely reaches it and why a home that lowers it accepts that trade knowingly.
Nothing is restarted or lost in that case - the report is report-only - and the next turn that acknowledges the wake retires the marker.

A fourth residual is that report's mirror, and it is a missed report rather than a false one.
The sentry retires the moment its wake is acknowledged, so a home whose turn acknowledged receipt of the notification, kept working, and died before the turn ended will not be reported at all: no watcher, no Stop, no queued row, and nothing arms a sentry except a watcher close.
The shape observed on 2026-09-14 is not that one - the limit fell at 10:29, before the 10:30:21 close and before any turn had acknowledged anything, so it sits inside the window this change covers - and the variant is bounded to a single turn, because the next turn that ends arms a watcher again.
The answer to it is a turn-liveness signal, which is waiting as separate work.

Three independent review passes over this change arrived at that same retirement rule and were answered the same way each time, and the finding is about the rule rather than the reviews, which were right about its coherence every time: a signal derived from the wake queue can decide that a turn finished with a wake, never that the session behind it is still alive, so the remedy is the liveness signal rather than a further addition here.

The close path pays nothing for it.
`watcher_cleanup` runs inside the watcher process, and callers bound that process from outside: `bin/fm-watch-checkpoint.sh` wraps the whole watcher in `timeout <n>`, and a kill at that bound discards the wake line the watcher had already written.
The sentry is therefore launched detached, in its own process group, and deliberately not waited for, so the gating, the fork of the watch loop, and its confirmation are all charged to the sentry's own process instead of to a budget Codex's bounded foreground checkpoint also spends.

A sentry must never outlive what it watches.
One is armed at every watcher close, so a survivor is not a stray process but one stray process per close, accumulating for as long as the home runs and each holding a stale generation.
The loop therefore terminates explicitly, before evaluating anything, when the home itself is gone or when the record names another process, rather than letting either fall out of the conditions above by accident.
The arm gate is that rule from the other side - one sentry per home and per wake - so a lingering sentry still holding a wake some turn has since finished is superseded rather than deferred to, because deferring to it would leave the wake this close just queued with nobody watching it at all.

The report is durable, read, and out of band.
`state/.silence-alarm` records the evidence, and the report itself is published as a `check` wake on this home's own durable queue, which is presented at session start and at every drain and stays queued until a turn acknowledges it.
That acknowledgement is what retires the marker, on the next watcher cycle or the sentry's own healthy exit: the first cycle after supervision returns is precisely when the captain would look, so a report he has not read yet is never erased underneath him.
Publishing a queue row starts nothing, so the report-only boundary holds.
A standing report is also the one queued row no sentry is ever armed over: it waits on the captain rather than on a turn, so a home that already holds an unread one gets no second report naming the first as the thing nobody handled.
The active alert reuses this home's configured [`wedge-alarm.md`](wedge-alarm.md) channels through that owner's one-shot `--alarm` entry, because they are the only channels in this repository that reach a person outside the terminal pane without the model's participation, and it passes its own banner title so a notification never names a condition that did not produce it.
Home scoping is absolute: every path derives from this home's own `FM_HOME`, and the sentry signals no process at all, so it cannot reach a sibling home sharing the machine.

Upstream issue 4209 reports the adjacent undelivered-rewake failure, whose durable aftermath is identical to this one, and proposes delivering the wake and never leaving the home unwatched.
This change does neither: it adds the third thing, noticing, and leaves both of 4209's halves open.

## Actionable wake ordering

After an actionable Pi, omp, or OpenCode child close, the adapter waits for the predecessor process to close, then starts and verifies one singleton successor before it delivers the original wake.
A complete Pi reason line observed while the predecessor is still finishing durable cleanup is retained for replacement handoff but never treats that already-ready predecessor as its own successor.
It confirms the handling handoff against that successor before scheduling the follow-up, retries once against the current generation and successor, and treats a failed confirmation as a restoration failure: it classifies the error, retires a successor that is no longer alive, and surfaces exactly one typed message.
A failed confirmation is never swallowed.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook also starts one handling successor before notification: after an actionable foreground close, including an attached peer cycle that ended, it launches `bin/fm-watch-arm.sh` with the closed arm's pid as `FM_WATCH_PREDECESSOR_ARM_PID`, waits for that arm's one status line, and only then exits 2 with the wake.
A child of the hook cannot outlive its exit-2 rewake, so that successor is the one deliberate detached launch in the continuity path: nohup, stdio away from the hook's pipes, and its own process group, the shape `bin/fm-startup-network.sh` uses and [`verification/supervision.md`](verification/supervision.md#detached-session-open-workers-survive-the-hook) verified survives the hook.
The next Stop's foreground arm attaches to that live cycle; a successor that confirms no live watcher adds one line to the rewake banner and never withholds the wake, leaving the next Stop to re-arm as before.
The durable wake queue preserves actionable events between a watcher close and the next drain, and the bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding, so a finished, hung, or identity-mismatched claim cannot suppress it ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).
The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce; it enters its poll loop immediately and keeps scanning signals, stale panes, and checks.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with a fire-and-forget shell `&` from a model command; the Claude hook's detached handling successor is launched by the hook itself, which waits for the successor's status line before it exits.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
An unacknowledged downtime generation is announced at most once: the first recovery marks that generation announced, and later arms wait until a new down stretch mints a new generation.
A non-successor watcher start after an announced-but-unacked episode is a new down stretch and mints a fresh generation so buried decisions still resurface once.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one, and an already-announced generation stays announced.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence (further scoped per actor - see "Per-actor acknowledgement" below), while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Per-actor acknowledgement

`bin/fm-wake-drain.sh` consumes the queue per actor, not per whole-queue cutoff, using the `fm_lease_actor` identity owned by `bin/fm-lease-lib.sh`; the Pi branch extension injects its branch actor into its own bash tool calls.
Every presented row is claimed to exactly one actor under the durable queue lock.
An ordinary presentation drain bounds both its initial queue-lock acquire and its later status-presentation-lock acquire at the deadline owned by the script header.
A live initial queue-lock holder produces one PID-naming advisory and skips the whole drain before any claim or mutation, while a live status-presentation-lock holder produces one such advisory after raw wake presentation and leaves status annotations, sections, and cursors retriable on the next drain.
Acknowledgement invocations and every other mutation-critical queue-lock acquire retain blocking semantics, so acknowledgement atomicity is unchanged.
Main records its presented set in `state/.main-eligible-rows`.
A branch grant is published through `bin/fm-wake-grant.sh` under that same lock in `state/.branch-eligible-rows`, bound to the live branch process and extension generation recorded in `state/.branch-eligible-owner`, and publication is refused if main already claimed any requested row.
A main drain validates that owner evidence under the queue lock and reclaims the grant when its process is gone or its identity no longer matches.
A main drain claims every currently unclaimed row and excludes an active branch grant from both presentation and acknowledgement.
Because that exclusion makes those rows invisible to main, `bin/fm-guard.sh`'s queued-wake warning counts only the rows the calling actor can itself present or retire, so an actor is never sent to a drain that provably has nothing for it.
`bin/fm-wake-lib.sh` owns that per-actor count (`fm_wake_actor_pending_count`) alongside the grant row-list and owner-record reads that the drain and `bin/fm-wake-grant.sh` share.
A row a live grant reserves is therefore never counted as drainable for main; rather than going silent about a visibly non-empty queue, the guard prints a distinct advisory naming the live supervision branch as the holder and saying not to drain those rows from here.
The branch actor's queued-wake output stays suppressed in every case.
A main drain with nothing of its own left, and a live grant still holding the queue, says so in one bounded line instead of exiting silently.
A row that lost the five appended fields or its numeric sequence can never be claimed, presented, or named by an `--ack-through` cutoff, so a main drain retires it under the queue lock and reports how many it removed together with those rows verbatim, bounded to the first 20 and a count of the rest, because the queue was their only durable record; a branch drain never does, because a grant can only name sequences that were structurally valid when it was published.
A retirement that cannot be read or written is reported and never fails the drain: the rows that remain usable are still presented with their acknowledgement command, the unusable ones stay queued for a later drain to retire, and failing the whole drain would strand the usable rows too.
Its `--ack-through <SEQ>` deletes only claimed main rows at or below the cutoff, while a branch acknowledgement deletes only claimed branch rows at or below its cutoff.
A main acknowledgement first claims every unreserved row at or below its cutoff, so none is stranded, and leaves a row above the cutoff that arrived after presentation unowned, so an away-session grant can still take it rather than handing every later wake back to main.
Every settled branch prompt releases any residual grant, so an omitted or failed acknowledgement leaves the durable row available to a later main drain; a successful acknowledgement has already removed it.
An acknowledgement whose cutoff removes none of the actor's rows while a presented row above the cutoff still waits is reported as having acknowledged nothing, together with the exact `--ack-through` and `--recovery-generation` command for that presented row; the presented set is read before any re-claim, so a row that arrived after presentation is never named for unseen acknowledgement.
If a branch offer loses the claim race to main, it rejects its settlement so the watcher retains the actionable close until Pi accepts its main follow-up.
[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.
A check-kind row is main-owned in every mode, including a heartbeat review, so it is never part of a branch claim and never defers one; main is woken for it on that check's own triggering close.
`fm-wake-drain.sh` never reclassifies a row itself: it filters the queue to the current actor's opaque claim before same-key deduplication, then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
Because branch claims contain no check-kind rows, a branch acknowledgement skips check-specific receipt scans.
`tests/fm-wake-queue.test.sh`'s mixed-queue actor, stale-acknowledgement remedy, and presentation-deadline tests drive the real scripts: branch acknowledgement cannot swallow a main row, a concurrent main turn cannot present or acknowledge an active branch grant, a no-op stale acknowledgement names the current presented wake's exact command, live-holder presentation contention stays bounded and retriable, and acknowledgement locking remains blocking.
The same suite pins the counted-equals-presentable invariant against `bin/fm-guard.sh` and `bin/fm-wake-drain.sh` together: a branch-held row raises the held advisory rather than the ordinary queued-wake warning for main, and is presented with its acknowledgement command - with the ordinary warning restored - as soon as the grant clears, and structurally unusable rows are retired by main alone while every remaining row stays presentable and acknowledgeable.
`tests/fm-pi-branch-extension.test.sh` pins extension-side classification, claim publication and release, and the pre-drain recheck.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.
The watcher uses bash's native fatal handling for HUP and TERM, including during a blocked poll, so both run its EXIT cleanup; `watcher_stop_signals` in `bin/fm-watch.sh` owns the signal-handling rationale.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, `/fork`, and reload, same-instance shutdown-plus-start, the predecessor remaining live under a handoff generation until its replacement commits, bounded retry after that replacement kills the predecessor but fails before readiness, automatic re-arm before any model turn, a fresh extension-module rebind carrying all in-flight actionable closes exactly once, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
The guard and session-start suites prove that active generation evidence tolerates a fresh-beacon handoff while a legacy or handoff-phase watcher marker from an absent replacement extension still raises the outage diagnostic.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, a re-arm whose recovery cycle is slowed after confirmation and must still surface rather than read as a watcher that stayed live, and the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
`tests/fm-watch-recovery-loop.test.sh` covers the once-per-generation announcement bound with the real Pi extension against a refused handling handshake, and a handling successor that must surface a real crew event instead of going blind.
`tests/fm-watch-triage.test.sh` proves TERM stops a watcher blocked inside a poll's pane capture and still releases its lock and records an acknowledgeable stop.
It also checks that a newly appended keyed decision is classified without rereading earlier status bytes, so signal handling can return to the watcher's beacon refresh even when the status history is long.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, exit-2 translation, the handling successor an ended attached cycle starts with the closed arm as its predecessor and that outlives the rewake, an unconfirmed successor reported in the banner without withholding the wake, and host-timeout HUP/TERM/INT translation into the same durable failure handoff.
It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim; [`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, receives session start through the tracked SessionStart hook, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset; [`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.
The same suite covers the last-resort arm with the real `bin/fm-watch.sh` as a real process: it brings a watcher up when nothing owns recovery, it keeps a home watched whose claim mutex is permanently wedged, and it stays out of both healthy shapes - a live identity-matched watcher, and a claim that is genuinely still arming - asserting in each that no watcher was started.
`tests/fm-claude-stop-autoarm.test.sh` drives the arming budget and the beacon apart and asserts the verdict survives losing either signal, with the grace held at its default so a regression to grace-only crediting fails all three assertions together.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-guard-last-resort-arm-live-e2e.test.sh` proves the two harness-dependent facts no fixture can: that Claude runs the guard synchronously and delivers its exit-2 banner, and that a watcher the guard spawns inside that hook outlives Claude tearing the hook down.
`tests/fm-silence-sentry.test.sh` drives the real watcher, the real drain and its real post-handling acknowledgement to pin the sentry's verdict: it reports a home whose queued wake no turn took at all, it reports the incident's own shape where a turn claimed the wake at its opening drain and then died without finishing it, and it starts nothing in either; it stays silent on an idle home, under away mode, beside a live parked watcher, once a handling turn acknowledges the wake, and before its deadline elapses, with the deadline floored at the watcher grace.
It also pins the report's reader: the real drain presents it to the next turn, and the marker stands through a later watcher cycle until a turn consumes it.
The same suite pins the termination contract, which is what keeps one sentry per watcher close from accumulating: a sentry exits when the home it watches is deleted, and a superseded one stands down without retiring the current sentry's record.
It pins the arm gate beside it: a second close over the same wake starts no second sentry, while a close carrying a fresher wake supersedes a sentry still holding a finished one, and a home whose only queued row is a standing silence report arms nothing.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-silence-sentry-live-e2e.test.sh` proves the one harness-dependent fact there: a sentry forked from a watcher a real Claude primary's auto-arm brought up survives Claude tearing that process tree down, without which the mechanism would be inert exactly when it is needed.
It then reaps that sentry by name and asserts it is gone, because retiring a watcher arms a fresh one over the record, so a reaper that only follows the record would leave the process it just asserted on running.

## Active limits and verification

The goal is continuity without a Pi, omp, or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake for the automatic cycle, with the last-resort arm above as a supervision-only backstop that keeps a home watched without reclaiming the rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.
The silence sentry adds no continuity of its own and is not a fallback for any of those: where a Stop event never arrives it reports the resulting unwatched home and nothing more, so a home that has gone silent still needs a person or the layer above to act on the report.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current cross-harness live evidence, the dated Stop-owned Claude auto-arm results, and exact opt-in commands.
