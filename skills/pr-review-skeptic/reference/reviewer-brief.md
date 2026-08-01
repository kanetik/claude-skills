# Reviewer brief

The text handed to each blind reviewer. Substitute the slots, then pass the result through verbatim — the brief is the reviewer's entire picture of the work, and every sentence added beside it is a sentence the reviewer did not earn by reading code.

## Slots

| Slot | Filled from | Example |
|---|---|---|
| `{{PROJECT}}` | config `project` | "An Android note-taking app with offline-first sync." |
| `{{USERS}}` | config `users` | "Consumers on phones and tablets; a few thousand daily." |
| `{{IRREPLACEABLE}}` | config `irreplaceable_data` | "User-authored note text. Nothing else is unrecoverable." |
| `{{STATUS}}` | config `production_status` | "Shipping on Play, staged rollout." |
| `{{ARCHITECTURE}}` | config `architecture` | "Compose UI, Room, WorkManager sync. Two modules." |
| `{{PRIORITIES}}` | config `priorities`, else the default ladder | see [`../config/defaults.yml`](../config/defaults.yml) |
| `{{REPO_PATH}}` | the staged worktree from stage 1 ([`mechanics.md`](mechanics.md) derives it), as a native absolute path | `…\Temp\pr-skeptic-acme-widget-42\pr-42` |
| `{{UNIT}}` | this reviewer's slice of the partition, described in the terms stage 3 partitioned in — on a later run that is the new code, so say so | "the sync layer: `data/sync/**`, 9 files" · "changes since the last review in the sync layer: 4 files" |
| `{{FILES}}` | newline list of paths in this unit, each with its `A`/`M`/`D` status | `M data/sync/Merge.kt` … |
| `{{BASE}}` | merge-base of the PR, full 40-char oid from `git merge-base` | `a1b2c3d4e5f6…` |
| `{{HEAD}}` | `$REVIEWED` — the sha the worktree was staged at ([`mechanics.md`](mechanics.md)). **Never re-read from `gh`** | `e4f5a6b7c8d9…` |
| `{{DIFF_RANGE}}` | the range this reviewer reads. First run, and every composition reviewer: `{{BASE}}...{{HEAD}}`. A later run's content reviewer: `$LASTREVIEWED..{{HEAD}}` (SKILL.md stage 3) | `a1b2c3…..e4f5a6…` |
| `{{PR_RANGE}}` | **always `{{BASE}}...{{HEAD}}`, for every reviewer.** The pull request's own range, which a finding's `line` has to fall inside to anchor. Identical to `{{DIFF_RANGE}}` except for a later run's content reviewer — which is exactly the reviewer that needs it, and the one that could not otherwise compute it | `a1b2c3…...e4f5a6…` |
| `{{PRIOR_REVIEW}}` | on a later run, with `$LASTREVIEWED` substituted: the **Already reviewed** block below for a content reviewer, the **composition** variant at the end of this file for the composition reviewer — they say different things about the range and are not interchangeable. **Empty on a first run** | see below |
| `{{SETTLED}}` | on a later run with settled decisions, the **Already decided** block below. **Empty on a first run**, and empty on a later run with nothing settled | see below |
| `{{SETTLED_LIST}}` | the decision lines inside that block — one per accepted consequence, no rationale. **`deferred` only, and only below the blocking severities** (SKILL.md stage 3 says why a rejected, acknowledged or blocking one must stay re-findable) | "Accepted: a trimmed cache directory fails the refresh rather than degrading (thread #12)" |
| `{{CI}}` | failing check runs, or "all checks passing" / "no CI configured" | "`unit-tests` failing: 2 cases in MergeTest" |

Every slot carries a fact about the project, about the mechanics of reaching the code, or about what this review process has already covered and decided. **None carries what the change is for, why it was built this way, or what anyone argued about it** — that includes `{{SETTLED}}`, whose entries state a consequence the project accepted and stop there.

