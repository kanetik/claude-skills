import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

const PANE = 'later'
const NOTHING = 'Nothing parked.'
const listing = atom({ plugin: 'later', key: 'listing' } as const, '')

async function runList($: EngineInterface) {
  const args = [`${$.plugin.root}/later.sh`, 'list', '--all']
  try {
    return await $.process.run(['/bin/sh', ...args])
  } catch {
    // Native Windows has no /bin/sh; Git for Windows ships one beside its exec path.
    const git = await $.process.run(['git', '--exec-path'], { cwd: $.plugin.root })
    const sh = git.stdout.trim().replace(/\/[^/]+\/libexec\/git-core$/, '/bin/sh.exe')
    return $.process.run([sh, ...args])
  }
}

async function refresh($: EngineInterface) {
  let text: string
  try {
    const ran = await runList($)
    text = (ran.stdout + ran.stderr).replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, '').trim()
  } catch (err) {
    text = `later: could not run later.sh -- ${err instanceof Error ? err.message : String(err)}`
  }
  await update($, listing, () => text)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'later-pane',
      description: 'Show parked /later thoughts in a pane',
    })
    await refresh($)
    if ((await read($, listing)) !== NOTHING) void $.ui.open({ id: PANE, title: 'Later' })

    return next(e)
  })

  on('command.run', { command: 'later-pane' }, async $ => {
    await refresh($)
    await $.ui.open({ id: PANE, title: 'Later' })

    return { text: 'Later pane opened.' }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (e.tool === 'Bash' && e.command.includes('later.sh')) await refresh($)

    return ran
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const lines = (await read($, listing)).split('\n')

    return (
      <Box flexDirection="column">
        {lines.map(line => (
          <Text dimColor={!/^\s+u?\d+\. /.test(line)}>{line || ' '}</Text>
        ))}
      </Box>
    )
  })
}
