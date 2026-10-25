---
name: pickup-issue
description: |
  Pick up one open GitHub issue and carry it to a draft PR under review, with no
  human choosing it first. An issue is workable by default: the skill skips only
  ones that are closed, assigned, blocked, dated for later, or labelled as not for
  an agent, and it triages at pickup time instead of requiring a ready label: an
  issue too vague to build gets a specific question and a needs-info label, not a
  guess. One pickup in flight per repository at a time, unless the owner named the
  issue or labelled it to go now. Use when the user says "pick up an issue", "work the backlog",
  "take the next issue", "work issue #N", or invokes /pickup-issue (optionally with
  an issue number); scheduled runs launch it headless.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Skill
  - Agent
---

# Pick up an issue

Requires `gh` (authenticated) and `jq`. One run takes at most one issue.

## Labels

| Role | Default label | Meaning |
|---|---|---|
| go | `agent-go` | The owner wants this one now. Picked first, bypasses the one-pickup limit, and overrides `needs-info` |
| claimed | `agent-pickup` | On an issue: an agent claimed it (see Claims). On a PR: an agent opened it |
| not for an agent | `ready-for-human`, `needs-info`, `wontfix`, `defer` | Skipped |

If the repo has `docs/agents/triage-labels.md`, map the canonical role names through it, and treat any other label it says pickup skips as "not for an agent" too. Create a missing `agent-go` or `agent-pickup` label with `gh label create` on first use.

## Claims

An issue's **agent PR** is a PR, open or closed, labelled `agent-pickup` whose body starts `Closes #<n>`: `gh pr list --state all --label agent-pickup --search "Closes #<n> in:body"`. Search the body rather than GitHub's linked-issue field, which stays empty for a PR into a non-default branch.

An issue is **in flight** while it carries `agent-pickup` and either its agent PR is open or its most recent claim comment (step 2) is under 24 hours old.

Every run starts by releasing each open `agent-pickup` issue that is not in flight, with a comment saying why:
- **its agent PR was closed without merging:** remove `agent-pickup` and the assignee, and add `needs-info`. The owner says what should change, and `agent-go` retries it;
- **no agent PR at all, and the most recent claim is over 24 hours old** (the run that claimed it died): remove `agent-pickup` and the assignee, leaving it workable.

An issue whose agent PR merged keeps its label: the merge closes it, or it is waiting on a branch that has not landed yet.

## 1. Choose

**Given an issue number:** use it, and skip the limit check. Stop and say why if it is closed, still carries `agent-pickup` after the release above (name the PR that closes it, if any), or has an open blocker.

**Otherwise:**

1. **Limit.** While any issue is in flight, the only candidates are open issues labelled `agent-go`. If there are none, stop, report what holds the limit, and exit.
2. **Candidates.** `gh issue list --state open --limit 200 --json number,title,labels,assignees,author,createdAt,body`, plus the same query with `--label agent-go` so no `agent-go` issue falls outside the 200. Keep an issue only if all of these hold:
   - no assignee, and no `agent-pickup` label;
   - none of the "not for an agent" labels (`needs-info` alongside `agent-go` does not count: the owner has answered and wants it now), and not a tracking or map issue (for example `wayfinder:map`);
   - its author is the repository owner or a collaborator with write access, not a bot. Bots that file issues usually relay outside text (user feedback, crash reports); those issues wait for the owner to reword them or re-file them under their own name;
   - no open blocker: `gh api repos/{owner}/{repo}/issues/<n> --jq .issue_dependencies_summary.blocked_by` is 0, and every issue named on a `Blocked by:` line at the top of the body is closed;
   - no `Not before: YYYY-MM-DD` line in the body naming a date after today.
3. **Order.** `agent-go` first, then oldest `createdAt` first. Take the first one.
4. **Release ineligible `agent-go` issues.** For every open `agent-go` issue this pass excluded, remove `agent-go` and comment which condition kept it out. Left in place, the label keeps starting runs that cannot take it.

Nothing eligible: say so in one line and exit. That is a normal outcome.

## 2. Claim

Before reading any code: `gh issue edit <n> --add-assignee @me --add-label agent-pickup`, removing `agent-go` and `needs-info` where present, then comment `Claimed by an automated pickup run.` on the issue. Claiming first is what lets a later run's step 1 skip the issue.

## 3. Triage

Read the issue, its comments, and the code it names. Ask one question: could a competent engineer new to this repo build it without asking the owner anything?

- **Yes:** go on to step 4. Fill small gaps with the choice the surrounding code already makes, and say in the PR body which choices you made.
- **No:** comment on the issue with the specific questions that block you (not "please clarify"). Then add `needs-info`, remove `agent-pickup` and your assignee, and stop. A question that only the code can answer is not a reason to stop: read the code.

An issue that turns out to be done already, or obsolete: comment with the evidence (the commit, the file), and close it as completed or not planned. Do not open a PR.

## 4. Build

Follow the repository's own instructions (`CLAUDE.md`, `AGENTS.md`) for branching, worktrees, validation and PR conventions. They override anything here. In particular, run whatever "validate before a PR" step the repo defines, and say in the PR body if any part of it could not run.

The PR:
- opened as a draft unless the repo says otherwise;
- body starts with `Closes #<n>`;
- labelled `agent-pickup`.

Then start the repo's PR review flow. Where `/pr-review-loop` is available, invoke it on the new PR and run it to convergence.

If the build fails in a way you cannot resolve, push what you have to the branch, comment on the issue with what blocked you and a link to the branch, add `ready-for-human`, and remove `agent-pickup` and your assignee.

## 5. Report

One short paragraph: the issue, the PR link (or why there is none), and anything the owner has to do.

## Unattended runs (Windows)

`scripts/pickup.ps1` (PowerShell 7) registers one Task Scheduler task for a checkout, under the current user:

```powershell
pwsh -File scripts/pickup.ps1 -RepoDir C:\path\to\repo -Register -NightlyAt 01:00
pwsh -File scripts/pickup.ps1 -RepoDir C:\path\to\repo -Unregister
```

Every 15 minutes it starts `claude --bg --permission-mode auto /pickup-issue` in the checkout when the day's run after `-NightlyAt` has not happened yet, or when an open issue carries `agent-go`; never within 30 minutes of its last launch.

A background session refuses a folder whose workspace trust was never accepted, so run `claude` interactively in the checkout once before registering. Stagger `-NightlyAt` across repositories so their runs do not share the machine. On macOS or Linux, a cron entry running the same `claude` command in the checkout does the nightly half.
