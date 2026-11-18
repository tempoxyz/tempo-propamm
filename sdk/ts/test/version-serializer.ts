// Snapshots name the package's version as `<version>`, so a release (`npm run changeset:version`) changes no snapshot.
// What the version is stays tested: test/errors.test.ts holds src/version.ts, and every error's `version`, to
// package.json's.
import type { SnapshotSerializer } from 'vitest'

/** The package's name and a version, not yet the placeholder. */
const VERSION = /(@tempoxyz\/propamm-sdk@)(?!<version>)[^\s\]"]+/
const ALL = new RegExp(VERSION.source, 'g')

const normalize = (text: string) => text.replace(ALL, '$1<version>')

export default {
  test: (value: unknown) =>
    (typeof value === 'string' && VERSION.test(value)) ||
    (value instanceof Error && VERSION.test(value.message)),
  serialize: (value, config, indentation, depth, refs, printer) =>
    typeof value === 'string'
      ? printer(normalize(value), config, indentation, depth, refs)
      : // As the snapshot prints any error: `[Name: message]`.
        `[${normalize(Error.prototype.toString.call(value))}]`,
} satisfies SnapshotSerializer
