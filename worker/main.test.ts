import { assert, mockHost, mountWorker, test } from 'orca/testing'
import { mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const dir = mkdtempSync(join(tmpdir(), 'orca-sprites-'))
process.env.SPRITES_SETTINGS_FILE = join(dir, 'nested', 'settings.json')
// A shell that prints noise around PATH, as an interactive login shell can.
process.env.SPRITES_LOGIN_SHELL = '/bin/sh'

const read = () => JSON.parse(readFileSync(process.env.SPRITES_SETTINGS_FILE as string, 'utf8'))

test('writes non-empty settings as recipe variables, readable only by you', async () => {
  const worker = await import('./main.mjs')
  await mountWorker(worker, {
    host: mockHost({
      capabilities: ['settings:own'],
      settings: { org: ' my-org ', namePrefix: 'orca', orcaVersion: '', browser: false, keepAwake: true }
    })
  })
  const vars = read()
  assert.equal(vars.SPRITES_ORG, 'my-org')
  assert.equal(vars.SPRITES_NAME_PREFIX, 'orca')
  assert.equal(vars.SPRITES_ORCA_VERSION, undefined)
  assert.equal(vars.SPRITES_BROWSER, '0')
  assert.equal(vars.SPRITES_KEEP_AWAKE, '1')
  assert.equal(statSync(process.env.SPRITES_SETTINGS_FILE as string).mode & 0o777, 0o600)
})

test('adds PATH from the login shell', async () => {
  const worker = await import('./main.mjs')
  await mountWorker(worker, { host: mockHost({ capabilities: ['settings:own'], settings: {} }) })
  assert.ok(typeof read().PATH === 'string' && read().PATH.includes('/bin'))
})

test('keeps only absolute PATH entries', async () => {
  const { absolutePath } = await import('./main.mjs')
  assert.equal(absolutePath('.:/usr/bin::bin:/opt/x/bin:/usr/bin'), '/usr/bin:/opt/x/bin')
  assert.equal(absolutePath('.:bin'), null)
})

test('keeps the saved PATH when the login shell does not answer', async () => {
  const { writeSettingsFile, settingsFile } = await import('./main.mjs')
  await writeSettingsFile(settingsFile(), { PATH: '/saved/bin:/usr/bin' })
  process.env.SPRITES_LOGIN_SHELL = '/bin/false'
  const worker = await import('./main.mjs')
  await mountWorker(worker, { host: mockHost({ capabilities: ['settings:own'], settings: {} }) })
  assert.equal(read().PATH, '/saved/bin:/usr/bin')
  process.env.SPRITES_LOGIN_SHELL = '/bin/sh'
})

test('a login shell that waits for input does not hang', async () => {
  const { loginShellPath } = await import('./main.mjs')
  const dir2 = mkdtempSync(join(tmpdir(), 'orca-sprites-sh-'))
  const shell = join(dir2, 'reads.sh')
  writeFileSync(shell, '#!/bin/sh\nread x\nsleep 60\n', { mode: 0o755 })
  const started = Date.now()
  assert.equal(await loginShellPath(shell), null)
  assert.ok(Date.now() - started < 8000)
})

test('a background program the rc file starts neither delays the answer nor stays running', async () => {
  const { loginShellPath } = await import('./main.mjs')
  const d = mkdtempSync(join(tmpdir(), 'orca-sprites-bg-'))
  const shell = join(d, 'bg.sh')
  writeFileSync(shell, `#!/bin/sh\nsleep 30 &\necho "$!" > ${d}/pid\nprintf '%s%s%s' __ORCA_SPRITES_PATH__ /usr/bin:/bin __ORCA_SPRITES_PATH__\n`, { mode: 0o755 })
  const started = Date.now()
  assert.equal(await loginShellPath(shell), '/usr/bin:/bin')
  assert.ok(Date.now() - started < 3000)
  const helper = Number(readFileSync(join(d, 'pid'), 'utf8'))
  const alive = () => {
    try {
      process.kill(helper, 0)
      return true
    } catch {
      return false
    }
  }
  for (let i = 0; i < 50 && alive(); i++) await new Promise((r) => setTimeout(r, 20))
  assert.equal(alive(), false)
})
