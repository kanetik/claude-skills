# Evaluating reviewer feedback (SKILL.md step 5 detail)

## Threads are the unit of evaluation — not individual review comments

Before evaluating anything, fetch unresolved review threads with their full comment lists via paginated GraphQL (`reference/graphql.md`). Threads cover both inline comments and file-level comments (`line: null`). The threads view also gives you the conversation context (human replies) that the per-review REST endpoint does NOT show.

**Also check each review's body separately.** A review's `body` field (the summary written when submitting) is distinct from threads — bots sometimes put high-level findings, approval qualifiers, or "no issues found" there. Fetch via `gh pr view <num> --json reviews` or GraphQL `reviews(...){nodes{body, comments{totalCount}}}`. Treat any unaddressed concern in `Review.body` as a finding even if no thread was created for it.

**And check bot-authored PR issue comments — a third surface.** Some bots deliver findings, or their entire clean verdict, as a plain PR issue comment rather than a formal review or a thread. Any state check — manual or programmatic — MUST union all three surfaces: reviews + review threads + bot issue comments. A reviews-only check is the specific trap that stranded a live run: it reported a bot as "pending" when the bot had been happy for minutes, its clean verdict sitting in an issue comment. Read a comment's disposition from its content (concerns raised vs. clean pass), judged the same way as a review body — not by matching fixed phrases.

The REST endpoint `/repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` is a convenience for one review's inline + file-level comments by review ID — same comments as `reviewThreads` filtered to that review. Use it when you have a specific review ID; for the whole-PR view, paginated `reviewThreads` is canonical.

## Human replies are evaluation INPUT, not a post-hoc check

When a thread has replies from the PR author, maintainers, or other humans, read them BEFORE forming your evaluation. They often contain steering — "we're doing it this way because…", "ignore for now", "fix narrowly, broader cleanup is tracked elsewhere" — and should weigh heavily, often decisively. Don't evaluate the bot's text first and then "check" replies as a sanity step; the reply is part of the comment's context. If a human reply directly conflicts with the lens-weighted evaluation (reply says "ignore" but lenses say it's a real project-breaking bug), surface the conflict to the user — don't silently obey or override.

## The integrated judgement

Hold three lenses and the mindset below as a **single integrated judgement** — not a sequential rubric. All aspects shape the decision simultaneously, with human replies as additional weighted input.

**Lenses, weighted (most → least important, all in play at once):**

- What's best for the **project as a whole** (most important).
- What's best for the **PR overall**, including its larger intent when clear (slightly less).
- What's best for the **specific item** on its own (slightly less again).

**Mindset (woven into the lens evaluation):**

- Steelman the reviewer's underlying concern. Their suggested fix is ONE possible response — it may not be the best one. Separate "is there a real issue?" from "is their proposed fix the right one?"
- The decision space is broader than {accept their fix, reject}. Pick the BEST course under the lens-weighted view.
- Don't get into pissing contests; don't be defensive about prior choices. Equally, don't capitulate to taste/preference asks when the lens-weighted evaluation says the current code is correct.
- "Reject-with-explanation" is reserved for cases where the concern is understood AND the lens-weighted view supports the current code — not stylistic disagreement.

## Possible courses of action

`Fix-as-suggested` · `Fix-differently` (better way to address the same concern) · `Fix-broader` (the real issue is bigger) · `Reject-with-explanation` · `Create-issue-and-close` (real but genuine scope-creep — NOT "broken, fix later") · `Ask-user` (genuinely uncertain).

**Default to `Ask-user` for:** security/auth-adjacent changes; scope-creep boundary calls; conflicting reviewer asks; big-impact architectural feedback.

## Upfront gate triage (SKILL.md Phase 0)

The upfront adversarial gate reuses everything above — same three surfaces, same lenses, same courses of action — but adds one classification on top, because its job is to decide *what the gate does next*, not just how to handle one thread. Read the whole verdict together (batch judgement) and sort it into one of three outcomes:

- **Minor.** Localized, low-risk changes — the kind the convergence loop handles every iteration: a rename, a missing guard, a doc fix, a small bug, a narrow refactor. Course is some `Fix-*`, the change is small and self-evidently correct, and it doesn't alter the PR's approach. → Apply, then start the loop. No gate re-review.
- **Major, path clear.** Structural/design-level — changes the approach, touches many files, or alters the PR's intent — **and** you're confident both that there's a real issue *and* what the correct change is (`Fix-broader` / `Fix-differently` with high certainty). → Apply, re-request the gate bot, repeat to clean.
- **Major, path unclear.** Structural **and** a genuine judgement call: multiple viable approaches, the reviewer's concern is real but the fix is contestable, or it's security/auth/data-model/API-contract-adjacent. This is the existing `Ask-user` default for "big-impact architectural feedback," just surfaced at gate time. → Pause and ask the user before the loop runs.

