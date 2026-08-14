---
name: post-merge-cleanup
description: |
  Return a repo to a clean state after a pull request lands. Moves the session
  back to the main checkout, prunes remote-tracking refs, fast-forwards the
  default branch, then removes the worktrees and local branches the merge made
  stale and prunes leftover worktree administrative entries. Refuses to delete
  anything holding uncommitted work, and asks rather than guessing wherever git
  cannot prove the work survived. Use when the user says a PR was merged, or
  says "clean up branches", "clean up worktrees", "remove stale branches", "back
  to main", or invokes /post-merge-cleanup.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
  - ExitWorktree
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

- If your harness provides an `ExitWorktree` tool (Claude Code does), try it
  first, asking it to **keep** the worktree rather than remove it. Removal is
  step 7's job, after the uncommitted-work check has cleared the worktree —
  leaving here is only about not standing in it.
- Otherwise, or **if that tool did nothing**, `cd` to the main checkout path
  from the command above.

That second clause is not a formality. Such a tool typically only knows about
worktrees the *current session* created, and does nothing at all for one it did
not — which is the ordinary case here, since the session that made the worktree
is usually the session whose PR just merged, not this one. A no-op reports no
error, so the only way to know is to check where you ended up:

```bash
git rev-parse --git-dir
```

This must print `.git`. A path under `.git/worktrees/` means you are still
inside the worktree, whatever the tool returned — `cd` to the main checkout and
check again. **Do not carry on from inside a worktree step 7 is going to try to
remove**; that removal will fail, and the branch will be left behind with no
explanation that fits.

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

Remember one more thing: **`<default-ref>`**, the ref every later containment
test is asked against. Where the repo has a remote, that is
`origin/<default-branch>`; where it has none, the local `<default-branch>`.

The distinction matters because step 3 has just made `origin/<default-branch>`
current, and it did so without needing the working tree to cooperate. Every
question of the form "are this branch's commits already in the default branch?"
is therefore answerable in full even when step 4 cannot switch — so classifying
against `<default-ref>` rather than against whatever is checked out keeps the
sweep's evidence sound on paths where the checkout is not.

If the repo has no remote at all, skip step 3 and the pull in step 4 — there is
nothing to prune against and nothing to pull. Everything else still runs, and
`<default-ref>` being the local branch is what keeps those steps executable.

## Step 3: Prune remote-tracking refs

```bash
git fetch --prune
```

This is what marks branches `[gone]`. Without it the whole sweep silently finds
nothing to do, because the deleted remote branch is still sitting in
`refs/remotes/`.

## Step 4: Get on the default branch and fast-forward it

**Before classifying anything**, because the branch checked out here is excluded
from deletion (step 5). In the common flow with no linked worktrees at all —
branch made in the main checkout, PR merged, remote branch deleted — that is the
*one* branch the sweep exists to remove. Switch first and the exclusion protects
only the default branch, which is what it is for.

Check the tree before touching it:

```bash
git status --porcelain
```

**Any output means do not switch.** Uncommitted changes follow you across a
`git switch`, so switching would carry the user's work-in-progress onto the
default branch. Say so, skip to step 5, and note that the exclusion in step 5
is now protecting whatever branch is checked out instead.

Otherwise:

```bash
git switch <default-branch>
git pull --ff-only
```

`git switch` can fail even on a clean tree — most often because the default
branch is already checked out in a linked worktree, which git refuses to check
out twice. **Treat any failure the same way as a dirty tree**: report it, skip
the pull, and carry on from step 5. Do not work around it with `--force` or a
detached checkout.

`--ff-only` on the pull is the point. If it fails, the local default branch has
commits the remote doesn't, which is a real situation the user needs to look at
— report the failure and stop. Never resolve it with a merge, a rebase, or a
reset.

**What the rest of the sweep does and does not depend on.** Classification and
the containment check ask `<default-ref>`, which step 3 already made current, so
they are equally sound whether or not this step succeeded — that is why they are
written against that ref rather than against `HEAD`. What a failure here costs
is narrower and worth stating exactly: the checked-out branch stays excluded
from the sweep, and the user is left where they were rather than on an updated
default branch. Both go in the report.

## Step 5: Classify every local branch

```bash
git for-each-ref --format="%(refname:short)|%(upstream:track)|%(upstream:short)" refs/heads/
git branch --merged <default-ref> --format="%(refname:short)"
```

`<default-ref>` is the ref step 2 defined, not the checked-out branch and not
`HEAD`. Step 3 made it current without needing the working tree, so this
classification is as good on the paths where step 4 failed as on the one where
it succeeded.

Read both outputs and sort the branches into three buckets. Prefer these two
commands over a piped `git branch -v | grep | sed | awk` chain — they are
parseable as-is and behave the same in PowerShell, cmd, and POSIX shells.

**Bucket A — remote branch gone.** `%(upstream:track)` contains `[gone]`: the
branch tracked a remote branch that no longer exists. This is the normal
after-a-merge signal, since GitHub deletes the head branch on merge (and `gh pr
merge --delete-branch` does it explicitly).

**`[gone]` is not proof of a merge, and this bucket must not be read as if it
were.** A remote branch also disappears when a PR is closed *without* merging
and the branch is deleted, and when anyone deletes a remote branch by hand. So
bucket A is "the remote branch is gone" and nothing more. Whether the work
survived is a separate question, decided by step 6's containment check against
`<default-ref>` — and where that check cannot decide, by asking.

**Bucket B — merged, remote still present.** The branch appears in `--merged`
output but is not in bucket A. Its commits are already in the default branch,
but its remote branch still exists — someone may still be using it, or the
merge simply hasn't been followed by a branch delete. **Ask before deleting
these**, listing them together in one question rather than one prompt per
branch. Note that `--merged` is an ancestry test, so a branch nobody has
committed to yet is "merged" too — it will show up here, and it is work someone
is about to start, not work that landed. That is most of why this bucket asks.

