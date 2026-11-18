// Typechecks every ```ts example in the JSDoc of src/**/*.ts and in README.md, each as its own module that imports
// `@tempoxyz/propamm-sdk` by name, as a consumer's code would.
//
// Usage (from sdk/ts):
//   node scripts/check-examples.mjs                     every example (npm run examples:check)
//   node scripts/check-examples.mjs src/Price.ts ...    only those files' examples
//
// It builds the package's declarations into a temporary directory, as `node_modules/@tempoxyz/propamm-sdk` with this
// package.json (so the name resolves through its `exports`, to the build, never to src/), links viem beside it, writes
// each example there as a module, and typechecks them all in one strict program: strict, exactOptionalPropertyTypes
// and noUncheckedIndexedAccess, as the SDK itself compiles, with the ES2023 and DOM libraries (for `console`) and no
// Node types, so an example that reads `process.env` fails. A broken example fails with its source file and line. A
// block fenced ```ts no-check is skipped: keep those rare, for a fragment that can't stand alone, and say why next to
// it. The temporary directory is removed however the check ends.

import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const packageName = '@tempoxyz/propamm-sdk'

/** Every `.ts` file under `dir`, sorted, so the report's order is stable. */
function sources(dir) {
  return readdirSync(dir, { withFileTypes: true, recursive: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.ts'))
    .map((entry) => join(entry.parentPath, entry.name))
    .sort()
}

/**
 * The fenced blocks in `lines` (`text`, from line `firstLine`, 1-based): `{ line, info, code }`, where `line` is the
 * source line of the block's first line of code. `strip` takes the comment prefix off each line.
 */
function fences(file, lines, firstLine, strip) {
  const out = []
  let open
  lines.forEach((raw, i) => {
    const line = strip(raw)
    const fence = /^(\s*)```(.*)$/.exec(line)
    if (open === undefined) {
      if (fence) {
        const info = fence[2].trim()
        open = {
          indent: fence[1].length,
          info,
          line: firstLine + i + 1,
          code: [],
        }
      }
      return
    }
    if (fence && fence[2].trim() === '') {
      out.push({
        file,
        line: open.line,
        info: open.info,
        code: open.code.join('\n'),
      })
      open = undefined
      return
    }
    open.code.push(
      line.slice(Math.min(open.indent, /^\s*/.exec(line)[0].length)),
    )
  })
  if (open !== undefined)
    throw new Error(
      `${relative(root, file)}:${open.line - 1}: unclosed code fence`,
    )
  return out
}

/** The fenced blocks in a source file's JSDoc comments, with their source lines. */
function jsdocBlocks(file) {
  const text = readFileSync(file, 'utf8')
  const out = []
  for (const match of text.matchAll(/\/\*\*[\s\S]*?\*\//g)) {
    const firstLine = text.slice(0, match.index).split('\n').length
    const lines = match[0]
      .replace(/^\/\*\*/, '')
      .replace(/\*\/$/, '')
      .split('\n')
    out.push(
      ...fences(file, lines, firstLine, (line) => line.replace(/^\s*\* ?/, '')),
    )
  }
  return out
}

/** The fenced blocks in a Markdown file. */
function markdownBlocks(file) {
  return fences(file, readFileSync(file, 'utf8').split('\n'), 1, (line) => line)
}

const files = [...sources(join(root, 'src')), join(root, 'README.md')]
const only = process.argv.slice(2).map((file) => resolve(file))
for (const file of only) {
  if (!files.includes(file))
    throw new Error(`${file} is neither a source file under src/ nor README.md`)
}
const blocks = files
  .filter((file) => only.length === 0 || only.includes(file))
  .flatMap((file) =>
    file.endsWith('.md') ? markdownBlocks(file) : jsdocBlocks(file),
  )
const typescript = blocks.filter((b) => /^(ts|typescript)(\s|$)/.test(b.info))
const skipped = typescript.filter((b) => /(^|\s)no-check(\s|$)/.test(b.info))
const examples = typescript.filter((b) => !skipped.includes(b))
const where = (b) => `${relative(root, b.file)}:${b.line}`

const temp = mkdtempSync(join(tmpdir(), 'propamm-examples-'))
let failed = false
try {
  // The package as a consumer installs it: its package.json and declarations built from src/ now.
  const pkg = join(temp, 'node_modules', ...packageName.split('/'))
  mkdirSync(pkg, { recursive: true })
  copyFileSync(join(root, 'package.json'), join(pkg, 'package.json'))
  const build = ts.getParsedCommandLineOfConfigFile(
    join(root, 'tsconfig.build.json'),
    {
      outDir: join(pkg, 'dist'),
      declaration: true,
      emitDeclarationOnly: true,
      declarationMap: false,
      sourceMap: false,
      noEmit: false,
    },
    { ...ts.sys, onUnRecoverableConfigFileDiagnostic: report },
  )
  const emitted = ts.createProgram(build.fileNames, build.options).emit()
  if (emitted.diagnostics.length > 0 || emitted.emitSkipped) {
    for (const d of emitted.diagnostics) report(d)
    throw new Error('the package does not build: run npm run typecheck')
  }
  symlinkSync(
    realpathSync(join(root, 'node_modules', 'viem')),
    join(temp, 'node_modules', 'viem'),
    'dir',
  )

  writeFileSync(
    join(temp, 'package.json'),
    `${JSON.stringify({ private: true, type: 'module' })}\n`,
  )
  const dir = join(temp, 'examples')
  mkdirSync(dir)
  const byPath = new Map()
  for (const b of examples) {
    const name = `${relative(root, b.file).replace(/[^A-Za-z0-9]+/g, '_')}_${b.line}.ts`
    const path = join(dir, name)
    writeFileSync(path, `${b.code}\n`)
    byPath.set(realpathSync(path), b)
  }

  const program = ts.createProgram([...byPath.keys()], {
    strict: true,
    exactOptionalPropertyTypes: true,
    noUncheckedIndexedAccess: true,
    noImplicitOverride: true,
    noFallthroughCasesInSwitch: true,
    target: ts.ScriptTarget.ES2022,
    lib: ['lib.es2023.d.ts', 'lib.dom.d.ts'],
    module: ts.ModuleKind.NodeNext,
    moduleResolution: ts.ModuleResolutionKind.NodeNext,
    moduleDetection: ts.ModuleDetectionKind.Force,
    isolatedModules: true,
    types: [],
    skipLibCheck: true,
    noEmit: true,
  })
  for (const d of ts.getPreEmitDiagnostics(program)) {
    failed = true
    const b = d.file && byPath.get(realpathSync(d.file.fileName))
    if (!b || d.start === undefined) {
      report(d)
      continue
    }
    const { line, character } = d.file.getLineAndCharacterOfPosition(d.start)
    process.stderr.write(
      `${relative(root, b.file)}:${b.line + line}:${character + 1} (example at ${where(b)}): error TS${d.code}: ${ts.flattenDiagnosticMessageText(d.messageText, '\n')}\n`,
    )
  }
} finally {
  rmSync(temp, { recursive: true, force: true })
}

function report(d) {
  process.stderr.write(
    `${ts.formatDiagnostic(d, { getCanonicalFileName: (f) => f, getCurrentDirectory: () => root, getNewLine: () => '\n' })}`,
  )
}

const fileCount = new Set(examples.map((b) => b.file)).size
for (const b of skipped) console.log(`skipped (no-check): ${where(b)}`)
if (failed) {
  process.stderr.write(
    `examples:check failed: ${examples.length} examples in ${fileCount} files\n`,
  )
  process.exit(1)
}
console.log(
  `typechecked ${examples.length} examples in ${fileCount} files against ${packageName}'s build${skipped.length > 0 ? `, skipped ${skipped.length} (no-check)` : ''}`,
)
