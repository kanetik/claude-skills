---
name: pr-review-loop
description: >-
  Iterative PR review loop: requests AI reviewers (Copilot, Codex, any bot that
  posts a review), waits for their verdicts, evaluates each under a weighted
  project/PR/item judgement, then fixes, pushes back, or files follow-up issues,
  resolves threads, and repeats until every loop reviewer is satisfied. Optional
  adversarial gate before the loop and a sanity-check pass after. Self-contained
  and auto-detects the best wait mechanism. Auto-invoke immediately and WITHOUT
  asking right after a PR is created (gh pr create, a commit-push-PR flow, or
  equivalent), and when the user says "start a PR review", "respond to PR
  comments", "handle PR feedback", says they just opened a PR, or invokes
  /pr-review-loop. Accepts modifiers like "no iteration cap", "only copilot", or
  a specific PR number / URL / cross-repo reference.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
---

# PR Review Loop

Drives AI code reviewers to convergence on a pull request: request → wait → evaluate → fix/answer → push → repeat, until every **loop reviewer** is happy. Two optional out-of-loop gates can bookend it: an **upfront adversarial gate** (Phase 0) that vets the approach before the loop and runs to completion (review → fix → re-review until it signs off), and a lighter **final sanity check** (step 10) after convergence. Convergence is gauged on `loop_reviewers` only; other tracked bots are triaged but don't gate the loop.

This skill is self-contained. The files below live in this skill's own directory, beside this `SKILL.md` — read them from there (paths are relative to this file, not the working directory). Load on demand:

- [`config/defaults.yml`](config/defaults.yml) — config defaults.
- [`reference/configuration.md`](reference/configuration.md) — config keys, override model, invocation modifiers, project procedural overrides.
- [`reference/mechanics.md`](reference/mechanics.md) — tool tiers, the GraphQL/REST queries the loop needs, and Copilot/Codex trigger mechanics.
- [`reference/evaluation.md`](reference/evaluation.md) — the step-5 lens rubric, courses of action, issue creation, reactions, resolve criteria, and Phase-0 triage.
- [`reference/waiting.md`](reference/waiting.md) — the step-3 wait: the poll-plus-events model, re-entrancy, carried state, timeouts.

