# Mechanics

`gh` incantations for the steps in `SKILL.md`. `<num>`, `<owner>`, `<repo>` are placeholders. Add `--repo <owner>/<repo>` to every call when the PR is not in the working directory's repo.

`<tmp>` is the one placeholder you create rather than derive. Make it **deterministic per PR and outside any git repository**: `"${TMPDIR:-/tmp}/pr-skeptic-<num>"`, in that POSIX form, in every **Bash** snippet on this page including on Windows (the PowerShell posting block takes the native form — see there) — these are Bash snippets, and `"$env:TEMP\..."` is PowerShell syntax that Bash expands to a *relative* path (`$env` is unset), which puts the whole staged checkout inside the user's own repository and later aims an `rm -rf` at a relative path in whatever directory the shell happens to be. Deterministic so an interrupted run's leavings can be found and cleared by the next one; outside any repo because a path resolved into the working directory means `git worktree add` plants a second full checkout of the PR head where it shows up in `git status` and can be swept into a commit.

**The shell variables below (`$REPO`, `$BASE`, `$BASETIP`, `$REMOTE`) live only inside their own invocation.** Later stages run in later shells, where an unset `$BASE` turns `git diff "$BASE...<head>"` into `HEAD...<head>` — the empty diff, exit code 0, no output, no error. Echo each resolved value when you compute it and carry the literals forward, the same way `<num>` and `<owner>` are carried. `$REPO` matters most: teardown runs many turns after staging, and aimed at the wrong repository it leaves `refs/prskeptic/*` and a worktree registration in the user's own, pinning the PR's objects alive with nothing to say so.

The snippets below are POSIX-shell forms and assume Git Bash on Windows, where `awk` and `cygpath` live. Only the posting step carries a PowerShell alternative.

## Resolve the PR

```bash
branch=$(git branch --show-current)
gh pr list --head "$branch" --json number,title,url        # named branch
gh pr list --search "$(git rev-parse HEAD)" --json number,title,url   # detached HEAD
```

Zero matches and no PR named in the invocation → say so and stop; this skill reviews a PR and there isn't one. Multiple → ask which.

## Stage the checkout

```bash
gh pr view <num> --json number,title,headRefOid,baseRefName

# The PR lives in its base repo, which is NOT `origin` in a fork clone -- there `origin`
# is the fork, and pull/<num>/head fetched from it either 404s or, worse, resolves to
# the fork's own PR of that number and reviews unrelated commits.
BASEREPO=$(gh pr view <num> --json url --jq '.url | sub("/pull/.*";"")')

# Clear anything an interrupted earlier run left behind. First, because the paths are
# deterministic: a stale worktree makes `git worktree add` fail hard, and a stale clone makes
# `gh repo clone` fail with "destination path already exists" -- either way the skill cannot
# start on that PR again until someone finds a temp directory they were never told about.
git -C "$REPO" worktree remove --force "<tmp>/pr-<num>" 2>/dev/null
rm -rf "<tmp>/pr-<num>" "<tmp>/repo-<num>"

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
BASE=$(git -C "$REPO" merge-base "$BASETIP" "<headRefOid>")
git -C "$REPO" cat-file -e "<headRefOid>^{commit}"                       # both shas resolve before any diff

git -C "$REPO" worktree add "<tmp>/pr-<num>" "<headRefOid>"              # every reviewer works here

echo "REPO=$REPO BASE=$BASE BASETIP=$BASETIP TMP=<tmp>"       # record these -- later shells will not have them
```

`$BASETIP` is also what the project's config layer is read from ([`configuration.md`](configuration.md)) — `git show <baseRefName>:…` would need a local branch of that name, which a fresh clone or an integration-branch base does not have.

The same directory needs **two path forms**, and they are not interchangeable.

- **In the shell, use the POSIX form and quote it every time** — `"<tmp>/pr-<num>"`. An unquoted Windows path loses its backslashes to shell escaping (`C:\Users\me\Temp/pr-42` collapses to `C:UsersmeTemp/pr-42`), and `git worktree add` then plants a garbage-named full checkout inside the user's own repository, which teardown will not find again.
- **In the `{{REPO_PATH}}` slot, use the native absolute form** — `cygpath -w` on Windows. Subagents open files with their own tools rather than through your shell, and a Git Bash `/tmp/...` path resolves for Bash and for nothing else: every reviewer's first read returns not-found, and the brief's report-what's-missing rule turns that into a page of findings about absent files.

The leading `+` on the refspec earns its place on the second run: a force-push — routine on a PR that has just been handed findings — makes an unforced fetch fail non-fast-forward and leaves the local ref on the superseded head.

