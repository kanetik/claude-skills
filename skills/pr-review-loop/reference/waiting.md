# Waiting for reviewer activity (SKILL.md step 3 detail)

## Poll on a timer — no events reach a local terminal to wait on

A local terminal can't *receive* GitHub webhook/event deliveries, so the loop **drives its own wakes by polling**: schedule a self-wake on a fixed cadence and reconcile the PR on each tick. Polling is the mechanism here, not a fallback.

**What each poll must catch.** Reconciling the full PR state every tick covers every transition that ends a wait — including the quiet ones a reviewer never announces: a **clean/approving verdict** (an APPROVE, or a clean verdict in an issue comment), a **"no new comments" review** (e.g. Copilot's), **CI completion — success *and* failure** (`statusCheckRollup` going green or red), **new pushes**, and **merge-conflict transitions** (`mergeStateStatus` → `DIRTY`/`BEHIND`). These are the "reviewer went green, move on" signals; the poll catches every one within one cadence.

**Wake ladder — feature-detect, take the highest available:**

(a) **Self-scheduled wake** — a scheduling primitive (`/loop <cadence>`, `ScheduleWakeup`, `CronCreate`) that re-invokes you at the cadence carrying the continuation payload; reconcile on the tick. Preferred in a local terminal — cheapest and simplest.
(b) **Background polling monitor** — a *background* task that fingerprints the PR's head-commit/review/comment/CI/merge state and emits on change (snippet below). It runs in the background and the agent **ends its turn** — not a foreground `sleep` busy-wait. **Auto-wake is host-dependent:** this rung re-invokes you only where the host turns a background process's output into an agent wake. In a plain terminal that output is just a human-visible notification, not a self-resume — where that's all you get, the change is surfaced to the user and you treat it as rung (c). Use only when rung (a) is unavailable; (a)'s self-scheduled wake is the dependable local mechanism.
(c) **Single-pass hand-back** — do one reconciliation pass, then stop with "re-invoke `/pr-review-loop` to continue." Last resort, only when (a) and (b) are both unavailable.

Never **foreground**-busy-wait with `sleep` for reviewer activity — that blocks the turn instead of yielding. **Re-arm on every wake** (re-schedule / restart) until the PR is merged or closed; do it silently.

End the turn. On every wake, re-pull and reconcile (below), then act. Stay in the **120-240s band (2-4 minutes)**: frequent enough to react promptly, and ≤270s keeps each wake inside the 5-minute prompt-cache window (cheap); >300s incurs a full context replay per wake. The `/loop` idle default of 1200-1800s is far too slow for a review loop — set the cadence explicitly.

### Background fingerprint poll (ladder rung b)

An illustrative starting point — adapt it. Hash the PR state, and wake when the hash changes; run it in the background.

```bash
fp() {
  gh pr view <num> --repo <owner>/<repo> \
    --json headRefOid,reviews,comments,statusCheckRollup,mergeStateStatus \
    --jq '[.headRefOid, (.reviews//[]|sort), (.comments//[]|sort),
           (.statusCheckRollup//[]|sort), .mergeStateStatus]' | sha256sum | cut -d' ' -f1
}
prev="<baseline>"                  # the fingerprint from your last reconciliation
while :; do
  sleep <cadence>
  cur=$(fp); [ "$cur" != "$prev" ] && { echo "pr <num> changed"; prev=$cur; }
done
```

When you adapt it: keep `headRefOid` so pushes register even in a repo with no CI; `sort` each array so result-ordering noise (and either CI shape — CheckRun or legacy commit status) doesn't fake a change; seed `<baseline>` from the fingerprint you took at your last reconciliation (and `sleep` before the first check) so a re-arm doesn't immediately re-emit; add a periodic floor emit if you also want a liveness signal. **Gotcha:** when the git remote is a proxy or other unrecognized host, bare `gh pr view` fails with *"none of the git remotes ... point to a known GitHub host"* — pass `--repo <owner>/<repo>`, and use explicit owner/repo/number on `gh api graphql` (the convention `reference/mechanics.md` already uses).

## Re-entrancy — build for it

Under polling the loop is **re-entered across wakes**, not run as one process. Make each wake idempotent:

1. Re-pull (`git fetch && git pull --ff-only`).
2. Re-derive where you are from the PR (SKILL.md step 1 gathering): unresolved threads, review states + timestamps, bot issue comments, latest push timestamp, tracked-bots set — **read all three surfaces against current HEAD** (SKILL.md "Reading reviewer state") before concluding any bot is still pending.
3. Act (evaluate / request / wait).
4. Re-schedule the poll, then yield.

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

If a bot doesn't respond within ~20 minutes of being triggered (or ~20 min after the push that should have auto-triggered it), surface to the user — don't silently hang. **Before declaring it unresponsive, reconcile all three surfaces against HEAD** — its verdict may have arrived as an issue comment a prior poll didn't catch, in which case it's done. The user decides: skip it this iteration, wait longer, or terminate.

## Optional self-review — push BEFORE triggering, not during the wait

Discretionary: if you spot something bots will surely flag (typo, clear bug, lint-level issue), fix and push it *before* requesting reviewers so they review the cleaner version. Don't push during an active lockstep wait — that means bots review different states. Hold mid-wait findings for the step-5 batch.
