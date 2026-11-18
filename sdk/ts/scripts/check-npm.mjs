// Fails unless the npm CLI is at least the given version: the release workflow's publish job runs it before
// `changeset publish`, because trusted publishing (exchanging the job's OIDC token for a publish token) needs npm
// 11.5.1 or later, and an older npm would fall back to asking for a token the job doesn't have.
//
// Usage (from sdk/ts): node scripts/check-npm.mjs <minimum version>

import { execFileSync } from 'node:child_process'

const minimum = process.argv[2]
const parse = (v) => {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(v).trim())
  if (!m) throw new Error(`not a version: ${v}`)
  return m.slice(1, 4).map(Number)
}
const below = (a, b) => {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i]
  return false
}

const installed = execFileSync('npm', ['--version'], {
  encoding: 'utf8',
}).trim()
if (below(parse(installed), parse(minimum))) {
  process.stderr.write(`npm ${installed} is older than ${minimum}\n`)
  process.exit(1)
}
process.stdout.write(`npm ${installed} (>= ${minimum})\n`)
