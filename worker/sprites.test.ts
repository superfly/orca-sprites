import { assert, mockHost, mountWorker, test } from 'orca/testing'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const dir = mkdtempSync(join(tmpdir(), 'orca-sprites-reg-'))
const registry = join(dir, 'sprites')
const bin = join(dir, 'bin')
mkdirSync(registry)
mkdirSync(bin)
process.env.SPRITES_REGISTRY_DIR = registry
process.env.SPRITES_SETTINGS_FILE = join(dir, 'settings.json')
process.env.SPRITES_LOGIN_SHELL = '/bin/false'
// A fake sprite CLI: `list` answers from list.json (or fails when list.fail exists),
// `checkpoint create` logs its arguments and waits for a release file when one is named.
writeFileSync(
  join(bin, 'sprite'),
  `#!/bin/sh
case "$*" in
  *checkpoint*) echo "$*" >> ${dir}/calls; while [ -f ${dir}/hold ]; do sleep 0.05; done; echo "Checkpoint v3 created";;
  *list*) if [ -f ${dir}/list.fail ]; then echo "Error: URL https://api.sprites.dev not found in config" >&2; exit 1; fi; cat ${dir}/list.json;;
esac
`
)
chmodSync(join(bin, 'sprite'), 0o755)
writeFileSync(process.env.SPRITES_SETTINGS_FILE as string, JSON.stringify({ PATH: bin }))

const now = Date.now()
const entry = (name: string, extra: Record<string, unknown> = {}) =>
  writeFileSync(
    join(registry, `${name}.json`),
    JSON.stringify({ name, org: 'acme', url: `https://${name}.sprites.app`, workspaceName: 'feature-a', createdAt: now, ...extra })
  )
const read = (name: string) => JSON.parse(readFileSync(join(registry, `${name}.json`), 'utf8'))
const vmId = (name: string) => `dab04a36::/home/sprite/orca/workspaces/Hello-World/${name}`
const ctx = (workspaceId: string, displayName = 'feature-a') => ({ workspaceId, displayName, branch: `Sprite/${displayName}`, terminals: [] })

test('links the focused workspace by its path on the Sprite, only when unambiguous, then by its id', async () => {
  const { spriteFor, spriteWorkspaceName } = await import('./sprites.mjs')
  const a = { name: 'orca-sprites-aaa', workspaceName: 'feature-a', createdAt: now }
  const b = { name: 'orca-sprites-bbb', workspaceName: 'feature-b', createdAt: now }
  assert.equal(spriteWorkspaceName(vmId('feature-a')), 'feature-a')
  assert.equal(spriteWorkspaceName('x::/Users/me/repo'), null)
  assert.equal(spriteFor(ctx(vmId('feature-a')), [a, b])?.entry.name, 'orca-sprites-aaa')
  assert.equal(spriteFor(ctx(vmId('feature-a')), [a, b])?.link, true)
  // The display name can differ from the workspace's name (a workspace made from an issue).
  assert.equal(spriteFor(ctx(vmId('feature-a'), 'Fix the login bug'), [a])?.entry.name, 'orca-sprites-aaa')
  // A matching display name is not enough without the Sprite path.
  assert.equal(spriteFor(ctx('x::/Users/me/feature-a'), [a]), null)
  // A same-named workspace of another repository (its project folder differs): no link.
  const fromRepo = { ...a, projectFolder: 'Hello-World' }
  assert.equal(spriteFor(ctx(vmId('feature-a')), [fromRepo])?.entry.name, 'orca-sprites-aaa')
  assert.equal(spriteFor(ctx('u::/home/sprite/orca/workspaces/Other-Repo/feature-a'), [fromRepo]), null)
  // Orca sanitizes the folder name as its sanitizeWorktreeName does, and may add "-2".
  assert.equal(spriteFor(ctx(vmId('Feature-A')), [{ ...a, workspaceName: 'Feature A' }])?.entry.name, 'orca-sprites-aaa')
  assert.equal(spriteFor(ctx(vmId('café-login')), [{ ...a, workspaceName: 'café login' }])?.entry.name, 'orca-sprites-aaa')
  assert.equal(spriteFor(ctx(vmId('feature-a-2')), [a])?.entry.name, 'orca-sprites-aaa')
  assert.equal(spriteFor(ctx(vmId('feature-a-x')), [a]), null)
  // Names that sanitize differently never match, even when both are non-Latin.
  assert.equal(spriteFor(ctx(vmId('修正')), [{ ...a, workspaceName: 'ログイン' }]), null)
  // Two Sprites made for workspaces of the same name: refuse to guess.
  assert.equal(spriteFor(ctx(vmId('feature-a')), [a, { ...b, workspaceName: 'feature-a' }]), null)
  // A workspace Orca lists as local or SSH is never a recipe VM; a linked entry still wins.
  assert.equal(spriteFor(ctx(vmId('feature-a')), [a], [vmId('feature-a')]), null)
  assert.equal(spriteFor(ctx(vmId('feature-a')), [{ ...a, workspaceId: vmId('feature-a') }], [vmId('feature-a')])?.link, false)
  // Too old to link; a resume (recordedAt) reopens the window.
  const old = { ...a, createdAt: now - 3 * 60 * 60 * 1000 }
  assert.equal(spriteFor(ctx(vmId('feature-a')), [old]), null)
  assert.equal(spriteFor(ctx(vmId('feature-a')), [{ ...old, recordedAt: now }])?.link, true)
  // Linked: found by id even after a rename, and never offered to another workspace.
  const linked = { ...a, workspaceId: vmId('feature-a') }
  assert.equal(spriteFor(ctx(vmId('feature-a'), 'renamed'), [linked])?.link, false)
  assert.equal(spriteFor(ctx(vmId('feature-a-2')), [linked]), null)
  assert.equal(spriteFor(null, [a]), null)
})

