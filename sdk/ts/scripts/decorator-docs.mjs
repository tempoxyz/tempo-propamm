// Keeps `propAmmActions()`'s docs (src/actions/decorator.ts) in step with the actions they bind: each entry's description
// and `@returns` are its action's, word for word (only the `@example` and `@param` differ, for the bound form). The
// check compares them ignoring line breaks; `--write` copies a drifted entry's from its action, rewrapped for the
// entry's indent. test/decorator-docs.test.ts runs the check, so CI fails a stale copy.
//
// Usage (from sdk/ts): node scripts/decorator-docs.mjs [--write]

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const actionsDir = join(root, 'src', 'actions')
const GROUPS = ['factory', 'maker', 'venue']
const WIDTH = 120

const JSDOC = String.raw`(\/\*\*(?:(?!\*\/)[\s\S])*\*\/)`

/** A JSDoc block's lines without the comment markers. */
function lines(doc) {
  return doc.split('\n').map((l) =>
    l
      .replace(/^\s*\/\*\*\s?/, '')
      .replace(/^\s*\*\/\s*$/, '')
      .replace(/^\s*\*\s?/, '')
      .replace(/\s*\*\/\s*$/, ''),
  )
}

/** A block's description (the lines before its first tag) and its `@returns` (until the next tag), as line lists. */
export function sections(doc) {
  const ls = lines(doc)
  const firstTag = ls.findIndex((l) => l.startsWith('@'))
  const description = ls.slice(0, firstTag < 0 ? ls.length : firstTag)
  const r = ls.findIndex((l) => l.startsWith('@returns'))
  let returns = []
  if (r >= 0) {
    const end = ls.findIndex((l, i) => i > r && l.startsWith('@'))
    returns = ls.slice(r, end < 0 ? ls.length : end)
  }
  const trim = (xs) => {
    const out = [...xs]
    while (out.length && out[0].trim() === '') out.shift()
    while (out.length && out[out.length - 1].trim() === '') out.pop()
    return out
  }
  return { description: trim(description), returns: trim(returns) }
}

/** Text compared without its line breaks. */
const flat = (xs) => xs.join(' ').replace(/\s+/g, ' ').trim()

/** Every documented action, `group.name`, with its doc's sections. */
export function actionDocs() {
  const out = new Map()
  for (const group of GROUPS) {
    const src = readFileSync(join(actionsDir, `${group}.ts`), 'utf8')
    // Top-level declarations only (an action's `call` and `extractEvent` sit indented in its namespace).
    const re = new RegExp(
      String.raw`${JSDOC}\nexport (?:async )?function (\w+)[<(]`,
      'g',
    )
    for (const m of src.matchAll(re))
      out.set(`${group}.${m[2]}`, sections(m[1]))
  }
  return out
}

/** The decorator's entries: each bound action, its doc and where the doc sits in the file. */
export function decoratorEntries(
  src = readFileSync(join(actionsDir, 'decorator.ts'), 'utf8'),
) {
  const re = new RegExp(
    String.raw`${JSDOC}(\s*)(\w+): Bound<\s*typeof (\w+)Actions\.(\w+)`,
    'g',
  )
  return [...src.matchAll(re)].map((m) => ({
    key: `${m[4]}.${m[5]}`,
    doc: m[1],
    start: m.index,
    end: m.index + m[1].length,
    indent: /\n( *)$/.exec(src.slice(0, m.index))?.[1] ?? '',
  }))
}

/** The entries whose description or `@returns` isn't their action's, and entries with no documented action. */
export function drift(src) {
  const actions = actionDocs()
  const out = []
  for (const e of decoratorEntries(src)) {
    const a = actions.get(e.key)
    if (!a) {
      out.push({ ...e, why: 'no documented action' })
      continue
    }
    const d = sections(e.doc)
    const why = [
      flat(a.description) === flat(d.description) ? '' : 'description',
      flat(a.returns) === flat(d.returns) ? '' : '@returns',
    ].filter(Boolean)
    if (why.length) out.push({ ...e, why: why.join(' and ') })
  }
  return out
}

