---
name: post-merge-cleanup
description: |
  Return a repo to a clean state after a pull request lands. Moves the session
  back to the main checkout, prunes remote-tracking refs, fast-forwards the
  default branch, then removes the worktrees and local branches the merge made
  stale, clearing stale worktree entries in its path. Refuses to delete
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

`git`, version 2.31 or newer — step 1 uses `git rev-parse --path-format`, added
in 2.31. Nothing else: no `gh`, no `jq`, no network access beyond whatever `git
fetch` needs.

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
git rev-parse --path-format=absolute --git-dir --git-common-dir
```

**The two must be equal.** In the main checkout they are; in a linked worktree
the first is a path under `.git/worktrees/` while the second is the shared
`.git`.

`--path-format=absolute` is required, not decorative. Without it the two are
printed in whatever form git finds shortest, and from a subdirectory of the main
checkout that is `<abs>/.git` and `../.git` — two spellings of the same
directory that compare unequal, so a plain string test reports a worktree that
is not there. The flag makes both absolute and the comparison honest from any
depth.

They differ, and you are still inside the worktree whatever the tool returned:
`cd` to the main checkout and check again. **Do not carry on from inside a
worktree step 7 is going to try to remove** — that removal will fail, and the
branch will be left behind with no explanation that fits.

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

The distinction matters because step 3 makes `origin/<default-branch>` current,
and does so without needing the working tree to cooperate. Every question of the
form "are this branch's commits already in the default branch?" is therefore
answerable in full even when step 4 cannot switch — so classifying against
`<default-ref>` rather than against whatever is checked out keeps the sweep's
evidence sound on paths where the checkout is not.

If the repo has no remote at all, skip step 3 and the pull in step 4 — there is
nothing to prune against and nothing to pull. Everything else still runs, and
`<default-ref>` being the local branch is what keeps those steps executable: an
`origin/`-qualified ref would fail outright with a bad-revision error, not
merely find nothing. Bucket A is empty on that path — with no remote there are
no upstreams to have gone — so `--merged` is the only evidence there is.

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
git status --porcelain --untracked-files=no
```

**Any output means do not switch**, because uncommitted changes to tracked files
follow you across a `git switch` and would carry the user's work-in-progress
onto the default branch. Say so, skip to step 5, and note that the exclusion in
step 5 is now protecting whatever branch is checked out instead.

`--untracked-files=no` is doing real work here and is not a tidiness flag.
Untracked files do not follow a `git switch` anywhere — they simply stay where
they are, and git refuses on its own in the one case where the switch would
clobber one. Left in, the default `--porcelain` reports every `??` line, so a
single scratch file in the main checkout stops the switch, which leaves step 5's
exclusion protecting the very branch this skill exists to remove. That is an
extremely ordinary tree state to be defeated by.

Otherwise:

```bash
git switch <default-branch>
git pull --ff-only
```

**Neither command stops the run when it fails.** Report what happened, carry on
from step 5, and put it in the final report:

- **`git switch` fails** — commonly because the default branch is already
  checked out in a linked worktree, which git refuses to check out twice, and
  also because an untracked file in the way would be overwritten (`The following
  untracked working tree files would be overwritten by checkout`). That second
  one is reachable *because* the gate above deliberately stops blocking on
  untracked files, which is the intended trade: git's own refusal is more precise
  than the gate's would have been. **Report what git actually said** rather than
  naming a cause you have not confirmed. Skip the pull and continue. Never work
  around it with `--force` or a detached checkout.
- **`git pull --ff-only` fails** — most often because the local default branch
  has commits the remote doesn't, though a network or authentication failure and
  a branch with no configured upstream fail here too. **Report what git actually
  said** rather than asserting a divergence you have not confirmed. Either way it
  is not a reason to abandon the cleanup: `<default-ref>` is the remote-tracking
  ref, which step 3 already made current, so the sweep's evidence does not depend
  on the local branch having moved. Where it is a real divergence, never resolve
  it with a merge, a rebase, or a reset — report it and leave it for the user.

