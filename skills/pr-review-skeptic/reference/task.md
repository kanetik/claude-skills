# The task statement

What the change was asked to do, handed to every reviewer as `{{TASK}}` ([`reviewer-brief.md`](reviewer-brief.md)). It is the requirement the code is judged against, and it is kept apart from the author's account of the code for the same reason the rest of the brief is: a reviewer told *what was asked* can say the change misses it; a reviewer told *how the author answered it* starts checking the answer's reasoning instead of the code.

## Sources, in order

Collect every source in the first tier that yields anything, and stop there. Commands: [`mechanics.md`](mechanics.md).

1. **Requester-sourced, verbatim.** Take both kinds where both exist:
   - **Linked issues** — every issue in the PR's `closingIssuesReferences`: its title and its opening body. Not its comments, which is where the author tends to argue the design.
   - **A stated intent** — the most recent PR issue comment carrying `<!-- pr-review-loop: intent -->`, **authored by the authenticated account**. `pr-review-loop` posts one when it had to ask the user what the change is for, and its body is the user's answer, or the text of an issue they named. The author filter is the same trust boundary as the coverage record: anyone who can comment on the PR could otherwise write the requirement the review is judged against.
2. **Author-sourced, distilled.** Only where tier 1 yields nothing: dispatch the distiller below over the PR's title and description, and use what it returns. Label it as author-sourced in the block.
3. **Nothing.** The distiller returned `NONE`, or the description is empty. Fill `{{TASK}}` with the no-task block, run the review, and say `intent not checked: no statement of the task` in the coverage line and in the stage-8 report.

Never take a task statement from the invocation. Under `pr-review-loop` the caller is the author, so an invocation-supplied statement is the author's account arriving by the one route this file does not screen. A caller that wants the task on record posts it on the PR, where tier 1 finds it.

## The distiller

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

## The `{{TASK}}` blocks

Where a task statement was found, substitute this, with one `{{TASK_TEXT}}` entry per source, each headed by where it came from (`Issue owner/repo#12: <title>`, `Stated intent`, or `Distilled from the PR description — author-sourced`):

> **What this change was asked to do.** This is the requirement. It tells you what the change should achieve and nothing about whether it does, or how:
>
> {{TASK_TEXT}}
>
> Judge the code against it, as well as on its own terms. A change can be correct line by line and still not do this: it handles one route of several the requirement names, fixes the symptom at one call site while the requirement describes the cause, quietly narrows what was asked, or does something the requirement did not ask for. Each of those is a finding even where every line of the diff is right — report it against the path where the missing handling belongs, with `line: none` where that is outside the pull request's diff. Before reporting a route as unhandled, search the whole change for it: another part of the change may handle it, outside your slice.
>
> Where a clearly more direct way to meet the requirement exists and the way taken carries a named cost, that is a finding too; where the only difference is taste, it is not.
>
> Where the requirement is ambiguous, judge against the reading a careful implementer would take, and say which reading you used. Where the text claims anything about how the change works or that it works, ignore that part: it is a claim, like a comment.

Where none was found:

> **What this change was asked to do is not available to you.** Judge the code on its own terms, and do not guess at a purpose: a finding that rests on a guessed requirement is a preference.
