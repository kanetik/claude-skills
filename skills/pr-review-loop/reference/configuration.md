# Configuration & override model

The loop is governed by the config keys below, plus natural-language invocation modifiers and project-level *procedural* overrides. `config/defaults.yml` holds the shipped values; this file is the full model.

One value the loop depends on is **not** its own: the severity floor that decides when a reviewer is happy (SKILL.md step 4). For `skeptic` that is `blocking_severities` in the *skeptic* skill's config — `[CRITICAL, HIGH]` by default, set in the reviewed repo's `.github/pr-review-skeptic.config.yml` and nowhere in this skill's config. For a bot, which tags no severities, there is no key at all: step 4's equivalent judgement is whether the verdict raises anything that would change code on a path users reach. So a user wanting `MEDIUM` findings to block the loop changes the skeptic config, not this one — and on a `reviewers: [copilot]` setup there is no floor to configure.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `reviewers` | `[copilot]` | The reviewers the loop drives: engaged on PR open, re-engaged after every fix push (SKILL.md step 8), and the set convergence is gauged on (step 4). Each entry is a review **bot** or **`skeptic`** (the sibling `pr-review-skeptic` skill, invoked locally, posting its findings to the PR itself). Must be non-empty — see below. |
| `auto_review_grace_seconds` | `0` | After a push, wait this long for an auto-trigger to land before manually requesting. `0` = no wait. Bump to ~60 where a Ruleset auto-requests Copilot, or to give a bot's auto-review time to start. Doesn't apply to `skeptic`, which nothing auto-triggers. |
| `wait_check_cadence_seconds` | `180` | Polling cadence while waiting on a **bot** (SKILL.md step 3, `reference/waiting.md`). Stay in 120-240s (every 2-4 min): frequent enough to react promptly, and ≤270s keeps each wake inside the 5-minute prompt-cache window; >300s incurs a full context replay per wake. A `reviewers` list with no bot in it never waits. |
| `max_iterations` | `10` | Iteration cap. **A backstop** — reaching it means something went wrong; see below. Waiting does NOT count toward it. |
| `mark_ready_on_convergence` | `false` | On terminal state 1 (*converged*) only, and on a PR in the **orchestrator repo** only, take the PR out of draft with `gh pr ready` (SKILL.md step 4). Off by default; see below. No other terminal state, and no cross-repo PR, has its draft state touched. |
| `fix_bar` | a general sentence, below | What a fix has to buy to be worth a round, in the project's own words. An input to step 5's question 2 only (`reference/evaluation.md`); it never decides whether a finding is *correct*, and it can never license leaving a blocking severity. |

### An empty `reviewers` is a configuration error, not a mode

It reads like it should mean "engage nobody, just triage whatever turns up", and it cannot: with nothing to engage there is nothing to wait for, so step 3 returns immediately, step 4 finds the intersection vacuously happy, and the loop terminates having triaged nothing — reporting a *converged* run on a PR no reviewer has looked at. A clean finish on an unreviewed PR is worse than no run at all.

So the non-empty requirement is an **invariant, not a validation of the config file** — and it is tested twice, over two different sets. Before step 2, over `reviewers`: emptied by the merge itself, by a modifier that narrows the list to nothing, or by the Preconditions offer to drop an unusable `skeptic`. And again at every step-4 evaluation, over the **accountable set** (`reviewers` minus excused), which is where the fourth route lands — a reviewer excused mid-run, the only one that fires after step 2 has passed.

The second test is over the accountable set specifically, **not** the active set. A reviewer that goes happy leaves the active set, so the active set empties on success; testing that for non-emptiness would call every successful run unreviewed. See SKILL.md step 4.

Any of the four routes landing on empty stops the run: say which set is empty and what emptied it, and never let "every reviewer is happy" pass vacuously over nobody.

The thing it was reaching for is legitimate and already works — a repo whose bots auto-review on push, needing no manual request. Put those bots in `reviewers` anyway: step 2's per-reviewer skip check sees each has already covered the current commit and requests nothing, so the loop waits for and converges on them without ever pinging one.

### `max_iterations` is a backstop, and hitting it is a diagnosis

Convergence is a round that **changes no code** — nothing at or above the blocking severities outstanding, *and* nothing fixed that a reviewer has not since seen (SKILL.md step 4; both conditions, not just the first).

