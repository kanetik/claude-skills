import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'
import type { ParkingLotChecked } from '../types'

const PANE = 'parking-lot'
const NOTHING = 'Nothing parked.'
const HANDLED = ' -- possibly handled by '
const listing = atom({ plugin: 'parking-lot', key: 'listing' } as const, '')
const expanded = atom({ plugin: 'parking-lot', key: 'expanded' } as const, [])
const checked = atom({ plugin: 'parking-lot', key: 'checked' } as const, [])
const shellPath = atom({ plugin: 'parking-lot', key: 'shell' } as const, '')

type Item = {
  id: string
  line: string
  entry: string
  isUser: boolean
  isMaybe: boolean
  origin: string
  when: string
  body: string
  reason: string
  handled?: string
  isReopening?: boolean
  key?: string
}
type Row = Item | { text: string }

function parseRow(listed: string, isUser: boolean): Row {
  const m = /^\s+(u?\d+)\. (- \[([ ~])\] \d{4}-\d{2}-\d{2} (?:\(from ([^)]*)\) )?(?:\(when: ([^)]*)\) )?(.*))$/.exec(listed)
  if (!m) return { text: listed.trim() }
  const [, id = '', line = '', mark, origin = '', when = '', rest = ''] = m
  const cut = mark === '~' ? rest.lastIndexOf(HANDLED) : -1
  const body = cut < 0 ? rest : rest.slice(0, cut)
  return {
    id,
    line,
    entry: `${isUser ? 'user' : 'repo'}:${line}`,
    isUser,
    isMaybe: mark === '~',
    origin: origin === '' || /^\[[\w.-]+\]/.test(body) ? '' : `from ${origin}`,
    when,
    body,
    reason: cut < 0 ? '' : rest.slice(cut + HANDLED.length),
  }
}

const WAITING = ', waiting'

function isWaiting(item: Item) {
  return item.when.endsWith(WAITING)
}

function whenLabel(raw: string) {
  const when = raw.endsWith(WAITING) ? raw.slice(0, -WAITING.length) : raw
  if (when === '') return ''
  if (when === 'next') return 'next  '
  if (when.startsWith('tag ')) return `after ${when.slice(4)}  `
  return /^\d{4}-\d{2}-\d{2}$/.test(when) ? `due ${when}  ` : ''
}

function rows(text: string) {
  let isUser = false
  return text
    .split('\n')
    .filter(line => line.trim() !== '' && !line.startsWith('Mark a u-prefixed item'))
    .flatMap(line => {
      if (!line.startsWith('Parked')) return [parseRow(line, isUser)]
      isUser = line.startsWith('Parked (user)')
      return []
    })
}

async function shell($: EngineInterface) {
  const known = await read($, shellPath)
  if (known !== '') return known
  let found = '/bin/sh'
  if ((await $.env.get('OS')) === 'Windows_NT') {
    // Native Windows has no /bin/sh; Git for Windows ships one beside its exec path.
    const git = await $.process.run(['git', '--exec-path'], { cwd: $.plugin.root })
    found = git.stdout.trim().replace(/\/[^/]+\/libexec\/git-core$/, '/bin/sh.exe')
  }
  await update($, shellPath, () => found)
  return found
}

async function runScript($: EngineInterface, args: string[]) {
  return $.process.run([await shell($), `${$.plugin.root}/parking-lot.sh`, ...args])
}

async function runList($: EngineInterface) {
  const scope = (await $.session.repo().catch(() => true)) ? '--all' : '--user'
  return runScript($, ['list', scope])
}

async function refresh($: EngineInterface) {
  let text: string
  try {
    const ran = await runList($)
    if (ran.exitCode !== 0) throw new Error(`exit ${ran.exitCode} ${ran.stderr}`)
    text = (ran.stdout + ran.stderr).replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, '').trim()
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err)
    text = `parking-lot: could not run parking-lot.sh -- ${why}`.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').trim()
  }
  await update($, listing, () => text)
}

function setChecked($: EngineInterface, entry: string, change: Partial<ParkingLotChecked[number]> | undefined) {
  return update($, checked, done =>
    change === undefined
      ? done.filter(one => one.entry !== entry)
      : done.map(one => (one.entry === entry ? { ...one, ...change } : one)),
  )
}

let scriptTurn: Promise<void> = Promise.resolve()

function inTurn(work: () => Promise<void>) {
  const run = scriptTurn.then(work)
  scriptTurn = run.catch(() => undefined)
  return run
}

