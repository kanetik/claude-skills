# Evaluating reviewer feedback (SKILL.md step 5 detail)

## What to read

**Threads are the unit of evaluation.** Fetch unresolved review threads with full comment lists via paginated GraphQL (`reference/mechanics.md`); they cover inline AND file-level comments (`line: null`) and carry the conversation context (human replies, and your own dispositions from earlier rounds) the per-review REST endpoint omits. **Also read each review's `body`** separately — reviewers put findings, qualifiers, or "no issues" there with no thread, and a skeptic body additionally names the findings it could not anchor, which exist nowhere else. **And read PR issue comments** — the third surface (SKILL.md "Reading reviewer state"); some bots deliver findings or their whole clean verdict only here. Any state check must union all three. (The REST endpoint `/repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` is a convenience for one review's comments by ID; for the whole-PR view, paginated `reviewThreads` is canonical.)

**Human replies are evaluation INPUT, not a post-hoc check.** Read replies from the author/maintainers BEFORE forming your evaluation — they often steer ("we're doing it this way because…", "ignore for now", "fix narrowly, broader cleanup is tracked elsewhere") and weigh heavily, often decisively. If a human reply directly conflicts with the lens-weighted evaluation (reply says "ignore" but lenses say it's a real project-breaking bug), surface the conflict — don't silently obey or override.

## The integrated judgement

Hold three lenses and the mindset as a **single integrated judgement**, not a sequential rubric, with human replies as weighted input.

**Lenses (most → least important, all in play at once):** what's best for the **project as a whole** (most) · the **PR overall**, including its larger intent (slightly less) · the **specific item** on its own (slightly less again).

**Mindset:** Steelman the reviewer's underlying concern — their suggested fix is one possible response, not necessarily the best; separate "is there a real issue?" from "is their fix the right one?" The decision space is broader than {accept their fix, reject}. Don't get into pissing contests or be defensive about prior choices; equally, don't capitulate to taste asks when the lens-weighted view says the code is correct. `Reject-with-explanation` is for "concern understood AND lenses support the current code" — not stylistic disagreement.

## Courses of action

`Fix-as-suggested` · `Fix-differently` (better way to address the same concern) · `Fix-broader` (the real issue is bigger) · `Already-fixed` (an earlier round handled it and the reviewer re-raised it against stale code — reply naming the commit, stamp `disposition=fixed`, resolve; changes no code, so it is one of the three no-op courses) · `Reject-with-explanation` · `Create-issue-and-close` (real but genuine scope-creep — NOT "broken, fix later") · `Ask-user` (genuinely uncertain).

**Default to `Ask-user` for:** security/auth-adjacent changes; scope-creep boundary calls; conflicting reviewer asks; big-impact architectural feedback.

## Writing the fix without causing the next finding

**This is the loop's characteristic failure: the defect arrives in the fix.** The round that introduced it looks like progress, the next round finds it, and iteration counts climb. Left unchecked it is the thing that makes a four-round loop a fifteen-round one, and no amount of reviewer quality compensates — the reviewer is doing its job; the fixes are squeezing the balloon.

**Scope: any fix with behavioural content.** Correctness, concurrency and data handling obviously. But judge by whether the thing you are editing *governs behaviour*, not by its file extension. A config default, a schema, a CLI flag's meaning, a documented contract, and — in a repo whose deliverable is prose an agent executes — a rule written in a `SKILL.md` are all behavioural. Only genuinely inert edits are exempt: a typo in a sentence nobody acts on, a reflowed paragraph. "It's only docs" is how the checks below get skipped on precisely the changes they were written for.

**The lenses above do not cover this.** They decide *whether* a finding deserves a fix and *which* fix serves the project — a triage judgement. Everything here is about *constructing* the fix once that's settled. A well-triaged fix can still break something else, and no weighting of project-versus-PR-versus-item catches it.

Five checks before pushing a fix:

- **Name the invariant, not the scenario.** State in one line the property that must hold ("a viewing never lands on an episode the user didn't watch"), then check the fix against *that*. The reviewer's scenario is one route to violating it; fixing only that route is how the second route survives.
- **Find every place the rule is stated.** This is the check most often missing, and the one that produces the most fix-introduced defects, because a rule that lives in several places fails as soon as they disagree — a definition and its uses, a general rule and its exceptions, a summary section and the step it summarises, a value and the comment documenting it. **Grep for the rule's terms, not just the file the finding named**, and fix or delete every stale restatement in the same commit. A finding pointing at one line is telling you where the contradiction was *noticed*, not where it lives. If you changed a rule and touched exactly one file, assume you are not done and go look.
- **Treat a special case as a smell.** If the fix is "the general rule, except here", ask why the general rule is wrong rather than adding the exception. Exceptions accumulate: the second one is usually a sign the rule is stated over the wrong thing, and by the third the rule is unrecoverable and the exceptions contradict each other. **A third patch on one rule means stop patching and restate the rule.** Restating costs one round; patching costs a round each time and gets worse.
- **Ask what already does this.** Before writing a predicate, a dispatcher, a null check — look for the seam that exists. Re-implementing a rule the codebase already encodes (a `Ref.isEmpty`, a project `ioDispatcher`) means the copy drifts from the original the first time either changes. A hand-rolled duplicate of an existing rule is a defect with a delay fuse.
- **Check the fix didn't weaken the tests.** A test edited while fixing a finding can end up asserting less than it did before, and it still passes — that is what makes it invisible. If a guard is added, disable it and confirm its test fails; if a fixture is changed, confirm the assertion still depends on what it claims to prove. Where there is no test suite, the equivalent is to re-read the fix as an executor rather than an author: follow it literally, from the top, and see whether it can be carried out.

**Then read the neighbourhood, not the line.** Before committing, re-read what surrounds every edit — the paragraph above and below, the other members of the list you changed, the section that cites this one. A fix that is locally right and regionally wrong reads perfectly at the diff and fails on the first literal execution.

**Say what the fix might have broken.** In the round's report, name any rule you changed that is stated elsewhere, and whether you checked those places. That line is what lets the next round's reviewer look where you were least certain, and it costs a sentence.

## Triaging a skeptic verdict

Same surfaces, same lenses, same courses. Four things about its shape change how you read it:

- **Severity decides what holds the loop open, not what deserves thought.** Blocking findings (`CRITICAL`/`HIGH` by default) are what convergence is gauged on: every one must end at fixed, `Create-issue-and-close`, or `Reject-with-explanation` before that reviewer is happy. A course that leaves HEAD unmoved satisfies it **without a re-review** — nothing about the code changed, so there is nothing for the reviewer to look at again (SKILL.md step 4). That is all three no-op courses: `Reject-with-explanation`, `Create-issue-and-close`, and *already-fixed*. Phrase the test as "did HEAD move", never as "was it a `Fix-*`": already-fixed carries a `fixed` marker and moves nothing, so the course-name form leaves a round of already-fixed dispositions unable to converge. Non-blocking observations are triaged under the same lenses — take the cheap correct ones now, reject or defer the rest — and every one of them still gets a reply and a resolved thread, because the record is what stops it coming back. They just don't hold the loop open. Don't invert this into "low severity, ignore": the severity is that skill's blast-radius judgement about the project, and your lenses may rate an item higher than it did. It cuts the other way too — a `MEDIUM` you reply to as `fixed` and leave present comes back a rung higher, as a blocking `HIGH`, since that is exactly the evidence the cross-check's `unfixed` bucket looks for.
- **The buckets are evidence, and `unfixed` is the loud one.** A finding bucketed `unfixed` — raised earlier in this PR's history, touched by a fix round, still present — is the loop's characteristic failure caught red-handed, and it arrives already a severity higher. Treat it as a signal that the earlier fix was written against the scenario rather than the invariant ("Writing the fix without causing the next finding", above) and re-open that question rather than patching the new instance. A `re-raised` one is a concern you argued down that an independent reviewer found anyway: worth more weight than either read alone, and a reason to re-examine your own rationale rather than restate it.
- **`settled` findings are not yours to re-litigate, and not yours to bury.** A prior thread weighed that consequence and the project chose otherwise — usually because *you* rejected or deferred it in an earlier round. They neither hold the loop open nor need a fix. But a *blocking* one gets named to the user with its count and thread, every time, because somebody decided to live with a `CRITICAL`. You are the author and the judge here; that line is the only thing keeping "converged" from meaning "rejected everything".
- **`Ask-user` is unchanged and still the default** for security/auth, scope boundaries and architectural calls. A finding arriving with a confident severity attached is not extra authority to act unilaterally.

## Recording the decision — disposition replies

**Every finding gets one, whatever its severity and whatever you decided.** A finding whose disposition isn't recorded on the PR is a finding the next round has no way to know was handled: its blind reviewers cannot see your fix commit's reasoning, and its cross-check settles a finding only against a thread that says what was decided. This is the mechanism that makes rounds cumulative. Skip it and the loop is a treadmill.

On the finding's own thread: reply with what you decided and why, then resolve the thread. End the reply with the marker line for the course you took:

```
<!-- pr-review-loop: disposition=fixed -->      any Fix-* course
<!-- pr-review-loop: disposition=rejected -->   Reject-with-explanation
<!-- pr-review-loop: disposition=deferred -->   Create-issue-and-close
```

Nothing for `Ask-user` — that thread is still open, so leave it open and unmarked.

The marker is machine-readable and the prose beside it is not, which is the point: the next run's cross-check takes the marker as decisive rather than inferring your intent from a sentence. But write the prose properly anyway. A rejection reading "rejected, see commit abc123" settles nothing for a reader who cannot see why, and the reader here includes the person reviewing your judgement later. Name the concern, say why the code is right as it stands, and keep it to a line or two.

**Findings with no thread.** Some findings arrive with nothing to reply on: a skeptic verdict names the ones it could not anchor (a deleted path, code the change never touched), and a bot that puts a concern in its review body rather than on a line has the same shape. Those get one PR-level comment per round instead, listing each with its path, a one-line restatement, and its disposition marker, and ending with:

```
<!-- pr-review-loop: dispositions -->
```

One comment per round, not one per finding. Its next run reads the PR's issue comments as part of the history payload and matches these entries on substance. Without it, exactly the findings that have no thread are the ones that come back every round forever — which is the same failure as skipping the replies, arriving through the one door replies can't cover.

## Issue creation (when choosing `Create-issue-and-close`)

Auto-create only if confident; else ask. Ensure the label exists, then create:

```bash
gh label create follow-up-from-pr-review --color 0E8A16 --description "Follow-up from AI PR review" 2>/dev/null || true
gh issue create --title "..." --body-file <path> --label follow-up-from-pr-review
```

The first line is a no-op when the label exists. The issue body links to the originating thread; the thread reply links back to the issue; then resolve the thread.

## Helpfulness reactions — thumbs-up / thumbs-down

Some reviewers invite a 👍/👎 reaction on whether a comment was useful (Codex is the current example). This applies **only** to a bot that both (a) invites the reaction in its comment body and (b) reads standard GitHub reactions. When present, react — mapped to whether you **accepted or rejected the underlying concern**, not whether you took its exact suggestion:

- **Accepted → 👍 (`+1`):** any `Fix-*` course or `Create-issue-and-close` (a real issue worth acting on, however addressed).
- **Rejected → 👎 (`-1`):** `Reject-with-explanation`.
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
- **Resolve a thread when:** Fixed (any variant), already-fixed, kicked-to-issue, OR Explanation-no-change (you've stated your reasoning; the reviewer can reopen). This is every course except `Ask-user`, and resolving is not optional bookkeeping — an unresolved thread is an undecided finding, and the next round treats it as one.
- **`already-fixed` is a course, not just a resolve category.** An earlier round handled the finding and the reviewer re-raised it against stale code: reply saying which commit, stamp `disposition=fixed`, resolve. It changes no code, so it is one of the three no-op dispositions that close a round without a push (SKILL.md step 4) — the one that is easy to miss, because its marker says `fixed`.
- **In a *terminating* round the courses are `rejected`, `deferred` and `Ask-user`** (SKILL.md step 4). `Ask-user` keeps the thread open and unmarked and routes the run to the paused outcome, so the security/auth default is not overridden by the round happening to be the last one. That pass pushes nothing, so "take the cheap correct ones now" does not apply to it: a non-blocking finding worth fixing makes the round non-terminal instead, and it goes through the normal fix→push→re-review path so the reviewer sees the result.
- **Do NOT resolve when:** awaiting clarification from a human, or `Ask-user` pending. Both are genuinely still open. Note that neither applies to skeptic, which cannot answer a question — where its finding leaves you uncertain, the question goes to the user, and the thread stays open and unmarked until they answer it.
