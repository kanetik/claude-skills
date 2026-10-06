# 0002 — Copilot gets one late pass; minor findings batch; the task is frozen

Date: 2026-10-05. Status: accepted.

## Context

An audit of the review loop over 2026-09-21 to 2026-10-05 (12 repos, 219 PRs, 710 skeptic reviews, 193 Copilot reviews, 671 findings classified) found:

- Skeptic findings were rarely wrong (3% false, 2% duplicate) but half were minor (50%), mostly prose and doc staleness. The author marked 174 minor findings fixed, and each fix bought another review round. 67 `MEDIUM`s were prose staleness; `HIGH` was well calibrated (46 of 54 material).
- The blind pre-push checker made 231 material catches in 226 runs with almost no false ones, and the author dropped at least 37 of them.
- Copilot findings were 25% material and 19% false. 151 of 170 were never raised by skeptic, and only 13 overlapped skeptic's in the same round. Four material Copilot findings were still open on main because they arrived after the loop had converged. With Copilot in `reviewers`, a wakey run re-requested it on every push, exhausted the allowance, and could not converge when the request then registered nothing.
- The stage-6 cross-check ran 8 times, changed 5 outcomes, and never raised a severity.
- Composition-unit false findings were mostly re-argued scope the owner had settled in issue comments, which the reviewers never saw. Re-distilling the task each round produced different requirements on the same PR.
- One PR's skeptic findings were posted with no attribution lines: its review was assembled from memory without invoking the skill, and the loop's posted-review check did not look at attribution.

## Decision

- **Minor findings are batched or acknowledged, never fixed in the round.** `LOW`, and prose that describes code at any severity, take `Batch-for-close` (applied by one closing commit when the run would otherwise converge) or `Acknowledge-no-change`. Skeptic rates prose that describes code `LOW` at most; prose an agent executes is behaviour.
- **The pre-push check is a gate.** Every fix carries a one-line invariant; a material catch is fixed or answered before the push.
- **Copilot is a first-pass reviewer, requested once per PR on the converging commit**, never in `reviewers`. Its outcome — arrived, timed out, not available — is recorded on the PR. A record on the PR, not carried state, is what makes it once.
- **A Copilot fix is closed only by a closure check**: a non-reviewer agent that compares the comment, the fix diff, the file and every call site. Skeptic re-reads its own fixes; Copilot never does, so this is the only re-test those fixes get, and it runs outside the skeptic so its reviewers stay blind.
- **The cross-check stage is gone.** Skeptic matches findings to its own earlier threads (for placement) and to Copilot's (tagged `unfixed`, one severity higher), inline.
- **The task statement is built once and frozen** in the first review, including owner scope decisions from issue comments, and amended only by a `scope-decision` comment carrying the user's words.
- **Attribution is checked mechanically** before skeptic posts, and again by the loop after.

## Consequences

- A run converges with known minor defects applied in one commit rather than one round each; a run with none has no closing round.
- A Copilot review that never arrives costs at most `first_pass_wait_seconds`, and a not-available one costs nothing.
- A blocking finding re-found against an earlier rejection no longer arrives pre-sorted as `settled`; the author answers it again on its new thread, and the taper treats it as the old decision.
- Amends 0001: owner scope decisions are now part of what reviewers are given, distilled by their own filter.
