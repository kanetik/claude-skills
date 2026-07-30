---
name: pr-review-loop
description: >-
  Iterative PR review loop with a strict role split: reviewers review and post
  their findings to the PR (AI bots like Copilot, and the pr-review-skeptic
  skill); this skill is the author, and the only thing that touches code. It
  reads every finding off the PR, decides each one (fix / reject with a public
  rationale / file a follow-up issue), replies, resolves the thread, pushes, and
  re-requests review — repeating until a round changes no code: nothing blocking
  left, and nothing fixed that a reviewer has not since seen. Self-contained and self-paces its polling waits.
  Auto-invoke immediately and WITHOUT asking permission right after a PR is
  created (gh pr create, a commit-push-PR flow, or equivalent), and when the user
  says "start a PR review", "respond to PR comments", "handle PR feedback", says
  they just opened a PR, or invokes /pr-review-loop. Accepts modifiers like "no
  iteration cap", "only copilot", or a specific PR number / URL / cross-repo
  reference.
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

Drives a pull request to convergence: engage reviewers → wait → evaluate → fix/answer → push → repeat, until every reviewer is satisfied.

## The role split

There is one loop and one path from a finding to its resolution, and the two roles never swap.

**The reviewer reviews. It never fixes.** It reads the code, finds what is wrong with it, and posts its findings to the PR as threads. That is the whole job. This holds for a review bot and equally for the `pr-review-skeptic` skill, whose blind reviewers are the strongest reviewer this loop has and still touch nothing.

**You are the author, and the only thing that touches code.** You read the findings off the PR, decide each one, apply what should be applied, answer what shouldn't, record the decision where the reviewer's next run will see it, push, and ask for review again.

Everything below is the mechanics of that. Two rules are worth stating before them, because most of the ways this loop fails are one of the two coming apart:

- **Every finding gets a decision, and the decision goes on the PR.** Not "the blocking ones" — every one. A finding you fix, a finding you reject, a finding you defer to an issue: each gets a reply saying which, and its thread resolved. That reply is not politeness. It is the only record the next round has that this finding was dealt with, and without it the next round finds it again, and the round after that.
- **If you changed code, it gets reviewed. No exceptions, and severity has nothing to do with it.** Severity decides what *must be fixed*. It never decides what must be *reviewed*. A round where you fixed only `MEDIUM` and `LOW` findings still moved HEAD, so that HEAD is unreviewed, and the run is not done — "the findings were non-blocking" is not a reason to skip review, it is a statement about the findings you were given, not about the code you then wrote. This is the rule the loop exists to enforce, and the one it is easiest to talk yourself out of at the end of a long run, because the remaining findings look small and the fixes feel obvious. The fixes that feel obvious are the ones that have been breaking things all along.

**So what does terminate it?** A round that **changes no code**. Fix nothing and there is nothing new to review, so the reviewer is satisfied — whether the round ended in rejections, deferrals, already-fixed replies, a re-answer of something you had already rejected, or a clean verdict. That is the fixed point, and it is a fact about the *diff*, not about severities. See step 4.

**Terminating is not the same as not answering.** Every finding in that last round still gets its reply, its marker and its resolved thread — the round terminates *because* answering them changed no code, not instead of answering them. A finding left unanswered is an undecided finding whatever else was true of the round, and leaving one on an unresolved thread under a summary that says *converged* is the worst of both rules.

This skill is self-contained. The files below live in this skill's own directory, beside this `SKILL.md` — read them from there (paths are relative to this file, not the working directory). Load on demand:

- [`config/defaults.yml`](config/defaults.yml) — config defaults.
- [`reference/configuration.md`](reference/configuration.md) — config keys, override model, invocation modifiers, project procedural overrides.
- [`reference/mechanics.md`](reference/mechanics.md) — tool tiers, the GraphQL/REST queries the loop needs, Copilot/Codex trigger mechanics, and how the skeptic reviewer is invoked and read.
- [`reference/evaluation.md`](reference/evaluation.md) — the step-5 lens rubric, courses of action, disposition replies, issue creation, reactions, resolve criteria.
- [`reference/waiting.md`](reference/waiting.md) — the step-3 wait: the polling model, re-entrancy, carried state, timeouts.

