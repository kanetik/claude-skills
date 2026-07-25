# Evaluating reviewer feedback (SKILL.md step 5 detail)

## What to read

**Threads are the unit of evaluation.** Fetch unresolved review threads with full comment lists via paginated GraphQL (`reference/mechanics.md`); they cover inline AND file-level comments (`line: null`) and carry the conversation context (human replies) the per-review REST endpoint omits. **Also read each review's `body`** separately — bots sometimes put findings, qualifiers, or "no issues" there with no thread. **And read bot-authored PR issue comments** — the third surface (SKILL.md "Reading reviewer state"); some bots deliver findings or their whole clean verdict only here. Any state check must union all three. (The REST endpoint `/repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` is a convenience for one review's comments by ID; for the whole-PR view, paginated `reviewThreads` is canonical.)

**Human replies are evaluation INPUT, not a post-hoc check.** Read replies from the author/maintainers BEFORE forming your evaluation — they often steer ("we're doing it this way because…", "ignore for now", "fix narrowly, broader cleanup is tracked elsewhere") and weigh heavily, often decisively. If a human reply directly conflicts with the lens-weighted evaluation (reply says "ignore" but lenses say it's a real project-breaking bug), surface the conflict — don't silently obey or override.

## The integrated judgement

Hold three lenses and the mindset as a **single integrated judgement**, not a sequential rubric, with human replies as weighted input.

**Lenses (most → least important, all in play at once):** what's best for the **project as a whole** (most) · the **PR overall**, including its larger intent (slightly less) · the **specific item** on its own (slightly less again).

**Mindset:** Steelman the reviewer's underlying concern — their suggested fix is one possible response, not necessarily the best; separate "is there a real issue?" from "is their fix the right one?" The decision space is broader than {accept their fix, reject}. Don't get into pissing contests or be defensive about prior choices; equally, don't capitulate to taste asks when the lens-weighted view says the code is correct. `Reject-with-explanation` is for "concern understood AND lenses support the current code" — not stylistic disagreement.

## Courses of action

`Fix-as-suggested` · `Fix-differently` (better way to address the same concern) · `Fix-broader` (the real issue is bigger) · `Reject-with-explanation` · `Create-issue-and-close` (real but genuine scope-creep — NOT "broken, fix later") · `Ask-user` (genuinely uncertain).

**Default to `Ask-user` for:** security/auth-adjacent changes; scope-creep boundary calls; conflicting reviewer asks; big-impact architectural feedback.

## Writing the fix without causing the next finding

**Applies to fixes for correctness, concurrency and data-handling findings** — not to typos, formatting or doc wording, where being approximately right costs nothing.

For those, a fix written against the *finding* rather than the *invariant* closes the path the reviewer described and leaves its siblings open. This is the loop's characteristic failure — the defect arrives in the fix, so the round that introduced it looks like progress — and it is why iteration counts climb. Three checks before pushing one:

- **Name the invariant, not the scenario.** State in one line the property that must hold ("a viewing never lands on an episode the user didn't watch"), then check the fix against *that*. The reviewer's scenario is one route to violating it; fixing only that route is how the second route survives. Reach for this hardest on data-correctness findings — where the lenses above say the project-level cost of being wrong is high.
- **Ask what already does this.** Before writing a predicate, a dispatcher, a null check — look for the seam that exists. Re-implementing a rule the codebase already encodes (a `Ref.isEmpty`, a project `ioDispatcher`) means the copy drifts from the original the first time either changes. A hand-rolled duplicate of an existing rule is a defect with a delay fuse.
- **Check the fix didn't weaken the tests.** A test edited while fixing a finding can end up asserting less than it did before, and it still passes — that is what makes it invisible. If a guard is added, disable it and confirm its test fails; if a fixture is changed, confirm the assertion still depends on what it claims to prove.

## Upfront gate triage (SKILL.md Phase 0)

The gate reuses everything above — same surfaces, lenses, courses — but adds one decision, because its job is to decide *what the gate does next*. Read the whole verdict together. A clean verdict, or one whose findings all resolve **without a code change** (`Create-issue-and-close` / `Reject-with-explanation`), **satisfies the gate** — deferred findings need no re-review. For actionable findings, sort into:

- **Actionable-clear.** Confident there's a real issue *and* what the correct change is — some `Fix-*` you'd stand behind. **Size is irrelevant** (one-line rename = structural redesign here). → Apply, re-request the gate bot(s), and **repeat to clean**: the gate's re-review sub-loop runs until every gate bot signs off on what you changed.
- **Actionable-unclear.** A genuine judgement call: multiple viable approaches, the concern is real but the fix is contestable, or it's security/auth/data-model/API-contract-adjacent (the `Ask-user` default, surfaced at gate time). → Pause and ask the user before the loop runs; their answer may turn it into a clear fix (then re-review to clean) or a reject.

The split is **certainty of the path, not size.** When a verdict mixes findings, the most conservative present outcome wins: any actionable-unclear routes the whole gate to `Ask-user` (you may still apply the unambiguous fixes in the same push), and the gate isn't satisfied until both the unclear question is settled and the bot has re-reviewed the result clean.

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

- **Replies should be one line where possible.** @-mention a bot back only when the mention reaches that reviewer and it acts on mentions (`@codex` yes; Copilot's reviewer no — reply unmentioned). See `reference/mechanics.md`.
- **Comment line numbers may be stale** — locate by content if the line doesn't match.
- **Resolve a thread when:** Fixed (any variant), already-fixed, kicked-to-issue, OR Explanation-no-change (you've stated your reasoning; the reviewer can reopen).
- **Do NOT resolve when:** awaiting reviewer clarification (your reply asks the reviewer something); acknowledged-without-fix where discussion is still expected.