An adversarial reviewer with no severity floor will always have *something*, and for a while this skill concluded from that the loop could not terminate on its own merits. That was wrong, and it was wrong in a way that made things worse: told the cap was the only thing that ends the run, the author role treated every round of correct observations as work to be done. **"Found something" is not "found a problem."** Most of what a late round surfaces is correct and names no problem anyone reaches, and step 5 acknowledges those on the record and closes them without moving HEAD (`Acknowledge-no-change`, `reference/evaluation.md`). A round that changes no code is reachable by following the skill.

So a run that burns to the cap is a **signal**, and usually a triage one: correct observations read as real problems, each fix owing another review, the loop reviewing its own repairs. Three consequences:

- **Reaching it is an outcome, not an error — and it is reported with evidence.** SKILL.md step 9 requires "did not converge" with the count and every outstanding blocking finding, plus rounds since the last blocking finding, the share of findings landing in the loop's own repair work (over whole-change reviewers only — a delta-scoped reviewer reads repair commits by construction), the longest repair chain, and diff growth. Growth alerts; it never stops. The user is otherwise choosing on the author's narration.
- **Its value is a real choice.** `10` suits a normal change. Raise it for a large one; lower it to keep an unattended run bounded.
- **"no iteration cap" removes the only bound the run has.** A round that changes no code is the loop's intended exit, not a guarantee it reaches one: where triage goes wrong in the way this section describes, every round finds real-looking work and the fixed point is never reached. Disabling the cap then means an unbounded run that pushes commits on every round and, with `skeptic` in `reviewers`, dispatches up to `max_reviewers` subagents posting reviews under the user's account each time. Reasonable when supervised, not otherwise — say that when honouring it.

### `mark_ready_on_convergence` is off by default, and that is a distribution decision

A converged run has driven the PR to the state a human is meant to read it in, so taking it out of draft at that point is the same job the loop is already doing — requesting reviews, replying, resolving, pushing (this repo's rule 1: a PR operation belongs to the caller *unless it is the skill's domain*). For a single user who runs the loop on every PR, `true` is what they want.

It ships `false` anyway, because this is a published skill and changing a PR's draft state is **outward-facing**. It notifies reviewers, and in a repo with required reviews it changes what can merge. A repo that adopts this skill did not necessarily agree to have an agent move its PRs into the queue for human sign-off. So the affordance exists and is one line to switch on — `mark_ready_on_convergence: true` in the user-level or project file — and nobody gets it by installing.

**And it applies only to PRs in the orchestrator repo.** A cross-repo PR is never taken out of draft, whatever the key says. This key merges from the user-level file and the *orchestrator* repo's project file, and that merged config governs every PR in the run including cross-repo ones (Precedence, below) — so without this scoping a `true` in one machine's user-level file would undraft PRs in repos that never opted in and have no file the loop consults to opt out. That is why the default being `false` is not on its own the safeguard, and why this is **not** the same shape as `allow_agent_posting` in the skeptic config: that key is a grant the *reviewed* repo commits, so it answers for the repo being acted on. Nothing in this key's merge does, and the scoping is what stands in for it.

The two guards matter more than the default, and both have to hold. The repo one is the paragraph above. The other is the terminal state: only state 1 marks ready; *paused*, *cap reached*, *nobody reviewed this HEAD* and *the whole change could not be read at HEAD* leave the draft alone. Getting that mapping wrong on the last two would turn an internal mis-report into a request for human review of code no reviewer has read — SKILL.md step 4 states it, and that is where it is enforced.

### `fix_bar`, and the project description it sits beside

Step 5's second question is whether a finding is *worth acting on*, and it is asked against something. Without a statement of what this project is and what it counts as worth it, that question is asked in the abstract by a reader whose default disposition is to fix — which is how a run acknowledges 8% of what it is handed and reads every remaining round as obviously necessary.

Part of what is needed is **already published by the reviewed repo, on the runs where it published it**, so this key does not ask for it again. Skeptic's config carries five project keys — `project`, `users`, `irreplaceable_data`, `production_status`, `architecture` — answering *who hits this and what it costs them*, the half of question 2 a finding's own text cannot supply. **Where they come from, when they are there, and which layer's answer may be calibrated on is settled in `reference/evaluation.md`, which is the authority; what follows is a summary of it.** The clause worth repeating here: on no reviewer list does step 5 answer those five itself.

`fix_bar` is the part the five don't carry: the sentence about what a fix has to *buy*. The shipped default states the general rule this skill already follows —

