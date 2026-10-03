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
  return opened
}

test('opens the pane at start and shows the listing on every surface', async ($, on) => {
  const argvs: string[][] = []
  const opened = engine(on, () => 'Parked in repo:\n  1. 2026-10-03 first thought\n\n', true, argvs)

  await $.session.start(START)
  expect(argvs.map(a => [a[0], ...a.slice(2)])).toEqual([['/bin/sh', 'list', '--all']])
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

test('lists only the user store outside a repository, and stays closed when it is empty', async ($, on) => {
  const argvs: string[][] = []
  const opened = engine(on, () => 'Nothing parked.\n', false, argvs)

  await $.session.start(START)
  expect(argvs.map(a => a.slice(2))).toEqual([['list', '--user']])
  expect(opened).toEqual([])
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
        : 'Parked in repo:\n  1. 2026-10-03 via git sh\n'
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
