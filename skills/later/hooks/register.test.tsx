import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const PANE_PROPS = {
  title: 'Later',
  isFocused: false,
  bodyColumns: 60,
  placement: 'dock',
  scroll: { offset: 0, bodyRows: 20 },
  view: {},
} as const

const START = { cwd: '/repo', surface: 'terminal', isInteractive: true } as const

function engine(on: On, listing: () => string) {
  const opened: string[] = []
  on('session.start', async (_$, e) => ({ cwd: e.cwd }))
  on('command.register', async (_$, e) => ({ value: { command: e.name } }))
  on('process.run', async () => ({
    value: {
      exitCode: 0,
      stdout: listing(),
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))
  on('ui.open', async (_$, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  return opened
}

test('opens the pane at start and shows the listing on every surface', async ($, on) => {
  const opened = engine(on, () => 'Parked in repo:\n  1. 2026-10-03 first thought\n\n')

  await $.session.start(START)
  expect(opened).toEqual(['later'])

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'later',
      surface,
      component: 'Pane',
      requestId: 'later',
      props: PANE_PROPS,
    })
    expect(await ui.find({ type: 'Text', text: 'first thought' })).toBeDefined()
    await ui.unmount()
  }
})

test('stays closed at start when nothing is parked', async ($, on) => {
  const opened = engine(on, () => 'Nothing parked.\n')

  await $.session.start(START)
  expect(opened).toEqual([])
})

test('falls back to the sh.exe beside git, resolving git from the plugin folder', async ($, on) => {
  const ran: string[] = []
  let gitCwd: string | undefined
  let script: string | undefined
  on('session.start', async (_$, e) => ({ cwd: e.cwd }))
  on('command.register', async (_$, e) => ({ value: { command: e.name } }))
  on('ui.open', async () => ({ value: { isPlaced: true } }))
  on('process.run', async (_$, e) => {
    const exe = e.argv[0] ?? ''
    ran.push(exe)
    if (exe === '/bin/sh') {
      script = e.argv[1]
      return { deny: 'not found' }
    }
    if (exe === 'git') gitCwd = e.init?.cwd
    const stdout =
      exe === 'git'
        ? 'C:/Program Files/Git/mingw64/libexec/git-core\n'
        : 'Parked in repo:\n  1. 2026-10-03 via git sh\n'
    return {
      value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })

  await $.session.start(START)
  expect(ran).toEqual(['/bin/sh', 'git', 'C:/Program Files/Git/bin/sh.exe'])
  expect(gitCwd).toBeDefined()
  expect(`${gitCwd}/later.sh`).toBe(script)
})

test('strips terminal control sequences from parked text', async ($, on) => {
  engine(on, () => 'Parked in repo:\n  1. 2026-10-03 \u001b]52;c;cGF5bG9hZA==\u0007evil \u001b[2Jthought\n')

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
  listing = 'Parked in repo:\n  1. 2026-10-03 new thought\n'
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
