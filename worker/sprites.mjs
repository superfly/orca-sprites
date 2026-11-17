// Which Sprite belongs to which workspace, and the sprite CLI calls the worker makes.
//
// The recipe writes one JSON file per Sprite it creates or resumes (src/sprites/lib.sh,
// record_sprite) to ~/.config/orca-sprites/sprites/. Orca gives the recipe the new workspace's
// name but not its id, because the workspace is made on the Sprite after create returns, and
// Orca's workspace.list does not list workspaces on a recipe VM. What the worker does see is the
// focused workspace (workspace.readContext). Its id ends with the workspace's path on the VM,
// "<uuid>::/home/sprite/orca/workspaces/<repo>/<name>", where <name> is the name the recipe got.
// So the first time a Sprite workspace is focused, the worker links it by that path, and only
// when exactly one Sprite fits; from then on it finds the Sprite by that exact workspace id,
// which it saves in the Sprite's file.

import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { readdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

/** How long after create (or resume) a Sprite may still be linked to a workspace by name. */
export const LINK_WINDOW_MS = 2 * 60 * 60 * 1000

export function registryDir() {
  return process.env.SPRITES_REGISTRY_DIR || join(homedir(), '.config', 'orca-sprites', 'sprites')
}

const NAME = /^[a-z0-9][a-z0-9-]{0,62}$/

/** Every Sprite this computer created and has not destroyed, newest first. */
export async function readRegistry(dir = registryDir()) {
  let files = []
  try {
    files = (await readdir(dir)).filter((file) => file.endsWith('.json'))
  } catch {
    return []
  }
  const entries = []
  for (const file of files) {
    try {
      const entry = JSON.parse(await readFile(join(dir, file), 'utf8'))
      if (typeof entry?.name === 'string' && NAME.test(entry.name) && `${entry.name}.json` === file) {
        entries.push(entry)
      }
    } catch {
      // A file being written or damaged by hand: skip it.
    }
  }
  return entries.sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0))
}

export async function saveEntry(entry, dir = registryDir(), { onlyIfPresent = false } = {}) {
  const file = join(dir, `${entry.name}.json`)
  if (onlyIfPresent && !(await stat(file).catch(() => null))) return
  const tmp = `${file}.${randomUUID()}.tmp`
  await writeFile(tmp, `${JSON.stringify(entry, null, 2)}\n`, { mode: 0o600 })
  await rename(tmp, file)
}

export async function forgetEntry(name, dir = registryDir()) {
  if (!NAME.test(name)) throw new Error(`not a Sprite name: ${name}`)
  await unlink(join(dir, `${name}.json`)).catch((error) => {
    if (error.code !== 'ENOENT') throw error
  })
}

/**
 * The Sprite for the focused workspace.
 * - `context` is what workspace.readContext answers; `localIds` are the ids workspace.list
 *   gives (those workspaces are not on a recipe VM).
 * - Returns `{ entry, link }`: `link` is true when the entry was matched by name and the caller
 *   should save the workspace id on it. Returns null when there is no Sprite, or when the name
 *   matches more than one Sprite, so nothing ever acts on a Sprite it is not sure of.
 */
export function spriteFor(context, entries, localIds = [], now = Date.now()) {
  const id = context?.workspaceId
  if (!id) return null
  const linked = entries.find((entry) => entry.workspaceId === id)
  if (linked) return { entry: linked, link: false }
  if (localIds.includes(id)) return null
  const name = spriteWorkspaceName(id)
  if (!name) return null
  const parent = spriteWorkspaceParent(id)
  const candidates = entries.filter(
    (entry) =>
      !entry.workspaceId &&
      // A Sprite still being built has no URL yet: never link it, since its workspace cannot
      // exist yet. serve (create) and resume set the URL.
      Boolean(entry.url) &&
      sameFolder(entry.workspaceName, name) &&
      // Orca keeps workspaces in <workspaces folder>/<project>/<name>, the project named after the
      // checkout folder on the Sprite, so a same-named workspace of another project never matches.
      (!entry.projectFolder || !parent || entry.projectFolder === parent) &&
      now - (entry.recordedAt ?? entry.createdAt ?? 0) < LINK_WINDOW_MS
  )
  return candidates.length === 1 ? { entry: candidates[0], link: true } : null
}

/** The folder name Orca makes from a workspace name (its sanitizeWorktreeName, without the
 *  emoji shortcodes: a name with emoji simply does not link). */
