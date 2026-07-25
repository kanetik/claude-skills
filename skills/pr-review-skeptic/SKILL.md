---
name: pr-review-skeptic
description: >-
  Independent skeptical review of a pull request by reviewers that took no part
  in writing it: blind subagents read the changes at HEAD, treat comments and
  docs as claims to verify against the code, and produce inline findings plus a
  go/no-go verdict — posted to the PR when asked to post, shown in the terminal
  otherwise. Use when the user asks for a second
  opinion or an independent skeptical review of a PR, or asks whether a PR is
  really ready to merge. Requires an existing PR; accepts a PR number, URL, or
  owner/repo#num, and modifiers like "don't post", "one reviewer", or
  "include medium".
allowed-tools:
  - Bash
  - Read
  - Write
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

**Requires:** `gh` (authenticated), `git`, and a subagent tool (`Task` / `Agent`). The shell snippets in [`reference/mechanics.md`](reference/mechanics.md) are POSIX forms — on Windows that means Git Bash, which supplies `awk` and `cygpath` but **not `jq`**, so install that separately there. `jq` is needed only to build the posting payload, and the PowerShell form of that step uses `ConvertTo-Json` instead, so it is the route to take without it.

## Reporting style — terse

Progress is a line per stage: "6 units, 6 reviewers out." / "14 findings, cross-checking against 9 threads." Don't replay findings in the terminal that are about to be posted to the PR — say where they landed and let the user read them there.

## Configuration (summary)

Read [`config/defaults.yml`](config/defaults.yml), then merge overrides per key, low → high: bundled defaults < `~/.claude/pr-review-skeptic.config.yml` < the PR repo's `.github/pr-review-skeptic.config.yml`. Five keys describe the project (`project`, `users`, `irreplaceable_data`, `production_status`, `architecture`); the rest shape the review (`priorities`, `files_per_unit`, `max_reviewers`, `blocking_severities`, `confirm_before_posting`). Parse invocation modifiers. Full model: [`reference/configuration.md`](reference/configuration.md).

## Context discipline

The blind pass is the whole value of this skill, and it is lost quietly — not by a decision to abandon it, but by one helpful sentence of preamble explaining what the change does.

So the brief is **built by substitution, not written**: fill the slots in [`reference/reviewer-brief.md`](reference/reviewer-brief.md) from config values and from the mechanics of reaching the code — project facts, file list, base and head shas, CI status — and hand the result to the subagent as the complete prompt. Every slot has a source that is a fact about the project or about how to find the diff. Between filling the last slot and dispatching, there is nothing left to add.

The one hard guardrail, because it cannot be phrased as a target: **no summary of the change, its purpose, its history, or its author's reasoning reaches a blind reviewer** — not in the brief, not in a follow-up message, not in an answer to a question it asks. When a reviewer asks what the change is for, the answer is that the code is the specification. History has exactly one entry point into this skill, and it is stage 6.

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

When the five are empty, draft answers from the PR repo's `README.md` / `CLAUDE.md` and confirm them with the user. Then offer to write `.github/pr-review-skeptic.config.yml`, but only where the PR's repo has a lasting checkout to write it into: the file is written there and left uncommitted, and the skill stages, branches, and commits nothing. Where the file already exists — a repo can legitimately set only `max_reviewers` and leave the project keys empty, which is what brought you here — add the missing keys and leave every existing one as it stands, naming in the offer which keys will be added. Where the only checkout is the temporary one from stage 1, hand the user the confirmed values as YAML to paste instead — a file written into a directory that gets deleted at teardown buys them nothing but a second interview next run.

**Done when** all five project keys hold a confirmed value. A reviewer that does not know which data is irreplaceable cannot rank anything it finds.

Where the run was started by another skill or agent there is nobody to confirm with, so an empty project layer stops the run: tear down (stage 9), say the config is required, and hand back what is missing. Reviewers steered by five invented project facts would produce a review whose independence is exactly the thing being claimed for it.

## 3. Scope and partition

Collect the merge-base, the head sha, CI status, and the changed file list ([`reference/mechanics.md`](reference/mechanics.md)). Take the file list from `git diff --name-status` in the staged worktree, not from `gh pr view --json files`, which returns at most 100 files and says nothing when it truncates — a partition built from a truncated list reviews part of the change and reports full coverage.

