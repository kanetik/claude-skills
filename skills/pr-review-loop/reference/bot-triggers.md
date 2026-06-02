# Bot trigger mechanics

How to request/re-request each bot. The per-bot "has it already started reviewing the current commit?" checks live in SKILL.md step 2; this file is the mechanics.

## Copilot

```bash
# Tier 1 (gh ≥ 2.85) — works for first-ever requests too.
gh pr edit <num> --add-reviewer @copilot
```

Tier 2: github MCP `request_copilot_review`.

Tier 3 (gh < 2.85 only) — GraphQL `requestReviews` with `botIds`. **Caveat:** this derives Copilot's bot ID by scanning EXISTING reviews for the `copilot-pull-request-reviewer` login. On a PR where Copilot has never reviewed, the lookup returns empty and `requestReviews` fails. For a fresh first request use Tier 1 or Tier 2. Tier 3 is reliable only for re-requests on PRs where Copilot has already reviewed at least once.

```bash
PR_ID=$(gh api graphql -F owner=<owner> -F repo=<repo> -F number=<num> \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id}}}' \
  --jq '.data.repository.pullRequest.id')
COPILOT_ID=$(gh api graphql -F owner=<owner> -F repo=<repo> -F number=<num> \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviews(last:100){nodes{author{login ... on Bot{id}}}}}}}' \
  --jq '.data.repository.pullRequest.reviews.nodes[] | select(.author.login? == "copilot-pull-request-reviewer") | .author.id' | head -1)
[ -z "$COPILOT_ID" ] && { echo "ERROR: Tier 3 lookup found no Copilot review on this PR. Use Tier 1 (gh ≥ 2.85) or Tier 2 (github MCP) for first-ever Copilot review requests." >&2; exit 1; }
gh api graphql -F prId="$PR_ID" -F botId="$COPILOT_ID" -f query='
mutation($prId: ID!, $botId: ID!) {
  requestReviews(input: {pullRequestId: $prId, botIds: [$botId], union: true}) { clientMutationId }
}'
```

**Verify (Tier 1/2):** `reviewRequests` must show `Bot:copilot-pull-request-reviewer`. Use GraphQL — `gh pr view --json reviewRequests` filters bots out:

```bash
gh api graphql -F owner=<owner> -F repo=<repo> -F number=<num> -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewRequests(first:10){nodes{requestedReviewer{__typename ... on Bot{login}}}}}}}'
```

## Codex

`requestReviews` with Codex's bot ID silently no-ops. Trigger via a PR comment whose body contains the mention **`@codex review`** — it's a bot mention, not a slash command, so there's no leading-slash path-mangling to worry about (the failure mode that plagues other bots). Codex acknowledges with a 👀 reaction, then posts its review (it flags only P0/P1 issues). You can scope a single request inline — `@codex review for security regressions`, `@codex review for performance bottlenecks` — without changing any permanent setting.

```bash
# Bash / Git Bash. No leading slash, so no MSYS path conversion issue.
gh pr comment <num> --body "@codex review"
```

```powershell
# PowerShell (Windows).
gh pr comment <num> --body "@codex review"
```

If a shell mangles the body for any reason, fall back to `--body-file` (write `@codex review` to a temp file, then `gh pr comment <num> --body-file <path>`, and delete the file) or the REST endpoint (`gh api repos/<owner>/<repo>/issues/<num>/comments -X POST -f body="@codex review"`).

**Verify after posting:**

```bash
gh pr view <num> --json comments --jq '.comments[-1].body?'  # ? guards an empty comments array
```

The last comment body must contain `@codex review`. If it doesn't, the trigger didn't fire — re-post. To delete a stray comment, note that `gh pr view <num> --json comments` returns each comment's **GraphQL node ID** (`IC_…`), not the integer database ID, so delete via the GraphQL mutation (the REST `DELETE …/issues/comments/{id}` endpoint wants the numeric ID and would 404 on a node ID):

```bash
# node ID from: gh pr view <num> --json comments --jq '.comments[-1].id?'
gh api graphql -f id="<node_id>" -f query='mutation($id:ID!){ deleteIssueComment(input:{id:$id}){ clientMutationId } }'
```

## Mentions in replies

Tag the reviewer when a reply needs a response from them — `@copilot` for Copilot, `@codex` for Codex. If Codex doesn't engage with a mention, the comment is still posted; treat as un-tagged.
