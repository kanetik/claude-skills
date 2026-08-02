---
name: whats-new
description: |
  Author Google Play Store "What's New" release notes (the English source
  only). Pulls commits since the last release tag, drafts a bullet list
  within Play's 500-char limit, presents the draft with reserve bullets,
  and waits for explicit approval. On approval, writes ONLY the default-locale
  source file (e.g., whatsnew-en-US or en-US/default.txt) and hands off to
  the `translate-content` skill for locale propagation. Reads per-repo
  .claude/whats-new.config.md. Use before cutting a release.
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - AskUserQuestion
---

# Author Play Store "What's New" release notes

Generate the English source for Play Store release notes — pull commits, draft
bullets, get approval, write the source-locale file. **This skill stops there.**
Locale translation is the `translate` skill's job; this skill hands off.

## When to use this skill

User says: "write what's new", "draft release notes", "playstore copy",
"whatsnew", "/whats-new", or invokes ahead of cutting a release.

## Step 0: Read the per-repo config

Look for `.claude/whats-new.config.md` in the repo root. Required keys:

| Key | Purpose | Example |
|---|---|---|
| `output_dir` | Where per-locale files live | `playstore/whatsnew` or `app/src/main/play/release-notes` |
| `file_pattern` | Filename template | `whatsnew-{locale}` (flat) or `{locale}/default.txt` (subdir) |
| `locales` | Play Store locale codes; one must be marked `(default)` | `en-US (default), de-DE, zh-CN, ...` |
| `since_ref_rule` | How to find the previous release | "last tag matching `^[0-9]+\.[0-9]+\.[0-9]+$`" |
| `skip_topics` | Topics to omit (optional; has defaults) | Analytics, crash logging, A/B tests |
| `notes` | Anything special to know | CI action contract, etc. |

If no config exists, ask the user for these values (use AskUserQuestion) and
offer to create the config file before proceeding.

## Universal Play Store rules (baked in)

These apply to every project — config doesn't override them:

- **500 Unicode characters max per locale.** Hard limit, and it is the
  limit on *release notes* specifically — other Play Store fields (title,
  short description, full description) have their own, larger or smaller.
  This skill only writes release notes, so 500 always applies here.
- **Customer-benefit framing.** "Works better" beats "improved memory handling."
  Speak to outcomes, not internals.
- **Tone:** light, easy, non-technical. Avoid jargon. A touch of personality
  is fine.
- **Default skip topics** (override via config):
  - Analytics / telemetry
  - Crash logging / reporting
  - A/B tests / experiments
  - Internal refactors, build config, R8 / Proguard
  - Bot-driven dependency bumps
  - Documentation, tests, CI changes

## Step 1: Resolve the since-reference

Per `since_ref_rule`. Examples:

- "last non-beta tag in `x.y.z`":
  `git tag --list '[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1`
- "last numeric version-code tag":
  `git tag --sort=-version:refname | grep -E '^[0-9]+$' | head -n1`
- "last entry in CHANGELOG.md": parse the file accordingly.

## Step 2: Gather commits since that ref

```
git log {ref}..HEAD --no-merges --pretty='%h %s'
git log {ref}..HEAD --merges --pretty='%h %s'   # squash/merge PR titles
```

For merge-heavy workflows, prefer PR titles from merge commit subjects.

## Step 3: Draft English

1. **Group by user-facing impact.** Drop skip-topic items.
2. **Draft a bulleted list** within the 500-char limit:
   - Lead with highest-impact items (fixes affecting many users, noticeable
     new features).
   - Use bullets starting with `• ` (U+2022) or `- ` — match the project's
     existing convention if a prior source file exists.
   - Customer-benefit framing throughout.
3. **Present to the user** with:
   - The proposed English text.
   - **Char count** (Unicode codepoints — `echo -n "$text" | wc -m`).
   - **Reserve bullets** — items that didn't make the cut but might be worth
     swapping in. Show as a separate list, not part of the draft.

## Step 4: Wait for approval

**Stop here.** Wait for explicit approval before writing anything. The user
may iterate, swap bullets, tweak wording. Re-show the draft + char count
each iteration.

Do not proceed until the user clearly approves (e.g., "looks good", "ship
it", "approve").

## Step 5: Write the source-locale file ONLY

After approval:

1. Resolve the source-locale path: substitute the `(default)` locale into
   `{output_dir}/{file_pattern}`. Examples:
   - Wakey: `playstore/whatsnew/whatsnew-en-US`
   - ART: `app/src/main/play/release-notes/en-US/default.txt`
2. Write the approved English text to that path. Overwrite if it exists.
3. Create parent directories if needed (e.g., for the subdir layout, mkdir
   the locale folder).

**Do not translate.** Do not write any other locale's file. That's the
`translate` skill's responsibility.

## Step 6: Hand off to /translate

Print:

```
✓ Wrote {source path} ({char count} chars)

Next: run `/translate-content` to propagate to the other locales.
These are release notes: 500 characters per locale.
```

The limit goes in the handoff because nothing else carries it across:
`whats-new.config.md` has no `char_limit` key, so a `/translate-content`
run that reads that config finds none.

The user invokes `/translate-content` directly when ready — typically after any
review iteration on the English source settles, so locale translations
land in one clean `i18n:` commit rather than churning across rounds.

## Char counting

Count Unicode codepoints, not UTF-8 bytes. Each CJK character is 1. Emoji
can be 1-7 codepoints depending on composition (skin tone, ZWJ sequences);
keep emoji rare. With bash: `echo -n "$text" | wc -m`.

## Edge cases

- **No commits since the ref.** Likely re-running for the same release. Ask
  the user what range they want (specific tag, date range, "last N commits").
  Don't invent content.
- **All commits are skip-topic items.** Tell the user; offer to write a
  generic "performance improvements and bug fixes" message in approved tone,
  or to widen the range.
- **Existing source file is newer than the resolved ref.** The previous
  release already has notes. Show the existing content and the proposed
  diff; ask whether to replace, extend, or start fresh.
- **User wants to skip approval** (says "just write it"). Honor that —
  write directly without the approval gate, but show what you wrote.

## What this skill does not do

- Doesn't translate. (Hand-off to `/translate-content`.)
- Doesn't upload to Play Store (CI does).
- Doesn't tag releases.
- Doesn't auto-commit. The user reviews and commits the source file (and
  the subsequent `i18n: ...` translations) before tagging.