async function check($: EngineInterface, item: Item) {
  const shown = shownRows(await read($, listing), await read($, checked))
  const at = shown.findIndex(row => 'id' in row && row.entry === item.entry)
  await update($, checked, done => [...done, { entry: item.entry, handled: '', at }])
  return inTurn(async () => {
    await refresh($)
    const live = rows(await read($, listing)).find((row): row is Item => 'id' in row && row.entry === item.entry)
    const ran = live && (await runScript($, ['done', ...scopeFlag(live), live.id.replace(/^u/, '')]))
    if (ran === undefined || ran.exitCode !== 0) {
      await setChecked($, item.entry, undefined)
      $.ui.toast(`parking-lot: could not mark done -- ${ran?.stderr.trim() || 'the item changed'}`)
    } else {
      await setChecked($, item.entry, { handled: ran.stdout.trim() })
    }
    await refresh($)
  })
}

async function uncheck($: EngineInterface, item: Item & { handled: string }) {
  await setChecked($, item.entry, { isReopening: true })
  return inTurn(async () => {
    const ran = await runScript($, ['reopen', ...scopeFlag(item), item.handled, item.line])
    if (ran.exitCode !== 0) {
      await setChecked($, item.entry, { isReopening: false })
      $.ui.toast(`parking-lot: could not reopen -- ${ran.stderr.trim()}`)
      return
    }
    await refresh($)
    await setChecked($, item.entry, undefined)
  })
}

function scopeFlag(item: Item) {
  return item.isUser ? ['--user'] : []
}

function toggleChecked($: EngineInterface, item: Item) {
  if (item.handled === undefined) return check($, item)
  if (item.handled === '' || item.isReopening) return
  return uncheck($, { ...item, handled: item.handled })
}

function isChecked(item: Item) {
  return item.handled !== undefined && !item.isReopening
}

function shownRows(text: string, done: ParkingLotChecked) {
  const all = rows(text).filter(
    row => !('id' in row ? done.some(one => one.entry === row.entry) : done.length > 0 && row.text === NOTHING),
  )
  for (const [i, one] of [...done].sort((a, b) => a.at - b.at).entries()) {
    const isUser = one.entry.startsWith('user:')
    const row = parseRow(`  0. ${one.entry.slice('user:'.length)}`, isUser)
    if ('id' in row) {
      all.splice(Math.min(Math.max(one.at, 0), all.length), 0, {
        ...row,
        id: `x${i}`,
        handled: one.handled,
        isReopening: one.isReopening === true,
      })
    }
  }
  const used = new Map<string, number>()
  return all.map((row): Row => {
    if (!('id' in row)) return row
    let hash = 5381
    for (const ch of row.entry) hash = ((hash * 33) ^ ch.charCodeAt(0)) >>> 0
    const key = `row-${hash.toString(36)}`
    const seen = used.get(key) ?? 0
    used.set(key, seen + 1)
    return { ...row, key: seen === 0 ? key : `${key}-${seen}` }
  })
}

function bodyStyle(item: Item) {
  if (isChecked(item)) return { strikethrough: true, dimColor: true }
  return item.isMaybe ? { italic: true, dimColor: true } : {}
}

type Ui = ReturnType<EngineInterface['ui']['resolve']>

function desktopRow(ui: Ui, item: Item) {
  if (!('Client' in ui)) return null
  const { Box, Client } = ui
  return (
    <Box marginTop={1}>
      <Client
        key={item.key ?? item.id}
        module="./row.tsx"
        width="100%"
        props={{
          id: item.handled === undefined ? item.id : '',
          label: whenLabel(item.when),
          origin: item.origin,
          body: item.body,
          reason: item.reason,
          isChecked: isChecked(item),
          isMaybe: item.isMaybe,
        }}
      />
    </Box>
  )
}

function checkbox(ui: Ui, item: Item, onPress: () => void) {
  const { Button } = ui
  return (
    <Button key={`check-${item.id}`} plain onPress={onPress}>
      {isChecked(item) ? '▣' : '▢'}
    </Button>
  )
}

function idLabel(item: Item, width: number) {
  return `  ${(item.handled === undefined ? `${item.id}:` : '').padEnd(width + 1)} `
}

function idWidth(all: Row[]) {
  return Math.max(0, ...all.map(row => ('id' in row && row.handled === undefined ? row.id.length : 0)))
}

function card(ui: Ui, isDesktop: boolean, children: RenderChildren) {
  const { Box, Text } = ui
  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor="inactive"
      paddingX={isDesktop ? 2 : 1}
      paddingY={isDesktop ? 1 : 0}
    >
      <Text bold>Parking lot</Text>
      <Text dimColor>Check an item off to mark it done.</Text>
      {children}
    </Box>
  )
}

