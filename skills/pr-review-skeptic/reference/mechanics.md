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
git fetch origin <baseRefName>
BASE=$(git merge-base origin/<baseRefName> <headRefOid>)
```

`files[].path` is the change's file list — the input to partitioning. `BASE` and `headRefOid` are the `{{BASE}}` and `{{HEAD}}` slots; reviewers diff with `git diff $BASE...<head>`.

## CI status

```bash
gh pr checks <num>                                          # human-readable, non-zero exit on failure
gh pr view <num> --json statusCheckRollup                   # structured
```

Fills `{{CI}}`: the failing check names and what they report, or that everything passes. No checks configured → "no CI configured", and the reviewer judges tests by reading alone.

## Prior review history

For the cross-check stage only.

```bash
gh pr view <num> --json body,reviews,comments
```

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

`event` is always `COMMENT`. `APPROVE` would let this review satisfy branch protection and admit a merge on an agent's judgement, which is not a call this skill makes; the verdict goes in the body where a person reads it and decides.

**Anchoring.** `line` must be a line the diff touches at `commit_id`, or the API rejects the whole payload with 422 — one bad anchor loses every comment in the call. Two ways through: attach the comment to the file instead, by dropping `line`/`side` and passing `"subject_type": "file"`; or move it into the summary body under its path. Prefer the file-level form, then the body.

Findings on code the PR did not touch cannot anchor anywhere. They belong in the body, under a heading that names the file — a defect in code the change depends on is still worth reporting, and it is worth saying that the change is what surfaced it.
