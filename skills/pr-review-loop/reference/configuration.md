# Configuration & override model

The loop is governed by seven config keys, plus natural-language invocation modifiers and project-level *procedural* overrides. `config/defaults.yml` holds the shipped values; this file is the full model.

The two gate keys accept **either** a bot name **or** `skeptic` (the sibling `pr-review-skeptic` skill, invoked locally — no request, no wait, no PR trace). The other two lists accept bots only: `skeptic` is not a GitHub reviewer, so it cannot be requested on PR open or re-requested by a push. Listing it in `request_on_pr_open` or `loop_reviewers` is a config error — **ignore it in that key** and tell the user, naming the key. Don't silently promote it into a gate: which gate was meant isn't inferable, and a `skeptic` in `loop_reviewers` may equally be a leftover from a config that no longer wants the gates at all. Where a gate key already lists it, that gate runs regardless; the error is only about the key it can't work in. Mechanism differences: SKILL.md "Two kinds of gate reviewer" and `reference/mechanics.md`.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `upfront_gate_reviewers` | `[skeptic]` | The gate **before** the loop (SKILL.md Phase 0). Runs to **completion**: actionable-clear (any size) → fix and re-engage the same reviewer(s), repeating to clean with no cap; actionable-unclear → pause and ask the user. Not satisfied until **every** gate reviewer is clean/all-deferred at/after the final gate change. `[]` = no gate. Runs only on a **fresh** PR — an initial bot auto-review doesn't suppress it; skipped only on a genuinely mid-flight PR. Catches a wrong-from-the-start approach before Copilot polishes it. |
| `request_on_pr_open` | `[copilot]` | Bots to manually request on the first pass (iteration 1). Controls who gets pinged then — bot *evaluation* is not gated by this (see below). |
| `loop_reviewers` | `[copilot]` | Bots re-requested on every push (the convergence drivers; SKILL.md step 8). A bot in `request_on_pr_open` but **not** here is **first-pass-only**: requested once, findings triaged like any other, then never re-requested and not gating convergence. |
| `final_gate_reviewers` | `[skeptic]` | Reviewers run **once** after convergence, as a final check (SKILL.md step 10) on what the fix rounds produced. Non-deferred findings → fix, push, re-run the check once, then hand back — **the loop does not restart**, so `loop_reviewers` are not re-requested and not waited on. `[]` = no check. Usually the same reviewer as the upfront gate. |
| `auto_review_grace_seconds` | `0` | After a push, wait this long for an auto-trigger to land before manually requesting. `0` = no wait. Bump to ~60 where a Ruleset auto-requests Copilot, or to give Codex's auto-review time to start. |
| `wait_check_cadence_seconds` | `180` | Polling cadence for the wait (SKILL.md step 3, `reference/waiting.md`). Stay in 120-240s (every 2-4 min): frequent enough to react promptly, and ≤270s keeps each wake inside the 5-minute prompt-cache window (each wake cheap); >300s incurs a full context replay per wake. |
| `max_iterations` | `10` | Iteration cap before pausing to ask the user. Waiting does NOT count toward it. |

## Precedence (low → high)

```
bundled defaults  <  ~/.claude/pr-review-loop.config.yml (optional)  <  <orchestrator-repo>/.github/pr-review-loop.config.yml (project)
```

Bundled defaults are always present (the self-sufficient baseline). User-level is optional and additive — read it *if it exists*; if it doesn't, that's fine, never require it. Project `.github/pr-review-loop.config.yml` in the orchestrator repo (the working directory's repo) wins. **Merge is per-key**, not whole-file replace — a project file setting only `max_iterations` inherits the rest from below. The merged config applies to ALL PRs in the run, including cross-repo ones (they don't pull config from their own repos).

**Gate vs `request_on_pr_open` for a deep reviewer.** Both put a reviewer in front of a fresh PR, but differ in structure. `request_on_pr_open` batches its first-pass findings into iteration 1 alongside the loop reviewers — one combined evaluation, then the loop runs. `upfront_gate_reviewers` makes it a **distinct phase that must complete first** (actionable-clear re-runs to clean, actionable-unclear pauses for the user) before any loop reviewer is requested. Use the gate when "is this approach even right?" should be answered before polish; use `request_on_pr_open` when the catches can be handled inline. Don't list the same bot in both (the gate already covers the first look) — and `skeptic` can only be a gate anyway.

**Evaluation is NOT config-gated.** Any bot that posts a review, or a review-style verdict comment (judged on content, not CI/noise), is evaluated and tracked. What *is* config-gated is **re-requesting**: only `loop_reviewers` are re-pinged after later pushes. A bot's verdict may arrive as a formal review *or* a plain issue comment (some bots only comment when happy — Codex posts a review with findings, an issue comment when clean); the loop reads both and **judges disposition from what was written** (SKILL.md "Reading reviewer state"). There is deliberately **no per-bot verdict-phrase configuration** — a phrase list would break on the next bot.

## Invocation modifiers — natural language, not flags

Parse intent; don't require precise syntax:

- "no iteration cap" / "until done" / "no max" → disable `max_iterations`.
- "only copilot" / "without codex" / "skip codex" → override `request_on_pr_open` (and the gate/loop/final lists) to drop the excluded reviewer for this run. Only changes who the loop *engages*; a bot that shows up via auto-trigger is still evaluated.
- "skip the gates" / "no skeptic" / "just the loop" → both gate lists empty for this run; the loop starts immediately and ends at convergence. Also the honest fallback to offer when the skeptic pre-flight fails and the user doesn't want to fix it now.
- "skip the final check" / "gate only" → `final_gate_reviewers: []`, upfront gate untouched. The mirror ("no upfront gate", "review it at the end only") empties `upfront_gate_reviewers` instead.
- "codex first pass only" / "adversarial codex" / "gate with codex" → swap the deep reviewer on the bookends: `upfront_gate_reviewers: [codex]`, `final_gate_reviewers: [codex]`, `request_on_pr_open: [copilot]`, `loop_reviewers: [copilot]` (set `request_on_pr_open` explicitly so Codex is dropped from the first pass — else a project config listing Codex there would gate *and* re-request it, violating "don't list the same bot in both").
- "gate the design first" / "have <bot> gate it first" → `upfront_gate_reviewers: [<reviewer>]` for this run (commonly paired with `final_gate_reviewers: [<reviewer>]`).
- A PR number, URL, or cross-repo reference → target specific PR(s) instead of auto-detecting.

Build command is not configured — detect the project's verify command at the commit step.

## Project-level *procedural* overrides (separate from config)

If the orchestrator repo has its own PR-review instructions that **contradict** this skill, defer to the project — assume the override is intentional. Check: `./.github/PR_REVIEW_LOOP.md`, `./CLAUDE.md` (PR-review section), `./AGENTS.md` (PR-review section), `./.cursorrules`, `./.claude/commands/pr-review-loop.md` / `./.claude/skills/pr-review-loop/`. Classify each difference:

- **Contradiction** = procedural disagreement (reply templates, escalation rules, rubric, resolve criteria). **Project wins.**
- **Addition** = non-contradicting delta (project build command, an extra lint rule, a preferred reply style). **Apply both.** (Bot selection is config, not a procedural addition.)
- **Unclear** = can't tell whether it's an intended override or just stale. **Ask the user.**