test('resolveSprite saves the link', async () => {
  const { resolveSprite } = await import('./sprites.mjs')
  entry('orca-sprites-ccc', { workspaceName: 'feature-c' })
  assert.equal((await resolveSprite(ctx(vmId('feature-c'), 'feature-c'), []))?.name, 'orca-sprites-ccc')
  assert.equal(read('orca-sprites-ccc').workspaceId, vmId('feature-c'))
  assert.equal(read('orca-sprites-ccc').workspaceLabel, 'feature-c')
})

test('the first link never brings back an entry destroy removed', async () => {
  const { resolveSprite, saveEntry } = await import('./sprites.mjs')
  const gone = { name: 'orca-sprites-zzz', org: 'acme', workspaceName: 'zz', createdAt: now }
  await saveEntry(gone, registry, { onlyIfPresent: true })
  assert.ok(!existsSync(join(registry, 'orca-sprites-zzz.json')))
  assert.equal(await resolveSprite(ctx(vmId('zz')), []), null)
})

test('readRegistry ignores files whose name is not a Sprite name', async () => {
  const { readRegistry } = await import('./sprites.mjs')
  writeFileSync(join(registry, '..evil.json'), JSON.stringify({ name: '..evil' }))
  assert.ok((await readRegistry()).every((e: { name: string }) => e.name !== '..evil'))
})

test('commonPrefix', async () => {
  const { commonPrefix } = await import('./main.mjs')
  assert.equal(commonPrefix(['orca-sprites-aaa', 'orca-sprites-abc']), 'orca-sprites-a')
  assert.equal(commonPrefix([]), '')
})

const host = (context: unknown) =>
  mockHost({
    capabilities: ['settings:own', 'workspace:read', 'notifications:show'],
    settings: {},
    results: {
      'workspace.list': { workspaces: [{ id: 'local-1', kind: 'worktree', name: 'main', path: '/x', branch: 'main', hostId: 'local' }], truncated: false },
      'workspace.readContext': context
    }
  })

test('lists Sprites with their state; gone only when the org listed fine', async () => {
  entry('orca-sprites-aaa')
  entry('orca-sprites-bbb', { workspaceName: 'feature-b' })
  writeFileSync(join(dir, 'list.json'), JSON.stringify({ sprites: [{ name: 'orca-sprites-aaa', status: 'warm', url: 'https://aaa.sprites.app' }] }))
  const worker = await import('./main.mjs')
  const mounted = await mountWorker(worker, { host: host(null), events: ['workspace.changed'], commands: ['sprites.show', 'sprites.checkpoint'] })
  const { sprites, error } = (await mounted.request('sprites.list', {})) as { sprites: any[]; error: string | null }
  assert.equal(error, null)
  assert.equal(sprites.find((s) => s.name === 'orca-sprites-aaa').status, 'warm')
  assert.equal(sprites.find((s) => s.name === 'orca-sprites-bbb').status, 'gone')
  writeFileSync(join(dir, 'list.fail'), '')
  const failed = (await mounted.request('sprites.list', {})) as { sprites: any[]; error: string | null }
  assert.match(String(failed.error), /no saved login: run sprite login/)
  assert.ok(failed.sprites.every((s) => s.status === 'unknown'))
  // Forget refuses while the list fails, then drops a Sprite that is really gone.
  await assert.rejects(mounted.request('sprites.forget', { name: 'orca-sprites-bbb' }))
  assert.ok(existsSync(join(registry, 'orca-sprites-bbb.json')))
  unlinkSync(join(dir, 'list.fail'))
  await assert.rejects(mounted.request('sprites.forget', { name: 'orca-sprites-aaa' }), /still exists/)
  assert.deepEqual(await mounted.request('sprites.forget', { name: 'orca-sprites-bbb' }), { forgotten: true })
  assert.ok(!existsSync(join(registry, 'orca-sprites-bbb.json')))
  worker.deactivate()
})

