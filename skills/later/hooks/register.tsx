import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

const PANE = 'later'
const NOTHING = 'Nothing parked.'
const listing = atom({ plugin: 'later', key: 'listing' } as const, '')

async function shell($: EngineInterface) {
  if ((await $.env.get('OS')) !== 'Windows_NT') return '/bin/sh'
  // Native Windows has no /bin/sh; Git for Windows ships one beside its exec path.
  const git = await $.process.run(['git', '--exec-path'], { cwd: $.plugin.root })
  return git.stdout.trim().replace(/\/[^/]+\/libexec\/git-core$/, '/bin/sh.exe')
}

async function runList($: EngineInterface) {
  const scope = (await $.session.repo().catch(() => true)) ? '--all' : '--user'
  return $.process.run([await shell($), `${$.plugin.root}/later.sh`, 'list', scope])
}

async function refresh($: EngineInterface) {
  let text: string
  try {
    const ran = await runList($)
    if (ran.exitCode !== 0) throw new Error(`exit ${ran.exitCode} ${ran.stderr}`)
    text = (ran.stdout + ran.stderr).replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, '').trim()
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err)
    text = `later: could not run later.sh -- ${why}`.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').trim()
  }
  await update($, listing, () => text)
}

export const register: Register = on => {
  let openedUnasked = false

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'later-pane',
      description: 'Show parked /later thoughts in a pane',
    })
    await refresh($)
    openedUnasked = (await read($, listing)) !== NOTHING
    if (openedUnasked) void $.ui.open({ id: PANE, title: 'Later' })

    return next(e)
  })

  on('command.run', { command: 'later-pane' }, async $ => {
    openedUnasked = false
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
    if (openedUnasked && e.props.placement === 'inline') {
      openedUnasked = false
      void $.ui.close({ id: PANE })
      return <Box />
    }
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
