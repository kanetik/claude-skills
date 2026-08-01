# Mechanics

`gh` incantations for the steps in `SKILL.md`. `<num>`, `<owner>`, `<repo>` are placeholders. Add `--repo <owner>/<repo>` to every call when the PR is not in the working directory's repo.

`<tmp>` is the one placeholder you create rather than derive. Make it **deterministic per PR and outside any git repository**: `"${TMPDIR:-/tmp}/pr-skeptic-<owner>-<repo>-<num>"`, in that POSIX form, in every **Bash** snippet on this page including on Windows (the PowerShell posting block takes the native form — see there) — these are Bash snippets, and `"$env:TEMP\..."` is PowerShell syntax that Bash expands to a *relative* path (`$env` is unset), which puts the whole staged checkout inside the user's own repository and later aims an `rm -rf` at a relative path in whatever directory the shell happens to be. Keyed on the repository as well as the number, because PR numbers are small integers and any user with two repos has a `#7` in both — sharing one staging directory means the second run's opening `rm -rf` deletes the worktree eight live reviewers are reading. Deterministic so an interrupted run's leavings can be found and cleared by the next one; outside any repo because a path resolved into the working directory means `git worktree add` plants a second full checkout of the PR head where it shows up in `git status` and can be swept into a commit.

**The shell variables below (`$REPO`, `$BASE`, `$BASETIP`, `$REMOTE`, `$REVIEWED`, and `$LASTID` from the posting block) live only inside their own invocation.**

`$REVIEWED` deserves its own note: it is the head sha **the blind reviewers actually read**, and it survives a re-staging where a freshly-read `headRefOid` does not. Every staleness question — has the head moved, was it a force-push, which sha does the review post at — is asked against `$REVIEWED`. Re-deriving it instead makes those questions compare a value against itself and answer "unchanged" forever. Later stages run in later shells, where an unset `$BASE` turns `git diff "$BASE...<head>"` into `HEAD...<head>` — the empty diff, exit code 0, no output, no error. Echo each resolved value when you compute it and carry the literals forward, the same way `<num>` and `<owner>` are carried. `$REPO` matters most: teardown runs many turns after staging, and aimed at the wrong repository it leaves `refs/prskeptic/*` and a worktree registration in the user's own, pinning the PR's objects alive with nothing to say so.

