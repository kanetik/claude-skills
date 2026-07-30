---
name: pr-review-skeptic
description: >-
  Independent skeptical review of a pull request by reviewers who took no part
  in writing it: blind subagents read the changes at HEAD, treat comments and
  docs as claims to verify against the code, and produce a thread per finding
  plus a go/no-go verdict — posted when a person asked for it to be published, or
  when an agent caller has the reviewed repo's committed permission AND the ask
  was not question-shaped; shown in the terminal otherwise. Use when the user asks for a second
  opinion or an independent skeptical review of a PR, or asks whether a PR is
  really ready to merge. Requires an existing PR; accepts a PR number, URL, or
  owner/repo#num, and modifiers like "don't post", "one reviewer", or
  "include medium".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Task
  - Agent
---

# PR Review Skeptic

An honest second opinion on a pull request, from reviewers with no stake in it. Work that has been iterated on — by a person, by a bot loop, by the agent that wrote it — accumulates its own justification: comments explaining why each decision is right, a description arguing the design, threads recording what was already considered. Read alongside the code, that justification is persuasive, and the reviewer starts verifying the story instead of the code. This skill puts **blind** reviewers on the diff first — they see the project and the code, and nothing about why the change exists — and only afterwards lets the PR's own history filter what they found.

This skill is self-contained. The files below live in this skill's own directory, beside this `SKILL.md` — read them from there (paths are relative to this file, not the working directory). Load on demand:

- [`config/defaults.yml`](config/defaults.yml) — config defaults and the default priority ladder.
- [`reference/configuration.md`](reference/configuration.md) — config keys, override model, first-run flow, invocation modifiers.
- [`reference/reviewer-brief.md`](reference/reviewer-brief.md) — the brief handed to each blind reviewer, and its slots.
- [`reference/cross-check.md`](reference/cross-check.md) — the brief for the one stage that reads the PR's history.
- [`reference/mechanics.md`](reference/mechanics.md) — the `gh` calls: resolving the PR, scoping the diff, CI status, review history, posting the review.

**Requires:** `gh` (authenticated), `git`, and a subagent tool (`Task` / `Agent`). The shell snippets in [`reference/mechanics.md`](reference/mechanics.md) are POSIX forms — on Windows that means Git Bash, which supplies `awk` and `cygpath`. `jq` is needed for one step only, building the posting payload, and that step has a PowerShell form using `ConvertTo-Json` instead — so `jq` is required only if you take the Bash route there, and Git Bash does not ship it.

## Reporting style — terse

Progress is a line per stage: "6 units, 6 reviewers out." / "14 findings, cross-checking against 9 threads." Don't replay findings in the terminal that are about to be posted to the PR — say where they landed and let the user read them there.

## Configuration (summary)

Read [`config/defaults.yml`](config/defaults.yml), then merge overrides per key, low → high: bundled defaults < an optional `~/.claude/pr-review-skeptic.config.yml` < the PR repo's `.github/pr-review-skeptic.config.yml`. Only the bundled layer is required; the skill runs with nothing else present. Five keys describe the project (`project`, `users`, `irreplaceable_data`, `production_status`, `architecture`); five shape the review (`priorities`, `files_per_unit`, `max_reviewers`, `blocking_severities`, `confirm_before_posting`). Parse invocation modifiers. Full model: [`reference/configuration.md`](reference/configuration.md).

**One key is not in that merge: `allow_agent_posting`.** It is a permission rather than a setting, and it is honoured **only** from the PR repo's own committed `.github/pr-review-skeptic.config.yml` read at the base ref — never from the bundled layer, never from `~/.claude/pr-review-skeptic.config.yml`, never from an uncommitted working-tree copy. Do not let it into the merged config at all: an effective config that carries a `true` from a user-level file has already answered stage 7's question wrongly, and the answer it gives is "publish under this account", on every repo that machine can reach. Resolve it separately, from the project layer, and see [`reference/configuration.md`](reference/configuration.md) for why the exception is worth its irregularity.

## Context discipline

The blind pass is the whole value of this skill, and it is lost quietly — not by a decision to abandon it, but by one helpful sentence of preamble explaining what the change does.

