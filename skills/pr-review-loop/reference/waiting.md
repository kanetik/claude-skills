# Waiting for reviewer activity (SKILL.md step 3 detail)

## Poll always; let events short-circuit

The wait is **not** an either/or between polling and events. The invariant: **never depend on an event arriving as your only wake.** An event subscription is an *accelerator* layered on a backstop — **never the sole wait mechanism.** Whenever the chosen mechanism can't itself deliver the terminal/quiet transitions that signal progress, a backstop is **mandatory**; the two run together.

**Why a subscription alone strands the loop — the non-events it misses.** A PR-activity subscription (`subscribe_pr_activity`, webhooks) forwards review *findings* but does **not** wake you for the transitions that actually end a wait: a **clean/approving verdict** (an APPROVE, or a clean verdict in an issue comment), a **"no new comments" review** (e.g. Copilot's), **CI completion — success *and* failure** (`statusCheckRollup` going green or red), **new pushes**, and **merge-conflict transitions** (`mergeStateStatus` → `DIRTY`/`BEHIND`). These are exactly the "reviewer went green, move on" signals — so on the subscription alone the loop stalls the instant a reviewer goes clean, and a human has to say "it's done" to un-stick it. The backstop catches every one within one cadence.

**Backstop ladder — feature-detect, take the highest available:**

(a) **Host scheduling / self-check-in** — a recurring scheduler or self-scheduled message (`/loop <cadence>`, `ScheduleWakeup`, `CronCreate`, `send_later` — often absent in cloud sessions). Wake at `wait_check_cadence_seconds` (default 240s) carrying the continuation payload; reconcile on the tick.
(b) **Background polling monitor** — a *background* task that fingerprints the PR's head-commit/review/comment/CI/merge state and emits on change plus a periodic floor (snippet below), waking you to reconcile. It runs in the background and the agent **ends its turn** — it is not a foreground `sleep` busy-wait. Harness-dependent (background output must actually wake the agent), so feature-detect first; an MCP-only GitHub with no shell `gh` can use a bare heartbeat here and reconcile through its in-agent tools.
(c) **Single-pass hand-back** — do one reconciliation pass, then stop with "re-invoke `/pr-review-loop` to continue." Never **foreground**-busy-wait with `sleep` for external events — that blocks the turn instead of yielding.

When (a) is unavailable, (b) is **required** before ending the turn — fall to (c) only when both are genuinely unavailable. A subscription, when present, layers on top: an event short-circuits the interval so you react sooner, never so you skip the backstop. **Re-arm on every wake** (re-schedule / restart / re-subscribe) until the PR is merged or closed; do it silently.

End the turn. On **any** wake — tick, event, or monitor emission — re-pull and reconcile (below), then act. Stay in the 180-270s band: ≤270s keeps each wake inside the 5-minute prompt-cache window (cheap); >300s incurs a full context replay per wake. The `/loop` idle default of 1200-1800s is too slow for a review loop.

**Events are a wake hint, not ground truth.** Treat every event as "look now," never as the authoritative statement of what changed — and never let the *absence* of an event mean a bot is still pending. The PR state is ground truth; reconcile it on every wake.

### Backstop fingerprint poll (ladder rung b)

Fingerprints the state a webhook won't reliably forward — the head commit (so any push flips the hash, even in a repo with no CI), reviews, comments, CI rollup, merge state. It wakes you on any change, **plus an initial tick and a periodic floor** so a terminal event that landed *before* the baseline was captured (the gap between your last reconciliation and the monitor starting) can't be silently absorbed. Run it in the background.

```bash
fp() {
  gh pr view <num> --repo <owner>/<repo> \
    --json headRefOid,reviews,comments,statusCheckRollup,mergeStateStatus \
    --jq '.headRefOid,
          [(.reviews[]?  | .author.login+":"+.state)]|sort,
          [(.comments[]? | .author.login+"@"+.createdAt)]|sort,
          [((.statusCheckRollup//[])[] | (.name//.context)+":"+(.conclusion//.status//.state//"?"))]|sort,
          .mergeStateStatus' | sha256sum | cut -d' ' -f1
}
prev=""; i=0                                  # empty baseline => the first tick always emits
while :; do
  cur=$(fp)
  # wake on any change, and on a periodic floor (every <floor>th tick) so a terminal
  # event that landed before the baseline was captured still reaches you
  { [ "$cur" != "$prev" ] || [ $((i % <floor>)) -eq 0 ]; } && echo "pr <num>: $cur"
  prev=$cur; i=$((i + 1)); sleep <cadence>
done
```

`statusCheckRollup` and `mergeStateStatus` are in the fingerprint precisely because those are the non-events above; the rollup entry reads **both** check shapes — CheckRuns (`name`/`status`/`conclusion`) and legacy commit statuses (`context`/`state`) — so a pending→success/failure flip changes the hash either way. **Gotcha:** when the git remote is a proxy or other unrecognized host, bare `gh pr view` fails with *"none of the git remotes ... point to a known GitHub host"* — even for the orchestrator repo — so the `--repo <owner>/<repo>` here is mandatory, as is explicit owner/repo/number on the `gh api graphql` thread queries/mutations (the convention `reference/mechanics.md` already uses).

## Re-entrancy — build for it

Under polling and events the loop is **re-entered across wakes**, not run as one process. Make each wake idempotent:

1. Re-pull (`git fetch && git pull --ff-only`).
2. Re-derive where you are from the PR (SKILL.md step 1 gathering): unresolved threads, review states + timestamps, bot issue comments, latest push timestamp, tracked-bots set — **read all three surfaces against current HEAD** (SKILL.md "Reading reviewer state") before concluding any bot is still pending.
3. Act (evaluate / request / wait).
4. Re-schedule the poll (and re-subscribe if event-driven), then yield.

**Resume at step 3, not the top.** A wake re-enters the wait/evaluate cycle — it does NOT re-run the first-run preamble (arg parse, modifier/override detection); that was kickoff work, and redoing it wastes effort and can re-prompt the user. The catch: anything the preamble *decided*, or run-scoped state the PR doesn't record, must instead ride in the **wake payload** (next section). Never hold loop-critical state only in turn-local memory — a wake may be a fresh context.

## Carried state — what the PR can't tell you

Most state re-derives from the PR. Three pieces don't, and must be carried in the wake/continuation payload (in the common single-context run this is just in-memory and always available):

- **Iteration counter** (drives `max_iterations`, SKILL.md step 9). Nothing on the PR records "how many times has this loop run." Carry "iteration N of max M" in the continuation. **Time-based tier:** schedule the wake with a continuation prompt — e.g. `"Resume the PR-review-loop at step 3; iteration N of max M; active modifiers: cap disabled, only copilot; dropped happy: copilot."` Do **not** schedule a bare `/pr-review-loop` re-invocation — that restarts the preamble and loses the count (reserve `/pr-review-loop` for kickoff and for the single-pass manual hand-back).
  - **Fallback when a context-less wake carries no counter:** scan the PR's commits for the `PR-Review-Loop: <N>` trailer (SKILL.md step 6), take the highest `<N>`, and resume at **`<N>+1`** (iteration `<N>`'s commit is already on the PR). The `commits` connection returns full messages, so this is a direct read. It's a *floor* — iterations that committed nothing carry no trailer, so it may under-count, the safe direction for a cap.
