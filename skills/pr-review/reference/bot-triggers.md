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

## Gemini

`requestReviews` with Gemini's bot ID silently no-ops. Trigger via a PR comment whose body is **exactly** `/gemini review` — treat it as a slash command, not a path. Anything else (e.g. `C:/Program Files/Git/gemini review`) does NOT trigger Gemini; it just sits on the PR as noise.

> ⚠️ **DO NOT** run `gh pr comment <num> --body "/gemini review"` from Git Bash / MSYS / MINGW. The shell rewrites the leading `/` into a Windows path BEFORE `gh` sees it. This is the #1 way this step goes wrong.

**Use `--body-file` by default — it sidesteps the mangling entirely:**

```bash
# Bash / Git Bash. /tmp exists in Git Bash; elsewhere use $TMPDIR.
echo '/gemini review' > /tmp/gemini-trigger-<num>.txt
gh pr comment <num> --body-file /tmp/gemini-trigger-<num>.txt
```

```powershell
# PowerShell (Windows). PowerShell does NOT mangle leading slashes, but --body-file is still the most robust form.
'/gemini review' | Out-File -Encoding ascii -NoNewline "$env:TEMP\gemini-trigger-<num>.txt"
gh pr comment <num> --body-file "$env:TEMP\gemini-trigger-<num>.txt"
```

**Inline fallbacks** (only if you can't write a temp file):

```bash
# Bash: suppress MSYS path conversion for this one call.
MSYS_NO_PATHCONV=1 gh pr comment <num> --body "/gemini review"
```

```powershell
# PowerShell: pass via env var through the REST API.
$env:BODY = '/gemini review'
gh api repos/<owner>/<repo>/issues/<num>/comments -X POST -f body="$env:BODY"
```

**Mandatory verify-and-fix.** After posting, immediately run:

```bash
gh pr view <num> --json comments --jq '.comments[-1].body'
```

The last comment body MUST be exactly `/gemini review` — no path prefix, no quotes, no trailing whitespace. If it shows the mangled form or anything else, the trigger did NOT fire. Delete the bad comment (`gh api -X DELETE repos/<owner>/<repo>/issues/comments/<comment_id>`, ID from `gh pr view <num> --json comments`) and re-post via `--body-file`. Do not proceed to the wait until verify shows the exact string.

## Mentions in replies

Tag the reviewer when a reply needs a response from them — `@copilot` for Copilot, `@gemini-code-assist` for Gemini. If Gemini doesn't engage with a mention, the comment is still posted; treat as un-tagged.