So the brief is **built by substitution, not written**: fill the slots in [`reference/reviewer-brief.md`](reference/reviewer-brief.md) from config values and from the mechanics of reaching the code — project facts, file list, base and head shas, CI status — and hand the result to the subagent as the complete prompt. Every slot has a source that is a fact about the project or about how to find the diff. Between filling the last slot and dispatching, there is nothing left to add.

The one hard guardrail, because it cannot be phrased as a target: **no summary of the change, its purpose, its history, or its author's reasoning reaches a blind reviewer** — not in the brief, not in a follow-up message, not in an answer to a question it asks. When a reviewer asks what the change is for, the answer is that the code is the specification. History has exactly one entry point into this skill, and it is stage 6.

**The rule gets harder to hold as runs accumulate, and more load-bearing.** By the tenth run over one PR, the history the blind pass must not see includes this skill's own nine previous reviews, every thread the author replied to, and every rationale they wrote for a rejection. That material is the most tempting thing to pass along — it reads like a head start, and handing a reviewer "here's what was already found and answered" would visibly cut the duplicate findings. It would also end the review: a reviewer told what nine predecessors concluded is checking their work, and the one thing this skill is for is a reader who has not been told. The duplicate findings are stage 6's job to remove, *after* they exist. So the brief is filled from the same slots on run ten as on run one, and the fact that a finding was raised before is something the reviewer must not know and the cross-check must.

## 1. Resolve the PR and stage a checkout

Find the target PR from the invocation, or from the current branch ([`reference/mechanics.md`](reference/mechanics.md)). Cross-repo references are fine in any phrasing; resolve to `(owner, repo, number)` and pass `--repo` on every later call.

No PR found and none named → say so and stop. This skill reviews a pull request; without one there is nothing to review and nowhere to post. Note the PR's `state` while you are here — a merged or closed PR can still be reviewed, but its verdict is a report rather than something to post (stage 7).

Reviewers read the code at the PR's head, and several of them read it at once, so every run happens in a **staged worktree** at that commit rather than in your own checkout ([`reference/mechanics.md`](reference/mechanics.md)):

1. Resolve the PR's own repository. For a cross-repo PR that isn't cloned locally, `gh repo clone` it into the temp directory first — same-named files in the repo you happen to be standing in are not the code under review.
2. Fetch the head from that repository and add a temporary `git worktree` at it.
3. The worktree comes down at stage 9.

Your working copy is then untouched by the review, dirty or not, and the reviewers get a tree whose contents are exactly the PR's.

**Done when** the review worktree exists, sits on the PR's head sha, and belongs to the PR's own repository.

## 2. Load configuration

Merge the config layers, reading the project's own layer from the PR's **base** ref rather than the staged worktree ([`reference/configuration.md`](reference/configuration.md)) — the five project keys are what the reviewers take on faith, so a change that edits them must not get to steer the review of itself.

When the five are empty, draft answers from the PR repo's `README.md` / `CLAUDE.md` — read at the same ref the config layer is (`$BASETIP`, or `$BASE` on a PR that is not `OPEN`), for the same reason — and confirm them with the user. A PR that edits the README would otherwise get to describe the project to the reviewers judging it, and a user confirming a plausible-looking line makes it a fact. Then offer to write `.github/pr-review-skeptic.config.yml`, but only where the PR's repo has a lasting checkout to write it into: the file is written there and left uncommitted, and the skill stages, branches, and commits nothing. Where the file already exists — a repo can legitimately set only `max_reviewers` and leave the project keys empty, which is what brought you here — **append** the missing keys with an edit rather than rewriting the file, and name in the offer which keys will be added. A rewrite silently drops the comments and key ordering the repo's author put there, in a file left uncommitted in their tree, so the loss rides into their next commit. Where the only checkout is the temporary one from stage 1, hand the user the confirmed values as YAML to paste instead — a file written into a directory that gets deleted at teardown buys them nothing but a second interview next run.

**Done when** all five project keys hold a confirmed value. A reviewer that does not know which data is irreplaceable cannot rank anything it finds.

Where the run was started by another skill or agent there is nobody to confirm with, so an empty project layer stops the run: tear down (stage 9), say the config is required, and hand back what is missing. Reviewers steered by five invented project facts would produce a review whose independence is exactly the thing being claimed for it.

## 3. Scope and partition

