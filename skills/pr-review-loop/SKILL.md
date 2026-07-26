---
name: pr-review-loop
description: >-
  Iterative PR review loop: requests AI reviewers (Copilot, Codex, any bot that
  posts a review), waits for their verdicts, evaluates each under a weighted
  project/PR/item judgement, then fixes, pushes back, or files follow-up issues,
  resolves threads, and repeats until every loop reviewer is satisfied. Bookended
  by two deep-review gates that must clear before and after the loop — by default
  the pr-review-skeptic skill, run locally rather than requested on the PR.
  Self-contained and self-paces its polling waits. Auto-invoke immediately and
  WITHOUT asking permission right after a PR is created (gh pr create, a
  commit-push-PR flow, or equivalent), and when the user says "start a PR review", "respond to PR
  comments", "handle PR feedback", says they just opened a PR, or invokes
  /pr-review-loop. Accepts modifiers like "no iteration cap", "only copilot",
  "skip the gates", or a specific PR number / URL / cross-repo reference.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Skill
  - Task
  - Agent
---

# PR Review Loop

Drives AI code reviewers to convergence on a pull request: request → wait → evaluate → fix/answer → push → repeat, until every **loop reviewer** is happy. Two out-of-loop gates bookend it: an **upfront gate** (Phase 0) that vets the approach before the loop and runs to completion (review → fix → re-review until it signs off), and a **final check** (step 10) after convergence, on the code the fix rounds produced. Both default to the sibling **pr-review-skeptic** skill; either can be emptied or pointed at a bot instead. Convergence is gauged on `loop_reviewers` only; other tracked bots are triaged but don't gate the loop.

The three phases in order, **as shipped**: skeptic gate → Copilot loop → skeptic check. Every part of that is config: either gate can be emptied or pointed at a bot, and `loop_reviewers` decides who drives the middle.

This skill is self-contained. The files below live in this skill's own directory, beside this `SKILL.md` — read them from there (paths are relative to this file, not the working directory). Load on demand:

- [`config/defaults.yml`](config/defaults.yml) — config defaults.
- [`reference/configuration.md`](reference/configuration.md) — config keys, override model, invocation modifiers, project procedural overrides.
- [`reference/mechanics.md`](reference/mechanics.md) — tool tiers, the GraphQL/REST queries the loop needs, Copilot/Codex trigger mechanics, and how the skeptic gate is invoked and read.
- [`reference/evaluation.md`](reference/evaluation.md) — the step-5 lens rubric, courses of action, issue creation, reactions, resolve criteria, and gate triage (both gates, bot and skeptic).
- [`reference/waiting.md`](reference/waiting.md) — the step-3 wait: the polling model, re-entrancy, carried state, timeouts.

