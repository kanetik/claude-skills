---
name: pr-review-loop
description: >-
  Runs an iterative PR review loop on a repo's open PR(s): optionally opens with an
  upfront adversarial-gate review (triaged minor / major-unclear / major-clear) that
  must settle before the loop, then requests AI reviewers (Copilot, Codex, and any
  bot that posts a review), waits for their reviews, evaluates each review thread under
  a weighted project/PR/item judgement, then fixes, pushes back, or files follow-up
  issues, resolves threads, and repeats until the loop reviewers are satisfied (with
  an optional final sanity-check pass by a configured bot). Self-contained — bundles its config
  defaults and reference material and reads project overrides from the consuming
  repo. Detects the best available wait mechanism (event-driven subscription,
  scheduled polling, or single-pass) and degrades gracefully. Auto-invoke this
  skill immediately and WITHOUT asking right after a PR is created — via gh pr
  create, a commit-push-PR flow, or any equivalent — and when the user says
  "start a PR review", "respond to PR comments", "handle PR feedback", says they
  just opened a PR, or invokes /pr-review-loop.
when_to_use: >-
  Use when the user says "start a PR review", "respond to PR comments", "handle
  PR feedback", invokes /pr-review-loop, or says they just created/opened a PR. ALSO
  invoke immediately and automatically right after you yourself create a PR (via
  gh pr create, a commit-push-pr skill, or equivalent) — do NOT ask permission,
  just start with config defaults and auto-detect the PR. Accepts natural-language
  modifiers like "no iteration cap", "only copilot", or a specific PR
  number / URL / cross-repo reference.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
---

# PR Review Loop

An iterative loop that drives AI code reviewers (Copilot, Codex, any bot that posts) to convergence on a pull request: request → wait → evaluate → fix/answer → push → repeat, until every **loop reviewer** is happy. It can be bookended by two optional out-of-loop gates: an **adversarial upfront gate** (Phase 0) that vets the approach *before* the loop starts, and a lighter **final sanity check** (step 10) by a configured bot after convergence. "Convergence" is gauged on `loop_reviewers`; out-of-loop reviewers are triaged but don't gate the loop — see "Reviewer roles" below.

This skill is self-contained. All the files below live **inside this skill's own directory**, alongside this `SKILL.md` — read them from there (paths are relative to this file, not to the current working directory). Config defaults live in [`config/defaults.yml`](config/defaults.yml); the heavy mechanics live in `reference/` and are loaded on demand:

- [`reference/configuration.md`](reference/configuration.md) — config keys, the layered override model, invocation modifiers, project procedural overrides.
- [`reference/tool-tiers.md`](reference/tool-tiers.md) — per-operation tool tiers and the wait capability ladder.
- [`reference/graphql.md`](reference/graphql.md) — paginated `reviewThreads` query and the other GraphQL/REST the loop needs (bash + PowerShell).
- [`reference/bot-triggers.md`](reference/bot-triggers.md) — Copilot/Codex request mechanics and post-trigger verify.
- [`reference/evaluation.md`](reference/evaluation.md) — the step-5 lens/mindset rubric, courses of action, resolve criteria, and the Phase-0 upfront-gate triage (minor / major-unclear / major-clear).
- [`reference/waiting.md`](reference/waiting.md) — the step-3 wait: capability ladder, re-entrancy, lockstep, timeouts.

**Requires:** `gh` (authenticated), `git`. Bash forms also use `jq`; PowerShell forms don't. Optional: a github MCP server, and a host loop/scheduling or event-subscription primitive for waits (the loop feature-detects and degrades — see [`reference/waiting.md`](reference/waiting.md)).

**Snippet convention:** in the code examples here and in the reference files, `<...>` tokens — `<num>`, `<owner>`, `<repo>`, `<path>`, `<tmp>`, etc. — are **placeholders you substitute with real values** (and quote as the shell requires); they are not literal shell tokens. Don't run them verbatim.

## Reporting style — terse

Status updates during iterations and waits are one or two lines. "Iter 3 wait, Codex still cooking, back in ~4 min." / "Both bots happy, terminating." / "Iter 2: 1 Copilot fix (terminology). Pushed, re-triggering." Don't restate bot text the user can read on the PR. The final summary is concise too — short bullets, not paragraphs.

## Configuration (summary)