Collect the merge-base, the head sha, CI status, and the changed file list ([`reference/mechanics.md`](reference/mechanics.md)). Take the file list from `git diff --name-status` in the staged worktree, not from `gh pr view --json files`, which returns at most 100 files and says nothing when it truncates — a partition built from a truncated list reviews part of the change and reports full coverage.

**An empty file list is never just "nothing to review."** An empty partition satisfies every condition below vacuously, produces no findings, and ends in a posted "no blocking findings", so separate the two ways it happens before going on. Three arms, and the difference matters to whoever reads the message:

- `$BASE` equals the head sha → the PR's commits are already contained in the base branch with no merge commit recording where they joined, so there is no base to diff against. Say that; offer to review against a base ref the user names.
- Both shas resolve and `git -C "$REPO" rev-list --count "$BASE..$REVIEWED"` is non-zero → the PR genuinely has no net change (an empty commit, or a change and its own revert). Say that.
- Anything else → the diff ran against the wrong revisions. Say that. Either way, tear down first (stage 9) — staging has already happened, and a stop is not a reason to leave a worktree and a ref in the user's repository. The difference matters to the user, who otherwise goes hunting a revision bug that isn't there.

Partition the changed files into **units** a single reviewer can hold at once. Cut on module and subsystem boundaries first — a unit should be something describable in a phrase ("the sync layer", "the settings screen and its view model") — using `files_per_unit` as the target size and `max_reviewers` as the cap on total reviewers. A change too large for the cap gets larger units, never fewer files: attention thinning across an oversized unit and a file nobody read produce the same silent "looks fine".

Where the partition yields more than one unit, spend one of those reviewers on a **composition unit**: it takes the whole file list and the seams between the other units, and asks how the pieces behave together. Functions that are each correct alone and wrong in the arrangement production actually uses are invisible to every reviewer holding only one of them. A single-unit partition has no seams, so it gets no composition reviewer.

**Done when** every changed file belongs to exactly one content unit, the composition unit (where there is one) spans all of them, the total reviewer count is within `max_reviewers`, and the partition is recorded for the report.

## 4. Blind pass

For each unit, fill the slots in [`reference/reviewer-brief.md`](reference/reviewer-brief.md) and dispatch a subagent with the filled brief as its entire prompt — see **Context discipline** above. The composition unit gets the same brief with its slice paragraph swapped for the composition variant at the end of that file. Dispatch all units concurrently; they are independent.

Each reviewer returns `FINDING` and `SOUND` blocks. A reviewer that returns neither has not reviewed its unit — dispatch it again rather than recording silence as a clean unit, up to twice. Still nothing after that, the unit is **unreviewed**: carry it forward, name it in the coverage line at stage 7 and in the report at stage 8, and keep going. An unreviewed unit is a hole in the review that the user has to know about; retrying it forever posts nothing at all.

**Done when** every unit has either returned at least one block or is recorded as unreviewed.

## 5. Merge

Collect the blocks. Two findings are the same when they name the same defect in the same place, whatever the wording; keep the clearest statement of it, at the highest severity either gave, and note that more than one reviewer found it. Independent agreement is signal — carry it into the report.

Keep the `SOUND` blocks. They feed the terminal report at stage 8 — what the reviewers actually verified, which is the difference between a clean result and a quiet one. They do not go in the posted body; a PR review is for what needs attention.

## 6. Cross-check against history

Where the PR has prior review activity, dispatch one subagent with the merged findings and the PR's review history, per [`reference/cross-check.md`](reference/cross-check.md). It buckets each finding as `new`, `unfixed` (raised before, changed, still present — severity rises), `re-raised` (raised before, dismissed, found independently), or `settled` (the same consequence was weighed and accepted).

Where the PR has no prior review activity, every finding is `new`. Skip the stage. Where "ignore the review history" was asked for, dispatch the marker-only variant at the end of that file instead — a duplicate thread posted beside this skill's own earlier one is not something the user opted into.

**This stage is what makes repeat runs cumulative rather than repetitive**, and it carries the whole weight of that on a PR being driven through an iterative loop, where this skill may run ten times. Without it, round ten's blind reviewers — who by design cannot see rounds one through nine — hand back round one's findings verbatim, and the loop never terminates. So the history payload must be complete: threads with their replies and resolution state, review bodies, the PR description, the commit list **with the paths each commit touched**, and **the PR's issue comments** ([`reference/mechanics.md`](reference/mechanics.md)). The last of those is easy to omit and matters for one specific case: findings this skill could not give a thread to (stage 7, tier 3) are dispositioned in a PR-level comment instead, and that comment is the only record that they were dealt with. Drop it and exactly those findings re-raise every round.

