# Claude Skills

A collection of [Claude Code](https://claude.com/claude-code) skills I find useful and worth sharing. It isn't tied to one domain — whatever makes a good, self-contained skill can live here. (Several of the skills so far happen to deal with localization for Android and Play Store content, but that's just where I started, not the theme.)

The skills here are deliberately small and single-purpose. Each one does **one job and nothing more**: it takes inputs, applies the expert work, and stops. A skill doesn't reach outside its own job — figuring out *what* to feed it (git ranges, "last PR", "what changed since master") is the conversation's job, and side concerns like committing or opening PRs belong to the caller **unless that work is the skill's actual domain** (a skill built to run a PR-review loop legitimately drives git and PRs — that's the point of it). Compose the small transforms with whatever commit/PR skills you already use.

## What's in here

| Skill | What it does |
|---|---|
| [`/translate-strings`](skills/translate-strings/SKILL.md) | Translate Android `values/strings.xml` keys into every sibling `values-{locale}/strings.xml`. Preserves placeholders, escapes, plurals, HTML, `translatable="false"`. Always writes locale files alphabetized by key. Supports `--add <locale>` for onboarding and `--retranslate <key>` to force a fresh pass. |
| [`/translate-content`](skills/translate-content/SKILL.md) | Translate prose — Play Store release notes, app descriptions, FAQs, marketing copy. Reads a per-repo config for output layout, target locales, and char limits. Handles cross-sentence consistency, tone, and the 500-char Play Store limit. |
| [`/whats-new`](skills/whats-new/SKILL.md) | Author Play Store "What's New" release notes from your commit log (English only). Pulls commits since the last release tag, drafts bullets within Play's 500-char limit, waits for approval, then writes the source-locale file and hands off to `/translate-content` for the other locales. |
| [`/pr-review-loop`](skills/pr-review-loop/SKILL.md) | Run an iterative PR review loop with a strict role split: reviewers review and post findings to the PR, and this skill is the author — the only thing that touches code. It reads every finding off the PR and decides each one on whether the problem is real and whether it is this PR's work (fix a real problem the change owns, whatever its severity / acknowledge a correct observation that names no problem / reject with a public rationale / file a follow-up issue for genuinely unrelated work), replies, resolves the thread, pushes, and asks for review again, until a round changes no code — nothing blocking outstanding, and nothing fixed that a reviewer hasn't since seen. Reviewers can be bots (Copilot, Codex, anything that posts a review) or `/pr-review-skeptic`, which it re-runs on every fix push. Bundles config defaults and reference material, reads project overrides from the consuming repo, and degrades gracefully where loop/scheduling primitives are absent. Driving git/PRs is this skill's actual job, not overreach. |
| [`/pr-review-skeptic`](skills/pr-review-skeptic/SKILL.md) | Get an honest second opinion on a PR from reviewers with no stake in it. Blind subagents read the changes at HEAD knowing the project but nothing about why the change exists, treating comments and docs as claims to check against the code, and reporting what is materially wrong rather than what is merely imperfect. Large PRs are partitioned across reviewers plus a pass on how the pieces compose. They are blind to the *author*, not to the review: the first run reads the whole change cold, and later runs stay as cold on the author's account while being scoped to what has changed since the last review and told which non-blocking consequences the project has already accepted — except the composition reviewer, which takes the whole change every run. The review history also reconciles what they found afterwards — a decision that was already weighed stops blocking but stays named in the verdict with the thread that settled it, a defect raised and patched before and still present comes back a severity higher, and a concern that was dismissed once and independently found again comes back flagged with the thread that dismissed it. Every finding gets its own thread, plus a go/no-go verdict: posted when you invoke `/pr-review-skeptic` or ask for it on the PR, shown in the terminal first for question-shaped asks like "is this ready to merge?". |

## Typical workflow

Translating a feature branch's new strings after review settles:

