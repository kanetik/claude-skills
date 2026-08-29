# CLAUDE.md — instructions for AI working on this repo

This repo is a **collection of Claude Code skills** I find useful and worth sharing, published for others to use. It's not themed around one domain — whatever makes a good, self-contained skill can live here. It's not an application: there's no build and no runtime, and for most skills the deliverable is the prose inside each `SKILL.md`.

**But a skill may bundle executable support files, and one does.** Where it does, that script is real code and is wrong in the ordinary ways code is wrong — so it ships with a runnable self-check beside it, and **the self-check is run before any change to that script lands.** Right now that means `skills/later/selfcheck.sh` (63 assertions, `sh skills/later/selfcheck.sh`, touches nothing outside its own temp directory). Treating this repo as prose-only is how a change to a bundled script gets shipped unverified.

## What goes here

- `skills/<name>/SKILL.md` — one skill per folder, frontmatter + body
- `skills/<name>/*.sh` — optional bundled scripts, each with a self-check beside it
- `.claude-plugin/plugin.json` — manifest listing every skill the plugin exports, and any hook a skill declares
- `README.md` — what the skills do, how to install, design principles
- `.gitattributes` — pins `*.sh` to LF so shipped scripts work off a Windows checkout
- `LICENSE`, `.gitignore` — standard

## Rules for changing skills

1. **A skill does its job and nothing more.** A skill should do what skills are good for: take inputs, apply expert knowledge, do the work, and stop. Don't bolt on concerns that fall outside the skill's stated job, and don't bake in opinionated workflow the caller didn't ask for. Operations like committing, pushing, or opening PRs are normally the caller's concern and don't belong inside a skill — **unless that operation IS the skill's domain.** A skill whose job is git/PR work (a PR-review loop, say) legitimately performs git/PR work; that's not overreach, it's the point. The test is never "does it touch git or run a loop"; it's "is this within the single job this skill exists to do." If it isn't, it belongs to the caller.
2. **Single responsibility per skill.** One skill, one job. If a new request would add modes that are really separate concerns, propose splitting into a new skill instead of bloating an existing one.
3. **Self-contained and dependency-light.** A skill must function on its own when its folder is copied into `~/.claude/skills/`, with everything it needs (reference files, config defaults) bundled inside the folder. Reference those files from `SKILL.md` by paths relative to `SKILL.md` (the documented supporting-files pattern — Claude resolves them against the skill's own directory when it loads them, *not* against the current working directory). For any file *executed* from a `` !`…` `` bash-injection command, use the `${CLAUDE_SKILL_DIR}` substitution instead, since the working directory at run time is the project root, not the skill folder. Never use an absolute `~/.claude/...` path or assume a user-level file exists. Don't require tools or services a typical user interested in the skill wouldn't have; if the skill genuinely needs a tool (`gh`, `jq`, etc.), state the requirement plainly rather than baking in an install step, and prefer the most portable form across shells/platforms.
4. **Project-agnostic.** No hardcoded brand names, paths, or per-project conventions. Those belong in per-repo config files or per-repo `CLAUDE.md` files in the *consuming* repo, not in the skill.
5. **Frontmatter contract.** Every `SKILL.md` must have valid YAML frontmatter with `name`, `description`, and `allowed-tools`. The `description` is what Claude Code reads to decide whether a skill applies — and it is the *only* part read before the skill is selected — so for a skill meant to auto-invoke, the description must carry enough "what it does / when it applies" signal to trigger reliably.
6. **Edge-case sections should be short.** Cover the common case well; let rare edge cases fall back to "ask the user." Long edge-case lists are noise.

## Rules for adding a new skill

1. Create `skills/<name>/SKILL.md` with valid frontmatter.
2. Add `./skills/<name>` to the `skills` array in `.claude-plugin/plugin.json`.
3. Add a row to the README's "What's in here" table.
4. Update the README's "Typical workflow" section if the new skill changes a typical flow.
5. If the skill needs a hook to work, declare it — either in a `hooks` block in the same `plugin.json`, or in a `hooks/hooks.json` at the plugin root. `${CLAUDE_PLUGIN_ROOT}` is substituted in anything a *plugin* declares and never in a user's own `settings.json`, so declaring it is the only way a plugin install gets a working hook without the user hand-editing their settings. Say in the skill's own `SKILL.md` what a manual install has to add by hand.

## Rules for removing or renaming a skill

1. Delete the skill folder.
2. Remove from `.claude-plugin/plugin.json` — from the `skills` array **and from any hook the skill declared**, in that file's `hooks` block or in `hooks/hooks.json`. On a **rename**, update the hook's path rather than deleting it. Either way, a hook left pointing at the old folder means every installed user runs a failing command at every session start. The `skills` array is the obvious half; the hook is the one that ships broken, and a rename is the case that looks least like it needs checking.
3. Remove from the README table.
4. Note the removal/rename in the commit message — users may have it installed.

## Style

- No emojis in skill content unless explicitly requested.
- Markdown tables for option/parameter lists.
- Bullet points sparingly; prose is usually clearer.
- Frontmatter `description` leads with **what the skill does**. Where a skill is meant to auto-invoke, it may also fold in the trigger conditions ("use when…"), since the description is the only signal Claude Code has before selecting the skill. Keep the heavy procedural detail in the body — the description is a routing signal, not the manual.
