---
name: translate-content
description: |
  Translate prose / natural-language content into multiple locales. Given a
  source file (Play Store release notes, app description, FAQ entries,
  marketing copy, etc.) and a target locale set, produces translated locale
  files. Preserves bullet markers, tone, register, brand-name handling.
  Honors the char limit the content type carries (Play release notes 500),
  plus any limit config or the caller supplies. Encodes locale-specific translation
  guidance. Pure transform: does not figure out what changed in git, does
  not commit, does not push.
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
---

# Translate prose content

A pure translation transform for natural-language content (Play Store
release notes, app store descriptions, FAQs, marketing copy, longer help
text). Given a source file and target locale info, produce translated
locale files. **Does not figure out what changed in git, does not commit,
does not push** — those are the caller's concerns.

For Android XML string resources (key-by-key UI labels), use
`/translate-strings` instead — different domain, different rules.

## What this skill does

- Reads a source prose file
- Translates the whole text into each target locale
- Writes per-locale output files at the configured path/pattern
- Preserves bullet markers, paragraph breaks, line breaks, emoji
- Honors the char limit the content type carries, whether configured or not
  (500 for Play Store release notes — other Play fields have their own)
- Applies locale-specific translation guidance (Hindi case, Chinese
  idiomatic forms, German capitalization, RTL handling)
- Handles cross-sentence consistency (pronoun/gender agreement, case,
  topic markers, register) by translating the whole text at once

## What this skill does NOT do

- Resolve git ranges or figure out "what changed since X" — caller's job
- Author source content — for Play Store release notes specifically, use
  `/whats-new`
- Commit, push, open PRs — compose with `commit-commands:*` for that
- Translate XML string resources — use `/translate-strings`

## Inputs

**1. Source file path + repo config** (most common)

> "Translate the release notes at
> `app/src/main/play/release-notes/en-US/default.txt` into every locale."

