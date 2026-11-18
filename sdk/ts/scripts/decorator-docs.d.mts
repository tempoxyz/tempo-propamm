// Types for scripts/decorator-docs.mjs, which test/decorator-docs.test.ts imports.

/** A JSDoc block's description and `@returns`, as comment-free lines. */
export type Sections = { description: string[]; returns: string[] }
/** A decorator entry: the bound action (`group.name`), its doc and where the doc sits in decorator.ts. */
export type Entry = {
  key: string
  doc: string
  start: number
  end: number
  indent: string
}

export function sections(doc: string): Sections
export function actionDocs(): Map<string, Sections>
export function decoratorEntries(src?: string): Entry[]
export function drift(src?: string): (Entry & { why: string })[]
export function synced(doc: string, action: Sections, indent: string): string
export function write(src?: string): string