1. You: *"find what strings changed since master, then translate them"*
2. Claude (the conversation): runs `git diff master -- 'app/src/main/res/values/strings.xml'`, identifies the changed keys, shows them to you
3. Claude invokes `/translate-strings` with the source path + the explicit key list
4. The skill writes the locale files and prints a summary
5. You commit however you normally do

Forgot to translate before merge? *"translate the strings from the last PR"* — the conversation resolves the PR commit, identifies the diff, calls the skill.

Cutting a release? `/whats-new` drafts the English release notes from your commits, you approve, then `/translate-content` propagates to the other locales.

Just opened a PR? `/pr-review-loop` takes it from there. It is one loop with one rule about who does what: **the reviewer reviews and never fixes; the loop is the author and the only thing that touches code.** Reviewers post their findings to the PR as threads. The loop reads them and decides each one — fix it, acknowledge it without changing anything, reject it with a rationale, or file a follow-up issue for genuinely unrelated work — on three questions that aren't severity: **is the problem real** (materially wrong, not merely not-quite-right), **is it worth acting on** (does someone reach a wrong outcome, or does the cost land only on a later reader), and **is it this PR's work**. A real problem the change owns gets fixed here whatever its severity, because what merges should work. A correct observation that names no problem gets acknowledged and closed — and so does a real one that isn't worth the round a fix would cost, with the reply saying which, because the second is a decision to ship a known defect. Comments, tests and descriptions need to be correct, not perfect, and that second question is where it mostly bites. Only genuinely unrelated work becomes a follow-up issue. Then it replies, resolves the thread, pushes, and asks for review again — until a round changes no code: nothing blocking left, and nothing fixed that a reviewer hasn't since seen. Severity decides what has to be fixed; it never decides what has to be reviewed.

That middle course is what keeps the loop from eating itself. A reviewer with no severity floor is usually *correct*, and correctness isn't the bar — an adversarial reader can always say something true, especially about prose, which has no failing test to pin it. Without a way to say "you're right, and I'm not changing this," every true remark is either a fix (which owes another review, whose reviewer finds something true about *that*) or an issue. One of those makes the loop run forever; the other grows a backlog nobody closes. Unlike the translation skills, this one *is* about git/PR work, so it drives those operations itself rather than leaving them to you.

A reviewer can be a bot (Copilot out of the box) or `/pr-review-skeptic`, and the pairing is what the loop is built for:

```yaml
# .github/pr-review-loop.config.yml
reviewers: [skeptic]        # or [copilot, skeptic]
```

Skeptic's reviewers are blind — they read the code at HEAD knowing the project and nothing about why the change exists, so they judge the code rather than the argument for it. Because it re-runs on every fix push, it also reads the code the fix rounds produced, which is the code with the least review behind it and the most accumulated confidence that it's fine.

They're blind to the **author**, not to the review. The first run reads the whole change cold. Later runs stay just as cold on the author's account while being told two things the review itself produced: which commit was already reviewed — so the content reviewers read what's changed since, instead of re-deriving round two's findings on round eight — and which consequences the project has already decided about, stated as decisions with none of the reasoning attached. One reviewer is exempt: the composition reviewer takes the whole change every single run, because a defect made by two changes written rounds apart appears in neither of their diffs and is visible from nowhere else. Its history pass then buckets what's left against the PR's own threads, so settled ground comes back marked settled, and a defect a fix round patched and left present comes back a severity higher.

That last part is why the loop replies to *every* finding and resolves its thread, not just the blocking ones — the reply is the record the next round reads. It's also why rejections are public and specific: a rejection with reasoning settles the finding, and a settled blocking finding still shows up in the verdict with its count and thread, so a bad rejection stays visible instead of quietly disappearing.

