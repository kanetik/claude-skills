---
name: parking-lot
description: |
  Put a thought on the parking lot: capture it verbatim, say one word, and
  return to what was happening -- no questions, no detour. A thought can also
  be parked for after the current work, or as a reminder for a date or a
  release tag. Use when the user says "park this", "parking lot this", "put it
  on the parking lot", "don't derail", "while I think of it", "unrelated but",
  "after this", "when we're done", "remind me in two weeks / tomorrow / after
  v12.2 ships", or invokes /parking-lot; and when the user asks what is parked,
  or an item looks like it was handled. An instruction ordering the current
  task ("after this, run the tests") is not a thought to park.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

# Parking lot

A thought arrives in the middle of unrelated work. Said out loud into the
session it drags the work sideways; swallowed, it is gone. This skill puts it
on the parking lot, and gets out of the way.

**The skill stores thoughts and hands them back. It does not do them.** Acting
on a parked item is a new piece of work the user starts deliberately.

It is also not an issue tracker. Anything that is real, specified work belongs
in the issue tracker. What lands here is the raw, half-formed thing that is
not yet that — including the reminder that only matters once a date or a
release has come.

## The capture rule

**Do not engage with a parked thought.** This is the rule the whole skill
turns on, and the one that is most tempting to break, because engaging looks
like helpfulness.

When a thought is parked:

- Do not ask a clarifying question about it.
- Do not estimate its size, guess at its design, or check whether it is already
  done.
- Do not offer to do it now. Do not offer to do it after the current work
  either — unless the user parked it for that, with `--next` (below).
- Do not read files to work out what it refers to.
- Do not restate it back in improved words.

Store it in the user's own words, acknowledge in a few words, and continue the
interrupted work in the same reply. Any response longer than an acknowledgement
is the derailment the user was trying to avoid — a fragmented session is the
cost of *responding*, not the cost of *mentioning*, and a helpful reply costs
exactly as much as an unhelpful one.

The one exception: if the thought is genuinely unintelligible as written, park
it verbatim anyway and say nothing. It can be deciphered when it comes back.

## When it comes back

Most thoughts are parked plain. Three flags on `add` say when one should come
back instead. Pick at most one, from the words the user used; do not ask.
"After this" parks only a new thought; followed by the next step of the current
task, it is an instruction, so do that step instead.

| The user says | Flag | Comes back |
|---|---|---|
| "after this", "once we're done", "when we wrap up", "next" | `--next` | At the next good stopping point, as a question (below) |
| "tomorrow", "in two weeks", "on the 20th" | `--on YYYY-MM-DD` | At the first session on or after that date |
| "after 12.2 ships", "once v12.2 is out" | `--tag <tag>` | At the first session after that git tag exists locally |

**Convert a relative date yourself**, from today's date, before calling the
script: it takes only `YYYY-MM-DD`. "In two weeks" on 2026-10-06 is
`--on 2026-10-20`.

**`--tag` needs the tag's exact name.** Use the repository's own release-tag
convention (`git tag --sort=-creatordate | head` shows it): "after 12.2 ships"
is `--tag v12.2` in a repository whose tags look like `v12.1`. A tag reaches
the local clone only when it is fetched, so a release tagged elsewhere shows up
after the next `git fetch`. `--tag` and `--next` are refused with `--user`,
since a user item surfaces in every repository and the tag or the work in
progress belongs to one.

A condition that is neither a date nor a tag ("once the API team replies") is
parked plain, in the user's words. Nothing can check it, so nothing pretends to.

A reminder whose date or tag has not arrived stays out of the digest and the
band, counted on one line as waiting. It still appears in `list`, marked
`, waiting` inside its `(when: ...)`, so it can be marked `done` early.

## Commands

Run the bundled script as `sh "${CLAUDE_SKILL_DIR}/parking-lot.sh" <command>`.
`${CLAUDE_SKILL_DIR}` resolves to this skill's folder; the working directory at
run time is the project root, not this folder. Every command except `show`
acts on this repository's store, or on the user store with `--user`.

| Command | What it does |
|---|---|
| `add <text>` | Park a thought; with `--user`, tagged with the repo it arrived in |
| `add --next <text>` | Park it for the next stopping point |
| `add --on <YYYY-MM-DD> <text>` | Park it as a reminder for that date |
| `add --tag <tag> <text>` | Park it as a reminder for when that tag exists |
| `list` | Numbered open items; `--all` lists both stores, user items prefixed `u` |
| `done <n>` | Mark item *n* handled |
| `reopen <handled-line> <line>` | Put back an item marked done: `<handled-line>` is the line `done` printed, `<line>` the item's line from `list` |
| `plain <n>` | Drop item *n*'s `(when: ...)`, leaving it an ordinary parked item |
| `maybe <n> <why>` | Mark item *n* *possibly* handled, recording what suggests it |
| `show` | The digest the SessionStart hook gives the model, both stores |
| `path` | Where the store lives |