**What the rest of the sweep does and does not depend on.** Classification and
the containment check ask `<default-ref>`, which step 3 already made current, so
they are equally sound whether or not this step succeeded — that is why they are
written against that ref rather than against `HEAD`. What a failure here costs
is exactly this much: the checked-out branch stays excluded from the sweep, and
the user is left where they were rather than on an updated default branch. Both
go in the report.

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
but its remote branch still exists — someone may still be using it, or the merge
simply hasn't been followed by a branch delete. **These are asked about**, in
step 7's single batched question. Note that `--merged` is an ancestry test, so a
branch nobody has committed to yet is "merged" too — it will show up here, and
it is work someone is about to start, not work that landed. That is most of why
this bucket asks.

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

First, clear out worktree entries whose directory no longer exists:

```bash
git worktree prune
```

This runs **here**, before anything reads a worktree, rather than at the end of
the sweep. A worktree whose directory was deleted by hand is still listed until
it is pruned, and the check below would then run `git -C` against a path that
does not exist — which fails, and reads exactly like the "something changed
underneath you" case that skips the branch. The branch would survive on the
strength of a worktree that is already gone.

**`git worktree prune` does not finish that job, and must not be relied on to.**
Locking a worktree exists precisely to stop its administrative files being
pruned, so a *locked* entry whose directory is gone survives the prune — and
since agent tooling locks the worktrees it creates (step 7), that is the common
flavour here rather than an exotic one.

So handle the missing directory explicitly, and keep it distinct from a failed
check. **All of this is scoped to branches the sweep is proposing to delete** —
the same set the status check below covers. A stale entry belonging to some
other branch is not this run's business, and mutating administrative state for
worktrees nobody asked about is exactly the overreach the rest of this skill
avoids.

For each such branch:

- **Path does not exist** → unlock the entry and prune it:

  ```bash
  git worktree unlock <worktree-path>
  git worktree prune
  ```

  Do not run the status check, and do not treat any of this as a failure.
- **Path exists** → run the check below.

**Test existence by looking at the path itself** — your own file tools, or
`test -d` / `Test-Path` where you are driving a shell. `git worktree list
--porcelain` gives you the paths to test and nothing more: it reports a
`prunable` field for an *unlocked* stale entry, but a **locked** one whose
directory is gone prints exactly what a live locked worktree prints —

```
worktree C:/…/wt
HEAD d68d5d0…
branch refs/heads/feat
locked claude session 123 pid 456
```

— with no marker distinguishing the two. Since the prune above has already
cleared every unlocked stale entry, a locked one is the *only* kind that ever
reaches this test, so a test reading git's own output can never fire here.
Probing the path is the whole of what works.

**Unlocking and pruning is the whole remedy — "just carry on as though the
branch had no worktree" is not an alternative, and this is the one place a
plausible-looking shortcut silently fails.** The entry stays registered, and
`git branch -D` in step 7 then refuses outright:

```
error: cannot delete branch 'feat' used by worktree at '<path>'
```

so the branch survives — the exact outcome this case exists to prevent, merely
reported under a different wrong reason. Note also that only *locked* entries
ever reach this bullet, since the prune above already cleared the unlocked ones.
There is no instance of this case where the shortcut works.

**And unlocking here is deliberately exempt from step 7's ask-before-unlocking
rule.** That rule protects a *working directory* someone else may still be
using. Here there is no directory: it is gone, its contents are gone with it,
and the lock now guards nothing. Nothing can be lost by clearing it, so asking
would only be a question with one sensible answer.

Collapsing this case into the status check is what puts a branch in the report
as "skipped, something changed underneath" when the truth is that its worktree
was deleted by hand weeks ago.

Then, for every branch about to be deleted whose worktree directory is still
there, check it before touching it:

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

Two things that look like they would do this job and don't, so neither is used
in its place:

- **`git branch -d`'s own judgement.** `-d` accepts a branch contained in *its
  own upstream*, and falls back to `HEAD` where the upstream is gone. Neither is
  the question this skill is asking, so a `-d` acceptance is not evidence of
  containment in the default branch and must not be read as any. That is why
  step 7 does not lean on it.
- **Checking bucket B only**, on the reasoning that a gone remote branch has
  merged by definition. That is the false premise step 5 corrects, and following
  it ends with unmerged commits deleted.

## Step 7: Decide everything, then act

**Settle every question before removing anything.** Removing a worktree is
irreversible from this skill's side, so it must not happen while an outcome is
still open. The obvious order — remove the worktree, then find out the branch is
ambiguous, then ask — deletes the working directory of a branch the user then
tells you to keep.

So this step runs in two passes.