**An empty file list is never just "nothing to review."** An empty partition satisfies every condition below vacuously, produces no findings, and ends in a posted "no blocking findings", so separate the two ways it happens before going on. Both shas resolve and `git -C "$REPO" rev-list --count "$BASE..<headRefOid>"` is non-zero → the PR genuinely has no net change (an empty commit, or a change and its own revert); say that and stop. Anything else → the diff ran against the wrong revisions; say that and stop. Either way, tear down first (stage 9) — staging has already happened, and a stop is not a reason to leave a worktree and a ref in the user's repository. The difference matters to the user, who otherwise goes hunting a revision bug that isn't there.

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

This is the largest single prompt the skill builds — every finding plus the whole history payload — so it is the one most likely to come back truncated or unusable. Re-dispatch once. Still unusable, fall back to the marker-only variant, which needs the threads and the marker string and nothing else. If even that fails, treat every finding as `new` and **say the cross-check did not run**, in the terminal report and in the posted summary body: without the marker pass a second run opens a fresh thread beside each of its own earlier comments, and the user should hear that from the report rather than from the notifications.

**Done when** every finding carries a bucket — or the cross-check is recorded as not run — and every `unfixed`, `re-raised`, and `settled` one carries the thread that decided it.

## 7. Verdict and post

**Blocking findings** are those at `blocking_severities` after the cross-check's severity changes. Any → the verdict names how many and what the worst one is.

None → the change is good to go, and the verdict says so **plainly only when the run earned it**. Two things qualify it, both because the verdict is the line collaborators act on and a note further down the body does not undo it:

- Units carried forward unreviewed from stage 4 → "no blocking findings in the N of M units reviewed, U unreviewed".
- Findings at a blocking severity that stage 6 bucketed `settled` → say how many. A CRITICAL that a prior thread weighed and accepted is still a CRITICAL somebody decided to live with, and burying it in a list under an unqualified good-to-go is how the decision stops being visible.

### Does this run post at all?

Settle this before drafting anything, because posting notifies every collaborator on the PR and cannot be unsent.

**Nothing posts unless something was reviewed.** Where no unit returned a `FINDING` or `SOUND` block — the subagent tool unavailable, rate-limited, or erroring, which hits every unit at once because it is a whole-session condition — the run has no review in it. Say so in the terminal and offer a re-run. Posting here would put a review on the user's PR, under their account, notifying everyone, containing nothing; "0 of 4 units reviewed" in the coverage line does not redeem that.

Otherwise: **a run posts when it was told to post** — the user invoked `/pr-review-skeptic`, or asked for the review on the PR ("post a review", "review it on the PR", "leave comments on #42").

Everything else is answered in the terminal, the drafted review shown, with an offer to post it. That includes the phrasings this skill most often arrives on — "second opinion on #42", "is this ready to merge?", "take a look at this PR" — which read as a question about the change rather than an instruction to publish under the user's name.

**Where both readings fit, preview wins.** `/pr-review-skeptic #42 — is this ready to merge?` carries a question, so it previews, bare slash command notwithstanding. The cost of being wrong runs one way only: an unwanted preview costs a turn, an unwanted review cannot be taken back.

Two cases post nothing at all, whatever the phrasing: **"don't post" / "just tell me"** in the invocation, and **another skill or agent invoking this one** — that caller gets the drafted review returned, and its reply is not a go-ahead, because the decision to publish belongs to the person whose account signs it. `confirm_before_posting: true` turns even an explicit posting instruction into a preview.

The second of those needs a test you can actually apply, because an orchestrator relaying a user's words ("post a review on #42") reads exactly like the user typing them. So: **the run is agent-invoked unless the request reached you directly from the user in this conversation.** Where you cannot tell whose words you are reading, preview — an unattributable posting instruction is the one case where the safe reading and the cautious reading agree.

### The review

Re-read the PR's head sha before building anything. Where it has moved since stage 1, the review describes a superseded commit — say so in the summary body ("reviewed at `<sha>`; head has since moved") or offer to re-run. GitHub marks outdated inline comments; it does not mark a stale verdict, and the verdict is the line that gets acted on.

