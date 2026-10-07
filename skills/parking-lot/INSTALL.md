# Installing the `parking-lot` hook

The skill captures thoughts on its own. Resurfacing them needs a `SessionStart`
hook that runs `parking-lot.sh hook`, which shows parked items on screen at the top of
each session and gives the model the list. Without it the store is write-only.

## As part of the plugin

Nothing to do. The hook is declared in `.claude-plugin/plugin.json` and
`${CLAUDE_PLUGIN_ROOT}` resolves to the installed plugin.

If parked items never appear anyway, install by symlink or copy instead and wire
the hook by hand, as below. **Do not edit the hook in the plugin's own cache
directory**: that path is version-stamped, so the edit works until the next
plugin update and then stops, silently and for good.

What the manual install buys is that the command becomes yours to change, so
change it — pasting the block below unaltered reproduces the plugin's own hook
verbatim, including the two things most likely to have been the problem. Give
`sh` its full path (`/usr/bin/sh`, or your `sh.exe` — see Windows below), and
raise `timeout` past 5 seconds.

## By symlink or copy into `~/.claude/skills/`

Add the hook by hand, to **`<claude-config>/settings.json`** — the user-level
settings file, not the skill folder and not a file in the repository.
`<claude-config>` is `CLAUDE_CONFIG_DIR` where you have set it and `~/.claude`
otherwise. The block below spells out the default; where you have relocated the
config root, substitute it yourself in both places — the settings file you edit,
and the path inside the command, which is literal and expands nothing but
`$HOME`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"$HOME/.claude/skills/parking-lot/parking-lot.sh\" hook",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**Installed this when the skill was called `later`?** Three steps:

1. Delete `~/.claude/skills/later`, whether it is a link or a copy. A copy left
   in place is still a working skill that answers "park this", and what it
   parks lands in the old store.
2. Link or copy `parking-lot` under its new name, as above.
3. Replace the old hook's command with the one above. A hook still pointing at
   `skills/later/later.sh` fails silently once step 1 is done.

Parked items carry over: the script renames the old store the first time it
runs. Anything the old skill parks after that is named at the top of each
session until it is moved across by hand.

A project's own `.claude/settings.json` takes the same block and works, but the
digest then appears only in that project — including the user store, which is
the half meant to follow you between projects. That file is also committed, so
the hook ships to collaborators who do not have the skill installed and fails
for them at every session start; `.claude/settings.local.json` is the
uncommitted equivalent. Put it in `<claude-config>` unless you want it scoped
deliberately.

**Use a literal path. `${CLAUDE_PLUGIN_ROOT}` does not work here** — it is
substituted only for hooks a plugin declares itself. In your own settings there
is no plugin context, so it reaches the shell as an unset variable, expands to
empty, and the hook runs `sh "/skills/parking-lot/parking-lot.sh"` at every session start.

**Assume any mistake here is silent**, and there are three: the wrong file, a
wrong path, and `${CLAUDE_PLUGIN_ROOT}`. All three fail the same way — no error,
no digest.

### Windows

The bare `sh` resolves because hooks run in the Git Bash environment Claude
Code uses there — **not** because `sh` is on the Windows PATH, where a default
Git for Windows install does not put it. So `where sh` finding nothing says
nothing about the hook; running the command by hand to test it does need the
full path to `sh.exe`.

## The band and the pane

The folder is also a Claude Code mod (`.claude-plugin/` and `hooks/` here): it
lists what is parked in a band above the prompt (collapse it with its `[-]`),
leaving out reminders whose date or tag has not arrived; `/parking-lot-pane` opens the
whole list in a side pane; and opening or merging a PR with `gh` shows a toast
of the `--next` items. Installed by symlink or copy into
`~/.claude/skills/`, Claude Code loads it from there; `claude --plugin-dir
<this folder>` loads it for one session. The marketplace plugin does not load
it, so a plugin install gets the digest without the band or the pane.

## OpenCode and other hosts

OpenCode discovers this skill: it reads `~/.claude/skills/*/SKILL.md` and
`.claude/skills/<name>/SKILL.md` alongside its own locations, and ignores
frontmatter fields it does not know, so `allowed-tools` is harmless there.

Two things do not carry over.

**`${CLAUDE_SKILL_DIR}` is not substituted.** It is a Claude Code feature.
Everywhere else the commands in `SKILL.md` need the skill folder's own path
written out.

**Parked thoughts do not resurface on their own.** OpenCode does not read
`.claude-plugin/plugin.json`, and it has no session-start command hook — its
plugins are JavaScript on event handlers. So asking what is parked works, and
nothing else does: no digest at the top of a session, and with it none of the
behaviour that depends on parked items sitting in context — raising an item the
current work runs into, and reconciling what got handled when work finishes.
Porting that half means writing an OpenCode plugin that shells out to
`parking-lot.sh show`, which prints the same digest as plain text.
