# Tool tiers

For each operation, use the best tier your environment supports. The columns denote **availability, not rank**: Tier 1 is the universal baseline that always works, Tier 2 an alternative to use when present, Tier 3 a fallback for when Tier 1 isn't available. Feature-detect; never assume a tier exists.

**Waiting is deliberately not in this table.** For the wait step, preference runs *inverse* to availability — the always-available single-pass hand-back is the *least* preferred, while the less-available event-driven subscription is the *most* preferred — so it doesn't fit the universal/when-available/fallback model. It has its own **capability ladder** below.

| Operation | Tier 1 (universal) | Tier 2 (when available) | Tier 3 (fallback) |
|---|---|---|---|
| Find PR for current branch | `gh pr list --head "$(git branch --show-current)" --json number,title,url` (quote the substitution — empty on detached HEAD, and unquoted it lets `--json` be swallowed as the `--head` value) | github MCP `list_pull_requests` | — |
| Get reviews / requested reviewers / decision | `gh pr view <num> --json reviews,reviewRequests,latestReviews,reviewDecision,comments` (note: `reviewRequests` filters bots out — for bot detection use the GraphQL form, see SKILL.md iteration-1 prelude) | github MCP `get_pull_request`, `list_pull_request_reviews` | — |
| Get unresolved review threads with `isResolved` | GraphQL via `gh api graphql` (paginated — see `reference/graphql.md`) | github MCP `get_pull_request_review_threads` if it exposes resolution state | — |
| Get inline + file-level comments per review | REST: `gh api repos/{o}/{r}/pulls/{n}/reviews/{id}/comments` | github MCP `get_pull_request_review_comments` | — |
| Get bot-authored PR issue comments (verdict surface) | `gh pr view <num> --json comments` (author + body + timestamp; or the GraphQL `comments` connection — see `reference/graphql.md`) | github MCP `get_pull_request` | — |
| Re-request Copilot review | `gh pr edit <num> --add-reviewer @copilot` (gh ≥ 2.85) | github MCP `request_copilot_review` | GraphQL `requestReviews` with `botIds` (gh < 2.85 only — see `reference/bot-triggers.md`) |
| Trigger Codex review | `gh pr comment <num> --body "@codex review"` (no leading slash, so no shell mangling) | — | `gh pr comment <num> --body-file <path>` with `@codex review` in the file, or REST via `gh api repos/{o}/{r}/issues/{n}/comments -X POST -f body="@codex review"` — see `reference/bot-triggers.md` |
| Reply to a review thread | GraphQL `addPullRequestReviewThreadReply` | github MCP equivalent | — |
| Resolve a review thread | GraphQL `resolveReviewThread` | github MCP equivalent | — |
| Update PR description | `gh pr edit <num> --body-file <path>` | github MCP `update_pull_request` | — |
| Create scope-creep issue | `gh issue create --title ... --body-file <path> --label follow-up-from-pr-review-loop` | github MCP `create_issue` | — |
| Push commits | `git push` | — | — |
| Build verification | Project-detected build tool | — | — |

(For **waiting**, see the capability ladder below — it intentionally isn't a row here.)

Defer to host tool primitives for committing (Claude Code `commit-commands:commit` skill if installed; otherwise plain `git commit`) and loop scheduling.

## Wait capability ladder (highest available wins)

The "wait" step is the one operation whose best tier is environment-specific, so it gets its own ladder. **Feature-detect and use the highest tier present.** Full mechanics in `reference/waiting.md`.

1. **Event-driven (preferred).** If the environment exposes a PR-activity subscription — e.g. GitHub-integrated Claude Code on the web, where `subscribe_pr_activity` / `unsubscribe_pr_activity` deliver `<github-webhook-activity>` wake events (review submitted, CI status change, new comment) — subscribe to the PR, **end the turn**, and let the event re-wake the session. No polling. This is the cloud default. It is a *harness capability*, not a guaranteed skill feature: detect it, don't assume it.
2. **Time-based scheduling.** Where a scheduling primitive exists but no event stream, use it at `wait_check_cadence_seconds` cadence (`/loop <cadence>`, `ScheduleWakeup`, `CronCreate`).
3. **Single pass + hand-back (floor).** If **neither** an event subscription **nor** a scheduling primitive is detectable, do **one** review pass, then stop with a clear "re-invoke `/pr-review-loop` to continue" note. **Never** busy-wait with `sleep` for external events — it doesn't work and burns the turn.

Because the loop may be re-entered across wakeups (tier 1) or invocations (tier 3) rather than run as one continuous process, every wake must be **idempotent**: re-pull, re-derive where you are from the PR (the iteration-1 branching does exactly this), act, re-subscribe or re-schedule, yield. Never hold loop-critical state only in turn-local memory.