**Requires:** `gh` (authenticated), `git`. Bash forms also use `jq` (PowerShell forms don't). With `skeptic` in `reviewers`, also the **`pr-review-skeptic` skill**, installed and configured (Preconditions below). Optional: a GitHub MCP server; a scheduling primitive (`/loop`, `ScheduleWakeup`, `CronCreate`) for self-paced polling waits (feature-detected — degrades gracefully).

**Snippet convention:** `<...>` tokens (`<num>`, `<owner>`, `<repo>`, `<path>`, `<tmp>`) are placeholders you substitute with real values, not literal shell tokens.

## Reporting style — terse

Status during iterations and waits is one or two lines: "Iter 3 wait, Copilot still cooking, back in ~4 min." / "Iter 4: skeptic 2 HIGH, 5 MEDIUM — fixing 5, rejecting 2." / "All reviewers clean, terminating." Don't restate reviewer text the user can read on the PR. The final summary is short bullets, not paragraphs.

## Configuration (summary)

Read [`config/defaults.yml`](config/defaults.yml), then merge overrides per key, low → high: bundled defaults < optional `~/.claude/pr-review-loop.config.yml` < orchestrator repo's `.github/pr-review-loop.config.yml`. Defaults: `reviewers: [copilot]`, `auto_review_grace_seconds: 0`, `wait_check_cadence_seconds: 180`, `max_iterations: 10`. Parse natural-language modifiers from the invocation. Full model — including the retired gate keys and what to do with a config that still sets them: `reference/configuration.md`.

**One reviewer list.** `reviewers` is the set the loop engages: engaged when the PR is opened, re-engaged after every fix push, and the set convergence is gauged on. There is no second list and no out-of-loop role. A reviewer that shows up on its own — a bot that auto-reviews on push, a review the user posted themselves — is read and triaged like any other, but it isn't re-engaged by step 8 and doesn't hold the loop open.

**`reviewers` must be non-empty when step 2 runs — an invariant, not a one-time config check.** With nothing to engage, step 2 engages nobody, step 3 has nothing to wait for, and step 4 finds the empty set vacuously happy: the loop terminates instantly and reports *converged* on a PR no reviewer has looked at. A clean finish on an unreviewed PR is the worst thing this skill can produce, because it is indistinguishable from a real one. The list can reach empty by more routes than a bad config file — a modifier that narrows it ("only copilot" where copilot isn't configured, "skip the skeptic" on a skeptic-only list), your own offer to drop an unusable reviewer in Preconditions, or a reviewer **excused** mid-run, which is the one route that fires after step 2 is long past. **So it is checked twice: over `reviewers` before step 2, and over the *accountable* set at every step-4 evaluation** (the convergence invariant, step 4 — which explains why it must not be the active set). Empty at either → stop and say so, naming what emptied it; never fall through to a vacuous pass.

## Two kinds of reviewer, one role

An entry in `reviewers` is either a **bot** or **`skeptic`** (the sibling `pr-review-skeptic` skill). They do the same job and their findings are triaged identically; only how you engage them, and how you recognise their work on the PR, differ.

| | Bot (`copilot`, `codex`, any review bot) | `skeptic` |
|---|---|---|
| How it's engaged | Requested/triggered on the PR (`reference/mechanics.md`) | The `pr-review-skeptic` skill, invoked locally; it posts its own review |
| Waiting | Step 3 polling wait | None — it runs synchronously, and its review is on the PR when it returns |
| Recognised by | `author.__typename: Bot` | The `<!-- pr-review-skeptic -->` marker in the review body and every comment |
| Posts under | Its own bot account | **The user's account** — indistinguishable from a hand-written review except by the marker |

The last row is the one that breaks naive code. Skeptic's reviews are authored by a human account, so anything classifying reviewers by author type alone reads them as human participation and skips them entirely. **Check the marker before the author type**, everywhere disposition is derived.

**Skeptic must be able to post, or this loop does not work.** Its findings reach you as threads on the PR; those are what you reply to and resolve, and what its own next run reads to tell a settled decision from a fresh finding. An agent-invoked run posts only where the PR's repo has committed `allow_agent_posting: true` to its `.github/pr-review-skeptic.config.yml` **and** no layer sets `confirm_before_posting: true`, which reverts an agent-invoked run to no-post and so cancels the grant. The Preconditions check below tests both at kickoff rather than after the first round.

**Context discipline when invoking skeptic.** You have just read this PR's description, its threads, and possibly written its code — everything that skill exists to keep away from its reviewers, and the pile grows every round. Invoking it does not launder that: follow its **Context discipline** section exactly, which builds each reviewer's brief by substitution from project config and the diff and forbids adding a summary of the change, its purpose, or its rationale. Hand it the PR reference and nothing else — on round ten as on round one. A reviewer steered by your account of what the change does, or of what the last nine rounds already settled, is not an independent reviewer.

## Three sets, and they answer different questions

Keep these apart. Two of them are about *work still to do*; the third is about *who has to have signed off*, and conflating that one with the others is how a loop reports success on an unreviewed PR.

- **Tracked set** (permanent, PR-derived): `reviewers` ∪ every reviewer that has posted a review *or* a review-style verdict comment (findings or a clean pass, judged on content — not routine CI/noise). One joins the moment it does so and never leaves; it's the same on every wake.
- **Active set** (run-scoped): tracked minus reviewers already gone happy, minus any excused. This is **engagement bookkeeping only** — who still needs asking. The loop's own fix push re-engages `active ∩ reviewers`; a reviewer that showed up on its own isn't re-engaged, and already-happy ones are skipped. It shrinks as the run succeeds, and an empty active set is the *normal* end state of a good run.
- **Accountable set** (run-scoped): `reviewers` **minus any excused** — and nothing else. Going happy does *not* remove a reviewer from it; going happy is how a member *satisfies* it. This is the set convergence is judged over (step 4), and it is deliberately insensitive to the loop's own progress: what it asks is "did everyone who was supposed to review this actually review it", which is a question the active set cannot answer because the active set empties precisely when they have.

Membership in tracked/active is decided by **what posted, not who**: a bot (`__typename: Bot`), or a review carrying the `<!-- pr-review-skeptic -->` marker. A genuine human reviewer is in none of the three — the loop reads their comments as evaluation input (step 5) and never re-pings them. Neither the active nor the accountable set is recorded on the PR as such, so a context-less wake reconstructs both from the carried wake payload — see `reference/waiting.md`.

## Reading reviewer state — three surfaces

A reviewer's disposition can surface on any of three channels; always read and union all three — never derive state from reviews alone (a clean verdict sitting in an issue comment, misread as "still reviewing", is the classic failure that strands the loop):

1. **Formal reviews** — `Review` objects and their bodies.
2. **Review threads** — inline and file-level comments.
3. **PR issue comments** — some reviewers post findings, or their whole clean verdict, only here.

**Judge disposition from what the reviewer wrote, not a fixed phrase list** — has findings, happy (a clean pass), or work-in-progress, reading the meaning as a person would; the next new bot will word it differently again. **Staleness:** only signals at/after the most recent push count for the current HEAD — a pre-push clean verdict is stale; re-derive against HEAD. Re-derivation applies only to reviewers **still in the active set**: a bot already dropped happy is not pulled back when a loop fix makes its verdict stale (only an external push or a manual re-request re-engages it — step 4). Skeptic never drops, and step 4 says why.

## Preconditions

- **Find the target PR(s).** Read the branch: `branch=$(git branch --show-current)`. Non-empty → `gh pr list --head "$branch" --json number,title,url` (quote it). Empty (detached HEAD — CI/automated runs) → match by commit: `gh pr list --search "$(git rev-parse HEAD)" --json number,title,url`. Zero matches and none specified → surface it. Multiple → ask which.
- **Cross-repo PRs** are allowed in any phrasing (URL, sibling name + number, `owner/repo#num`). Resolve to `(owner, repo, number)` and pass `--repo` to every `gh` call for that PR. **At least one PR in the run must be in the orchestrator repo** (the working directory's repo) — else ask the user to add one or confirm.
- **Working tree must be clean** and `gh` authenticated.
- **A configured `skeptic` reviewer must be usable** — check at kickoff, not at first use, so a run that can't review says so at the start rather than after the first wait. Three things can be missing (the checks themselves: `reference/mechanics.md`): the **skill** isn't installed; **any one of its five project keys** is still empty once its own config layers are merged (all five must hold a value — a layer that fills three leaves it as unusable as one that fills none), because an agent-invoked run does not interview for them and instead stops and hands back what's missing; or **an agent-invoked run won't post** — either the PR repo hasn't committed `allow_agent_posting: true`, or `confirm_before_posting: true` is set in some layer and cancels it. Say which it is, and offer the options that fit: add the missing config to the PR repo's `.github/pr-review-skeptic.config.yml`, or — **only if another reviewer would remain** — drop `skeptic` from `reviewers` for this run. Where skeptic is the *only* reviewer, dropping it is not on offer: it empties the list and the loop would terminate reporting a converged run on an unreviewed PR (the invariant above). There the options are fix the config, add a bot, or don't run. Don't guess project facts on the user's behalf either — five invented answers steer the reviewer that is supposed to be the independent one.

  The posting check is the one worth being blunt about, because the run *looks* fine without it: skeptic returns a full review to you, you fix what it found, and nothing is ever recorded on the PR — so its next run's blind pass re-finds everything you rejected, its cross-check has no threads to settle them against, and the loop grinds to `max_iterations` re-litigating the same findings every round. If the user wants to proceed anyway, proceed, but say that is what will happen.

  This check is kickoff work: it runs once, not on every wake.

Run `git fetch && git pull --ff-only` before each iteration's analysis. Run multiple PRs concurrently only if your scheduler supports it, each in an isolated working directory (separate `git worktree`/clone) to avoid state collisions.

## The loop

### 1. Initial state check
Gather from the PR (queries in `reference/mechanics.md`): unresolved review threads (paginated; inline + file-level); all reviews with state, body, `submittedAt`, author type **and body marker**; PR issue comments with bodies + timestamps; the most recent push timestamp (latest of `HeadRefPushedEvent`/`HeadRefForcePushedEvent.createdAt` — force-pushes count; NOT `committedDate`); the PR's `createdAt` (iter-1 grace baseline); and `reviewRequests` via GraphQL (NOT `gh pr view --json reviewRequests`, which drops bots).

Then branch:

- **Any unresolved feedback** — unresolved threads (inline AND file-level), an unaddressed concern in any review body, OR a review-style comment raising unaddressed concerns → **jump to step 5**, skipping steps 2–3.
- **Else** → **step 2** (grace window; engage reviewers that haven't already covered this commit) → **step 3** (wait). No push here.

**One iteration is one pass through 3 → 4 → 5 → 6 → 7 → 8**, and the counter (step 9) increments once at the end of it, after the push. A round in which step 4 finds everyone happy ends the loop instead and increments nothing. Waiting never counts.

### 2. Engage reviewers
Same flow on iteration 1 and after every push (called from step 8). Mechanics: `reference/mechanics.md`.

1. **Wait `auto_review_grace_seconds`** from the baseline: iter 1 = `max(PR createdAt, latest push event)` (some auto-triggers fire on PR open even when the branch was pushed earlier); iter 2+ = the most recent push event. Default `0` = no wait. Skeptic ignores this — nothing auto-triggers it, so there is nothing to wait out.
2. **Determine the engage set:** `active ∩ reviewers`. An **external** push (new commits lacking a `PR-Review-Loop` trailer — code no reviewer has seen) is the exception: rebuild the active set from the tracked set and re-engage **`(tracked − excused) ∩ reviewers`** — which brings back previously-dropped-happy configured reviewers, and only those, since no prior verdict covers code nobody has seen (`reference/waiting.md`). Excused reviewers stay out: they never left `tracked`, so an intersection that forgets them re-engages a reviewer that already could not run, buying another timeout and the same question on every external push. Still intersected with `reviewers` too: an uninvited reviewer is never re-engaged, on an external push as on any other, and re-engaging one would mean invoking a reviewer the config never asked the loop to drive — for `skeptic` that is a worktree and up to `max_reviewers` subagents, posting under the user's account, on every external push.
3. **Skip any that has already covered the current commit** — started reviewing it or already delivered a verdict for it (evaluate at/after the most recent push across all three surfaces, plus the loop's own trigger). Copilot = a `reviewRequests` entry (presence means already-requested, so skip; `reviewRequests` carries no timestamp — when the loop owns push→request ordering that presence implies at/after the push, otherwise compare the timeline `ReviewRequestedEvent.createdAt` against the latest push). Codex = a `chatgpt-codex-connector` post OR an existing `@codex review` trigger at/after the push. **Skeptic = a review carrying the `<!-- pr-review-skeptic -->` marker submitted at/after the push** — the check that makes a re-entered wake idempotent instead of dispatching a second eight-reviewer pass over a commit already reviewed. Where the PR has no push event at all (the branch was pushed before the PR was opened), compare against the iteration-1 baseline from step 1 rather than treating "no push" as "nothing counts".
4. **Engage each one not skipped.** A bot is requested or triggered. Skeptic is invoked — the `pr-review-skeptic` skill, given the PR reference and nothing else, which reviews HEAD and posts its findings itself. Don't tell it not to post; whether it may is the repo's committed answer, not yours to assert either way (`reference/mechanics.md`).
5. Proceed to step 3.

**Never auto-re-ping a human.** A person who commented on the PR is not re-requested by this loop; their input is read in step 5 and weighed there. Skeptic is not covered by that rule despite posting under a human account — it is a reviewer this loop drives, identified by its marker, and re-engaged on every push like any other.

### 3. Wait for new reviewer activity
**Only bots are waited on.** Skeptic runs synchronously — its review is on the PR by the time it returns — so it is never pending. Where `reviewers` has no bot in it, **there is no wait at all**: step 2 comes back with the round's findings already in hand and you go straight to step 4. A wait armed for a set with nothing pending in it never ends.

For bots: **poll on a timer — no events reach a local terminal to wait on.** A local terminal can't *receive* GitHub webhook/event deliveries, so the loop drives itself: schedule a self-wake every `wait_check_cadence_seconds` (default 180s; recommended band 120-240s, i.e. every 2-4 min) and reconcile on each tick. Arm the best self-wake available: (a) a scheduling primitive — `/loop <cadence>`, `ScheduleWakeup`, `CronCreate` — carrying the continuation payload, else (b) a background polling monitor that fingerprints head-commit/reviews/comments/CI/merge state and emits on change — auto-waking you only where the host turns that background output into a re-invocation (in a plain terminal it just notifies a human, so fall through to c), else (c) a single-pass hand-back ("re-invoke `/pr-review-loop` to continue"). Never **foreground**-`sleep` busy-wait — that blocks the turn instead of yielding. Re-arm on every wake until the PR is merged or closed. End the turn. On every wake, re-pull and do a full three-surface reconciliation against HEAD before concluding anything — the PR state is ground truth. Make every wake idempotent — reconstruct loop state from the PR plus the carried payload. Waiting does NOT count toward `max_iterations`. Full model, ladder, polling snippet, the `--repo` gotcha, lockstep, re-entrancy, and carried state: `reference/waiting.md`.

### 4. Detect "this reviewer is happy"

**Two conditions, and they do different jobs. Both must hold.**

1. **Nothing left at or above the blocking severities** — not nothing left at all. A reviewer whose latest verdict carries three `MEDIUM` observations and no `CRITICAL`/`HIGH` has nothing *blocking*. Hold out for an empty verdict and the loop never ends: a reviewer that reports everything real it sees, with no floor, always sees something.
2. **The current HEAD has been reviewed.** If the round that dispositioned those three `MEDIUM`s *fixed* any of them, HEAD moved and nobody has looked at it. That round is not terminal, however small the fixes were — push and go round again.

Condition 1 is about the findings you were handed. Condition 2 is about the code you wrote in response, and it is the one that gets skipped, because at the end of a long run the remaining findings look minor and the fixes feel safe. Six rounds of this loop's own history say fixes are where the defects come from, and the smallest-looking round is not exempt.

**What actually terminates the loop is a round that changes no code.** Reject, defer, reply already-fixed, or find nothing — any of those leave HEAD where it was, so there is nothing new for a reviewer to see and the reviewer is satisfied. A round whose findings are only re-raises of things you have already rejected on the record terminates too: the reviewer said nothing new, and re-answering it would just be the previous round again. Terminating is a property of the diff, not of the severities.

Which severities block is `blocking_severities` in the skeptic config (`[CRITICAL, HIGH]` by default), and the equivalent judgement for a bot that doesn't tag severities: does its latest verdict raise anything that would change the code on a path users reach, or is it down to polish? Read it as a person would.

For each reviewer **still in the active set**, all must hold:
- Zero unresolved threads attributed to it that carry a **blocking** finding. A non-blocking thread left unresolved does not by itself hold the loop open — but step 5 requires every finding be dispositioned and resolved, so in a round done properly there are none. It is never a licence to leave findings unanswered and call the round terminal.
- Its latest verdict *for the current HEAD* (formal review/body or an issue comment) names no blocking finding — judged from what it wrote per "Reading reviewer state."
- That signal is at/after the most recent push.

A reviewer that posts **no formal review** can still be happy on a clean issue comment alone — exactly the case a reviews-only check misses.

**A `settled` blocking finding does not hold the loop open, and does not disappear either.** Skeptic's cross-check moves a finding to `settled` when a prior thread weighed the same consequence and the project chose otherwise — which includes a rejection you wrote and a concern you deferred to an issue. Those are decisions, and re-litigating them is what a loop with no memory does. So they don't block. But a *blocking* one still appears in skeptic's verdict with its count and the thread that decided it, and it belongs in your final summary the same way. You are judging your own work here, and the only thing between that and a loop you converge by rejecting everything is that a settled `CRITICAL` stays visible. Never let settled become silent.

This subsumes the old all-rejections short-circuit and replaces it: it does not matter what mix of no-op courses the round took, because none of them changes the code the verdict was about. Any course that actually edits code does change it, so the round pushes and the reviewer looks again.

**A reviewer the user excuses leaves the run.** Two places offer that — an unresponsive bot (`reference/waiting.md`) and a skeptic round in which no unit got reviewed (`reference/mechanics.md`) — and the offer is empty unless something acts on it, since a reviewer otherwise leaves `active` only by going happy. So: when the user says to skip or proceed without one, **drop it from `active` for the rest of the run**, exactly as a happy reviewer is dropped but for the opposite reason. It is not re-engaged by step 8, it **ends any wait pending on it** (`reference/waiting.md` lockstep), and it is named in the final summary as **excused, not reviewed** — never folded in with the happy ones.

**Excusing the last reviewer is not convergence.** Excusing is the one thing that removes a reviewer from the **accountable** set, and an excused reviewer is one that did *not* review — so where excusing it would empty that set, the invariant fails and the run reports *nobody reviewed this HEAD*. Say that when you make the offer, so the user is choosing between a review and no review rather than appearing to pick between two ways of finishing.

Carry the excused set in the wake payload alongside the dropped-happy set. **An external push resets the dropped-happy set but not the excused set:** a happy verdict is genuinely stale against code nobody has seen, whereas a reviewer that could not run does not become able to run because the diff changed — re-engaging it buys another twenty-minute timeout and the same question. Re-offer it if you like; don't re-arm the wait.

**Happy is sticky for a bot, never for skeptic.** Once a bot goes happy it leaves the active set for the rest of the run (it stays in the tracked set as history) — not re-requested, not re-evaluated — and this holds across the loop's own follow-up commits even as its clean verdict goes stale. Exactly two things bring it back: the user manually asking for it, or an **external** push (`reference/waiting.md`). **Skeptic never drops.** It is re-invoked on every fix push for as long as the loop runs, because reviewing what the fix rounds produced is the largest part of its value: the code with the least review behind it is the code written last, under the most accumulated confidence about why it's right. A clean skeptic verdict on round 4 says nothing about round 5's fix.

**The convergence invariant — judged over the accountable set, never the active one.** Before reporting *converged*, both of these must hold:

- **The accountable set is non-empty.** "Everyone is happy" is vacuously true of nobody, and three things can empty it: a modifier that narrowed `reviewers` to nothing, an unusable `skeptic` dropped at kickoff, and every member being excused.
- **Every member has a happy verdict** — and for every member **still in the active set**, that verdict is at/after the most recent push. A fix push no active reviewer has looked at is the state this whole skill exists to keep from being called done.

  The staleness half is scoped to the active set for the same reason re-derivation is ("Reading reviewer state"): a bot that went happy **left** the active set by design, is deliberately never re-requested, and its clean verdict is *expected* to go stale as later rounds push. Demanding a current-HEAD verdict from it asks for something stickiness forbids the loop to obtain, so a `[copilot, skeptic]` run where Copilot went clean early could never converge no matter what skeptic said. A dropped-happy reviewer's stale verdict satisfies this clause; that is what dropping it means. If you want it to re-review, the ways to bring it back are in step 4's stickiness rule, and doing so puts it back in `active` where the staleness half applies again.

Fail either and it is **not** convergence. Report it as its own outcome — *nobody reviewed this HEAD* — naming the last commit and why the set is empty or unreviewed. This is the one mis-report nothing downstream recovers from, because a converged verdict is exactly what a reader stops checking.

**Do not state this over the active set.** A happy reviewer *leaves* the active set, so `active ∩ reviewers` empties on success: an invariant demanding it be non-empty would declare every successful all-bot run unreviewed, and make convergence unreachable for any list without `skeptic` in it (skeptic being the one reviewer that never drops). The active set tracks who still needs asking; the accountable set tracks who had to answer. Only the second is a convergence question.

**Terminal states, reported differently.**

1. **Converged** — the invariant holds. Disposition and resolve any remaining non-blocking findings in the terminating verdict first (below), then go to the final summary.
2. **Paused for your answer** — the only things still holding the loop open are `Ask-user` findings, or threads awaiting a human reply. Nothing the loop can do advances those: it cannot decide them, and a round that changes no code re-derives the same question next time round. **Stop and ask, rather than iterating.** Report it as paused, list the open questions with their threads, and say what is already settled. This is not a failure to converge, and reporting it as one buries a question behind a word that reads like a bug. Iterations spent spinning on an unanswerable finding are iterations the loop does not have.
3. **Cap reached** — `max_iterations` exhausted with blocking findings outstanding (step 9).

**The terminating round still dispositions its own findings.** Terminal state 1 goes to the summary without passing through step 5, so the findings in the verdict that *ended* the loop — a clean pass carrying three `MEDIUM` nits, typically — would never get a reply or a resolved thread. That is the commonest terminating round there is, and leaving it undispositioned breaks the rule this skill leads with: every finding gets a decision. So before the summary, run step 5's recording half over them — reply, disposition marker, resolve.

**In that pass the courses are `rejected`, `deferred`, and `Ask-user`.**

`Ask-user` has to be available, because the findings arriving in a terminating verdict are subject to the same default as any others: security/auth-adjacent, scope-boundary, conflicting and architectural calls go to the user. Without it, a security-adjacent `MEDIUM` in the last verdict would have to be stamped `rejected` and resolved — after which the next run's cross-check reads that thread, buckets the finding `settled`, and it neither blocks nor re-raises again. A question the skill mandates escalating would be decided unilaterally by the author of the code and permanently suppressed. So leave that thread open and unmarked, name it in the summary under threads left open, and **report the run as terminal state 2 (paused) rather than 1** — an open question is an open question whether or not the finding was blocking.

The other two courses: It commits and pushes nothing, so it cannot fix anything: stamping `disposition=fixed` on a finding you did not fix hands the next round's cross-check a `fixed` marker on a defect still present at HEAD, which is the definition of `unfixed` and comes back a severity higher. And fixing it anyway leaves an edit either uncommitted (tripping the next run's clean-tree precondition) or pushed after convergence was declared, unreviewed. **So a non-blocking finding you judge worth fixing means the round is not terminal** — go through 5→6→7→8 normally and let the reviewer see the result. `reference/evaluation.md`'s "take the cheap correct ones now" is that path, not this one.

**A reviewer that turned up uninvited is not accountable.** It is triaged in step 5 like any other, but it is not in `reviewers`, so step 8 never re-engages it and its verdict goes stale at the first fix push with nothing able to refresh it. Requiring it to be happy means the loop cannot terminate at all — it runs to the cap reporting an unhappy reviewer nobody asked for and nobody can satisfy. The commonest instance is the user running `/pr-review-skeptic` themselves mid-loop.

**A reviewer whose blocking findings have all been dispositioned is happy, even with no new verdict.** The second and third conditions above ask what its *latest verdict* says, and a round that decided every finding without changing any code — all `Reject-with-explanation`, all `Create-issue-and-close`, or a mix — moves neither HEAD nor the verdict. Step 6 commits nothing, step 8 pushes nothing, and step 2's skip check then skips the reviewer because its existing review is already at/after the (unmoved) push. Read literally, that reviewer is unhappy forever over findings you settled in round one, and the loop spins out its remaining iterations doing nothing.

So: **a blocking finding you have dispositioned and resolved on the PR no longer holds the loop open** — whatever the disposition — exactly as a `settled` one doesn't. It has been decided, and there is nothing left for the reviewer to look at again. It is still reported: it goes in the final summary with its count and its thread, under the same rule that keeps a settled `CRITICAL` visible.

The test is **whether HEAD moved, not which course you took.** `rejected` and `deferred` never move it. Neither does the third no-op course, which is easy to miss because it wears a `fixed` marker: *already-fixed*, where you reply that an earlier round handled the finding and resolve the thread (`reference/evaluation.md`). A round of nothing but already-fixed dispositions produces no commit and no push, so a rule phrased as "only `Fix-*` needs a re-review" leaves it unable to converge — the reviewer's verdict still names the finding and nothing can refresh it. Only a course that actually changed HEAD needs the reviewer to look again.

### 5. Evaluate each finding, and record the decision
Threads are the unit of evaluation; also read each review's body, and read human replies as evaluation input (not a post-hoc check). Hold the weighted project/PR/item lenses + mindset as one integrated judgement for the triage. **Then, when writing the fix, apply the same three lenses in order — project, then PR, then line** (`reference/evaluation.md`): a suggested fix that fails at the project or PR level is not the fix, and where the reviewer suggested nothing, start at the project lens rather than reaching for the smallest edit that makes the finding go away. Courses: `Fix-as-suggested`, `Fix-differently`, `Fix-broader`, `Already-fixed`, `Reject-with-explanation`, `Create-issue-and-close`, `Ask-user`. Default to `Ask-user` for security/auth, scope-creep boundaries, conflicting asks, big architectural feedback. **The loop's own defects mostly arrive *in* fixes**, so on any fix with behavioural content — which includes a rule written in prose, where the prose is what an agent executes — write against the invariant rather than the reviewer's scenario, **grep out every other place that rule is stated and fix the stale restatements in the same commit**, treat a third patch on one rule as a sign to restate the rule instead, prefer the seam the codebase already has, and confirm the fix didn't weaken a test. Full checks: `reference/evaluation.md`.

**Every finding gets a course, and every course gets posted.** Reply on the thread saying what you decided and why, stamp the reply with the disposition marker, and resolve the thread. Not only the blocking ones: a `MEDIUM` you silently leave alone is a `MEDIUM` the next round finds again, and the round after that — and that is what turns a four-round loop into a fifteen-round one. A finding that arrived with no thread — one skeptic could not anchor, or a concern a bot left in its review body — is dispositioned in a PR-level comment instead, which is the only place the next round can read it.

A rejection is **public and specific**: the rationale goes on the thread, where the next round's cross-check reads it and buckets the finding settled rather than re-raising it, and where a person can disagree with you. "Rejected" with no reasoning settles nothing and deserves to come back.

Full rubric, the disposition markers and their exact form, the threadless-findings comment, issue creation, reactions, and resolve criteria: `reference/evaluation.md`.

### 6. Commit changes
One commit per logical group of fixes. Build first if any non-doc code was touched (detect the project's standard verify command) — **never commit red**. Defer commit mechanics to the host (`commit-commands:commit` skill if installed; else plain `git commit`). Keep messages tight. **Stamp each loop commit with a `PR-Review-Loop: <N>` trailer** (`<N>` = current iteration) — a standard `Key: value` git trailer. A context-less wake reads the iteration floor off the highest `<N>`, and the trailer's presence is what tells the loop's own commits from external pushes.

### 7. Update PR description if it has drifted
If this iteration's commits made the description inaccurate, update it — **surgical edits only**, change only affected sections. Use `--body-file` to avoid shell-escaping issues:

```bash
gh pr view <num> --json body --jq '.body // ""' > <tmp>/pr-body-<num>.md  # --jq outputs raw; // "" guards a null body
# edit surgically
gh pr edit <num> --body-file <tmp>/pr-body-<num>.md
```

### 8. Push + re-engage reviewers
**Push first, then check the cap, then re-engage.** The two halves of this step are separable and the cap goes between them: re-engaging on the round that exhausts `max_iterations` solicits reviews the run will never triage — on a skeptic reviewer that is up to `max_reviewers` subagents dispatched and their findings posted to the PR moments before the run stops, absent from the cap report and orphaned for the next run to puzzle over. So **where the round just completed is the `max_iterations`-th** — i.e. the counter's current value, before step 9's increment, equals the cap — push and go straight to the cap report. Compare the pre-increment value: the counter names the *current* iteration (step 6 stamps it, and a wake resumes at `<N>+1`), so testing the post-increment value against the cap spends only nine of a configured ten rounds, and only one of a configured two.

Otherwise: `git push`, then run the step 2 flow to re-engage **every** not-yet-happy reviewer (`active ∩ reviewers`) — *all* of them, not just the ones whose feedback you addressed this round. Mandatory on every round that changes HEAD. A reviewer converges only by re-reviewing the new HEAD, so re-engaging the unsatisfied ones is exactly what lets the loop reach "everyone happy" (step 4) — skip it and the loop strands, waiting forever on a reviewer that was never asked to look again.

The step 2 flow waits the grace window, then applies its own per-reviewer skip check: one is skipped when it has already covered *this* new commit — an outstanding review request, an in-progress review, or a delivered verdict, all judged **at/after this push**. The point that makes the re-engagement fire: a verdict from before the latest push is **stale and does not count** (per "Reading reviewer state") — that reviewer still needs to see the new HEAD. Already-happy bots stay dropped. Skeptic is re-invoked on every push — but note the condition is *a push*: a round that dispositioned everything without changing code leaves HEAD where it was, so the skip check correctly skips it and step 4's disposition rule is what closes that round instead.

### 9. Iteration counter, and running out of them
Increment — once per completed round, at the end of step 8 — then return to step 3.

`max_iterations` is **load-bearing here, not a backstop.** With no severity floor on what a reviewer may report, and no guarantee that a round produces fewer findings than the last, nothing in the loop's own logic makes it terminate — the cap is what does. Expect to reach it sometimes, and treat doing so as a real outcome rather than an error:

**On reaching the cap, stop and report it as a named outcome:** the loop did not converge; here is the iteration count, the reviewers still unhappy, every blocking finding outstanding with its thread, and what the last round changed. Then ask the user whether to continue, stop here, or drop a reviewer. Don't silently keep going, and don't round "cap reached, two HIGHs outstanding" up to a clean finish — it is the opposite of one. (Skip the cap entirely if invoked with "no iteration cap"; the outcome then is that the user asked for it.)

The counter is the one piece of loop state with no PR backstop, so it **must ride in the wake payload** (with any active modifiers); a context-less wake with no carried counter derives a floor from the highest `PR-Review-Loop: <N>` trailer and resumes at `<N>+1`. Mechanics: `reference/waiting.md`.

## Final summary report

When the loop terminates, summarize concisely:

- **How it ended** — one of four, and say which: *converged* (the invariant holds, every accountable reviewer happy); *paused for your answer* (open `Ask-user` questions, listed); *cap reached* (the count, and what's outstanding); or *nobody reviewed this HEAD* (the convergence invariant failed — name the last commit and what left the accountable set empty or unreviewed). Never round the last three toward the first: a converged verdict is the one a reader stops checking.
- **Any reviewer excused** — one the user skipped, or one whose round reviewed nothing. Name it as unreviewed. It never counts toward "every reviewer happy", and a converged verdict that quietly rests on an excused reviewer is the same mis-report as a clean verdict on an unreviewed PR.
- Commits made (sha + one-liner each), and follow-up issues created with reasons.
- **Findings you rejected, and blocking findings that came back `settled`** — with counts and threads. This part isn't optional. You were both the author and the judge of every rejection in this run, and this is where that gets shown rather than buried. A settled `CRITICAL` is a decision somebody made to ship a known defect; say so plainly.
- Any coverage caveat a skeptic run reported — units left unreviewed, a cross-check that didn't run. Those qualify a clean verdict and survive nowhere else.
- Threads left open for discussion, and anything else for user attention.
