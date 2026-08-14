---
name: post-merge-cleanup
description: |
  Return a repo to a clean state after a pull request lands. Moves the session
  back to the main checkout, prunes remote-tracking refs, removes the worktrees
  and local branches whose remote branch is gone, prunes stale worktree
  administrative entries, and fast-forwards the default branch. Refuses to
  delete anything holding uncommitted work, and asks before deleting a branch
  whose remote still exists. Use when the user says a PR was merged, or says
  "clean up branches", "clean up worktrees", "remove stale branches", "back to
  main", or invokes /post-merge-cleanup.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

# Post-merge cleanup

A PR merged. The repo is still carrying the branch it was built on, the
worktree that branch was checked out in, remote-tracking refs for a branch that
no longer exists on the remote, and a default branch several commits behind.
This skill puts all of that back.

**This skill only cleans up.** It does not merge the PR, close issues, tag a
release, bump versions, or trigger CI. If the PR has not actually merged yet,
say so and stop — there is nothing here to do.

## When to use this skill

The user says a PR merged, or asks to clean up branches or worktrees, get back
to main, or drop stale local state. Also invoked directly as
`/post-merge-cleanup`.

The user may name a branch ("clean up the auth branch"). If they do, still run
the whole sweep — a named branch is a hint about what they expect to be gone,
not a restriction. Report it explicitly if it is *not* among the branches
cleaned up, since that usually means something unexpected happened at merge
time.

## Requirements

`git` only. No `gh`, no `jq`, no network access beyond whatever `git fetch`
needs.

## Step 1: Find the main checkout and leave any worktree

Do this **first**. A worktree cannot be removed while a process is sitting
inside it, and the session's working directory is very often the worktree that
is about to be deleted.

```bash
git worktree list --porcelain
```

The first `worktree ` line in that output is the main checkout — the one with
the real `.git` directory. Every later entry is a linked worktree.

Move the session there:

- If your harness provides an `ExitWorktree` tool (Claude Code does), use it.
- Otherwise `cd` to the main checkout path from the command above.

Confirm you landed: `git rev-parse --git-dir` should print `.git`, not a path
under `.git/worktrees/`.

If the repo has no linked worktrees at all, this step is a no-op — carry on.

## Step 2: Determine the default branch

```bash
git symbolic-ref --quiet --short refs/remotes/origin/HEAD
```

That prints e.g. `origin/main`; the default branch is the part after the slash.
If it prints nothing (the ref is commonly unset on clones), fall back in this
order: `main` if `refs/remotes/origin/main` exists, else `master` if
`refs/remotes/origin/master` exists, else ask the user.

Remember this name. **The default branch is never deleted**, whatever the later
steps say about it.

If the repo has no remote at all, skip steps 3 and 7 — there is nothing to
prune against and nothing to pull. Steps 4–6 still run, with `--merged` as the
only evidence available.

## Step 3: Prune remote-tracking refs

```bash
git fetch --prune
```

This is what marks branches `[gone]`. Without it the whole sweep silently finds
nothing to do, because the deleted remote branch is still sitting in
`refs/remotes/`.

## Step 4: Classify every local branch

```bash
git for-each-ref --format="%(refname:short)|%(upstream:track)|%(upstream:short)" refs/heads/
git branch --merged origin/<default-branch> --format="%(refname:short)"
```

Read both outputs and sort the branches into three buckets. Prefer these two
commands over a piped `git branch -v | grep | sed | awk` chain — they are
parseable as-is and behave the same in PowerShell, cmd, and POSIX shells.

**Bucket A — remote branch gone.** `%(upstream:track)` contains `[gone]`: the
branch tracked a remote branch that no longer exists. This is the normal
after-a-merge signal, since GitHub deletes the head branch on merge (and `gh pr
merge --delete-branch` does it explicitly). Delete these.

**Bucket B — merged, remote still present.** The branch appears in `--merged`
output but is not in bucket A. Its commits are already in the default branch,
but its remote branch still exists — someone may still be using it, or the
merge simply hasn't been followed by a branch delete. **Ask before deleting
these**, listing them together in one question rather than one prompt per
branch. Note that `--merged` is an ancestry test, so a branch nobody has
committed to yet is "merged" too — it will show up here, and it is work someone
is about to start, not work that landed. That is most of why this bucket asks.

**Bucket C — everything else.** Leave alone, silently.