Skill reads the source text and looks up `.claude/translate-content.config.md`
(or `.claude/whats-new.config.md` if that's the project convention) for
target locales, output path pattern, and char limit.

**2. Source file path + explicit target list** (no config, ad-hoc)

> "Translate `docs/faq-en.md` into de-DE, es-ES, fr-FR. Write outputs to
> `docs/faq-{locale}.md`. No char limit."

Skill uses the explicit info instead of looking up a config.

**3. `--add <locale>` — add a new locale**

> "Add Polish translations of the release notes."

Skill resolves the source from config, translates into the new locale only,
writes to the matching path.

## Config file format (`.claude/translate-content.config.md` or similar)

| Key | Purpose |
|---|---|
| `source_path` | Path to the default-locale source file or pattern (e.g., `playstore/whatsnew/whatsnew-en-US`, `app/src/main/play/release-notes/en-US/default.txt`) |
| `output_pattern` | Template for each locale's output, with `{locale}` substituted |
| `locales` | List of target locale codes (one marked `(default)` matching the source) |
| `char_limit` | Per-locale char limit, when the content type's own limit needs overriding or the type is not obvious. Limits belong to the content type, not the store — Play Store release notes are 500, a full description 4000, a short description 80, an app title 30, most other prose none. Omitting it means "not configured", not "unlimited": see Char limit handling. |
| `skip_locales_with_content` | Optional: if `true`, skip locales whose output file already exists with content (default: true — conservative) |

If no config exists, ask the user for these values; offer to write the
config file.

## Translation rule (the conservative default)

For each target locale:

| Caller invocation | Locale file state | Action |
|---|---|---|
| Source path given, default config | exists, non-empty | **Skip** (already translated; caller can use `--retranslate` to force) |
| Source path given, default config | absent or empty | **Translate** |
| `--retranslate` | any | **Translate** |
| `--add <locale>` | n/a | **Translate** into the new locale only |

The "skip if locale already has content" rule fits the release-notes case
(the file is the contract with CI; replacing it requires intent). For
other content types where the user wants every invocation to overwrite,
they can pass `--retranslate` or set `skip_locales_with_content: false`
in config.

## Char limit handling

A char limit belongs to the specific field being translated, not to a store
as a whole. 500 is Play's *release-notes* limit; a full description allows
4000, a short one 80, an app title 30, and ordinary prose has none. So the
limit follows from what the content is, never from the fact that it is Play
Store copy.

Take it from config or the caller where either supplies one. **Where neither
does, apply the limit the content type carries** — an absent `char_limit`
means "not configured", not "unlimited". Release notes are the common case:
`whats-new.config.md` has no `char_limit` key at all, so a release-notes
translation arriving by that documented handoff has nothing configured and
must still be held to 500. Ask only when the content type itself is unclear.

When a limit applies, from whatever source:

- Count Unicode codepoints, not UTF-8 bytes. CJK = 1 codepoint each.
  Emoji can be 1-7 codepoints; keep emoji rare to be safe.
- If a translation exceeds the limit, reword tighter — don't drop content
  unless rewording can't get it under. If dropping is unavoidable, drop
  the least-interesting item (typically a vague "and more" bullet).
- Flag in the summary any locale where you had to drop content to fit.
- Use `wc -m` to verify codepoint counts when in doubt.

## No partial-sentence retranslation

When translating prose, translate the **whole** text. Don't try to
preserve unchanged sentences within a multi-sentence source — cross-sentence
references cascade in many languages:

- **Pronouns / gender agreement** (German der/die/das, Spanish el/la,
  French le/la) must match antecedent gender, which can shift if a noun
  changes elsewhere in the text.
- **Case agreement** (Russian, Polish, Czech) pulls from earlier verb
  constructions.
- **Topic markers** (Japanese は/が, Korean 은/는) carry continuity across
  sentences.
- **Register** (formal vs informal, du/Sie, tú/usted) must stay consistent
  across the whole text.

## Style anchoring per locale

If prior versions of the locale output file exist (or other content
written in the same locale), read them first to capture:

- Tone (light/casual vs formal/marketing)
- Bullet conventions (• vs - vs *)
- Formality and address forms (du/Sie, tú/usted, etc.)
- Brand-term rendering (whether the project keeps brand names in English
  or has chosen a localization)

Apply those conventions so a series of releases reads consistently.

## Brand names and project terminology

- **Brand/product names** stay in source language unless an existing
  locale translation establishes a precedent otherwise. Check the
  existing locale file (or other localized content in the repo) before
  rendering a proper-noun-looking term.
- **App-specific terminology** — reuse whatever the locale already uses
  for established features and concepts. Don't invent new translations
  for terms that have prior renderings elsewhere in the project.
- **URLs, prices, hashtags, code identifiers** — never translate.
- For project-specific brand-name lists, check the repo's `CLAUDE.md` or
  the per-repo translate-content config notes.

## Locale-specific guidance

- **Hindi (hi).** Maintain noun case agreement. For "this month" / "last
  month" prefer locative/oblique case (`इस महीने` / `पिछले महीने`) over
  nominative. Apply the same case consistency principle to other time
  expressions and recurring noun phrases.
- **Chinese (zh-rCN, zh-rHK, zh-rTW).** Prefer concise, idiomatic phrasing
  over literal translation. Avoid English-style sentence structure. Use
  everyday terms in app contexts (`昨天` over formal `昨日`). Taiwanese
  (zh-rTW) often prefers slightly less formal/literary forms than zh-rCN.
- **German (de).** Capitalize all nouns. Compound nouns usually one word.
- **Japanese (ja).** Omit subjects when context makes them obvious.
  Marketing/notice tone tends to use polite-but-friendly register (です/ます).
- **RTL locales (ar, he, fa, ur).** Don't insert LTR overrides; let the
  platform handle bidirectional layout. Translate the text.

## Output

After writing, print a summary:

- Files written (count + paths)
- Per-locale char count (flag any close to the limit)
- Any locale where content was dropped or skipped, and why
- A suggested commit subject (e.g., `i18n: translate release notes`) for
  the caller to use with a commit skill

**Stop here.** Do not run `git add`, `git commit`, `git push`, or
`gh pr create`. The caller will handle that.

## Edge cases

- **No config + no explicit locales** — ask the user; don't guess.
- **Output path resolves to a directory that doesn't exist** — create
  parents (e.g., for the per-locale-subdir layout `{locale}/default.txt`,
  `mkdir -p` the locale folder).
- **Source file empty** — tell the caller; don't write empty locale files.
- **Char limit unmeetable even after rewording** — drop the least
  interesting bullet for that locale only, keep other locales intact,
  flag in summary.
- **Caller wants the file translated but it's actually structured
  content** (e.g., a Markdown file with a complex frontmatter or table) —
  translate prose only; preserve structural elements (frontmatter keys,
  table separators, Markdown headers, code fences) verbatim.