The evidence a disposition leaves is a reply — on a thread, or in that PR-level comment — and where the author is an agent it carries a machine-readable marker saying which disposition it was. Treat that marker as decisive when it says a finding was rejected on the merits: the point of an author recording a rejection publicly is that the next round does not re-litigate it. What keeps that from quietly burying real defects is not skepticism here but stage 7's rule that a **blocking** finding bucketed `settled` is still named in the verdict, with its count and its thread. Settled means decided, not silent.

This is the largest single prompt the skill builds — every finding plus the whole history payload — so it is the one most likely to come back truncated or unusable. Re-dispatch once. Still unusable, fall back to the marker-only variant, which needs the threads and the marker string and nothing else. If even that fails, treat every finding as `new` and **say the cross-check did not run**, in the terminal report and in the posted summary body: without the marker pass a second run opens a fresh thread beside each of its own earlier comments, and the user should hear that from the report rather than from the notifications.

**Done when** every finding carries a bucket — or the cross-check is recorded as not run — and every `unfixed`, `re-raised`, and `settled` one carries **the thread or the disposition record** that decided it. Both count: a finding that never had a thread is settled by an entry in the PR-level dispositions comment instead, and a Done-when demanding a thread cannot be satisfied for exactly those findings — which would send them back as `new` every round, undoing the mechanism the record exists for.

## 7. Verdict and post

**Blocking findings** are those at `blocking_severities` after the cross-check's severity changes. Any → the verdict names how many and what the worst one is.

None → the change is good to go, and the verdict says so **plainly only when the run earned it**. Two things qualify it, both because the verdict is the line collaborators act on and a note further down the body does not undo it:

- Units carried forward unreviewed from stage 4 → "no blocking findings in the N of M units reviewed, U unreviewed".
- Findings at a blocking severity that stage 6 bucketed `settled` → say how many. A CRITICAL that a prior thread weighed and accepted is still a CRITICAL somebody decided to live with, and burying it in a list under an unqualified good-to-go is how the decision stops being visible.

### Does this run post at all?

Settle this before drafting anything, because posting notifies every collaborator on the PR and cannot be unsent.

**Nothing posts unless something was reviewed.** Where no unit returned a `FINDING` or `SOUND` block — the subagent tool unavailable, rate-limited, or erroring, which hits every unit at once because it is a whole-session condition — the run has no review in it. Say so in the terminal and offer a re-run. Posting here would put a review on the user's PR, under their account, notifying everyone, containing nothing; "0 of 4 units reviewed" in the coverage line does not redeem that.

**Nothing posts on a PR that is not `OPEN`**, and **nothing posts when the invocation said "don't post" / "just tell me"**. Those two hold whatever else is configured or asked for.

Past those, who asked decides:

**A person asked.** The run posts when it was told to — the user invoked `/pr-review-skeptic`, or asked for the review on the PR ("post a review", "review it on the PR", "leave comments on #42"). Everything else is answered in the terminal, the drafted review shown, with an offer to post it. That includes the phrasings this skill most often arrives on — "second opinion on #42", "is this ready to merge?", "take a look at this PR" — which read as a question about the change rather than an instruction to publish under the user's name. **Where both readings fit, preview wins:** `/pr-review-skeptic #42 — is this ready to merge?` carries a question, so it previews, bare slash command notwithstanding. The cost of being wrong runs one way only — an unwanted preview costs a turn, an unwanted review cannot be taken back. `confirm_before_posting: true` turns even an explicit posting instruction into a preview.

**Another skill or agent asked.** The run posts **only** where the PR's repo has committed `allow_agent_posting: true` to its own `.github/pr-review-skeptic.config.yml`, read at the base ref ([`reference/configuration.md`](reference/configuration.md)). Absent that — which is the default — the caller gets the drafted review returned and nothing reaches the PR.