export const folderName = (s) =>
  String(s ?? '')
    .trim()
    .replace(/[^\p{L}\p{N}._-]+/gu, '-')
    .replace(/-+/g, '-')
    .replace(/\.{2,}/g, '.')
    .replace(/^[.-]+|[.-]+$/g, '')

/** Whether a folder on the Sprite is the one Orca made for this workspace name: the same, or
 *  with the "-2", "-3" Orca adds when the branch is taken. Never matches an empty name. */
export function sameFolder(workspaceName, folder) {
  const want = folderName(workspaceName)
  if (!want || !folder) return false
  return folder === want || new RegExp(`^${want.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-\\d+$`).test(folder)
}

/** The workspace name at the end of a workspace id whose path is in a Sprite's home folder
 *  ("<uuid>::/home/sprite/.../<name>"), or null for any other id. */
export function spriteWorkspaceName(id) {
  const match = /::\/home\/sprite\/(?:[^/]+\/)*([^/]+)\/?$/.exec(String(id))
  return match ? match[1] : null
}

/** The folder above that name ("<project>" in .../workspaces/<project>/<name>), or null. */
export function spriteWorkspaceParent(id) {
  const match = /::\/home\/sprite\/(?:[^/]+\/)*([^/]+)\/([^/]+)\/?$/.exec(String(id))
  return match ? match[1] : null
}

/** Finds the focused workspace's Sprite and saves the link when it was made by name. */
export async function resolveSprite(context, localIds, dir = registryDir()) {
  const found = spriteFor(context, await readRegistry(dir), localIds)
  if (!found) return null
  if (found.link) {
    found.entry.workspaceId = context.workspaceId
    found.entry.workspaceLabel = context.displayName
    // Only while the entry still exists: destroy may have removed it since it was read.
    await saveEntry(found.entry, dir, { onlyIfPresent: true }).catch(() => {})
  }
  return found.entry
}

/** The PATH the recipe uses: the one the worker saved from your login shell, else Orca's. */
export async function cliEnv(settingsFile) {
  let path = null
  try {
    path = JSON.parse(await readFile(settingsFile, 'utf8')).PATH ?? null
  } catch {}
  return { ...process.env, PATH: path ? `${path}:${process.env.PATH ?? ''}` : process.env.PATH }
}

/** Runs the sprite CLI. Resolves with stdout; rejects with its message. */
export function sprite(args, env, timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const child = execFile(
      'sprite',
      args,
      { env, timeout: timeoutMs, killSignal: 'SIGKILL', maxBuffer: 8 << 20 },
      (error, stdout, stderr) => {
        if (!error) return resolve(String(stdout))
        if (error.code === 'ENOENT') return reject(new Error('the sprite CLI is not on PATH'))
        if (error.killed) {
          const words = args.filter((arg, i) => !arg.startsWith('-') && !(i > 0 && /^-(o|s)$/.test(args[i - 1])))
          return reject(new Error(`sprite ${words.slice(0, 2).join(' ')} timed out`))
        }
        const text = String(stderr || stdout || error.message)
        const message = /no token found|not logged in|run 'sprite login'|not found in config|organization .* not found/i.test(text)
          ? 'the sprite CLI has no saved login: run sprite login (the plugin does not see SPRITE_TOKEN)'
          : text
              .split('\n')
              .map((line) => line.trim())
              .filter((line) => line && !line.startsWith('│'))
              .slice(-3)
              .join(' ')
        reject(new Error(message || error.message))
      }
    )
    child.stdin?.end()
  })
}

/** Status (running, warm, cold) and URL of each Sprite in an org whose name starts with prefix. */
export async function spriteStates(org, prefix, env) {
  const out = await sprite(['-o', org, '--json', 'list', '--prefix', prefix], env)
  const states = {}
  for (const s of JSON.parse(out).sprites ?? []) {
    states[s.name] = { status: s.status ?? 'unknown', url: s.url ?? null }
  }
  return states
}

/** Checkpoints a Sprite. Waking a cold one first can take a while, hence the long timeout. */
export async function checkpoint(entry, comment, env) {
  const out = await sprite(['-o', entry.org, '-s', entry.name, 'checkpoint', 'create', '--comment', comment], env, 10 * 60 * 1000)
  // Keep the CLI's last two lines: the checkpoint it made and how to restore it.
  const lines = out.split('\n').map((line) => line.replace(/^[^\w]+/, '').trim()).filter(Boolean)
  return lines.slice(-2).join('. ') || 'Checkpoint created'
}
