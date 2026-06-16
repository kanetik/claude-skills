# Mechanics — tool tiers, queries, bot triggers

Requires `gh` (authenticated). Bash forms also use `jq`; PowerShell forms use `ConvertFrom-Json` and need no `jq`. `gh api graphql` is identical on every platform.

## Tool tiers

For each operation use the best tier your environment supports. Columns denote **availability, not rank**: Tier 1 is the universal baseline, Tier 2 an alternative when present, Tier 3 a fallback. Feature-detect; never assume a tier exists. (The **wait** step is the exception — it has its own poll-plus-events model in `reference/waiting.md`, not a row here.)

| Operation | Tier 1 (universal) | Tier 2 (when available) | Tier 3 (fallback) |
|---|---|---|---|
| Find PR for current branch | `gh pr list --head "$(git branch --show-current)" --json number,title,url` (quote the substitution — empty on detached HEAD) | github MCP `list_pull_requests` | — |
| Get reviews / requested reviewers / decision | `gh pr view <num> --json reviews,reviewRequests,latestReviews,reviewDecision,comments` (`reviewRequests` drops bots — use the GraphQL form below for bot detection) | github MCP `get_pull_request`, `list_pull_request_reviews` | — |
| Unresolved review threads with `isResolved` | GraphQL via `gh api graphql` (paginated — below) | github MCP `get_pull_request_review_threads` if it exposes resolution state | — |
| Inline + file-level comments per review | REST `gh api repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` | github MCP `get_pull_request_review_comments` | — |
| Bot-authored PR issue comments (verdict surface) | Paginated GraphQL `comments` connection (below) — carries `author.__typename` and numeric `databaseId`, both needed | github MCP `get_pull_request` | `gh pr view <num> --json comments` as a **non-authoritative** read only — no pagination, omits `__typename` and numeric `databaseId` |
| Re-request Copilot review | `gh pr edit <num> --add-reviewer @copilot` (gh ≥ 2.85) | github MCP `request_copilot_review` | GraphQL `requestReviews` with `botIds` (gh < 2.85 — below) |
| Trigger Codex review | `gh pr comment <num> --body "@codex review"` | — | `--body-file <path>`, or REST `gh api repos/{o}/{r}/issues/{n}/comments -X POST -f body="@codex review"` (below) |
| Reply to a review thread | GraphQL `addPullRequestReviewThreadReply` | github MCP equivalent | — |
| Resolve a review thread | GraphQL `resolveReviewThread` | github MCP equivalent | — |
| Update PR description | `gh pr edit <num> --body-file <path>` | github MCP `update_pull_request` | — |
| Create scope-creep issue | `gh issue create --title ... --body-file <path> --label follow-up-from-pr-review` | github MCP `create_issue` | — |
| Push commits | `git push` | — | — |

Defer committing to the host (`commit-commands:commit` skill if installed; else plain `git commit`) and loop scheduling to the host scheduler.

## GraphQL & REST queries

### Paginated `reviewThreads`

Returns up to 100 nodes/page — **paginate until `pageInfo.hasNextPage` is false** (large PRs have 100+ threads). Threads cover inline comments AND file-level comments (`path` set, `line: null`). Use `comments(last: 100)` for recent context (human replies, steering).