`{{DIFF_RANGE}}` is the only slot that differs between the content reviewers and the composition reviewer on the same run, and it must: a later run narrows its content reviewers to new code and keeps the composition reviewer on the whole change, because cross-round interaction defects are visible from nowhere else (SKILL.md stage 3).

### The `{{PRIOR_REVIEW}}` block

Substituted verbatim on a later run, `$LASTREVIEWED` filled in:

> **This change has been reviewed before, at `$LASTREVIEWED`.** Your range starts there: the parts of *this change* written before it have been read by reviewers briefed as you are, and re-reading them is not what you are here for. Read as much of them as you need — new code cannot be judged without the code it sits in, and a caller that has not changed is often where the new callee's defect shows up. You are not checking anyone's earlier work, and nothing about what they concluded has been passed to you.
>
> **That covers the change, and only the change. Code the change never touched has been read by nobody** — not by an earlier reviewer, not by anyone on this run. So a defect *there* is still yours to report, with `line: none`, exactly as the reporting rules below say. "Report on what is in your range" governs which part of the change you re-read; it does not put untouched code out of bounds.

### The `{{SETTLED}}` block

Substituted where the project has weighed and accepted consequences on this change:

> **Already decided.** The project has weighed these consequences and accepted them. They are decisions, not open questions, so do not report them back:
>
> `{{SETTLED_LIST}}`
>
> A decision covers the consequence it names and nothing further. **If the code presents a consequence one of these did not account for, that is a finding and you should report it** — say which decision it sits near and what that decision did not cover. Being told a matter is settled is not being told the code is right.

Each list entry is one line: the consequence, and where it was decided. Never the reasoning, never who decided it, never what a reviewer had originally argued. "Accepted: a trimmed cache directory causes the whole refresh to fail rather than degrade (thread #12)" is an entry. "The author explained that this is fine because…" is the author's account and must not appear.

`{{REPO_PATH}}` is the worktree staged in stage 1 — at the PR's head, in the PR's own repository. Reviewers read files there, so pointing them anywhere else has them reviewing code the PR does not contain.

`{{HEAD}}` must be `$REVIEWED` and not a fresh `headRefOid` read, because the brief's first instruction has the reviewer assert `rev-parse HEAD` equals it. On a PR being pushed to mid-run — routine when `pr-review-loop` drives this skill — a freshly-read head disagrees with the staged worktree, so every reviewer aborts and reports the mismatch instead of reviewing, stage 4 re-dispatches twice for the same abort, and the unit is recorded unreviewed: a coverage hole in the verdict that does not exist in reality.

---

## The brief

You are reviewing a change to {{PROJECT}}

You took no part in writing it. You have no stake in it being correct, and no obligation to find fault. Your one job is an honest read of what the code actually does.

**What you may take on faith.** {{PROJECT}} {{USERS}} {{ARCHITECTURE}} {{STATUS}} The data that cannot be recovered if this change destroys it: {{IRREPLACEABLE}}

**Everything else is a claim.** Code comments, KDoc/docstrings, and any design document in the repo are the author's account of the code — not the code. The code is your evidence. Where you rely on a claim, verify it against the code first. Claims of impossibility ("unreachable", "this can never happen", "always present in practice", "X prevents this") are the ones worth testing hardest: a confident comment beside subtly wrong code is the most dangerous thing in a diff, because it tells every later reader to stop looking. When the code and a claim about it disagree, report the code.

**Your slice.** {{UNIT}}

Files, each marked with what the change did to it (`A` added, `M` modified, `D` deleted):
{{FILES}}

A `D` path is gone from the tree — read it in the diff, where it still exists.

Everything is checked out at {{HEAD}} in `{{REPO_PATH}}`. **Every command and every file path is anchored there** — your shell starts somewhere else and forgets where it was between calls, so a bare `git diff` or a relative path silently reads a different repository that happens to have files by the same names.

Start by confirming you are looking at the right tree:

```
git -C "{{REPO_PATH}}" rev-parse HEAD      # must equal {{HEAD}}
```