Teardown when the run ends — **including when it ends badly.** A cancelled run, a failed subagent, or an error at the posting step leaves the worktree, the ref, and possibly a several-hundred-megabyte clone on disk, and the next run on that PR then fails at its first step for a reason the user cannot see.

```bash
git -C "$REPO" worktree remove --force "<tmp>/pr-<num>"
git -C "$REPO" update-ref -d "refs/prskeptic/<num>"
rm -rf "<tmp>/repo-<num>"                  # only where this run cloned it
```

`--force` because `git worktree remove` refuses outright on any untracked file a reviewer left behind. Nothing the run needs to keep lives there — stage 2's config file goes to the primary checkout, never here. Drop the clone too where the cross-repo path created one; left behind, every run against a large upstream repo adds another few hundred megabytes the user has no reason to know about.

## Scope the change

From inside the staged worktree:

```bash
git -C "<tmp>/pr-<num>" diff --name-status --no-renames "$BASE...<headRefOid>"   # the file list
```

Not `gh pr view --json files`: it returns at most 100 files and gives no signal when it truncates, so a 300-file PR partitions the first hundred and reports full coverage over all of them. `BASE` and `<headRefOid>` fill the `{{BASE}}` and `{{HEAD}}` slots.

`--name-status` rather than `--name-only` because the status matters downstream: a `D` path is in the change but not in the worktree, and a reviewer sent to open it finds nothing and — following the brief's report-what's-missing rule — turns a deletion into a finding about an absent file. Mark deleted paths as deleted when they reach `{{FILES}}`; they are reviewed through the diff.

`--no-renames` so the statuses stay the three the brief documents. Rename detection is on by default and emits `R<score>` with *two* tab-separated paths, one of which is not in the worktree — an undefined status and a phantom file for the reviewer, and an ambiguous count for stage 3's one-file-one-unit condition. Split into `D` + `A`, both already handled.

## CI status

```bash
gh pr checks <num>                                          # human-readable, non-zero exit on failure
gh pr view <num> --json statusCheckRollup                   # structured
```

Fills `{{CI}}`: the failing check names and what they report, or that everything passes. No checks configured → "no CI configured", and the reviewer judges tests by reading alone.

## Prior review history

For the cross-check stage only.

```bash
gh pr view <num> --json body,reviews,comments,commits
```

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
        nodes{ isResolved isOutdated path line originalLine originalStartLine
               comments(first:50){nodes{databaseId author{login} body url createdAt}} }
      }}}}' -F owner=<owner> -F repo=<repo> -F num=<num>
```

Paginate on `hasNextPage`. A thread's resolution plus its replies is what separates `settled` from `re-raised` — a thread closed after the author explained why they chose otherwise reads very differently from one closed by a commit.

`databaseId` is the id the replies endpoint needs, and it is how a run recognises its own earlier comments: every comment this skill posts ends with the marker line `<!-- pr-review-skeptic -->`. Without it there is nothing to recognise — these reviews are authored by the user's own account, indistinguishable from a hand-written one.

`line` comes back **null on any outdated thread**, so match on `originalLine` when it does. Outdated is the common case here, not the rare one: a rebase or a formatting push marks every thread in the PR outdated at once, and the run that follows is exactly the one that needs to find its own earlier comment. Matching on path alone instead posts a second thread beside the first and notifies everyone twice for one defect.

## Post the review

One review carries the summary body and every inline comment. Build a JSON payload and post it:

Finding bodies are free prose quoting the code under review — quotes, backslashes, fenced snippets. **Write every body to a file, and let a JSON encoder read it from there.** Two separate hazards close this way: one hand-written `"` makes the payload malformed and this call is all-or-nothing, so the summary and every other comment fail with it; and a body pasted into a shell assignment has its backticks and `$(…)` evaluated by the shell before `jq` ever sees them, which both corrupts the quoted code and executes text lifted out of the repository being reviewed.

So: write `<tmp>/body.md` and one `<tmp>/c-<n>.md` per inline comment with your file-writing tool (or a quoted heredoc — `<<'EOF'`, where the quoted delimiter is what stops the shell evaluating the contents), then:

```bash
: > "<tmp>/comments.jsonl"      # truncate -- a retry must not re-append the first attempt's comments

# one compact JSON object per inline comment
jq -nc --arg p "data/sync/Merge.kt" --argjson l 118 --rawfile b "<tmp>/c-1.md" \
  '{path:$p, line:$l, side:"RIGHT", body:$b}' >> "<tmp>/comments.jsonl"

jq -s '{comments: .}' "<tmp>/comments.jsonl" > "<tmp>/comments.json"
jq -n --arg sha "<headRefOid>" --rawfile body "<tmp>/body.md" --slurpfile c "<tmp>/comments.json" \
  '{commit_id:$sha, event:"COMMENT", body:$body, comments:$c[0].comments}' > "<tmp>/review.json"

gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input "<tmp>/review.json"
```