function itemOf(text: string, done: ParkingLotChecked, element: string) {
  return shownRows(text, done).find((row): row is Item => 'id' in row && row.key === element)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await update($, checked, () => [])
    await $.command.register({
      name: 'parking-lot-pane',
      description: 'Show the parking lot in a pane',
    })
    await refresh($)

    return next(e)
  })

  on('command.run', { command: 'parking-lot-pane' }, async $ => {
    await inTurn(async () => {
      await update($, checked, () => [])
      await refresh($)
    })
    await $.ui.open({ id: PANE, title: 'Parking lot' })

    return { text: 'Parking lot pane opened.' }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (e.tool !== 'Bash') return ran
    if (e.command.includes('parking-lot.sh')) await refresh($)
    if (/\bgh\s+pr\s+(create|merge)\b/.test(e.command)) {
      const upNext = rows(await read($, listing)).filter((row): row is Item => 'id' in row && row.when === 'next')
      if (upNext.length > 0) {
        $.ui.toast(`Parked for after this: ${upNext.map(row => row.body).join(' · ')}`, { timeoutMs: 10000 })
      }
    }

    return ran
  })

  on('ui.message', async ($, e, next) => {
    if (e.data !== 'toggle' || !e.element.startsWith('row-')) return next(e)
    const item = itemOf(await read($, listing), await read($, checked), e.element)
    if (item !== undefined) await toggleChecked($, item)

    return {}
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const text = await read($, listing)
    const all = shownRows(text, await read($, checked))
    const shown = all.filter(row => !('id' in row) || !isWaiting(row))
    const isEmpty = all.some(row => 'id' in row) ? !shown.some(row => 'id' in row) : text === NOTHING
    if (e.props.hasSurvey || text === '' || isEmpty) return next(e)
    const open = await read($, expanded)
    const ui = $.ui.resolve(e)
    const { Box, Button, Text } = ui
    const width = idWidth(shown)
    const toggle = (id: string) =>
      update($, expanded, ids => (ids.includes(id) ? ids.filter(one => one !== id) : [...ids, id]))

    return card(
      ui,
      e.surface === 'desktop',
      shown.map(row => {
        if ('text' in row) return <Text dimColor>{row.text}</Text>
        if (e.surface === 'desktop') return desktopRow(ui, row)
        const isOpen = open.includes(row.id)
        const label = whenLabel(row.when)
        const room = e.props.bodyColumns - `││ ▢${idLabel(row, width)}${label}${row.origin}  ▸`.length - 1
        const isCut = row.body.length > room
        const body = isOpen || !isCut ? row.body : `${row.body.slice(0, Math.max(0, room - 1))}…`
        return (
          <Box flexDirection="column">
            <Box flexDirection="row">
              {checkbox(ui, row, () => toggleChecked($, row))}
              <Text dimColor>{idLabel(row, width)}</Text>
              {label !== '' && <Text bold>{label}</Text>}
              {row.origin !== '' && <Text dimColor>{row.origin}  </Text>}
              <Box flexGrow={1}>
                <Text wrap={isOpen ? 'wrap' : 'truncate-end'} {...bodyStyle(row)}>
                  {body}
                </Text>
              </Box>
              {(isCut || row.reason !== '') && (
                <Button key={`item-${row.id}`} plain dimColor onPress={() => toggle(row.id)}>
                  {isOpen ? ' ▾' : ' ▸'}
                </Button>
              )}
            </Box>
            {isOpen && row.reason !== '' && <Text dimColor>{`  possibly handled: ${row.reason}`}</Text>}
          </Box>
        )
      }),
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Text } = ui

    const all = shownRows(await read($, listing), await read($, checked))
    const width = idWidth(all)

    return card(
      ui,
      e.surface === 'desktop',
      all.map(row => {
        if ('text' in row) return <Text dimColor>{row.text}</Text>
        if (e.surface === 'desktop') return desktopRow(ui, row)
        return (
          <Box flexDirection="column">
            <Box flexDirection="row">
              {checkbox(ui, row, () => toggleChecked($, row))}
              <Text dimColor>{idLabel(row, width)}</Text>
              <Box flexGrow={1}>
                <Text {...bodyStyle(row)}>
                  {whenLabel(row.when)}
                  {row.origin !== '' && `${row.origin}  `}
                  {row.body}
                </Text>
              </Box>
            </Box>
            {row.reason !== '' && <Text dimColor>{`  possibly handled: ${row.reason}`}</Text>}
          </Box>
        )
      }),
    )
  })
}
