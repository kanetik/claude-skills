---
name: pr-review
description: >-
  Runs an iterative PR review loop on a repo's open PR(s): requests AI reviewers
  (Copilot, Gemini, and any bot that posts a review), waits for their reviews,
  evaluates each review thread under a weighted project/PR/item judgement, then
  fixes, pushes back, or files follow-up issues, resolves threads, and repeats
  until every tracked bot is satisfied. Self-contained — bundles its config
  defaults and reference material and reads project overrides from the consuming
  repo. Detects the best available wait mechanism (event-driven subscription,
  scheduled polling, or single-pass) and degrades gracefully.
when_to_use: >-
  Use when the user says "start a PR review", "respond to PR comments", "handle
  PR feedback", invokes /pr-review, or says they just created/opened a PR. ALSO
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

An iterative loop that drives AI code reviewers (Copilot, Gemini, any bot that posts) to convergence on a pull request: request → wait → evaluate → fix/answer → push → repeat, until every tracked bot is happy.

This skill is self-contained. All the files below live **inside this skill's own directory**, alongside this `SKILL.md` — read them from there (paths are relative to this file, not to the current working directory). Config defaults live in [`config/defaults.yml`](config/defaults.yml); the heavy mechanics live in `reference/` and are loaded on demand:

- [`reference/configuration.md`](reference/configuration.md) — config keys, the layered override model, invocation modifiers, project procedural overrides.
- [`reference/tool-tiers.md`](reference/tool-tiers.md) — per-operation tool tiers and the wait capability ladder.
- [`reference/graphql.md`](reference/graphql.md) — paginated `reviewThreads` query and the other GraphQL/REST the loop needs (bash + PowerShell).
- [`reference/bot-triggers.md`](reference/bot-triggers.md) — Copilot/Gemini request mechanics and the mandatory Gemini verify-and-fix.
- [`reference/evaluation.md`](reference/evaluation.md) — the step-5 lens/mindset rubric, courses of action, resolve criteria.
- [`reference/waiting.md`](reference/waiting.md) — the step-3 wait: capability ladder, re-entrancy, lockstep, timeouts.

**Requires:** `gh` (authenticated), `git`. Bash forms also use `jq`; PowerShell forms don't. Optional: a github MCP server, and a host loop/scheduling or event-subscription primitive for waits (the loop feature-detects and degrades — see [`reference/waiting.md`](reference/waiting.md)).

**Snippet convention:** in the code examples here and in the reference files, `<...>` tokens — `<num>`, `<owner>`, `<repo>`, `<path>`, `<tmp>`, etc. — are **placeholders you substitute with real values** (and quote as the shell requires); they are not literal shell tokens. Don't run them verbatim.

## Reporting style — terse

Status updates during iterations and waits are one or two lines. "Iter 3 wait, Gemini still cooking, back in ~4 min." / "Both bots happy, terminating." / "Iter 2: 1 Copilot fix (terminology). Pushed, re-triggering." Don't restate bot text the user can read on the PR. The final summary is concise too — short bullets, not paragraphs.

## Configuration (summary)

Read defaults from this skill's [`config/defaults.yml`](config/defaults.yml), then merge overrides per key, low → high: bundled defaults < optional `~/.claude/pr-review.config.yml` < orchestrator repo's `.github/pr-review.config.yml`. Defaults: `request_on_pr_open: [copilot]`, `auto_review_grace_seconds: 0`, `wait_check_cadence_seconds: 240`, `max_iterations: 10`. Parse natural-language modifiers from the invocation. Full model and project *procedural* overrides: `reference/configuration.md`.

## Preconditions