**On the agent path, a caller's reply is never a go-ahead** — whether the grant is present or absent, and whether the reply is the first or the tenth. Asking again does not make it one, and neither does agreeing with itself. This governs the whole path, not just the ungranted case, and it is what makes the preview below actually hold: an agent-invoked run that previews returns its draft with **no standing offer to post**, so stage 8's offer is a human-path affordance only. Without that, the two-axis rule below is undone one turn later — the run previews a question-shaped ask, the orchestrator says "post it", and the review publishes under the user's account on a PR where no person ever asked for one.

That key is what an agent-driven review loop runs on, so be exact about what it is and isn't. It is a **standing grant made by the repository**: committed where collaborators can see and revoke it, read from the base ref so a PR cannot grant it to itself, and confined to the project layer so it cannot ride one machine's user-level config into every repo that machine can reach. It is not an instruction a caller can supply, and a caller asserting it in a prompt is exactly the thing it replaces. `confirm_before_posting: true` has nobody to confirm with here, so it reverts an agent-invoked run to no-post rather than hanging on a preview no person will see.

Telling agent-invoked from user-invoked needs a test you can actually apply, because an orchestrator relaying a user's words ("post a review on #42") reads exactly like the user typing them. So: **the run is agent-invoked unless the request reached you directly from the user in this conversation.**

Two ambiguities can stack here, and they resolve differently. **Who is asking** — where you cannot tell, take the agent path, since it falls back to the repo's own committed answer, the one source in this question no prompt can forge. **What is being asked** — where the ask is question-shaped ("is #42 ready to merge?", "second opinion on this"), preview, *and this survives the agent path*: the repo's grant answers "may agents post here", not "did anyone want a post this time". A question answered with a published go/no-go review under the user's account, notifying every collaborator, is the outcome that cannot be taken back, and a standing grant is not consent to it. So an ask that is ambiguous on both axes previews. An unwanted preview costs a turn; that asymmetry does not change just because the caller is a machine.

Say which path the run took, in the terminal, either way. An agent-invoked run that could not post because the key is absent looks identical from the caller's side to one that found nothing worth posting, and a caller that cannot tell the difference will keep re-running the review expecting threads that never appear.

### Is this still the right commit?

Re-read the PR's head sha before building anything and compare it against **`$REVIEWED`** — the sha the blind reviewers actually read ([`reference/mechanics.md`](reference/mechanics.md)), which is fixed for the life of the review and survives a re-staging. Comparing against "whatever stage 1 last resolved" answers "unchanged" forever on the preview-then-post path, which is the one path this check exists for.

Moved → the review describes a superseded commit; say so in the summary body ("reviewed at `<sha>`; head has since moved") or offer to re-run. GitHub marks outdated inline comments; it does not mark a stale verdict, and the verdict is the line that gets acted on.

**The review still posts at `$REVIEWED`**, not at the sha you just read. Every anchor was validated against that commit's diff, so posting at a newer one hands GitHub line numbers from a diff it isn't looking at, and one shifted line 422s the whole call. Unless the move was a **force-push**, which orphans the reviewed sha from the branch and makes it an invalid `commit_id`. Establish which it was by the test in [`reference/mechanics.md`](reference/mechanics.md), which fetches the new head first and reads the exit code strictly; an unanswered test is not a force-push.

**On the force-push path, every finding at every tier goes into the body**, and no file-level comment is attempted. Both comment tiers pass `commit_id: $REVIEWED`, which is the sha the force-push just orphaned, so both would be rejected — and since the body is otherwise built to hold only the findings that reached tier 3, following the tier rules unchanged would publish a verdict naming findings that appear nowhere on the PR: not inline (dropped), not file-level (rejected), not in the body (not tier 3). The verdict is the line collaborators act on, and it cannot be unsent. So build the body with all of them, post against the current head, and say the review describes a commit that has since been rewritten.

Re-read the PR's **state** here too. A PR merged or closed during the run — or one whose number was mistyped in the first place — still stages and reviews cleanly, because a merged PR's head ref still resolves. Posting a go/no-go verdict on it says nothing useful and cannot be unsent, so a non-`OPEN` PR previews: report in the terminal and say the PR is already merged or closed.

### Every finding gets its own thread

**Severity decides the verdict, not the placement.** `blocking_severities` says which findings make the verdict no-go; it says nothing about where a finding goes. Every finding this review reports — `CRITICAL` through `LOW` — is posted as its own thread, and the body carries only the ones that could not be given one.

