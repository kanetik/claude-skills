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

`git`, version 2.31 or newer. Two things need it, and 2.31 is where both landed:
step 1's `git rev-parse --path-format`, and the `locked` annotation in `git
worktree list --porcelain` that steps 6 and 7 read. (The same release added
`prunable`, which this skill deliberately does not rely on — step 6 says why.)
Nothing else: no `gh`, no `jq`, no network access beyond whatever `git fetch`
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

That second clause is not a formality: such a tool typically only knows about
worktrees the *current session* created and does nothing for one it did not —
the ordinary case here, since the worktree is usually the merged PR's session's
rather than this one's. A no-op reports no error, so check where you landed:

```bash
git rev-parse --path-format=absolute --git-dir --git-common-dir
```

**The two must be equal, and the second must belong to the main checkout path
you read above** — meaning either `<that path>/.git` in the ordinary layout, or
`<that path>` itself where the first `worktree ` entry carried a `bare` line.
Accept both. In a bare-repo-plus-worktrees layout — a standard pattern among
exactly the worktree-heavy users this skill is for — `git worktree list
--porcelain` reports the bare directory as the first entry and both rev-parse
values *are* that directory, so a test demanding `/.git` rejects a perfectly good
main checkout and the run stops at step 1 having done nothing. (Step 4's switch
and pull will then fail there, which it already reports without stopping.)

Two things that look optional here and are not. Compare against the main
checkout path, not just the two values against each other — equality proves "not
in a linked worktree" and nothing about *which* repository, and an exit tool can
land the session in a nested repo's root, which passes an equality-only test and
runs the sweep against the wrong repo. And `--path-format=absolute` is required,
because without it git prints whichever form is shortest: from a subdirectory of
the main checkout that is `<abs>/.git` and `../.git`, two spellings of one
directory that compare unequal.

Failing either, you are not where you need to be: `cd` to the main checkout and
check again. **Do not carry on from inside a worktree step 7 will try to
remove** — that removal fails, and the branch is left behind with no explanation
that fits.

If the repo has no linked worktrees at all, this step is a no-op — carry on.

## Step 2: Determine the remote and the default branch

**The remote first**, because everything below is qualified by its name and
`origin` is a convention rather than a guarantee — a fork clone routinely has
`upstream` alongside it, and a remote can simply be named something else.

```bash
git remote
```

- **Nothing printed** → the repo has no remote. Skip step 3 and the pull in step
  4; there is nothing to prune against and nothing to pull.
- **Exactly one** → that is `<remote>`.
- **More than one** → take the one the checked-out branch tracks, via
  `git config --get branch.<current-branch>.remote`. Where that is unset or the
  checkout is detached, fall back to `origin` if it is among them, and otherwise
  ask the user which to use.

Then the default branch:

```bash
git symbolic-ref --quiet --short refs/remotes/<remote>/HEAD
```

That prints e.g. `<remote>/main`; the default branch is the part after the
slash. If it prints nothing — the ref is commonly unset on clones — fall back in
this order: `main` if `refs/remotes/<remote>/main` exists, else `master` if
`refs/remotes/<remote>/master` exists, else ask the user.

**With no remote there is no `<remote>` to substitute**, so skip that chain
rather than attempting it: look for a local `main`, else a local `master`, else
ask. Falling through the remote-qualified commands reaches the same "ask the
user" by accident, which is safe but tells the user nothing about why.

Remember this name. **The default branch is never deleted**, whatever the later
steps say about it.

Remember one more thing: **`<default-ref>`**, the ref every later containment
test is asked against — `<remote>/<default-branch>` where the repo has a remote,
the local `<default-branch>` where it has none. Step 3 makes the remote-tracking
form current without needing the working tree to cooperate, which is why
classification and containment ask this ref rather than `HEAD`: they stay sound
on the paths where step 4 cannot switch. On the no-remote path the local form is
what keeps them executable at all, since a remote-qualified ref would be a
bad-revision error rather than an empty result. Bucket A is empty there too —
no remote means no upstreams to have gone — so `--merged` is the only evidence.

**Then confirm the ref resolves:**

```bash
git rev-parse --verify <default-ref>
```

This catches what resolving the remote does not: a stale
`refs/remotes/<remote>/HEAD` pointing at a default branch since renamed away.
`symbolic-ref` answers happily there, so the fallback chain never fires and the
failure would otherwise surface two steps later as a bad-revision error in the
middle of classification. Fail here instead, naming the ref you tried.

## Step 3: Prune remote-tracking refs

```bash
git fetch --prune <remote>
```

This is what marks branches `[gone]`. Without it the whole sweep silently finds
nothing to do, because the deleted remote branch is still sitting in
`refs/remotes/`.

Name the remote rather than relying on a bare `git fetch --prune`, which picks
the default remote and so can prune a different one than every later step is
asking about. A branch tracking some *other* remote then simply never reaches
bucket A — it is not pruned, so it is not `[gone]` — which under-reports rather
than misfires, and under-reporting is the safe direction here.

## Step 4: Get on the default branch and fast-forward it

**Before classifying anything**, because the branch checked out here is excluded
from deletion (step 5). In the common flow with no linked worktrees at all —
branch made in the main checkout, PR merged, remote branch deleted — that is the
*one* branch the sweep exists to remove. Switch first and the exclusion protects
only the default branch, which is what it is for.

**Already on the default branch?** Then there is no switch and no gate. Pull:

```bash
git pull --ff-only
```

Do not gate this on a clean tree. `git pull --ff-only` fast-forwards a dirty tree
when the incoming commits do not touch the modified files, and refuses on its own
— `error: Your local changes to the following files would be overwritten by
merge` — when they do. Gating it costs the user the fast-forward over a stray
modified file that had nothing to do with the incoming commits.

**Otherwise** the switch needs a gate, so check the tree first:

```bash
git status --porcelain --untracked-files=no
```

**Any output means do not switch**, and do not pull either — `git pull` acts on
the *current* branch, so pulling here would fast-forward the wrong one. Say so
and skip to step 5, noting that step 5's exclusion is now protecting whatever
branch is checked out rather than the default branch.

`--untracked-files=no` is load-bearing, not a tidiness flag. Untracked files do
not follow a `git switch` anywhere, and git refuses on its own in the one case
where the switch would clobber one. Left in, plain `--porcelain` reports every
`??` line, so a single scratch file stops the switch and leaves step 5's
exclusion protecting the very branch this skill exists to remove — an extremely
ordinary tree state to be defeated by.

Clean, so:

```bash
git switch <default-branch>
git pull --ff-only
```

**Neither command stops the run when it fails.** Report what happened, carry on
from step 5, and put it in the final report — and **report what git actually
said** rather than naming a cause you have not confirmed, since each of these
has more than one.

- **`git switch` fails** — commonly because the default branch is already checked
  out in a linked worktree, which git refuses to check out twice; also because an
  untracked file in the way would be overwritten. That second one is reachable
  *because* the gate above stops blocking on untracked files, and that is the
  intended trade: git's own refusal is more precise than the gate's would have
  been, firing only when a file would actually be clobbered rather than whenever
  one exists. Skip the pull and continue. Never work around it with `--force` or
  a detached checkout.
- **`git pull --ff-only` fails** — most often a local default branch holding
  commits the remote doesn't, but network or authentication failure and a missing
  upstream land here too. Where it is a real divergence, never resolve it with a
  merge, a rebase, or a reset; report it and leave it for the user.

Neither failure costs the sweep its evidence, because classification and
containment ask `<default-ref>`, which step 3 made current without the working
tree's help. What a failure here does cost is exactly this: the checked-out
branch stays excluded, and the user is left where they were rather than on an
updated default branch. Both go in the report.

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
output but is not in bucket A. Its commits are already in the default branch and
its remote branch still exists, so someone may still be using it. **These are
asked about**, in step 7's single batched question — mostly because `--merged` is
an ancestry test, so a branch nobody has committed to yet is "merged" too, and
that is work someone is about to start rather than work that landed.

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
git worktree prune -v 2>&1
```

