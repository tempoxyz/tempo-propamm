// Generates src/generated/{abis,enums,constants,internal}.ts from the Forge build of contracts/src/v2
// (`npm run contracts:build`), so the SDK keeps no handwritten ABI (AGENTS.md). Constants and enums come from hash-verified source parsed by @solidity-parser/parser, evaluated by a
// small integer evaluator that refuses any expression form it does not know, so a contract edit that introduces a new
// form fails generation instead of producing a wrong value.
//
// Usage (from sdk/ts):
//   node scripts/gen.mjs           write src/generated/*
//   node scripts/gen.mjs --check   exit 1 if the committed files differ from a fresh generation
//
// PROPAMM_FORGE_OUT overrides the artifact directory (default: sdk/ts/.forge/solar/out). Every file goes through the
// package's Biome formatter (`biome format`, under biome.json), so the generated code is formatted as the rest is and
// `npm run check` holds it too.

import { spawnSync } from 'node:child_process'
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatAbiItem } from 'viem/utils'
import { bitsOf, sourceModel, verifySource } from './solidity-source.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const outDir = resolve(
  process.env.PROPAMM_FORGE_OUT ?? join(root, '.forge', 'solar', 'out'),
)
const genDir = join(root, 'src', 'generated')

if (!existsSync(outDir)) {
  process.stderr.write(
    `${outDir} does not exist: run npm run contracts:build first\n`,
  )
  process.exit(1)
}

/** Every artifact in the build, by `<file>:<contract>`. */
const artifacts = new Map()
for (const dir of readdirSync(outDir)) {
  if (!dir.endsWith('.sol')) continue
  for (const file of readdirSync(join(outDir, dir))) {
    if (!file.endsWith('.json')) continue
    artifacts.set(
      `${dir}:${file.slice(0, -5)}`,
      JSON.parse(readFileSync(join(outDir, dir, file), 'utf8')),
    )
  }
}

function artifact(file, name) {
  const a = artifacts.get(`${file}:${name}`)
  if (!a) throw new Error(`missing artifact ${file}:${name} in ${outDir}`)
  return a
}

// ---------------------------------------------------------------------------------------------------------------------
// ABIs
// ---------------------------------------------------------------------------------------------------------------------

/** An item's kind and canonical signature (`function quote(uint16,...)`), as viem's `formatAbiItem` writes it. */
const signature = (item) => `${item.type} ${formatAbiItem(item)}`

/** The artifact's ABI without its constructor, each error once (a library error and the interface's re-declaration share
 * a selector). */
function runtimeAbi(a) {
  const seen = new Set()
  const out = []
  for (const item of a.abi) {
    if (item.type === 'constructor') continue
    const sig = signature(item)
    if (seen.has(sig)) continue
    seen.add(sig)
    out.push(item)
  }
  return out
}

/** Holds the concrete contract's functions and events to its interface's: `exact` for equality, else a superset. */
function checkInterface(concrete, iface, name, exact) {
  const sigs = (abi) =>
    new Set(
      abi
        .filter((i) => i.type === 'function' || i.type === 'event')
        .map(signature),
    )
  const c = sigs(concrete)
  const i = sigs(iface)
  for (const s of i)
    if (!c.has(s)) throw new Error(`${name} lacks its interface's ${s}`)
  if (exact)
    for (const s of c)
      if (!i.has(s))
        throw new Error(`${name} has ${s}, which its interface doesn't declare`)
}

const venue = runtimeAbi(artifact('Venue.sol', 'Venue'))
const settler = runtimeAbi(artifact('Settler.sol', 'Settler'))
const factory = runtimeAbi(artifact('VenueFactory.sol', 'VenueFactory'))
const hook = runtimeAbi(artifact('IVenueHook.sol', 'IVenueHook'))
checkInterface(venue, artifact('IVenue.sol', 'IVenue').abi, 'Venue', true)
checkInterface(
  settler,
  artifact('ISettler.sol', 'ISettler').abi,
  'Settler',
  true,
)
checkInterface(
  factory,
  artifact('IVenueFactory.sol', 'IVenueFactory').abi,
  'VenueFactory',
  true,
)