This is not a presentation preference. A finding that lives only in the summary body has nothing to reply to and nothing to resolve, so **nothing on the PR ever records that it was dealt with**. The next run's cross-check (stage 6) reads threads and their replies to decide what is `settled`; a finding that never had a thread produces no such evidence, so it comes back `new` every round, at the same severity, forever. Where this skill drives an iterative loop, that one gap is the difference between rounds that accumulate and rounds that repeat.

So each finding lands in the highest of these three that works ([`reference/mechanics.md`](reference/mechanics.md)):

1. **Inline, in the review payload** — where its `line` falls inside a new-side hunk for its `path` at `$REVIEWED`. The normal case.
2. **File-level, as a standalone comment** — where it does not anchor to a line but its path is in the diff and present at `$REVIEWED`: a finding on line 40 of a file the change only touches at line 200. Posted after the review call, one call each, so a `422` there costs that one comment rather than the whole review.
3. **The summary body, under a heading naming its path** — a `D` path, or a file the change never touched at all. These are the ones with no thread, so the body lists them under an explicit heading saying so, rather than mixing them in with the rest: whoever dispositions this review needs to know which findings they cannot resolve on the PR.

**Assign all three tiers before the review call goes out.** Every input needed is already in hand — the diff decides tiers 1 and 2, and what is left is tier 3 — and the review call is what publishes the body, which nothing afterwards can amend. A tier-2 call that then fails at run time is *reported* (terminal, and stage 8), not quietly re-filed into a body that has already posted.

Tier 3 is a hole in the settle-and-move-on mechanism, not a tidy fallback. Keep it small — it is the tier findings fall into, never one they are put into.

### The review

Whether it is posted or shown, the review is one `event: COMMENT` review, plus any tier-2 comments after it ([`reference/mechanics.md`](reference/mechanics.md)):

- **Comments** — one per finding, carrying its severity, the defect, its consequence, and the fix. `unfixed` findings say how many rounds have already touched that code; `re-raised` ones link the thread — or cite the dispositions comment — where the concern was dismissed. Every comment ends with the marker line `<!-- pr-review-skeptic -->`, which is how a later run recognises its own work: these reviews post under the user's account and are otherwise indistinguishable from a hand-written one.
- **A summary body** — the verdict; the coverage (files reviewed, units, how many reviewers, whether the cap forced larger units, and any unit left unreviewed); the tier-3 findings under their own heading, at full severity, marked as having no thread; the `settled` list with the thread or dispositions-comment record that decided each; and, when a run was narrowed by a modifier, what it did not cover. It ends with the same marker line the comments carry — invisible in the rendered body, and the only way a later run can tell whether a review it could not confirm actually landed. A clean verdict has no comments at all, so without it there would be nothing on the PR to recognise.

The verdict belongs in the body, where a person reads it and decides. Report coverage even when the verdict is clean — a thorough clean review and a shallow one read identically without it.

**Reply, or open a new thread?** A finding that stage 6 matched to a prior marker-carrying thread goes back as a reply on that thread **when the thread is still open** — otherwise a second run posts every finding beside its own original and notifies everyone twice for one defect. Where the matched thread is **resolved**, open a new thread and link the old one. A resolved thread is a decision someone recorded, a reply on it is invisible to everyone who acted on that decision, and a finding that comes back after a thread was resolved is precisely the case that needs to be seen: either the fix did not land (`unfixed`, arriving a severity higher) or it was rejected and independently re-found (`re-raised`). A finding matched to a resolved thread whose decision genuinely covers it is not here at all — stage 6 bucketed it `settled` and moved it out.

## 8. Report

One short block to the user: the verdict, counts by severity, the PR URL, what the reviewers confirmed sound, and anything the run could not cover.

Where the review was posted, say the findings are on the PR, and say how many landed as threads versus in the body with none. Where it was previewed, they are in the draft already shown and the offer to post stands. Where an agent invoked the run and the repo has not granted `allow_agent_posting`, say that too, and name the file that would grant it — a caller that expects threads and gets none has no other way to learn why.

**The offer is a human-path affordance.** It stands only where a person previewed — an agent-invoked run's returned draft carries no offer, and a caller asking for it is not a go-ahead (stage 7).

Taking it up **re-runs stage 1's staging and nothing else** — carrying `$REVIEWED` across unchanged, since the point of the checks is to notice the head has moved away from what was reviewed. Order matters: **re-read `state` and the current head *before* re-staging**, per "Is this still the right commit?".