This runs here, before anything reads a worktree, because the status check below
would otherwise run `git -C` against a path that does not exist — which fails,
and looks exactly like the "something changed underneath you" case that skips the
branch, leaving it alive on the strength of a worktree that is already gone.

**`-v` is not optional**, because this prune is the one irreversible thing the
skill does without asking (below). Plain `git worktree prune` is silent and exits
`0` whether it removed nothing or removed six entries, so without `-v` there is
nothing to tell the user. With it, each removal prints a line like `Removing
worktrees/wt: gitdir file points to non-existent location`. **Keep those lines
and put them in the step 8 report.**

**`2>&1` is not optional either**, and it is the half that looks like shell
noise: `-v` writes those lines to **stderr**, not stdout. Capture the command's
stdout alone and you get an empty string on every run — which step 8 reads as the
"nothing was pruned" case, so the one irreversible unasked-for operation in the
skill goes unreported precisely when it did something.

**That prune does not finish the job.** Locking a worktree exists precisely to
stop its administrative files being pruned, so a *locked* entry whose directory
is gone survives it — and agent tooling locks the worktrees it creates (step 7),
so that is the common flavour here rather than an exotic one.

So for each branch the sweep proposes to delete, decide first whether its
worktree directory is still there, and keep that distinct from a check that
failed:

