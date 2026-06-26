# Configuration & override model

The loop is governed by seven config keys, plus natural-language invocation modifiers and project-level *procedural* overrides. `config/defaults.yml` holds the shipped values; this file is the full model.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `upfront_gate_reviewers` | `[]` | Adversarial bots run as a gate **before** the loop (SKILL.md Phase 0). The review runs to **completion**: actionable-clear (any size) → fix and re-request the same bot(s), repeating to clean with no cap; actionable-unclear → pause and ask the user. Not satisfied until **every** gate bot is clean/all-deferred at/after the final gate change. `[]` = no gate. Runs only on a **fresh** PR — an initial bot auto-review doesn't suppress it; skipped only on a genuinely mid-flight PR. Typically a rate-limited deep reviewer, catching a wrong-from-the-start approach before Copilot polishes it. |
| `request_on_pr_open` | `[copilot]` | Bots to manually request on the first pass (iteration 1). Controls who gets pinged then — bot *evaluation* is not gated by this (see below). |
| `loop_reviewers` | `[copilot]` | Bots re-requested on every push (the convergence drivers; SKILL.md step 8). A bot in `request_on_pr_open` but **not** here is **first-pass-only**: requested once, findings triaged like any other, then never re-requested and not gating convergence. |
| `final_gate_reviewers` | `[]` | Bots requested **once** after convergence, as a final **sanity check** (SKILL.md step 10) — a confirming look, not an adversarial dig. Non-deferred findings → fix, re-converge `loop_reviewers`, re-run once. `[]` = no check. Often the same deep reviewer as the upfront gate, to catch what the fix rounds introduced. |
| `auto_review_grace_seconds` | `0` | After a push, wait this long for an auto-trigger to land before manually requesting. `0` = no wait. Bump to ~60 where a Ruleset auto-requests Copilot, or to give Codex's auto-review time to start. |
| `wait_check_cadence_seconds` | `180` | Polling cadence for the wait (SKILL.md step 3, `reference/waiting.md`). Stay in 120-240s (every 2-4 min): frequent enough to react promptly, and ≤270s keeps each wake inside the 5-minute prompt-cache window (each wake cheap); >300s incurs a full context replay per wake. |
| `max_iterations` | `10` | Iteration cap before pausing to ask the user. Waiting does NOT count toward it. |

## Precedence (low → high)

```
bundled defaults  <  ~/.claude/pr-review-loop.config.yml (optional)  <  <orchestrator-repo>/.github/pr-review-loop.config.yml (project)
```

Bundled defaults are always present (the self-sufficient baseline). User-level is optional and additive — read it *if it exists*; if it doesn't, that's fine, never require it. Project `.github/pr-review-loop.config.yml` in the orchestrator repo (the working directory's repo) wins. **Merge is per-key**, not whole-file replace — a project file setting only `max_iterations` inherits the rest from below. The merged config applies to ALL PRs in the run, including cross-repo ones (they don't pull config from their own repos).

**Gate vs `request_on_pr_open` for a deep reviewer.** Both put a bot in front of a fresh PR, but differ in structure. `request_on_pr_open` batches its first-pass findings into iteration 1 alongside the loop reviewers — one combined evaluation, then the loop runs. `upfront_gate_reviewers` makes it a **distinct phase that must complete first** (actionable-clear re-runs to clean, actionable-unclear pauses for the user) before any loop reviewer is requested. Use the gate when "is this approach even right?" should be answered before polish; use `request_on_pr_open` when the catches can be handled inline. Don't list the same bot in both (the gate already covers the first look).

**Evaluation is NOT config-gated.** Any bot that posts a review, or a review-style verdict comment (judged on content, not CI/noise), is evaluated and tracked. What *is* config-gated is **re-requesting**: only `loop_reviewers` are re-pinged after later pushes. A bot's verdict may arrive as a formal review *or* a plain issue comment (some bots only comment when happy — Codex posts a review with findings, an issue comment when clean); the loop reads both and **judges disposition from what was written** (SKILL.md "Reading reviewer state"). There is deliberately **no per-bot verdict-phrase configuration** — a phrase list would break on the next bot.

## Invocation modifiers — natural language, not flags

Parse intent; don't require precise syntax:

- "no iteration cap" / "until done" / "no max" → disable `max_iterations`.
- "only copilot" / "without codex" / "skip codex" → override `request_on_pr_open` (and the gate/loop/final lists) to drop the excluded bot for this run. Only changes who the loop *requests*; a bot that shows up via auto-trigger is still evaluated.
- "codex first pass only" / "adversarial codex" → the rate-limited-deep-reviewer bookend: `upfront_gate_reviewers: [codex]`, `request_on_pr_open: [copilot]`, `loop_reviewers: [copilot]`, `final_gate_reviewers: [codex]` (set `request_on_pr_open` explicitly so Codex is dropped from the first pass — else a project config listing Codex there would gate *and* re-request it, violating "don't list the same bot in both").
- "gate the design first" / "have codex gate it first" → `upfront_gate_reviewers: [<bot>]` for this run (commonly paired with `final_gate_reviewers: [<bot>]`).
- A PR number, URL, or cross-repo reference → target specific PR(s) instead of auto-detecting.

Build command is not configured — detect the project's verify command at the commit step.

## Project-level *procedural* overrides (separate from config)

If the orchestrator repo has its own PR-review instructions that **contradict** this skill, defer to the project — assume the override is intentional. Check: `./.github/PR_REVIEW_LOOP.md`, `./CLAUDE.md` (PR-review section), `./AGENTS.md` (PR-review section), `./.cursorrules`, `./.claude/commands/pr-review-loop.md` / `./.claude/skills/pr-review-loop/`. Classify each difference:

- **Contradiction** = procedural disagreement (reply templates, escalation rules, rubric, resolve criteria). **Project wins.**
- **Addition** = non-contradicting delta (project build command, an extra lint rule, a preferred reply style). **Apply both.** (Bot selection is config, not a procedural addition.)
- **Unclear** = can't tell whether it's an intended override or just stale. **Ask the user.**
