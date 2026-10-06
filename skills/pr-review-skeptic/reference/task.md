# The task statement

What the change was asked to do, handed to every reviewer as `{{TASK}}` ([`reviewer-brief.md`](reviewer-brief.md)). It is the requirement the code is judged against, and it is kept apart from the author's account of the code for the same reason the rest of the brief is: a reviewer told *what was asked* can say the change misses it; a reviewer told *how the author answered it* starts checking the answer's reasoning instead of the code.

## Built once, then frozen

The statement is built on the first run over a PR and **frozen**: stage 7 writes it into the review body, and every later run reuses that text verbatim rather than re-reading the sources or re-running the distiller. Re-distilling each round gives each round a slightly different requirement, and reviewers judging against a moving requirement report differences in the requirement as defects in the code.

**Reading it back.** Take it from the authenticated account's most recent review that carries one ([`mechanics.md`](mechanics.md)), between the lines `<!-- pr-review-skeptic: task-begin -->` and `<!-- pr-review-skeptic: task-end -->`. The author filter is the same trust boundary as the coverage record: the frozen text decides what every later reviewer judges against. No such review, or one with no frozen block, means build it now.

**The one amendment.** Where a comment carrying `<!-- pr-review-loop: scope-decision -->`, by the authenticated account, has been posted on the PR or on a linked issue since the review the frozen text came from, append each such comment's body to the frozen statement as its own entry headed `Owner scope decision`, verbatim, oldest first. `pr-review-loop` posts these only with the user's own words in them, so they are requester text and are not distilled. Nothing else changes a frozen statement: an edited issue body or PR description does not. The amended statement is what this run freezes.

**A frozen statement with no requirement in it is the exception** — one with no `Issue`, `Stated intent` or `Distilled` entry: `NONE`, alone or with owner-decision entries. It records that no task was found, not a task. So whenever tier 1 now yields anything, build the statement as on a first run and freeze what that build returns. No timing test is needed: if tier 1 yields now and the frozen statement holds no requirement, the source appeared since.

## Building it — sources, in order

Commands: [`mechanics.md`](mechanics.md).

1. **Requester-sourced, verbatim.** Take both kinds where both exist:
   - **Linked issues** — every issue in the PR's `closingIssuesReferences`: its title and its opening body.
   - **A stated intent** — the most recent PR issue comment carrying `<!-- pr-review-loop: intent -->`, **authored by the authenticated account**. `pr-review-loop` posts one when it had to ask the user what the change is for, and its body is the user's answer, or the text of an issue they named. The author filter is the same trust boundary as the coverage record: anyone who can comment on the PR could otherwise write the requirement the review is judged against.
2. **Author-sourced, distilled.** Only where tier 1 yields nothing: dispatch the **requirement distiller** below over the PR's title and description, and use what it returns. Label it as author-sourced in the block.
3. **Nothing.** The distiller returned `NONE`, or the description is empty. Fill `{{TASK}}` with the no-task block, run the review, and say `intent not checked: no statement of the task` in the coverage line and in the stage-8 report.

**Then, whatever the tier, owner decisions.** Collect the comments on each linked issue and on the PR whose author association is `OWNER`, `MEMBER` or `COLLABORATOR` and whose body carries no `<!-- pr-review-` marker, plus every `scope-decision` comment above. Where there are any, dispatch the **decisions distiller** below over them and add what it returns as an entry headed `Owner decisions`. A requirement and the decisions made about its scope are both what was asked; without the second, a reviewer re-argues scope the owner already settled.

Never take a task statement from the invocation. Under `pr-review-loop` the caller is the author, so an invocation-supplied statement is the author's account arriving by the one route this file does not screen. A caller that wants the task on record posts it on the PR, where tier 1 or a `scope-decision` comment carries it.

## The requirement distiller

Dispatch one subagent with this as its entire prompt, the PR title and description appended, and `{{DELIVERY}}` filled as for a reviewer with "the block" in place of "the blocks":

> Below is a pull request's title and description, written by its author. Extract **what the author was asked to do** — the problem being fixed or the capability being added, and the behaviour that should hold once it is done, including every case, route, input or entry point the text says should be covered.
>
> Leave out everything about **how** it was done or **whether** it works: the implementation, the files or functions touched, design choices and the reasons for them, alternatives considered, test results, and any claim that the change is correct, complete or safe. Those are the author's account of the answer, and your reader is judging the answer.
>
> Write it in the requester's terms, as a requirement, in as few sentences as carry it. Do not add anything the text does not say. Return exactly one block:
>
> ```
> TASK
> <the requirement>
> ```
>
> or, where the text says only what was changed and never what problem or goal it serves, return `NONE`. {{DELIVERY}}

A returned requirement that names files, functions or a mechanism has let the answer through: drop those clauses before substituting it, and where nothing is left, treat it as `NONE`.

## The decisions distiller

Same dispatch, with this prompt and the comments appended, each headed by where it was posted:

> Below are comments by a project's owners on an issue and on the pull request that addresses it. Extract **only the decisions they made about scope**: what the change must cover, what it deliberately does not, and any limitation or behaviour they accepted. One line per decision, in their terms.
>
> Leave out everything else: how the change is or should be implemented, the reasons for any design, status updates, questions, and any claim that the change works. Do not add a decision the text does not make. Return exactly one block:
>
> ```
> DECISIONS
> - <decision>
> ```
>
> or `NONE` where no comment makes a scope decision. {{DELIVERY}}

The same screen applies to what comes back: a line naming files, functions or a mechanism is dropped.

## The `{{TASK}}` blocks

Where a task statement was found, substitute this, with one `{{TASK_TEXT}}` entry per source, each headed by where it came from (`Issue owner/repo#12: <title>`, `Stated intent`, `Distilled from the PR description — author-sourced`, `Owner decisions`, or `Owner scope decision`):

> **What this change was asked to do.** This is the requirement. It tells you what the change should achieve and nothing about whether it does, or how:
>
> {{TASK_TEXT}}
>
> Judge the code against it, as well as on its own terms. A change can be correct line by line and still not do this: it handles one route of several the requirement names, fixes the symptom at one call site while the requirement describes the cause, quietly narrows what was asked, or does something the requirement did not ask for. Each of those is a finding even where every line of the diff is right — report it against the path where the missing handling belongs, with `line: none` where that is outside the pull request's diff. Before reporting a route as unhandled, search the whole change for it: another part of the change may handle it, outside your slice.
>
> **Owner decisions are settled scope.** What they exclude is not missing, and what they accept is not a defect; do not report either. A consequence a decision did not cover is still yours to report.
>
> Where a clearly more direct way to meet the requirement exists and the way taken carries a named cost, that is a finding too; where the only difference is taste, it is not.
>
> Where the requirement is ambiguous, judge against the reading a careful implementer would take, and say which reading you used. Where the text claims anything about how the change works or that it works, ignore that part: it is a claim, like a comment.

Where none was found:

> **What this change was asked to do is not available to you.** Judge the code on its own terms, and do not guess at a purpose: a finding that rests on a guessed requirement is a preference.

## Freezing it — what stage 7 writes

The `{{TASK_TEXT}}` entries exactly as substituted, or the line `NONE`, between the two marker lines, inside a collapsed block so it does not crowd the verdict:

```
<details><summary>Task judged against</summary>

<!-- pr-review-skeptic: task-begin -->
<the entries>
<!-- pr-review-skeptic: task-end -->

</details>
```

`NONE` is frozen too: a PR with no statement of its task does not re-run the distiller every round in the hope of a different answer. It keeps none until tier 1 yields (above), and a `scope-decision` comment may still be appended meanwhile.
