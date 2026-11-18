import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'
import { gitTagEvent, tagOf } from '../scripts/publish.mjs'

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), 'utf8')

describe('the published package', () => {
  test('is publishable as public, and builds before it publishes', () => {
    const pkg = JSON.parse(read('../package.json'))
    const changesets = JSON.parse(read('../.changeset/config.json'))
    expect(pkg.private).toBeUndefined()
    // No `provenance`: trusted publishing attaches it by itself from a public repository.
    expect(pkg.publishConfig).toEqual({ access: 'public' })
    expect(changesets.access).toBe('public')
    expect(pkg.files).toContain('dist')
    // The release workflow publishes with lifecycle scripts off (NPM_CONFIG_IGNORE_SCRIPTS), so `prepack` doesn't
    // build: the publish script must.
    expect(pkg.scripts['changeset:publish']).toBe(
      'npm run build && node scripts/publish.mjs',
    )
  })

  test("tags a release with the package's name", () => {
    const pkg = { name: '@tempoxyz/propamm-sdk', version: '0.1.0' }
    expect(tagOf(pkg)).toBe('@tempoxyz/propamm-sdk@0.1.0')
    // The event changesets/action reads from CHANGESETS_OUTPUT to push the tag and create its release.
    expect(JSON.parse(gitTagEvent(pkg))).toStrictEqual({
      type: 'git-tag',
      tag: '@tempoxyz/propamm-sdk@0.1.0',
      packageName: '@tempoxyz/propamm-sdk',
    })
  })

  test("ships the repository's license", () => {
    // npm only packs a LICENSE from the package's own directory.
    expect(read('../LICENSE')).toBe(read('../../../LICENSE'))
  })
})
