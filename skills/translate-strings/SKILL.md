---
name: translate-strings
description: |
  Translate Android string resources. Given a source values/strings.xml file
  (and optionally an explicit list of keys to translate), produces translated
  values into every sibling values-{locale}/strings.xml. Preserves XML
  structure, placeholders, escapes, plurals, alphabetization, and
  translatable=false flags. Encodes locale-specific translation guidance.
  Pure transform: does not figure out what changed in git, does not commit,
  does not push. The caller decides what to translate and what to do with
  the result.
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
---

# Translate Android strings.xml

A pure translation transform for Android string resources. Given a source
file and optionally a list of keys to translate, produce translated locale
files. **Does not figure out what changed in git, does not commit, does not
push** — those are the caller's concerns.

## What this skill does

- Reads the source `values/strings.xml` and its sibling `values-{locale}/strings.xml` files
- Translates the requested keys into every locale
- Writes the locale files, alphabetized by key
- Preserves XML structure, placeholders, escapes, plurals, HTML, `translatable="false"`
- Applies locale-specific translation guidance (case agreement, idiomatic forms, RTL, etc.)

## What this skill does NOT do

- Resolve git ranges or figure out "what changed since X" — caller's job
- Commit, push, open PRs — compose with `commit-commands:*` for that
- Author source strings — that's just editing `values/strings.xml` yourself
- Translate Play Store release notes or other prose — use `/translate-content`

## Inputs

Invoke with one of these input shapes. The caller (usually the conversation,
sometimes a script) decides which shape fits.

**1. Source path + explicit key list** (most common, after a diff)

> "Translate the keys `foo_title`, `foo_subtitle`, `bar_button` from
> `app/src/main/res/values/strings.xml` into every locale."

Skill translates exactly those keys. Used when the caller has already done
a diff and knows what changed.

**2. Source path only — sync missing keys**

> "Sync missing translations for `app/src/main/res/values/strings.xml`."

Skill scans each locale file; for every key in source missing from a locale,
translate it. Does not touch keys already present (no way to detect "stale"
translations from past source changes without a translation memory).

**3. `--add <locale>` — onboard a new locale**

> "Add Polish translations for the strings."

Skill creates `values-{locale}/strings.xml` (or fills in the existing one)
with translations of every source key. Use Android folder naming
conventions: 2-letter language code, optionally followed by `-r` and a
2-letter region (`values-pt-rBR`, `values-zh-rCN`).

**4. `--retranslate <key>` — force a fresh pass**

> "Re-translate `foo_title` — the previous translation is wrong."

Skill ignores the "already present" rule for the named key(s) and
translates them fresh in every locale.

## Locating files

Source: typically `app/src/main/res/values/strings.xml` (Android standard).
Other module roots possible (`*/src/main/res/values/strings.xml`). Caller
should provide the path; if not, glob for it and disambiguate.

Targets: sibling folders matching `values-*/strings.xml`. **Exclude
non-locale qualifiers:**

- `values-night*` (theme)
- `values-v\d+` (API level)
- `values-land`, `values-port`
- `values-w\d+dp`, `values-sw\d+dp`, `values-h\d+dp`
- `values-mcc*`
- `values-television`, `values-watch`, `values-car`, `values-desk`

Anything else is a locale.

Exclude paths under `/build/`, `/node_modules/`, or `.claude/worktrees/`
(unless the current working directory is one).

## Translation rule (the conservative default)

For each target locale file:

| Caller-specified state | Locale state | Action |
|---|---|---|
| Key in explicit list, OR `--retranslate` | any | **Translate** |
| Key not in explicit list, missing from locale | (absent) | **Translate** (catch-up) |
| Key not in explicit list, present in locale | present | **Skip** — already translated |
| `--add <locale>` | any | **Translate** all source keys |

**Removal handling:** if the caller passes a key list that signals removals
(e.g., "the following keys were removed: foo, bar"), delete those from
every locale file. Otherwise the skill doesn't infer removal — it doesn't
look at source-vs-locale to find "extras."

## Always alphabetize by key when writing

Output locale files with keys sorted alphabetically by `name` attribute.
The source file's order is left untouched (devs cluster related new keys
together before they get sorted into locales). This convention produces
small, locally-coherent diffs over time.

## Critical preservation rules

1. **Placeholders.** `%s`, `%d`, `%1$s`, `%2$d`, `%.2f` — preserve exact
   count and identifiers. Argument order may shift naturally in some
   languages (`%2$s ... %1$s` when natural).
2. **Escapes.** `\'`, `\"`, `\n`, `\t`, `\\`, ` ` — preserve. Single
   quotes inside `<string>` must be `\'` or wrap the value in `"..."`;
   apostrophes are a common build-failure source.
