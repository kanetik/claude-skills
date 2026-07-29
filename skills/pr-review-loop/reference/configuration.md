# Configuration & override model

The loop is governed by four config keys, plus natural-language invocation modifiers and project-level *procedural* overrides. `config/defaults.yml` holds the shipped values; this file is the full model.

One value the loop depends on is **not** its own: the severity floor that decides when a reviewer is happy (SKILL.md step 4). For `skeptic` that is `blocking_severities` in the *skeptic* skill's config — `[CRITICAL, HIGH]` by default, set in the reviewed repo's `.github/pr-review-skeptic.config.yml` and nowhere in this skill's config. For a bot, which tags no severities, there is no key at all: step 4's equivalent judgement is whether the verdict raises anything that would change code on a path users reach. So a user wanting `MEDIUM` findings to block the loop changes the skeptic config, not this one — and on a `reviewers: [copilot]` setup there is no floor to configure.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `reviewers` | `[copilot]` | The reviewers the loop drives: engaged on PR open, re-engaged after every fix push (SKILL.md step 8), and the set convergence is gauged on (step 4). Each entry is a review **bot** or **`skeptic`** (the sibling `pr-review-skeptic` skill, invoked locally, posting its findings to the PR itself). Must be non-empty — see below. |
| `auto_review_grace_seconds` | `0` | After a push, wait this long for an auto-trigger to land before manually requesting. `0` = no wait. Bump to ~60 where a Ruleset auto-requests Copilot, or to give a bot's auto-review time to start. Doesn't apply to `skeptic`, which nothing auto-triggers. |
| `wait_check_cadence_seconds` | `180` | Polling cadence while waiting on a **bot** (SKILL.md step 3, `reference/waiting.md`). Stay in 120-240s (every 2-4 min): frequent enough to react promptly, and ≤270s keeps each wake inside the 5-minute prompt-cache window; >300s incurs a full context replay per wake. A `reviewers` list with no bot in it never waits. |
| `max_iterations` | `10` | Iteration cap. **Not a backstop** — see below. Waiting does NOT count toward it. |

### An empty `reviewers` is a configuration error, not a mode

It reads like it should mean "engage nobody, just triage whatever turns up", and it cannot: with nothing to engage there is nothing to wait for, so step 3 returns immediately, step 4 finds the intersection vacuously happy, and the loop terminates having triaged nothing — reporting a *converged* run on a PR no reviewer has looked at. A clean finish on an unreviewed PR is worse than no run at all.

So the non-empty requirement is an **invariant, not a validation of the config file** — and it is tested twice, because the set can empty at two different times. Before step 2, over `reviewers`: the merge itself, a modifier that narrows the list to nothing, or the Preconditions offer to drop an unusable `skeptic`. And again at every step-4 evaluation, over `active ∩ reviewers`, which is where the fourth route lands — a reviewer *excused* mid-run, the only one that fires after step 2 has already passed. Any of the four landing on empty stops the run: say the set is empty and name what emptied it, and never let step 4's "every reviewer is happy" pass vacuously over nobody.

The thing it was reaching for is legitimate and already works — a repo whose bots auto-review on push, needing no manual request. Put those bots in `reviewers` anyway: step 2's per-reviewer skip check sees each has already covered the current commit and requests nothing, so the loop waits for and converges on them without ever pinging one.

### `max_iterations` is load-bearing

Under the old shape the loop converged on a bot going quiet, and the cap existed for the case where something had gone wrong. That is no longer true. Convergence is now "no reviewer has anything at or above the blocking severities" (SKILL.md step 4), and an adversarial reviewer with no severity floor will always have *something* — so the loop is not guaranteed to terminate on its own merits, and the cap is what guarantees it terminates at all. Two consequences:

- **Reaching it is an outcome, not an error.** SKILL.md step 9 requires it be reported as "did not converge", with the count and every outstanding blocking finding, and distinguished in the summary from a clean finish.
- **Its value is a real choice.** `10` suits a normal change. Raise it for a large one; lower it to keep an unattended run bounded. "no iteration cap" in the invocation disables it, which means asking for a loop with no termination guarantee — reasonable when supervised, not otherwise.

## Precedence (low → high)

```
bundled defaults  <  ~/.claude/pr-review-loop.config.yml (optional)  <  <orchestrator-repo>/.github/pr-review-loop.config.yml (project)
```