The snippets below are POSIX-shell forms and assume Git Bash on Windows, where `awk` and `cygpath` live — `jq` does not ship with it and has to be installed separately. Only the posting step needs a standalone `jq` (the `--jq` flags elsewhere are `gh`'s own), and its PowerShell alternative uses `ConvertTo-Json`, so that block is the route to take where `jq` is missing rather than only where the shell is PowerShell.

## Resolve the PR

```bash
branch=$(git branch --show-current)
gh pr list --head "$branch" --json number,title,url        # named branch
gh pr list --search "$(git rev-parse HEAD)" --json number,title,url   # detached HEAD
```

Zero matches and no PR named in the invocation → say so and stop; this skill reviews a PR and there isn't one. Multiple → ask which.

## Stage the checkout

```bash
gh pr view <num> --json number,title,headRefOid,baseRefName,state,mergedAt

# The PR lives in its base repo, which is NOT `origin` in a fork clone -- there `origin`
# is the fork, and pull/<num>/head fetched from it either 404s or, worse, resolves to
# the fork's own PR of that number and reviews unrelated commits.
BASEREPO=$(gh pr view <num> --json url --jq '.url | sub("/pull/.*";"")')

# Clear anything an interrupted earlier run left behind. First, because the paths are
# deterministic: a stale clone makes `gh repo clone` fail with "destination path already
# exists", and a stale worktree makes `git worktree add` fail hard -- either way the skill
# cannot start on that PR again until someone finds a temp directory they were never told
# about. The `rm -rf` plus the `worktree prune` below are what actually clear it; keep both.
#
# But STOP if <tmp>/run.lock was touched in the last 30 minutes: the key is (owner, repo,
# num), so a second run on the SAME PR shares this directory with a first one that may still
# be live -- eight subagents make a run look stalled for minutes. Clearing it deletes the
# worktree those reviewers are reading, and their teardown later deletes this run's payload
# files. On LIVE-RUN-SUSPECTED, ask the user whether the other run is still going rather than
# continuing through this block. Older than that, the lock is a crashed run's leaving: sweep it.
#
# The window only works if the lock keeps moving, so `: > "<tmp>/run.lock"` again at every
# stage boundary -- after staging, after the stage-2 interview (which waits on a human and can
# outlast 30 minutes by itself), and once per reviewer dispatch. A lock that ages out under a
# live run is worse than none: the second run stops asking and clears the worktree the first
# run's reviewers are mid-read of.
#
# Stage boundaries are NOT enough on their own, because the two longest waits in the run sit
# BETWEEN them: the concurrent blind pass (stage 4) and the cross-check (stage 6, the largest
# prompt the skill builds). Either can outlast 30 minutes on a large PR. So also re-touch the
# lock on a timer -- every ~10 minutes -- for as long as any subagent is outstanding. A second
# run on the same PR is not hypothetical: the key is (owner, repo, num), pr-review-loop
# re-invokes this skill on every fix push, and the user can run /pr-review-skeptic on the same
# PR at the same time.
if [ -n "$(find "<tmp>/run.lock" -mmin -30 2>/dev/null)" ]; then
  echo "LIVE-RUN-SUSPECTED"; exit 1     # stop here and ask; do NOT clear
fi
rm -rf "<tmp>"                               # the whole staging dir: a crashed run's payload files
mkdir -p "<tmp>" && : > "<tmp>/run.lock"     # sit here too, and hold review text quoting user code
                                             # touch the lock again at every stage boundary below

# Cross-repo PR with no local clone at hand -- get one, and work from it.
gh repo clone <owner>/<repo> "<tmp>/repo-<num>"

# $REPO is the checkout every git call below runs against: the current repo for a PR in it,
# else the clone above. Teardown happens many turns later, in another shell -- point it at
# the wrong repo and the fetch plants refs/prskeptic/* and a worktree registration in the
# user's own repository, where nothing ever reclaims them.
REPO=<repo-root-or-tmp-clone>

# Fetch from an existing remote pointing at the base repo where there is one; $BASEREPO is
# the fallback for the fork/cross-repo case. `git fetch https://...` on a repo whose remote
# is SSH has no credential helper unless `gh auth setup-git` was run, and a private repo
# then fails or blocks on a credential prompt with no TTY.
#
# Compare on owner/repo, normalised out of each remote URL: an SSH remote never matches an
# https string, and a substring test would match sibling repos (acme/widget ~ acme/widget-android).
OWNERREPO=$(gh pr view <num> --json url --jq '.url | capture("[^/]+/(?<or>[^/]+/[^/]+)/pull").or')
REMOTE=$(git -C "$REPO" remote -v | awk '$3=="(fetch)"{u=$2; sub(/\.git$/,"",u); sub(/^git@[^:]+:/,"",u);
           sub(/^[a-z]+:\/\/[^\/]+\//,"",u); print $1, u}' \
         | awk -v r="$OWNERREPO" '$2==r {print $1; exit}')
REMOTE=${REMOTE:-$BASEREPO}

git -C "$REPO" worktree prune
git -C "$REPO" fetch "$REMOTE" "+pull/<num>/head:refs/prskeptic/<num>"   # head, into a local ref
git -C "$REPO" fetch "$REMOTE" "<baseRefName>"                           # base tip -> FETCH_HEAD
BASETIP=$(git -C "$REPO" rev-parse FETCH_HEAD)                           # the next fetch overwrites FETCH_HEAD

# An already-merged PR needs its pre-merge base. Once the head is contained in the base
# branch -- which a merge-commit merge (GitHub's default) makes true -- merge-base returns
# the head itself, so the diff comes back empty on a PR that plainly changed things. The
# empty-$MERGE guard matters: a head can be contained with no merge commit (commits that
# reached the base another way), and `rev-parse "^1"` prints "^1" and exits 128, so BASE
# would be the literal string and every later git call dies on "bad revision".
MERGE=""
if git -C "$REPO" merge-base --is-ancestor "<headRefOid>" "$BASETIP"; then
  MERGE=$(gh pr view <num> --json mergeCommit --jq '.mergeCommit.oid // empty')
fi
if [ -n "$MERGE" ]; then
  BASE=$(git -C "$REPO" rev-parse "$MERGE^1")                            # the base as it was pre-merge
else
  BASE=$(git -C "$REPO" merge-base "$BASETIP" "<headRefOid>")
fi
git -C "$REPO" cat-file -e "<headRefOid>^{commit}"                       # both shas resolve before any diff

git -C "$REPO" worktree add "<tmp>/pr-<num>" "<headRefOid>"              # every reviewer works here

REVIEWED=<headRefOid>          # the sha the reviewers actually read -- fixed for the life of the review
echo "REPO=$REPO REMOTE=$REMOTE BASE=$BASE BASETIP=$BASETIP REVIEWED=$REVIEWED TMP=<tmp>"
```

`$BASETIP` is also what the project's config layer is read from ([`configuration.md`](configuration.md)) — `git show <baseRefName>:…` would need a local branch of that name, which a fresh clone or an integration-branch base does not have.

The same directory needs **two path forms**, and they are not interchangeable.

- **In the shell, use the POSIX form and quote it every time** — `"<tmp>/pr-<num>"`. An unquoted Windows path loses its backslashes to shell escaping (`C:\Users\me\Temp/pr-42` collapses to `C:UsersmeTemp/pr-42`), and `git worktree add` then plants a garbage-named full checkout inside the user's own repository, which teardown will not find again.
- **In the `{{REPO_PATH}}` slot, use the native absolute form** — `cygpath -w` on Windows. Subagents open files with their own tools rather than through your shell, and a Git Bash `/tmp/...` path resolves for Bash and for nothing else: every reviewer's first read returns not-found, and the brief's report-what's-missing rule turns that into a page of findings about absent files.

The leading `+` on the refspec earns its place on the second run: a force-push — routine on a PR that has just been handed findings — makes an unforced fetch fail non-fast-forward and leaves the local ref on the superseded head.

Teardown — `SKILL.md` stage 9, and **every other exit after staging**: a cancelled run, a failed subagent, an error at the posting step, and the deliberate stops at stages 2 and 3 alike. Once `worktree add` has run, the only orderly ways out are through here.

```bash
git -C "$REPO" worktree remove --force "<tmp>/pr-<num>"
git -C "$REPO" update-ref -d "refs/prskeptic/<num>"
git -C "$REPO" update-ref -d "refs/prskeptic/<num>-new" 2>/dev/null   # only if the head-moved check ran
rm -rf "<tmp>"                             # the whole per-PR directory, clone and payload files included
```

`--force` because `git worktree remove` refuses outright on any untracked file a reviewer left behind. Nothing the run needs to keep lives there — stage 2's config file goes to the primary checkout, never here.

Remove the whole `<tmp>` directory, not just its two subdirectories. The payload files sit directly in it — `body.md`, every `c-<n>.md`, every `f-<n>.md`, `reply.md`, `comments.jsonl`, `review.json` — and they hold the full review text, which by design quotes the user's source. Note the `f-<n>.md` and `reply.md` entries: those are read by calls that happen *after* the review call, which is why teardown waits for the last posting call rather than the first ([`SKILL.md`](../SKILL.md) stage 9). Left behind they sit in a deterministic path nothing ever reclaims. The cross-repo clone goes with it, which on a large upstream repo is a few hundred megabytes per run.

## Scope the change

From inside the staged worktree:

```bash
git -C "<tmp>/pr-<num>" -c core.quotePath=false \
    diff --name-status --no-renames "$BASE...$REVIEWED"      # the file list
```

**Two file lists on a later run, and they feed different reviewers** ([`SKILL.md`](../SKILL.md) stage 3). The command above is the **composition** reviewer's list, on every run. The **content** reviewers' list is the delta since the last review, intersected with it:

```bash
git -C "<tmp>/pr-<num>" -c core.quotePath=false \
    diff --name-status --no-renames "$LASTREVIEWED..$REVIEWED" > "<tmp>/delta.txt"
git -C "<tmp>/pr-<num>" -c core.quotePath=false \
    diff --name-only --no-renames "$BASE...$REVIEWED" | sort > "<tmp>/prfiles.txt"
awk -F'\t' 'NR==FNR{p[$0];next} ($2 in p)' "<tmp>/prfiles.txt" "<tmp>/delta.txt"   # content units
```

**`-F'\t'` is load-bearing.** `--name-status` separates the status from the path with a tab, and `core.quotePath=false` does not quote a path containing a space, so awk's default whitespace splitting turns `M<TAB>docs/release notes.md` into `$2 = docs/release`, which matches no key. The file drops out of the content units silently, no content reviewer reads it, and stage 7 still reports the delta as reviewed — the same class of hole `core.quotePath=false` and `--no-renames` are already here to prevent, on a path shape far commoner than a non-ASCII byte.

Partitioning the raw delta instead breaks in two ways, and the second is silent. `$LASTREVIEWED..$REVIEWED` is a plain two-endpoint diff, so **after the base branch is merged into the PR branch** — one click of "Update branch" between rounds — it contains all the upstream code, while `$BASE` has moved forward so the PR's own diff does not. Reviewers are then dispatched over files the pull request does not modify, and any finding they return cannot anchor: the anchor check tests new-side hunks of `$BASE...$REVIEWED`, where those lines do not appear. Every such finding falls to tier 3, in the body with no thread, which is the tier that comes back `new` every round forever.

**What the intersection buys, and what it leaves.** It keeps the reviewed **file set** inside the pull request's own, which is what stops whole upstream files being handed out as units and keeps `max_reviewers` sized against work the PR owns. It does **not** narrow the range within a file: a content reviewer's `{{DIFF_RANGE}}` is still `$LASTREVIEWED..$REVIEWED`, so for a file both the PR and the merge touched — a build file, a lockfile, a version catalog — the reviewer still reads upstream hunks, and where the PR's own edit predates `$LASTREVIEWED`, everything it reads there is upstream. That residue is why the brief gives every reviewer a `{{PR_RANGE}}` slot holding `{{BASE}}...{{HEAD}}`: without it a delta-scoped content reviewer is told to test its anchors against a range it has no way to compute and is barred from discovering. What the slot buys is a reviewer that reports such a finding with `line: none` instead of a line that cannot anchor — **not** a reviewer that suppresses it. A finding on a path outside the PR's diff is still a finding, and tier 3 is where it lands. (`$LASTREVIEWED...$REVIEWED` is not a fix — `$LASTREVIEWED` is an ancestor, so the two forms name the same range.)

And skipping the delta form entirely — building units from the whole-change list while filling `{{DIFF_RANGE}}` with `$LASTREVIEWED..{{HEAD}}` — hands a reviewer a large unit of which a few files have any content in its range, leaves `max_reviewers` sized against the full change so the cap keeps forcing oversized units, and delivers none of the attention saving the delta scope exists for while looking like it worked.

Not `gh pr view --json files`: it returns at most 100 files and gives no signal when it truncates, so a 300-file PR partitions the first hundred and reports full coverage over all of them. `$BASE` and `$REVIEWED` fill the `{{BASE}}` and `{{HEAD}}` slots. Downstream of the staging block, `$REVIEWED` is the name for the reviewed head — `<headRefOid>` appears only above, where it is the value being read for the first time.

`--name-status` rather than `--name-only` because the status matters downstream: a `D` path is in the change but not in the worktree, and a reviewer sent to open it finds nothing and — following the brief's report-what's-missing rule — turns a deletion into a finding about an absent file. Mark deleted paths as deleted when they reach `{{FILES}}`; they are reviewed through the diff.

`core.quotePath=false` so paths reach `{{FILES}}` and the payload byte-for-byte. Git's default octal-escapes any non-ASCII byte and wraps the path in literal quotes — `src/café.kt` comes back as `"src/caf\303\251.kt"` — and a reviewer sent to open that finds nothing and reports a missing file that is present. Worse if such a finding does anchor: the mangled path goes into the payload, GitHub 422s the all-or-nothing call, and one i18n fixture costs the whole review its inline comments.

`--no-renames` so the statuses stay the three the brief documents. Rename detection is on by default and emits `R<score>` with *two* tab-separated paths, one of which is not in the worktree — an undefined status and a phantom file for the reviewer, and an ambiguous count for stage 3's one-file-one-unit condition. Split into `D` + `A`, both already handled.

## CI status

```bash
gh pr checks <num>                                          # human-readable, non-zero exit on failure
gh pr view <num> --json statusCheckRollup                   # structured
```

Fills `{{CI}}`: the failing check names and what they report, or that everything passes. No checks configured → "no CI configured", and the reviewer judges tests by reading alone.

## Prior review history

Read by two stages now, for different things: **stage 3** takes the last-reviewed commit and the settled decisions from it, and **stage 6** takes the whole payload for bucketing.

### `$LASTREVIEWED` — the commit this skill last reviewed (stage 3)

The most recent review whose body carries the `<!-- pr-review-skeptic -->` marker, and the commit its reviewers actually read. **Take it from the coverage record, then guard that value** — the record's sha is what gets tested, never the review's `commit_id`, which on the force-push route is the current head and would pass a guard the reviewed sha fails.

```bash
# 1. Read the coverage record this skill writes into its own review body (stage 7).
#    That sha is what the reviewers read; `commit_id` is not, on the force-push route,
#    which posts body-only against the CURRENT head so GitHub stamps the review with a
#    commit nobody reviewed.
#
#    RESTRICT TO THE AUTHENTICATED ACCOUNT'S OWN REVIEWS. The reviews endpoint returns
#    reviews by anyone who can see the PR -- on a public repo, any GitHub user -- and the
#    record is the one input that decides this run's scope. Unfiltered, a reviewer who
#    writes `<!-- pr-review-skeptic: reviewed=<any ancestor of head> unreviewed-units=0 -->`
#    into a review body picks the scope: the sha passes the ancestry guard by construction,
#    stage 3 declares a later run, the content reviewers get an empty or near-empty delta,
#    and the run posts "no blocking findings in the changes since <sha>" over code no
#    reviewer read -- then records unreviewed-units=0 so the next run scopes past it too.
#    This is the same trust boundary the project keys and `allow_agent_posting` are read at
#    the base ref for: PR-side content must not steer the review of itself. The marker
#    identifies this skill's work only WITHIN that account's reviews.
# gh's --jq takes exactly ONE argument, the filter -- it has no --arg passthrough, so
# interpolate the login into the filter string (double quotes) as the $LASTID block does.
# `--jq --arg me "$ME" '…'` fails with "accepts 1 arg(s), received 4".
ME=$(gh api user --jq .login)
LASTREVIEWED=$(gh api "repos/<owner>/<repo>/pulls/<num>/reviews" --paginate \
  --jq ".[] | select(.user.login == \"$ME\") | select(.body | contains(\"<!-- pr-review-skeptic\")) | .body" \
  | sed -n 's/.*<!-- pr-review-skeptic: reviewed=\([0-9a-f]*\) .*/\1/p' | tail -1)

# There is deliberately NO fallback to the review's commit_id. It is wrong on the
#    force-push route, and a review with no coverage record cannot tell you whether that
#    run left units unreviewed -- which sends the run to first-run scope anyway
#    ([`SKILL.md`](../SKILL.md) stage 3), so any value derived from commit_id would be
#    discarded. Empty here means first run, full stop.
#
# The read emits one line per matching review and reduces in the shell. NOT `| last |`
# inside the --jq: --jq runs PER PAGE (see "Any other failure" below, which solves the
# identical problem for $LASTID), so on a PR with more than 30 reviews -- the loop-driven
# PR this scope exists for, and the only case where --paginate does anything -- that form
# emits one value per page and $LASTREVIEWED comes back multi-line.

# 2. Empty -> no prior run carrying a record -> first run.
# 3. Otherwise test that it is still on the branch, on THIS value:
git -C "$REPO" merge-base --is-ancestor "$LASTREVIEWED" "$REVIEWED"
# 0 = still on the branch      -> later run
# 1 = force-pushed off it      -> first-run scope
# anything else = unanswered   -> first-run scope
```

`cat-file -e` is the wrong test and fails open. Teardown removes `refs/prskeptic/<num>` but not the objects behind it, so on a same-repo PR — the `pr-review-loop`-driven case — an orphaned commit stays in the object database until it is pruned, weeks later, and resolves fine. The guard would never fire: the run would diff `$LASTREVIEWED..$REVIEWED` across a rewrite, which after a rebase is upstream churn that the PR-file intersection then reduces to nearly nothing. The content reviewers would then read almost none of the rewritten change while the review claims delta coverage **since a commit no longer on the branch** — a posted verdict whose coverage line names a sha that is not in the PR's history, on the PR that most needs a real read. Only the cross-repo path escapes it, and only because its clone is rebuilt each run.

Testing the record's sha rather than `commit_id` is what makes the guard meaningful on the force-push route: `commit_id` there is the current head, an ancestor of any later `$REVIEWED`, so a guard run against it would answer "later run" while the orphaned sha the reviewers actually read — the one that fails — went untested.

**Match on the marker *within the authenticated account's own reviews*.** These reviews post under the user's account and are otherwise indistinguishable from a hand-written one, so a filter looking for a *bot* author finds nothing and silently makes every run a first run — but the account itself is a usable filter and a necessary one, for the reason in the block above: the coverage record decides this run's scope, and any reviewer on the PR can write one into a review body. And take the *last* such review, not the first: taking the first re-reviews every round's work on every round, which is the behaviour the delta scope exists to end.

### The full payload (stage 6)

```bash
gh pr view <num> --json body,reviews,comments,commits
```

`comments` here is the PR's **issue** comments, not the review threads below, and it is the one field easy to mistake for redundant. It carries the disposition records for findings that never got a thread ([`cross-check.md`](cross-check.md)) — drop it and exactly those findings come back `new` on every run, which on a PR being driven through a loop is a round that repeats rather than accumulates.

`commits` alone carries no paths — only `oid`, dates, and messages — so it cannot answer the question the `unfixed` bucket asks. Get the paths too, and pass those through with the threads:

```bash
for oid in $(gh pr view <num> --json commits --jq '.commits[].oid'); do
  git -C "$REPO" show --name-only --format='%H %cI' "$oid"
done
```

That pairing — which commit touched which path, and when — is what separates a concern that was *changed* in response from one that was only argued about. Without it every genuinely unfixed defect falls through to `re-raised`, which keeps its severity, so the bucket [`cross-check.md`](cross-check.md) calls the strongest signal this review produces is unreachable.

Thread resolution state needs GraphQL:

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!,$cursor:String){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      reviewThreads(first:100,after:$cursor){
        pageInfo{hasNextPage endCursor}
        nodes{ isResolved isOutdated subjectType path line originalLine originalStartLine
               comments(first:50){nodes{databaseId author{login} body url createdAt}} }
      }}}}' -F owner=<owner> -F repo=<repo> -F num=<num>
```

Paginate on `hasNextPage`. A thread's resolution plus its replies is what separates `settled` from `re-raised` — a thread closed after the author explained why they chose otherwise reads very differently from one closed by a commit.

`databaseId` is the id the replies endpoint needs, and it is how a run recognises its own earlier comments: every comment this skill posts ends with the marker line `<!-- pr-review-skeptic -->`. Without it there is nothing to recognise — these reviews are authored by the user's own account, indistinguishable from a hand-written one.

`line` comes back **null on any outdated thread**, so match on `originalLine` when it does. Outdated is the common case here, not the rare one: a rebase or a formatting push marks every thread in the PR outdated at once, and the run that follows is exactly the one that needs to find its own earlier comment.

`subjectType` is why it is in the selection: a `FILE` thread — the file-level comments below — has `line` **and** `originalLine` null forever, outdated or not, so it is not distinguishable from an outdated `LINE` thread without it, and a line-based key matches no file-level thread ever. Match those on `path` plus the finding's substance ([`cross-check.md`](cross-check.md)). Getting this wrong posts a second thread beside the first and notifies everyone twice for one defect — on exactly the findings the file-level tier exists to make settleable.

## Post the review

One review carries the summary body and every inline comment. Build a JSON payload and post it:

Finding bodies are free prose quoting the code under review — quotes, backslashes, fenced snippets. **Write every body to a file, and let a JSON encoder read it from there.** Two separate hazards close this way: one hand-written `"` makes the payload malformed and this call is all-or-nothing, so the summary and every other comment fail with it; and a body pasted into a shell assignment has its backticks and `$(…)` evaluated by the shell before `jq` ever sees them, which both corrupts the quoted code and executes text lifted out of the repository being reviewed.

So: write `<tmp>/body.md` and one `<tmp>/c-<n>.md` per inline comment with a **quoted heredoc** — `<<'EOF'`, where the quoted delimiter is what stops the shell evaluating the contents — then:

```bash
: > "<tmp>/comments.jsonl"      # truncate -- a retry must not re-append the first attempt's comments

# one compact JSON object per inline comment
jq -nc --arg p "data/sync/Merge.kt" --argjson l 118 --rawfile b "<tmp>/c-1.md" \
  '{path:$p, line:$l, side:"RIGHT", body:$b}' >> "<tmp>/comments.jsonl"

jq -s '{comments: .}' "<tmp>/comments.jsonl" > "<tmp>/comments.json"
jq -n --arg sha "$REVIEWED" --rawfile body "<tmp>/body.md" --slurpfile c "<tmp>/comments.json" \
  '{commit_id:$sha, event:"COMMENT", body:$body, comments:$c[0].comments}' > "<tmp>/review.json"

# High-water mark, BEFORE the POST -- see "Any other failure" below, which needs to tell this
# run's review from one an earlier run left. Captured afterwards it includes this review, and
# the check then concludes nothing landed and re-sends the lot.
LASTID=$(gh api --paginate "repos/<owner>/<repo>/pulls/<num>/reviews" --jq '.[].id' | sort -n | tail -1)
LASTID=${LASTID:-0}
echo "LASTID=$LASTID"          # carry it forward -- the check that needs it runs in a later shell

gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input "<tmp>/review.json"
```

The heredoc rather than a file-writing tool because everything in this block has to agree on one path convention. Git Bash MSYS-converts a `/tmp/…` argument to the native directory before `jq` and `gh` see it; a file-writing tool takes the string literally and resolves the leading `/` against the current drive, so bodies written to `C:\tmp\…` are invisible to a `jq --rawfile` reading `C:\Users\…\AppData\Local\Temp\…`. `review.json` then never gets built, at the last step, after every reviewer has run. Use a file-writing tool here only with the native (`cygpath -w`) path.

A run with **no inline comments** posts through this same path: the `: >` leaves an empty `comments.jsonl`, `jq -s` yields `{"comments": []}`, and an empty array is a valid review. Skipping the truncate would instead have `jq` fail on a file that was never created.

That is "no findings at all, or every finding in another tier" — **not** "a clean verdict". Severity decides the verdict, placement is decided separately, and every finding gets a thread whatever its severity ([`SKILL.md`](../SKILL.md) stage 7): a verdict with no `CRITICAL`/`HIGH` is clean and may still carry four `MEDIUM`s that each need an inline comment. Reading the two as the same thing posts a clean verdict with an empty comment array and drops those four off the PR entirely, where the next run's blind pass re-finds them as `new` forever.

PowerShell, where a heredoc is a parse error and `ConvertTo-Json` does the encoding. Bodies come from files here too, for the same reason.

**Substitute `<tmp>` as the native Windows path here** (the `cygpath -w` form, as for `{{REPO_PATH}}`), not the POSIX literal the Bash snippets use. PowerShell and .NET resolve a leading `/` against the current drive, so `/tmp/pr-skeptic-42/body.md` becomes `C:\tmp\…` and every read and write in this block misses the directory the reviewers actually wrote to — at the last step, after the whole review has been produced.

```powershell
$summary = [System.IO.File]::ReadAllText("<tmp>/body.md")
$c1      = [System.IO.File]::ReadAllText("<tmp>/c-1.md")
$payload = @{ commit_id = $REVIEWED; event = 'COMMENT'; body = $summary
  comments = @(@{ path = 'data/sync/Merge.kt'; line = 118; side = 'RIGHT'; body = $c1 })
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText("<tmp>/review.json", $payload, (New-Object System.Text.UTF8Encoding $false))

# High-water mark, BEFORE the POST -- same purpose and same timing as the Bash block's.
$ids = gh api --paginate "repos/<owner>/<repo>/pulls/<num>/reviews" --jq '.[].id'
$LASTID = if ($ids) { ($ids | ForEach-Object { [long]$_ } | Measure-Object -Maximum).Maximum } else { 0 }
Write-Output "LASTID=$LASTID"      # carry it forward -- the check that needs it runs in a later shell

gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input "<tmp>/review.json"
```

**The `$LASTID` capture is not optional on this route.** It is easy to read as a Bash-block detail, and it is not: this is the route to take wherever standalone `jq` is missing, which on Windows with Git Bash is the default rather than the exception. Without it the ambiguous-failure check below compiles `select(.id > )`, jq errors, the `||` fires, and every ambiguous failure lands on the `<unverifiable>` branch — the one branch that cannot answer the question and has to ask a human, which on an agent-invoked run means nobody. `ForEach-Object { [long]$_ }` because the ids arrive as strings and `Measure-Object -Maximum` would otherwise compare them lexically, making `id 9` beat `id 10`.

`ReadAllText` rather than `Get-Content -Raw`, for two reasons that both land on Windows PowerShell 5.1: `-Raw` returns a decorated PSObject that `ConvertTo-Json` serializes as an object (`"body": {"value": …, "PSPath": …}`) which GitHub rejects outright, and it decodes UTF-8 through the ANSI codepage, so every em dash and arrow in a finding posts as mojibake. Both surface only at the last step, after every reviewer has run.

Write the file BOM-free. `Set-Content -Encoding utf8` emits a BOM on Windows PowerShell 5.1, and `gh api --input` forwards it verbatim for GitHub to reject as unparseable JSON — after every reviewer has already run, and with a file that looks correct in any editor.

`event` is always `COMMENT`. `APPROVE` would let this review satisfy branch protection and admit a merge on an agent's judgement, which is not a call this skill makes; the verdict goes in the body where a person reads it and decides.

**Anchoring.** `line` must be a line the diff touches at `commit_id`, or the API rejects the whole payload with 422 — one bad anchor loses every comment in the call, summary body included.

Check each anchor yourself before building the payload: you already have `git diff "$BASE...$REVIEWED"`, so a finding's `line` either falls inside a **new-side** hunk range (the `+` half of `@@ -a,b +c,d @@`) for its `path` or it does not. New-side because `side` is always `RIGHT` — which also means a finding on a `D` path can never anchor: a deleted file's only hunk range is on the left, and an old-side line number that happens to look plausible passes a careless check and then 422s the whole call. Ones that do not anchor drop to the next placement tier — a file-level comment where the path allows one, the summary body otherwise (below). Doing this up front is what makes the step decidable at all: GitHub's 422 does not say *which* entry it rejected, so a run that skips the check has nothing to act on when the call fails.

**Recovering from a 422.** The call posted nothing, so a retry cannot duplicate. Since the response names no offending entry, rebuild the body with a line saying the inline anchors were rejected and the findings follow as separate comments, re-send the review once with **no** `comments[]` at all — one retry, not a search — then place each of those findings through the file-level path below, one call each, reporting any that fail. That costs a round of separate calls, but it keeps each finding on a thread that can be resolved; folding them all into the body instead trades one bad anchor for a review whose every finding re-raises on the next run. Rebuild the body *before* the retry, for the reason in that section: once it posts, there is no amending it.

**Any other failure — check before re-sending.** The no-duplicate guarantee above belongs to the 422 alone: a timeout, a connection reset, or a 502 can arrive *after* GitHub accepted the review, and `gh` exits non-zero either way. Re-sending then posts the whole review twice, every inline comment duplicated, everyone notified again. So look first:

This runs in a later shell than the POST, so it needs the `$LASTID` literal the posting block echoed — an empty one makes the filter `select(.id > )`, a jq compile error, which trips the "cannot verify" fallback on *every* ambiguous failure and asks the user the one question the mechanism exists to answer. Note `--jq` runs **per page** rather than over a merged array, which is why it emits every id and takes the maximum in the shell: `.[-1].id` would return one id per page, a multi-line value that turns the filter below into a jq syntax error on exactly the many-review PRs `--paginate` is here for.

After an ambiguous failure:

```bash
BODIES=$(gh api --paginate "repos/<owner>/<repo>/pulls/<num>/reviews" \
           --jq ".[] | select(.id > $LASTID) | .body") || BODIES="<unverifiable>"
```

Read `$BODIES` in this order — the first bullet is the one that must not be skipped:

- `BODIES` is exactly `<unverifiable>` → the `||` fired, so **`gh` itself failed and the outcome is unknown; do not re-send.** Say so and ask. This check runs exactly when the network has just misbehaved, so its own call failing is likely — and `<unverifiable>` carries no marker, so anything that tests for the marker first reads it as "absent" and re-posts the review, which is the thing the check exists to stop.
- Otherwise, a body newer than `$LASTID` contains `<!-- pr-review-skeptic -->` → it landed; report it posted.
- Otherwise (the call succeeded and nothing newer carries the marker) → re-send.

`--paginate` because reviews come back oldest-first, 30 to a page, so on a PR driven through a bot loop the newest is nowhere near the first page. The `id > $LASTID` filter because a second run over a PR this skill already reviewed — the repeat-run path the marker machinery exists for — would otherwise match run one's marker, conclude wrongly that it landed, and lose the current review silently. Match the whole marker string with `grep -F`; a body that merely names the skill is not evidence.

A bad anchor is the usual cause of a 422 but not the only one: a `commit_id` the PR no longer contains is rejected the same way, and an identical retry will fail identically. Where the head moved during the run, check whether the reviewed sha is still on the branch. The new head came from `gh pr view` — a remote read — so **fetch it before testing it**, or the test errors on a commit the repo has never seen:

```bash
git -C "$REPO" fetch "$REMOTE" "+pull/<num>/head:refs/prskeptic/<num>-new"
git -C "$REPO" rev-parse --verify "refs/prskeptic/<num>-new"   # the fetch above exits 0 on an empty $REMOTE
git -C "$REPO" merge-base --is-ancestor "$REVIEWED" "refs/prskeptic/<num>-new"
```

Verify the ref before trusting the test: `git fetch "" <refspec>` **exits 0 and creates nothing**, so a `$REMOTE` lost between shells produces a missing ref, then a 128 from `--is-ancestor`, then a post at a sha the force-pushed PR no longer contains — a 422, a retry that 422s identically, and a review lost after every reviewer has run. A missing ref means unanswered, not fast-forward.

Read the exit code strictly: `0` = fast-forward, post at the reviewed sha as usual. `1` = force-push — drop `commit_id` and the inline comments, post the findings in the body against the current head, and say the review describes a commit that has since been rewritten. **Anything else is not an answer**: `128` means the sha did not resolve, and treating that as a force-push discards every anchor and posts a false claim about the PR's history under the user's name. Post at the reviewed sha, or ask. Resist posting the comments piecemeal through `/pulls/<num>/comments`, which trades one notification for N and scatters findings the body was going to carry anyway.

Replying to a thread this skill opened on an earlier run, rather than opening a second one beside it:

```bash
gh api repos/<owner>/<repo>/pulls/<num>/comments/<comment-id>/replies --method POST -F "body=@<tmp>/reply.md"
```

The write-to-file rule governs **every** posting call, not just the review payload: `-F key=@path` reads the value from the file, where `-f body=<text>` would put a finding that quotes the reviewed code through the shell first.

So does the check-before-re-sending rule. This call is separate from the all-or-nothing review payload, so an ambiguous failure here has the same shape and the same cost — re-send blindly and the thread carries two identical replies, notifying every subscriber twice for one defect, which is what the reply path exists to avoid. Re-read the thread first and look for a reply carrying the marker; unknown means ask, not re-send.

## File-level comments — the second placement tier

`subject_type: file` attaches a comment to a whole file rather than a line. It is a property of the **standalone** comment endpoint, not of the `comments[]` array in a review — sending it inside the review payload is another 422 on the same all-or-nothing call, which is why these go out separately, **after** the review call has succeeded:

```bash
gh api repos/<owner>/<repo>/pulls/<num>/comments --method POST \
  -f commit_id="$REVIEWED" -f path="data/sync/Merge.kt" -f subject_type=file \
  -F "body=@<tmp>/f-1.md"
```

This is the home for a finding whose path is in the diff and present at `$REVIEWED` but whose line the change never touched — a defect on line 40 of a file the diff only reaches at line 200 ([`SKILL.md`](../SKILL.md) stage 7, tier 2). It buys the one thing the summary body cannot: a real thread, which can be replied to and resolved, and which a later run's cross-check can read as evidence that the finding was dealt with. A finding with no thread comes back every round forever.

**Every finding that qualifies for this tier gets one.** The extra notification is the price of a settleable finding, and it is worth paying at any severity — a `LOW` with no thread re-raises just as forever as a `HIGH` with none. Don't ration them by importance; the only question is whether the tier applies.

**Order matters, and the failure path is why.** The review call publishes the summary body, and nothing in this skill can amend a published body afterwards — there is no edit step. So a tier-2 failure discovered *after* the review call cannot be "moved into the body"; the body is already on the PR. Two consequences:

- **Decide tier 3 before the review call, not after.** Tier 3 is the findings that could never anchor — a `D` path, a file the change never touched, a path absent from the diff. Those are knowable from the diff you already have, so the body is built with them in it and the placement is correct when it posts.
- **A tier-2 call that fails anyway is reported, not relocated.** Say so in the terminal and in stage 8's report, naming the finding and its path. Do not silently drop it: stage 8 would otherwise count it as placed on a thread when it is nowhere at all.

One call per finding, so a failure costs that finding rather than the review. On failure — a secondary rate limit, a 502, a path the API rejects — do not retry variations.

The ambiguous-failure rule applies here too, but **the marker is not a usable test on this path**. `gh` exits non-zero whether or not GitHub accepted the comment, and by now this same run's inline comments are already on the PR carrying the same marker, quite possibly on the same file — so "look for the marker" answers yes for a comment that never landed. Test for *this finding* instead: capture the comment `databaseId`s on that path before the tier-2 batch begins, and look for one newer than the high-water mark whose body matches this finding (the same shape as `$LASTID` for the review call). Where you cannot establish that, report the finding as unplaced rather than assuming it landed — an unplaced finding the user is told about is recoverable; one silently counted as posted is not.

**Findings that reach neither tier** — on a `D` path, or on a file the change never touched at all — go in the summary body under a heading that names the file, at full severity, listed as having no thread. A defect in code the change depends on is still worth reporting, and it is worth saying that the change is what surfaced it. Say plainly in the body that these carry no thread: whoever dispositions the review needs to know which findings they cannot resolve on the PR, and where those dispositions have to go instead.