**Requires:** `gh` (authenticated), `git`. Bash forms also use `jq` (PowerShell forms don't). With the shipped gate config, also the **`pr-review-skeptic` skill**, installed and configured (Preconditions below). Optional: a GitHub MCP server; a scheduling primitive (`/loop`, `ScheduleWakeup`, `CronCreate`) for self-paced polling waits (feature-detected — degrades gracefully).

**Snippet convention:** `<...>` tokens (`<num>`, `<owner>`, `<repo>`, `<path>`, `<tmp>`) are placeholders you substitute with real values, not literal shell tokens.

## Reporting style — terse

Status during iterations and waits is one or two lines: "Iter 3 wait, Copilot still cooking, back in ~4 min." / "Both bots happy, terminating." / "Gate: 6 units reviewed, 2 HIGH, fixing." Don't restate bot text the user can read on the PR. The final summary is short bullets, not paragraphs.

The one thing terseness must not swallow is a **skeptic verdict**, which exists nowhere but in what you say — no thread, no comment, nothing to go read. One line while it runs; the verdict, its blocking findings, and any coverage caveat in the summary.

## Configuration (summary)

Read [`config/defaults.yml`](config/defaults.yml), then merge overrides per key, low → high: bundled defaults < optional `~/.claude/pr-review-loop.config.yml` < orchestrator repo's `.github/pr-review-loop.config.yml`. Defaults: `upfront_gate_reviewers: [skeptic]`, `request_on_pr_open: [copilot]`, `loop_reviewers: [copilot]`, `final_gate_reviewers: [skeptic]`, `auto_review_grace_seconds: 0`, `wait_check_cadence_seconds: 180`, `max_iterations: 10`. Parse natural-language modifiers from the invocation. Full model: `reference/configuration.md`.

**Reviewer roles.** Four reviewer lists: `upfront_gate_reviewers` (gate before the loop — Phase 0), `request_on_pr_open` (requested on the first pass), `loop_reviewers` (re-requested on every push — these *drive convergence*), and `final_gate_reviewers` (run once after convergence). **Only `loop_reviewers` run *inside* the loop**: they alone are re-requested on the loop's own pushes (step 8) and they alone gate convergence (step 4). Everything else is **out-of-loop** — engaged only in its own phase and never dragged through the iterations: `upfront_gate_reviewers` in Phase 0 (before), `final_gate_reviewers` in step 10 (after), and a **first-pass-only** bot (in `request_on_pr_open` but not `loop_reviewers`) once on iteration 1. An out-of-loop reviewer's findings are triaged like any other, but it is never re-requested by step 8 and never gates convergence.

## Two kinds of gate reviewer

A gate list entry is either a **bot** or the **skeptic skill**, and they reach their verdict by different mechanisms. Everything downstream of the verdict — triage, courses of action, the re-review sub-loop — is identical; only how you ask and how you read differ.

| | Bot gate (`codex`, any review bot) | Skeptic gate (`skeptic`) |
|---|---|---|
| How it's engaged | Requested/triggered on the PR (`reference/mechanics.md`) | The sibling `pr-review-skeptic` skill, invoked locally |
| How the verdict arrives | Posted to the PR; read across the three surfaces | Returned to you as a drafted review — verdict, severity-tagged findings, coverage |
| Waiting | Step 3 polling wait | None — it runs synchronously and returns |
| Trace on the PR | Reviews, threads, comments | **None.** An agent-invoked skeptic run posts nothing, by that skill's own rule |
| Tracked set | Joins it (a bot that posted a review) | Never joins — not a GitHub reviewer, never re-requested, never gates convergence |

Two consequences worth stating plainly. First, a skeptic gate's findings exist only in your context, so nothing about them is PR-derivable on a later wake — which is fine, because a local gate is cheap to **re-run**: an unsure wake re-runs it rather than reconstructing it (`reference/waiting.md`). Second, there are no threads to resolve for skeptic findings and no reactions to leave; the fix commit is the whole response.

**Context discipline when invoking skeptic.** You have just read this PR's description, its threads, and possibly written its code — everything the skeptic skill exists to keep away from its reviewers. Invoking it does not launder that: follow its **Context discipline** section exactly, which builds each reviewer's brief by substitution from project config and the diff, and forbids adding a summary of the change, its purpose, or its rationale. Hand it the PR reference and nothing else. A gate steered by your account of what the change does is not an independent gate.

## Tracked set vs active set

- **Tracked set** (permanent, PR-derived): `request_on_pr_open` ∪ every bot that has posted a review *or* a review-style verdict comment (findings or a clean pass, judged on content — not routine CI/noise). A bot joins the moment it does so and never leaves; it's the same on every wake. (Bot authorship via `__typename: Bot`.)
- **Active set** (run-scoped): tracked minus bots already gone happy. These are the bots the loop still tracks for state; *which* of them it re-requests on its own pushes is further narrowed to `loop_reviewers` (the out-of-loop rule, "Reviewer roles" above).

Both sets contain **bots only**; a `skeptic` entry in a gate list is in neither, and none of the tracked/active machinery applies to it.

The loop's own fix push re-requests `active ∩ loop_reviewers` (step 8); out-of-loop bots — the gate bots (`upfront_gate_reviewers`, `final_gate_reviewers`) and first-pass-only bots — and already-happy bots are skipped. Because the active set isn't recorded on the PR as such, a context-less wake reconstructs it from the carried wake payload — see `reference/waiting.md`.

## Reading reviewer state — three surfaces

A reviewer's disposition can surface on any of three channels; always read and union all three — never derive state from reviews alone (a clean verdict sitting in an issue comment, misread as "still reviewing", is the classic failure that strands the loop):

1. **Formal reviews** — `Review` objects and their bodies.
2. **Review threads** — inline and file-level comments.
3. **Bot-authored PR issue comments** — some bots post findings, or their whole clean verdict, only here.

**Judge disposition from what the bot wrote, not a fixed phrase list** — has findings, happy (a clean pass), or work-in-progress, reading the meaning as a person would; the next new bot will word it differently again. **Staleness:** only signals at/after the most recent push count for the current HEAD — a pre-push clean verdict is stale; re-derive against HEAD. Re-derivation applies only to bots **still in the active set**: a bot already dropped happy is not pulled back when a loop fix makes its verdict stale (only an external push or a manual re-request re-engages it — step 4).

## Preconditions

- **Find the target PR(s).** Read the branch: `branch=$(git branch --show-current)`. Non-empty → `gh pr list --head "$branch" --json number,title,url` (quote it). Empty (detached HEAD — CI/automated runs) → match by commit: `gh pr list --search "$(git rev-parse HEAD)" --json number,title,url`. Zero matches and none specified → surface it. Multiple → ask which.
- **Cross-repo PRs** are allowed in any phrasing (URL, sibling name + number, `owner/repo#num`). Resolve to `(owner, repo, number)` and pass `--repo` to every `gh` call for that PR. **At least one PR in the run must be in the orchestrator repo** (the working directory's repo) — else ask the user to add one or confirm.
- **Working tree must be clean** and `gh` authenticated.
- **A configured skeptic gate must be usable** — check before Phase 0, not when you get there, so a run that can't gate says so at the start rather than after the first wait. Two things can be missing (the check itself: `reference/mechanics.md`): the **skill** isn't installed, or **any one of its five project keys** is still empty once its own config layers are merged (all five must hold a value — a layer that fills three of them leaves the gate as unusable as one that fills none). The second matters because an agent-invoked skeptic run does not interview for them — it stops and hands back what's missing, so an unchecked gate turns into a hard stop mid-Phase-0. Either way, **pause and tell the user which it is**, and offer the options that fit: draft `.github/pr-review-skeptic.config.yml` for the PR's repo (the config is read from the base ref, so an uncommitted draft covers this run only from a lasting checkout), point the gate at a bot instead, or run the loop with that gate empty. Don't guess project facts on the user's behalf — five invented answers steer the gate that is supposed to be the independent one. This check is kickoff work: it runs once, not on every wake.

Run `git fetch && git pull --ff-only` before each iteration's analysis. Run multiple PRs concurrently only if your scheduler supports it, each in an isolated working directory (separate `git worktree`/clone) to avoid state collisions.

## Phase 0 — upfront gate

Runs **before** the loop, only when `upfront_gate_reviewers` is non-empty and the PR is **fresh**. Its job: vet the approach once, up front, so the loop doesn't polish a design that's wrong from the start.

**Fresh vs mid-flight.** A brand-new PR an auto-reviewer (Copilot, a Codex auto-review, a ruleset) has already commented on is still **fresh** — run the gate; that initial auto-review never counts as mid-flight (otherwise auto-reviewers would suppress the gate on every PR). Treat the PR as **mid-flight and skip Phase 0** only on real prior iteration: a `PR-Review-Loop: N≥1` trailer, human (non-bot) review/reply participation, resolved review threads, or several iteration pushes. The gate's own `PR-Review-Loop: 0` fixes do **not** count as mid-flight. One case reads as mid-flight but isn't quite: a `/pr-review-skeptic` review the **user** ran themselves posts under their account and so counts as human participation. Skipping the gate there is usually right — they just ran it — but **say that's why you skipped it**, since from the outside a suppressed gate and an absent one look the same.

Otherwise:

1. **Engage the gate reviewer(s)** in `upfront_gate_reviewers` against current HEAD (mechanics: `reference/mechanics.md`), by whichever mechanism each one is:
   - **`skeptic`** → invoke the `pr-review-skeptic` skill on this PR and read what it returns. Nothing is requested on the PR, and nothing is posted. Give it the PR reference and nothing else — **Context discipline** above.
   - **A bot** → request/trigger it; grace window as in step 2, on the iteration-1 baseline `max(PR createdAt, latest push event)`. **Frame the request adversarially whenever the trigger mechanism carries free text** (Codex and other comment/mention-triggered bots) — bake the adversarial brief into the trigger body; don't settle for the bot's default review posture. Ask it to challenge the *approach*: design, correctness, security, data-model/API-contract soundness, wrong-from-the-start choices, not just surface polish. E.g. `@codex review — act as an adversarial reviewer: challenge the approach and design and hunt for correctness/security/data-model flaws or anything wrong from the start, not just style.` A request-only reviewer that takes no prompt (Copilot via `--add-reviewer`) **cannot be steered this way** — its gate run is adversarial only by *our* triage, which is weaker — so prefer `skeptic` or a comment-triggered deep reviewer for this slot.
2. **Wait** (step 3 mechanics; the waited-on set is the **bot** entries of `upfront_gate_reviewers`). A skeptic-only gate skips this step entirely — its verdict is already in hand.
3. **Triage the verdict as one judgement** — for a bot, read it across all three surfaces first; for skeptic, read the review it returned, blocking findings first (`reference/evaluation.md` → "Gate triage"):
   - **Clean, or all findings deferred** (every finding resolved without a code change via `Create-issue-and-close` / `Reject-with-explanation`) → gate satisfied; resolve any threads, fall through to the loop. (Deferred findings need no re-review — nothing new to see.)
   - **Actionable-clear** — you're confident both that there's a real issue *and* what the correct change is; **size is irrelevant** (a one-line rename and a structural redesign are the same outcome). → Apply it (steps 5–8), re-engage the same gate reviewer(s) by their own mechanism, and return to step 2. This is the gate's **re-review sub-loop**: repeat until every configured gate reviewer is clean/all-deferred on what you changed. No cap (it precedes, and doesn't count toward, `max_iterations`). If it stops converging or surfaces a finding you can't confidently resolve, fall to `Ask-user`.
   - **Actionable-unclear** (ambiguous, multiple viable approaches, security/auth/data-model/API-contract judgement, or anything you shouldn't decide unilaterally) → **pause and ask the user**. Don't proceed to the loop until it's resolved; their answer may convert it to a clear fix (which then re-reviews to clean) or a reject.

The gate isn't satisfied — and the loop must not start — until **every** configured gate reviewer's latest verdict is clean or all-deferred **at/after your final gate change**. When a verdict mixes findings, the most conservative present outcome wins: any actionable-unclear finding routes the whole gate to `Ask-user` (you may still apply the unambiguous fixes in the same push).

**A skeptic pass that didn't fully cover the PR is not a clean gate.** Its report says what it could not do — units left unreviewed, a cross-check that didn't run, blocking findings its history pass bucketed `settled`. None of those are findings to triage, and none of them block on their own; they qualify the verdict. Repeat the qualification to the user in the same breath as the gate result ("gate clean over 5 of 6 units; the sync layer went unreviewed"), and let them decide whether to re-run it. A caveat that reaches you and not them is the same as no caveat.

**Gate role after Phase 0.** Stamp Phase-0 fixes with `PR-Review-Loop: 0` (iteration 0 = pre-loop; they don't advance the counter). A gate **bot** is now tracked but, unless also in `loop_reviewers`, out-of-loop: step 8 won't re-request it and it doesn't gate convergence; its Phase-0 verdict was already triaged. A **skeptic** gate leaves nothing behind at all — no tracked-set entry, no threads, no trace on the PR beyond the `: 0` fix commits. Both are re-run after convergence when listed in `final_gate_reviewers` (step 10), which is where the shipped config puts skeptic. (Context-less re-entrancy into Phase 0 is handled in `reference/waiting.md`.)

## The loop

### 1. Initial state check
Gather from the PR (queries in `reference/mechanics.md`): unresolved review threads (paginated; inline + file-level); all reviews with state, body, `submittedAt`, author type; bot-authored issue comments with bodies + timestamps; the most recent push timestamp (latest of `HeadRefPushedEvent`/`HeadRefForcePushedEvent.createdAt` — force-pushes count; NOT `committedDate`); the PR's `createdAt` (iter-1 grace baseline); and `reviewRequests` via GraphQL (NOT `gh pr view --json reviewRequests`, which drops bots).

When `upfront_gate_reviewers` is non-empty **and the PR is fresh**, run **Phase 0** (above) first; it must settle before the loop proper. With no gate configured, or on a mid-flight PR, skip it. Then branch:

- **Any unresolved feedback** — unresolved threads (inline AND file-level), an unaddressed concern in any review body, OR a bot-authored review-style comment raising unaddressed concerns → **jump to step 5**, skipping steps 2–3.
- **Else** → **step 2** (grace window, selectively request bots that haven't auto-triggered) → **step 3** (wait). No push here.

Iterations 2+ run the full sequence: 3 → 4 → (5 → 6 → 7 → 8 if any reviewer has comments) → 3.

### 2. Request reviewers
Humans are never auto-re-pinged. Same flow on iteration 1 and after every push (called from step 8). Mechanics: `reference/mechanics.md`.

1. **Wait `auto_review_grace_seconds`** from the baseline: iter 1 = `max(PR createdAt, latest push event)` (some auto-triggers fire on PR open even when the branch was pushed earlier); iter 2+ = the most recent push event. Default `0` = no wait.
2. **Determine the request set:** iter 1 = `request_on_pr_open`. After one of the loop's **own** fix pushes = `active ∩ loop_reviewers`. An **external** push (new commits lacking a `PR-Review-Loop` trailer — code no reviewer has seen) is the exception: rebuild the active set as the **full tracked set** and re-request every tracked bot, previously-happy ones included (`reference/waiting.md`).
3. **For each bot, skip if it has already engaged the current commit** — started reviewing it or already delivered a verdict for it (evaluate at/after the most recent push across all three surfaces, plus the loop's own trigger). Copilot = a `reviewRequests` entry (presence means already-requested, so skip; `reviewRequests` carries no timestamp — when the loop owns push→request ordering that presence implies at/after the push, otherwise compare the timeline `ReviewRequestedEvent.createdAt` against the latest push). Codex = a `chatgpt-codex-connector` post OR an existing `@codex review` trigger at/after the push. Otherwise request it.
4. Proceed to step 3.

### 3. Wait for new reviewer activity
**Poll on a timer — no events reach a local terminal to wait on.** A local terminal can't *receive* GitHub webhook/event deliveries, so the loop drives itself: schedule a self-wake every `wait_check_cadence_seconds` (default 180s; recommended band 120-240s, i.e. every 2-4 min) and reconcile on each tick. Arm the best self-wake available: (a) a scheduling primitive — `/loop <cadence>`, `ScheduleWakeup`, `CronCreate` — carrying the continuation payload, else (b) a background polling monitor that fingerprints head-commit/reviews/comments/CI/merge state and emits on change — auto-waking you only where the host turns that background output into a re-invocation (in a plain terminal it just notifies a human, so fall through to c), else (c) a single-pass hand-back ("re-invoke `/pr-review-loop` to continue"). Never **foreground**-`sleep` busy-wait — that blocks the turn instead of yielding. Re-arm on every wake until the PR is merged or closed. End the turn. On every wake, re-pull and do a full three-surface reconciliation against HEAD before concluding anything — the PR state is ground truth. Make every wake idempotent — reconstruct loop state from the PR plus the carried payload. Waiting does NOT count toward `max_iterations`. Full model, ladder, polling snippet, the `--repo` gotcha, lockstep, re-entrancy, and carried state: `reference/waiting.md`. This step is a **bot** mechanism throughout: a skeptic gate is never waited on, and a gate with no bot entries skips it.

### 4. Detect "this reviewer is happy"
For each bot **still in the active set** (already-happy bots are done — don't re-evaluate them), all must hold:
- Zero unresolved review threads attributed to it (inline AND file-level).
- Its latest verdict *for the current HEAD* (formal review/body or a bot-authored issue comment) reads as a clean verdict with no unaddressed concerns — judged from what it wrote per "Reading reviewer state."
- That clean signal is at/after the most recent push.

A bot that posts **no formal review** can still be happy on a clean issue comment alone — exactly the case a reviews-only check misses.

**All-rejections short-circuit:** if a reviewer's latest comments ALL resolved to `Reject-with-explanation`, it's done — further iteration won't help. Any `Create-issue-and-close` (a deferred real concern = acceptance) disqualifies that call.

**Happy is terminal and sticky.** Once a bot goes happy it leaves the **active set** for the rest of the run (it stays in the tracked set as history) — not re-requested, not re-evaluated, not asked about again — and this holds across the loop's **own** follow-up commits even as its clean verdict goes stale. Exactly two things re-engage it: (1) the user **manually** bringing it back ("re-run \<bot\>"); or (2) an **external** push — commits the loop didn't author (no `PR-Review-Loop` trailer), code no prior verdict can cover, so every tracked bot re-reviews the new HEAD (`reference/waiting.md`). The loop's own fix commits are neither.

**Loop terminates when all `loop_reviewers` are happy** — out-of-loop bots (the gate bots and first-pass-only bots) are triaged but never gate convergence, so a tracked gate bot still sitting on deferred findings does not hold the loop open. On termination, run the **final check** (step 10) if `final_gate_reviewers` is non-empty, then the Final summary.

### 5. Evaluate each comment
Threads are the unit of evaluation; also read each review's body, and read human replies as evaluation input (not a post-hoc check). Hold the weighted project/PR/item lenses + mindset as one integrated judgement. Courses: `Fix-as-suggested`, `Fix-differently`, `Fix-broader`, `Reject-with-explanation`, `Create-issue-and-close`, `Ask-user`. Default to `Ask-user` for security/auth, scope-creep boundaries, conflicting asks, big architectural feedback. On a **correctness, concurrency or data-handling** finding, write the fix against the invariant rather than the reviewer's scenario, prefer the seam the codebase already has, and confirm the fix didn't weaken a test — the loop's own defects mostly arrive *in* fixes. Full rubric, issue creation, reactions, and resolve criteria: `reference/evaluation.md`.

### 6. Commit changes
One commit per logical group of fixes. Build first if any non-doc code was touched (detect the project's standard verify command) — **never commit red**. Defer commit mechanics to the host (`commit-commands:commit` skill if installed; else plain `git commit`). Keep messages tight. **Stamp each loop commit with a `PR-Review-Loop: <N>` trailer** (`<N>` = current iteration; Phase-0 fixes use `0`; final-check fixes keep the converged `<N>` and add `PR-Review-Loop-Phase: final` — step 10) — a standard `Key: value` git trailer. A context-less wake reads the iteration floor off the highest `<N>`, and the trailer's presence is what tells the loop's own commits from external pushes.

### 7. Update PR description if it has drifted
If this iteration's commits made the description inaccurate, update it — **surgical edits only**, change only affected sections. Use `--body-file` to avoid shell-escaping issues:

```bash
gh pr view <num> --json body --jq '.body // ""' > <tmp>/pr-body-<num>.md  # --jq outputs raw; // "" guards a null body
# edit surgically
gh pr edit <num> --body-file <tmp>/pr-body-<num>.md
```

### 8. Push + re-request reviewers
`git push`, then run the step 2 trigger flow to re-request **every** not-yet-happy loop reviewer (`active ∩ loop_reviewers`) — *all* of them, not just the ones whose feedback you addressed this round. This is mandatory on every **loop** round that changes HEAD — the one push it does not apply to is a final-check fix (step 10), which deliberately does not reopen the loop. A loop reviewer converges only by re-reviewing the new HEAD, so re-requesting the unsatisfied ones is exactly what lets the loop reach "all `loop_reviewers` happy" (step 4) — skip it and the loop strands, waiting forever on a bot that was never asked to look again. It's the in-loop analog of Phase 0's gate re-review sub-loop: fix → push → re-request the unsatisfied reviewers → wait → re-evaluate, repeating until every loop reviewer goes happy.

The step 2 flow waits the grace window, then applies its own per-bot skip check (step 2): a bot is skipped when it has already engaged *this* new commit — an outstanding review request, an in-progress review, or a delivered verdict, all judged **at/after this push**. The point that makes the re-request fire: a verdict (or request) from before the latest push is **stale and does not count** as engagement with the new commit (per "Reading reviewer state") — that bot still needs to see the new HEAD, so request it. First-pass-only bots aren't re-requested here, and already-happy bots stay dropped (sticky — step 4).

### 9. Iteration counter
Increment. If `max_iterations` reached, pause and ask the user (skip the cap if invoked with "no iteration cap"). Return to step 3. The counter is the one piece of loop state with no PR backstop, so it **must ride in the wake payload** (with any active modifiers); a context-less wake with no carried counter derives a floor from the highest `PR-Review-Loop: <N>` trailer and resumes at `<N>+1`. Mechanics: `reference/waiting.md`.

### 10. Final check
Runs once after convergence (all `loop_reviewers` happy) when `final_gate_reviewers` is non-empty. Its subject is what the loop *produced* — a code path that has been through several rounds of fixes and a day's worth of confident replies explaining why each one is right. Engage the configured reviewer(s) against HEAD by their own mechanism (Phase 0 step 1), then:

- **`skeptic`** → invoke it exactly as in Phase 0, and no wait. Its reviewers are blind, so the accumulated justification on the PR doesn't reach them; its history pass then buckets what they found against the loop's own threads, so ground the loop already settled comes back marked `settled` rather than re-litigated, and a defect a fix round patched and left present comes back a severity higher. That is the value of running it here and not just up front.
- **A bot** → request it once and wait (step 3). Where the trigger carries free text, frame it as a confirming check (did the converged result hold together, anything the fix rounds regressed?), *not* the adversarial framing of Phase 0.

Then, either way:
- **Any finding needs a code change** → evaluate (step 5), fix and commit (6–7), push. **The loop does not restart.** Do not run step 8's re-request, do not wait on `loop_reviewers`, do not return to step 3 — convergence already happened, and this push is the final check's own business. Re-run the final check **once** against the new HEAD; clean or all-deferred → summary; still finding → hand back to the user.
- **Clean, or all findings deferred** (`Create-issue-and-close` / `Reject-with-explanation`) → resolve any threads; proceed to the summary.

**Why the loop stays closed.** Re-converging every loop reviewer on a final-check fix is how one late finding turns into another full round of bot iteration, and then another when that round's fixes get checked again — a tail with no natural end, arriving after the work is done. The bounded shape is: one fix, one re-check, then stop. Two things follow, and both are the user's to act on rather than yours:

- **The final-check fix ships without loop-reviewer review.** Say so in the summary, plainly, and name the commit. Weigh that when writing the fix — this is the change with the least review behind it, so prefer the narrow correct one over the ambitious one, and hold anything you can't write confidently as `Ask-user` instead.
- **A loop bot may auto-review the push anyway** (a ruleset auto-request, a bot that watches every push). Its findings are reported in the summary, not looped on. If the user wants another convergence round they'll say so; restarting the loop on an auto-review is the same tail through a side door.

**Stamp final-check commits with both trailers** — `PR-Review-Loop: <N>` (the converged iteration, so the numeric floor still reads) and `PR-Review-Loop-Phase: final`. The second is what makes "the loop is over" survive a context-less wake: without it, a wake that re-derives its position from the trailers alone sees an unconverged-looking HEAD and re-enters the loop, which is exactly the restart this step exists to prevent.

Coverage caveats qualify this verdict the same way they qualify the gate's (Phase 0), and they belong in the final summary, not just in this step.

## Final summary report

When the loop terminates (all `loop_reviewers` happy; final check clean or only-deferred if configured), summarize concisely: which of the three phases actually ran and which were skipped or unavailable, commits made (sha + one-liner each), follow-up issues created with reasons, threads acknowledged-without-fix left open for discussion, any coverage caveat either skeptic pass reported, and anything left for user attention. A skeptic pass leaves no trace on the PR, so if its verdict isn't in this summary the user has no way to learn it ran at all.