One wrinkle on the cross-repo path: `$REPO` was the temp clone, and teardown deleted it, so the force-push test — which is `git -C "$REPO" …` — would run in a repository that no longer exists and exit 128 on every call. A missing `$REPO` is not the same as an unresolvable sha, and treating it as one posts at an orphaned `$REVIEWED` and 422s twice. So **re-clone first where the PR is cross-repo** (a bare clone with no worktree is enough for the fetch and `--is-ancestor`), then run the checks, then stage or skip staging as they direct. Then re-stage at `$REVIEWED`, write the payload files again from the draft already shown, re-validate the anchors against the diff at `$REVIEWED`, and post — through all three placement tiers, so the previewed threads land as threads.

Checking first is what makes the force-push case survivable. Teardown deleted `refs/prskeptic/<num>`, so re-staging re-fetches `pull/<num>/head` — which after a force-push is a *different* commit, leaving `$REVIEWED` unresolvable: `cat-file -e` and `worktree add` both fail, and the skill's own force-push answer sits behind a step that cannot complete. So on a force-push, **skip staging entirely** and go straight to the body-only post against the current head. There are no anchors to re-validate, because none survive a force-push.

One detail the re-clone makes load-bearing: a fresh clone contains no ref to `$REVIEWED`, so `merge-base --is-ancestor "$REVIEWED" …` exits **128** (unresolvable) rather than `1` (not an ancestor) — and the strict reading in [`reference/mechanics.md`](reference/mechanics.md) sends 128 to "post at the reviewed sha, or ask", which is the one branch this path cannot use. So fetch the reviewed sha into its own ref first — `git -C "$REPO" fetch "$REMOTE" "+$REVIEWED:refs/prskeptic/<num>-reviewed"` — and read *that* result: it succeeds on a fast-forward (run the ancestor test as normal) and **fails when the sha has been force-pushed out of the remote, which is itself the force-push answer**. A 128 from a sha the remote no longer has is evidence, not an unanswered test. A preview can sit for an hour while the PR is merged or force-pushed out from under it, which is what those checks are for. Do not re-run stages 2–6 — dispatching fresh reviewers would publish a draft the user never saw — and do not re-apply the post/preview decision, which they have already made. Telling someone to go read findings on a PR that has none is how a previewed run gets mistaken for a clean one.

## 9. Tear down

Remove the staged worktree, delete `refs/prskeptic/<num>`, and drop the temp clone where the run made one ([`reference/mechanics.md`](reference/mechanics.md)). **Every exit after stage 1 comes through here** — a posted review, a shown preview, and the deliberate stops at stages 2 and 3 alike. None of it is anything to keep: left behind, the ref pins the PR's objects alive and the worktree shows up in the user's `git worktree list` and `git status` forever, at paths they were never told.

Run it **after the last posting call of the run has returned** — the review, every file-level comment, and every thread reply — or, on a previewed run, as soon as the preview is shown. Not after the review call: that call is only the first of several, and the ones after it read their bodies from `<tmp>/f-<n>.md` and `<tmp>/reply.md`, which this step deletes. Tear down early and every file-level comment fails on a missing file, on findings whose whole purpose was to be settleable, with the summary body already published without them. Do not hold it open for an answer that may never come: the phrasings that preview are the ones this skill most often arrives on, a user with their answer usually closes the session rather than replying, and what is left behind is a ref pinning the PR's objects and a worktree registration in the user's own repository, at paths they were never told and in a `refs/prskeptic/*` namespace nothing surfaces. Accepting the offer later re-stages through stage 1, which costs one fetch.

This holds on the cross-repo path too. Accepting the offer re-enters at stage 1, which clears and re-clones anyway, so a retained clone is never the one used — and a few hundred megabytes of upstream repo left at a temp path the user was never told is a poor trade for state that gets discarded. Carry the resolved literals forward instead; the checkout is cheap to rebuild.

**Done when** `git -C "$REPO" worktree list` shows no worktree at `<tmp>/pr-<num>`, the `refs/prskeptic/<num>` refs are gone, and the `<tmp>` directory itself no longer exists — the payload files holding the review text live directly in it. Cross-repo, the clone going with it settles all three.