Three things to know before turning skeptic on. It needs the skill installed and its five project keys configured (below). It needs `allow_agent_posting: true` committed to the reviewed repo's `.github/pr-review-skeptic.config.yml` — an agent-invoked review posts nothing without it, and a reviewer that leaves no trace on the PR can't record decisions, so the loop just re-finds the same things every round. And `max_iterations` is a backstop worth understanding: the loop terminates on a round that changes no code rather than on silence, so hitting the cap usually means triage went wrong — correct observations read as real problems, each fix owing another review. Reaching it is a reported outcome ("did not converge"), not a quiet stop, and the report carries the evidence: rounds since the last blocking finding, how much of the round was spent on code the loop itself wrote, and the longest repair chain. The loop checks all of the setup at kickoff and tells you what's missing rather than starting a run that can't finish.

You can also run `/pr-review-skeptic` yourself, on its own, whenever you want a colder read — same skill, posting under your account. If you run it during a loop, the loop recognises the review by its marker and folds it into the current round rather than re-running the reviewers over the same commit.

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
ln -s ~/Projects/claude-skills/skills/translate-strings   ~/.claude/skills/translate-strings
ln -s ~/Projects/claude-skills/skills/translate-content   ~/.claude/skills/translate-content
ln -s ~/Projects/claude-skills/skills/whats-new           ~/.claude/skills/whats-new
ln -s ~/Projects/claude-skills/skills/pr-review-loop      ~/.claude/skills/pr-review-loop
ln -s ~/Projects/claude-skills/skills/pr-review-skeptic   ~/.claude/skills/pr-review-skeptic
```

**Windows (directory junctions, no admin required):**

```cmd
mklink /J "%USERPROFILE%\.claude\skills\translate-strings"  "%USERPROFILE%\Projects\claude-skills\skills\translate-strings"
mklink /J "%USERPROFILE%\.claude\skills\translate-content"  "%USERPROFILE%\Projects\claude-skills\skills\translate-content"
mklink /J "%USERPROFILE%\.claude\skills\whats-new"          "%USERPROFILE%\Projects\claude-skills\skills\whats-new"
mklink /J "%USERPROFILE%\.claude\skills\pr-review-loop"     "%USERPROFILE%\Projects\claude-skills\skills\pr-review-loop"
mklink /J "%USERPROFILE%\.claude\skills\pr-review-skeptic"  "%USERPROFILE%\Projects\claude-skills\skills\pr-review-skeptic"
```

### Option C — plain copy

If you don't want the link / want to fork-and-modify locally without syncing back:

```bash
cp -r ~/Projects/claude-skills/skills/translate-strings   ~/.claude/skills/
cp -r ~/Projects/claude-skills/skills/translate-content   ~/.claude/skills/
cp -r ~/Projects/claude-skills/skills/whats-new           ~/.claude/skills/
cp -r ~/Projects/claude-skills/skills/pr-review-loop      ~/.claude/skills/
cp -r ~/Projects/claude-skills/skills/pr-review-skeptic   ~/.claude/skills/
```

Installing a subset is fine. The loop ships defaulting to Copilot, so it works on its own; add the skeptic when you want the pairing described above, and the loop will tell you at kickoff if it's configured for skeptic and can't find it.

## Per-project setup

The skills are project-agnostic — they don't hardcode any paths, brand names, or layouts. To wire a project in:

### For `/translate-strings`

No config needed. The skill operates on standard Android resource layout (`app/src/main/res/values/strings.xml` and sibling `values-{locale}/strings.xml`). Project-specific brand names (the things that should *not* be translated) belong in your project's `CLAUDE.md` so the conversation can pass them through as guidance.

### For `/whats-new`

Add a `.claude/whats-new.config.md` at your repo root. Keys:

| Key | Required | Purpose |
|---|---|---|
| `output_dir` | yes | Directory holding the per-locale files (e.g. `app/src/main/play/release-notes` for gradle-play-publisher, `playstore/whatsnew` for r0adkll/upload-google-play) |
| `file_pattern` | yes | Filename template with `{locale}` — `{locale}/default.txt` (subdir layout) or `whatsnew-{locale}` (flat layout) |
| `locales` | yes | Play Store locale codes; exactly one marked `(default)`, matching the English source |
| `since_ref_rule` | yes | How to find the previous release, e.g. the last version tag |
| `skip_topics` | no | Commit topics to omit from the notes (has sensible defaults: analytics, crash logging, A/B tests, refactors, dependency bumps, docs/tests/CI) |
| `notes` | no | Anything else the skill should know (CI contract, etc.) |

```yaml
output_dir: app/src/main/play/release-notes
file_pattern: "{locale}/default.txt"
locales:
  - en-US (default)
  - de-DE
  - es-ES
  - fr-FR
  # ... etc