> A fix is worth a round when leaving it costs more than the round costs: a wrong result on a path people reach, a boundary that lets through what it exists to stop, or a claim that tells a reader to stop looking. Correct-but-cornered is not, and neither is prose that is true and could be sharper.

— and a project overrides it with its own, in its own terms. The wording that motivated the key: *"find any code quality and code-breaking issues, incorrect documentation or comments, and otherwise fixable issues as long as that fix provides real value. Continuing to hunt down and kill every crazy edge-case — especially ones that can't actually even be reproduced with a shipping iPhone — chasing down perfection CANNOT be the goal."*

**It does not merge the way the five keys do, and the difference is narrower than it first looks.** The two stacks are analogous rather than shared — each has its own bundled defaults and its own optional `~/.claude/` file, in that skill's own name — and what differs is which *project* file wins — the **orchestrator** repo's for this key, the **reviewed** repo's for the five. On a cross-repo PR that means the bar is the caller's, which is the right way round for a key governing the author's own fix decision, and it is the opposite shape to `mark_ready_on_convergence` above, scoped *out* of cross-repo PRs precisely because it merges from the same place. The difference between them is that undrafting acts on the other repo's PR, while this only decides what you do with a finding.

**Three things it is not.** It is not a severity floor: `blocking_severities` still decides what must be fixed, it lives in the skeptic config, and no wording here can license leaving a `CRITICAL` or `HIGH` (`reference/evaluation.md` — `Acknowledge-no-change` is unavailable there, and that guard is upstream of this key). It is not an instruction to the reviewer, which reports everything real it finds regardless — this key governs what the *author* does with a finding, and the split is the point. And it is not context about the change: like the five keys beside it, it describes the project rather than the PR, and using it as a route to explain the change to a reviewer defeats what their blindness is for.

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

It also has a precondition a bot doesn't: the reviewed repo must have committed `allow_agent_posting: true` to its `.github/pr-review-skeptic.config.yml` — the five project keys have to be filled too, but those merge across that skill's layers and need not all come from the repo's own file. Without it an agent-invoked run posts nothing, and a loop whose reviewer leaves no trace on the PR cannot record decisions, cannot settle anything, and will run to the cap re-finding what it already answered. SKILL.md checks all of this at kickoff.

## Invocation modifiers — natural language, not flags

Parse intent; don't require precise syntax:

- "no iteration cap" / "until done" / "no max" → disable `max_iterations`. Say plainly what it removes: the only *bound* on the run. A round that changes no code is the intended exit, but it is a fixed point the loop may reach rather than one it is guaranteed to, and the cap is what stops a run that never gets there — and surfaces it as an outcome. Unsupervised, that is a loop that pushes and re-reviews indefinitely.
- "only copilot" / "without codex" / "skip the skeptic" → narrow `reviewers` for this run. Only changes who the loop *engages*; a reviewer that shows up via auto-trigger is still evaluated. **If the narrowing leaves the list empty, stop and say so** — don't run a loop with nobody in it (above).
- "just fix what's there" / "one pass" → triage what is already on the PR and stop: steps 1, 5, 6, 7, then **push without step 8's re-engagement**, and no wait, no step 4, no return to step 3. Step 8's two halves come apart here deliberately, and only the push runs. It makes no convergence judgement, so it reports its own outcome — *one pass; triaged what was already on the PR, no reviewer engaged, nothing has reviewed the new HEAD* — and never one of step 4's five, least of all *converged*. Re-engaging reviewers and then terminating would be worse than either: they post findings onto a PR this run has already stopped triaging, and the next run reads them as unresolved feedback of unknown provenance.
- A PR number, URL, or cross-repo reference → target specific PR(s) instead of auto-detecting.

Build command is not configured — detect the project's verify command at the commit step.

## Project-level *procedural* overrides (separate from config)

If the orchestrator repo has its own PR-review instructions that **contradict** this skill, defer to the project — assume the override is intentional. Check: `./.github/PR_REVIEW_LOOP.md`, `./CLAUDE.md` (PR-review section), `./AGENTS.md` (PR-review section), `./.cursorrules`, `./.claude/commands/pr-review-loop.md` / `./.claude/skills/pr-review-loop/`. Classify each difference:

- **Contradiction** = procedural disagreement (reply templates, escalation rules, rubric, resolve criteria). **Project wins.**
- **Addition** = non-contradicting delta (project build command, an extra lint rule, a preferred reply style). **Apply both.** (Reviewer selection is config, not a procedural addition.)
- **Unclear** = can't tell whether it's an intended override or just stale. **Ask the user.**