Bundled defaults are always present (the self-sufficient baseline). User-level is optional and additive — read it *if it exists*; if it doesn't, that's fine, never require it. Project `.github/pr-review-loop.config.yml` in the orchestrator repo (the working directory's repo) wins. **Merge is per-key**, not whole-file replace — a project file setting only `max_iterations` inherits the rest from below. The merged config applies to ALL PRs in the run, including cross-repo ones (they don't pull config from their own repos).

## Retired keys

Earlier versions had four reviewer lists — `upfront_gate_reviewers`, `request_on_pr_open`, `loop_reviewers`, `final_gate_reviewers` — with the two gates running their own review/fix/re-review sub-loops before and after the main one. All four are retired, and with them the second path from a finding to a fix that made up most of the skill's complexity.

Where a config layer still sets any of them: **union them into `reviewers`**, deduplicated, and tell the user once which keys you folded and what the resulting list is. Don't fail on them and don't ignore them silently — a user whose gate reviewer quietly stopped running would find out from a missed defect. `skeptic` in any of the four is now simply a reviewer, which is what most such configs meant.

The one thing that genuinely disappears is the *first-pass-only* role: a bot listed in `request_on_pr_open` but not `loop_reviewers`, requested once and never again. Folded into `reviewers` it is now re-engaged on every push. Say so if you fold such a config, since it is the one case where the union changes behaviour rather than just spelling.

**Evaluation is NOT config-gated.** Any reviewer that posts a review, or a review-style verdict comment (judged on content, not CI/noise), is evaluated and tracked. What *is* config-gated is **re-engaging**: only `reviewers` are engaged again after later pushes. A verdict may arrive as a formal review *or* a plain issue comment (some bots only comment when happy); the loop reads both and **judges disposition from what was written** (SKILL.md "Reading reviewer state"). There is deliberately **no per-bot verdict-phrase configuration** — a phrase list would break on the next bot.

## `skeptic` as a reviewer

`skeptic` works in `reviewers` alongside bots, and the loop treats its findings identically. Three things about it are not like a bot, and all three are handled in SKILL.md rather than here: it is invoked rather than requested (so never waited on), it is recognised by the `<!-- pr-review-skeptic -->` marker rather than by author type (its reviews post under the user's account), and it never goes sticky-happy (it is re-invoked on every fix push, which is where most of its value is).

It also has a precondition a bot doesn't: the reviewed repo must have committed `allow_agent_posting: true` to its `.github/pr-review-skeptic.config.yml`, alongside the five project keys. Without it an agent-invoked run posts nothing, and a loop whose reviewer leaves no trace on the PR cannot record decisions, cannot settle anything, and will run to the cap re-finding what it already answered. SKILL.md checks all of this at kickoff.

## Invocation modifiers — natural language, not flags

Parse intent; don't require precise syntax:

- "no iteration cap" / "until done" / "no max" → disable `max_iterations`. Say plainly that this removes the loop's only termination guarantee.
- "only copilot" / "without codex" / "skip the skeptic" → narrow `reviewers` for this run. Only changes who the loop *engages*; a reviewer that shows up via auto-trigger is still evaluated. **If the narrowing leaves the list empty, stop and say so** — don't run a loop with nobody in it (above).
- "just fix what's there" / "one pass" → triage what is already on the PR and stop: steps 1, 5, 6, 7, then **push without step 8's re-engagement**, and no wait, no step 4, no return to step 3. Step 8's two halves come apart here deliberately, and only the push runs. Re-engaging reviewers and then terminating would be worse than either: they post findings onto a PR this run has already stopped triaging, and the next run reads them as unresolved feedback of unknown provenance.
- A PR number, URL, or cross-repo reference → target specific PR(s) instead of auto-detecting.

Build command is not configured — detect the project's verify command at the commit step.

## Project-level *procedural* overrides (separate from config)

If the orchestrator repo has its own PR-review instructions that **contradict** this skill, defer to the project — assume the override is intentional. Check: `./.github/PR_REVIEW_LOOP.md`, `./CLAUDE.md` (PR-review section), `./AGENTS.md` (PR-review section), `./.cursorrules`, `./.claude/commands/pr-review-loop.md` / `./.claude/skills/pr-review-loop/`. Classify each difference:

- **Contradiction** = procedural disagreement (reply templates, escalation rules, rubric, resolve criteria). **Project wins.**
- **Addition** = non-contradicting delta (project build command, an extra lint rule, a preferred reply style). **Apply both.** (Reviewer selection is config, not a procedural addition.)
- **Unclear** = can't tell whether it's an intended override or just stale. **Ask the user.**