since_ref_rule: "last tag matching ^[0-9]+\\.[0-9]+\\.[0-9]+$"
skip_topics:
  - analytics
  - crash logging
  - A/B tests
```

The 500-character Play Store limit is baked into the skill — you don't configure it. If the config is missing, `/whats-new` asks for these values and offers to write the file.

### For `/translate-content`

Add a `.claude/translate-content.config.md` at your repo root. Note the keys differ from `/whats-new` — this skill uses `source_path`/`output_pattern`, not `output_dir`/`file_pattern`:

| Key | Required | Purpose |
|---|---|---|
| `source_path` | yes | Path to the default-locale source file (e.g. `app/src/main/play/release-notes/en-US/default.txt`, `playstore/whatsnew/whatsnew-en-US`, `docs/faq-en.md`) |
| `output_pattern` | yes | Template for each locale's output, with `{locale}` substituted |
| `locales` | yes | Target locale codes; one marked `(default)`, matching the source |
| `char_limit` | no | Per-locale codepoint limit (500 for Play Store release notes; omit for unlimited prose) |
| `skip_locales_with_content` | no | If `true` (the default), skip locales whose output file already exists with content; set `false` to always overwrite |

```yaml
source_path: app/src/main/play/release-notes/en-US/default.txt
output_pattern: app/src/main/play/release-notes/{locale}/default.txt
locales:
  - en-US (default)
  - de-DE
  - es-ES
  - fr-FR
  # ... etc
char_limit: 500
skip_locales_with_content: true
```

You can also skip the config entirely and drive `/translate-content` ad-hoc: *"translate `docs/faq-en.md` into de-DE, es-ES, fr-FR, write to `docs/faq-{locale}.md`, no char limit."*

### One file or two?

**Two.** `/whats-new` and `/translate-content` read separate config files with non-overlapping keys — `/whats-new` never reads `source_path`/`output_pattern`, and `/translate-content` never reads `since_ref_rule`. Keep them as two files. (`/translate-content` will fall back to reading `whats-new.config.md` if that's your project's convention, but it only picks up the keys it recognizes, so a dedicated `translate-content.config.md` is clearer.) When a config is missing, the skill asks for the values and offers to write the file for you.

### For `/pr-review-skeptic`

Worth two minutes: add `.github/pr-review-skeptic.config.yml` to the repo you review. Run directly, the skill asks on first run without it (drafting answers from your README/CLAUDE.md for you to confirm) and offers to write the file. Run **from `/pr-review-loop`**, there's nobody to interview — so the loop checks the config at kickoff and pauses to ask you, rather than reviewing your PR against five invented facts about your project. Committing the file to your default branch settles it for good: the config is read from the PR's base ref, so a committed one covers every run from anywhere.

| Key | Required | Purpose |
|---|---|---|
| `project` | yes | What the application is, in a sentence |
| `users` | yes | Who uses it, and roughly how many |
| `irreplaceable_data` | yes | What can't be recovered if a change destroys it — the key that does the most work, since it turns "data loss" into a named thing the reviewer goes hunting for |
| `production_status` | yes | Shipping, staged, pre-release, internal — sets what a regression costs |
| `architecture` | yes | The shape of the system, in two sentences |
| `allow_agent_posting` | for the loop | `true` lets a review invoked by another skill or agent post to the PR. Required for `/pr-review-loop` to use the skeptic as a reviewer — see below |
| `priorities` | no | Blast-radius order in your own domain's words (has a sensible seven-rung default) |
| `files_per_unit` | no | Soft target when splitting a large PR across reviewers (default 12) |
| `max_reviewers` | no | Cap for one PR (default 8); past it, units grow rather than files going unreviewed |
| `blocking_severities` | no | Which severities hold the verdict (default `[CRITICAL, HIGH]`). Not which ones post — every finding gets its own thread |
| `confirm_before_posting` | no | `true` to preview the review before it's posted, when a person asked for it (default `false`). On an agent-invoked run there's nobody to preview to, so it reverts that run to posting nothing — which **cancels `allow_agent_posting`**. Don't set both |

```yaml
project: "An offline-first note-taking app for Android."
users: "Consumers on phones and tablets; a few thousand daily."
irreplaceable_data: "User-authored note bodies. Everything else re-syncs from the server."
production_status: "Shipping on Play, staged rollout."
architecture: "Compose UI over a Room database, with a WorkManager sync worker reconciling against a REST backend."

