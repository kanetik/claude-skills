# Configuration & override model

The loop is governed by four config keys, plus natural-language invocation modifiers and project-level *procedural* overrides. This file is the full model; `config/defaults.yml` holds the shipped values.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `request_on_pr_open` | `[copilot]` | Bots to manually request when a PR is opened. Only controls who gets pinged on PR creation — bot *engagement* is not gated by this (see tracked-bots below). |
| `auto_review_grace_seconds` | `0` | After a push, wait this long for an auto-trigger to land before manually requesting. `0` = no wait (correct when nothing auto-triggers). Bump to ~60 where a Ruleset auto-requests Copilot, or to give Codex's auto-review on PR open time to start. |
| `wait_check_cadence_seconds` | `240` | How often to check during a **time-based** wait. Stay in 180-270s: that band stays inside the 5-minute prompt-cache window (each wake is cheap), and >300s incurs a full context replay per wake. Does not apply to event-driven waits (those are push, not poll). |
| `max_iterations` | `10` | Iteration cap before pausing to ask the user. Waiting does NOT count toward it. |

## Config precedence (low → high)

```
bundled defaults  <  ~/.claude/pr-review.config.yml (optional)  <  <orchestrator-repo>/.github/pr-review.config.yml (project)
```

- **Bundled defaults** (`config/defaults.yml`) are always present — the baseline that makes the skill self-sufficient with zero external config.
- **User-level** `~/.claude/pr-review.config.yml` is optional and additive. Read it *if it exists*; it simply won't exist in a cloud session, which is fine. Never require it.
- **Project** `.github/pr-review.config.yml` in the orchestrator repo (the current working directory's repo — see SKILL.md "Preconditions") wins. The merged config applies to ALL PRs in the run, including cross-repo PRs.
- **Merge is per-key, not whole-file replace.** A project file that sets only `max_iterations` inherits the other three keys from the layer(s) below.

The orchestrator repo is the current working directory's repo. Cross-repo PRs in the same run still use the orchestrator repo's merged config — they don't pull config from their own repos.

`request_on_pr_open` only controls who gets pinged on PR creation. **Bot engagement itself is NOT config-gated** — any bot that posts a review on the PR gets evaluated, tracked, and re-requested after subsequent pushes (the tracked-bots model in SKILL.md step 2). The grace window handles auto-triggering bots (Codex's auto-review on PR open, when enabled in Codex settings; Rulesets that auto-request Copilot): wait briefly, skip the manual request when the bot already started.

## Invocation modifiers — natural language, not flags

Parse intent from the invocation; don't require precise syntax:

- "no iteration cap" / "until done" / "no max" / "no limit" → disable `max_iterations`.
- "only copilot" / "without codex" / "skip codex" / "just copilot" → override `request_on_pr_open` for this run. Note: this only changes who gets pinged on PR open; bots that show up anyway via auto-trigger or installation still get engaged with (tracked-bots model).
- A PR number, URL, or cross-repo reference → target specific PR(s) instead of auto-detecting from the current branch.

Build command is not configured — detect the project's standard verify command at the commit step.

## Project-level *procedural* overrides (separate from config)

Config (above) is one mechanism. Project *procedural* instructions are a second, complementary one. If the orchestrator repo has its own PR-review instructions and they **contradict** this skill, defer to the project — assume the override is intentional. Sources to check:

- `./.github/PR_REVIEW_LOOP.md`
- `./CLAUDE.md` (PR-review section)
- `./AGENTS.md` (PR-review section)
- `./.cursorrules`
- `./.claude/commands/pr-review-loop.md` / `./.claude/skills/pr-review-loop/`

Classify each difference:

- **Contradiction** = procedural disagreement (different reply templates, escalation rules, evaluation rubric, resolve criteria). **Project wins.**
- **Addition** = non-contradicting delta (project-specific build command, an extra lint rule, a preferred reply style for one case). **Apply both** — this skill's baseline plus the project delta. (Bot selection is config, not a procedural addition.)
- **Unclear** = can't tell whether the project intends to override or just hasn't been updated. **Ask the user** before proceeding; don't silently pick.
