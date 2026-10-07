import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const PANE_PROPS = {
  title: 'Parking lot',
  isFocused: false,
  bodyColumns: 60,
  placement: 'dock',
  scroll: { offset: 0, bodyRows: 20 },
  view: {},
} as const

const BAND_PROPS = {
  hasSurvey: false,
  isWorking: false,
  maxRows: 10,
  bodyColumns: 120,
  scroll: { offset: 0, bodyRows: 10 },
  view: {},
} as const

const REPO_INFO = { root: '/repo', remote: null, internal: false, name: null, id: 'repo' }

const START = { cwd: '/repo', surface: 'terminal', isInteractive: true } as const

function engine(on: On, listing: (args: string[]) => string, inRepo = true, argvs: string[][] = []) {
  const opened: string[] = []
  on('session.start', async (_$, e) => ({ cwd: e.cwd }))
  on('env.get', async () => ({ value: undefined }))
  on('session.repo', async () => ({
    value: inRepo ? REPO_INFO : null,
  }))
  on('command.register', async (_$, e) => ({ value: { command: e.name } }))
  on('process.run', async (_$, e) => {
    argvs.push([...e.argv])
    return {
      value: {
        exitCode: 0,
        stdout: listing(e.argv.slice(2)),
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  on('ui.open', async (_$, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.render', { component: 'AbovePrompt' }, async ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
  return opened
}

function mountBand<S extends 'terminal' | 'desktop' | 'mobile' = 'terminal'>($: Engine, surface?: S) {
  return $.ui.mount({ plugin: 'parking-lot', surface: surface ?? ('terminal' as S), component: 'AbovePrompt', props: BAND_PROPS })
}

test('shows parked items in the band above the prompt on every surface, without opening the pane', async ($, on) => {
  const argvs: string[][] = []
  const opened = engine(on, () => 'Parked in repo:\n  1. - [ ] 2026-10-03 first thought\n\n', true, argvs)

  await $.session.start(START)
  expect(argvs.map(a => [a[0], ...a.slice(2)])).toEqual([['/bin/sh', 'list', '--all']])
  expect(opened).toEqual([])

  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await mountBand($, surface)
    const client = surface === 'desktop' ? await band.find({ type: 'Client' }) : undefined
    const scope = client?.key === undefined ? {} : { in: client.key }
    expect(await band.find({ type: 'Text', text: 'first thought', ...scope })).toBeDefined()
    await band.unmount()
  }
})

test('rows are checklist items labelled with the id done takes, without dash or date, show the origin repo, and expand on the arrow', async ($, on) => {
  engine(
    on,
    () =>
      'Parked (user):\n' +
      '  u1. - [~] 2026-10-01 (from alpha) [tag] a long thought -- possibly handled by PR #4\n' +
      '  u2. - [ ] 2026-10-02 (from beta) another thought\n' +
      '  u3. - [ ] 2026-10-03 (from gamma) [see notes] third thought\n\n' +
      'Mark a u-prefixed item with --user: parking-lot.sh done --user <n>\n',
  )

  await $.session.start(START)
  const band = await mountBand($)
  expect(await band.find({ type: 'Text', text: /2026-10-0|- \[|Mark a u-prefixed|^Parked/ })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'from alpha' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'from beta' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: 'from gamma' })).toBeDefined()
  expect(await band.findAll({ type: 'Button', text: '▢' })).toHaveLength(3)
  expect((await band.findAll({ type: 'Text', text: /^ {2}u\d: $/ })).map(found => found.text)).toEqual(['  u1: ', '  u2: ', '  u3: '])
  expect((await band.find({ type: 'Text', text: '[tag] a long thought' }))?.props).toMatchObject({ italic: true })
  expect((await band.find({ type: 'Text', text: 'another thought' }))?.props.italic).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'possibly handled: PR #4' })).toBeUndefined()

  await band.press({ key: 'item-u1' })
  expect(await band.find({ type: 'Text', text: 'possibly handled: PR #4' })).toBeDefined()
  await band.press({ key: 'item-u1' })
  expect(await band.find({ type: 'Text', text: 'possibly handled: PR #4' })).toBeUndefined()
  await band.unmount()
})

test('a collapsed row fits the band width, so it never wraps onto a second line', async ($, on) => {
  engine(on, () => `Parked (user):\n  u1. - [ ] 2026-10-01 (from wakey) ${'x'.repeat(300)}\n`)

  await $.session.start(START)
  const band = await mountBand($)
  const body = await band.find({ type: 'Text', text: /x…$/ })
  expect(body).toBeDefined()
  expect('││ ▢  u1: from wakey  ▸'.length + (body?.text.length ?? 999)).toBeLessThanOrEqual(BAND_PROPS.bodyColumns)
  await band.unmount()
})

test('/parking-lot-pane opens the side pane with the listing', async ($, on) => {
  const opened = engine(on, () => 'Parked in repo:\n  1. - [ ] 2026-10-03 first thought\n')

  await $.session.start(START)
  await $.command.run({
    command: 'parking-lot-pane',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 120 },
  })
  expect(opened).toEqual(['parking-lot'])
  const pane = await $.ui.mount({
    plugin: 'parking-lot',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'parking-lot',
    props: PANE_PROPS,
  })
  expect(await pane.find({ type: 'Text', text: 'first thought' })).toBeDefined()
  await pane.unmount()
})