**Requires:** `gh` (authenticated), `git`. Bash forms also use `jq` (PowerShell forms don't). Optional: a github MCP server; a scheduling and/or event-subscription primitive for waits (feature-detected — degrades gracefully).

**Snippet convention:** `<...>` tokens (`<num>`, `<owner>`, `<repo>`, `<path>`, `<tmp>`) are placeholders you substitute with real values, not literal shell tokens.

## Reporting style — terse

Status during iterations and waits is one or two lines: "Iter 3 wait, Codex still cooking, back in ~4 min." / "Both bots happy, terminating." Don't restate bot text the user can read on the PR. The final summary is short bullets, not paragraphs.

## Configuration (summary)

Read [`config/defaults.yml`](config/defaults.yml), then merge overrides per key, low → high: bundled defaults < optional `~/.claude/pr-review.config.yml` < orchestrator repo's `.github/pr-review.config.yml`. Defaults: `upfront_gate_reviewers: []`, `request_on_pr_open: [copilot]`, `loop_reviewers: [copilot]`, `final_gate_reviewers: []`, `auto_review_grace_seconds: 0`, `wait_check_cadence_seconds: 240`, `max_iterations: 10`. Parse natural-language modifiers from the invocation. Full model: `reference/configuration.md`.

**Reviewer roles.** Four bot lists: `upfront_gate_reviewers` (gate before the loop — Phase 0), `request_on_pr_open` (requested on the first pass), `loop_reviewers` (re-requested on every push — these *drive convergence*), and `final_gate_reviewers` (requested once after convergence). **Only `loop_reviewers` run *inside* the loop**: they alone are re-requested on the loop's own pushes (step 8) and they alone gate convergence (step 4). Every other tracked bot is **out-of-loop** — requested only in its own phase and never dragged through the iterations: `upfront_gate_reviewers` in Phase 0 (before), `final_gate_reviewers` in step 10 (after), and a **first-pass-only** bot (in `request_on_pr_open` but not `loop_reviewers`) once on iteration 1. An out-of-loop bot's findings are triaged like any other, but it is never re-requested by step 8 and never gates convergence. The recommended pattern for a rate-limited deep reviewer (Codex) puts it on the two gates while Copilot drives the loop — see `config/defaults.yml`.

## Tracked set vs active set

- **Tracked set** (permanent, PR-derived): `request_on_pr_open` ∪ every bot that has posted a review *or* a review-style verdict comment (findings or a clean pass, judged on content — not routine CI/noise). A bot joins the moment it does so and never leaves; it's the same on every wake. (Bot authorship via `__typename: Bot`.)
- **Active set** (run-scoped): tracked minus bots already gone happy. These are the bots the loop still tracks for state; *which* of them it re-requests on its own pushes is further narrowed to `loop_reviewers` (the out-of-loop rule, "Reviewer roles" above).

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

Run `git fetch && git pull --ff-only` before each iteration's analysis. Run multiple PRs concurrently only if your scheduler supports it, each in an isolated working directory (separate `git worktree`/clone) to avoid state collisions.

## Phase 0 — upfront adversarial gate

Runs **before** the loop, only when `upfront_gate_reviewers` is non-empty and the PR is **fresh**. Its job: vet the approach once, up front, so the loop doesn't polish a design that's wrong from the start.

**Fresh vs mid-flight.** A brand-new PR an auto-reviewer (Copilot, a Codex auto-review, a ruleset) has already commented on is still **fresh** — run the gate; that initial auto-review never counts as mid-flight (otherwise auto-reviewers would suppress the gate on every PR). Treat the PR as **mid-flight and skip Phase 0** only on real prior iteration: a `PR-Review-Loop: N≥1` trailer, human (non-bot) review/reply participation, resolved review threads, or several iteration pushes. The gate's own `PR-Review-Loop: 0` fixes do **not** count as mid-flight.

Otherwise:

1. **Request the gate bot(s)** in `upfront_gate_reviewers` against current HEAD (mechanics: `reference/mechanics.md`); grace window as in step 2, on the iteration-1 baseline `max(PR createdAt, latest push event)`. **Always frame the gate request adversarially whenever the trigger mechanism carries free text** (Codex and other comment/mention-triggered bots) — bake the adversarial brief into the trigger body itself; don't settle for the bot's default review posture. Ask it to challenge the *approach*: design, correctness, security, data-model/API-contract soundness, wrong-from-the-start choices, not just surface polish. E.g. `@codex review — act as an adversarial reviewer: challenge the approach and design and hunt for correctness/security/data-model flaws or anything wrong from the start, not just style.` A request-only reviewer that takes no prompt (Copilot via `--add-reviewer`) **cannot be steered this way** — its gate run is adversarial only by *our* triage, which is weaker — so whenever a comment-triggered deep reviewer is available, prefer it for the gate (the recommended Codex pattern).
2. **Wait** (step 3 mechanics; the requested set for this wait is `upfront_gate_reviewers`).
3. **Read the verdict across all three surfaces and triage it as one judgement** (`reference/evaluation.md` → "Upfront gate triage"):
   - **Clean, or all findings deferred** (every finding resolved without a code change via `Create-issue-and-close` / `Reject-with-explanation`) → gate satisfied; resolve any threads, fall through to the loop. (Deferred findings need no re-review — nothing new for the bot to see.)
   - **Actionable-clear** — you're confident both that there's a real issue *and* what the correct change is; **size is irrelevant** (a one-line rename and a structural redesign are the same outcome). → Apply it (steps 5–8), re-request the same gate bot(s), and return to step 2. This is the gate's **re-review sub-loop**: repeat until every configured gate bot is clean/all-deferred on what you changed. No cap (it precedes, and doesn't count toward, `max_iterations`). If it stops converging or surfaces a finding you can't confidently resolve, fall to `Ask-user`.
   - **Actionable-unclear** (ambiguous, multiple viable approaches, security/auth/data-model/API-contract judgement, or anything you shouldn't decide unilaterally) → **pause and ask the user**. Don't proceed to the loop until it's resolved; their answer may convert it to a clear fix (which then re-reviews to clean) or a reject.

The gate isn't satisfied — and the loop must not start — until **every** configured gate bot's latest verdict is clean or all-deferred **at/after your final gate change**. When a verdict mixes findings, the most conservative present outcome wins: any actionable-unclear finding routes the whole gate to `Ask-user` (you may still apply the unambiguous fixes in the same push).

**Gate-bot role after Phase 0.** Stamp Phase-0 fixes with `PR-Review-Loop: 0` (iteration 0 = pre-loop; they don't advance the counter). The gate bot is now tracked but, unless also in `loop_reviewers`, out-of-loop: step 8 won't re-request it and it doesn't gate convergence; its Phase-0 verdict was already triaged. Put the same bot in `final_gate_reviewers` if you also want it to vet what the fix rounds introduce. (Context-less re-entrancy into Phase 0 is handled in `reference/waiting.md`.)

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
**Poll always; let events short-circuit.** A PR-activity subscription is an accelerator, never the sole wait mechanism — webhooks don't wake you for the transitions that end a wait (clean/approving verdicts, CI completion, new pushes, merge-conflict flips), so a backstop runs alongside it and is **mandatory**. Arm the best available: (a) host scheduling / self-check-in at `wait_check_cadence_seconds`, else (b) a background polling monitor that emits on any change to reviews/comments/CI/merge state, else (c) a single-pass hand-back — and when (a) is absent, (b) is required: never end a wait with no backstop armed, and re-arm it on each wake until the PR is merged or closed. End the turn. On **any** wake — tick, event, or monitor emission — re-pull and do a full three-surface reconciliation against HEAD before concluding anything; events are a hint to look, never ground truth, and an event's *absence* never means a bot is still pending. Make every wake idempotent — reconstruct loop state from the PR plus the carried payload. Waiting does NOT count toward `max_iterations`. Full model, ladder, polling snippet, the `--repo` gotcha, lockstep, re-entrancy, and carried state: `reference/waiting.md`.

### 4. Detect "this reviewer is happy"
For each bot **still in the active set** (already-happy bots are done — don't re-evaluate them), all must hold:
- Zero unresolved review threads attributed to it (inline AND file-level).
- Its latest verdict *for the current HEAD* (formal review/body or a bot-authored issue comment) reads as a clean verdict with no unaddressed concerns — judged from what it wrote per "Reading reviewer state."
- That clean signal is at/after the most recent push.

A bot that posts **no formal review** can still be happy on a clean issue comment alone — exactly the case a reviews-only check misses.

**All-rejections short-circuit:** if a reviewer's latest comments ALL resolved to `Reject-with-explanation`, it's done — further iteration won't help. Any `Create-issue-and-close` (a deferred real concern = acceptance) disqualifies that call.

**Happy is terminal and sticky.** Once a bot goes happy it leaves the **active set** for the rest of the run (it stays in the tracked set as history) — not re-requested, not re-evaluated, not asked about again — and this holds across the loop's **own** follow-up commits even as its clean verdict goes stale. Exactly two things re-engage it: (1) the user **manually** bringing it back ("re-run \<bot\>"); or (2) an **external** push — commits the loop didn't author (no `PR-Review-Loop` trailer), code no prior verdict can cover, so every tracked bot re-reviews the new HEAD (`reference/waiting.md`). The loop's own fix commits are neither.

**Loop terminates when all `loop_reviewers` are happy** — out-of-loop bots (the gate bots and first-pass-only bots) are triaged but never gate convergence, so a tracked gate bot still sitting on deferred findings does not hold the loop open. On termination, run the **final sanity check** (step 10) if `final_gate_reviewers` is non-empty, then the Final summary.

### 5. Evaluate each comment
Threads are the unit of evaluation; also read each review's body, and read human replies as evaluation input (not a post-hoc check). Hold the weighted project/PR/item lenses + mindset as one integrated judgement. Courses: `Fix-as-suggested`, `Fix-differently`, `Fix-broader`, `Reject-with-explanation`, `Create-issue-and-close`, `Ask-user`. Default to `Ask-user` for security/auth, scope-creep boundaries, conflicting asks, big architectural feedback. Full rubric, issue creation, reactions, and resolve criteria: `reference/evaluation.md`.

### 6. Commit changes
One commit per logical group of fixes. Build first if any non-doc code was touched (detect the project's standard verify command) — **never commit red**. Defer commit mechanics to the host (`commit-commands:commit` skill if installed; else plain `git commit`). Keep messages tight. **Stamp each loop commit with a `PR-Review-Loop: <N>` trailer** (`<N>` = current iteration; Phase-0 fixes use `0`) — a standard `Key: value` git trailer. A context-less wake reads the iteration floor off the highest `<N>`, and the trailer's presence is what tells the loop's own commits from external pushes.

### 7. Update PR description if it has drifted
If this iteration's commits made the description inaccurate, update it — **surgical edits only**, change only affected sections. Use `--body-file` to avoid shell-escaping issues:

```bash
gh pr view <num> --json body --jq '.body // ""' > <tmp>/pr-body-<num>.md  # --jq outputs raw; // "" guards a null body
# edit surgically
gh pr edit <num> --body-file <tmp>/pr-body-<num>.md
```

### 8. Push + re-request reviewers
`git push`, then run the step 2 trigger flow against the **not-yet-happy** `loop_reviewers` (waits the grace window, skips bots already reviewing the new commit, requests the rest). First-pass-only bots aren't re-requested here.

### 9. Iteration counter
Increment. If `max_iterations` reached, pause and ask the user (skip the cap if invoked with "no iteration cap"). Return to step 3. The counter is the one piece of loop state with no PR backstop, so it **must ride in the wake payload** (with any active modifiers); a context-less wake with no carried counter derives a floor from the highest `PR-Review-Loop: <N>` trailer and resumes at `<N>+1`. Mechanics: `reference/waiting.md`.

### 10. Final sanity check
Runs only after convergence (all `loop_reviewers` happy) when `final_gate_reviewers` is non-empty — a last confirming look, not an adversarial dig (that's the upfront gate's job). Request the configured bot(s) once against HEAD and wait (step 3) — where the trigger carries free text, frame it as a light confirming check (did the converged result hold together, anything the fix rounds regressed?), *not* the adversarial framing of Phase 0 — then:
- **Any finding needs a code change** → evaluate (step 5), fix/commit/push (6–8). That push re-engages `loop_reviewers`; re-converge, then re-run the check **once**. Still failing after that → hand back to the user.
- **Clean, or all findings deferred** (`Create-issue-and-close` / `Reject-with-explanation`) → resolve the threads, no re-converge; proceed to the summary.

## Final summary report

When the loop terminates (all `loop_reviewers` happy; final sanity check clean or only-deferred if configured), summarize concisely: commits made (sha + one-liner each), follow-up issues created with reasons, threads acknowledged-without-fix left open for discussion, anything left for user attention.
