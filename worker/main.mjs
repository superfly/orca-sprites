// The plugin's worker. The Sprites recipe runs as shell commands that cannot read plugin
// settings, so the worker writes them, with the PATH of your login shell, to a file the recipe
// reads: ~/.config/orca-sprites/settings.json (SPRITES_SETTINGS_FILE overrides the path, for
// tests only: Orca does not pass it to the worker, so setting it where Orca starts does nothing).
// The status bar item keeps this worker running while the plugin is on, so a change made in
// Settings reaches the file at once.

import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { chmod, mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { homedir, userInfo } from 'node:os'
import { dirname, join } from 'node:path'
import { checkpoint, cliEnv, forgetEntry, readRegistry, resolveSprite, spriteStates } from './sprites.mjs'

/** Settings keys, and the recipe variable each one sets. */
export const SETTINGS = {
  org: 'SPRITES_ORG',
  namePrefix: 'SPRITES_NAME_PREFIX',
  orcaVersion: 'SPRITES_ORCA_VERSION',
  projectRoot: 'SPRITES_PROJECT_ROOT',
  browser: 'SPRITES_BROWSER',
  keepAwake: 'SPRITES_KEEP_AWAKE'
}

export function settingsFile() {
  return process.env.SPRITES_SETTINGS_FILE || join(homedir(), '.config', 'orca-sprites', 'settings.json')
}

/** The recipe variables for the given setting values: strings trimmed, empty ones left out. */
export function toVariables(values) {
  const vars = {}
  for (const [key, name] of Object.entries(SETTINGS)) {
    const value = values[key]
    if (typeof value === 'boolean') {
      vars[name] = value ? '1' : '0'
    } else if (typeof value === 'string' && value.trim() !== '') {
      vars[name] = value.trim()
    }
  }
  return vars
}

/** Only absolute directories: the recipe runs in the repository, so `.`, an empty entry or a
 *  relative one would find commands from the repository first. */
export function absolutePath(path) {
  const dirs = String(path ?? '').split(':').filter((dir) => dir.startsWith('/'))
  return dirs.length > 0 ? [...new Set(dirs)].join(':') : null
}

/** The person's login shell. Orca does not pass SHELL to plugin workers, so read it from the
 *  user database. SPRITES_LOGIN_SHELL is for tests. */
export function loginShell() {
  if (process.env.SPRITES_LOGIN_SHELL) return process.env.SPRITES_LOGIN_SHELL
  try {
    const shell = userInfo().shell
    if (shell && shell.startsWith('/')) return shell
  } catch {}
  return process.env.SHELL || '/bin/zsh'
}

/** PATH from the person's login shell, so a recipe started by a Dock-launched Orca finds the
 *  sprite CLI and node. Null when the shell does not answer within 5 s.
 *  - The shell runs in its own session (detached) with no stdin or stderr, so an interactive
 *    shell never takes over the terminal Orca was started from.
 *  - Interactive shells ignore SIGTERM and an rc file may wait for input or start background
 *    programs, so the shell's whole process group gets SIGKILL once PATH has arrived or 5 s pass. */
export function loginShellPath(shell = loginShell()) {
  const mark = '__ORCA_SPRITES_PATH__'
  const pattern = new RegExp(`${mark}(.*?)${mark}`, 's')
  return new Promise((resolve) => {
    let out = ''
    let done = false
    let child
    // Answer as soon as the PATH has arrived: a program the rc file started in the background
    // may keep stdout open long after the shell exits. Then kill the whole process group, so no
    // such program is left running, whether the shell answered or timed out.
    const finish = (value) => {
      if (done) return
      done = true
      clearTimeout(timer)
      try {
        process.kill(-child.pid, 'SIGKILL')
      } catch {}
      child?.stdout?.destroy()
      resolve(value)
    }
    try {
      child = spawn(shell, ['-ilc', `printf '%s%s%s' ${mark} "$PATH" ${mark}`], {
        detached: true,
        stdio: ['ignore', 'pipe', 'ignore'],
        env: { ...process.env, TERM: 'dumb' }
      })
    } catch {
      return resolve(null)
    }
    const timer = setTimeout(() => finish(null), 5000)
    child.on('error', () => finish(null))
    child.stdout.on('data', (chunk) => {
      out += chunk
      const match = out.match(pattern)
      if (match) finish(absolutePath(match[1].trim()))
    })
    child.on('close', () => finish(null))
  })
}

/** PATH from the file an earlier worker wrote, so a restart never drops a good one. */
export async function savedPath(file) {
  try {
    return absolutePath(JSON.parse(await readFile(file, 'utf8')).PATH)
  } catch {
    return null
  }
}

/** Writes the file atomically, readable only by you. */
export async function writeSettingsFile(file, content) {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.${randomUUID()}.tmp`
  await writeFile(tmp, `${JSON.stringify(content, null, 2)}\n`, { mode: 0o600 })
  await chmod(tmp, 0o600)
  await rename(tmp, file)
}

/** How often to read PATH from the login shell again, so a newly installed CLI is found. */
export const PATH_REFRESH_MS = 10 * 60 * 1000
/** How often the status bar item asks for the focused workspace's Sprite state. */
export const STATUS_REFRESH_MS = 60 * 1000
let refreshTimer = null
let statusTimer = null

/** Longest common start of the names, to list them in one `sprite list --prefix` call. */
export function commonPrefix(names) {
  if (names.length === 0) return ''
  let prefix = names[0]
  for (const name of names) {
    while (!name.startsWith(prefix)) prefix = prefix.slice(0, -1)
  }
  return prefix
}

const asleep = (status) => status === 'warm' || status === 'cold' || status === 'suspended'
export const describe = (status) => (status === 'running' ? 'awake' : asleep(status) ? 'asleep' : status)

/** The ids of every workspace Orca lists, which are never on a recipe VM. */
async function localIds(orca) {
  const { workspaces } = await orca.host.call('workspace.list', {})
  return workspaces.map((row) => row.id)
}

/** Every Sprite this computer created, with its state and the workspace it was made for. */
export async function listSprites(orca) {
  const entries = await readRegistry()
  const env = await cliEnv(settingsFile())
  const states = {}
  const failed = new Set()
  let error = null
  await Promise.all(
    [...new Set(entries.map((entry) => entry.org))].map(async (org) => {
      const names = entries.filter((entry) => entry.org === org).map((entry) => entry.name)
      try {
        Object.assign(states, await spriteStates(org, commonPrefix(names), env))
      } catch (e) {
        failed.add(org)
        error = e.message
      }
    })
  )
  const sprites = entries.map((entry) => ({
    name: entry.name,
    org: entry.org,
    url: states[entry.name]?.url ?? entry.url ?? null,
    // Gone only when its org listed fine and it was not there.
    status: states[entry.name]?.status ?? (failed.has(entry.org) ? 'unknown' : 'gone'),
    workspace: entry.workspaceLabel ?? entry.workspaceName ?? null,
    createdAt: entry.createdAt ?? null
  }))
  return { sprites, error }
}

/** The focused workspace's Sprite entry, or a sentence saying why there is none. */
async function focusedSprite(orca, context) {
  context = context === undefined ? await orca.host.call('workspace.readContext', {}) : context
  if (!context) return { why: 'No workspace is open.' }
  const entry = await resolveSprite(context, await localIds(orca))
  if (!entry) {
    return {
      why: `Could not match ${context.displayName} to a Sprite recorded on this computer. If it runs on a Sprite, suspend and resume the workspace, then open it again.`
    }
  }
  return { entry, context }
}

/** @type {import('orca/worker').Activate} */
export default async function activate(orca) {
  let path = await savedPath(settingsFile())
  const write = async () => {
    const values = {}
    for (const key of Object.keys(SETTINGS)) {
      values[key] = await orca.settings.get(key)
    }
    const content = toVariables(values)
    if (path) {
      content.PATH = path
    }
    await writeSettingsFile(settingsFile(), content)
  }
  // One write at a time, in order, so the file always ends with the latest settings.
  let queue = Promise.resolve()
  const sync = () => {
    queue = queue
      .then(write)
      .catch((error) => orca.log(`could not write ${settingsFile()}: ${error.message}`))
    return queue
  }
  const refreshPath = async () => {
    const fresh = await loginShellPath()
    if (fresh) {
      path = fresh
      await sync()
    } else {
      orca.log('could not read PATH from your login shell; the recipe keeps the last one it had')
    }
  }

  // Orca does not show what a command returns, so commands answer with a notification too.
  const notify = (title, body) => orca.host.call('notifications.show', { title, body }).catch(() => {})

  // A checkpoint can take minutes on a sleeping Sprite, longer than Orca waits for a command or
  // a panel request. So it runs in the background and reports when it is done.
  const running = new Set()
  let runs = 0
  const startCheckpoint = (entry, label) => {
    if (running.has(entry.name)) return null
    running.add(entry.name)
    const run = ++runs
    void (async () => {
      let message
      let ok = true
      try {
        message = await checkpoint(entry, `Orca: ${label}`, await cliEnv(settingsFile()))
      } catch (error) {
        ok = false
        message = error.message
      }
      // Report to the panel in the same step that frees the name, so the event of this run can
      // never clear the spinner of a checkpoint started after it.
      running.delete(entry.name)
      try {
        orca.panels.post('sprites.checkpointed', { name: entry.name, run, ok, message })
      } catch {}
      await notify(ok ? `Checkpointed ${label}` : `Checkpoint failed for ${label}`, `${entry.name}: ${message}`)
    })()
    return run
  }

  orca.commands.register('sprites.show', async () => {
    const { entry, why } = await focusedSprite(orca)
    if (!entry) {
      await notify('No Sprite', why)
      return why
    }
    let text
    try {
      const state = (await spriteStates(entry.org, entry.name, await cliEnv(settingsFile())))[entry.name]
      text = state ? `${describe(state.status)} · ${state.url ?? 'no URL'}` : `gone from ${entry.org}`
    } catch (error) {
      text = error.message
    }
    await notify(`Sprite ${entry.name}`, text)
    return `${entry.name}: ${text}`
  })
  orca.commands.register('sprites.checkpoint', async () => {
    const { entry, context, why } = await focusedSprite(orca)
    if (!entry) {
      await notify('No Sprite', why)
      return why
    }
    const started = startCheckpoint(entry, context.displayName) !== null
    const text = started ? `Checkpointing ${entry.name}…` : `A checkpoint of ${entry.name} is already running.`
    await notify(text, 'You get a notification when it is done.')
    return text
  })
  // The panel also learns which checkpoints are running, so a spinner whose result never came
  // (the worker restarted, say) clears on the next refresh.
  orca.panels.handle('sprites.list', async () => ({ ...(await listSprites(orca)), checkpointing: [...running] }))
  orca.panels.handle('sprites.checkpoint', async ({ name }) => {
    const entry = (await readRegistry()).find((e) => e.name === name)
    if (!entry) throw new Error(`no Sprite named ${name} was created on this computer`)
    const run = startCheckpoint(entry, entry.workspaceLabel ?? entry.workspaceName ?? entry.name)
    return { started: run !== null, run }
  })
  // Forget only a Sprite that is really gone: its org listed fine and it was not there.
  orca.panels.handle('sprites.forget', async ({ name }) => {
    const entry = (await readRegistry()).find((e) => e.name === name)
    if (!entry) return { forgotten: false }
    const states = await spriteStates(entry.org, entry.name, await cliEnv(settingsFile()))
    if (states[entry.name]) throw new Error(`${name} still exists in ${entry.org}`)
    await forgetEntry(name)
    return { forgotten: true }
  })

  // The status bar item shows the focused workspace's Sprite, and hides for other workspaces.
  // workspace.changed also fires when terminals open or close, so runs can overlap: only the
  // newest one may update the item.
  let focused = null
  let generation = 0
  const showStatus = async () => {
    const mine = ++generation
    const found = focused ? await focusedSprite(orca, focused).catch(() => ({})) : {}
    if (mine !== generation) return
    if (!found.entry) {
      await orca.host.call('statusBar.update', { id: 'sprites', visible: false }).catch(() => {})
      return
    }
    let status = 'unknown'
    try {
      status = (await spriteStates(found.entry.org, found.entry.name, await cliEnv(settingsFile())))[found.entry.name]?.status ?? 'gone'
    } catch {}
    if (mine !== generation) return
    await orca.host
      .call('statusBar.update', {
        id: 'sprites',
        visible: true,
        text: `Sprite ${describe(status)}`,
        tone: status === 'running' ? 'success' : status === 'gone' ? 'danger' : 'neutral',
        tooltip: `${found.entry.name} in ${found.entry.org}. Click for its URL.`
      })
      .catch(() => {})
  }
  orca.events.on('workspace.changed', ({ context }) => {
    focused = context
    void showStatus()
  })
  statusTimer = setInterval(() => void showStatus(), STATUS_REFRESH_MS)
  statusTimer.unref?.()

  orca.settings.onDidChange(() => {
    sync()
    void refreshPath()
  })
  // The login shell can be slow, so write the settings first and update PATH when it answers.
  await sync()
  await refreshPath()
  refreshTimer = setInterval(() => void refreshPath(), PATH_REFRESH_MS)
  refreshTimer.unref?.()
}

export function deactivate() {
  for (const timer of [refreshTimer, statusTimer]) {
    if (timer) clearInterval(timer)
  }
  refreshTimer = null
  statusTimer = null
}