Two branches never go in bucket A or B regardless of what the commands say: the
default branch, and the branch currently checked out in the main checkout.

### The squash-merge gap

A squash-merged branch is not in `--merged` output — its commits were replaced
by a single new commit with a different sha, so git sees it as unmerged
forever. Squash merges land in bucket A instead, via the deleted remote branch,
which is why step 3 matters so much.

If a branch looks merged to the user but shows up in neither bucket, say so and
leave it. Do not try to prove equivalence with `git cherry` or patch-id
comparison and do not delete on a hunch — report it and let the user decide.

## Step 5: Check for uncommitted work

For every branch about to be deleted that has a worktree, check that worktree
before touching it:

```bash
git -C <worktree-path> status --porcelain
```

Any output at all — modified files, staged changes, untracked files — means
**skip that branch entirely**. Do not remove its worktree, do not delete the
branch, and do not use `git worktree remove --force` to get past it. Collect
these and report them at the end as skipped, naming the path so the user can go
look.

This is the one place this skill differs sharply from a plain
delete-everything-gone script, and it is deliberate: an untracked file in a
worktree is the one thing in this whole sweep that exists nowhere else.

Also check for unpushed commits on branches in **bucket B** only — bucket A's
remote branch is gone precisely because it merged, so "unpushed" is meaningless
there:

```bash
git log origin/<default-branch>..<branch> --oneline
```

Output means the branch has commits not in the default branch. That contradicts
`--merged` only in odd cases, but if it happens, skip the branch and report it.

## Step 6: Remove worktrees, then delete branches

Order matters — a branch checked out in a worktree cannot be deleted while that
worktree exists.

For each surviving branch, worktree first:

```bash
git worktree remove <worktree-path>
```

No `--force`. Step 5 already established the worktree is clean, so a failure
here means either a lock (see below) or that something changed underneath you —
in the second case report it and skip that branch rather than forcing.

### Locked worktrees

`git worktree list --porcelain` marks some entries `locked`, usually with a
reason. A lock blocks removal, and agent tooling routinely locks the worktree it
is working in — Claude Code's own worktrees are locked for the life of the
session, with a reason naming the session and pid. Treating every lock as "leave
it alone" would make this skill refuse to clean up the exact worktrees it exists
for.

So split on whose lock it is:

- **The worktree the session itself vacated in step 1.** That lock is yours, and
  you have already left. `git worktree unlock <path>`, then remove.
- **Any other lock.** Show the user the path and the lock reason verbatim and
  ask before unlocking. A lock someone else set is a deliberate "not yet," and
  the reason text is what they left to explain it.

Never unlock a worktree that step 5 flagged as holding uncommitted work. The
lock question only arises for worktrees already established as clean.

Then the branch:

```bash
git branch -d <branch>
```

Use `-d`, not `-D`. For bucket B, `-d` succeeds by definition. For bucket A it
can refuse on a squash-merged branch, since git cannot see the merge — that
refusal is expected, and `-D` is correct there: the deleted remote branch is the
evidence `-d` lacks. Use `-D` only after `-d` has refused, and only for a branch
in bucket A.

Then clear out administrative entries for worktrees whose directory is already
gone:

```bash
git worktree prune
```

## Step 7: Update the default branch

The session is in the main checkout from step 1. If it is not already on the
default branch:

```bash
git switch <default-branch>
```

If the main checkout has uncommitted changes, don't switch — report the pending
work and skip to the summary. The cleanup already done still stands.

Then:

```bash
git pull --ff-only
```

`--ff-only` is the point. If it fails, the local default branch has commits the
remote doesn't, which is a real situation the user needs to look at — report the
failure and stop. Never resolve it with a merge, a rebase, or a reset.

## Step 8: Report

State plainly what happened:

- Branches deleted, and which bucket each came from
- Worktrees removed
- Anything skipped, and why — uncommitted work (with the path), a failed
  `worktree remove`, a branch that looked merged but proved nothing
- The default branch's new position: `Already up to date` or the commit range
  pulled
- Where the session is now

If nothing needed cleaning, say that in one line. A repo that was already clean
is a normal outcome, not a failure.

## Edge cases

If a worktree's directory has been deleted by hand but its branch is still
listed, `git worktree prune` in step 6 handles it. Anything else unexpected:
stop and ask the user rather than guessing.