**The review still posts at the sha that was reviewed** — stage 1's `<headRefOid>`, not the sha you just read. Every anchor was validated against that commit's diff, so posting at a newer one hands GitHub line numbers from a diff it isn't looking at, and one shifted line 422s the whole call. Unless the move was a **force-push**, which orphans the reviewed sha from the branch and makes it an invalid `commit_id` — that case posts to the body against the current head instead. Establish which it was by the test in [`reference/mechanics.md`](reference/mechanics.md), which fetches the new head first and reads the exit code strictly; an unanswered test is not a force-push.

Re-read the PR's **state** here too. A PR merged or closed during the run — or one whose number was mistyped in the first place — still stages and reviews cleanly, because a merged PR's head ref still resolves. Posting a go/no-go verdict on it says nothing useful and cannot be unsent, so a non-`OPEN` PR previews: report in the terminal and say the PR is already merged or closed.

Whether it is posted or shown, the review is one `event: COMMENT` review carrying ([`reference/mechanics.md`](reference/mechanics.md)):

- **Inline comments** — one per blocking finding, anchored at its line: severity, the defect, its consequence, the fix. `unfixed` findings say how many rounds have already touched that code; `re-raised` ones link the thread where the concern was dismissed. Every comment ends with the marker line `<!-- pr-review-skeptic -->`, which is how a later run recognises its own work: these reviews post under the user's account and are otherwise indistinguishable from a hand-written one. A finding whose prior thread carries that marker and is still open is a reply on that thread, not a new one — a second run otherwise posts every unfixed finding beside its own original and notifies everyone twice for one defect.
- **A summary body** — the verdict; the coverage (files reviewed, units, how many reviewers, whether the cap forced larger units, and any unit left unreviewed); non-blocking observations, one line each; the `settled` list with the threads that decided them; and, when a run was narrowed by a modifier, what it did not cover. It ends with the same marker line `<!-- pr-review-skeptic -->` the inline comments carry — invisible in the rendered body, and the only way a later run can tell whether a review it could not confirm actually landed. A clean verdict has no inline comments at all, so without it there would be nothing on the PR to recognise.

The verdict belongs in the body, where a person reads it and decides. Report coverage even when the verdict is clean — a thorough clean review and a shallow one read identically without it.

## 8. Report

One short block to the user: the verdict, counts by severity, the PR URL, what the reviewers confirmed sound, and anything the run could not cover.

Where the review was posted, say the findings are on the PR; where it was previewed, they are in the draft already shown and the offer to post stands — and taking that offer up **re-enters the run at stage 1**, re-staging and re-reading state and head sha before anything is sent, because a preview can sit for an hour while the PR is merged or force-pushed out from under it. Telling someone to go read findings on a PR that has none is how a previewed run gets mistaken for a clean one.

## 9. Tear down

Remove the staged worktree, delete `refs/prskeptic/<num>`, and drop the temp clone where the run made one ([`reference/mechanics.md`](reference/mechanics.md)). **Every exit after stage 1 comes through here** — a posted review, a shown preview, and the deliberate stops at stages 2 and 3 alike. None of it is anything to keep: left behind, the ref pins the PR's objects alive and the worktree shows up in the user's `git worktree list` and `git status` forever, at paths they were never told.

Run it as soon as the review is **posted** — or, on a previewed run, as soon as the preview is shown. Do not hold it open for an answer that may never come: the phrasings that preview are the ones this skill most often arrives on, a user with their answer usually closes the session rather than replying, and what is left behind is a ref pinning the PR's objects and a worktree registration in the user's own repository, at paths they were never told and in a `refs/prskeptic/*` namespace nothing surfaces. Accepting the offer later re-stages through stage 1, which costs one fetch.

The exception is the **cross-repo** path, where `$REPO` is the temp clone and the accept path needs it for the state and force-push checks. Hold that one open until the offer resolves or the user moves on.

**Done when** `git -C "$REPO" worktree list` shows no worktree at `<tmp>/pr-<num>` and `refs/prskeptic/<num>` is gone — or, cross-repo, once the clone itself is gone, which settles both.