### Pass 1 — decide, touching nothing

Sort every candidate into `delete` or `keep`, using what step 6 established:

- **Bucket A, containment check empty** → `delete`, no question. The remote
  branch is gone and every commit is already in the default branch, so there is
  nothing left to decide.
- **Bucket A, containment check non-empty** → **ask, and do not guess.** Show
  the branch, the commits step 6 listed, and say plainly that git cannot
  distinguish a squash-merge from work that never landed. The user's answer sets
  `delete` or `keep`.
- **Bucket B, containment check empty** → **ask.** This is step 5's rule and it
  still holds: the remote branch is still there, so someone may still be working
  on this, and a branch nobody has committed to yet is "merged" too. Nothing is
  at risk — the work is contained and the remote copy remains — but it is not
  this skill's call to make.
- **Bucket B, containment check non-empty** → `keep`, and report the
  contradiction with `--merged`.

**Everything that needs asking goes into one question**: the ambiguous bucket A
branches, the bucket B branches, and any **locked worktree belonging to a branch
in this candidate set** whose lock you cannot attribute to this session (below).
A run with three of each costs one question, not nine.

Ask about nothing outside that set. In particular, do not ask per branch — that
trains the user to say yes without reading, which costs exactly the case the
asking exists for — and do not ask about locked worktrees on branches nobody
proposed to touch.

### Pass 2 — act on the `delete` set only

Worktree first, since a branch checked out in a worktree cannot be deleted while
that worktree exists:

```bash
git worktree remove <worktree-path>
```

No `--force`. Three failures are expected here and only the last is a problem:

- **`fatal: '<path>' is not a working tree`** — step 6 pruned this entry because
  its directory was already gone. Nothing to remove; carry straight on to
  deleting the branch. This is a success, not a failure, and skipping the branch
  over it would undo exactly what step 6 just unblocked.
- **`fatal: cannot remove a locked working tree`** — the lock is still on,
  because it was not attributable to this session and the user declined to
  unlock it. Keep the branch and report it; a declined unlock is a decision, and
  the branch is not deletable while its worktree stands.
- **Anything else** — something changed underneath you. Report it and skip that
  branch rather than forcing.

Step 6 already established the worktree is clean, so `--force` buys nothing here
that is not already covered.

### Locked worktrees

`git worktree list --porcelain` marks some entries `locked`, usually with a
reason. A lock blocks removal, and agent tooling routinely locks the worktree it
is working in — Claude Code's own worktrees are locked for the life of the
session, with a reason naming the session and pid. Treating every lock as "leave
it alone" would make this skill refuse to clean up the exact worktrees it exists
for.

So split on whether the lock is demonstrably **yours**:

- **Your harness told you it is.** If the worktree-exit tool in step 1 reported
  that it left *this* worktree — which such tools only do for worktrees the
  current session created — then the lock is this session's and you have already
  left it. `git worktree unlock <path>`, then remove.
- **Everything else**, including a reason naming some other session, and
  including a reason you cannot attribute at all. Show the user the path and the
  lock reason verbatim, and ask before unlocking. A lock someone else set is a
  deliberate "not yet," and the reason text is what they left to explain it.

**Ask in the batch, not one at a time.** These go into the same pass-1 question
as the ambiguous branches, so a run with three locked worktrees costs one
question rather than three.

Two things this rule deliberately does not do. It does not treat "I was standing
in it" as proof of ownership: the worktree this run vacated in step 1 is usually
*not* this session's, since the session that created it is normally the one
whose PR just merged, so that test would silently unlock and remove another —
possibly still-running — session's working directory. And it does not ask you to
parse a session id or pid out of the reason text and match it against your own.
That is not reliably knowable from inside the skill, and a rule written on it
would in practice send every lock down the ask path, which is the outcome the
first bullet exists to avoid. The harness's own answer is the one signal here
that is trustworthy; absent it, ask.

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

No second `git worktree prune` is needed here. Between them, step 6's prune
(unlocked stale entries) and its per-entry unlock-and-prune (locked ones, for
the branches in scope) already cleared what this run is responsible for, and
`git worktree remove` clears the entry for each worktree it removes.

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
listed, step 6 handles it before anything tries to read that directory — by
pruning, and where the entry is locked and so survives the prune, by unlocking it
first. Anything else unexpected: stop and ask the user rather than guessing.
