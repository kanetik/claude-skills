# GraphQL & REST queries

Requires `gh` (authenticated) and, for the bash forms, `jq`. PowerShell forms use `ConvertFrom-Json` and need no `jq`. `gh api graphql` is identical on every platform; only the surrounding loop/JSON handling differs by shell.

## Paginated `reviewThreads` query

GitHub's GraphQL `reviewThreads` connection returns up to 100 nodes per page. **Always paginate until `pageInfo.hasNextPage` is `false`** — large PRs can have 100+ threads. Threads cover both inline comments (anchored to a line) AND file-level comments (`path` set, `line: null`) — both appear here.

Use `comments(last: 100)` (the GraphQL max, oriented toward recent context — human replies and recent steering), not `comments(last: 1)`. For threads with >100 comments, paginate; in practice vanishingly rare.

The query itself (shell-agnostic):

```graphql
query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          path
          line
          comments(last: 100) {
            nodes { databaseId body author { login } createdAt }
          }
        }
      }
    }
  }
}
```

**Bash / Git Bash:**

```bash
cursor=null
while :; do
  args=(-F owner=<owner> -F repo=<repo> -F number=<num>)
  [ "$cursor" = "null" ] || args+=(-F cursor="$cursor")
  if ! page=$(gh api graphql "${args[@]}" -f query='<the query above>'); then
    echo "GraphQL page fetch failed — aborting pagination" >&2; break
  fi
  # accumulate nodes from $page here
  has_next=$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
  [ "$has_next" = "true" ] || break
  cursor=$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done
```

**PowerShell (no `jq`):**

```powershell
$cursor = $null
do {
  $cursorArgs = if ($cursor) { @('-F', "cursor=$cursor") } else { @() }
  $page = gh api graphql -F owner=<owner> -F repo=<repo> -F number=<num> @cursorArgs -f query='<the query above>' | ConvertFrom-Json
  # accumulate $page.data.repository.pullRequest.reviewThreads.nodes here
  $info = $null
  $threads = $page.data.repository.pullRequest.reviewThreads
  if ($threads) { $info = $threads.pageInfo; $cursor = $info.endCursor }
} while ($info -and $info.hasNextPage)
```

## Other GraphQL the loop needs

- **Reviews with state, body, comment count, author type** (`__typename: Bot` identifies bot reviewers — the tracked-bots set is dynamic):
  `reviews(last:100){nodes{author{login __typename} state body submittedAt comments{totalCount}}}`
- **`reviewRequests` including bots** — use GraphQL, NOT `gh pr view --json reviewRequests` (which filters bots out):
  `reviewRequests(first:10){nodes{requestedReviewer{__typename ... on Bot{login}}}}`
- **Most recent push timestamp** — latest of `HeadRefPushedEvent.createdAt` and `HeadRefForcePushedEvent.createdAt` from the PR timeline (force-pushes count as pushes for staleness). NOT `committedDate`, which can predate the push.
- **`ReviewRequestedEvent.createdAt`** filtered to Copilot — only for externally-managed PRs where the loop doesn't own push→request ordering (rare); step 2's per-bot "has started" check needs it for the at-or-after evaluation.

## Reply to / resolve a thread

```graphql
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) { comment { id } }
}
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
}
```

## Softening the `jq` dependency

Where you only need a scalar out of a `gh api` call, prefer `gh`'s built-in `--jq` (uses gh's embedded jq engine — no separate `jq` binary) or `--template`, e.g.:

```bash
gh api graphql -F owner=<o> -F repo=<r> -F number=<n> -f query='...' \
  --jq '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage'
```

This runs identically on Windows and Unix and avoids requiring a standalone `jq` for simple extractions. Reserve full `jq`/`ConvertFrom-Json` for accumulating node lists across pages.
