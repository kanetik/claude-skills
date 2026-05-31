# Waiting for reviewer activity (SKILL.md step 3 detail)

The wait is the one step whose best mechanism is environment-specific. Pick the highest available tier from the **capability ladder** in `reference/tool-tiers.md`, then apply the lockstep and timeout rules below regardless of tier.

## Capability ladder (recap)

1. **Event-driven (preferred).** Subscribe to the PR's activity, **end the turn**, get re-woken by review/CI/comment events. No polling. Cloud default where available (e.g. `subscribe_pr_activity` on GitHub-integrated web). Feature-detect — don't assume it exists.
2. **Time-based scheduling.** `/loop <cadence>`, `ScheduleWakeup`, or `CronCreate` at `wait_check_cadence_seconds` (default 240s). Stay in the 180-270s band: ≤270s stays inside the 5-minute prompt-cache window (cheap per wake); >300s incurs a full context replay each wake. The /loop dynamic-mode default of 1200-1800s is for genuinely idle waits, NOT for PR review loops.
3. **Single pass + hand-back (floor).** No event subscription and no scheduling primitive → do one review pass, then stop with "re-invoke `/pr-review` to continue." Never busy-wait with `sleep` for external events.

## Re-entrancy — build for it

Under the event-driven and time-based tiers the loop is **re-entered across wakeups**, not run as one continuous process. Make each wake idempotent:

1. Re-pull (`git fetch && git pull --ff-only`).
2. Re-derive where you are from the PR — apply the iteration-1 branching: unresolved threads, review states + timestamps, most recent push timestamp, tracked-bots set. Loop state lives in the PR, not in turn-local memory.
3. Act (evaluate / request / wait).
4. Re-subscribe (event-driven) or re-schedule (time-based), then yield.

**Resume at step 3, not the top.** A wake re-enters the wait/evaluate cycle (SKILL.md step 3 onward) — it does NOT re-run the first-run preamble (arg parse, modifier/override detection). That kickoff work happened on the initial `/pr-review` invocation; redoing it on every wake is wasted and can re-prompt the user. The catch: anything the preamble *decided* that can't be re-derived from the PR must instead be **carried in the wake payload** — both the iteration counter (below) and the effective invocation modifiers (a disabled cap from "no iteration cap", an "only copilot" request set). Otherwise a context-less wake silently reverts them — re-enabling the cap, re-widening the request set. Iteration-1 branching is still the correct routine for *deriving state* from the PR; the point is that kickoff-only decisions are carried explicitly rather than reset or re-derived from scratch.

Never hold loop-critical state only in turn-local memory — a wakeup may be a fresh context.

### Carrying the iteration counter — and recording it on the PR

Of the carried state above, the **iteration counter** that drives `max_iterations` (SKILL.md step 9) is the one the PR doesn't record on its own — nothing tracks "how many times has this loop run" unless the loop writes it down. Today it survives only because wakes happen to share one persistent context (a persistent web session under the event-driven tier; the same conversation under `/loop`/`ScheduleWakeup`). A truly context-less wake — a detached `CronCreate`, a hand-off that drops the conversation, a compacted/fresh context — would reset it to 0 every wake, so `max_iterations` would never fire and the loop would run unbounded. Handle it two ways:

- **Primary — carry the counter (and modifiers) in the wake/continuation payload.** When yielding to wait, embed iteration N of max M plus any active invocation modifiers in whatever re-wakes you:
  - **Event-driven tier:** include them in the re-subscription/continuation context as a one-line resume instruction, e.g. `"Resume the PR-review loop at step 3; iteration N of max M; active modifiers: cap disabled, only copilot."`
  - **Time-based tier:** schedule the wake with a **continuation prompt** stating iteration N of max M, any active modifiers, and "resume at step 3." Do **NOT** *schedule* a bare re-invocation of `/pr-review` as the continuation — a fresh invocation restarts the preamble and loses the count. (This applies to automated continuations only; the single-pass tier's manual "re-invoke `/pr-review`" hand-back is fine — there's no carried counter for it to clobber, and the floor below re-derives one.)
- **Fallback — read the floor off the loop's commits.** If a wake arrives with no carried counter (context-less), scan the PR's commits for the `PR-Review-Loop: <N>` trailer SKILL.md step 6 stamps, and take the highest `<N>` as the floor. That's the iteration the loop's last commit was made in — use it so the cap still engages instead of resetting to 0. The PR's `commits` connection returns the full message, so this is a direct read: no push-event correlation, no actor guessing, no `HeadRefPushedEvent` window limits. It's a **floor** — later iterations that committed nothing (e.g. one that only posted `Reject-with-explanation` replies) carry no trailer, so it may under-count, which is the safe direction for a cap.

## Lockstep across all tracked bots

Wait until every tracked bot (`request_on_pr_open` ∪ any bot that has posted a review on this PR) has either posted a review for the current commit OR been dropped as "happy" (step 4). **Batch-evaluate the combined feedback in one pass** — don't react to one bot's comments, push a fix, then let another bot review the new state. That compounds iteration count: bot B re-reviews your fresh diff and raises tangential comments that would've been weighed differently with both takes side by side. Seeing all tracked bots together also surfaces contradictions (one says X, another ¬X) and overlap (both flag the same issue) before you decide.

**Newly appearing bots count.** If a bot posts a review during the wait that wasn't previously tracked (e.g. an auto-triggering bot whose review lands after the grace window), add it to the tracked set immediately; lockstep then waits for it too.

## Timeout for unresponsive bots

If a bot doesn't respond within ~20 minutes of being triggered (or, for auto-triggering bots in the request set, ~20 min after the push that should have triggered them), surface to the user — don't silently hang. The user decides: skip the bot for this iteration, wait longer, or terminate. (A bot service may be down, the trigger may have silently failed, or the bot may have hit a daily quota.)

## External pushes during the wait

If `git pull` on wake introduces new commits (e.g. a teammate pushed), pending bot reviews are stale against the new HEAD. Return to step 1 — step 2's per-bot "started reviewing the current commit" check re-triggers any tracked bot whose pending review predates the new HEAD.

## Optional self-review — push BEFORE triggering bots, not during the wait

Discretionary: if you spot something bots will surely flag (typo, clear bug, lint-level issue), fix and push it *before* requesting reviewers so they review the cleaner version. Don't push during an active lockstep wait — that means bots review different states. Hold any mid-wait findings for the batch evaluation in step 5.

## Cost note

Waiting does NOT count toward `max_iterations`. Re-pull each time you wake.
