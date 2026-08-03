# Evaluating reviewer feedback (SKILL.md step 5 detail)

## What to read

**Threads are the unit of evaluation.** Fetch unresolved review threads with full comment lists via paginated GraphQL (`reference/mechanics.md`); they cover inline AND file-level comments (`line: null`) and carry the conversation context (human replies, and your own dispositions from earlier rounds) the per-review REST endpoint omits. **Also read each review's `body`** separately — reviewers put findings, qualifiers, or "no issues" there with no thread, and a skeptic body additionally names the findings it could not anchor, which exist nowhere else. **And read PR issue comments** — the third surface (SKILL.md "Reading reviewer state"); some bots deliver findings or their whole clean verdict only here. Any state check must union all three. (The REST endpoint `/repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` is a convenience for one review's comments by ID; for the whole-PR view, paginated `reviewThreads` is canonical.)

**Human replies are evaluation INPUT, not a post-hoc check.** Read replies from the author/maintainers BEFORE forming your evaluation — they often steer ("we're doing it this way because…", "ignore for now", "fix narrowly, broader cleanup is tracked elsewhere") and weigh heavily, often decisively. If a human reply directly conflicts with the lens-weighted evaluation (reply says "ignore" but lenses say it's a real project-breaking bug), surface the conflict — don't silently obey or override.

## The integrated judgement

Hold three lenses and the mindset as a **single integrated judgement**, not a sequential rubric, with human replies as weighted input. That is for *triage* — deciding whether a finding is real and which course it takes. **When you come to write the fix, the same three lenses are applied in order instead**, top down: see "Writing the fix without causing the next finding" below. The two are not in tension: one weighs a decision, the other sequences a construction, and the ordering is what keeps a fix from serving the line at the project's expense.

**Lenses (most → least important, all in play at once):** what's best for the **project as a whole** (most) · the **PR overall**, including its larger intent (slightly less) · the **specific item** on its own (slightly less again).

**Mindset:** Steelman the reviewer's underlying concern — their suggested fix is one possible response, not necessarily the best; separate "is there a real issue?" from "is their fix the right one?" The decision space is broader than {accept their fix, reject}. Don't get into pissing contests or be defensive about prior choices; equally, don't capitulate to taste asks when the lens-weighted view says the code is correct. `Reject-with-explanation` is for "concern understood AND lenses support the current code" — not stylistic disagreement.

## Is the problem real, is it worth acting on, and is it ours?

Three questions, in that order, before any course is chosen. They are what separate a round worth running from a round that manufactures work, and none of them is a question about severity.

**1. Is the finding correct, and is the problem real?**

Correct and real are different, and treating them as one predicate is the single largest source of churn this loop produces. A reviewer with no severity floor is usually correct — correctness is not the bar, because an adversarial reader of code, and far more so of prose, can always say something true. The bar is whether there is a **problem**: the code does something wrong, a claim about it is false, or a real cost lands on someone.

- **Materially wrong** — someone relying on this gets a wrong answer, is led toward reintroducing a defect, or pays a cost you can name. A real problem.
- **Not quite right** — imprecise, incomplete, could be phrased better, could assert more. Correct, and not a problem.

**Comments, tests and PR descriptions need to be correct, not perfect**, and that is where the worst churn lives. A comment asserting something false is a real problem: a confident claim beside subtly wrong code tells every later reader to stop looking. A comment that is true but could be sharper is polish — and polishing it costs a round, which owes a review, and the reviewer of the rewrite will find something true to say about *it*. Prose has no falsifier: a wrong line of code can be pinned by a failing test, so the reviewer is one check among two, but a wrong sentence has only the reviewer. That asymmetry is why this floor has to be applied here, by the author, rather than hoped for from the reviewer.

**2. Is it worth acting on?**

Real is not the same as worth another round, and collapsing the two is what turns a converging loop into a grinding one. Every fix costs a round, and that round owes a review, and that review finds things — so a fix has to buy more than it costs.

**Ask reach, not correctness — and say the answer out loud: _who hits this, how often, and what happens to them?_** Correctness is settled by question 1; this question is about how far the problem travels. A test phrased as "does someone reach a wrong outcome" barely filters, because that is the first half of the reviewer's own reporting bar — so every finding that took that half passes the gate by construction, and it is the same bar twice. What little filtering it did was all in its other clause, which is preserved below.

- **Who** — a user on a normal path, the next person to read this file, or nobody without an unusual combination of settings.
- **How often** — every run, or only when two independent conditions line up.
- **What happens** — data or behaviour goes wrong, or a report misleads, or someone is mildly worse off.

**Likely × harmful is worth acting on**, whatever its size: a wrong result on a path people take, a boundary that lets through what it exists to stop, a confidently false claim that tells a reader to stop looking. A one-word fix to one of those is worth the round; a large fix to one of them is too.

**The organizing question is "is this worth another round?"** If the honest answer is no, and the fix is not free, it is not worth acting on — however true the finding is. **Not "would this block the merge"**: most `MEDIUM`s and every `LOW` would not, and a real, related problem that clears *this* gate is fixed here whatever its severity. Severity says what *must* be fixed; this gate asks what is *worth* fixing, and the two are different questions. Reading it as the blocking question would acknowledge away the entire non-blocking tier, which is most of what a reviewer reports.

**What usually is not: a cost that lands only on the next reader, in a place that is already correct enough to act on** — or anything reachable only by ANDing two unusual conditions. A report that omits one of four numbers. A precondition you discover a round later than you could have. An ambiguity in a corner that needs two unusual settings at once to reach.

**The bar rises as a run goes on, and that is deliberate.** After several rounds with nothing blocking, the marginal defect you would fix is smaller than the marginal defect a fix introduces — this loop's own history has a round where three of six findings were regressions from the previous round's fixes, one of which made an environment strictly worse than before it was touched. So late in a run, "worth acting on" means *clearly* worth it. Chasing the last correct-but-cornered finding is how a converging loop becomes a grinding one. Documentation, comments, PR descriptions and test names belong here more often than anywhere else — **they need to be correct, not perfect**, and this is the second gate that says so. A comment that asserts something *false* fails question 1 and gets fixed. A comment that is true, and could be clearer, or is missing a caveat that changes nobody's decision, is real and is **not worth the round**.

The honest test is a trade, so make it out loud: *what does this cost if left, against what the round to fix it costs?* Where the answer is "a later reader is mildly worse off, and the round costs a full review of everything the fix touches", leave it.

**Two guards, because this gate is the one that can be abused.** It is **never available at a blocking severity** — a `CRITICAL` or `HIGH` is worth acting on by definition. And leaving a real problem is a decision you are making on the project's behalf, so it is recorded as one: the reply says the finding is right, says what it costs to leave, and says you are leaving it. That is a different claim from "this is not a problem" and must not be written as if it were.

**3. Is it related to what this PR is doing?**

Not "did the diff touch this line" — is it part of the job this change came to do. A defect this change is responsible for is related even where the line predates it (a change that makes a broken path newly reachable owns that path). Work the change merely happens to sit near is not.

**First ask whether HEAD still has it.** A reviewer re-raising a finding against stale code is `Already-fixed` — reply naming the commit, stamp `disposition=fixed`, resolve. The table below has no row for it, and both routes through it record something false: `acknowledged` says the defect is there and being lived with, `rejected` says the code was kept as-is on the merits. Either one lies to the next round's cross-check and inflates a count a reader is told to audit your judgement by.

| Correct? | Real problem? | Worth acting on? | Related? | Course |
|---|---|---|---|---|
| Yes | Yes | Yes | Yes | **Fix it** — cost shapes *how*, never *whether* |
| Yes | Yes | Yes | No | `Create-issue-and-close` |
| Yes | Yes | **No — real, not worth the round** | — | `Acknowledge-no-change`, reply saying it is right and what leaving it costs |
| Yes | No — correct, not a problem | — | — | `Acknowledge-no-change` |
| No | — | — | — | `Reject-with-explanation` |
| — | Uncertain, security/auth, architectural, or blocking-and-you-think-immaterial | — | — | `Ask-user` |

**`Acknowledge-no-change` covers two different claims and the reply must say which.** *"You are right and this is not a problem"* and *"you are right, it is a problem, and it is not worth a round"* are both closes-without-change, but the second is a decision to ship a known defect and the summary counts them separately. Never write the second as the first.

**Severity is not one of the three questions, and it still closes one course.** It does not decide whether a problem is real — that is the first question, and a `HIGH` you judge immaterial is still answered by the first question. What it decides is which courses remain: at a blocking severity `Acknowledge-no-change` is unavailable, because a run that converges by agreeing with a `HIGH` is the outcome the course's bar exists to forbid. Stamping `rejected` on a finding you agree with is not the way out either — that puts a false statement in the record. Where you genuinely think a blocking finding is immaterial, that is an `Ask-user`.

**A real, related problem gets fixed in this PR.** Deferring it is not on the table. What merges should work, and an issue filed against a defect this change is responsible for is that defect shipping with a note attached. `Create-issue-and-close` means one thing — work that is genuinely not what this PR is about — and every use outside that meaning trades a bounded round now for an unbounded backlog later. If issues are opening faster than they close, this is the leak.

**Cost to own is a question about the fix, not about whether to fix.** Ask it, because it goes unasked and it is where the loop's worst rounds come from: a fix cheap to *write* and expensive to *own* — one boolean on a stateful object, one latch, one exception to a general rule — lands among lifecycle, concurrency or caching neighbours and produces defects for three rounds afterwards. The answer changes the fix's **shape**: revert rather than patch, restate the rule rather than add the exception, take the seam that already exists. Only a genuinely ridiculous cost changes the *decision*, and then the course is `Ask-user`, never a quiet deferral.

## Courses of action

`Fix-as-suggested` · `Fix-differently` (better way to address the same concern) · `Fix-broader` (the real issue is bigger) · `Already-fixed` (an earlier round handled it and the reviewer re-raised it against stale code — reply naming the commit, stamp `disposition=fixed`, resolve; changes no code, so it is one of the four no-op courses) · `Acknowledge-no-change` (correct, and either not a problem or not worth the round it would cost — reply agreeing and saying which, stamp `disposition=acknowledged`, resolve; changes no code) · `Reject-with-explanation` · `Create-issue-and-close` (real, and genuinely not what this PR is about — NOT "broken, fix later") · `Ask-user` (genuinely uncertain).

**`Acknowledge-no-change` and `Reject-with-explanation` are not interchangeable, and the reply says which.** Reject asserts the reviewer is wrong or the code is right as it stands. Acknowledge says the reviewer is right and this is not worth changing. Writing "rejected" over a finding you know is correct puts a false statement in the record the next round reads, and hides the count of things you agreed with and declined — which is exactly the number a person reviewing your judgement needs to see.

**`Acknowledge-no-change` is not available at a blocking severity.** A `CRITICAL` or `HIGH` is a real problem by definition, so it ends at fixed, `Create-issue-and-close` (only if genuinely unrelated), `Reject-with-explanation` on the merits, or `Ask-user`. The course is a licence to stop polishing, not a licence to converge by agreeing with everything.

**Default to `Ask-user` for:** security/auth-adjacent changes; relatedness boundary calls; conflicting reviewer asks; big-impact architectural feedback; a fix whose cost to own looks ridiculous.

## Whose code is this finding about?

By round six a reviewer reading HEAD is mostly reading **your repair work**, not the change the PR came to make. It cannot know that — its blindness is the point — and nothing tells you either unless you look. So look: it is one cheap lookup and it changes the triage.

Blame the line the finding names, find the commit that introduced it, and read whether that commit carries a `PR-Review-Loop: <N>` trailer (SKILL.md step 6 stamps every commit *it* makes, which is why the same step says not to make one earlier — a commit that slipped in before it carries no trailer and reads here as though the loop never wrote it). Three answers:

- **original** — the change under review. Normal triage.
- **repair** — code this loop wrote in an earlier round. The finding is a defect in a fix, so re-open the question that fix was answering rather than patching the new instance. See the revert lever below.
- **pre-existing** — neither the PR nor the loop touched it. Strong evidence for *unrelated*, and the commonest thing a long run gets wrong in the other direction: after five rounds patching one subsystem, a sixth finding in that subsystem reads as the fifth defect in your own latch when it is actually a defect that predates the change and that your fix never covered. Ripping out the fix then re-opens the window the finding is about. **Evidence, not a verdict** — a change that makes a broken path newly reachable owns that path, and the best single finding in this loop's recorded history was exactly that shape.

Provenance is also the round-level signal that the work has changed character — **but only when computed over reviewers who could have found something else.** A reviewer scoped to what changed since the last review is reading the loop's repair commits *by construction*, so a share taken over its findings is near-100% on every loop-driven round, healthy or not, and measures the reviewer's scope rather than the run. `pr-review-skeptic` scopes its content reviewers that way from its second run onward, and dispatches a whole-change composition reviewer on some later runs but not all of them; **take the share over the whole-change reviewers only**, and say which reviewers it was computed over.

**The test is the reviewer's range, not the presence of a tag.** A finding counts toward the share when the reviewer that produced it had **the whole change in range**, and is excluded only when that reviewer is known to have been **delta-scoped**. Concretely:

- **A bot** — Copilot, or any review bot — reads the whole PR diff. Its findings count. This is the shipped default's case, and a rule phrased over a skeptic-specific tag would exclude every reviewer the default configuration has.
- **Skeptic on a first run**: every reviewer had the whole change. They count, and there is no tag, because none is written on a first run.
- **Skeptic on a later run** writes a scope line just above each comment's marker — `<!-- pr-review-skeptic: scope=whole -->` or `scope=delta`. Count the first, exclude the second. It is a separate line from the plain `<!-- pr-review-skeptic -->` marker, which is unchanged and is still what identifies the comment. **A finding with no comment carries its scope in the review body**, under the tier-3 heading that lists it — read it from there. Those findings exist by construction (a `D` path, a file the change never touched), so a rule that looked only above comment markers would find no tag for them and void the whole round's share. The value is **uniform across a round**: a later run dispatches either content reviewers on the delta or a composition reviewer on the whole change, never both (`pr-review-skeptic` SKILL.md, stage 3).

**A round where no whole-change reviewer ran has no share at all, and that is not a failure to attribute.** It is the normal shape of a skeptic-only round under the composition cadence: the reviewers were uniformly `scope=delta`, so the set the share is taken over is empty. Say the share is **undefined this round — no reviewer had the whole change in range** — and name when one last did, from skeptic's `whole-change` sha — only where the record holds one, since `none` and an absent field name no commit. **Where you are reporting across several rounds** — a capped run, SKILL.md step 9 — say how many of them had it rather than calling each one an exception: on a skeptic-only list most rounds of a capped run are delta-scoped, so "undefined this round" repeated N times misdescribes the shape. Do not report it as `0%`, do not fall back to the all-findings number, and do not call it *not attributable*, which names a different problem and would send a reader looking for a parsing fault that isn't there.

**Report the share as *not attributable* in one case only: a run that lost the attribution** — a reviewer whose findings carry no tag where one was due, or any reviewer whose range you cannot establish. Absence of a tag is not by itself that case; on a first run it means the ranges were uniformly whole. And where the share is not attributable, **never substitute the all-findings number** under a claim that it was filtered. Where most of *those* findings are `repair`, the loop is reviewing itself, and that belongs in the run's report (SKILL.md step 9) — say it plainly. A finding that exists because this loop wrote the code it is about is worth naming as such, both to the user and on the thread where it helps.

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

**The revert lever — when a repair keeps producing repairs.** The bullet above says a third patch on one rule means restating the rule. The same holds for code, and it is the check with no equivalent anywhere else in this loop: the `re-raised` bucket catches a *reviewer* repeating itself, and nothing catches the *author* failing repeatedly at the same thing. So: **a repair whose own repair produced a finding is a candidate for revert**, not a third patch. Take the whole chain out with `git revert --no-commit`, so step 6 makes the commit and stamps it with the round's `PR-Review-Loop: <N>` trailer: a plain `git revert` commits by default, and a commit with no trailer is what step 2 reads as an **external push**, which re-engages `(tracked − excused) ∩ reviewers` — including bots that had already gone happy. Then go back to the finding that started it — then restate the rule, `Acknowledge-no-change` it, or, where it is genuinely separable, `Create-issue-and-close`. Two consecutive rounds of net-negative work is a thing you can only see by looking for it, and by the third round the patches are interacting with each other rather than with the original defect.

This is not a rule about diff size or round count, and it must not be read as one. A round that grows the diff can be the round that finds the defect which would otherwise ship; runs in this loop's recorded history found permanent-failure and wrong-data-shown-to-users defects well after the diff had ballooned. What the lever keys on is a **chain** — repair on repair on repair — not volume, and killing the chain leaves the loop free to keep finding real defects in the original change.

**Then read the neighbourhood, not the line.** Before committing, re-read what surrounds every edit — the paragraph above and below, the other members of the list you changed, the section that cites this one. A fix that is locally right and regionally wrong reads perfectly at the diff and fails on the first literal execution.

**Say what the fix might have broken.** In the round's report, name any rule you changed that is stated elsewhere, and whether you checked those places. That line is what lets the next round's reviewer look where you were least certain, and it costs a sentence.

## The blind pre-push check

Every check above is run by the context that just decided the fix was right, at the moment it is most sure of that — which is why a round can satisfy all of them and still ship the defect the next round reports. The reviewer catches it, one round later, and that round is the cost this whole section exists to avoid. So before the push, one **independent** read of the round's own diff. It is named for what it guards — nothing reaches a reviewer until the push — but it runs well before that: ahead of the round's fix commit, so what it finds is folded into the fix instead of arriving as a second commit correcting the first, and ahead of step 5 recording anything, so the record describes what the round finally did rather than what it first tried. Ahead of *that* commit, note — which is an ordering, not a claim that the tree is uncommitted when the check runs.

**Run it once per round, after the round's fixes are written and before step 5 records any of them** — not once per finding, and **not at all on a round that changed no code**. A round of nothing but rejections, acknowledgements and already-fixed replies has nothing to push, so it has nothing to guard; dispatching over its empty diff spends a subagent and, worse, invites the reader to go hunting the diff-construction bug the paragraph above warns about, which is not there. The ordering is the point and it is easy to get backwards: this check is the only thing in the loop that can tell you a fix was the *wrong* fix, which a red build cannot, so it has to come before the replies go out. Record first and a check that sends you back to redo or abandon a fix leaves the PR carrying a resolved thread stamped `fixed` over a defect still present at HEAD — which is what this file names as producing the `unfixed` bucket a rung higher next round, the churn this check was added to prevent. Repairing that afterwards is possible and awkward, which is why the order is the rule rather than the fallback. GitHub can edit a review comment and can un-resolve a thread, but `reference/mechanics.md` documents neither call — it has reply and resolve — so a correction means reaching past this skill's own toolkit, and it either rewrites a reply people have already read or reopens a thread they were told was closed. **If you find yourself there, correct it anyway** — the next run's cross-check takes the marker as decisive, so a `fixed` left standing over a live defect is the one outcome worse than an untidy thread. Its job is the round as a whole, including the way this round's fixes interact with each other, which is a defect class no per-fix check can see and no reviewer sees until the next round.

**Give the checker the diff and the invariants. Nothing else.** Everything the round has done since the last push, plus the one-line invariant you named for each fix.

**The diff has to satisfy one requirement, and the requirement is the rule — not any particular command.** It must contain **everything the round has done since the last push**: committed, staged, unstaged, and newly created alike. Check the diff you built against that sentence before handing it over, because every wrong form fails the same silent way — it gives the checker less than the round did, a checker reports nothing wrong with code it was never given, and the round pushes under a clean pre-push read. That is worse than running no check at all.

In the ordinary case that is `git add -N` on the round's new files, and **only then** `git diff @{upstream}` — the order is part of it, since a diff taken first cannot show a file `add -N` has not yet reached. Two things make that recipe right, and they are also what tells you when it isn't:

- **New files reach a diff only through `git add -N`.** An untracked file appears in no diff at all, so a fix that adds a reference doc or a config default is otherwise invisible. Take the names from `git status --porcelain` at the repo root, and **read that list rather than globbing it with `add -N .`** — the clean-tree precondition means it should hold this round's work and nothing else, so anything unexpected there is a stray to deal with before committing, not to sweep in. Then add those files properly when the round commits: intent-to-add is not a staged file and plain `git commit` skips it, so a `git add` on them belongs before the commit whichever host performs it — otherwise a file the checker approved never reaches the push, and the reviewer reads a change referencing something absent.
- **The base is the last pushed commit, never `HEAD`.** This check guards the push, and the round's work does not always sit uncommitted. `git revert` commits by default — the revert lever above says `--no-commit` for that reason, but an executor that reaches for the bare form, or a commit host that ran early, leaves the round's work *in* `HEAD`, where a diff against `HEAD` comes back empty and hands over nothing at all for the largest single act a round can perform. Basing on the pushed ref is right either way, which is why it is the rule rather than a precaution.

`@{upstream}` names that commit on an ordinary tracking branch and is right whether the round committed or not. Where it doesn't — no upstream configured, a triangular remote where the tracked ref is not the pushed one, the detached HEAD that Preconditions contemplates for automated runs — it is fatal or wrong rather than subtly short, so you will see it. Name the pushed commit some other way and carry on; the requirement above is what has to hold, and `git diff <remote>/<branch>` usually holds it. Reaching for `HEAD` because `@{upstream}` failed is the one move that is never the answer.

**Not** the finding text, not the reviewer's rationale, not the PR description, not which round this is, not why you chose this fix over the one that was suggested. Withholding those is the entire mechanism: a checker told what the diff was *meant* to do reads the diff for confirmation, and confirms. This is the same discipline `pr-review-skeptic` applies to its own reviewers, applied here to a diff that skill will not see until after it ships.

**Tell it, in as many words, that it reads and never writes.** Read and grep only; no `stash`, `checkout`, `restore`, `reset`, `clean`, `fetch`, or edits of any kind; no `gh`; report what it finds rather than fixing it. **Give it the safe route in the same breath** — the pre-change state is read with `git show <ref>:<path>`, never by moving the tree — because the paragraph is otherwise a prohibition on the one move it predicts the checker will want to make.

`fetch` is on that list for a reason of its own: it moves the remote-tracking ref this check's diff is *defined against*, so a checker fetching to orient itself silently re-bases the very diff it was handed. And none of this is boilerplate — the checker works in your **live tree**, on work that may exist nowhere else, and its natural move when asked what a diff changed is to go and look at the state before it. That is a weaker position than `pr-review-skeptic`'s reviewers are in: they read a throwaway worktree pinned at a committed sha, and are still told this in as many words. An edit made here is either work destroyed outright or, worse, work that rides into the round's commit under its `PR-Review-Loop: <N>` trailer and reads as the loop's own repair for the rest of the run.

**Bound its reads too, and state that one as a property rather than a list.** Everything written *about* this change is out of scope for it, **by every route** — the branch's own commits and their messages, the branch name, anything under `.git/`. Not because a particular command is banned, but because that material is the author's account of the change, which is the one thing that would compromise the read. Name the obvious routes as examples and not as the rule: no `git log`, no `git show` of a *commit*, no `git blame`, no `reflog`. `git show <ref>:<path>` stays available, since it prints file content rather than messages.

The enumeration cannot be the rule, and this is where that bites hardest. From round two the branch carries this loop's own fix commits, each stamped `PR-Review-Loop: <N>`, so any route into the history hands the checker the round number and every previous round's rationale — after which it does what a briefed checker does: reads the diff for confirmation, and confirms. `git blame --line-porcelain` prints each line's commit subject without `log` or `show`, and it is the lookup this skill documents twice elsewhere, so it is the checker's *most natural* move. Reflog entries and `.git/COMMIT_EDITMSG` carry subjects too, and "read files only" affirmatively licenses reading them. The failure is silent and it fires on every round after the first, which is the range where this loop's own repair defects live. `pr-review-skeptic`'s brief states the same rule as a property for exactly this reason — copy its form, not just its list.

Three questions, and the second and third are the ones a self-check cannot answer honestly:

1. **Read it as an executor, not an author.** Follow the changed code or prose literally, from the top. What breaks?
2. **Was the problem removed, or relocated?** Squeezing the balloon has a signature: the reported symptom is gone, and the property it was a symptom of is still violable by another route. Name the route if there is one.
3. **Where else is each invariant stated, and does the diff leave those places agreeing with it?** Grep the invariant's terms across the repo. This is the check that verifies the grep bullet above actually happened — the author's belief that they checked is not evidence that they did, and a stale restatement is the single most common thing a fix round leaves behind.

**What comes back is yours to triage, in-round.** Real problem in your own fix → fix it now, before anything is recorded and before the round's fix commit, so nothing ships that you already know is wrong and no reply goes out describing a fix you are about to change. Not real → drop it. **Nothing from this check is posted, gets a thread, or gets a disposition marker.** It is not a reviewer and it produces no findings in the sense the rest of this skill uses the word — it is one more thing you did before the round's fix commit, and the record of it is the fix itself.

**One pass.** Do not iterate with it, and do not re-run it over the fixes it prompted. An inner review loop inside a review loop is the failure this skill is built to bound, and the second pass buys much less than the first: what survives an independent read of the diff is what the reviewer's round is for.

**It does not count as a review, and a round that passes it is not converged.** Step 4 is untouched — the code still moved, so an accountable reviewer still has to see it. This check makes the reviewer's round more likely to be the last one; it never substitutes for it. Treating a clean pre-push read as a reviewer's clean verdict is the one way this check makes things worse than not having it.

The trade is one subagent per fix round against a full review round — a wait, a reviewer dispatch, and a triage pass — every time it catches something.

**Where no subagent is available**, run the three questions yourself as a separate deliberate pass over the diff, and say in the round's report that the check was self-run. It is a weaker check and should be described as one: the thing that makes the dispatched version work is that the reader does not know what the diff was for, and you cannot unknow it.

## Triaging a skeptic verdict

Same surfaces, same lenses, same courses. Four things about its shape change how you read it:

- **Severity decides what holds the loop open, not what deserves thought.** Blocking findings (`CRITICAL`/`HIGH` by default) are what convergence is gauged on: every one must end at fixed, `Create-issue-and-close`, or `Reject-with-explanation` before that reviewer is happy. A course that leaves HEAD unmoved satisfies it **without a re-review** — nothing about the code changed, so there is nothing for the reviewer to look at again (SKILL.md step 4).

**Two different questions, and conflating them is how a blocking finding gets talked away.** *Is this course a no-op?* asks whether HEAD moved: all four of `Reject-with-explanation`, `Create-issue-and-close`, `Acknowledge-no-change` and *already-fixed* are no-ops, and none of them owes a re-review. *Is this course available for this finding?* is a separate question with a separate answer, and at a blocking severity `Acknowledge-no-change` is **not available** — a `CRITICAL` or `HIGH` is a real problem by definition, so it ends at fixed, `Create-issue-and-close` (only if genuinely unrelated), `Reject-with-explanation` on the merits, or `Ask-user`. Reading "no-op" as "available" is what turns the course into the licence to converge by agreeing with everything that its bar exists to forbid.

Phrase the no-op test as "did HEAD move", never as "was it a `Fix-*`": already-fixed carries a `fixed` marker and moves nothing, so the course-name form leaves a round of already-fixed dispositions unable to converge. Non-blocking observations go through the same three questions as anything else ("Is the problem real, is it worth acting on, and is it ours?") — a real, related problem is fixed here whatever its severity; a correct observation that names no problem is acknowledged and closed. Every one still gets a reply and a resolved thread, because the record is what stops it coming back. They just don't hold the loop open. Don't invert this into "low severity, ignore": the severity is that skill's blast-radius judgement about the project, and your judgement may rate an item higher than it did. It cuts the other way too — a `MEDIUM` you reply to as `fixed` and leave present comes back a rung higher, as a blocking `HIGH`, since that is exactly the evidence the cross-check's `unfixed` bucket looks for.
- **The buckets are evidence, and `unfixed` is the loud one.** A finding bucketed `unfixed` — raised earlier in this PR's history, touched by a fix round, still present — is the loop's characteristic failure caught red-handed, and it arrives already a severity higher. Treat it as a signal that the earlier fix was written against the scenario rather than the invariant ("Writing the fix without causing the next finding", above) and re-open that question rather than patching the new instance. A `re-raised` one is a concern you argued down that an independent reviewer found anyway: worth more weight than either read alone, and a reason to re-examine your own rationale rather than restate it.
- **`settled` findings are not yours to re-litigate, and not yours to bury.** A prior thread weighed that consequence and the project chose otherwise — usually because *you* rejected, acknowledged, or deferred it in an earlier round. They neither hold the loop open nor need a fix. But a *blocking* one gets named to the user with its count and thread, every time, because somebody decided to live with a `CRITICAL`. You are the author and the judge here; that line is the only thing keeping "converged" from meaning "rejected everything".
- **`Ask-user` is unchanged and still the default** for security/auth, scope boundaries and architectural calls. A finding arriving with a confident severity attached is not extra authority to act unilaterally.

## Recording the decision — disposition replies

**`NOTED` items are not findings and get nothing.** A skeptic review body lists them under their own heading, marked as needing no response: correct observations that are cornered or cost only a later reader. **Read the heading, not the severity.** "Does not hold the merge" is not the discriminator and never was — it is true of every `MEDIUM` and `LOW` as well — and the body carries two path-keyed sections, so a tier-3 finding sitting beside the notes is exactly what a merge-blocking test would misfile. One of those misfiled is a finding with no reply, no marker and no entry in the PR-level comment, which is the shape that comes back every round forever. They have no thread, no severity and no bucket, and they must not be dispositioned, replied to, or counted as work — treating them as findings re-creates by the back door exactly the churn the reviewer's bar removed. Read them, act on one if you happen to be in that code anyway, and otherwise leave them for whoever touches it next.

**Every finding gets one, whatever its severity and whatever you decided.** A finding whose disposition isn't recorded on the PR is a finding the next round has no way to know was handled: its blind reviewers cannot see your fix commit's reasoning, and its cross-check settles a finding only against a thread that says what was decided. This is the mechanism that makes rounds cumulative. Skip it and the loop is a treadmill.

On the finding's own thread: reply with what you decided and why, then resolve the thread. End the reply with the marker line for the course you took:

```
<!-- pr-review-loop: disposition=fixed -->          any Fix-* course
<!-- pr-review-loop: disposition=rejected -->       Reject-with-explanation
<!-- pr-review-loop: disposition=acknowledged -->   Acknowledge-no-change
<!-- pr-review-loop: disposition=deferred -->       Create-issue-and-close
```

Nothing for `Ask-user` — that thread is still open, so leave it open and unmarked.

**`acknowledged` earns a real sentence, not a shrug, and it says which of the two claims it is.** For a finding that names no problem: "true; the phrasing is loose but nothing reads it to decide anything, so leaving it." For a real one you are choosing not to spend a round on: **say it is right, say what leaving it costs, and say that is the trade** — "right, and the report will omit this number until someone hits it; not worth a round and the review it owes." The reviewer was right either way and the reply is the only place that is recorded. A bare "acknowledged" reads as a brush-off to the person who has to judge whether you were being disciplined or lazy, and it gives the next round's cross-check nothing to settle the finding against.

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
