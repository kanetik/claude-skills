# Evaluating reviewer feedback (SKILL.md step 5 detail)

## What to read

**Threads are the unit of evaluation.** Fetch unresolved review threads with full comment lists via paginated GraphQL (`reference/mechanics.md`); they cover inline AND file-level comments (`line: null`) and carry the conversation context (human replies, and your own dispositions from earlier rounds) the per-review REST endpoint omits. **Also read each review's `body`** separately — reviewers put findings, qualifiers, or "no issues" there with no thread, and a skeptic body additionally names the findings it could not anchor, which exist nowhere else. **And read PR issue comments** — the third surface (SKILL.md "Reading reviewer state"); some bots deliver findings or their whole clean verdict only here. Any state check must union all three. (The REST endpoint `/repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` is a convenience for one review's comments by ID; for the whole-PR view, paginated `reviewThreads` is canonical.)

**Human replies are evaluation INPUT, not a post-hoc check.** Read replies from the author/maintainers BEFORE forming your evaluation — they often steer ("we're doing it this way because…", "ignore for now", "fix narrowly, broader cleanup is tracked elsewhere") and weigh heavily, often decisively. If a human reply directly conflicts with the lens-weighted evaluation (reply says "ignore" but lenses say it's a real project-breaking bug), surface the conflict — don't silently obey or override.

## The integrated judgement

Hold three lenses and the mindset as a **single integrated judgement**, not a sequential rubric, with human replies as weighted input. That is for *triage* — deciding whether a finding is real and which course it takes. **When you come to write the fix, the same three lenses are applied in order instead**, top down: see "Writing the fix without causing the next finding" below. The two are not in tension: one weighs a decision, the other sequences a construction, and the ordering is what keeps a fix from serving the line at the project's expense.

**Lenses (most → least important, all in play at once):** what's best for the **project as a whole** (most) · the **PR overall**, including its larger intent (slightly less) · the **specific item** on its own (slightly less again).

**Mindset:** Steelman the reviewer's underlying concern — their suggested fix is one possible response, not necessarily the best; separate "is there a real issue?" from "is their fix the right one?" The decision space is broader than {accept their fix, reject}. Don't get into pissing contests or be defensive about prior choices; equally, don't capitulate to taste asks when the lens-weighted view says the code is correct. `Reject-with-explanation` is for "concern understood AND lenses support the current code" — not stylistic disagreement.

## Is the problem real, and is it ours?

Two questions, in that order, before any course is chosen. They are what separate a round worth running from a round that manufactures work, and neither is a question about severity.

**1. Is the finding correct, and is the problem real?**

Correct and real are different, and treating them as one predicate is the single largest source of churn this loop produces. A reviewer with no severity floor is usually correct — correctness is not the bar, because an adversarial reader of code, and far more so of prose, can always say something true. The bar is whether there is a **problem**: the code does something wrong, a claim about it is false, or a real cost lands on someone.

- **Materially wrong** — someone relying on this gets a wrong answer, is led toward reintroducing a defect, or pays a cost you can name. A real problem.
- **Not quite right** — imprecise, incomplete, could be phrased better, could assert more. Correct, and not a problem.

**Comments, tests and PR descriptions need to be correct, not perfect**, and that is where the worst churn lives. A comment asserting something false is a real problem: a confident claim beside subtly wrong code tells every later reader to stop looking. A comment that is true but could be sharper is polish — and polishing it costs a round, which owes a review, and the reviewer of the rewrite will find something true to say about *it*. Prose has no falsifier: a wrong line of code can be pinned by a failing test, so the reviewer is one check among two, but a wrong sentence has only the reviewer. That asymmetry is why this floor has to be applied here, by the author, rather than hoped for from the reviewer.

**2. Is it related to what this PR is doing?**

Not "did the diff touch this line" — is it part of the job this change came to do. A defect this change is responsible for is related even where the line predates it (a change that makes a broken path newly reachable owns that path). Work the change merely happens to sit near is not.

**First ask whether HEAD still has it.** A reviewer re-raising a finding against stale code is `Already-fixed` — reply naming the commit, stamp `disposition=fixed`, resolve. The table below has no row for it, and both routes through it record something false: `acknowledged` says the defect is there and being lived with, `rejected` says the code was kept as-is on the merits. Either one lies to the next round's cross-check and inflates a count a reader is told to audit your judgement by.

| Correct? | Real problem? | Related? | Course |
|---|---|---|---|
| Yes | Yes | Yes | **Fix it** — cost shapes *how*, never *whether* |
| Yes | Yes | No | `Create-issue-and-close` |
| Yes | No — correct, not a problem | — | `Acknowledge-no-change` — **but not at a blocking severity**; there, `Reject-with-explanation` on the merits or `Ask-user` |
| No | — | — | `Reject-with-explanation` |
| — | Uncertain, security/auth, architectural | — | `Ask-user` |

**Severity is not one of the two questions, and it still closes one course.** It does not decide whether a problem is real — that is the first question, and a `HIGH` you judge immaterial is still answered by the first question. What it decides is which courses remain: at a blocking severity `Acknowledge-no-change` is unavailable, because a run that converges by agreeing with a `HIGH` is the outcome the course's bar exists to forbid. Stamping `rejected` on a finding you agree with is not the way out either — that puts a false statement in the record. Where you genuinely think a blocking finding is immaterial, that is an `Ask-user`.

**A real, related problem gets fixed in this PR.** Deferring it is not on the table. What merges should work, and an issue filed against a defect this change is responsible for is that defect shipping with a note attached. `Create-issue-and-close` means one thing — work that is genuinely not what this PR is about — and every use outside that meaning trades a bounded round now for an unbounded backlog later. If issues are opening faster than they close, this is the leak.

**Cost to own is a question about the fix, not about whether to fix.** Ask it, because it goes unasked and it is where the loop's worst rounds come from: a fix cheap to *write* and expensive to *own* — one boolean on a stateful object, one latch, one exception to a general rule — lands among lifecycle, concurrency or caching neighbours and produces defects for three rounds afterwards. The answer changes the fix's **shape**: revert rather than patch, restate the rule rather than add the exception, take the seam that already exists. Only a genuinely ridiculous cost changes the *decision*, and then the course is `Ask-user`, never a quiet deferral.

## Courses of action

`Fix-as-suggested` · `Fix-differently` (better way to address the same concern) · `Fix-broader` (the real issue is bigger) · `Already-fixed` (an earlier round handled it and the reviewer re-raised it against stale code — reply naming the commit, stamp `disposition=fixed`, resolve; changes no code, so it is one of the four no-op courses) · `Acknowledge-no-change` (correct, and not a problem worth changing — reply agreeing, stamp `disposition=acknowledged`, resolve; changes no code) · `Reject-with-explanation` · `Create-issue-and-close` (real, and genuinely not what this PR is about — NOT "broken, fix later") · `Ask-user` (genuinely uncertain).

**`Acknowledge-no-change` and `Reject-with-explanation` are not interchangeable, and the reply says which.** Reject asserts the reviewer is wrong or the code is right as it stands. Acknowledge says the reviewer is right and this is not worth changing. Writing "rejected" over a finding you know is correct puts a false statement in the record the next round reads, and hides the count of things you agreed with and declined — which is exactly the number a person reviewing your judgement needs to see.

**`Acknowledge-no-change` is not available at a blocking severity.** A `CRITICAL` or `HIGH` is a real problem by definition, so it ends at fixed, `Create-issue-and-close` (only if genuinely unrelated), `Reject-with-explanation` on the merits, or `Ask-user`. The course is a licence to stop polishing, not a licence to converge by agreeing with everything.

**Default to `Ask-user` for:** security/auth-adjacent changes; relatedness boundary calls; conflicting reviewer asks; big-impact architectural feedback; a fix whose cost to own looks ridiculous.

## Whose code is this finding about?

By round six a reviewer reading HEAD is mostly reading **your repair work**, not the change the PR came to make. It cannot know that — its blindness is the point — and nothing tells you either unless you look. So look: it is one cheap lookup and it changes the triage.

Blame the line the finding names, find the commit that introduced it, and read whether that commit carries a `PR-Review-Loop: <N>` trailer (SKILL.md step 6 stamps every loop commit with one). Three answers:

- **original** — the change under review. Normal triage.
- **repair** — code this loop wrote in an earlier round. The finding is a defect in a fix, so re-open the question that fix was answering rather than patching the new instance. See the revert lever below.
- **pre-existing** — neither the PR nor the loop touched it. Strong evidence for *unrelated*, and the commonest thing a long run gets wrong in the other direction: after five rounds patching one subsystem, a sixth finding in that subsystem reads as the fifth defect in your own latch when it is actually a defect that predates the change and that your fix never covered. Ripping out the fix then re-opens the window the finding is about. **Evidence, not a verdict** — a change that makes a broken path newly reachable owns that path, and the best single finding in this loop's recorded history was exactly that shape.

Provenance is also the round-level signal that the work has changed character — **but only when computed over reviewers who could have found something else.** A reviewer scoped to what changed since the last review is reading the loop's repair commits *by construction*, so a share taken over its findings is near-100% on every loop-driven round, healthy or not, and measures the reviewer's scope rather than the run. `pr-review-skeptic` scopes its content reviewers that way from its second run onward and keeps its composition reviewer on the whole change; **take the share over the whole-change reviewers only**, and say which reviewers it was computed over.

**The test is the reviewer's range, not the presence of a tag.** A finding counts toward the share when the reviewer that produced it had **the whole change in range**, and is excluded only when that reviewer is known to have been **delta-scoped**. Concretely:

- **A bot** — Copilot, or any review bot — reads the whole PR diff. Its findings count. This is the shipped default's case, and a rule phrased over a skeptic-specific tag would exclude every reviewer the default configuration has.
- **Skeptic on a first run**, on a composition-only run, or on any run where it dispatched no delta-scoped reviewers: every finding is whole-change. They count, and there is no tag, because the tag is only written when a run's reviewers had *different* ranges.
- **Skeptic on a mixed-scope run** writes a line just above each comment's marker — `<!-- pr-review-skeptic: scope=whole -->` or `scope=delta`. Count the first, exclude the second. It is a separate line from the plain `<!-- pr-review-skeptic -->` marker, which is unchanged and is still what identifies the comment. **A finding with no comment carries its scope in the review body**, under the tier-3 heading that lists it — read it from there. Those findings exist by construction (a `D` path, a file the change never touched), so a rule that looked only above comment markers would find no tag for them and void the whole round's share.

**Report the share as *not attributable* in one case only: a run that genuinely mixed ranges and lost the attribution** — a mixed-scope reviewer whose findings carry no tag, or any reviewer whose range you cannot establish. Absence of a tag is not by itself that case; on every run above it means the ranges were uniform. And where the share is not attributable, **never substitute the all-findings number** under a claim that it was filtered. Where most of *those* findings are `repair`, the loop is reviewing itself, and that belongs in the run's report (SKILL.md step 9) — say it plainly. A finding that exists because this loop wrote the code it is about is worth naming as such, both to the user and on the thread where it helps.

## Writing the fix without causing the next finding

**This is the loop's characteristic failure: the defect arrives in the fix.** The round that introduced it looks like progress, the next round finds it, and iteration counts climb. Left unchecked it is the thing that makes a four-round loop a fifteen-round one, and no amount of reviewer quality compensates — the reviewer is doing its job; the fixes are squeezing the balloon.

**Scope: any fix with behavioural content.** Correctness, concurrency and data handling obviously. But judge by whether the thing you are editing *governs behaviour*, not by its file extension. A config default, a schema, a CLI flag's meaning, a documented contract, and — in a repo whose deliverable is prose an agent executes — a rule written in a `SKILL.md` are all behavioural. Only genuinely inert edits are exempt: a typo in a sentence nobody acts on, a reflowed paragraph. "It's only docs" is how the checks below get skipped on precisely the changes they were written for.

**The three lenses are how you construct the fix, not just how you triaged it — and here they are applied in order.** Everywhere else they are held as one integrated judgement; at the moment of writing a fix, run them top down, because the order is what stops the patch:

1. **The project, first.** Not "does this close the finding" — *does the codebase end up better*. This is the lens a patch fails. Closing the reported symptom while leaving the rule it came from inconsistent, or adding an exception that makes a general rule harder to state, serves the line and costs the project. Ask what the right shape is here if nobody had reported anything, and how far that is from what you were about to type.
2. **Then the PR.** Does the fix belong to what this change is for? A fix the project would benefit from but this PR has no business making is `Create-issue-and-close`, not a quiet enlargement of scope.
3. **Then the line.** Only now: is this particular edit correct, minimal, and in the idiom around it.

Two consequences, and they are the whole point of the ordering:

- **A suggested fix that doesn't pass the hierarchy is not the fix.** The reviewer's suggestion is an input, not an instruction — it was written from the line's point of view, which is the lens that comes last. Where it fails at the project or PR level, go a different way and say why: that is what `Fix-differently` and `Fix-broader` are for.
- **Where the reviewer suggested nothing, do not default to the smallest edit that makes the finding go away.** No suggestion means the whole construction is yours, so start at the project lens rather than the line. The minimum edit that silences a symptom is the single most reliable way to produce the next round's finding — that edit is what squeezing the balloon looks like from the inside, and it always feels like restraint.

The checks below are the mechanics of doing that well. They are not a substitute for the hierarchy; a fix can pass all five and still be the wrong fix if it was never held against the project first.

- **Name the invariant, not the scenario.** State in one line the property that must hold ("a viewing never lands on an episode the user didn't watch"), then check the fix against *that*. The reviewer's scenario is one route to violating it; fixing only that route is how the second route survives.
- **Find every place the rule is stated.** This is the check most often missing, and the one that produces the most fix-introduced defects, because a rule that lives in several places fails as soon as they disagree — a definition and its uses, a general rule and its exceptions, a summary section and the step it summarises, a value and the comment documenting it. **Grep for the rule's terms, not just the file the finding named**, and fix or delete every stale restatement in the same commit. A finding pointing at one line is telling you where the contradiction was *noticed*, not where it lives. If you changed a rule and touched exactly one file, assume you are not done and go look.
- **Treat a special case as a smell — this is the project lens, applied.** If the fix is "the general rule, except here", ask why the general rule is wrong rather than adding the exception. Each exception is locally defensible and the accumulation is a project-level defect, which is exactly what the first lens is for and exactly what the third lens cannot see. Exceptions accumulate: the second one is usually a sign the rule is stated over the wrong thing, and by the third the rule is unrecoverable and the exceptions contradict each other. **A third patch on one rule means stop patching and restate the rule.** Restating costs one round; patching costs a round each time and gets worse.
- **Ask what already does this.** Before writing a predicate, a dispatcher, a null check — look for the seam that exists. Re-implementing a rule the codebase already encodes (a `Ref.isEmpty`, a project `ioDispatcher`) means the copy drifts from the original the first time either changes. A hand-rolled duplicate of an existing rule is a defect with a delay fuse.
- **Check the fix didn't weaken the tests.** A test edited while fixing a finding can end up asserting less than it did before, and it still passes — that is what makes it invisible. If a guard is added, disable it and confirm its test fails; if a fixture is changed, confirm the assertion still depends on what it claims to prove. Where there is no test suite, the equivalent is to re-read the fix as an executor rather than an author: follow it literally, from the top, and see whether it can be carried out.

**The revert lever — when a repair keeps producing repairs.** The bullet above says a third patch on one rule means restating the rule. The same holds for code, and it is the check with no equivalent anywhere else in this loop: the `re-raised` bucket catches a *reviewer* repeating itself, and nothing catches the *author* failing repeatedly at the same thing. So: **a repair whose own repair produced a finding is a candidate for revert**, not a third patch. Take the whole chain out and go back to the finding that started it — then restate the rule, `Acknowledge-no-change` it, or, where it is genuinely separable, `Create-issue-and-close`. Two consecutive rounds of net-negative work is a thing you can only see by looking for it, and by the third round the patches are interacting with each other rather than with the original defect.

This is not a rule about diff size or round count, and it must not be read as one. A round that grows the diff can be the round that finds the defect which would otherwise ship; runs in this loop's recorded history found permanent-failure and wrong-data-shown-to-users defects well after the diff had ballooned. What the lever keys on is a **chain** — repair on repair on repair — not volume, and killing the chain leaves the loop free to keep finding real defects in the original change.

**Then read the neighbourhood, not the line.** Before committing, re-read what surrounds every edit — the paragraph above and below, the other members of the list you changed, the section that cites this one. A fix that is locally right and regionally wrong reads perfectly at the diff and fails on the first literal execution.

**Say what the fix might have broken.** In the round's report, name any rule you changed that is stated elsewhere, and whether you checked those places. That line is what lets the next round's reviewer look where you were least certain, and it costs a sentence.

## Triaging a skeptic verdict

Same surfaces, same lenses, same courses. Four things about its shape change how you read it:

- **Severity decides what holds the loop open, not what deserves thought.** Blocking findings (`CRITICAL`/`HIGH` by default) are what convergence is gauged on: every one must end at fixed, `Create-issue-and-close`, or `Reject-with-explanation` before that reviewer is happy. A course that leaves HEAD unmoved satisfies it **without a re-review** — nothing about the code changed, so there is nothing for the reviewer to look at again (SKILL.md step 4).

**Two different questions, and conflating them is how a blocking finding gets talked away.** *Is this course a no-op?* asks whether HEAD moved: all four of `Reject-with-explanation`, `Create-issue-and-close`, `Acknowledge-no-change` and *already-fixed* are no-ops, and none of them owes a re-review. *Is this course available for this finding?* is a separate question with a separate answer, and at a blocking severity `Acknowledge-no-change` is **not available** — a `CRITICAL` or `HIGH` is a real problem by definition, so it ends at fixed, `Create-issue-and-close` (only if genuinely unrelated), `Reject-with-explanation` on the merits, or `Ask-user`. Reading "no-op" as "available" is what turns the course into the licence to converge by agreeing with everything that its bar exists to forbid.

Phrase the no-op test as "did HEAD move", never as "was it a `Fix-*`": already-fixed carries a `fixed` marker and moves nothing, so the course-name form leaves a round of already-fixed dispositions unable to converge. Non-blocking observations go through the same two questions as anything else ("Is the problem real, and is it ours?") — a real, related problem is fixed here whatever its severity; a correct observation that names no problem is acknowledged and closed. Every one still gets a reply and a resolved thread, because the record is what stops it coming back. They just don't hold the loop open. Don't invert this into "low severity, ignore": the severity is that skill's blast-radius judgement about the project, and your judgement may rate an item higher than it did. It cuts the other way too — a `MEDIUM` you reply to as `fixed` and leave present comes back a rung higher, as a blocking `HIGH`, since that is exactly the evidence the cross-check's `unfixed` bucket looks for.
- **The buckets are evidence, and `unfixed` is the loud one.** A finding bucketed `unfixed` — raised earlier in this PR's history, touched by a fix round, still present — is the loop's characteristic failure caught red-handed, and it arrives already a severity higher. Treat it as a signal that the earlier fix was written against the scenario rather than the invariant ("Writing the fix without causing the next finding", above) and re-open that question rather than patching the new instance. A `re-raised` one is a concern you argued down that an independent reviewer found anyway: worth more weight than either read alone, and a reason to re-examine your own rationale rather than restate it.
- **`settled` findings are not yours to re-litigate, and not yours to bury.** A prior thread weighed that consequence and the project chose otherwise — usually because *you* rejected, acknowledged, or deferred it in an earlier round. They neither hold the loop open nor need a fix. But a *blocking* one gets named to the user with its count and thread, every time, because somebody decided to live with a `CRITICAL`. You are the author and the judge here; that line is the only thing keeping "converged" from meaning "rejected everything".
- **`Ask-user` is unchanged and still the default** for security/auth, scope boundaries and architectural calls. A finding arriving with a confident severity attached is not extra authority to act unilaterally.

## Recording the decision — disposition replies

**Every finding gets one, whatever its severity and whatever you decided.** A finding whose disposition isn't recorded on the PR is a finding the next round has no way to know was handled: its blind reviewers cannot see your fix commit's reasoning, and its cross-check settles a finding only against a thread that says what was decided. This is the mechanism that makes rounds cumulative. Skip it and the loop is a treadmill.

On the finding's own thread: reply with what you decided and why, then resolve the thread. End the reply with the marker line for the course you took:

```
<!-- pr-review-loop: disposition=fixed -->          any Fix-* course
<!-- pr-review-loop: disposition=rejected -->       Reject-with-explanation
<!-- pr-review-loop: disposition=acknowledged -->   Acknowledge-no-change
<!-- pr-review-loop: disposition=deferred -->       Create-issue-and-close
```

Nothing for `Ask-user` — that thread is still open, so leave it open and unmarked.

**`acknowledged` earns a real sentence, not a shrug.** Say what you agree with and why it isn't worth changing — "true; the phrasing is loose but nothing reads it to decide anything, so leaving it" — because the reviewer was right and the reply is the only place that is recorded. A bare "acknowledged" reads as a brush-off to the person who has to judge whether you were being disciplined or lazy, and it gives the next round's cross-check nothing to settle the finding against.

The marker is machine-readable and the prose beside it is not, which is the point: the next run's cross-check takes the marker as decisive rather than inferring your intent from a sentence. But write the prose properly anyway. A rejection reading "rejected, see commit abc123" settles nothing for a reader who cannot see why, and the reader here includes the person reviewing your judgement later. Name the concern, say why the code is right as it stands, and keep it to a line or two.

**Findings with no thread.** Some findings arrive with nothing to reply on: a skeptic verdict names the ones it could not anchor (a deleted path, code the change never touched), and a bot that puts a concern in its review body rather than on a line has the same shape. Those get one PR-level comment per round instead, listing each with its path, a one-line restatement, and its disposition marker, and ending with:

```
<!-- pr-review-loop: dispositions -->
```

One comment per round, not one per finding. Its next run reads the PR's issue comments as part of the history payload and matches these entries on substance. Without it, exactly the findings that have no thread are the ones that come back every round forever — which is the same failure as skipping the replies, arriving through the one door replies can't cover.

## Issue creation (when choosing `Create-issue-and-close`)

**Check the course first.** An issue is right only where the work is genuinely not what this PR is about. A real problem the change is responsible for is fixed here, and a correct observation that names no problem is `Acknowledge-no-change` — neither is an issue. Filing one in either case looks like progress on the round and is how a backlog outgrows the team that maintains it.

Auto-create only if confident; else ask. Ensure the label exists, then create:

```bash
gh label create follow-up-from-pr-review --color 0E8A16 --description "Follow-up from AI PR review" 2>/dev/null || true
gh issue create --title "..." --body-file <path> --label follow-up-from-pr-review
```

The first line is a no-op when the label exists. The issue body links to the originating thread; the thread reply links back to the issue; then resolve the thread.

## Helpfulness reactions — thumbs-up / thumbs-down

Some reviewers invite a 👍/👎 reaction on whether a comment was useful (Codex is the current example). This applies **only** to a bot that both (a) invites the reaction in its comment body and (b) reads standard GitHub reactions. When present, react — mapped to whether you **accepted or rejected the underlying concern**, not whether you took its exact suggestion:

- **Accepted → 👍 (`+1`):** any `Fix-*` course, `Create-issue-and-close`, or `Acknowledge-no-change`. The reaction tracks whether the comment was *right*, and acknowledge concedes that it was — the decision not to act is carried by the reply, not by a thumbs-down.
- **Rejected → 👎 (`-1`):** `Reject-with-explanation`, and only that — the one course that says the comment was wrong.
- `Ask-user` or a thread still awaiting clarification → don't react yet.

**Not every 👍/👎 is a standard reaction.** Copilot's review comments render their own "was this helpful" widget (a closed Copilot-UI control, no API) — that is not a reaction invitation, so don't treat a Copilot finding as one. The reactions this skill uses are the standard emoji-picker reactions, and the invitation must be in the comment body.

React on whichever comment carries the invitation. Both REST endpoints take the comment's numeric `databaseId` (not a GraphQL `IC_…`/`PRRC_…` node ID):

```bash
# Inline / file-level review comment:
gh api repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions -X POST -f content=+1   # or -1
# PR-level issue comment:
gh api repos/<owner>/<repo>/issues/comments/<comment_id>/reactions -X POST -f content=+1  # or -1
```

A review *summary* (`PullRequestReview`) has no REST reactions endpoint but is reactable via GraphQL — `addReaction(input:{subjectId:<review node id>, content: THUMBS_UP|THUMBS_DOWN})` — so when a helpfulness prompt rides only a summary, react via GraphQL/MCP, falling back to the written reply if you have no such path. The reaction is in addition to (not instead of) the reply. No reactions path at all → skip gracefully; it's an optional steering signal, the reply carries the substance.

## Replies, line numbers, resolution

- **Replies should be one line where possible** — but a rejection earns two, since its whole job is to carry reasoning forward. @-mention a bot back only when the mention reaches that reviewer and it acts on mentions (`@codex` yes; Copilot's reviewer no — reply unmentioned; skeptic never). See `reference/mechanics.md`.
- **Comment line numbers may be stale** — locate by content if the line doesn't match.
- **Resolve a thread when:** Fixed (any variant), already-fixed, acknowledged, kicked-to-issue, OR Explanation-no-change (you've stated your reasoning; the reviewer can reopen). This is every course except `Ask-user`, and resolving is not optional bookkeeping — an unresolved thread is an undecided finding, and the next round treats it as one.
- **`already-fixed` is a course, not just a resolve category.** An earlier round handled the finding and the reviewer re-raised it against stale code: reply saying which commit, stamp `disposition=fixed`, resolve. It changes no code, so it is one of the four no-op dispositions that close a round without a push (SKILL.md step 4) — the one that is easy to miss, because its marker says `fixed`.
- **In a *terminating* round the courses are `rejected`, `acknowledged`, `deferred`, *already-fixed* and `Ask-user`** (SKILL.md step 4), with `acknowledged` still unavailable at a blocking severity — the round being the last does not widen it. *already-fixed* is on the list for the same reason it is on every other: it wears a `fixed` marker and moves no code, and stamping `rejected` instead would record a fix as a rejection. `Ask-user` keeps the thread open and unmarked and routes the run to the paused outcome, so the security/auth default is not overridden by the round happening to be the last one. That pass pushes nothing, so it cannot fix: a finding that *is* a real, related problem makes the round non-terminal instead, and goes through the normal fix→push→re-review path so the reviewer sees the result. `acknowledged` is the course that makes most terminating rounds honest — a clean verdict carrying three correct `LOW` observations that name no problem is the commonest terminating round there is.
- **Do NOT resolve when:** awaiting clarification from a human, or `Ask-user` pending. Both are genuinely still open. Note that neither applies to skeptic, which cannot answer a question — where its finding leaves you uncertain, the question goes to the user, and the thread stays open and unmarked until they answer it.