A clean verdict posts through this same path with no inline comments: the `: >` leaves an empty `comments.jsonl`, `jq -s` yields `{"comments": []}`, and an empty array is a valid review. Skipping the truncate would instead have `jq` fail on a file that was never created — on exactly the outcome the skill most wants to report.

PowerShell, where a heredoc is a parse error and `ConvertTo-Json` does the encoding. Bodies come from files here too, for the same reason.

**Substitute `<tmp>` as the native Windows path here** (the `cygpath -w` form, as for `{{REPO_PATH}}`), not the POSIX literal the Bash snippets use. PowerShell and .NET resolve a leading `/` against the current drive, so `/tmp/pr-skeptic-42/body.md` becomes `C:\tmp\…` and every read and write in this block misses the directory the reviewers actually wrote to — at the last step, after the whole review has been produced.

```powershell
$summary = [System.IO.File]::ReadAllText("<tmp>/body.md")
$c1      = [System.IO.File]::ReadAllText("<tmp>/c-1.md")
$payload = @{ commit_id = '<headRefOid>'; event = 'COMMENT'; body = $summary
  comments = @(@{ path = 'data/sync/Merge.kt'; line = 118; side = 'RIGHT'; body = $c1 })
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText("<tmp>/review.json", $payload, (New-Object System.Text.UTF8Encoding $false))
gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input "<tmp>/review.json"
```

`ReadAllText` rather than `Get-Content -Raw`, for two reasons that both land on Windows PowerShell 5.1: `-Raw` returns a decorated PSObject that `ConvertTo-Json` serializes as an object (`"body": {"value": …, "PSPath": …}`) which GitHub rejects outright, and it decodes UTF-8 through the ANSI codepage, so every em dash and arrow in a finding posts as mojibake. Both surface only at the last step, after every reviewer has run.

Write the file BOM-free. `Set-Content -Encoding utf8` emits a BOM on Windows PowerShell 5.1, and `gh api --input` forwards it verbatim for GitHub to reject as unparseable JSON — after every reviewer has already run, and with a file that looks correct in any editor.

`event` is always `COMMENT`. `APPROVE` would let this review satisfy branch protection and admit a merge on an agent's judgement, which is not a call this skill makes; the verdict goes in the body where a person reads it and decides.

**Anchoring.** `line` must be a line the diff touches at `commit_id`, or the API rejects the whole payload with 422 — one bad anchor loses every comment in the call, summary body included.

Check each anchor yourself before building the payload: you already have `git diff "$BASE"...<headRefOid>`, so a finding's `line` either falls inside a **new-side** hunk range (the `+` half of `@@ -a,b +c,d @@`) for its `path` or it does not. New-side because `side` is always `RIGHT` — which also means a finding on a `D` path can never anchor: a deleted file's only hunk range is on the left, and an old-side line number that happens to look plausible passes a careless check and then 422s the whole call. Ones that do not go in the **summary body** under a heading naming their path — a little less prominent, and it always works. Doing this up front is what makes the step decidable at all: GitHub's 422 does not say *which* entry it rejected, so a run that skips the check has nothing to act on when the call fails.

**Recovering from a 422.** The call posted nothing, so a retry cannot duplicate. Since the response names no offending entry, move **all** the inline comments into the summary body under path headings and send the single review call once more — one retry, not a search. Resist posting the comments piecemeal through `/pulls/<num>/comments`, which trades one notification for N and scatters findings the body was going to carry anyway.

Replying to a thread this skill opened on an earlier run, rather than opening a second one beside it:

```bash
gh api repos/<owner>/<repo>/pulls/<num>/comments/<comment-id>/replies --method POST -F "body=@<tmp>/reply.md"
```

The write-to-file rule governs **every** posting call, not just the review payload: `-F key=@path` reads the value from the file, where `-f body=<text>` would put a finding that quotes the reviewed code through the shell first.

`subject_type: file` attaches a comment to a whole file, but it is a property of the standalone comment endpoint, not of the `comments[]` array in a review — sending it here is another 422 on the same all-or-nothing call. Where a file-level comment is worth a second request, post it after the review lands:

```bash
gh api repos/<owner>/<repo>/pulls/<num>/comments --method POST \
  -f commit_id=<headRefOid> -f path=<path> -f subject_type=file -F "body=@<tmp>/file-comment.md"
```

Findings on code the PR did not touch cannot anchor anywhere, and neither can findings on a `D` path. Both belong in the body, under a heading that names the file — a defect in code the change depends on is still worth reporting, and it is worth saying that the change is what surfaced it.
