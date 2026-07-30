# Mechanics — tool tiers, queries, bot triggers

Requires `gh` (authenticated). Bash forms also use `jq`; PowerShell forms use `ConvertFrom-Json` and need no `jq`. `gh api graphql` is identical on every platform.

## Tool tiers

For each operation use the best tier your environment supports. Columns denote **availability, not rank**: Tier 1 is the universal baseline, Tier 2 an alternative when present, Tier 3 a fallback. Feature-detect; never assume a tier exists. (The **wait** step is the exception — it has its own timer-based polling model in `reference/waiting.md`, not a row here.)

| Operation | Tier 1 (universal) | Tier 2 (when available) | Tier 3 (fallback) |
|---|---|---|---|
| Find PR for current branch | `gh pr list --head "$(git branch --show-current)" --json number,title,url` (quote the substitution; on detached HEAD it's empty — don't run `--head ""`, use the commit-search fallback in SKILL.md "Preconditions": `gh pr list --search "$(git rev-parse HEAD)"`) | github MCP `list_pull_requests` | — |
| Get reviews / requested reviewers / decision | `gh pr view <num> --json reviews,reviewRequests,latestReviews,reviewDecision,comments` (`reviewRequests` drops bots — use the GraphQL form below for bot detection) | github MCP `get_pull_request`, `list_pull_request_reviews` | — |
| Unresolved review threads with `isResolved` | GraphQL via `gh api graphql` (paginated — below) | github MCP `get_pull_request_review_threads` if it exposes resolution state | — |
| Inline + file-level comments per review | REST `gh api repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` | github MCP `get_pull_request_review_comments` | — |
| PR issue comments (verdict surface, and the loop's own disposition records) | Paginated GraphQL `comments` connection (below) — carries `author.__typename` and numeric `databaseId`, both needed | github MCP `get_pull_request` | `gh pr view <num> --json comments` as a **non-authoritative** read only — no pagination, omits `__typename` and numeric `databaseId` |
| Re-request Copilot review | `gh pr edit <num> --add-reviewer @copilot` (gh ≥ 2.85) | github MCP `request_copilot_review` | GraphQL `requestReviews` with `botIds` (gh < 2.85 — below) |
| Trigger Codex review | `gh pr comment <num> --body "@codex review"` | — | `--body-file <path>`, or REST `gh api repos/{o}/{r}/issues/{n}/comments -X POST -f body="@codex review"` (below) |
| Engage the skeptic reviewer | Invoke the `pr-review-skeptic` skill (below) — no `gh` call, no wait; it posts its own review | — | None. Absent the skill it can't run; pause and ask |
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

- **Reviews with state, body, comment count, author type.** `__typename: Bot` identifies bot reviewers; **the body is not optional here**, because a review authored by a `User` carrying the marker line `<!-- pr-review-skeptic -->` is the skeptic reviewer, not a human. Classify on the marker first, author type second — a query that reads `__typename` and drops `body` cannot tell them apart, and the loop then skips its own reviewer as human participation:
  `reviews(last:100){nodes{author{login __typename} state body submittedAt comments{totalCount}}}`
- **PR issue comments** (the third reviewer-state surface — some bots post findings or their whole clean verdict here, never as a `Review`; the loop's own threadless-finding dispositions also live here). Drive with the **same cursor loop** as `reviewThreads`; page the full connection (or filter by `author`) since a verdict can be buried by later discussion. Use this `databaseId` for reactions/edits — `gh pr view --json comments` returns node IDs (`IC_…`), not the numeric ID:
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

**Verify (Tier 1/2):** `reviewRequests` must show `Bot:copilot-pull-request-reviewer`. Query it by dropping the `reviewRequests` field from "Other queries the loop needs" (above) into a `gh api graphql` call:

```bash
gh api graphql -F owner=<owner> -F repo=<repo> -F number=<num> -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewRequests(first:10){nodes{requestedReviewer{__typename ... on Bot{login}}}}}}}'
```

(`gh pr view --json reviewRequests` drops bots, so it can't confirm this.)

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

## The skeptic reviewer — a local skill that posts to the PR

`skeptic` in `reviewers` means the sibling **`pr-review-skeptic`** skill. Half the machinery above doesn't apply to it — nothing is requested, nothing is triggered, nothing is polled — but its output lands in exactly the same place a bot's does: a review on the PR, with a thread per finding. Everything downstream of that (step 5 evaluation, replies, resolution, step 4 convergence) is identical.

### Pre-flight (SKILL.md Preconditions)

Run once at kickoff whenever `skeptic` is in `reviewers`. Three checks, all cheap, all needed before the first round.

1. **Is the skill installed?** A `pr-review-skeptic` entry in the skills available to you is the answer — that listing covers every install layout (user-level, project-level, plugin bundle) without your having to know which one this environment uses. Don't go looking for it at a fixed path. Absent from the listing → pause.
2. **Are its five project keys filled?** They come from that skill's own config, merged low → high: its bundled `config/defaults.yml` (all five empty by design) < `~/.claude/pr-review-skeptic.config.yml` < the **PR repo's** `.github/pr-review-skeptic.config.yml`, read from the PR's **base** ref:

```bash
gh api -H "Accept: application/vnd.github.raw" \
  "repos/<owner>/<repo>/contents/.github/pr-review-skeptic.config.yml?ref=<base-branch>" 2>/dev/null
```

The raw `Accept` header returns the file's bytes directly. Don't take the default JSON response and decode `.content` yourself — that needs a `base64` whose decode flag differs across platforms (`-d` GNU, `-D` BSD), for a step that has a portable form.

Non-empty `project`, `users`, `irreplaceable_data`, `production_status`, `architecture` after the merge → good. Any still empty → there is one more place to look, but **resolve it exactly the way the skeptic skill does rather than restating its rule**, or the two drift and the pre-flight passes a run that skill will then stop. Its order is: read layer 3 from the base ref; **only where the base ref has no such file at all** fall back to an uncommitted copy in the PR repo's working tree, and then only when that copy is not part of the change (`git -C "$REPO" cat-file -e "<head-sha>:.github/pr-review-skeptic.config.yml"` must *fail*).

Both conditions matter, and the first is the one easy to drop. A repo that committed the file to set only `max_reviewers` — leaving the project keys empty, which is a legitimate thing to do and the case that skill appends interviewed keys to the working copy for — *has* a file at the base ref, so its file-level fallback never fires. Treat a filled working-tree copy as satisfying the check only in the case that skill would: no file at base. Otherwise the loop proceeds, the skeptic run reads the base-ref file, still finds the keys empty, and tears down with "config is required" — a wasted staging round and a stop that reads as a failure, which is the whole thing this pre-flight exists to prevent.

Where the fallback does apply, proceed and say the config is uncommitted, so it covers this run only. Still empty → pause. This check exists because an **agent-invoked** skeptic run does not interview for missing keys — it tears down and hands back what's missing. Discovering that inside the first round wastes a staging round and reads like a failure rather than a setup step.

3. **Will an agent-invoked run actually post?** Two keys decide it, and both must be right — checking only the first is the commonest way this pre-flight passes on a setup that cannot work:
   - `allow_agent_posting: true`, which counts **only** from the committed project file at the base ref (a user-level copy does not grant it, by that skill's own rule). That is why the one `gh api` call above answers checks 2 and 3 together.
   - `confirm_before_posting` must not be `true`. Unlike the grant, this key **merges normally across all three layers**, so read the merged value — including `~/.claude/pr-review-skeptic.config.yml`, which the base-ref call above does not cover. `true` turns an agent-invoked run into a no-post, so it silently cancels the grant. It is a perfectly reasonable thing for someone to have set for their own hand-run previews, and a repo can equally commit both keys thinking they are independent.

   Either one wrong produces the identical symptom, so name which when you pause. Diagnosing this as `allow_agent_posting` when the real cause is `confirm_before_posting` sends the user to verify a key that is already correct.

Read the base ref, not the working tree and not the PR head: that is the ref the skeptic skill itself reads, and a config the PR *adds* is a change under review describing the project to its own reviewers — or, for the posting key, granting itself permission to publish. For the five project keys, a file sitting uncommitted in the working tree does satisfy that skill (it falls back to the working copy when the file isn't part of the change), but only from a lasting checkout, so treat it as covering this run rather than as configured-for-good. For `allow_agent_posting` there is no such fallback: uncommitted is not granted.

**Why check 3 is not a nicety.** Without it the skill still runs, still reviews, and still hands you a full verdict — and posts nothing. Every consequence is downstream and silent: no threads to reply to, so no disposition is recorded anywhere; no thread history, so its own next run's cross-check has nothing to bucket against and every finding you already answered comes back `new`; no severity escalation for a defect a fix round missed, since that bucket needs the prior thread. The loop then re-litigates the same findings every round until `max_iterations`. Report the missing key at kickoff, and if the user wants to run anyway, say that is what the run will look like.

### Invoking it

Invoke the `pr-review-skeptic` skill with the PR reference and nothing more — `#<num>`, a URL, or `<owner>/<repo>#<num>` for a cross-repo PR. Then follow that skill's procedure as written, in particular its **Context discipline** section: the reviewer brief is filled by substitution from project config and the diff, and no summary of the change, its purpose, or its rationale goes into it or into any answer to a reviewer's question. You are the worst-placed caller for that rule — you may have written the code, and by round five you are also carrying every finding the earlier rounds settled — which is exactly why it's a hard guardrail there.

Two of that skill's rules matter to you as caller and are not yours to override:

- **Whether it posts is the repo's answer, not yours.** Don't instruct it to post and don't instruct it not to; it reads `allow_agent_posting` from the committed project config and acts on that. An earlier version of this skill told you to suppress posting — that instruction is retired, and a caller still following it would silence the reviewer this loop is built around.
- **It cleans up after itself.** It stages a worktree at the PR head and tears it down on every exit, including its stops. Your own checkout is untouched, so a round needs no preparation from you beyond a clean tree.

### Reading what comes back

Two channels, and use both. The skill **returns** a verdict, the findings with severities and buckets (`new` / `unfixed` / `re-raised` / `settled`), a coverage line, and where each finding was placed. It also **posts** that review, so the findings are on the PR as threads. Evaluate from the threads — they are what you reply to and resolve — and use the returned copy as the convenient in-turn source for the rest.

Both of the things you most need from the returned copy are also **recoverable from the PR**, and it matters that you know that, because a context-less wake has only the PR: the posted summary body carries the coverage line and the findings that got no thread, under their own heading. So a wake can reconstruct the whole round without the return value — read the marker-carrying review body.

Findings placed in that body rather than on a thread (a deleted path, code the change never touched) are yours to disposition in the PR-level comment described in `reference/evaluation.md`. Nothing else records them, and a finding with no record comes back every round.

Failure modes, and what each means:

| What comes back | Reading |
|---|---|
| A verdict with findings, or a clean verdict, posted to the PR | Normal. Triage from the threads and proceed. |
| A verdict, but nothing posted | One of check 3's two keys — `allow_agent_posting` absent from the committed project file, or `confirm_before_posting: true` in any layer. Re-read both before naming one; they produce the same symptom and the second is the one a pre-flight that checked only the grant will have missed. Not a reviewer this loop can converge — say so and ask whether to fix the config, drop `skeptic`, or proceed knowing rounds won't accumulate. |
| "Config is required", listing missing project keys | Pre-flight missed it (a user-level config that turned out empty, say). Pause as in Preconditions. |
| No unit reviewed — subagent tool unavailable, rate-limited, erroring | **Not a clean round.** It is a whole-session condition, so it hits every unit at once. Say so and ask the user whether to retry, use a bot, or proceed without it. "Proceed without it" means **excused for the run** (SKILL.md step 4) — drop it from `active`. Leaving it in place is not proceeding: with no verdict at/after the push and no stickiness to drop it, it can never be happy, so the loop runs to the cap over a reviewer that never ran. Where it is the only reviewer, say that proceeding means nothing will have reviewed this HEAD, so the run cannot come back converged. |
| A clean verdict qualified by unreviewed units, or a cross-check that didn't run | Counts as happy over what was covered. Carry the qualification into what you tell the user, verbatim in substance, and into the final summary. |
| No PR found, or an empty diff | Something is wrong with the target, not with the change. Surface it; don't treat it as a pass. |

The one reading to avoid: a run that produced no review is not the same as a run that found nothing. Both are quiet.

### Mentions in replies

@-mention a bot in a reply only when the mention reaches the reviewing bot AND it acts on mentions. `@codex` does — lead Codex replies with it. Copilot's reviewer (`copilot-pull-request-reviewer`) does **not** act on reply mentions, and `@copilot` routes to a different bot (`copilot-swe-agent`) which misfires — reply to Copilot **without** a mention. For a new bot, mention only if you know its handle reaches the reviewer; if unsure, post unmentioned.

**Never mention on a skeptic thread.** There is no account behind it to notify — the review posted under the user's own — so a mention either does nothing or pings the user about their own thread. Its next run reads the reply as text, from the thread; that is the whole channel. Write for that reader: state the disposition and the reasoning in the reply itself rather than pointing at a commit, since a bare "fixed in abc123" gives the cross-check nothing to match a re-found finding against.