# Only if /pr-review-loop will drive the skeptic in this repo -- see below.
# allow_agent_posting: true
```

Nothing about any individual change belongs in this file — it describes the project, and it's the only thing the reviewers are allowed to take on faith.

**About `allow_agent_posting`.** Leave it out unless you're running `/pr-review-loop` against this repo. By default a review invoked by another skill or agent posts nothing: it hands the draft back to whoever called it, because the decision to publish under your GitHub account is yours. This key is how a repository gives that up standingly — any skill or agent that invokes the skeptic here can then publish a review under the invoking user's account, notifying every collaborator, with no preview. That's the right trade when a review loop needs threads to reply to, and it isn't part of the minimal setup.

It's deliberately the one key that doesn't follow the usual merge rules: it counts only from this file, committed, read at the PR's base ref. Not from `~/.claude/`, not from an uncommitted copy in your tree. So a PR can't grant itself the right to publish in its own diff, the permission is visible and revocable by everyone who works on the repo, and it can't ride your machine's user-level config into someone else's project. It never overrides *"don't post"*, never posts on a merged or closed PR, and `confirm_before_posting: true` cancels it outright.

## Design principles

If you want to add to this collection (or fork it for your own), these are the rules I'm holding myself to:

1. **Does its job and nothing more.** Inputs → expertise → outputs. A skill doesn't bolt on concerns outside its stated job or impose workflow the caller didn't ask for. Git operations, commits, pushes, and PRs are normally the caller's concern — *unless they are the skill's actual domain*, in which case doing them is the whole point.
2. **Single responsibility.** One skill, one thing. `/translate-strings` and `/translate-content` are separate because XML resources and prose are different domains with different rules — better than one `/translate` with internal dispatch.
3. **Self-contained and dependency-light.** A skill stands on its own when its folder is dropped into `~/.claude/skills/` — everything it needs lives inside the folder. Reference bundled files from `SKILL.md` by paths relative to `SKILL.md` (the documented supporting-files pattern; Claude resolves them against the skill's own directory, not the working directory). Files *executed* from a bash-injection command use the `${CLAUDE_SKILL_DIR}` substitution, since the working directory at run time is the project root. No absolute `~/.claude/...` assumptions. It doesn't demand tools a typical user wouldn't have; where a real dependency exists (`gh`, `jq`), it's stated, not silently assumed.
4. **Project-agnostic.** No project-specific brand names, paths, or conventions baked into the skill. Those go in per-repo config files or per-repo `CLAUDE.md`.
5. **Composable.** A skill should work the same whether the caller is a human typing a slash command, another skill, or a script. No assumptions about who's calling.
6. **Conservative defaults.** Don't do expensive work that wasn't asked for — e.g. don't re-translate what's already translated. The user can always force it.

## Contributing

Issues and PRs welcome. If you want to add a skill, please follow the principles above — small, single-purpose, self-contained, and scoped to one job (don't reach outside what the skill is actually for).

## License

[MIT](LICENSE)