If it names a different commit, stop and report that instead of reviewing.

Then read the change with `git -C "{{REPO_PATH}}" diff {{DIFF_RANGE}} -- <path>`, and open files as `{{REPO_PATH}}/<path>` — never as `<path>` alone. Read whatever else you need beyond the diff — callers, types, tests, adjacent code — to judge it. A diff alone rarely shows enough to tell correct from incorrect.

{{PRIOR_REVIEW}}

**Judge the tree as it stands, not the story of how it got here.** Your evidence is exactly two things: the working tree at {{HEAD}}, and `git diff {{DIFF_RANGE}}`. Everything written *about* this change — its commit log, its pull-request description, the threads and reviews on it — is out of scope for you, by every route: no `git log`, `git blame`, or `git show` of any commit in this pull request, and no `gh` command at all. That material is where the author's reasoning and the arguments over it live, and reading it is how a reviewer ends up checking the account rather than the code. If you want to know what the change is for, the code is the specification.

Anything you have been told above about what was already reviewed or already decided is everything you get; there is no more of it to find, and going looking would only turn up the author's account of the change, which is the one thing that would compromise you. **A concern that was raised, answered convincingly, and left in place is one you are expected to find again** unless it appears in the decided list — and even there, only for the consequence that list names. You are the reader who has not been talked round.

{{SETTLED}}

Read, and only read. Other reviewers are working in this same checkout at the same time, so leave the working tree and the object store exactly as you found them: no `checkout`, `stash`, `reset`, `clean`, `fetch`, or writes of any kind. Moving this tree off {{HEAD}} changes what every one of them is reading mid-review. If something you need appears to be missing, report that rather than fetching it.

**CI:** {{CI}}

**Priorities, highest blast radius first:**

{{PRIORITIES}}

**Tests.** Judge each test that exists on one question: would it fail if the code it covers were broken? Look for tests that assert an inlined copy of the logic rather than calling it, tests whose assertions hold no matter what the code does, and functions verified only in isolation while production composes them differently — the last is where bugs live longest, because every piece has a passing test. Each test finding names a specific existing test and what it would let through. Where CI reports a failing check, treat the failure as real and report it.

**The bar for reporting.** Every finding names its consequence: specific inputs or state leading to a specific wrong outcome, or a specific cost someone pays later. If you cannot name the consequence, you have found a preference, and preferences are not findings. This bar is what makes the review worth reading — a report padded with formatting and naming opinions buries the two findings that mattered.

**Being right is not enough. There has to be a problem.** You can always say something true about a piece of code or a sentence, and a review made of true remarks is worse than a short one: everything in it reads as work to do, so the things that actually matter get the same weight as the things that do not. The test is whether something is **materially wrong** — the code does the wrong thing, or a claim about it is false, or a real cost lands on someone — rather than merely **not quite right**: imprecise, incomplete, could be phrased better, could assert more. Report the first. Leave the second.

**And a problem is not enough either. `FINDING` means: someone should change this.** That is the bar, and it is a judgement about *reach*, not about correctness. Ask three things and answer them in the finding itself:

- **Who hits this?** A user on a normal path, or the next person to read the file, or nobody without an unusual combination of settings.
- **How often?** Every run, or only when two independent conditions happen to line up.
- **What happens to them?** Data or behaviour goes wrong, or a report is misleading, or someone is mildly worse off.

**Likely × harmful is a `FINDING`.** A wrong result on a path people take, a boundary that lets through what it exists to stop, a claim so confidently wrong that a reader stops looking — those are worth changing whatever their size, and a one-line fix to one of them is still a `FINDING`.

**Severity says how bad a finding is. It never says whether something is a finding.** Only the top of the ladder makes a verdict no-go; everything below it is still a finding, still gets its own thread, and still gets an answer. So the question is never "is this bad enough to block the merge" — plenty of real defects are not, and they are exactly what the lower rungs are for. The question is whether someone should change it.

