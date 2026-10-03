import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

const PANE = 'later'
const NOTHING = 'Nothing parked.'
const HANDLED = ' -- possibly handled by '
const listing = atom({ plugin: 'later', key: 'listing' } as const, '')
const expanded = atom({ plugin: 'later', key: 'expanded' } as const, [])

type Row =
  | { id: string; isMaybe: boolean; origin: string; body: string; reason: string }
  | { text: string }

function parseRow(line: string): Row {
  const m = /^\s+(u?\d+)\. - \[([ ~])\] \d{4}-\d{2}-\d{2} (?:\(from ([^)]*)\) )?(.*)$/.exec(line)
  if (!m) return { text: line.trim() }
  const [, id = '', mark, origin = '', rest = ''] = m
  const cut = mark === '~' ? rest.lastIndexOf(HANDLED) : -1
  return {
    id,
    isMaybe: mark === '~',
    origin: origin === '' ? '' : `from ${origin}`,
    body: cut < 0 ? rest : rest.slice(0, cut),
    reason: cut < 0 ? '' : rest.slice(cut + HANDLED.length),
  }
}

function rows(text: string) {
  return text
    .split('\n')
    .filter(line => line.trim() !== '' && !line.startsWith('Mark a u-prefixed item'))
    .map(parseRow)
}

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
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'later-pane',
      description: 'Show parked /later thoughts in a pane',
    })
    await refresh($)

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

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const text = await read($, listing)
    if (e.props.hasSurvey || text === '' || text === NOTHING) return next(e)
    const open = await read($, expanded)
    const { Box, Button, Text } = $.ui.resolve(e)
    const toggle = (id: string) =>
      update($, expanded, ids => (ids.includes(id) ? ids.filter(one => one !== id) : [...ids, id]))

    return (
      <Box flexDirection="column">
        <Text bold>Parked thoughts (/later)</Text>
        {rows(text).map(row => {
          if ('text' in row) return <Text dimColor>{row.text}</Text>
          const isOpen = open.includes(row.id)
          const room = e.props.bodyColumns - `${row.id}. ◐ ${row.origin}  `.length - 1
          const body = isOpen || row.body.length <= room ? row.body : `${row.body.slice(0, Math.max(0, room - 1))}…`
          return (
            <Box flexDirection="column">
              <Box flexDirection="row">
                <Button key={`item-${row.id}`} plain onPress={() => toggle(row.id)}>
                  {`${row.id}.`}
                </Button>
                <Text> {row.isMaybe ? '◐' : '○'} </Text>
                {row.origin !== '' && <Text dimColor>{row.origin}  </Text>}
                <Text wrap={isOpen ? 'wrap' : 'truncate-end'}>{body}</Text>
              </Box>
              {isOpen && row.reason !== '' && <Text dimColor>{`    possibly handled: ${row.reason}`}</Text>}
            </Box>
          )
        })}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {rows(await read($, listing)).map(row =>
          'text' in row ? (
            <Text dimColor>{row.text}</Text>
          ) : (
            <Box flexDirection="column">
              <Text>
                {`${row.id}. ${row.isMaybe ? '◐' : '○'} `}
                {row.origin !== '' && `${row.origin}  `}
                {row.body}
              </Text>
              {row.reason !== '' && <Text dimColor>{`    possibly handled: ${row.reason}`}</Text>}
            </Box>
          ),
        )}
      </Box>
    )
  })
}