- **Find the target PR(s).** First read the branch: `branch=$(git branch --show-current)`. If non-empty, `gh pr list --head "$branch" --json number,title,url` (quote it). If empty (detached HEAD — CI/automated runs), don't run `--head ""`; match by commit instead: `gh pr list --search "$(git rev-parse HEAD)" --json number,title,url`. Zero matches and no PR specified → surface it. Multiple → ask which.
- **Cross-repo PRs are allowed** in any natural phrasing (URL, sibling project name + number, `owner/repo#num`). Resolve to `(owner, repo, number)` and pass `--repo` to every `gh` call for that PR. **At least one PR in the run must be in the orchestrator repo** (the current working directory's repo) — if not, ask the user to add one or confirm.
- **Working tree must be clean** and `gh` authenticated.

Run `git fetch && git pull --ff-only` before each iteration's analysis. For multiple PRs run concurrently only if your scheduling primitive supports it, and each concurrent run MUST use an isolated working directory (separate `git worktree` or clone) to avoid `git` state collisions.

## Iteration-1 branching

Before iteration 1, gather (see `reference/graphql.md` for exact queries): unresolved review threads (paginated); all reviews with state, submission timestamps, author type (`__typename: Bot`); PR issue comments (for Gemini's "has started" check); the most recent push timestamp (latest of `HeadRefPushedEvent`/`HeadRefForcePushedEvent.createdAt` — force-pushes count; NOT `committedDate`); the PR's `createdAt` (iter-1 grace baseline); and `reviewRequests` via GraphQL (NOT `gh pr view --json reviewRequests`, which filters bots out). For externally-managed PRs, also fetch Copilot's `ReviewRequestedEvent.createdAt`.

Then branch:

- **If any unresolved feedback exists** — unresolved review threads (inline AND file-level) OR unaddressed concerns in any review body → **jump to step 5**. Skip steps 2 and 3.
- **Else** → **step 2** (apply grace window, selectively request bots that haven't auto-triggered) → **step 3** (wait). No push here. Step 2 is self-aware about not re-firing in-flight bots, so this covers both "fresh PR" and "PR with pending bot activity."

Iterations 2+ run the full sequence: 3 → 4 → (5 → 6 → 7 → 8 if any reviewer has comments) → 3.

## The loop

### 1. Initial state check
Apply the iteration-1 branching above.

### 2. Request reviewers
Humans are never auto-re-pinged. Same flow on iteration 1 and after every push (called from step 8). Mechanics: `reference/bot-triggers.md`.

1. **Wait `auto_review_grace_seconds`** from the baseline: iter 1 = `max(PR createdAt, latest push event)` (some auto-triggers fire on PR open even when the branch was pushed earlier); iter 2+ = the most recent push event. Default `0` = no wait.
2. **Determine the request set:** iter 1 = `request_on_pr_open`. Iter 2+ = the **tracked bots** not yet "happy". Tracked bots = `request_on_pr_open` ∪ every bot that has posted a review (identified via `__typename: Bot`); once tracked, re-engaged after every push regardless of why it first appeared.
3. **For each bot, skip if it has already started reviewing the current commit:** Copilot = a `reviewRequests` entry at/after the most recent push (membership implies at-or-after when the loop owns push→request ordering; else derive via `ReviewRequestedEvent.createdAt`). Gemini = a `/gemini review` comment OR any `gemini-code-assist` post at/after the push. Any bot = a review with `submittedAt` at/after the push. Otherwise request it.
4. **Proceed to step 3.**

### 3. Wait for new reviewer activity
Pick the highest tier from the wait capability ladder (event-driven subscription → time-based scheduling → single-pass hand-back) and apply lockstep + timeouts. Make each wake idempotent — reconstruct loop state from the PR. A wake **resumes here at the wait/evaluate cycle**, applying the carried (or PR-derived-floor) iteration counter; it does NOT re-run the first-run preamble (arg parse, modifier detection), which is kickoff-only work. Full detail: `reference/waiting.md`. Waiting does NOT count toward `max_iterations`.

### 4. Detect "this reviewer is happy"
For each tracked bot, ALL must hold:
- Zero unresolved review threads attributed to it (threads cover inline AND file-level comments).
- Its most recent `Review.body` has no unaddressed concerns.
- AND at least one of: most recent review state `APPROVED`; OR most recent review has zero comments; OR body explicitly says "no issues"/"LGTM"/"no new comments".

**All-rejections short-circuit:** if a reviewer's latest comments ALL resolved to `Reject-with-explanation`, treat it as done — further iteration won't help. **`Create-issue-and-close` IS acceptance** (deferred real concern), so any issue creation disqualifies an all-rejections call.

Once happy (either path), drop the reviewer for subsequent iterations. **Loop terminates when all tracked bots are happy** → Final summary report.

### 5. Evaluate each comment
Threads are the unit of evaluation; also check each review's body. Read human replies as input, not a post-hoc check. Hold the weighted project/PR/item lenses + mindset as one integrated judgement. Courses: `Fix-as-suggested`, `Fix-differently`, `Fix-broader`, `Reject-with-explanation`, `Create-issue-and-close`, `Ask-user`. Default to `Ask-user` for security/auth, scope-creep boundaries, conflicting asks, big architectural feedback. Full rubric, issue-creation, and resolve criteria: `reference/evaluation.md`.

### 6. Commit changes
One commit per logical group of fixes. Build first if any non-doc code was touched — detect the project's standard verify command. **Never commit red.** Defer commit mechanics to the host (`commit-commands:commit` skill if installed; else plain `git commit`). Keep messages tight: one-line summary, optional one-line detail.

### 7. Update PR description if it has drifted
If this iteration's commits made the description inaccurate, update it — **surgical edits only**, change only affected sections, keep it tight. Use `--body-file` to avoid shell-escaping issues:

```bash
gh pr view <num> --json body --jq '.body // ""' > <tmp>/pr-body-<num>.md  # gh --jq outputs raw; no -r flag; // "" guards a null (bodyless) PR
# edit surgically
gh pr edit <num> --body-file <tmp>/pr-body-<num>.md
```

### 8. Push + re-request reviewers
`git push`, then run the step 2 trigger flow against the **not-yet-happy** tracked bots (it waits the grace window, skips bots already reviewing the new commit, requests the rest).

### 9. Iteration counter
Increment. If `max_iterations` reached, pause and ask the user (skip the cap if invoked with a "no iteration cap" modifier). Then return to step 3.

**The counter must survive the wake — it is the one piece of loop state not derivable from the PR.** Don't hold it only in turn-local context, or a context-less wake resets it to 0 and the cap never fires. When yielding to wait, **carry iteration N and cap M in the wake payload**: event-driven → put it in the re-subscription/continuation context; time-based → schedule a **continuation prompt** stating "iteration N of max M, resume at step 3" (NOT a bare `/pr-review` re-invocation, which restarts the preamble and loses the count — reserve `/pr-review` for the initial kickoff). If a wake arrives with no carried counter, **derive a floor from the PR** (count the loop's own push events / fix commits since PR creation) so the cap still engages; it's a floor and may under-count, which is the safe direction. Full mechanics: `reference/waiting.md`. The single-pass floor tier hands back to the user, so the counter is moot there.

## Final summary report

When the loop terminates (all tracked bots happy), summarize concisely: commits made (sha + one-liner each), follow-up issues created with reasons, threads acknowledged-without-fix that remain open for discussion, anything left for user attention.