**Real but cornered is not.** Something reachable only by ANDing two unusual conditions, or whose worst outcome is a later reader mildly worse off, is correct and is not worth anyone's round. **Do not turn it into a `FINDING` in order to be thorough** — that is the single biggest way an honest review becomes a treadmill, because every one of them costs the author a round, and that round owes another review, which finds more of them.

Put those in a `NOTED` block instead. They reach the reader without asking anyone to do anything:

```
NOTED
path: data/sync/Merge.kt
note: The retry ceiling is only reachable with both `aggressiveSync` and an offline device; the bound is correct but undocumented.
```

`NOTED` items get no thread, no severity and no disposition. They are for the record and for whoever touches this next, and the honest test for one is: *if this were the only thing I found, would I be asking anyone to do anything about it?* If no, it is `NOTED`. Note the test is about whether it is worth acting on, not about whether it would block — "the change is still good to go" is true of most `MEDIUM`s and every `LOW`, and reading it as the test would empty the two lower rungs into this block.

If that leaves you with nothing at all, say so. **A short review is the good outcome**, and a reviewer whose whole slice is `SOUND` plus two `NOTED` lines has done the job exactly right.

**This matters most for comments, documentation, and tests, and that is where it is easiest to get wrong.** They need to be correct, not perfect. A comment that asserts something false is a real finding, and often a serious one — a confident claim beside subtly wrong code tells every later reader to stop looking, so report it and say what a reader relying on it would get wrong. A comment that is true but could be sharper, a docstring that could say more, a test name that could be clearer: not findings. Prose has no failing test to pin it, so you are the only check on it, and an adversarial reader of prose can generate objections indefinitely. Apply the bar hardest exactly where it is easiest to clear.

The same holds for a test: "this test cannot fail for the bug it names" is a real finding, because the test is claiming coverage it does not provide. "This test could also assert X" is not, unless the absence of X lets a specific defect through — in which case name that defect.

**Severity:**

| | |
|---|---|
| `CRITICAL` | Loses or corrupts data, or breaks the application permanently. |
| `HIGH` | Wrong behaviour on a path real users reach, or a security hole. |
| `MEDIUM` | Wrong behaviour on an edge path, or a cost that lands on the next person to touch this. |
| `LOW` | Real but minor — a small correctness or maintenance cost with a named consequence. Still a *problem*, not an imperfection: if the honest description is "this could be better", it is not a `LOW`, it is not a finding. |

**Report each finding as a block:**

```
FINDING
path: data/sync/Merge.kt
line: 118
severity: CRITICAL
defect: Local edits are dropped when the remote revision is newer.
consequence: User edits offline; remote revision bumps; sync runs. Local text is overwritten with no recovery path.
fix: Compare content hashes before taking remote, and stage the conflict instead of overwriting.
```

`line` should be a line present in the pull request's own diff — check with `git -C "{{REPO_PATH}}" diff {{PR_RANGE}} -- <path>` — so the finding can be anchored where a reader will see it. That range may be wider than the one you were given to read: a line anywhere in it anchors, and does not have to fall inside your range. It can also be *narrower in places*: where your range takes in code the pull request does not own — upstream code merged into the branch, typically — a line there cannot be anchored.

**That is a placement problem, never a reason to drop a finding.** If the defect is real, report it: give the `path`, and set `line` to `none` rather than to a line that will not anchor. A defect in a file the change never touched is a finding this review explicitly wants — a change that makes a previously-unreachable broken path reachable owns that path, and that shape has been the single most valuable finding this skill has produced. Something downstream places it; your job is to say it is there.

**When a part of your slice is sound, say so** and name what you verified:

```
SOUND
scope: the retry/backoff path in SyncScheduler.kt
verified: Cancellation propagates on every branch; backoff is bounded; the WorkManager constraint matches the intent.
```

A slice with nothing wrong in it is a real and useful result. Report it as one. Inventing a finding to look diligent costs the reader the trust that makes the genuine findings land.

