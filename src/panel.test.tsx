import { assert, mockHost, mount, test } from 'orca/testing'
import * as panel from './panel'

const sprites = [
  { name: 'orca-sprites-aaa', org: 'acme', url: 'https://aaa.sprites.app', status: 'running', workspace: 'feature-a', createdAt: Date.now() - 60000 },
  { name: 'orca-sprites-bbb', org: 'acme', url: null, status: 'gone', workspace: 'old', createdAt: null }
]
const drawn = (p: { tree(): unknown }) => JSON.stringify(p.tree())

test('lists Sprites with their state, opens a URL, starts a checkpoint and forgets a gone one', async () => {
  const requested: string[] = []
  const p = await mount(panel, {
    host: mockHost({
      requests: {
        'sprites.list': { sprites, error: null, checkpointing: [] },
        'sprites.checkpoint': ({ name }: { name: string }) => {
          requested.push(`checkpoint ${name}`)
          return { started: true, run: 7 }
        },
        'sprites.forget': ({ name }: { name: string }) => {
          requested.push(`forget ${name}`)
          return { forgotten: true }
        }
      }
    })
  })
  assert.deepEqual(p.errors, [])
  for (const text of ['feature-a', 'orca-sprites-aaa · acme', 'awake', 'gone', 'Forget']) {
    assert.ok(drawn(p).includes(text), text)
  }
  await p.press(p.findAll({ type: 'Button', text: 'Checkpoint' })[0])
  assert.deepEqual(requested, ['checkpoint orca-sprites-aaa'])
  assert.ok(drawn(p).includes('Checkpointing'))
  await p.press(p.findAll({ type: 'Button', text: 'Open URL' })[0])
  assert.deepEqual(p.host.callsOf('shell.openExternal').map((c) => (c as { url: string }).url), ['https://aaa.sprites.app'])
  await p.press(p.findAll({ type: 'Button', text: 'Forget' })[0])
  assert.ok(requested.includes('forget orca-sprites-bbb'))
})

test('shows an empty state, and the worker error', async () => {
  const p = await mount(panel, {
    host: mockHost({ requests: { 'sprites.list': { sprites: [], error: 'the sprite CLI is not on PATH', checkpointing: [] } } })
  })
  assert.ok(drawn(p).includes('No Sprites yet'))
  assert.ok(drawn(p).includes('not on PATH'))
})

test('a failed first load shows the error, not "No Sprites yet"', async () => {
  const p = await mount(panel, {
    host: mockHost({
      requests: {
        'sprites.list': () => {
          throw new Error('timeout')
        }
      }
    })
  })
  assert.ok(drawn(p).includes('timeout'))
  assert.ok(!drawn(p).includes('No Sprites yet'))
})

test('a checkpoint spinner whose result never came clears on refresh', async () => {
  const p = await mount(panel, {
    host: mockHost({
      requests: {
        'sprites.list': { sprites, error: null, checkpointing: [] },
        'sprites.checkpoint': () => ({ started: true, run: 1 })
      }
    })
  })
  await p.press(p.findAll({ type: 'Button', text: 'Checkpoint' })[0])
  assert.ok(drawn(p).includes('Checkpointing'))
  await p.press(p.find({ type: 'IconButton', label: 'Refresh' })!)
  assert.ok(!drawn(p).includes('Checkpointing'))
})