```graphql
query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved path line
          comments(last: 100) { nodes { databaseId body author { login } createdAt } }
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

### Other queries the loop needs

- **Reviews with state, body, comment count, author type** (`__typename: Bot` identifies bot reviewers):
  `reviews(last:100){nodes{author{login __typename} state body submittedAt comments{totalCount}}}`
- **PR issue comments** (the third reviewer-state surface — some bots post findings or their whole clean verdict here, never as a `Review`). Drive with the **same cursor loop** as `reviewThreads`; page the full connection (or filter by `author`) since a verdict can be buried by later discussion. Use this `databaseId` for reactions/edits — `gh pr view --json comments` returns node IDs (`IC_…`), not the numeric ID:
  `comments(first:100, after:$cursor){ pageInfo{ hasNextPage endCursor } nodes{ databaseId author{login __typename} body createdAt } }`
- **`reviewRequests` including bots** — GraphQL, NOT `gh pr view --json reviewRequests` (which drops bots):
  `reviewRequests(first:10){nodes{requestedReviewer{__typename ... on Bot{login}}}}`
- **Most recent push timestamp** — latest of `HeadRefPushedEvent.createdAt` / `HeadRefForcePushedEvent.createdAt` from the timeline (force-pushes count). NOT `committedDate`.
- **`ReviewRequestedEvent.createdAt`** filtered to Copilot — only for externally-managed PRs where the loop doesn't own push→request ordering; step 2's per-bot "has started" check needs it for the at-or-after comparison.

### Reply to / resolve a thread

```graphql
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) { comment { id } }
}
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
}
```

### Softening the `jq` dependency

Where you need only a scalar, prefer `gh`'s built-in `--jq` (embedded engine, no separate binary) or `--template` — runs identically on Windows and Unix. Reserve full `jq`/`ConvertFrom-Json` for accumulating node lists across pages.

## Bot triggers

### Copilot

```bash
gh pr edit <num> --add-reviewer @copilot   # Tier 1 (gh ≥ 2.85) — works for first-ever requests too.
```

Tier 2: github MCP `request_copilot_review`. Tier 3 (gh < 2.85): GraphQL `requestReviews` with `botIds`. **Caveat:** Tier 3 derives Copilot's bot ID by scanning existing reviews for the `copilot-pull-request-reviewer` login, so it fails on a PR where Copilot has never reviewed — use Tier 1/2 for a first request.

```bash
PR_ID=$(gh api graphql -F owner=<owner> -F repo=<repo> -F number=<num> \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id}}}' \
  --jq '.data.repository.pullRequest.id')
COPILOT_ID=$(gh api graphql -F owner=<owner> -F repo=<repo> -F number=<num> \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviews(last:100){nodes{author{login ... on Bot{id}}}}}}}' \
  --jq '.data.repository.pullRequest.reviews.nodes[] | select(.author.login? == "copilot-pull-request-reviewer") | .author.id' | head -1)
[ -z "$COPILOT_ID" ] && { echo "ERROR: no Copilot review on this PR — use Tier 1/2 for a first request." >&2; exit 1; }
gh api graphql -F prId="$PR_ID" -F botId="$COPILOT_ID" -f query='
mutation($prId: ID!, $botId: ID!) { requestReviews(input: {pullRequestId: $prId, botIds: [$botId], union: true}) { clientMutationId } }'
```

**Verify (Tier 1/2):** `reviewRequests` must show `Bot:copilot-pull-request-reviewer` (use the GraphQL `reviewRequests` query above — `gh pr view --json reviewRequests` drops bots).

### Codex

`requestReviews` with Codex's bot ID silently no-ops. Trigger via a PR comment containing **`@codex review`** (a bot mention, not a slash command — no leading-slash path-mangling). Codex acks with 👀, then posts its review (P0/P1 only). You can scope inline: `@codex review for security regressions`.

```bash
gh pr comment <num> --body "@codex review"
```

If a shell mangles the body, fall back to `--body-file` (write `@codex review` to a temp file, then `gh pr comment <num> --body-file <path>`, delete it) or REST (`gh api repos/{o}/{r}/issues/{n}/comments -X POST -f body="@codex review"`).

**Verify:** `gh pr view <num> --json comments --jq '.comments[-1].body?'` — the last comment must contain `@codex review`; if not, re-post. To delete a stray comment, use the GraphQL mutation (the comment's ID from `gh pr view` is a node ID `IC_…`, which the REST delete endpoint 404s on):

```bash
gh api graphql -f id="<node_id>" -f query='mutation($id:ID!){ deleteIssueComment(input:{id:$id}){ clientMutationId } }'
```

### Mentions in replies

@-mention a bot in a reply only when the mention reaches the reviewing bot AND it acts on mentions. `@codex` does — lead Codex replies with it. Copilot's reviewer (`copilot-pull-request-reviewer`) does **not** act on reply mentions, and `@copilot` routes to a different bot (`copilot-swe-agent`) which misfires — reply to Copilot **without** a mention. For a new bot, mention only if you know its handle reaches the reviewer; if unsure, post unmentioned.
