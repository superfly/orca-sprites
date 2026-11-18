#!/usr/bin/env node
// Builds recipes/sprites.json, the recipe Orca reads, from src/sprites/*.sh.
// A plugin recipe must be self-contained, so each phase gets lib.sh inlined in place of
// its `. "$(dirname "$0")/lib.sh"` line.
//
// Orca keeps a copy of all four phases with each VM it creates, in one store file with a
// size cap, so the phases are kept small:
// - Code between `#@create-only` and `#@end` lines in lib.sh goes only into create. Those
//   regions may hold only function definitions and remote_* fragments, and the build fails if
//   another phase still names one of them.
// - Each phase is gzipped and base64-encoded. The command Orca runs through `sh -c` unpacks
//   it with base64 and gunzip and hands it to bash, so stdin (the lifecycle payload) stays free.
//
//   node scripts/build.mjs                  write recipes/sprites.json
//   node scripts/build.mjs --check          fail if recipes/sprites.json does not match the sources
//   node scripts/build.mjs --print <phase>  print a phase's bash script, unpacked
import { readFileSync, writeFileSync, writeSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gunzipSync, gzipSync } from 'node:zlib'
import { spawnSync } from 'node:child_process'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const src = (f) => readFileSync(join(root, 'src/sprites', f), 'utf8')
const MAX = 32 * 1024 // Orca's limit per recipe command
const MAX_ARG = 128 * 1024 // Linux's limit on one argument: the unpacked script goes to bash -c
const PHASES = ['create', 'suspend', 'resume', 'destroy']
const lib = src('lib.sh').replace(/^# shellcheck shell=bash\n/, '')
const include = /^\. "\$\(dirname "\$0"\)\/lib\.sh".*$/m

/** lib.sh split into the lines every phase gets (with a marker per region) and the regions. */
function splitLib() {
  const shared = []
  const regions = []
  let region = null
  // lib has lost lib.sh's first line (shellcheck), so lib.sh's line number for lib[i] is i + 2.
  for (const [i, line] of lib.split('\n').entries()) {
    if (line === '#@create-only') {
      if (region) throw new Error(`lib.sh:${i + 2}: #@create-only inside another`)
      region = { line: i + 3, lines: [] }
      shared.push(line)
    } else if (line === '#@end') {
      if (!region) throw new Error(`lib.sh:${i + 2}: #@end without #@create-only`)
      regions.push({ line: region.line, text: region.lines.join('\n') })
      region = null
    } else if (/^#@/.test(line)) {
      // A misspelled marker would quietly put its region into every phase.
      throw new Error(`lib.sh:${i + 2}: unknown marker ${line}; the markers are #@create-only and #@end`)
    } else if (region) {
      region.lines.push(line)
    } else {
      shared.push(line)
    }
  }
  if (region) throw new Error('lib.sh: #@create-only without #@end')
  return { shared, regions }
}
const { shared, regions } = splitLib()

/** lib.sh for one phase: create keeps everything, the others lose the create-only regions. */
function libFor(name) {
  let next = 0
  const out = []
  for (const line of shared) {
    if (line !== '#@create-only') out.push(line)
    else if (name === 'create') out.push(regions[next++].text)
    else next++
  }
  return out.join('\n')
}

// What the create-only regions define. A region may hold only comments, blank lines and two
// shapes of code, matched here in full so anything else fails the build:
// - a function, `name() {` with its body up to a `}` line, or `name() { ...; }` on one line,
//   and bash -n must agree that the function ends there;
// - a fragment, remote_x= followed by '...' strings, "'" and "$remote_y", with nothing after.
// Any other statement (a variable, a check, a loop) would silently vanish from the other phases.
// Sticky, without the m flag: each shape must start where the last one ended and run to a real
// newline, so a shape cannot start inside another one's body or string.
const skipShape = /[ \t]*(?:#[^\n]*)?(?:\n|$)/y
const fragmentShape = /(remote_[a-z0-9_]+)=(?:'[^']*'|"'"|"\$remote_[a-z0-9_]+")+(?:\n|$)/y
const functionShape = /([a-z_][a-z0-9_]*)(\(\) \{)(?: [^\n]*|(?: +#[^\n]*)?\n[\s\S]*?\n)\}(?:\n|$)/y
/** Whether bash parses this text as complete commands. -n reads without running anything. */
const parses = (text) => {
  // LC_ALL=C: bash warns on stderr about a locale that is not installed, which would read as a
  // parse failure. Any other stderr (such as an unterminated heredoc, only a warning) does fail.
  const r = spawnSync('bash', ['-n'], { input: text, encoding: 'utf8', timeout: 10000, env: { ...process.env, LC_ALL: 'C' } })
  if (r.error) throw r.error
  return r.status === 0 && r.stderr === ''
}
const dropped = new Set()
for (const { line, text } of regions) {
  let at = 0
  while (at < text.length) {
    let m = null
    for (const shape of [skipShape, fragmentShape, functionShape]) {
      shape.lastIndex = at
      if ((m = shape.exec(text))) break
    }
    const where = `lib.sh:${line + text.slice(0, at).split('\n').length - 1}`
    if (!m) {
      throw new Error(`${where}: \`${text.slice(at).split('\n')[0].trim()}\` is in a create-only region; only functions and remote_* fragments may go there`)
    }
    if (m[2]) {
      // The regex only guesses where the function ends (the first line that is `}`). bash decides:
      // the body alone must parse, which fails if the function closed earlier (`:; }`, `} >&2`),
      // and so must the whole definition, which fails if this `}` does not close it.
      const whole = m[0].trimEnd()
      const body = whole.slice(m[1].length + m[2].length, -1)
      if (!parses(body) || !parses(whole)) throw new Error(`${where}: ${m[1]}() does not end at the \`}\` the build takes as its end`)
    }
    if (m[1]) dropped.add(m[1])
    at += m[0].length
  }
}

/** Fails if a phase without the create-only regions still names something they define. */
function checkReferences(name, script) {
  if (name === 'create') return
  // Any mention counts, a call or not: a false alarm is cheap, a missing function in destroy is
  // not. Only a word character after the name makes it another name: ${remote_x-} is a use.
  const missing = [...dropped].filter((word) => new RegExp(`(?<![\\w.-])${word}(?!\\w)`).test(script))
  if (missing.length) throw new Error(`${name} uses ${missing.join(', ')}, which lib.sh marks create-only`)
}

/** The bash script for a phase, lib.sh inlined and whole-line comments dropped. */
function script(name) {
  const body = src(`${name}.sh`)
  if (!include.test(body)) throw new Error(`${name}.sh does not source lib.sh`)
  // The sources have no heredocs or multi-line strings with a line that starts with #, other
  // than shell run on the Sprite, where dropping a comment line is also safe.
  const text = body.replace(/^#!.*\n/, '').replace(include, () => libFor(name).trimEnd())
    .replace(/^[ \t]*#.*\n/gm, '').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n'
  checkReferences(name, text)
  if (Buffer.byteLength(text) > MAX_ARG) throw new Error(`${name} is ${Buffer.byteLength(text)} bytes unpacked, over ${MAX_ARG}`)
  return text
}

/** The command Orca runs, around a base64 gzip of the script: unpack, then run it with bash
 *  as sprites-<name>. base64 --decode and gunzip are on macOS and Linux alike, so this needs
 *  nothing on PATH beyond the system folders. $(...) drops the script's final newline. */
const wrap = (name, b64) =>
  `s="$(printf %s '${b64}' | base64 --decode | gunzip -c)" && [ -n "$s" ] ` +
  `|| { echo '[sprites] error: could not unpack the recipe script' >&2; exit 1; }; ` +
  `exec bash -c "$s" sprites-${name}`

function phase(name) {
  const gz = gzipSync(script(name), { level: 9 })
  gz[9] = 3 // gzip's OS byte, which zlib sets per platform
  const command = wrap(name, gz.toString('base64'))
  if (Buffer.byteLength(command) > MAX) throw new Error(`${name} is ${Buffer.byteLength(command)} bytes, over ${MAX}`)
  return command
}

/** Whether a built command is the wrapper around exactly this script, however it was compressed. */
function matches(name, command, text) {
  if (typeof command !== 'string' || Buffer.byteLength(command) > MAX) return false
  const m = /printf %s '([A-Za-z0-9+/=]+)'/.exec(command)
  if (!m || command.replace(m[1], '') !== wrap(name, '')) return false
  const gz = Buffer.from(m[1], 'base64')
  // Node stops decoding at the first '=' but GNU base64 goes on, and gunzip would then unpack
  // a second gzip member: accept only base64 that decodes to exactly these bytes and back.
  if (gz.toString('base64') !== m[1]) return false
  try {
    return gunzipSync(gz).toString('utf8') === text
  } catch {
    return false
  }
}

const print = process.argv.indexOf('--print')
if (print !== -1) {
  const name = process.argv[print + 1]
  if (!PHASES.includes(name)) throw new Error(`--print takes one of ${PHASES.join(', ')}`)
  // writeSync, not process.stdout.write: exiting right after an async write can cut off a pipe.
  writeSync(1, script(name))
  process.exit(0)
}

const recipe = {
  schemaVersion: 1,
  id: 'sprites',
  name: 'Sprites',
  description:
    'Runs each workspace in its own Sprite, a persistent Linux VM from Fly.io: builds the Sprite, starts orca serve as a service, sleeps it on suspend and destroys it on delete.',
  ...Object.fromEntries(PHASES.map((p) => [p, phase(p)]))
}
const out = join(root, 'recipes/sprites.json')
if (process.argv.includes('--check')) {
  // Compares what each phase unpacks to, not the compressed bytes: another Node or zlib version
  // may compress the same script differently.
  let current = null
  let raw = ''
  try { raw = readFileSync(out, 'utf8'); current = JSON.parse(raw) } catch {}
  const same =
    current !== null &&
    typeof current === 'object' &&
    raw === JSON.stringify(current, null, 2) + '\n' &&
    JSON.stringify(Object.keys(current)) === JSON.stringify(Object.keys(recipe)) &&
    Object.keys(recipe).every((key) =>
      PHASES.includes(key) ? matches(key, current[key], script(key)) : current[key] === recipe[key]
    )
  if (!same) { console.error('recipes/sprites.json is stale: run node scripts/build.mjs'); process.exit(1) }
  console.log('recipes/sprites.json is up to date')
} else {
  writeFileSync(out, JSON.stringify(recipe, null, 2) + '\n')
  let total = 0
  for (const p of PHASES) {
    total += Buffer.byteLength(JSON.stringify(recipe[p]))
    console.log(`${p}: ${Buffer.byteLength(recipe[p])} bytes (${Buffer.byteLength(script(p))} unpacked)`)
  }
  console.log(`about ${Math.round(total / 1024)} KB of each VM's record in Orca's store`)
  console.log('wrote recipes/sprites.json')
}