- **Path does not exist** → `git worktree unlock <worktree-path>`, then `git
  worktree prune -v 2>&1`. Skip the status check, and treat none of it as a
  failure. Both flags for the same reasons as above: its stderr output is what
  the report is built from.
- **Path exists** → run the check below.

Three things about that first bullet, each of which a plausible-looking
alternative gets wrong:

- **Test existence by probing the path** — `test -d "<worktree-path>"`, or
  `Test-Path` under PowerShell. `git worktree list --porcelain` supplies the
  branch-to-path mapping every command in this step needs, and nothing more: it
  marks an *unlocked* stale entry `prunable`, but prints a **locked** stale one
  identically to a live locked one. The prune above already cleared every
  unlocked stale entry, so a locked one is the only kind that reaches this test
  and git's own output can never distinguish it.
- **Unlock and prune is the whole remedy.** Carrying on as though the branch had
  no worktree leaves the entry registered, and `git branch -D` in step 7 then
  refuses with `error: cannot delete branch '<branch>' used by worktree at
  '<path>'` — so the branch survives, which is the outcome this case exists to
  prevent, reported under a different wrong reason.
- **Unlocking here is exempt from step 7's ask-before-unlocking rule.** That rule
  protects a working directory someone else may be using; here the directory is
  gone and the lock guards nothing, so the question would have one sensible
  answer. The exemption is this case only — step 7's unlocking stays scoped to
  the branches in the candidate set.

  **The plain prune above is repo-wide and cannot be scoped**, and that is worth
  stating honestly rather than justifying away. `git worktree prune` takes no
  path argument: it sweeps every unlocked entry whose directory is unreachable,
  including worktrees with nothing to do with the merged PR. If a path is only
  *temporarily* unreachable — an unmounted drive, a disconnected share, a
  directory something else is mid-move on — that entry goes anyway, and the loss
  is not recoverable: pruning deletes the entry's admin directory outright —
  `.git/worktrees/<id>`, or `<bare-dir>/worktrees/<id>` in a bare layout — so `git
  worktree repair` cannot restore it (`error: unable to locate repository`), and
  `git worktree add` on the returned path refuses with `fatal: '<path>' already
  exists`. The files in the directory survive; what is gone is its status as a
  worktree, plus that worktree's own HEAD, index and reflog. Recovery is manual —
  move the files aside, re-add the worktree, move them back. The sweep needs the
  prune and git offers no scoped form, so this is a cost the skill accepts rather
  than one it avoids. Say so in the report if a prune removed anything.

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

**Settle every question before removing anything**, in two passes. Removing a
worktree is irreversible from this skill's side, and the obvious order — remove
it, then discover the branch is ambiguous, then ask — deletes the working
directory of a branch the user goes on to tell you to keep.

### Pass 1 — decide, touching nothing

Sort every candidate into `delete` or `keep`, using what step 6 established:

- **Any branch step 6 skipped for uncommitted work** → `keep`, before any other
  bullet is considered. Report it with its worktree path so the user can go and
  look. No question is asked about it and nothing below applies to it.

  **It must stay first**, because the bullets below key only on bucket and
  containment and a dirty worktree is neither. Demote it and such a branch sorts
  to `delete`, after which pass 2 clears its lock and only then fails the
  removal — so the protection is given up before the failure that would have
  reported the problem, and the user's own work comes back as "something changed
  underneath you". Git refuses the deletion either way; the lock and the
  explanation are what get lost.

- **Bucket A, containment empty** → `delete`, no question. The remote branch is
  gone and every commit is already in the default branch.
- **Bucket A, containment non-empty** → **ask, and do not guess.** Show the
  branch and the commits step 6 listed, and say plainly that git cannot
  distinguish a squash-merge from work that never landed. The user's answer sets
  `delete` or `keep`.
- **Bucket B, containment empty** → **ask.** The remote branch is still there, so
  someone may still be working on this, and a branch nobody has committed to yet
  is "merged" too. Nothing is at risk — the work is contained and the remote copy
  remains — but it is not this skill's call.
- **Bucket B, containment non-empty** → `keep`, and report the contradiction with
  `--merged`.