**Bucket C — everything else.** Leave alone, silently.

**Two branches never go in bucket A or B**, and both exclusions are needed:

- **The default branch.** `git branch --merged <default-ref>` always lists it —
  a branch is trivially an ancestor of itself — so without this it lands in
  bucket B and the skill offers `main` up for deletion. Step 2 already says it
  is never deleted; this is where that is enforced.
- **The branch checked out in the main checkout.** Where step 4 succeeded these
  are the same branch and the second exclusion does nothing. Where step 4 could
  not switch, it is whatever branch was already there — reported rather than
  swept, with the reason.

### The squash-merge gap

A squash-merged branch is not in `--merged` output — its commits were replaced
by a single new commit with a different sha, so git sees it as unmerged
forever. Squash merges land in bucket A instead, via the deleted remote branch,
which is why step 3 matters so much.

If a branch looks merged to the user but shows up in neither bucket, say so and
leave it. Do not try to prove equivalence with `git cherry` or patch-id
comparison and do not delete on a hunch — report it and let the user decide.

## Step 6: Check for uncommitted work

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

### The containment check

Then, for **every** branch about to be deleted, in either bucket, list the
commits it holds that the default branch does not:

```bash
git log <default-ref>..<branch> --oneline
```

**This is the skill's containment oracle, and it is the only one.** Empty means
every commit on the branch is already in the default branch and deleting it
loses nothing. Non-empty means it isn't, and what that implies differs by
bucket:

- **Bucket B** — it contradicts `--merged`, which happens only in odd cases.
  Skip the branch and report it.
- **Bucket A** — it is either a squash-merge (the commits are the pre-squash
  originals, and the same work is in the default branch under one new sha) or
  work that never merged at all. **Git cannot tell these apart, and neither can
  this skill.** Carry the list to step 7, which asks.

Two things this check replaces, both of which look like they would do the job
and don't:

- **`git branch -d`'s own judgement.** `-d` accepts a branch contained in *its
  own upstream*, and falls back to `HEAD` where the upstream is gone. Neither is
  the question this skill is asking, so a `-d` acceptance is not evidence of
  containment in the default branch and must not be read as any. That is why
  step 7 does not lean on it.
- **Checking only bucket B**, on the reasoning that a gone remote branch has
  merged by definition — the false premise step 5 corrects, and the one that
  ends with unmerged commits deleted.

## Step 7: Decide everything, then act

**Settle every question before removing anything.** Removing a worktree is
irreversible from this skill's side, so it must not happen while an outcome is
still open. The obvious order — remove the worktree, then find out the branch is
ambiguous, then ask — deletes the working directory of a branch the user then
tells you to keep.

So this step runs in two passes.

### Pass 1 — decide, touching nothing

Sort every candidate into `delete` or `keep`, using what step 6 established:

- **Containment check empty** → `delete`. The branch's commits are all in the
  default branch.
- **Bucket B, containment check non-empty** → `keep`, and report the
  contradiction.
- **Bucket A, containment check non-empty** → **ask, and do not guess.** Show
  the branch, the commits step 6 listed, and say plainly that git cannot
  distinguish a squash-merge from work that never landed. The user's answer sets
  `delete` or `keep`. Ask about all such branches together, in one question.

Ask nothing else. In particular, the run of ordinary merged branches needs no
confirmation — a question per branch trains the user to say yes without reading,
which costs exactly the case this asking exists for.

### Pass 2 — act on the `delete` set only

Worktree first, since a branch checked out in a worktree cannot be deleted while
that worktree exists:

```bash
git worktree remove <worktree-path>
```

No `--force`. Step 6 already established the worktree is clean, so a failure
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

Never unlock a worktree that step 6 flagged as holding uncommitted work. The
lock question only arises for worktrees already established as clean.

Then the branch:

```bash
git branch -D <branch>
```

**`-D`, deliberately, and only for a branch pass 1 put in the `delete` set.**
This looks like the dangerous flag and here it is the honest one. `git branch
-d` asks a *different question* than this skill has been asking: it accepts a
branch contained in its own upstream, and falls back to `HEAD` where the
upstream is gone. Neither is containment in the default branch. So `-d` would
refuse every squash-merged branch the user has just confirmed, and would accept
some branch whose work is in a stale upstream and nowhere else — a safety net
that catches the wrong things in both directions.

The check that decides this is step 6's, run explicitly, against a ref step 2
pinned for the purpose. `-D` here executes a decision already made rather than
skipping one.

**Record the sha of every branch deleted and put it in the report.** `git branch
-D` prints it. It is the only thing standing between a wrong answer — the
skill's or the user's — and reflog archaeology.

Then clear out administrative entries for worktrees whose directory is already
gone:

```bash
git worktree prune
```

## Step 8: Report

State plainly what happened:

- The default branch's new position: `Already up to date` or the commit range
  pulled — and where the switch or the pull did not happen, say so and why,
  since that is the difference between the user being left on an updated default
  branch and being left where they started
- Branches deleted, with the sha of each and which bucket it came from
- Worktrees removed
- Anything kept, and why — uncommitted work (with the path), a failed `worktree
  remove`, an ambiguous branch the user chose to keep, a bucket B branch that
  contradicted `--merged`, a branch excluded because it was checked out
- Where the session is now

If nothing needed cleaning, say that in one line. A repo that was already clean
is a normal outcome, not a failure.

## Edge cases

If a worktree's directory has been deleted by hand but its branch is still
listed, `git worktree prune` in step 7 handles it. Anything else unexpected:
stop and ask the user rather than guessing.