/** Greedy-wraps a paragraph's words to `width`, the first line after `first`, the rest after `rest`. */
function wrap(words, width, first, rest) {
  const out = []
  let line = first
  let empty = true
  for (const w of words) {
    if (!empty && line.length + 1 + w.length > width) {
      out.push(line)
      line = rest + w
    } else {
      line += (empty ? '' : ' ') + w
    }
    empty = false
  }
  out.push(line)
  return out
}

/** Source lines (already comment-free) rewrapped for a ` * ` prefix of `indent`: paragraphs and `- ` items kept. */
function rewrap(src, indent) {
  const prefix = `${indent} * `
  const out = []
  let para = []
  const flush = () => {
    if (!para.length) return
    const text = para.join(' ').replace(/\s+/g, ' ').trim()
    const item = /^(- |\d+\. )/.exec(text)
    const hang = item ? ' '.repeat(item[0].length) : ''
    out.push(...wrap(text.split(' '), WIDTH, prefix, prefix + hang))
    para = []
  }
  for (const l of src) {
    if (l.trim() === '') {
      flush()
      out.push(`${indent} *`)
    } else if (/^(- |\d+\. )/.test(l.trim())) {
      flush()
      para.push(l.trim())
    } else para.push(l.trim())
  }
  flush()
  return out
}

/** `doc` with its description and `@returns` replaced by the action's, rewrapped for `indent`. */
export function synced(doc, action, indent) {
  const ls = doc.split('\n')
  const body = lines(doc)
  const firstTag = body.findIndex((l) => l.startsWith('@'))
  const r = body.findIndex((l) => l.startsWith('@returns'))
  const end = r < 0 ? -1 : body.findIndex((l, i) => i > r && l.startsWith('@'))
  // The doc's lines: `/**`, the description, its tags (with `@returns` replaced), ` */`.
  const tagLines = ls.slice(
    firstTag < 0 ? ls.length - 1 : firstTag,
    ls.length - 1,
  )
  const tags = []
  for (let i = 0; i < tagLines.length; i++) {
    const at = (firstTag < 0 ? ls.length - 1 : firstTag) + i
    if (r >= 0 && at === r) tags.push(...rewrap(action.returns, indent))
    else if (r >= 0 && at > r && (end < 0 || at < end)) continue
    else tags.push(tagLines[i])
  }
  return [
    `/**`,
    ...rewrap(action.description, indent),
    `${indent} *`,
    ...tags,
    `${indent} */`,
  ].join('\n')
}

/** The decorator's source with every drifted entry synced from its action. */
export function write(
  src = readFileSync(join(actionsDir, 'decorator.ts'), 'utf8'),
) {
  const actions = actionDocs()
  let out = src
  // From the end, so earlier offsets stay valid.
  for (const e of drift(src).reverse()) {
    const a = actions.get(e.key)
    if (!a) continue
    out = out.slice(0, e.start) + synced(e.doc, a, e.indent) + out.slice(e.end)
  }
  return out
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const path = join(actionsDir, 'decorator.ts')
  const src = readFileSync(path, 'utf8')
  if (process.argv.includes('--write')) {
    const next = write(src)
    if (next !== src) writeFileSync(path, next)
    const left = drift(next)
    process.stdout.write(`synced ${drift(src).length - left.length} entries\n`)
    if (left.length) {
      process.stderr.write(
        `${left.map((e) => `${e.key}: ${e.why}`).join('\n')}\n`,
      )
      process.exit(1)
    }
  } else {
    const d = drift(src)
    if (d.length) {
      process.stderr.write(
        `src/actions/decorator.ts is out of step with its actions (run node scripts/decorator-docs.mjs --write):\n${d.map((e) => `- ${e.key}: ${e.why}`).join('\n')}\n`,
      )
      process.exit(1)
    }
    process.stdout.write(
      `src/actions/decorator.ts matches its ${decoratorEntries(src).length} actions\n`,
    )
  }
}