**Everything needing an answer goes into one question**: those ambiguous bucket A
branches, the bucket B branches *that reached the ask*, and any **locked worktree
belonging to a branch in this candidate set** whose lock you cannot attribute to
this session (below). Not the bucket B branches the bullet above already sorted
to `keep` — those are decided, not open.
Three of each costs one question, not nine. **Do not ask per branch** — that
trains the user to say yes without reading, which costs exactly the case the
asking exists for. **Ask about nothing outside that set**, and in particular not
about locked worktrees on branches nobody proposed to touch.

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
- **`fatal: cannot remove a locked working tree`** — the worktree is locked, and
  **this is where you go and apply the lock rule below**, not where you conclude
  anything. Locked is the *normal* state for the worktrees this skill deals with,
  since agent tooling locks what it creates for the life of the session. Three
  outcomes, and the answer from pass 1 picks between them:

  - the lock is this session's → unlock and retry the removal;
  - it is not, and pass 1's question came back **approved** → unlock and retry
    the removal;
  - it is not, and pass 1's question came back **declined** → keep the branch and
    report it with the lock reason.

  Reading this error as a decline on its own reports a refusal nobody was asked
  for, and leaves the worktree and branch the run exists to remove both standing.
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

- **This session created it, and the harness says so.** Where the worktree-exit
  tool in step 1 reported leaving *this* worktree **and** this session created
  it, the lock is yours and you have already left. `git worktree unlock <path>`,
  then remove.

  Both halves are needed, and the second is the one that gets dropped. A session
  can *enter* a worktree it did not create — Claude Code's `EnterWorktree` takes
  an existing path — and the exit tool reports leaving that one too. So the exit
  report alone is not proof of ownership, and **treating it as proof silently
  unlocks and removes another, possibly still-running, session's working
  directory.** That needs an enter-by-path and a live owner, so it is cornered
  rather than likely — but it is the reason the second half is there, and the
  reason collapsing this to "the tool said we left it, so it is ours" is wrong.
  Where you cannot tell, you cannot tell: take the bullet below.
- **Everything else**, including a reason naming another session and a reason you
  cannot attribute at all. Show the user the path and the lock reason verbatim
  and ask before unlocking, then **act on the answer**: approved → unlock and
  remove, as above; declined → keep the branch and report it with the reason.

  **This is the ordinary path, not the exception**, since the worktree being
  cleaned up is usually another session's. A rule that stops at "ask" leaves the
  commonest run in this skill's remit asking, getting a yes, and having no
  instruction for the yes — worktree still locked, branch still undeleted, both
  reported as kept despite consent, and a re-run producing the same non-result.

**Ask in the batch**, in the same pass-1 question as the ambiguous branches, so
three locked worktrees cost one question rather than three.

Two tests this rule deliberately does not use: "I was standing in it", which is
not ownership for the reason above; and matching a session id or pid parsed out
of the reason text, which is not reliably knowable from inside the skill and
would send every lock down the ask path. The harness's own answer is the only
trustworthy signal; absent it, ask.

Never unlock a worktree step 6 flagged as holding uncommitted work. The lock
question only arises for worktrees already established as clean.

Then the branch:

```bash
git branch -D <branch>
```

**`-D`, deliberately, and only for a branch pass 1 put in the `delete` set.** It
looks like the dangerous flag and here it is the honest one, so do not "fix" it
back to `-d`: `-d` answers a *different question* — containment in the branch's
own upstream, falling back to `HEAD` where the upstream is gone, neither of which
is containment in the default branch. It would refuse every squash-merged branch
the user just confirmed, and accept a branch whose work is in a stale upstream
and nowhere else. Step 6's check is what decides this, run explicitly against a
ref step 2 pinned for the purpose; `-D` executes that decision rather than
skipping one.

**Record the sha of every branch deleted and put it in the report.** `git branch
-D` prints it, and it is the only thing between a wrong answer — the skill's or
the user's — and reflog archaeology.

No second `git worktree prune` is needed: step 6's prune and its per-entry
unlock-and-prune already cleared what this run is responsible for, and `git
worktree remove` clears the entry for each worktree it removes.

## Step 8: Report

State plainly what happened:

- The default branch's new position: `Already up to date` or the commit range
  pulled — and where the switch or the pull did not happen, say so and why,
  since that is the difference between the user being left on an updated default
  branch and being left where they started
- Branches deleted, with the sha of each and which bucket it came from
- Worktrees removed
- **Worktree entries pruned**, from step 6's `git worktree prune -v 2>&1` output —
  separately from the line above, because these are entries whose directory was
  already gone rather than worktrees this run removed, the prune is repo-wide so
  some may belong to branches the sweep never considered, and it is irreversible.
  Silence here is the normal case and needs no line at all
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
