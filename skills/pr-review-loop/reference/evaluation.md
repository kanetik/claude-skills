# Evaluating reviewer feedback (SKILL.md step 5 detail)

## Threads are the unit of evaluation — not individual review comments

Before evaluating anything, fetch unresolved review threads with their full comment lists via paginated GraphQL (`reference/graphql.md`). Threads cover both inline comments and file-level comments (`line: null`). The threads view also gives you the conversation context (human replies) that the per-review REST endpoint does NOT show.

**Also check each review's body separately.** A review's `body` field (the summary written when submitting) is distinct from threads — bots sometimes put high-level findings, approval qualifiers, or "no issues found" there. Fetch via `gh pr view <num> --json reviews` or GraphQL `reviews(...){nodes{body, comments{totalCount}}}`. Treat any unaddressed concern in `Review.body` as a finding even if no thread was created for it.

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

## Issue creation (when choosing `Create-issue-and-close`)

Auto-create only if you're confident; otherwise ask. Ensure the label exists, then create:

```bash
gh label create follow-up-from-pr-review --color 0E8A16 --description "Follow-up from AI PR review" 2>/dev/null || true
gh issue create --title "..." --body-file <path> --label follow-up-from-pr-review
```

The first line is a no-op when the label already exists. Issue body links to the originating thread; the thread reply links back to the issue; then resolve the thread.

## Replies, line numbers, resolution

- **Replies should be one line where possible.** Tag the reviewer when the reply needs a response (`@copilot` / `@codex`).
- **Comment line numbers may be stale** — locate by content if the line doesn't match.
- **Resolve a thread when:** Fixed (any variant), already-fixed, kicked-to-issue, OR Explanation-no-change (you've stated your reasoning; the reviewer can reopen).
- **Do NOT resolve when:** Clarify-needed (waiting on the reviewer); acknowledged-without-fix where discussion is still expected.
