---
name: pickup-issue
description: |
  Pick up one open GitHub issue and carry it to a draft PR under review, with no
  human choosing it first. An issue is workable by default: the skill skips only
  ones that are closed, assigned, blocked, dated for later, or labelled as not for
  an agent, and it triages at pickup time instead of requiring a ready label: an
  issue too vague to build gets a specific question and a needs-info label, not a
  guess. One agent PR open per repository at a time, unless the owner labelled an
  issue to go now. Use when the user says "pick up an issue", "work the backlog",
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
| go | `agent-go` | The owner wants this one now. Picked first, and bypasses the one-PR limit |
| claimed | `agent-pickup` | An agent has taken this issue, or opened this PR. Applied to both |
| not for an agent | `ready-for-human`, `needs-info`, `wontfix`, `defer` | Skipped |

If the repo has `docs/agents/triage-labels.md`, map the canonical role names through it. Create a missing `agent-go` or `agent-pickup` label with `gh label create` on first use.

## 1. Choose

**Given an issue number:** use it, and skip the limit check. Stop and say why if it is closed, already carries `agent-pickup`, or has an open blocker.

**Otherwise:**

1. **Limit.** If any open PR carries `agent-pickup`, the only candidates are open issues labelled `agent-go`. If there are none, stop: report the open PR and exit.
2. **Candidates.** `gh issue list --state open --limit 200 --json number,title,labels,assignees,author,createdAt,body`. Keep an issue only if all of these hold:
   - no assignee, and no `agent-pickup` label;
   - none of the "not for an agent" labels, and not a tracking or map issue (for example `wayfinder:map`);
   - its author is the repository owner or a collaborator with write access, not a bot. Bots that file issues usually relay outside text (user feedback, crash reports); those issues wait for the owner to reword them or re-file them under their own name;
   - no open blocker: `gh api repos/{owner}/{repo}/issues/<n> --jq .issue_dependencies_summary.blocked_by` is 0, and every issue named on a `Blocked by:` line at the top of the body is closed;
   - no `Not before: YYYY-MM-DD` line in the body naming a date after today.
3. **Order.** `agent-go` first, then oldest `createdAt` first. Take the first one.

Nothing eligible: say so in one line and exit. That is a normal outcome.

## 2. Claim

Before reading any code: `gh issue edit <n> --add-assignee @me --add-label agent-pickup --remove-label agent-go`. Then re-read the issue. If another assignee appeared, another run claimed it first: remove your assignee and label and stop.

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

`scripts/pickup.ps1` (PowerShell 7) registers two Task Scheduler tasks for one checkout, under the current user:

```powershell
pwsh -File scripts/pickup.ps1 -RepoDir C:\path\to\repo -Register -NightlyAt 01:00
pwsh -File scripts/pickup.ps1 -RepoDir C:\path\to\repo -Unregister
```

- **nightly** starts `claude --bg --permission-mode auto /pickup-issue` in the checkout.
- **agent-go** runs every 15 minutes, and starts the same session only when an open issue carries `agent-go`.

A background session refuses a folder whose workspace trust was never accepted, so run `claude` interactively in the checkout once before registering. Stagger `-NightlyAt` across repositories so their runs do not share the machine. On macOS or Linux, a cron entry running the same `claude` command in the checkout does the nightly half.
