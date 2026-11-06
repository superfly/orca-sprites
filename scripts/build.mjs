#!/usr/bin/env node
// Builds recipes/sprites.json, the recipe Orca reads, from src/sprites/*.sh.
// A plugin recipe must be self-contained, so each phase gets lib.sh inlined in place of
// its `. "$(dirname "$0")/lib.sh"` line. Orca runs each phase through `sh -c`, so the
// bash script travels in a quoted heredoc and stdin (the lifecycle payload) stays free.
//   node scripts/build.mjs           write recipes/sprites.json
//   node scripts/build.mjs --check   fail if recipes/sprites.json is stale
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const src = (f) => readFileSync(join(root, 'src/sprites', f), 'utf8')
const MARKER = 'ORCA_SPRITES_SCRIPT'
const MAX = 32 * 1024 // Orca's limit per recipe command
const lib = src('lib.sh').replace(/^# shellcheck shell=bash\n/, '')
const include = /^\. "\$\(dirname "\$0"\)\/lib\.sh".*$/m

function phase(name) {
  const body = src(`${name}.sh`)
  if (!include.test(body)) throw new Error(`${name}.sh does not source lib.sh`)
  const script = body.replace(/^#!.*\n/, '').replace(include, () => lib.trimEnd())
  if (script.split('\n').includes(MARKER)) throw new Error(`${name}.sh contains the heredoc marker`)
  const command = `bash -c "$(cat <<'${MARKER}'\n${script.trimEnd()}\n${MARKER}\n)" sprites-${name}`
  if (Buffer.byteLength(command) > MAX) throw new Error(`${name} is ${Buffer.byteLength(command)} bytes, over ${MAX}`)
  return command
}

const recipe = {
  schemaVersion: 1,
  id: 'sprites',
  name: 'Sprites',
  description:
    'Runs each workspace in its own Sprite, a persistent Linux VM from Fly.io: builds the Sprite, starts orca serve as a service, sleeps it on suspend and destroys it on delete.',
  create: phase('create'),
  suspend: phase('suspend'),
  resume: phase('resume'),
  destroy: phase('destroy')
}
const out = join(root, 'recipes/sprites.json')
const text = JSON.stringify(recipe, null, 2) + '\n'
if (process.argv.includes('--check')) {
  let current = ''
  try { current = readFileSync(out, 'utf8') } catch {}
  if (current !== text) { console.error('recipes/sprites.json is stale: run node scripts/build.mjs'); process.exit(1) }
  console.log('recipes/sprites.json is up to date')
} else {
  writeFileSync(out, text)
  for (const p of ['create', 'suspend', 'resume', 'destroy']) console.log(`${p}: ${Buffer.byteLength(recipe[p])} bytes`)
  console.log('wrote recipes/sprites.json')
}