3. **HTML/markup.** `<b>`, `<i>`, `<u>`, `<a href="...">`, `<br/>`, CDATA
   blocks — preserve structure exactly, translate only visible text.
4. **Plurals.** Each locale has CLDR-defined categories. From English
   `one`/`other`, generate the locale-appropriate full set:
   - English, German, Dutch, Spanish, Italian, French, Portuguese: `one` / `other`
   - Turkish, Indonesian, Chinese, Japanese, Korean, Vietnamese, Thai: `other` only
   - Russian, Ukrainian, Polish, Croatian, Czech, Slovak: `one` / `few` / `many` / `other`
   - Arabic: `zero` / `one` / `two` / `few` / `many` / `other`
5. **`translatable="false"`.** Never translate, never include in locale files.
6. **`formatted="false"`.** Preserve attribute; `%` is literal.
7. **String arrays.** Translate every `<item>` preserving order; never
   add/remove items.
8. **XML structure.** Match the existing file's indentation and attribute
   ordering. Preserve preamble (`<?xml version="1.0" encoding="utf-8"?>`).
9. **Encoding.** UTF-8, no BOM, Unix line endings (`\n`).

## No partial-sentence retranslation

When translating a value with multiple sentences, translate the whole value.
Don't try to preserve unchanged sentences within a string — cross-sentence
references cascade in many languages (pronoun/gender agreement, case
agreement, topic markers, register consistency). Re-translating one
sentence in isolation risks breaking those ties.

## Brand names and project terminology

- **Brand/product names stay in source language.** Examples vary per
  project. **Before translating any term that looks like a proper noun
  (product name, feature name, trademark), check existing locale
  translations:** if previous translations kept it in English, keep it.
- **Reuse established terminology.** If a project-specific term has been
  translated before in a locale (e.g., "Reliability Mode" rendered as
  some specific phrase), use the same phrase in new strings. Scan
  existing translations before deciding.
- **URLs, package names, code identifiers** inside strings stay
  untranslated.
- For project-specific brand-name lists, check the repo's `CLAUDE.md` or
  `.claude/translate-strings.config.md`.

## Locale-specific guidance

These reflect past hand-corrections; apply upfront:

- **Hindi (hi).** Maintain noun case agreement with adjacent words. For
  "this month" / "last month" as time-period labels, prefer
  locative/oblique case (`इस महीने` / `पिछले महीने`) over nominative
  (`यह महीना` / `पिछला महीना`). Match the case used in adjacent existing
  translations for consistency.
- **Chinese (zh-rCN, zh-rHK, zh-rTW).** Prefer concise, idiomatic phrasing
  over literal translation. UI labels should be short. Use everyday terms
  (e.g., `昨天` not formal `昨日` for "Yesterday" in app UIs). Taiwanese
  (zh-rTW) often prefers slightly less formal/literary forms than zh-rCN
  (e.g., `上個月` over `上月`, `這個月` over `本月`).
- **German (de).** Capitalize all nouns. Compound nouns are usually one word.
- **Japanese (ja).** UI labels typically omit subjects ("Save" → `保存`,
  not `あなたが保存する`).
- **RTL locales (ar, he, fa, ur).** Don't insert LTR overrides; Android
  handles RTL layout, just translate the text.

## Style anchoring per locale

Before translating into a locale, scan ~20 existing translations in that
locale's file to capture:
- Formality (du/Sie, tú/usted, casual/formal)
- Terminology choices for app-specific terms
- Case conventions (Title Case vs sentence case)
- Punctuation conventions

Apply those conventions to new translations so the locale file reads
consistently.

## Quality check before writing

For each translation:
- Placeholders match source (count, identifiers, syntax — e.g. `%1$s` not `%1 $s`)
- No leftover English fragments in non-English locales
- Escape sequences intact
- XML well-formed (mentally parse the resulting line)
- Length sane for UI context (button labels not 3× source length)

## Output

After writing, print a summary:

- Locale files touched (count + paths)
- Per-locale rough counts (e.g., "+7 keys, 2 re-translated")
- Any keys skipped (translator-hold markers, etc.) and why
- A suggested commit subject (`i18n: translate ...`) so the caller has
  something to use with a commit skill

**Stop here.** Do not run `git add`, `git commit`, `git push`, or
`gh pr create`. The caller will handle that.

## Edge cases

- **Locale folder exists but `strings.xml` doesn't** — create the file with
  the source's XML preamble + `<resources>` root, then add the keys.
- **Locale file has keys not in source** — leave them. Could be
  hand-overrides or stale entries the user manages separately. Never
  delete silently.
- **Translator hold marker** (`<!-- HOLD: ... -->` directly above a key) —
  skip that key for that locale; note in summary.
- **Caller-provided key not in source** — note in summary, skip it (can't
  translate what's not there).
- **Build files reference strings.xml** — never modify build files.