- **Dropped-happy set** (SKILL.md step 4). A dropped bot's clean verdict still sits on the PR and the tracked set still counts it, so re-deriving from PR history alone would re-add and re-request it — the resurrection stickiness forbids. Carry the set, e.g. `"...; dropped happy: copilot, codex."` **No carried set? Do NOT infer drops from stale clean verdicts** — a stale-clean bot may simply have gone clean on an earlier commit and still need the new HEAD, which step 4 says to re-request. Re-derive conservatively (re-request the stale-clean bot — one extra review is harmless; silently dropping a bot that may have concerns is not). For full stickiness across context-less wakes, record each drop **durably at drop time** in a marker you own and read back (e.g. a hidden `<!-- pr-review-loop: dropped-happy: … @ <sha> -->` line in the PR body).
- **Effective invocation modifiers** (a disabled cap, an "only copilot" request set). Not PR-derivable; carry them so a context-less wake doesn't silently revert to defaults.

An **external push** (below) empties the dropped-happy set — every tracked bot re-reviews — so both carry forms reset on one.

**Still in Phase 0?** Carry a flag. Absent it, fall back: you're still in the upfront gate (SKILL.md Phase 0) only if `upfront_gate_reviewers` is non-empty, not **all** gate bots are clean at/after HEAD, and the loop proper hasn't begun — judged by the durable signals the gate's own sub-loop can't manufacture (`PR-Review-Loop: N≥1` trailer or human participation), **not** resolved threads / `: 0` commits (the gate sub-loop creates those itself). A mid-flight PR is never re-gated. Otherwise the gate has passed or never applied — resume in the loop.

