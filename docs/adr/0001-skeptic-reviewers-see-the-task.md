# 0001 — Skeptic reviewers see the task, not the author's account

Date: 2026-09-29. Status: accepted.

## Context

`pr-review-skeptic` was built to give an independent reviewer: one not talked round by the author's understanding of the code. As first written it withheld everything about the change's purpose — "the code is the specification". On a loop-driven PR, Copilot flagged that a fix missed the route the linked issue described; skeptic did not, because its reviewers could not know which route was asked for. Their reading of the code was correct; they simply had nothing to compare it against.

The intent was always independence from the **author**, not ignorance of the **task**. A reviewer that knows what was asked can say "this does not do what was asked" or "there is a more direct way to do what was asked"; one that does not can only say the code is internally consistent.

## Decision

Split what is withheld in two:

- **Given to reviewers:** what the change was asked to do — linked issues' title and opening body, and a user-stated intent comment, verbatim; failing both, a requirement distilled from the PR description by a separate subagent that strips implementation, design rationale and claims of correctness.
- **Still withheld:** the author's account — how it was meant to work, why it was built this way, commit messages, threads, and the rest of the PR description.

Where skeptic is a reviewer, `pr-review-loop` checks at kickoff that the task is on the PR and, where it is not, stops and asks the user, posting the answer as a marked comment. Only skeptic needs this: a review bot reads the PR description and linked issues on its own, while skeptic's reviewers see only the brief. The task never travels through the invocation, because under the loop the caller is the author.

## Consequences

- Reviewers can report a change that is correct line by line but misses the requirement.
- A requirement distilled from the description is author-written text passed through a filter; the filter can leak. It is the fallback, labelled as author-sourced, and never preferred over a requester-sourced source.
- Do not "restore" full blindness to purpose: that reintroduces the miss above. Do not widen `{{TASK}}` to carry the description wholesale: that reintroduces the author's account.