/** Which contracts declare each error, by signature, for `Errors.decode`. */
const errorContracts = {}
for (const [name, abi] of [
  ['Venue', venue],
  ['Settler', settler],
  ['VenueFactory', factory],
]) {
  for (const item of abi) {
    if (item.type !== 'error') continue
    const sig = formatAbiItem(item)
    errorContracts[sig] = [...(errorContracts[sig] ?? []), name]
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Parsed source: enums and constants
// ---------------------------------------------------------------------------------------------------------------------

// Metadata binds parsed sources to the exact compiler inputs, even when an artifact has no AST.
const sources = new Map()
const targets = new Map()
for (const [key, a] of artifacts) {
  const metadata = a.metadata ?? JSON.parse(a.rawMetadata)
  const target = Object.entries(metadata.settings.compilationTarget)
  if (
    target.length !== 1 ||
    target[0][1] !== key.slice(key.lastIndexOf(':') + 1)
  )
    throw new Error(`ambiguous compilation target ${key}`)
  targets.set(key, target[0][0])
  for (const [path, info] of Object.entries(metadata.sources)) {
    const absolute = resolve(root, '../..', path)
    const repository = resolve(root, '../..')
    if (!absolute.startsWith(`${repository}/`))
      throw new Error(`source outside repository: ${path}`)
    const source = sources.get(path) ?? readFileSync(absolute, 'utf8')
    verifySource(source, info.keccak256, path)
    sources.set(path, source)
  }
}
const model = sourceModel(sources)
const enums = (file, name) => model.enums(targets.get(`${file}:${name}`), name)
const constants = (file, name) =>
  model.constants(targets.get(`${file}:${name}`), name)

// ---------------------------------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------------------------------

const HEADER =
  '// Generated by scripts/gen.mjs from the Forge build of contracts/src/v2. Do not edit.\n'

function renderAbi(name, doc, abi) {
  return `/** ${doc} */\nexport const ${name} = ${JSON.stringify(abi, null, 2)} as const\n`
}

function renderAbis() {
  const parts = [HEADER]
  parts.push(
    renderAbi(
      'venueAbi',
      "`Venue` (every `IVenue` function, event and error, plus the implementation's own errors).",
      venue,
    ),
  )
  parts.push(renderAbi('settlerAbi', '`Settler` (`ISettler`).', settler))
  parts.push(
    renderAbi(
      'venueFactoryAbi',
      '`VenueFactory` (`IVenueFactory`, plus the OpenZeppelin `Clones`/`Create2` errors).',
      factory,
    ),
  )
  parts.push(
    renderAbi(
      'venueHookAbi',
      "`IVenueHook`, the interface a pair's hook implements.",
      hook,
    ),
  )
  return parts.join('\n')
}

/** An enum member's name as the SDK reads and writes it: camelCase, as its constants are (`NotListed` is `notListed`). */
const camelMember = (name) => `${name[0].toLowerCase()}${name.slice(1)}`

function renderEnums() {
  const e = enums('IVenue.sol', 'IVenue')
  const parts = [HEADER]
  for (const name of ['AccessMode', 'TakerAccess']) {
    const members = e[name]
    if (!members) throw new Error(`IVenue.${name} missing`)
    const body = members.map((m, i) => `  ${m}: ${i},`).join('\n')
    const names = `${name[0].toLowerCase()}${name.slice(1)}Names`
    const range = `0-${members.length - 1}, 0 \`${members[0]}\``
    const example = [
      `\`IVenue.${name}\`'s values, by member, as the ABI carries them (${range}): an event's argument, a raw read.`,
      `\`${names}\` names each value as the SDK reads and writes it, in camelCase.`,
      '',
      '@example',
      '```ts',
      `import { ${name}, ${names} } from '@tempoxyz/propamm-sdk'`,
      '',
      `${names}[${name}.${members[1]}] // '${camelMember(members[1])}'`,
      '```',
    ]
    parts.push(
      `${jsdoc(example, '')}\nexport const ${name} = {\n${body}\n} as const\n/** An \`IVenue.${name}\` value, as the ABI's \`uint8\` decodes (${range}). */\nexport type ${name} = (typeof ${name})[keyof typeof ${name}]\n/** \`IVenue.${name}\`'s names, by value, in camelCase: the SDK reads and writes these. */\nexport const ${names} = ${JSON.stringify(members.map(camelMember))} as const\n/** An \`IVenue.${name}\` member's name, as the SDK reads and writes it. */\nexport type ${name}Name = (typeof ${names})[number]\n`,
    )
  }
  return parts.join('\n')
}

function renderValue(type, value) {
  if (type.startsWith('bytes'))
    return `'0x${value.toString(16).padStart(bitsOf(type) / 4, '0')}'`
  // viem's ABI typing: uint48 and narrower are numbers, wider are bigints.
  if (bitsOf(type) <= 48) return value.toString()
  return `${value}n`
}

/** A Solidity constant's name in camelCase, as the SDK exports constants: `MAX_BATCH` is `maxBatch`. */
const camel = (name) =>
  name.toLowerCase().replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase())

/**
 * Every constant, by group. A contract's `public` constants (its ABI's getters) are public; the rest are its private
 * storage layout and checks, which go to internal.ts, never the package entry. A library's constants are its interface,
 * all public.
 */
const groups = [
  ['Venue', 'Venue.sol', 'contract'],
  ['Settler', 'Settler.sol', 'contract'],
  ['VenueFactory', 'VenueFactory.sol', 'contract'],
  ['HotWord', 'HotWord.sol', 'library'],
  ['ShapeWord', 'ShapeWord.sol', 'library'],
  ['LadderMath', 'LadderMath.sol', 'library'],
  ['VenueHookFlags', 'IVenueHook.sol', 'library'],
].map(([name, file, kind]) => {
  const list = constants(file, name)
  const seen = new Set()
  for (const c of list) {
    if (seen.has(camel(c.name)))
      throw new Error(`${name}: two constants are ${camel(c.name)}`)
    seen.add(camel(c.name))
  }
  const isPublic = (c) => kind === 'library' || c.visibility === 'public'
  return {
    name,
    public: list.filter(isPublic),
    internal: list.filter((c) => !isPublic(c)),
  }
})

/**
 * The unit of each constant the package entry exports (src/constants.ts re-exports these groups), which the NatSpec
 * doesn't always say. A new public constant fails generation until it has one here.
 */
const EXPORTED = new Set(['Venue', 'VenueHookFlags'])
const UNITS = {
  'Venue.HOOK_VIEW_GAS': 'gas',
  'Venue.MAX_BATCH': 'accounts per call',
  'Venue.NO_PRIORITY_FEE_CAP': 'wei of priority fee per gas',
  'Venue.DEFAULT_TAKER_PRIORITY_FEE_CAP': 'wei of priority fee per gas',
  'VenueHookFlags.BEFORE_FILL': 'a hook flag bit',
  'VenueHookFlags.AFTER_FILL': 'a hook flag bit',
  'VenueHookFlags.TAKE_INPUT': 'a hook flag bit',
  'VenueHookFlags.ALL':
    'every hook flag bit: BEFORE_FILL | AFTER_FILL | TAKE_INPUT',
}

/** A JSDoc block at `indent`, its text's `*\/` escaped. */
function jsdoc(lines, indent) {
  const body = lines.map((l) => l.replaceAll('*/', '*\\/'))
  if (body.length === 1) return `${indent}/** ${body[0]} */`
  return [
    `${indent}/**`,
    ...body.map((l) => (l ? `${indent} * ${l}` : `${indent} *`)),
    `${indent} */`,
  ].join('\n')
}

function renderGroup(name, list, doc, exported = false) {
  const body = list
    .map((c) => {
      const unit = UNITS[`${name}.${c.name}`]
      if (exported && unit === undefined)
        throw new Error(
          `${name}.${c.name} is exported: give it a unit in scripts/gen.mjs`,
        )
      const tag = `\`${c.name}\`: \`${c.type}\`${c.visibility === 'public' ? ', public' : ''}${unit ? `; ${unit}` : ''}.`
      const lines = c.doc ? [...c.doc.split('\n'), '', tag] : [tag]
      return `${jsdoc(lines, '  ')}\n  ${camel(c.name)}: ${renderValue(c.type, c.value)},`
    })
    .join('\n')
  // An exported group shows how a consumer reads it; the example checker compiles it.
  const first = list[0]
  const lines = exported
    ? [
        doc,
        '',
        '@example',
        '```ts',
        `import { ${name} } from '@tempoxyz/propamm-sdk'`,
        '',
        `${name}.${camel(first.name)} // ${renderValue(first.type, first.value)}`,
        '```',
      ]
    : [doc]
  return `${jsdoc(lines, '')}\nexport const ${name} = {\n${body}\n} as const\n`
}

function renderConstants() {
  const parts = [HEADER]
  for (const g of groups) {
    if (g.public.length > 0)
      parts.push(
        renderGroup(
          g.name,
          g.public,
          EXPORTED.has(g.name)
            ? `\`${g.name}\`'s public constants, its ABI's getters, in camelCase.`
            : `\`${g.name}\`'s constants: the modules that port it re-export them.`,
          EXPORTED.has(g.name),
        ),
      )
  }
  return parts.join('\n')
}

/** What the SDK reads but never exports: the contracts' private constants and which contracts declare each error. */
function renderInternal() {
  const parts = [
    `${HEADER}// Internal to the SDK: the package entry re-exports nothing from this file.\n`,
  ]
  for (const g of groups) {
    if (g.internal.length > 0)
      parts.push(
        renderGroup(g.name, g.internal, `\`${g.name}\`'s private constants.`),
      )
  }
  const sorted = Object.fromEntries(
    Object.entries(errorContracts).sort(([a], [b]) =>
      a < b ? -1 : a > b ? 1 : 0,
    ),
  )
  parts.push(
    `/** The contracts that declare each error, by signature. */\nexport const errorContracts = ${JSON.stringify(sorted, null, 2)} as const\n`,
  )
  return parts.join('\n')
}

/** `text` as Biome formats it at `path` (relative to sdk/ts). */
function format(path, text) {
  const biome = join(root, 'node_modules', '.bin', 'biome')
  const result = spawnSync(biome, ['format', `--stdin-file-path=${path}`], {
    cwd: root,
    input: text,
    encoding: 'utf8',
  })
  if (result.error) throw result.error
  if (result.status !== 0)
    throw new Error(`biome format ${path} failed:\n${result.stderr}`)
  return result.stdout
}

const files = Object.fromEntries(
  Object.entries({
    'abis.ts': renderAbis(),
    'enums.ts': renderEnums(),
    'constants.ts': renderConstants(),
    'internal.ts': renderInternal(),
  }).map(([name, text]) => [name, format(`src/generated/${name}`, text)]),
)

if (process.argv.includes('--check')) {
  let stale = false
  for (const [name, text] of Object.entries(files)) {
    const path = join(genDir, name)
    if (!existsSync(path) || readFileSync(path, 'utf8') !== text) {
      process.stderr.write(`${path} is stale: run npm run gen\n`)
      stale = true
    }
  }
  if (stale) process.exit(1)
  console.log(`src/generated is up to date with ${outDir}`)
} else {
  mkdirSync(genDir, { recursive: true })
  for (const [name, text] of Object.entries(files))
    writeFileSync(join(genDir, name), text)
  console.log(
    `wrote ${Object.keys(files)
      .map((f) => `src/generated/${f}`)
      .join(', ')}`,
  )
}
