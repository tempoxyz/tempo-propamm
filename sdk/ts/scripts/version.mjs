// Writes src/version.ts from package.json's version, so the SDK's errors name the version the package releases as, and
// keeps package-lock.json's own version in step. `npm run changeset:version` runs it after `changeset version` bumps
// package.json; test/errors.test.ts holds src/version.ts to package.json.
//
// Usage (from sdk/ts): node scripts/version.mjs

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
if (typeof version !== 'string' || !/^\d+\.\d+\.\d+(-[\w.]+)?$/.test(version))
  throw new Error(`package.json has no release version: ${version}`)
writeFileSync(
  join(root, 'src', 'version.ts'),
  `/** This package's version, as its package.json gives it (\`npm run changeset:version\` writes it; \`test/errors.test.ts\`\n * holds the two together). */\nexport const version = '${version}'\n`,
)
const lockPath = join(root, 'package-lock.json')
const lock = JSON.parse(readFileSync(lockPath, 'utf8'))
lock.version = version
if (lock.packages?.['']) lock.packages[''].version = version
writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
process.stdout.write(`src/version.ts and package-lock.json are ${version}\n`)
