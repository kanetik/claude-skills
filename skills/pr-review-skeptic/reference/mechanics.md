# Mechanics

`gh` incantations for the steps in `SKILL.md`. `<num>`, `<owner>`, `<repo>`, `<tmp>` are placeholders. Add `--repo <owner>/<repo>` to every call when the PR is not in the working directory's repo.

## Resolve the PR

```bash
branch=$(git branch --show-current)
gh pr list --head "$branch" --json number,title,url        # named branch
gh pr list --search "$(git rev-parse HEAD)" --json number,title,url   # detached HEAD
```

Zero matches and no PR named in the invocation → say so and stop; this skill reviews a PR and there isn't one. Multiple → ask which.

## Scope the change

```bash
gh pr view <num> --json number,title,headRefOid,baseRefName,files
git fetch origin "<baseRefName>" "pull/<num>/head"        # the head is not local for a fork, or for any PR you didn't open here
BASE=$(git merge-base origin/<baseRefName> <headRefOid>)
git cat-file -e "<headRefOid>^{commit}"                   # both shas must resolve before a reviewer diffs them
```

`files[].path` is the change's file list — the input to partitioning. `BASE` and `headRefOid` are the `{{BASE}}` and `{{HEAD}}` slots; reviewers diff with `git diff $BASE...<head>`.

Staging the checkout (`SKILL.md` stage 1) where the current tree isn't already at the head:

```bash
git worktree add <tmp>/pr-<num> <headRefOid>       # review here
git worktree remove <tmp>/pr-<num>                 # when the run ends
```

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

```bash
cat > <tmp>/review.json <<'JSON'
{
  "commit_id": "<head-sha>",
  "event": "COMMENT",
  "body": "<summary body: verdict, coverage, observations, settled>",
  "comments": [
    { "path": "data/sync/Merge.kt", "line": 118, "side": "RIGHT",
      "body": "**CRITICAL** — Local edits are dropped when...\n\n**Consequence:** ...\n\n**Fix:** ..." }
  ]
}
JSON
gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input <tmp>/review.json
```

PowerShell, where a heredoc is a parse error:

```powershell
@{ commit_id = '<head-sha>'; event = 'COMMENT'; body = $summary
   comments = @(@{ path = 'data/sync/Merge.kt'; line = 118; side = 'RIGHT'; body = $comment })
} | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 <tmp>/review.json
gh api repos/<owner>/<repo>/pulls/<num>/reviews --method POST --input <tmp>/review.json
```

`event` is always `COMMENT`. `APPROVE` would let this review satisfy branch protection and admit a merge on an agent's judgement, which is not a call this skill makes; the verdict goes in the body where a person reads it and decides.

**Anchoring.** `line` must be a line the diff touches at `commit_id`, or the API rejects the whole payload with 422 — one bad anchor loses every comment in the call, summary body included. So any finding you cannot anchor with confidence goes in the **summary body** under a heading naming its path. That costs a little prominence and always works.

`subject_type: file` attaches a comment to a whole file, but it is a property of the standalone comment endpoint, not of the `comments[]` array in a review — sending it here is another 422 on the same all-or-nothing call. Where a file-level comment is worth a second request, post it after the review lands:

```bash
gh api repos/<owner>/<repo>/pulls/<num>/comments --method POST \
  -f commit_id=<head-sha> -f path=<path> -f subject_type=file -f body=<text>
```

Findings on code the PR did not touch cannot anchor anywhere. They belong in the body, under a heading that names the file — a defect in code the change depends on is still worth reporting, and it is worth saying that the change is what surfaced it.
