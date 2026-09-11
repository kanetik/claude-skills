---
name: later
description: |
  Park a thought that is not about the work in progress, and hand it back when
  it is useful again. Captures the thought verbatim into a per-repository or
  user-level store, says one word, and returns to what was happening -- no
  questions, no scoping, no detour. A SessionStart hook replays what is parked
  at the top of later sessions, and finished work is reconciled against the
  list so an item that got handled along the way stops coming back. Use when
  the user says "later", "park this", "note that down", "don't derail", "while
  I think of it", "unrelated but", "remind me to", or invokes /later; and when
  the user asks what is parked, or an item looks like it was handled.
allowed-tools:
  - Bash
  - Read
  - Edit
  - AskUserQuestion
---

# Later

A thought arrives in the middle of unrelated work. Said out loud into the
session it drags the work sideways; swallowed, it is gone. This skill takes it,
writes it down, and gets out of the way.

**The skill stores thoughts and hands them back. It does not do them.** Acting
on a parked item is a new piece of work the user starts deliberately.

It is also not an issue tracker or a scheduler. Anything with a due date
belongs in a calendar or a cron entry, and anything that is real, specified
work belongs in the issue tracker. What lands here is the raw, half-formed
thing that is not yet either.

## The capture rule

**Do not engage with a parked thought.** This is the rule the whole skill
turns on, and the one that is most tempting to break, because engaging looks
like helpfulness.

When a thought is parked:

- Do not ask a clarifying question about it.
- Do not estimate its size, guess at its design, or check whether it is already
  done.
- Do not offer to do it now, and do not offer to do it after the current work.
- Do not read files to work out what it refers to.
- Do not restate it back in improved words.

Store it in the user's own words, acknowledge in a few words, and continue the
interrupted work in the same reply. Any response longer than an acknowledgement
is the derailment the user was trying to avoid — a fragmented session is the
cost of *responding*, not the cost of *mentioning*, and a helpful reply costs
exactly as much as an unhelpful one.

The one exception: if the thought is genuinely unintelligible as written, park
it verbatim anyway and say nothing. It can be deciphered when it comes back.

## Commands

Run the bundled script. `${CLAUDE_SKILL_DIR}` resolves to this skill's folder;
the working directory at run time is the project root, not this folder.

| Command | What it does |
|---|---|
| `sh "${CLAUDE_SKILL_DIR}/later.sh" add <text>` | Park a thought against this repository |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" add --user <text>` | Park it at user level, tagged with the repo it arrived in |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" list` | Numbered open items for this repository |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" list --user` | Numbered open items in the user store |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" list --all` | Both, user items prefixed `u` |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" done <n>` | Mark repository item *n* handled |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" done --user <n>` | Mark user item *n* handled |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" maybe <n> <why>` | Mark repository item *n* *possibly* handled, recording what suggests it |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" maybe --user <n> <why>` | The same, in the user store |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" show` | The digest the SessionStart hook prints |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" path` | Where this repository's store lives |

**`${CLAUDE_SKILL_DIR}` is a Claude Code substitution.** A host that does not
provide it leaves it empty, turning every command above into `sh "/later.sh"`.
Substitute the path of the folder this file is in. `INSTALL.md` beside this
file says which hosts that covers.

**`add` is the one command whose flag must come first.** Its text is free-form,
so a flag after the text is text: `add "a stray thought" --user` parks into the
*repository* store with `--user` glued onto the end of the thought. Nothing
complains; the scope `add` names back — `Parked (repo store, N open)` — is the
only cue. On every other command the flag may go anywhere, so `done 1 --user`
means what it looks like.

Item numbers shift as items are handled, so `list` before `done` or `maybe`
rather than reusing a number from earlier in the session. **A number means
nothing without a scope**: each store numbers from 1, and `done` and `maybe`
without `--user` always mean the repository. The digest prints no numbers at
all, so a number never comes from it — run a scoped `list`. `list --all`
prefixes user items with `u`, and `u2` means `done --user 2`.

`--all` is refused on `add`, `done` and `maybe`, which write to exactly one
store. `--` ends the flags, for a thought or a reason that begins with one:
`add -- "--no-verify keeps biting us"`.