## Lockstep across the round's requested bots

Wait until every bot **requested for the current commit** has either delivered a verdict (a formal review OR an issue comment, clean or findings) OR been dropped as happy (step 4). The requested set depends on the round: upfront gate = `upfront_gate_reviewers` (each re-review in the gate sub-loop waits on the same set again — the "dropped as happy" escape is a loop mechanism that does **not** apply inside the gate, which isn't satisfied until every gate bot is clean/all-deferred at/after the final gate change); iter 1 = `request_on_pr_open` (first-pass-only bots *are* waited for and batched on the first pass); the loop's own fix push = the re-requested `loop_reviewers` (don't wait on first-pass-only bots then); an external push = the full tracked set; the final sanity check = `final_gate_reviewers`. **Convergence is gauged on `loop_reviewers` only** — a first-pass-only bot's verdict is triaged but never blocks the loop.

**Batch-evaluate the round's combined feedback in one pass** — don't react to bot A, push a fix, then let bot B review the new state. That compounds iterations and misses contradictions (one says X, another ¬X) and overlap you'd catch seeing both side by side.

**Newly appearing bots count.** A bot that posts a review — or a review-style verdict comment (not CI/noise) — during the wait joins the tracked set immediately and is batched into this round's lockstep. But it joins **out-of-loop**: not in `loop_reviewers` unless configured, so step 8 won't re-request it and it doesn't gate convergence; its findings are still triaged in step 5.

## External pushes during the wait

If `git pull` on wake brings in commits the loop didn't author (a teammate or automation), pending reviews are stale against the new HEAD — and this is the one case that **re-engages already-happy bots**. External code is code no reviewer has seen, which no prior clean verdict can cover. Return to step 1 and rebuild the active set as the **full tracked set**: every tracked bot, previously-dropped-happy ones included, re-reviews the new HEAD (step 2's per-bot "has it started on the current commit?" check re-triggers each). An external push is one whose new commits **lack the `PR-Review-Loop` trailer** step 6 stamps — the PR-derivable signal that separates the loop's own commits from everyone else's, so even a context-less wake can tell them apart. (A user manually re-requesting one happy bot is the other, narrower re-engagement path — step 4.)

## Timeout for unresponsive bots

If a bot doesn't respond within ~20 minutes of being triggered (or ~20 min after the push that should have auto-triggered it), surface to the user — don't silently hang. **Before declaring it unresponsive, reconcile all three surfaces against HEAD** — its verdict may have arrived as an issue comment no event surfaced, in which case it's done. The user decides: skip it this iteration, wait longer, or terminate.

## Optional self-review — push BEFORE triggering, not during the wait

Discretionary: if you spot something bots will surely flag (typo, clear bug, lint-level issue), fix and push it *before* requesting reviewers so they review the cleaner version. Don't push during an active lockstep wait — that means bots review different states. Hold mid-wait findings for the step-5 batch.
