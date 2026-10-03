import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const PANE_PROPS = {
  title: 'Later',
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

function engine(on: On, listing: () => string, inRepo = true, argvs: string[][] = []) {
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
        stdout: listing(),
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

function mountBand($: Engine, surface: 'terminal' | 'desktop' = 'terminal') {
  return $.ui.mount({ plugin: 'later', surface, component: 'AbovePrompt', props: BAND_PROPS })
}

test('shows parked items in the band above the prompt on every surface, without opening the pane', async ($, on) => {
  const argvs: string[][] = []
  const opened = engine(on, () => 'Parked in repo:\n  1. - [ ] 2026-10-03 first thought\n\n', true, argvs)

  await $.session.start(START)
  expect(argvs.map(a => [a[0], ...a.slice(2)])).toEqual([['/bin/sh', 'list', '--all']])
  expect(opened).toEqual([])

  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await mountBand($, surface)
    expect(await band.find({ type: 'Text', text: 'first thought' })).toBeDefined()
    await band.unmount()
  }
})

test('rows drop the dash and date, show the origin repo and a glyph, and expand when the number is pressed', async ($, on) => {
  engine(
    on,
    () =>
      'Parked (user):\n' +
      '  u1. - [~] 2026-10-01 (from wakey) [tag] a long thought -- possibly handled by PR #4\n' +
      '  u2. - [ ] 2026-10-02 (from wakey) another thought\n\n' +
      'Mark a u-prefixed item with --user: later.sh done --user <n>\n',
  )

  await $.session.start(START)
  const band = await mountBand($)
  expect(await band.find({ type: 'Text', text: /2026-10-0|- \[|Mark a u-prefixed/ })).toBeUndefined()
  expect(await band.findAll({ type: 'Text', text: 'from wakey' })).toHaveLength(1)
  expect(await band.find({ type: 'Text', text: '◐' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: '○' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: '[tag] a long thought' })).toBeDefined()
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
  expect('u1. ○ from wakey  '.length + (body?.text.length ?? 999)).toBeLessThanOrEqual(BAND_PROPS.bodyColumns)
  await band.unmount()
})

test('/later-pane opens the side pane with the listing', async ($, on) => {
  const opened = engine(on, () => 'Parked in repo:\n  1. - [ ] 2026-10-03 first thought\n')

  await $.session.start(START)
  await $.command.run({
    command: 'later-pane',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 120 },
  })
  expect(opened).toEqual(['later'])
  const pane = await $.ui.mount({
    plugin: 'later',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'later',
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
  expect(`${gitCwd}/later.sh`).toBe(script)
})

test('a shell that fails to run later.sh shows an error, not its output as the listing', async ($, on) => {
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
    plugin: 'later',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'later',
    props: PANE_PROPS,
  })
  expect(await ui.find({ type: 'Text', text: /^later: could not run later\.sh -- exit 1/ })).toBeDefined()
  await ui.unmount()
})

test('strips terminal control sequences from parked text', async ($, on) => {
  engine(on, () => 'Parked in repo:\n  1. - [ ] 2026-10-03 \u001b]52;c;cGF5bG9hZA==\u0007evil \u001b[2Jthought\n')

  await $.session.start(START)
  const ui = await $.ui.mount({
    plugin: 'later',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'later',
    props: PANE_PROPS,
  })
  expect(await ui.find({ type: 'Text', text: /\u001b|\u0007/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'thought' })).toBeDefined()
  await ui.unmount()
})

test('a Bash call running later.sh refreshes the listing', async ($, on) => {
  let listing = 'Nothing parked.\n'
  engine(on, () => listing)
  on('tool.call', async () => ({
    result: { stdout: '', stderr: '', interrupted: false },
  }))

  await $.session.start(START)
  listing = 'Parked in repo:\n  1. - [ ] 2026-10-03 new thought\n'
  await $.tool.call({ tool: 'Bash', command: 'sh later.sh add new thought' })

  const ui = await $.ui.mount({
    plugin: 'later',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'later',
    props: PANE_PROPS,
  })
  expect(await ui.find({ type: 'Text', text: 'new thought' })).toBeDefined()
  await ui.unmount()
})