Read defaults from this skill's [`config/defaults.yml`](config/defaults.yml), then merge overrides per key, low → high: bundled defaults < optional `~/.claude/pr-review.config.yml` < orchestrator repo's `.github/pr-review.config.yml`. Defaults: `upfront_gate_reviewers: []`, `request_on_pr_open: [copilot]`, `loop_reviewers: [copilot]`, `final_gate_reviewers: []`, `auto_review_grace_seconds: 0`, `wait_check_cadence_seconds: 240`, `max_iterations: 10`. Parse natural-language modifiers from the invocation. Full model and project *procedural* overrides: `reference/configuration.md`.

**Reviewer roles.** Four sets, all bot lists: `upfront_gate_reviewers` (run as a gate *before* the loop — Phase 0), `request_on_pr_open` (requested on the first pass), `loop_reviewers` (re-requested on every push — these *drive convergence*), and `final_gate_reviewers` (requested once after convergence). Both gate sets are **out-of-loop** reviewers (outside `loop_reviewers`), but they differ in character: the upfront gate runs an *adversarial* review (with its own minor/major triage and an optional re-review sub-loop) before the loop, while the final gate is a lighter *sanity check* after it.

**Out-of-loop** is a **structural** property here, not a vibe: it means any tracked reviewer that sits **outside** `loop_reviewers`. The loop reviewers are the iterative *drivers*; every other tracked bot is out-of-loop — tracked and evaluated once like any other, but never re-requested by step 8, so it isn't dragged through every polish round. The configured forms are **first-pass-only** bots (in `request_on_pr_open` but not `loop_reviewers`), `upfront_gate_reviewers`, and `final_gate_reviewers`; a bot that simply auto-appears unconfigured (tracked because it posted, but in no config list) lands in the same bucket. **Character is a separate axis from this structure:** the **upfront gate** is an *adversarial* review — its job is to find design/correctness problems before the loop — whereas the **final gate** is a lighter *sanity check*, a last confirming look after convergence. A rate-limited deep reviewer (e.g. Codex) thus contributes its first-look design/correctness catches via the upfront gate without being dragged through every polish round. Being on the *PR-open* request is not itself out-of-loop — Copilot is on `request_on_pr_open` too and is a loop driver. See `config/defaults.yml` for the recommended Codex pattern.

## Preconditions