test('shows no band when nothing is parked', async ($, on) => {
  engine(on, () => 'Nothing parked.\n')

  await $.session.start(START)
  const band = await mountBand($)
  expect(await band.find({ type: 'Text', text: /Parked|Nothing/ })).toBeUndefined()
  await band.unmount()
})

test('lists only the user store outside a repository', async ($, on) => {
  const argvs: string[][] = []
  engine(on, () => 'Nothing parked.\n', false, argvs)

  await $.session.start(START)
  expect(argvs.map(a => a.slice(2))).toEqual([['list', '--user']])
})

test('on Windows runs the sh.exe beside git, resolving git from the plugin folder', async ($, on) => {
  const ran: string[] = []
  let gitCwd: string | undefined
  let script: string | undefined
  on('session.start', async (_$, e) => ({ cwd: e.cwd }))
  on('command.register', async (_$, e) => ({ value: { command: e.name } }))
  on('ui.open', async () => ({ value: { isPlaced: true } }))
  on('session.repo', async () => ({ value: REPO_INFO }))
  on('env.get', async (_$, e) => ({ value: e.name === 'OS' ? 'Windows_NT' : undefined }))
  on('process.run', async (_$, e) => {
    const exe = e.argv[0] ?? ''
    ran.push(exe)
    if (exe === 'git') gitCwd = e.init?.cwd
    else script = e.argv[1]
    const stdout =
      exe === 'git'
        ? 'C:/Program Files/Git/mingw64/libexec/git-core\n'
        : 'Parked in repo:\n  1. - [ ] 2026-10-03 via git sh\n'
    return {
      value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })

  await $.session.start(START)
  expect(ran).toEqual(['git', 'C:/Program Files/Git/bin/sh.exe'])
  expect(gitCwd).toBeDefined()
  expect(`${gitCwd}/parking-lot.sh`).toBe(script)
})

test('a shell that fails to run parking-lot.sh shows an error, not its output as the listing', async ($, on) => {
  on('session.start', async (_$, e) => ({ cwd: e.cwd }))
  on('command.register', async (_$, e) => ({ value: { command: e.name } }))
  on('ui.open', async () => ({ value: { isPlaced: true } }))
  on('session.repo', async () => ({ value: REPO_INFO }))
  on('env.get', async () => ({ value: undefined }))
  on('process.run', async () => ({
    value: {
      exitCode: 1,
      stdout: '',
      stderr: 'The system cannot find the path specified.',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))

  await $.session.start(START)
  const ui = await $.ui.mount({
    plugin: 'parking-lot',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'parking-lot',
    props: PANE_PROPS,
  })
  expect(await ui.find({ type: 'Text', text: /^parking-lot: could not run parking-lot\.sh -- exit 1/ })).toBeDefined()
  await ui.unmount()
})

test('strips terminal control sequences from parked text', async ($, on) => {
  engine(on, () => 'Parked in repo:\n  1. - [ ] 2026-10-03 \u001b]52;c;cGF5bG9hZA==\u0007evil \u001b[2Jthought\n')

  await $.session.start(START)
  const ui = await $.ui.mount({
    plugin: 'parking-lot',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'parking-lot',
    props: PANE_PROPS,
  })
  expect(await ui.find({ type: 'Text', text: /\u001b|\u0007/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'thought' })).toBeDefined()
  await ui.unmount()
})

test('a Bash call running parking-lot.sh refreshes the listing', async ($, on) => {
  let listing = 'Nothing parked.\n'
  engine(on, () => listing)
  on('tool.call', async () => ({
    result: { stdout: '', stderr: '', interrupted: false },
  }))

  await $.session.start(START)
  listing = 'Parked in repo:\n  1. - [ ] 2026-10-03 new thought\n'
  await $.tool.call({ tool: 'Bash', command: 'sh parking-lot.sh add new thought' })

  const ui = await $.ui.mount({
    plugin: 'parking-lot',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'parking-lot',
    props: PANE_PROPS,
  })
  expect(await ui.find({ type: 'Text', text: 'new thought' })).toBeDefined()
  await ui.unmount()
})

const REMINDERS =
  'Parked in repo:\n' +
  '  1. - [ ] 2026-10-01 (when: next) after this work\n' +
  '  2. - [ ] 2026-10-01 (when: 2000-01-01) overdue thing\n' +
  '  3. - [ ] 2026-10-01 (when: 2999-01-01, waiting) far future thing\n' +
  '  4. - [ ] 2026-10-01 (when: tag v12.2) after release thing\n' +
  '  5. - [ ] 2026-10-01 (when: tag v13, waiting) unreleased thing\n'

test('the band labels reminders and hides the ones the listing marks waiting', async ($, on) => {
  engine(on, () => REMINDERS)

  await $.session.start(START)
  const band = await mountBand($)
  expect(await band.find({ type: 'Text', text: 'next  ' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: 'due 2000-01-01  ' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: 'after v12.2  ' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: 'overdue thing' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: 'far future thing' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'unreleased thing' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: /\(when:/ })).toBeUndefined()
  await band.unmount()
})

test('the pane lists waiting reminders, labelled without the waiting marker', async ($, on) => {
  engine(on, () => REMINDERS)

  await $.session.start(START)
  const pane = await $.ui.mount({
    plugin: 'parking-lot',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'parking-lot',
    props: PANE_PROPS,
  })
  expect(await pane.find({ type: 'Text', text: /after v13 {2}unreleased thing/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: /waiting/ })).toBeUndefined()
  await pane.unmount()
})

test('no band when every parked item is waiting', async ($, on) => {
  engine(on, () => 'Parked in repo:\n  1. - [ ] 2026-10-01 (when: tag v13, waiting) unreleased thing\n')

  await $.session.start(START)
  const band = await mountBand($)
  expect(await band.find({ type: 'Text', text: /Parking lot|Parked/ })).toBeUndefined()
  await band.unmount()
})

test('opening or merging a PR toasts the items parked for after the current work', async ($, on) => {
  const toasts: string[] = []
  engine(on, () => REMINDERS)
  on('ui.toast', async (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('tool.call', async () => ({
    result: { stdout: '', stderr: '', interrupted: false },
  }))

  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'git status' })
  expect(toasts).toEqual([])
  await $.tool.call({ tool: 'Bash', command: 'gh pr create --fill' })
  expect(toasts).toEqual(['Parked for after this: after this work'])
})

function fakeStores(repo: string[], user: string[] = []) {
  const stores = {
    repo: repo.map(line => ({ line, isDone: false })),
    user: user.map(line => ({ line, isDone: false })),
  }
  const open = (store: 'repo' | 'user') => stores[store].filter(one => !one.isDone)
  const handledOf = (line: string) => {
    const cut = line.lastIndexOf(' -- possibly handled by ')
    const body = line.startsWith('- [~]') && cut >= 0 ? line.slice(0, cut) : line
    return body.replace(/^- \[.\]/, '- [x]')
  }
  const section = (heading: string, store: 'repo' | 'user', prefix: string) =>
    open(store).length === 0
      ? ''
      : `${heading}:\n${open(store)
          .map((one, i) => `  ${prefix}${i + 1}. ${one.line}\n`)
          .join('')}\n`
  return (args: string[]) => {
    const store = args.includes('--user') ? 'user' : 'repo'
    const [cmd, a = '', b = ''] = args.filter(arg => arg !== '--user')
    if (cmd === 'done') {
      const one = open(store)[Number(a) - 1]
      if (one === undefined) return ''
      one.isDone = true
      return handledOf(one.line)
    }
    if (cmd === 'reopen') {
      const one = stores[store].find(x => x.isDone && handledOf(x.line) === a)
      if (one === undefined) return ''
      one.isDone = false
      one.line = b
      return b
    }
    const text =
      args[1] === '--user'
        ? section('Parked (user)', 'user', '')
        : section('Parked in repo', 'repo', '') + section('Parked (user)', 'user', 'u')
    return text === '' ? 'Nothing parked.\n' : text
  }
}

function scriptCalls(argvs: string[][]) {
  return argvs.map(a => a.slice(2)).filter(a => a[0] !== 'list')
}

const FIRST = '- [ ] 2026-10-01 first thought'
const SECOND = '- [~] 2026-10-02 second thought -- possibly handled by PR #9'

test('checking an item marks it done at once and leaves it in place, checked and struck through', async ($, on) => {
  const argvs: string[][] = []
  engine(on, fakeStores([FIRST, SECOND, '- [ ] 2026-10-03 third thought']), true, argvs)

  await $.session.start(START)
  const band = await mountBand($)
  await band.press({ key: 'check-2' })
  expect(scriptCalls(argvs)).toEqual([['done', '2']])
  const texts = (await band.findAll({ type: 'Text', text: /thought$/ })).map(found => found.text)
  expect(texts).toEqual(['first thought', 'second thought', 'third thought'])
  expect(await band.find({ type: 'Text', text: /^Parked/ })).toBeUndefined()
  expect((await band.find({ type: 'Text', text: 'second thought' }))?.props).toMatchObject({ strikethrough: true })
  expect(await band.findAll({ type: 'Button', text: '▣' })).toHaveLength(1)
  expect((await band.findAll({ type: 'Text', text: /^ {2}\d: $/ })).map(found => found.text)).toEqual(['  1: ', '  2: '])
  await band.unmount()
})

test('a checked item is gone the next time the list is shown', async ($, on) => {
  engine(on, fakeStores([FIRST, SECOND]))

  await $.session.start(START)
  let band = await mountBand($)
  await band.press({ key: 'check-1' })
  await band.unmount()

  await $.session.start(START)
  band = await mountBand($)
  expect(await band.find({ type: 'Text', text: 'first thought' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'second thought' })).toBeDefined()
  await band.unmount()
})

test('unchecking reopens the item as it was, possibly-handled reason included', async ($, on) => {
  const argvs: string[][] = []
  engine(on, fakeStores([FIRST, SECOND]), true, argvs)

  await $.session.start(START)
  const band = await mountBand($)
  await band.press({ key: 'check-2' })
  await band.press({ key: 'check-x0' })
  expect(scriptCalls(argvs)).toEqual([
    ['done', '2'],
    ['reopen', '- [x] 2026-10-02 second thought', SECOND],
  ])
  expect(await band.findAll({ type: 'Button', text: '▣' })).toHaveLength(0)
  expect((await band.find({ type: 'Text', text: 'second thought' }))?.props).toMatchObject({ italic: true })
  await band.unmount()
})

test('the band stays while every item shown is checked', async ($, on) => {
  engine(on, fakeStores([FIRST]))

  await $.session.start(START)
  const band = await mountBand($)
  await band.press({ key: 'check-1' })
  expect(await band.find({ type: 'Text', text: 'first thought' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: NOTHING_PARKED })).toBeUndefined()
  await band.unmount()
})

const NOTHING_PARKED = 'Nothing parked.'

for (const [where, inRepo, key] of [
  ['inside a repository', true, 'check-u1'],
  ['outside one', false, 'check-1'],
] as const) {
  test(`a user item is marked done in the user store, ${where}`, async ($, on) => {
    const argvs: string[][] = []
    engine(on, fakeStores([FIRST], ['- [ ] 2026-10-01 (from alpha) user thought']), inRepo, argvs)

    await $.session.start(START)
    const band = await mountBand($)
    await band.press({ key })
    expect(scriptCalls(argvs)).toEqual([['done', '--user', '1']])
    await band.unmount()
  })
}

test('on the desktop the whole row is the control: a click anywhere on it checks the item, and unchecking keeps the same row', async ($, on) => {
  const argvs: string[][] = []
  engine(on, fakeStores([FIRST, SECOND]), true, argvs)

  await $.session.start(START)
  const band = await mountBand($, 'desktop')
  const [first] = await band.findAll({ type: 'Client' })
  const key = first?.key ?? ''
  expect(await band.find({ type: 'Button', text: '▢' })).toBeUndefined()
  await band.pointer({ type: 'down', x: 12, y: 0, button: 'left', in: key })
  expect(scriptCalls(argvs)).toEqual([['done', '1']])
  expect((await band.find({ type: 'Text', text: 'first thought', in: key }))?.props).toMatchObject({
    strikethrough: true,
  })
  await band.pointer({ type: 'down', x: 12, y: 0, button: 'left', in: key })
  expect((await band.findAll({ type: 'Client' })).map(found => found.key)[0]).toBe(key)
  expect((await band.find({ type: 'Text', text: 'first thought', in: key }))?.props.strikethrough).toBeUndefined()
  await band.unmount()
})

test('the pane rows are checklist items too', async ($, on) => {
  const argvs: string[][] = []
  engine(on, fakeStores([FIRST, SECOND]), true, argvs)

  await $.session.start(START)
  const pane = await $.ui.mount({
    plugin: 'parking-lot',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'parking-lot',
    props: PANE_PROPS,
  })
  await pane.press({ key: 'check-1' })
  expect(scriptCalls(argvs)).toEqual([['done', '1']])
  expect((await pane.find({ type: 'Text', text: /first thought$/ }))?.props).toMatchObject({ strikethrough: true })
  await pane.unmount()
})

test('on the mobile app the rows are checkboxes that mark an item done', async ($, on) => {
  const argvs: string[][] = []
  engine(on, fakeStores([FIRST, SECOND]), true, argvs)

  await $.session.start(START)
  const band = await mountBand($, 'mobile')
  await band.press({ key: 'check-1' })
  expect(scriptCalls(argvs)).toEqual([['done', '1']])
  expect(await band.find({ type: 'Button', text: '▣' })).toBeDefined()
  await band.unmount()
})

test('checks made in quick succession each mark the item that was clicked', async ($, on) => {
  const argvs: string[][] = []
  engine(on, fakeStores([FIRST, '- [ ] 2026-10-02 middle thought', '- [ ] 2026-10-03 third thought']), true, argvs)

  await $.session.start(START)
  const band = await mountBand($)
  await Promise.all([band.press({ key: 'check-1' }), band.press({ key: 'check-3' })])
  expect(scriptCalls(argvs)).toEqual([
    ['done', '1'],
    ['done', '2'],
  ])
  expect((await band.find({ type: 'Text', text: 'first thought' }))?.props).toMatchObject({ strikethrough: true })
  expect((await band.find({ type: 'Text', text: 'third thought' }))?.props).toMatchObject({ strikethrough: true })
  expect((await band.find({ type: 'Text', text: 'middle thought' }))?.props.strikethrough).toBeUndefined()
  await band.unmount()
})

test('checking rows from the top down keeps them in their places', async ($, on) => {
  engine(on, fakeStores([FIRST, '- [ ] 2026-10-02 middle thought', '- [ ] 2026-10-03 third thought']))

  await $.session.start(START)
  const band = await mountBand($)
  await band.press({ key: 'check-1' })
  await band.press({ key: 'check-1' })
  const texts = (await band.findAll({ type: 'Text', text: /thought$/ })).map(found => found.text)
  expect(texts).toEqual(['first thought', 'middle thought', 'third thought'])
  expect((await band.find({ type: 'Text', text: 'middle thought' }))?.props).toMatchObject({ strikethrough: true })
  await band.unmount()
})
