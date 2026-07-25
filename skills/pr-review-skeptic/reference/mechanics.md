# Mechanics

`gh` incantations for the steps in `SKILL.md`. `<num>`, `<owner>`, `<repo>`, `<tmp>` are placeholders. Add `--repo <owner>/<repo>` to every call when the PR is not in the working directory's repo.

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

# Cross-repo PR with no local clone at hand -- get one, and work from it.
gh repo clone <owner>/<repo> <tmp>/repo-<num>

git fetch "$BASEREPO" "+pull/<num>/head:refs/prskeptic/<num>"   # head, into a local ref
git fetch "$BASEREPO" "<baseRefName>"                           # base tip -> FETCH_HEAD
BASE=$(git merge-base FETCH_HEAD "<headRefOid>")
git cat-file -e "<headRefOid>^{commit}"                         # both shas resolve before any reviewer diffs them

git worktree add <tmp>/pr-<num> "<headRefOid>"                  # every reviewer works here
```

The leading `+` on the refspec earns its place on the second run: a force-push — routine on a PR that has just been handed findings — makes an unforced fetch fail non-fast-forward and leaves the local ref on the superseded head.

Teardown when the run ends:

```bash
git worktree remove --force <tmp>/pr-<num>
git update-ref -d "refs/prskeptic/<num>"
```

`--force` because `git worktree remove` refuses outright on any untracked file a reviewer left behind. Nothing the run needs to keep lives there — stage 2's config file goes to the primary checkout, never here.

## Scope the change

From inside the staged worktree:

```bash
git diff --name-only "$BASE...<headRefOid>"      # the file list -- the input to partitioning
```

Not `gh pr view --json files`: it returns at most 100 files and gives no signal when it truncates, so a 300-file PR partitions the first hundred and reports full coverage over all of them. `BASE` and `<headRefOid>` fill the `{{BASE}}` and `{{HEAD}}` slots.

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

`commits` is what separates a concern that was *changed* in response from one that was only argued about — the `unfixed` / `re-raised` split in [`cross-check.md`](cross-check.md) turns on it, and neither bucket can be judged from thread text alone. Pass it through with the threads.

Thread resolution state needs GraphQL:

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!,$cursor:String){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      reviewThreads(first:100,after:$cursor){
        pageInfo{hasNextPage endCursor}
        nodes{ isResolved isOutdated path line
               comments(first:50){nodes{author{login} body url createdAt}} }
      }}}}' -F owner=<owner> -F repo=<repo> -F num=<num>
```

Paginate on `hasNextPage`. A thread's resolution plus its replies is what separates `settled` from `re-raised` — a thread closed after the author explained why they chose otherwise reads very differently from one closed by a commit.

## Post the review

One review carries the summary body and every inline comment. Build a JSON payload and post it:

Finding bodies are free prose quoting the code under review — quotes, backslashes, fenced snippets. **Write every body to a file, and let a JSON encoder read it from there.** Two separate hazards close this way: one hand-written `"` makes the payload malformed and this call is all-or-nothing, so the summary and every other comment fail with it; and a body pasted into a shell assignment has its backticks and `$(…)` evaluated by the shell before `jq` ever sees them, which both corrupts the quoted code and executes text lifted out of the repository being reviewed.

So: write `<tmp>/body.md` and one `<tmp>/c-<n>.md` per inline comment with your file-writing tool (or a quoted heredoc — `<<'EOF'`, where the quoted delimiter is what stops the shell evaluating the contents), then:

```bash
: > <tmp>/comments.jsonl        # truncate -- a retry must not re-append the first attempt's comments

# one compact JSON object per inline comment
jq -nc --arg p "data/sync/Merge.kt" --argjson l 118 --rawfile b <tmp>/c-1.md \
  '{path:$p, line:$l, side:"RIGHT", body:$b}' >> <tmp>/comments.jsonl

jq -s '{comments: .}' <tmp>/comments.jsonl > <tmp>/comments.json
jq -n --arg sha "<head-sha>" --rawfile body <tmp>/body.md --slurpfile c <tmp>/comments.json \
  '{commit_id:$sha, event:"COMMENT", body:$body, comments:$c[0].comments}' > <tmp>/review.json

gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input <tmp>/review.json
```

A clean verdict posts through this same path with no inline comments: the `: >` leaves an empty `comments.jsonl`, `jq -s` yields `{"comments": []}`, and an empty array is a valid review. Skipping the truncate would instead have `jq` fail on a file that was never created — on exactly the outcome the skill most wants to report.

PowerShell, where a heredoc is a parse error and `ConvertTo-Json` does the encoding. Bodies come from files here too, for the same reason:

```powershell
$summary = Get-Content -Raw <tmp>/body.md
$c1      = Get-Content -Raw <tmp>/c-1.md
$payload = @{ commit_id = '<head-sha>'; event = 'COMMENT'; body = $summary
  comments = @(@{ path = 'data/sync/Merge.kt'; line = 118; side = 'RIGHT'; body = $c1 })
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText("<tmp>/review.json", $payload, (New-Object System.Text.UTF8Encoding $false))
gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input <tmp>/review.json
```

Write the file BOM-free. `Set-Content -Encoding utf8` emits a BOM on Windows PowerShell 5.1, and `gh api --input` forwards it verbatim for GitHub to reject as unparseable JSON — after every reviewer has already run, and with a file that looks correct in any editor.

`event` is always `COMMENT`. `APPROVE` would let this review satisfy branch protection and admit a merge on an agent's judgement, which is not a call this skill makes; the verdict goes in the body where a person reads it and decides.

**Anchoring.** `line` must be a line the diff touches at `commit_id`, or the API rejects the whole payload with 422 — one bad anchor loses every comment in the call, summary body included. So any finding you cannot anchor with confidence goes in the **summary body** under a heading naming its path. That costs a little prominence and always works.

`subject_type: file` attaches a comment to a whole file, but it is a property of the standalone comment endpoint, not of the `comments[]` array in a review — sending it here is another 422 on the same all-or-nothing call. Where a file-level comment is worth a second request, post it after the review lands:

```bash
gh api repos/<owner>/<repo>/pulls/<num>/comments --method POST \
  -f commit_id=<head-sha> -f path=<path> -f subject_type=file -f body=<text>
```

Findings on code the PR did not touch cannot anchor anywhere. They belong in the body, under a heading that names the file — a defect in code the change depends on is still worth reporting, and it is worth saying that the change is what surfaced it.