## Choosing the scope

Default to the repository store. Use `--user` when the thought is not about the
repository the session is in — the case where an idea about project B surfaces
while working in project A. That is the fragmenting case this skill exists for,
and it has nowhere else to go.

When it is genuinely ambiguous, park it against the repository. A
repository-scoped item is seen more often, and being seen is the point.

## Where it is stored

| Scope | Path |
|---|---|
| Repository | `<claude-config>/projects/<mangled-repo-root>/later.md` |
| User | `<claude-config>/later.md` |

`<claude-config>` is `CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`. The
mangling matches the convention Claude Code uses to key per-project state, so
the file sits beside that project's `memory/` directory. The script resolves
the *main* repository root, so every worktree and every subdirectory of a
repository share one store.

Handled items stay in the file rather than being deleted — "did I already think
of this?" is worth being able to answer. They stop appearing in `list` and in
the digest.

## Resurfacing

Capture is worth nothing without this half. A store nothing ever reads is a
hole thoughts go into.

The mechanism is a `SessionStart` hook that runs `later.sh show`, whose output
is injected as context at the top of each session. **The digest always prints**
— `Nothing parked, via the /later skill.` when both stores are empty, and a line
naming the reason where the repository store cannot be read — so its presence is
what says the hook ran.

Installed as part of the plugin, the hook is already declared and there is
nothing to set up. Installed by symlink or copy into `~/.claude/skills/`, it
has to be added by hand: `INSTALL.md` beside this file has both shapes.

**If nothing at all appeared at the top of this session — no parked list, no
`Nothing parked`, no unreachable-store line — nothing is replaying the store.**
Say so once, in one line, the first time a thought is parked, and point at
`INSTALL.md`.

**Do not go looking for the hook, and do not offer to write one.** A hook is
equally valid in any of several settings files and plugin manifests, so not
finding one proves nothing; and under a plugin install this skill lives in a
version-stamped cache directory, so a hook written to that path works until the
next plugin update and then fails silently, for good.

## Raising a parked item

The digest is the main path, and it is passive on purpose: it is context for
the session, not a task list to work through. Do not open a session by
proposing to do what is parked.

Beyond that, raise an item unprompted only when the current work runs directly
into it — the file being edited is the file an item names, or the change about
to be made would be shaped differently if the item were done. Then say which
item, in one sentence, and let the user decide. Everything else waits for them
to ask.

## Reconciling what got handled

Work sometimes covers a parked item without anybody noticing, and re-parking or
re-proposing something already done is its own kind of fragmentation.

When a piece of work finishes — a task completed, a PR opened, a branch merged
— compare what was actually done against the open items already in context from
the digest. This needs no search: both halves are already known. For anything
that looks handled:

1. Mark it with `maybe <n> <why>`, recording what suggests it (`maybe 2 "the
   retry backoff commit on this branch"`).
2. Say so in one line so the user can correct it.

**Use `maybe`, not `done`, unless the user says outright that an item is
finished.** A false positive that quietly deletes an idea is worse than a stale
line, because the user never finds out it happened. `maybe` leaves the item
visible, carrying the reason, for them to confirm or dismiss. Never delete an
item, and never silently drop one.

`done` is for explicit instructions — the user saying an item is handled, or
asking to clear it.

## Requirements

A POSIX shell (`sh`), the standard text tools (`grep`, `sed`, `awk`, `date`),
and **git 2.31 or newer** for the repository store. No network access, no `gh`,
no `jq`.

The git floor is hard and has deliberately no fallback: without
`--path-format=absolute`, the same repository keys a different store from the
main checkout, from a linked worktree and from a subdirectory, and that failure
is silent — the thought is written and `list` from anywhere else says nothing is
parked. So on older git a repository-scoped `add` is refused with a message
naming the version; `--user` still works, minus the `(from <repo>)` tag, and
`show` still exits 0, because a missing store must never stop a session
starting.

`sh "${CLAUDE_SKILL_DIR}/selfcheck.sh"` exercises the store end to end in a
throwaway directory, touching nothing real.
