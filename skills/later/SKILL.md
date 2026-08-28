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

A thought arrives in the middle of unrelated work. It is worth keeping and it
is not worth doing now. Said out loud into the session it drags the work
sideways; swallowed, it is gone. This skill takes it, writes it down, and gets
out of the way.

**The skill stores thoughts and hands them back. It does not do them.** When a
parked item comes back around, acting on it is a new piece of work the user
starts deliberately. This skill never begins it.

It is also not an issue tracker or a scheduler. Anything with a due date
belongs in a calendar or a cron entry, and anything that is real, specified
work belongs in the issue tracker. What lands here is the raw, half-formed
thing that is not yet either — the note that would otherwise be lost or, worse,
spoken mid-task.

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
| `sh "${CLAUDE_SKILL_DIR}/later.sh" list --all` | Repository and user items together |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" done <n>` | Mark item *n* handled |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" maybe <n> <why>` | Mark item *n* *possibly* handled, recording what suggests it |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" show` | The digest the SessionStart hook prints |
| `sh "${CLAUDE_SKILL_DIR}/later.sh" path` | Where this repository's store lives |

Flags come before the text. Item numbers match what `list` last printed, and
they shift as items are handled — always `list` before `done` or `maybe` rather
than reusing a number from earlier in the session.

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
the file sits beside that project's `memory/` directory.

**The store is deliberately outside the repository.** A `later.md` committed to
the repo turns every parked thought into a diff and a collaborator's problem,
and one that is git-ignored inside a worktree is deleted along with the
worktree when the branch lands — losing parked thoughts at precisely the moment
the work they were parked behind finishes. The script resolves the *main*
repository root via `git rev-parse --git-common-dir`, so every worktree of a
repository shares one store.

Handled items stay in the file rather than being deleted. "Did I already think
of this?" is worth being able to answer. They stop appearing in `list` and in
the digest.

## Resurfacing

Capture is worth nothing without this half. A store nothing ever reads is a
hole thoughts go into.

The mechanism is a `SessionStart` hook that runs `later.sh show`, whose output
is injected as context at the top of each session. It prints nothing at all
when nothing is parked, so it stays worth reading.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"$HOME/.claude/skills/later/later.sh\" show",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Adjust the path to wherever the skill is installed — plugin installs can use
`${CLAUDE_PLUGIN_ROOT}/skills/later/later.sh`. On Windows, point it at Git
Bash's `sh` by full path if a bare `sh` is not resolvable.

**Check the hook is wired up the first time a thought is parked in a session.**
Look for `later.sh` in the user's `settings.json`. If it is not there, say so
once, in one line, after the acknowledgement — a write-only store is the worst
outcome this skill has. Offer to add the hook; do not add it unasked, and do
not repeat the offer later in the session if it is declined.

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

A POSIX shell (`sh`), `git`, and the standard text tools (`grep`, `sed`, `awk`,
`date`). No network access, no `gh`, no `jq`.

Git 2.31 or newer is worth having but not required: `--path-format=absolute`
is what makes a linked worktree and its main checkout agree on one store. On
older git the script falls back and a worktree may key its own store, which is
the pre-2.31 behaviour rather than an error.

`sh "${CLAUDE_SKILL_DIR}/selfcheck.sh"` exercises the store end to end in a
throwaway directory, touching nothing real.
