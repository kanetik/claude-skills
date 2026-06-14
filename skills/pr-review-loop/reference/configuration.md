# Configuration & override model

The loop is governed by seven config keys, plus natural-language invocation modifiers and project-level *procedural* overrides. This file is the full model; `config/defaults.yml` holds the shipped values.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `upfront_gate_reviewers` | `[]` | Adversarial bots run as a gate **before** the loop (SKILL.md Phase 0). One review, triaged: **minor** → fix then start the loop; **major-unclear** → pause and ask the user; **major-clear** → fix and re-request the same bot, repeating **to clean with no cap**. `[]` = no upfront gate (loop starts immediately). Skipped on a PR that already has unaddressed feedback (it's not fresh). Typically a rate-limited deep reviewer, so a wrong-from-the-start approach is caught before Copilot polishes it. |
| `request_on_pr_open` | `[copilot]` | Bots to manually request on the first pass (iteration 1). Only controls who gets pinged then — bot *evaluation* is not gated by this (see tracked-bots below). |
| `loop_reviewers` | `[copilot]` | Bots re-requested on every push during the loop (the convergence drivers; SKILL.md step 8). A bot in `request_on_pr_open` but **not** here is **first-pass-only**: requested once, its findings evaluated like any other, then never re-requested and not gating convergence. Lets a rate-limited deep reviewer (Codex) contribute its first-look catches without running every iteration. |
| `final_gate_reviewers` | `[]` | Bots requested **once** after the loop converges, as a final **sanity check** (SKILL.md step 10) — a last confirming look, not an adversarial dig. If it raises non-deferred findings, fix and re-converge `loop_reviewers`, then re-run it once. `[]` = no check. Often the same deep reviewer as the upfront gate, so it also catches anything the fix rounds introduced. |
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
- **Merge is per-key, not whole-file replace.** A project file that sets only `max_iterations` inherits the other keys from the layer(s) below.

The orchestrator repo is the current working directory's repo. Cross-repo PRs in the same run still use the orchestrator repo's merged config — they don't pull config from their own repos.

**`upfront_gate_reviewers` vs `request_on_pr_open` for a deep reviewer.** Both can put a bot in front of a fresh PR, but they differ in *structure*. Listing the deep reviewer in `request_on_pr_open` batches its first-pass findings into iteration 1 alongside the loop reviewers — one combined evaluation, then the loop runs. Listing it in `upfront_gate_reviewers` instead makes it a **distinct phase that must settle first**: its review is triaged minor/major-unclear/major-clear, a major-clear finding re-runs the gate to clean, and a major-unclear one pauses for the user — all before any loop reviewer is requested. Use the gate when "is this approach even right?" should be answered before polish begins; use `request_on_pr_open` when the deep reviewer's catches can be handled inline with everything else. Don't list the same bot in both (the gate already covers the first look).

`request_on_pr_open` controls who gets pinged on the first pass. **Bot *evaluation* is NOT config-gated** — any bot that posts a review, or a review-style verdict comment (judged on content, not routine CI/noise), gets evaluated and tracked (the tracked-bots model in SKILL.md step 2). What **is** config-gated is *re-requesting*: only `loop_reviewers` are re-pinged after subsequent pushes (step 8). So a first-pass-only bot's iter-1 findings are still triaged, but it isn't dragged through later iterations. The grace window handles auto-triggering bots (Codex's auto-review on PR open, when enabled in Codex settings; Rulesets that auto-request Copilot): wait briefly, skip the manual request when the bot already started.

A bot's verdict may arrive as a formal review *or* as a plain PR issue comment — some bots only comment when they're happy (Codex is the current example: it posts a formal review when it has findings, but a plain issue comment when it's clean). The loop reads both surfaces and **judges the bot's disposition from what it wrote** (SKILL.md "Reading reviewer state"). There is deliberately **no per-bot "verdict phrase" configuration** — a phrase list would be brittle and break on the next bot that words things differently — so disposition is decided by reading the message's meaning, not by matching configured strings.

## Invocation modifiers — natural language, not flags

Parse intent from the invocation; don't require precise syntax:

- "no iteration cap" / "until done" / "no max" / "no limit" → disable `max_iterations`.
- "only copilot" / "without codex" / "skip codex" / "just copilot" → override `request_on_pr_open` (and `loop_reviewers` / `final_gate_reviewers`) to drop the excluded bot for this run. Note: this only changes who the loop *requests*; a bot that shows up anyway via auto-trigger or installation still gets evaluated when it posts (tracked-bots model).
- "codex first pass only" / "codex once" / "adversarial codex" → the rate-limited-deep-reviewer bookend for this run: `upfront_gate_reviewers: [codex]`, `loop_reviewers: [copilot]`, `final_gate_reviewers: [codex]` (Codex runs the adversarial upfront gate and the final sanity check; Copilot drives the loop).
- "gate the design first" / "adversarial review before the loop" / "have codex gate it first" → set `upfront_gate_reviewers: [<bot>]` for this run, so that bot runs the Phase-0 gate before the loop starts (commonly paired with `final_gate_reviewers: [<bot>]` to bookend).
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