- **Find the target PR(s).** First read the branch: `branch=$(git branch --show-current)`. If non-empty, `gh pr list --head "$branch" --json number,title,url` (quote it). If empty (detached HEAD — CI/automated runs), don't run `--head ""`; match by commit instead: `gh pr list --search "$(git rev-parse HEAD)" --json number,title,url`. Zero matches and no PR specified → surface it. Multiple → ask which.
- **Cross-repo PRs are allowed** in any natural phrasing (URL, sibling project name + number, `owner/repo#num`). Resolve to `(owner, repo, number)` and pass `--repo` to every `gh` call for that PR. **At least one PR in the run must be in the orchestrator repo** (the current working directory's repo) — if not, ask the user to add one or confirm.
- **Working tree must be clean** and `gh` authenticated.

Run `git fetch && git pull --ff-only` before each iteration's analysis. For multiple PRs run concurrently only if your scheduling primitive supports it, and each concurrent run MUST use an isolated working directory (separate `git worktree` or clone) to avoid `git` state collisions.

## Phase 0 — upfront adversarial gate

Runs **before** iteration-1 branching, **only when `upfront_gate_reviewers` is non-empty**. Empty (the default) → skip straight to iteration-1 branching; the loop behaves exactly as before. The gate's job is to vet the PR's *approach* once, up front, so the convergence loop doesn't polish a design that's wrong from the start.

But first, **don't gate a PR that already carries unaddressed feedback.** If unresolved feedback already exists (apply the iteration-1 "any unresolved feedback exists" test below — unresolved threads, unaddressed review-body concerns, or a bot-authored review-style verdict comment), skip Phase 0 and go straight to iteration-1 branching: the PR is mid-flight, not fresh, so an upfront design gate is the wrong move and would re-litigate settled ground. Phase 0 is for a *fresh* gate request only.

Otherwise:

1. **Request the gate bot(s)** in `upfront_gate_reviewers` once against current HEAD (step 2 trigger mechanics; `reference/bot-triggers.md`). The grace window applies as in step 2.
2. **Wait** for the verdict (step 3 mechanics; the requested set for this wait is `upfront_gate_reviewers`).
3. **Read the verdict** across all three reviewer-state surfaces ("Reading reviewer state") and **triage it as one integrated judgement** (`reference/evaluation.md` → "Upfront gate triage") into exactly one outcome:
   - **Clean** (no concerns) → gate passes. Resolve any threads, then fall through to **iteration-1 branching**.
   - **Minor** → apply the changes (evaluate per step 5, commit per step 6, update the description per step 7, push per step 8), then fall through to **iteration-1 branching**. Do **not** re-request the gate bot for minor changes — the convergence loop takes it from here.
   - **Major-unclear** (ambiguous, multiple viable approaches, security/auth/data-model/API-contract judgement, or anything you shouldn't decide unilaterally) → **pause and ask the user** (`Ask-user`). Do not proceed to the loop until it's resolved. The user's answer may convert it to a minor/clear fix or a reject.
   - **Major-clear** (you're confident what the right change is *and* that it's correct) → apply it (steps 5–8), then **re-request the same gate bot** and return to Phase 0 step 2. **Repeat to clean** — this sub-loop has no iteration cap (it precedes, and does not count toward, `max_iterations`); each pass should converge the design further. If it stops converging or a re-review surfaces a major-unclear finding, fall to the `Ask-user` outcome rather than spinning.

A verdict can carry several findings at once; judge them together. If **any** finding is major-unclear, take the `Ask-user` outcome (the most conservative) — you may still apply the unambiguously-minor/clear fixes in the same push, but the gate does not pass until the unclear question is settled. Only when no finding is major-unclear do the all-minor or major-clear outcomes apply.

**Gate-bot role after Phase 0.** Stamp Phase-0 fix commits with a `PR-Review-Loop: 0` trailer (iteration 0 = pre-loop gate) so they read as loop-authored, not external (per step 6 and `reference/waiting.md`); they don't advance the iteration counter. The gate bot is now a **tracked** bot but, unless it's also in `loop_reviewers`, it is out-of-loop — step 8 won't re-request it across the loop's own pushes and it doesn't gate convergence. Its Phase-0 verdict was already triaged, so the loop won't ask about it again. (Put the same bot in `final_gate_reviewers` if you also want it to vet what the fix rounds introduce — the two gates are independent.)

**Re-entrancy.** In the common single-context run Phase 0 just runs inline before the loop. A context-less wake that lands mid-gate reconstructs "still in Phase 0" from the carried payload (note it, like the iteration counter — `reference/waiting.md`); absent a carried payload, the fallback is: if `upfront_gate_reviewers` is set and **any** gate bot lacks a clean verdict at/after current HEAD, you're still in Phase 0 — the gate has passed only once **all** gate bots are clean at/after HEAD (matching the Phase-0 lockstep in `reference/waiting.md`).

## Iteration-1 branching

Before iteration 1, gather (see `reference/graphql.md` for exact queries): unresolved review threads (paginated); all reviews with state, submission timestamps, author type (`__typename: Bot`); bot-authored PR issue comments with bodies and timestamps (a first-class reviewer-state surface, not just a Codex "has started" check — some bots deliver their whole verdict, clean *or* findings, as an issue comment and never post a formal review; see "Reading reviewer state" below); the most recent push timestamp (latest of `HeadRefPushedEvent`/`HeadRefForcePushedEvent.createdAt` — force-pushes count; NOT `committedDate`); the PR's `createdAt` (iter-1 grace baseline); and `reviewRequests` via GraphQL (NOT `gh pr view --json reviewRequests`, which filters bots out). For externally-managed PRs, also fetch Copilot's `ReviewRequestedEvent.createdAt`.

Then branch:

- **If any unresolved feedback exists** — unresolved review threads (inline AND file-level), unaddressed concerns in any review body, OR a bot-authored review-style issue comment raising unaddressed concerns (such a comment itself makes the bot tracked, per step 2 — so this covers a bot that first appears via a comment) → **jump to step 5**. Skip steps 2 and 3.
- **Else** → **step 2** (apply grace window, selectively request bots that haven't auto-triggered) → **step 3** (wait). No push here. Step 2 is self-aware about not re-firing in-flight bots, so this covers both "fresh PR" and "PR with pending bot activity."

Iterations 2+ run the full sequence: 3 → 4 → (5 → 6 → 7 → 8 if any reviewer has comments) → 3.

## Reading reviewer state — three surfaces, judged on content

A reviewer's disposition can surface on any of **three** channels, and you must always read all three together and union them — never derive a bot's state from reviews/threads alone:

1. **Formal reviews** — `Review` objects and their bodies.
2. **Review threads** — inline and file-level comments.
3. **Bot-authored PR issue comments** — a plain comment on the PR, not attached to a review. Some bots post findings, or their entire clean verdict, only here.

Reviews-only is the specific trap that broke a live run: a bot that had been **happy for minutes** — its clean verdict sitting in an issue comment — was reported as "still reviewing" because the check looked at `Review` objects only.

**Judge disposition from what the bot actually wrote, not from a fixed phrase list.** For a bot's latest signal on the current commit, decide whether it reports unresolved concerns (**has findings**), a clean pass (**happy**), or work-in-progress — reading the *meaning*, the same way a person would. Bots word these differently and the next new bot will word them differently again, so don't pattern-match canned strings. As rough shape: a formal review carrying inline threads is usually "has findings"; an `APPROVED` state, a zero-comment review, or a short "nothing to flag / looks good / no major issues" note (in a review body OR an issue comment) is usually "happy."

**Staleness:** only signals at/after the most recent push count for the current HEAD. A clean verdict from before the latest push is stale — it does NOT make the bot happy for the new commit; re-derive against current HEAD. This re-derivation applies only to bots **still in the active set**. A bot that has *already* gone happy is dropped across the loop's own follow-up commits (step 4) — its clean verdict going stale against a loop fix does not pull it back. (An *external* push — code the loop didn't author — is the one exception that re-engages it, since that verdict can't cover code no reviewer has seen; see step 4 and `reference/waiting.md`.)

## The loop

### 1. Initial state check
Run **Phase 0 (upfront adversarial gate)** first when `upfront_gate_reviewers` is set — it must settle (clean, or minor fixes applied) before the loop proper begins. Then apply the iteration-1 branching above.

### 2. Request reviewers
Humans are never auto-re-pinged. Same flow on iteration 1 and after every push (called from step 8). Mechanics: `reference/bot-triggers.md`.

1. **Wait `auto_review_grace_seconds`** from the baseline: iter 1 = `max(PR createdAt, latest push event)` (some auto-triggers fire on PR open even when the branch was pushed earlier); iter 2+ = the most recent push event. Default `0` = no wait.
2. **Determine the request set:** iter 1 = `request_on_pr_open`. Iter 2+ after one of the loop's **own** fix pushes = the **active set** ∩ `loop_reviewers` — the tracked bots minus any already dropped happy (see step 4 and the terminology note below), intersected with the bots configured to drive the loop. A **first-pass-only** bot (in `request_on_pr_open` but not `loop_reviewers`) is therefore requested in iter 1, its findings evaluated in step 5 like any other, but never re-requested across the loop's own fix pushes — it behaves like a dropped-happy bot for re-request purposes regardless of its verdict, and does not gate convergence (step 4). **The ∩ `loop_reviewers` restriction applies only to the loop's own fix-driven re-requests.** An **external** push is the exception: per `reference/waiting.md` ("External pushes during the wait") it rebuilds the active set as the **full tracked set** and re-requests every tracked bot — first-pass-only and dropped-happy included — since none can have seen code the loop didn't author. A first-pass-only bot otherwise re-engages only via a manual re-request or the final sanity check. Tracked bots = `request_on_pr_open` ∪ every bot that has posted a review OR a review-style verdict comment — a bot-authored PR issue comment that reads as a review verdict (findings or a clean pass), judged on content per "Reading reviewer state". A comment-only reviewer (one that signals only via issue comments, never a formal `Review`) is tracked on that basis; routine CI/status/noise comments (build bots, dependabot, and the like) are NOT verdicts and do not make a bot tracked. (All bot authorship via `__typename: Bot`.) Once a bot is tracked it stays in the tracked set **permanently** — that membership is PR-derived history (it reviewed/commented, and that never un-happens) and is the same on every wake. If it's in `loop_reviewers` it's re-engaged after every push — **until it goes happy, after which it leaves the *active* set** (step 4) and this step stops requesting it, until a manual re-request or an external push re-engages it. A tracked bot that is *not* in `loop_reviewers` (first-pass-only, final-gate, or an unconfigured bot that just showed up) is **not** re-engaged by the loop's own pushes — only by an external push or the final gate, per the rule above. *Tracked set* (permanent, PR-derived) and *active set* (run-scoped = tracked minus already-happy) are deliberately distinct: a happy bot never leaves the tracked set, only the active set, which is why "dropped for good" is a loop rule, not a claim about PR history. Keeping the active set across context-less wakes is `reference/waiting.md`'s job (it's carried/derived like the iteration counter).
3. **For each bot, skip if it has already engaged the current commit** — started reviewing it, or already delivered a verdict for it. Evaluate at/after the most recent push across the three reviewer-state surfaces (above) plus the loop's own trigger: a formal review (`submittedAt`) or new review-thread comments; a bot-authored verdict issue comment (clean or findings); or, for a bot we trigger by mention, our own trigger comment already posted for this commit. Copilot = a `reviewRequests` entry at/after the push (membership implies at-or-after when the loop owns push→request ordering; else derive via `ReviewRequestedEvent.createdAt`). Codex (a comment-style bot) = a `chatgpt-codex-connector` post OR an existing `@codex review` trigger at/after the push. Otherwise request it.
4. **Proceed to step 3.**

### 3. Wait for new reviewer activity
Pick the highest tier from the wait capability ladder (event-driven subscription → time-based scheduling → single-pass hand-back) and apply lockstep + timeouts. Make each wake idempotent — reconstruct loop state from the PR. A wake **resumes here at the wait/evaluate cycle**, applying the carried iteration counter (or PR-derived floor) and any carried invocation modifiers; it does NOT re-run the first-run preamble (arg parse, modifier detection) — that's kickoff-only, so the modifiers' *effects* (a disabled cap, an "only copilot" request set) must ride in the wake payload rather than being re-detected. Full detail: `reference/waiting.md`. Waiting does NOT count toward `max_iterations`.

### 4. Detect "this reviewer is happy"
For each bot **still in the active set** (already-happy bots are done — don't re-evaluate them, per "Happy is terminal and sticky" below), ALL must hold:
- Zero unresolved review threads attributed to it (inline AND file-level).
- Its most recent verdict *for the current HEAD* — the latest of a formal review (and its body) or a bot-authored issue comment (its review threads are covered by the first bullet above) — reads as a clean verdict with no unaddressed concerns. Judge this from what the bot wrote per "Reading reviewer state" above, not a fixed phrase list.
- That clean signal is at/after the most recent push (a pre-push verdict is stale — re-derive against current HEAD).

A bot that posts **no formal review at all** can still be happy on this basis — its clean issue comment is the verdict. This is exactly the case the loop used to miss: a comment-style bot's clean verdict isn't a `Review`, so a reviews-only check wrongly reports it pending.

**All-rejections short-circuit:** if a reviewer's latest comments ALL resolved to `Reject-with-explanation`, treat it as done — further iteration won't help. **`Create-issue-and-close` IS acceptance** (deferred real concern), so any issue creation disqualifies an all-rejections call.

**Happy is terminal and sticky.** Once a bot goes happy (either path), it is **done for the rest of this loop run** — removed from the **active set** (it stays in the PR-derived tracked set as history; the loop just stops engaging it). Do not re-request it, do not re-evaluate it, and **do not ask whether to review it again** on later iterations. This holds across the loop's **own** follow-up commits: a push the loop makes for *another* bot's fix does NOT resurrect a dropped happy bot, even though its clean verdict is now stale against the new HEAD — the staleness/re-derive-against-HEAD rule (see "Reading reviewer state") governs only bots **still in the active set** and never reaches back to one already gone happy. Exactly **two** things re-engage a happy bot: (1) the user **manually** bringing it back (an explicit "re-run \<bot\>" / "have \<bot\> look again"); or (2) an **external push** — commits the loop didn't author (a teammate or automation, identified by the missing `PR-Review-Loop` trailer) that introduce code no reviewer has seen, which a prior clean verdict can't cover, so every tracked bot re-reviews the new HEAD (see `reference/waiting.md` "External pushes during the wait"). The loop's own fix commits are neither, so they never re-engage a happy bot. Absent a manual re-request or an external push, a happy bot stays out — silently, no prompt. Because the active set is run-scoped state the PR doesn't record as such, a context-less wake must reconstruct it — carried in the wake payload (or, for full stickiness, recorded on the PR at drop time) per `reference/waiting.md` ("Carrying the dropped-happy set"). It must **not** be inferred from a stale clean verdict: that can't tell a genuinely-dropped bot from one that simply went clean on an older commit and still needs the new HEAD, so absent the carried set the loop re-requests conservatively rather than silently skipping. **Loop terminates when all `loop_reviewers` are happy** — first-pass-only bots do **not** gate convergence (their iter-1 findings were already triaged in step 5). On termination, run the **final sanity check** (below) when `final_gate_reviewers` is non-empty, then the Final summary report.

### 5. Evaluate each comment
Threads are the unit of evaluation; also check each review's body. Read human replies as input, not a post-hoc check. Hold the weighted project/PR/item lenses + mindset as one integrated judgement. Courses: `Fix-as-suggested`, `Fix-differently`, `Fix-broader`, `Reject-with-explanation`, `Create-issue-and-close`, `Ask-user`. Default to `Ask-user` for security/auth, scope-creep boundaries, conflicting asks, big architectural feedback. Full rubric, issue-creation, and resolve criteria: `reference/evaluation.md`.

### 6. Commit changes
One commit per logical group of fixes. Build first if any non-doc code was touched — detect the project's standard verify command. **Never commit red.** Defer commit mechanics to the host (`commit-commands:commit` skill if installed; else plain `git commit`). Keep messages tight: one-line summary, optional one-line detail. **Stamp each loop commit with a `PR-Review-Loop: <N>` trailer**, where `<N>` is the current iteration number — a standard `Key: value` git trailer, parseable by `git interpret-trailers`. A context-less wake reads the iteration floor straight off this marker (`reference/waiting.md`); without it the floor can't be derived.

### 7. Update PR description if it has drifted
If this iteration's commits made the description inaccurate, update it — **surgical edits only**, change only affected sections, keep it tight. Use `--body-file` to avoid shell-escaping issues:

```bash
gh pr view <num> --json body --jq '.body // ""' > <tmp>/pr-body-<num>.md  # gh --jq outputs raw; no -r flag; // "" guards a null (bodyless) PR
# edit surgically
gh pr edit <num> --body-file <tmp>/pr-body-<num>.md
```

### 8. Push + re-request reviewers
`git push`, then run the step 2 trigger flow against the **not-yet-happy** `loop_reviewers` (it waits the grace window, skips bots already reviewing the new commit, requests the rest). First-pass-only bots are not re-requested here.

### 9. Iteration counter
Increment. If `max_iterations` reached, pause and ask the user (skip the cap if invoked with a "no iteration cap" modifier). Then return to step 3.

**The counter must survive the wake** — it's the one piece of loop state with no PR backstop, so a context-less wake that doesn't carry it resets to 0 and the cap never fires. Carry iteration N of max M (plus any effective invocation modifiers — a disabled cap, an "only copilot" request set — which aren't PR-derivable either) in the wake payload via a **continuation prompt that resumes at step 3**, not a bare `/pr-review-loop` re-invocation (which restarts the preamble and loses the count; reserve `/pr-review-loop` for kickoff). If a wake carries no counter, derive a floor from the PR so the cap still engages. Full mechanics, including the floor derivation: `reference/waiting.md`. The single-pass floor tier hands back to the user, so the counter is moot there.

### 10. Final sanity check
A last confirming look once the loop has converged — **not** an adversarial deep-dive (that is the upfront gate's job), just a check by the configured bot that the converged state is coherent and nothing regressed. Runs only when the loop has converged (all `loop_reviewers` happy) **and** `final_gate_reviewers` is non-empty; otherwise skip straight to the summary. Request the configured bot(s) once against the current HEAD and wait (step 3 mechanics), then:
- **Any finding needs a code change** → evaluate (step 5), fix/commit/push (steps 6–8). That push re-engages the `loop_reviewers`, so re-converge the loop, then run the check **once more**. Cap it at one re-run to avoid ping-pong with a rate-limited reviewer; if it still has code-change findings after that, hand back to the user.
- **Clean, or all findings resolve without a code change** (`Create-issue-and-close` / `Reject-with-explanation`) → resolve the threads, no re-converge; proceed to the Final summary.

Expect it to be clean most of the time; its value is confirming the converged result and catching anything the fix rounds happened to introduce or miss — a final check before wrapping up, not another review round.

## Final summary report

When the loop terminates (all `loop_reviewers` happy, and the final sanity check — if `final_gate_reviewers` is set — is clean or only deferred), summarize concisely: commits made (sha + one-liner each), follow-up issues created with reasons, threads acknowledged-without-fix that remain open for discussion, anything left for user attention.
