# Claude Skills

A small collection of [Claude Code](https://claude.com/claude-code) skills focused on **localization for Android apps and Play Store content**.

The skills here are deliberately small and single-purpose. Each one is a **pure transform** — it takes inputs, does the expert work, writes files, and stops. Figuring out *what* to translate (git ranges, "last PR", "what changed since master") is the conversation's job, not the skill's. Committing, pushing, and opening PRs are also the caller's job. Compose them with whatever commit/PR skills you already use.

## What's in here

| Skill | What it does |
|---|---|
| [`/translate-strings`](skills/translate-strings/SKILL.md) | Translate Android `values/strings.xml` keys into every sibling `values-{locale}/strings.xml`. Preserves placeholders, escapes, plurals, HTML, `translatable="false"`. Always writes locale files alphabetized by key. Supports `--add <locale>` for onboarding and `--retranslate <key>` to force a fresh pass. |
| [`/translate-content`](skills/translate-content/SKILL.md) | Translate prose — Play Store release notes, app descriptions, FAQs, marketing copy. Reads a per-repo config for output layout, target locales, and char limits. Handles cross-sentence consistency, tone, and the 500-char Play Store limit. |
| [`/whats-new`](skills/whats-new/SKILL.md) | Author Play Store "What's New" release notes from your commit log (English only). Pulls commits since the last release tag, drafts bullets within Play's 500-char limit, waits for approval, then writes the source-locale file and hands off to `/translate-content` for the other locales. |

## Typical workflow

Translating a feature branch's new strings after review settles:

1. You: *"find what strings changed since master, then translate them"*
2. Claude (the conversation): runs `git diff master -- 'app/src/main/res/values/strings.xml'`, identifies the changed keys, shows them to you
3. Claude invokes `/translate-strings` with the source path + the explicit key list
4. The skill writes the locale files and prints a summary
5. You commit however you normally do

Forgot to translate before merge? *"translate the strings from the last PR"* — the conversation resolves the PR commit, identifies the diff, calls the skill.

Cutting a release? `/whats-new` drafts the English release notes from your commits, you approve, then `/translate-content` propagates to the other locales.

## Installation

### Option A — Claude Code plugin (recommended)

In Claude Code:

```
/plugin install kanetik/claude-skills
```

This wires the skills in via the `.claude-plugin/plugin.json` manifest.

### Option B — clone + symlink

If you'd rather keep a local checkout you can hack on:

```bash
git clone https://github.com/kanetik/claude-skills.git ~/Projects/claude-skills
```

Then symlink each skill into your `~/.claude/skills/` directory.

**macOS / Linux:**

```bash
ln -s ~/Projects/claude-skills/skills/translate-strings  ~/.claude/skills/translate-strings
ln -s ~/Projects/claude-skills/skills/translate-content  ~/.claude/skills/translate-content
ln -s ~/Projects/claude-skills/skills/whats-new          ~/.claude/skills/whats-new
```

**Windows (directory junctions, no admin required):**

```cmd
mklink /J "%USERPROFILE%\.claude\skills\translate-strings" "%USERPROFILE%\Projects\claude-skills\skills\translate-strings"
mklink /J "%USERPROFILE%\.claude\skills\translate-content" "%USERPROFILE%\Projects\claude-skills\skills\translate-content"
mklink /J "%USERPROFILE%\.claude\skills\whats-new"         "%USERPROFILE%\Projects\claude-skills\skills\whats-new"
```

### Option C — plain copy

If you don't want the link / want to fork-and-modify locally without syncing back:

```bash
cp -r ~/Projects/claude-skills/skills/translate-strings  ~/.claude/skills/
cp -r ~/Projects/claude-skills/skills/translate-content  ~/.claude/skills/
cp -r ~/Projects/claude-skills/skills/whats-new          ~/.claude/skills/
```

## Per-project setup

The skills are project-agnostic — they don't hardcode any paths, brand names, or layouts. To wire a project in:

### For `/translate-strings`

No config needed. The skill operates on standard Android resource layout (`app/src/main/res/values/strings.xml` and sibling `values-{locale}/strings.xml`). Project-specific brand names (the things that should *not* be translated) belong in your project's `CLAUDE.md` so the conversation can pass them through as guidance.

### For `/translate-content` and `/whats-new`

Add a `.claude/whats-new.config.md` (or `.claude/translate-content.config.md`) at your repo root with:

```yaml
output_dir: app/src/main/play/release-notes      # gradle-play-publisher layout
file_pattern: "{locale}/default.txt"
# or for r0adkll/upload-google-play layout:
# output_dir: playstore/whatsnew
# file_pattern: whatsnew-{locale}
locales:
  - en-US (default)
  - de-DE
  - es-ES
  - fr-FR
  # ... etc
char_limit: 500
since_ref_rule: "last tag matching ^[0-9]+\\.[0-9]+\\.[0-9]+$"
```

The skills read this once per invocation and use it to find the source file, list the target locales, and enforce the char limit.

## Design principles

If you want to add to this collection (or fork it for your own), these are the rules I'm holding myself to:

1. **Pure transforms.** Inputs → expertise → outputs. No git operations, no commits, no pushes, no PRs inside a skill. Those are the caller's concern.
2. **Single responsibility.** One skill, one thing. `/translate-strings` and `/translate-content` are separate because XML resources and prose are different domains with different rules — better than one `/translate` with internal dispatch.
3. **Project-agnostic.** No project-specific brand names, paths, or conventions baked into the skill. Those go in per-repo config files or per-repo `CLAUDE.md`.
4. **Composable.** A skill should work the same whether the caller is a human typing a slash command, another skill, or a script. No assumptions about who's calling.
5. **Conservative defaults.** Don't waste tokens re-translating what's already translated. The user can always force with `--retranslate`.

## Contributing

Issues and PRs welcome. If you want to add a skill, please follow the principles above — small, single-purpose, no orchestration.

## License

[MIT](LICENSE)
