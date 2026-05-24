# CLAUDE.md — instructions for AI working on this repo

This repo is a **collection of Claude Code skills**, published for others to use. It's not an application — it has no build, no tests, no runtime. The deliverable is the prose inside each `SKILL.md`.

## What goes here

- `skills/<name>/SKILL.md` — one skill per folder, frontmatter + body
- `.claude-plugin/plugin.json` — manifest listing every skill the plugin exports
- `README.md` — what the skills do, how to install, design principles
- `LICENSE`, `.gitignore` — standard

## Rules for changing skills

1. **Skills are pure transforms.** They do the expert work and stop. Never add git operations, commit/push logic, PR creation, or workflow orchestration to a skill. Those are the caller's concern.
2. **Single responsibility per skill.** If a new request would add modes that are really separate concerns, propose splitting into a new skill instead of bloating an existing one.
3. **Project-agnostic.** No hardcoded brand names, paths, or per-project conventions. Those belong in per-repo config files or per-repo `CLAUDE.md` files in the *consuming* repo, not in the skill.
4. **Frontmatter contract.** Every `SKILL.md` must have valid YAML frontmatter with `name`, `description`, and `allowed-tools`. The `description` is what Claude Code reads to decide whether a skill applies, so be specific.
5. **Edge-case sections should be short.** Cover the common case well; let rare edge cases fall back to "ask the user." Long edge-case lists are noise.

## Rules for adding a new skill

1. Create `skills/<name>/SKILL.md` with valid frontmatter.
2. Add `./skills/<name>` to the `skills` array in `.claude-plugin/plugin.json`.
3. Add a row to the README's "What's in here" table.
4. Update the README's "Typical workflow" section if the new skill changes a typical flow.

## Rules for removing or renaming a skill

1. Delete the skill folder.
2. Remove from `.claude-plugin/plugin.json`.
3. Remove from the README table.
4. Note the removal/rename in the commit message — users may have it installed.

## Style

- No emojis in skill content unless explicitly requested.
- Markdown tables for option/parameter lists.
- Bullet points sparingly; prose is usually clearer.
- Frontmatter `description` should be **what the skill does**, not **when to invoke it** (the invocation triggers live in the body).