**`${CLAUDE_SKILL_DIR}` is a Claude Code substitution.** A host that does not
provide it leaves it empty, turning every command above into `sh "/parking-lot.sh"`.
Substitute the path of the folder this file is in. `INSTALL.md` beside this
file says which hosts that covers.

**`add` is the one command whose flags must come first.** Its text is free-form,
so a flag after the text is text: `add "a stray thought" --user` parks into the
*repository* store with `--user` glued onto the end of the thought. Nothing
complains; the scope `add` names back — `Parked (repo store, N open)` — is the
only cue. On every other command the flag may go anywhere, so `done 1 --user`
means what it looks like.

Item numbers shift as items are handled, so `list` before `done`, `plain` or
`maybe` rather than reusing a number from earlier in the session, and `done`
several items highest number first. **A number
means nothing without a scope**: each store numbers from 1, and `done`, `plain`
and `maybe` without `--user` always mean the repository. The digest prints no numbers at
all, so a number never comes from it — run a scoped `list`. `list --all`
prefixes user items with `u`, and `u2` means `done --user 2`.

`--all` is for `list` only; every other command refuses it. `--` ends the flags, for a thought or a reason that begins with one:
`add -- "--no-verify keeps biting us"`.

## Choosing the scope

Default to the repository store. Use `--user` when the thought is not about the
repository the session is in — the case where an idea about project B surfaces
while working in project A. That is the fragmenting case this skill exists for,
and it has nowhere else to go.

When it is genuinely ambiguous, park it against the repository. A
repository-scoped item is seen more often, and being seen is the point.

## Where it is stored

`path` prints the store in use. Handled items stay in that file, marked `[x]`,
so "did I already park this?" is answered by reading it.

On git older than 2.31 a repository-scoped `add` is refused; park with `--user`
instead.

## Resurfacing

Capture is worth nothing without this half. A store nothing ever reads is a
hole thoughts go into.

The mechanism is a `SessionStart` hook that runs `parking-lot.sh hook`, which
puts the digest in this context at the top of each session, and on the user's
screen when something is parked or a store cannot be read. **The context copy
always prints** — `Nothing parked, via the /parking-lot skill.` when both
stores are empty, and a line naming the reason where a store cannot be read —
so its presence is what says the hook ran.

Installed as part of the plugin, the hook is already declared and there is
nothing to set up. Installed by symlink or copy into `~/.claude/skills/`, it
has to be added by hand: `INSTALL.md` beside this file has both shapes.

**If nothing at all appeared in this context — no parked list, no
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

**Two exceptions, both because the user asked for them when parking.**

A reminder that has come due — a `(when: <date>)` or `(when: tag ...)` item in
the digest — is mentioned once, in one line, early in the session, and then
left alone.

A `(when: next)` item waits for a **good stopping point**: the piece of work in
progress is finished and the user is satisfied with it — they have approved it,
or it has been committed, a PR opened, or a branch merged, with nothing left
pending from them. Not mid-task, not while a review loop or a test run is still
going, and not while the user is still correcting the work. At that point:

1. Run a scoped `list`; the digest may be stale.
2. Ask once with `AskUserQuestion` which of its `(when: next)` items, if any,
   to pick up now, with an option to leave them parked.
3. Run `plain <n>` on every item offered and not picked, so it is never offered
   again.
4. Run `done <n>` on every picked item, highest number first: it has been
   handed to the work, which starts now.

Steps 3 and 4 go in that order because `plain` keeps the numbers `list` printed
and `done` shifts them. `(when: next)` items parked in an earlier session are
asked about the same way, at this session's first stopping point.

Beyond those, raise an item unprompted only when the current work runs directly
into it — the file being edited is the file an item names, or the change about
to be made would be shaped differently if the item were done. Then say which
item, in one sentence, and let the user decide. Everything else waits for them
to ask.

## Reconciling what got handled

Work sometimes covers a parked item without anybody noticing, and re-parking or
re-proposing something already done is its own kind of fragmentation.

When a piece of work finishes — a task completed, a PR opened, a branch merged
— compare what was actually done against the open items already in context: the
digest, and anything parked this session. This needs no search: both halves are
already known. For anything that looks handled:

1. Run a scoped `list` for its number; the digest prints none.
2. Mark it with `maybe <n> <why>`, recording what suggests it (`maybe 2 "the
   retry backoff commit on this branch"`).
3. Say so in one line so the user can correct it.

**Use `maybe`, not `done`, unless the user says outright that an item is
finished.** A false positive that quietly deletes an idea is worse than a stale
line, because the user never finds out it happened. `maybe` leaves the item
visible, carrying the reason, for them to confirm or dismiss. Never delete an
item, and never silently drop one.

`done` is for explicit instructions — the user saying an item is handled, or
asking to clear it, or picking it up at a stopping point. If the user says an
item just marked `done` is not finished after all, `reopen` it with the line
`done` printed and the item's line from the `list` you ran before it.