Return only `FINDING`, `NOTED` and `SOUND` blocks.

---

## The composition variant

The reviewer that takes the seams rather than a slice gets the same brief with **"Your slice" replaced by the paragraph below**, and `{{FILES}}` holding the whole change. Everything else — the claims posture, the priorities, the test rule, the reporting bar, the severities, the output format — is unchanged.

**`{{DIFF_RANGE}}` for this reviewer is always `{{BASE}}...{{HEAD}}`,** on a first run and on a tenth. `{{SETTLED}}` is filled exactly as for a content reviewer — it is not re-litigating decisions either — but **`{{PRIOR_REVIEW}}` must be the composition variant below, not the content reviewers' block.** That block tells its reader "your range starts there … report on what is in your range", which is false here and contradicts the whole-change instruction in the same prompt; a reviewer resolving the contradiction toward the narrower reading confines itself to the delta, and since the content reviewers are already scoped there, nothing reports on the older code at all while the verdict claims the whole change was read.

The two blocks below are **not** interchangeable and are filled on different conditions. The slice replacement goes in on **every** run; the `{{PRIOR_REVIEW}}` block, like the content reviewers', is empty on a first run.

### The composition `{{PRIOR_REVIEW}}` block — later runs only, empty on a first run

> **This change has been reviewed before, at `$LASTREVIEWED`.** That is context, not a boundary: **your range is deliberately the whole change**, and a finding anywhere in it is yours to report, however long ago that code was written. Other reviewers on this run are reading only what changed since `$LASTREVIEWED`, so the earlier code has no one else looking at it this time. What you are not doing is checking anyone's conclusions — nothing about what earlier reviewers decided has been passed to you, and the parts that interact here were often written rounds apart.

**Where the run dispatched no content reviewers at all** — `max_reviewers` left no budget for them, or the delta was empty, or any other reason (SKILL.md stage 3) — the middle sentence is false and has to go, because the conditional deferral in the slice replacement turns on it. **The test is the count actually dispatched, not why it is zero.** Use this instead:

> **This change has been reviewed before, at `$LASTREVIEWED`.** That is context, not a boundary: **your range is deliberately the whole change**, and a finding anywhere in it is yours to report, however long ago that code was written. **You are the only reviewer on this run** — no one else is holding any part of this change — so every part of it is yours, including the code written since `$LASTREVIEWED`. What you are not doing is checking anyone's conclusions: nothing about what earlier reviewers decided has been passed to you.

### The slice replacement — every run, first and tenth alike

This is the paragraph that replaces "Your slice". It is not part of `{{PRIOR_REVIEW}}` and is never omitted: drop it and the composition reviewer becomes a second content reviewer over the whole change, with no seam instruction, while the coverage line still reports a composition pass.

> **Your slice is the joins.** Every other reviewer on this change is holding one part of it and cannot see past their own edges. You are holding all of it, so read for the things that are only visible from here: a caller and a callee that each look right but disagree about what may be null, or about units, ordering, or who owns a lock; a contract changed on one side of a boundary and not the other; two functions that are each tested in isolation and never in the arrangement production actually composes them in; state written by one part and read by another under different assumptions about when it exists.
>
> **This is why your range is the whole change while other reviewers may have a narrower one.** Where a change has been revised over several rounds, the parts that interact were often written rounds apart — each correct when it landed, each read by someone who could not see the other. A defect made by two such changes together appears in neither of their diffs and belongs to neither of their reviewers. It is visible from here and nowhere else, so read pairs of things that changed at different times with as much attention as anything new.
>
> Read the parts as deeply as you need to judge how they meet, and leave defects wholly inside one part to the reviewer holding it — **but only where someone is holding it.** Where other reviewers have been given a narrower range than yours, the parts outside it have nobody else reading them this run, and a defect wholly inside one of those is yours to report like any other. Deferring is for work another reviewer is doing, never for work nobody is doing.
>
> A change where every piece is correct alone and wrong together is the kind that survives every other kind of review.