The split between the two major outcomes is **certainty of the path forward**, not size — a big change you're sure of is "clear"; a small-looking change with contested direction can still be "unclear." When a verdict mixes findings, the most conservative present outcome wins: any major-unclear finding routes the whole gate to `Ask-user` (you may still apply the unambiguous fixes in the same push), and only with no major-unclear finding do the major-clear or all-minor outcomes apply. `Reject-with-explanation` (a gate finding that doesn't hold up under the lenses) and `Create-issue-and-close` (real but genuine scope-creep) behave as everywhere else and don't block the gate.

## Issue creation (when choosing `Create-issue-and-close`)

Auto-create only if you're confident; otherwise ask. Ensure the label exists, then create:

```bash
gh label create follow-up-from-pr-review --color 0E8A16 --description "Follow-up from AI PR review" 2>/dev/null || true
gh issue create --title "..." --body-file <path> --label follow-up-from-pr-review
```

The first line is a no-op when the label already exists. Issue body links to the originating thread; the thread reply links back to the issue; then resolve the thread.

## Helpfulness feedback — thumbs-up / thumbs-down

Some reviewers end a comment by inviting a reaction on whether it was useful — "React with 👍 or 👎 to indicate if this comment was helpful", "Was this comment useful?", or similar (Codex is the current example). This applies **only to a bot that both (a) invites the reaction in its comment body and (b) reads standard GitHub reactions** — those are the ones a reaction actually steers. When a comment carries that invitation, leave a reaction so the bot gets the steering signal, mapped to whether you **accepted or rejected the underlying concern** — NOT whether you took its exact suggestion:

- **Accepted → 👍 (`+1`).** Any `Fix-*` course (`Fix-as-suggested`, `Fix-differently`, `Fix-broader`) or `Create-issue-and-close` — the comment surfaced a real issue worth acting on, even if you addressed it differently than suggested.
- **Rejected → 👎 (`-1`).** `Reject-with-explanation` — the concern didn't hold up under the lens-weighted view.
- `Ask-user`, or any thread still awaiting reviewer clarification — don't react yet; wait until it settles into an accept or reject.

**Not every 👍/👎 you see is a standard reaction.** Copilot's review comments render their own *"was this helpful"* thumbs widget (beside "Copilot uses AI. Check for mistakes."); that is a closed GitHub-UI control feeding Copilot's own model: it isn't wired to standard GitHub reactions and has no API of its own, so you can't set it. (You *can* still add a normal emoji reaction to a Copilot comment via the reactions/`addReaction` API — it just doesn't touch the widget.) So don't treat a Copilot finding as a reaction-invitation. The reactions this skill uses are the standard emoji-picker reactions on a comment (a different signal), and the invitation must be in the comment body.

When a reaction mechanism is available (the `gh`/REST calls below, or an equivalent reactions API/MCP path), react on whichever comment the invitation is attached to. Inline/file-level review comments use the pulls-comments reactions endpoint; an invitation on a PR-level issue comment uses the issue-comments endpoint. (A review *summary* (`PullRequestReview`) has no REST reactions endpoint, but it IS reactable via GraphQL — `addReaction(input:{subjectId:<review node id>, content: THUMBS_UP|THUMBS_DOWN})` — so when a helpfulness prompt rides only a summary, react via GraphQL/MCP if you have that path, and fall back to the written reply only if you don't.) Both REST endpoints take the comment's numeric `databaseId`, not a GraphQL `IC_…`/`PRRC_…` node ID:

```bash
# Inline or file-level review comment (numeric databaseId from the reviewThreads query):
gh api repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions -X POST -f content=+1   # or -1
# PR-level issue comment (numeric databaseId — NOT a GraphQL IC_ node ID):
gh api repos/<owner>/<repo>/issues/comments/<comment_id>/reactions -X POST -f content=+1  # or -1
```

This reaction is the signal the bot uses to learn what kind of feedback is valued — when a reaction path exists, apply it whenever the invitation is present, in addition to (not instead of) the written reply. If your environment has no way to react (no `gh`, no reactions API/MCP path), skip it gracefully: it's an optional steering signal, not a requirement, and the written reply still carries the substance.

## Replies, line numbers, resolution

- **Replies should be one line where possible.** **@-mention a bot back only when the mention reaches that reviewer and it acts on mentions.** `@codex` does — Codex re-engages on mention, so lead Codex replies with it. Copilot's *reviewer* does NOT act on reply mentions, and `@copilot` routes to Copilot's separate coding agent (`copilot-swe-agent`), which just misfires — so reply to Copilot **without** an @-mention. General rule for any new bot: mention it only if its handle reaches the reviewing service and that service acts on mentions; if unsure, post the reply unmentioned.
- **Comment line numbers may be stale** — locate by content if the line doesn't match.
- **Resolve a thread when:** Fixed (any variant), already-fixed, kicked-to-issue, OR Explanation-no-change (you've stated your reasoning; the reviewer can reopen).
- **Do NOT resolve when:** awaiting reviewer clarification (your reply asks the reviewer something); acknowledged-without-fix where discussion is still expected.
