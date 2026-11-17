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
let refreshTimer = null

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
  if (refreshTimer) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
}
