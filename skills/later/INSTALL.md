# Installing the `later` hook

The skill captures thoughts on its own. Resurfacing them needs a `SessionStart`
hook that runs `later.sh show` and injects the digest at the top of each
session. Without it the store is write-only.

## As part of the plugin

Nothing to do. The hook is declared in `.claude-plugin/plugin.json` and
`${CLAUDE_PLUGIN_ROOT}` resolves to the installed plugin.

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
            "command": "sh \"$HOME/.claude/skills/later/later.sh\" show",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

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
empty, and the hook runs `sh "/skills/later/later.sh"` at every session start.

**Assume any mistake here is silent**, and there are three: the wrong file, a
wrong path, and `${CLAUDE_PLUGIN_ROOT}`. All three fail the same way — no error,
no digest.

The one check that settles it: the digest now prints on every session, whether
or not anything is parked. If the top of a session shows nothing at all — no
parked list, no `Nothing parked, via the /later skill.`, no unreachable-store
line — the hook is not running.

### Windows

The bare `sh` resolves because hooks run in the Git Bash environment Claude
Code uses there — **not** because `sh` is on the Windows PATH, where a default
Git for Windows install does not put it. So `where sh` finding nothing says
nothing about the hook; running the command by hand to test it does need the
full path to `sh.exe`.

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
`later.sh show`.