test('commands notify; a checkpoint runs in the background and reports when done', async () => {
  entry('orca-sprites-aaa', { workspaceId: vmId('feature-a'), workspaceLabel: 'feature-a' })
  writeFileSync(join(dir, 'list.json'), JSON.stringify({ sprites: [{ name: 'orca-sprites-aaa', status: 'running', url: 'https://aaa.sprites.app' }] }))
  const worker = await import('./main.mjs')
  const h = host(ctx(vmId('feature-a')))
  const mounted = await mountWorker(worker, { host: h, events: ['workspace.changed'], commands: ['sprites.show', 'sprites.checkpoint'] })
  assert.match(String(await mounted.command('sprites.show')), /orca-sprites-aaa: awake · https:\/\/aaa.sprites.app/)
  writeFileSync(join(dir, 'hold'), '')
  assert.match(String(await mounted.command('sprites.checkpoint')), /Checkpointing orca-sprites-aaa/)
  // A second request while it runs does not start another.
  assert.deepEqual(await mounted.request('sprites.checkpoint', { name: 'orca-sprites-aaa' }), { started: false, run: null })
  unlinkSync(join(dir, 'hold'))
  for (let i = 0; i < 100 && !mounted.posts.some((p) => p.event === 'sprites.checkpointed'); i++) {
    await new Promise((r) => setTimeout(r, 30))
  }
  const done = mounted.posts.find((p) => p.event === 'sprites.checkpointed')?.payload as { ok: boolean; message: string }
  assert.equal(done?.ok, true)
  assert.match(done.message, /Checkpoint v3 created/)
  assert.match(readFileSync(join(dir, 'calls'), 'utf8'), /-o acme -s orca-sprites-aaa checkpoint create --comment Orca: feature-a/)
  const titles = (h.callsOf('notifications.show') as { title: string }[]).map((c) => c.title)
  assert.ok(titles.includes('Sprite orca-sprites-aaa'))
  assert.ok(titles.includes('Checkpointed feature-a'))
  // A local workspace: no Sprite, and the command says so.
  const local = await mountWorker(worker, { host: host(ctx('local-1', 'main')), events: ['workspace.changed'], commands: ['sprites.show', 'sprites.checkpoint'] })
  assert.match(String(await local.command('sprites.checkpoint')), /Could not match main to a Sprite/)
  worker.deactivate()
})

test('the status bar shows the focused Sprite and hides elsewhere', async () => {
  entry('orca-sprites-aaa', { workspaceId: vmId('feature-a'), workspaceLabel: 'feature-a' })
  writeFileSync(join(dir, 'list.json'), JSON.stringify({ sprites: [{ name: 'orca-sprites-aaa', status: 'running' }] }))
  const worker = await import('./main.mjs')
  const h = host(ctx(vmId('feature-a')))
  const mounted = await mountWorker(worker, { host: h, events: ['workspace.changed'], commands: ['sprites.show', 'sprites.checkpoint'] })
  await mounted.emit('workspace.changed', { context: ctx(vmId('feature-a')) })
  for (let i = 0; i < 100 && !(h.callsOf('statusBar.update') as any[]).some((c) => c.visible === true); i++) {
    await new Promise((r) => setTimeout(r, 20))
  }
  const shown = (h.callsOf('statusBar.update') as any[]).find((c) => c.visible === true)
  assert.equal(shown?.text, 'Sprite awake')
  await mounted.emit('workspace.changed', { context: ctx('local-1', 'main') })
  for (let i = 0; i < 100 && (h.callsOf('statusBar.update') as any[]).at(-1)?.visible !== false; i++) {
    await new Promise((r) => setTimeout(r, 20))
  }
  assert.equal((h.callsOf('statusBar.update') as any[]).at(-1)?.visible, false)
  worker.deactivate()
})
