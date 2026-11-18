import { execFileSync, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, test } from 'vitest'
import {
  checkoutHead,
  githubState,
  gitTagEvent,
  packArtifact,
  parseNpmMetadata,
  plan,
  registryTarballUrl,
  runRelease,
} from '../scripts/publish.mjs'

const pkg = { name: '@tempoxyz/propamm-sdk', version: '0.1.0' }
const head = 'a'.repeat(40)
const other = 'b'.repeat(40)
const integrity = `sha512-${Buffer.alloc(64, 1).toString('base64')}`
const differentIntegrity = `sha512-${Buffer.alloc(64, 2).toString('base64')}`
const metadata = {
  ...pkg,
  gitHead: head,
  dist: {
    integrity,
    tarball:
      'https://registry.npmjs.org/@tempoxyz/propamm-sdk/-/propamm-sdk-0.1.0.tgz',
  },
}
const artifact = 'contents-a'
const publishedArtifact = async (value: unknown) =>
  (value as typeof metadata).dist.integrity === differentIntegrity
    ? 'contents-b'
    : artifact
const sleep = async () => {}
const missing = { tagCommit: null, releaseExists: false }
const tagged = { tagCommit: head, releaseExists: false }
const complete = { tagCommit: head, releaseExists: true }

describe('release identity and recovery', () => {
  test('publishes a new release, recovers either missing tag or release, then does nothing', () => {
    const decide = (
      value: typeof metadata | null,
      github: typeof missing | typeof tagged,
    ) => plan({ pkg, metadata: value, github, head })
    expect(decide(null, missing)).toEqual({ publish: true, tag: true })
    expect(decide(metadata, missing)).toEqual({ publish: false, tag: true })
    expect(decide(metadata, tagged)).toEqual({ publish: false, tag: true })
    expect(decide(metadata, complete)).toEqual({ publish: false, tag: false })
  })

  test('a fully released version is a no-op on a later main commit, even with different package bytes', () => {
    expect(
      plan({
        pkg,
        metadata,
        github: complete,
        head: other,
      }),
    ).toEqual({ publish: false, tag: false })
  })

  test.each([missing, tagged, undefined])(
    'recovery requires the exact original commit, not just equal bytes (%j)',
    (github) => {
      expect(() => plan({ pkg, metadata, github, head: other })).toThrow(
        'gitHead',
      )
    },
  )

  test.each([
    { ...pkg, dist: { integrity } },
    { ...pkg, gitHead: head },
    { ...metadata, gitHead: 'not-a-commit' },
    { ...metadata, dist: { integrity: 'sha1-not-enough' } },
    { ...metadata, version: '0.2.0' },
  ])('refuses missing or malformed npm identity (%j)', (value) => {
    expect(() => plan({ pkg, metadata: value, github: missing, head })).toThrow(
      'identity',
    )
  })

  test.each([false, true])(
    'rejects a wrong tag target, even when release exists=%s',
    (releaseExists) => {
      expect(() =>
        plan({
          pkg,
          metadata,
          github: { tagCommit: other, releaseExists },
          head,
        }),
      ).toThrow('different source commit')
    },
  )

  test.each([
    { value: { ...metadata, gitHead: other }, github: missing },
    {
      value: {
        ...metadata,
        dist: { ...metadata.dist, integrity: differentIntegrity },
      },
      github: tagged,
    },
    { value: { ...pkg }, github: missing },
    { value: null, github: { tagCommit: other, releaseExists: false } },
  ])(
    'preflight failures neither publish nor emit (%j)',
    async ({ value, github }) => {
      const actions: string[] = []
      await expect(
        runRelease(pkg, {
          head: () => head,
          metadata: () => value,
          github: async () => github,
          artifact: () => artifact,
          publishedArtifact,
          sleep,
          publish: () => actions.push('publish'),
          emit: (event: string) => actions.push(event),
        }),
      ).rejects.toThrow()
      expect(actions).toEqual([])
    },
  )

  test('the release runner is a no-op on later main commits after completion', async () => {
    const actions: string[] = []
    expect(
      await runRelease(pkg, {
        head: () => other,
        metadata: () => metadata,
        github: async () => complete,
        artifact: () => {
          throw new Error('completed releases need no artifact reads')
        },
        publishedArtifact,
        publish: () => actions.push('publish'),
        emit: (event: string) => actions.push(event),
      }),
    ).toEqual({ publish: false, tag: false })
    expect(actions).toEqual([])
  })

  test('a manual first publish uses the same identity checks and event format', async () => {
    const actions: string[] = []
    let published = false
    const result = await runRelease(pkg, {
      head: () => head,
      metadata: () => (published ? metadata : null),
      github: async () => undefined,
      artifact: () => artifact,
      publishedArtifact,
      sleep,
      publish: () => {
        published = true
        actions.push('publish')
      },
      emit: (event: string) => actions.push(event),
    })
    expect(result).toEqual({ publish: true, tag: true })
    expect(actions).toEqual(['publish', gitTagEvent(pkg)])
  })

  test.each([missing, tagged, complete])(
    'retry never republishes npm (%j)',
    async (github) => {
      const actions: string[] = []
      await runRelease(pkg, {
        head: () => head,
        metadata: () => metadata,
        github: async () => github,
        artifact: () => artifact,
        publishedArtifact,
        sleep,
        publish: () => actions.push('publish'),
        emit: (event: string) => actions.push(event),
      })
      expect(actions).toEqual(github.releaseExists ? [] : [gitTagEvent(pkg)])
    },
  )

  test.each([
    null,
    { ...metadata, gitHead: other },
    { ...metadata, dist: { ...metadata.dist, integrity: differentIntegrity } },
  ])(
    'a successful publisher exit is insufficient; recheck npm before emitting (%j)',
    async (result) => {
      const actions: string[] = []
      let published = false
      await expect(
        runRelease(pkg, {
          head: () => head,
          metadata: () => (published ? result : null),
          github: async () => missing,
          artifact: () => artifact,
          publishedArtifact,
          sleep,
          publish: () => {
            published = true
          },
          emit: (event: string) => actions.push(event),
        }),
      ).rejects.toThrow('identity')
      expect(actions).toEqual([])
    },
  )

  test('publisher failure never emits a tag event', async () => {
    const actions: string[] = []
    await expect(
      runRelease(pkg, {
        head: () => head,
        metadata: () => null,
        github: async () => missing,
        artifact: () => artifact,
        publishedArtifact,
        sleep,
        publish: () => {
          throw new Error('publish failed')
        },
        emit: (event: string) => actions.push(event),
      }),
    ).rejects.toThrow('publish failed')
    expect(actions).toEqual([])
  })

  test.each(['head', 'artifact'])(
    'refuses %s changes while publishing',
    async (changed) => {
      let published = false
      const actions: string[] = []
      await expect(
        runRelease(pkg, {
          head: () => (published && changed === 'head' ? other : head),
          metadata: () => (published ? metadata : null),
          github: async () => missing,
          artifact: () =>
            published && changed === 'artifact' ? 'changed' : artifact,
          publishedArtifact,
          sleep,
          publish: () => {
            published = true
          },
          emit: (event: string) => actions.push(event),
        }),
      ).rejects.toThrow('changed while publishing')
      expect(actions).toEqual([])
    },
  )

  test('waits for metadata and tarball propagation without publishing twice', async () => {
    const values = [
      null,
      null,
      { ...pkg },
      { ...metadata, dist: undefined },
      metadata,
      metadata,
    ]
    const delays: number[] = []
    const actions: string[] = []
    let downloads = 0
    await runRelease(pkg, {
      head: () => head,
      metadata: () => (values.length ? values.shift() : metadata),
      github: async () => missing,
      artifact: () => artifact,
      publishedArtifact: async () => (++downloads === 1 ? null : artifact),
      sleep: async (ms) => {
        delays.push(ms)
      },
      publish: () => {
        actions.push('publish')
      },
      emit: () => {
        actions.push('emit')
      },
    })
    expect(actions).toEqual(['publish', 'emit'])
    expect(delays).toEqual([1000, 2000, 4000, 8000])
  })

  test('bounded propagation timeout never republishes or emits', async () => {
    let publishes = 0
    let reads = 0
    const delays: number[] = []
    await expect(
      runRelease(pkg, {
        head: () => head,
        metadata: () => {
          reads++
          return null
        },
        github: async () => missing,
        artifact: () => artifact,
        publishedArtifact,
        sleep: async (ms) => {
          delays.push(ms)
        },
        publish: () => {
          publishes++
        },
        emit: () => {
          throw new Error('must not emit')
        },
      }),
    ).rejects.toThrow('bounded readback retries')
    expect(publishes).toBe(1)
    expect(reads).toBe(8)
    expect(delays.reduce((a, b) => a + b, 0)).toBe(60_000)
  })

  test('compression differences do not block recovery of identical files', async () => {
    const actions: string[] = []
    await runRelease(pkg, {
      head: () => head,
      metadata: () => ({
        ...metadata,
        dist: { ...metadata.dist, integrity: differentIntegrity },
      }),
      github: async () => tagged,
      artifact: () => artifact,
      publishedArtifact: async () => artifact,
      publish: () => {
        throw new Error('must not republish')
      },
      emit: () => {
        actions.push('emit')
      },
    })
    expect(actions).toEqual(['emit'])
  })

  test.each([
    'https://evil.invalid/file.tgz',
    'https://registry.npmjs.org@evil.invalid/file.tgz',
    'http://registry.npmjs.org/file.tgz',
    'https://user:secret@registry.npmjs.org/file.tgz',
    undefined,
  ])('refuses unsafe tarball URL %s', (tarball) => {
    expect(() => registryTarballUrl({ dist: { tarball } })).toThrow('URL')
  })

  test.each([
    { ...metadata, gitHead: other },
    { ...metadata, dist: { ...metadata.dist, integrity: 'malformed' } },
    { ...metadata, dist: { ...metadata.dist, integrity: differentIntegrity } },
  ])(
    'conflicting published identity fails immediately, not after retry (%j)',
    async (value) => {
      let published = false
      await expect(
        runRelease(pkg, {
          head: () => head,
          metadata: () => (published ? value : null),
          github: async () => missing,
          artifact: () => artifact,
          publishedArtifact,
          sleep: async () => {
            throw new Error('must not retry a conflict')
          },
          publish: () => {
            published = true
          },
          emit: () => {
            throw new Error('must not emit')
          },
        }),
      ).rejects.toThrow('identity')
    },
  )

  test('refuses 0.0.0 before any I/O', async () => {
    const unexpected = () => {
      throw new Error('unexpected I/O')
    }
    await expect(
      runRelease(
        { ...pkg, version: '0.0.0' },
        {
          head: unexpected,
          metadata: unexpected,
          github: unexpected,
          artifact: unexpected,
          publishedArtifact: unexpected,
          publish: unexpected,
          emit: unexpected,
        },
      ),
    ).rejects.toThrow('version it first')
  })
})

describe('npm metadata JSON', () => {
  test('only an explicit npm E404 means absent', () => {
    expect(
      parseNpmMetadata(pkg, {
        status: 1,
        stdout: JSON.stringify({ error: { code: 'E404' } }),
      }),
    ).toBeNull()
    expect(
      parseNpmMetadata(pkg, { status: 0, stdout: JSON.stringify(metadata) }),
    ).toEqual(metadata)
  })

  // Observed with npm 11.5.1, 11.16.0 and 11.19.1: missing exact versions emit structured E404 on stdout.
  // Exit 0 + empty stdout instead occurs when querying an absent field on an existing version, not absence.
  test('accepts the real npm 11 exact-version absence response', () => {
    expect(
      parseNpmMetadata(pkg, {
        status: 1,
        stdout: JSON.stringify({
          error: {
            code: 'E404',
            summary: 'No match found for version 9999.0.0',
            detail:
              "The requested resource 'is-number@9999.0.0' could not be found or you do not have permission to access it.",
          },
        }),
      }),
    ).toBeNull()
  })

  test.each([
    { status: 0, stdout: '' },
    { status: 0, stdout: '"0.1.0"' },
    { status: 0, stdout: '{}' },
    { status: 0, stdout: JSON.stringify({ ...metadata, version: '0.2.0' }) },
    { status: 0, stdout: JSON.stringify({ error: { code: 'E404' } }) },
    { status: 1, stdout: '404 Not Found' },
    {
      status: 1,
      stdout: JSON.stringify({ error: { code: 'E401', summary: '404' } }),
    },
    { status: 1, stdout: JSON.stringify({ error: { code: 'E500' } }) },
    { status: null, stdout: JSON.stringify({ error: { code: 'E404' } }) },
  ])('fails closed on malformed data and errors (%j)', (result) => {
    expect(() => parseNpmMetadata(pkg, result)).toThrow()
  })
})

const directories: string[] = []
afterEach(() => {
  for (const directory of directories.splice(0))
    rmSync(directory, { recursive: true, force: true })
})

describe('real local checkout and npm pack identity', () => {
  test.for(['worktree', 'separate-git-dir', 'reftable'])(
    'rejects a clean %s checkout before publishing',
    async (layout, context) => {
      const base = mkdtempSync(join(tmpdir(), 'propamm-release-layout-'))
      directories.push(base)
      const source = join(base, 'source')
      mkdirSync(source)
      const git = (...args: string[]) =>
        execFileSync('git', args, {
          cwd: source,
          encoding: 'utf8',
          stdio: 'pipe',
        }).trim()
      if (layout === 'separate-git-dir')
        git('init', '-q', '--separate-git-dir', join(base, 'git-data'))
      else if (layout === 'reftable') {
        const initialized = spawnSync(
          'git',
          ['init', '-q', '--ref-format=reftable'],
          {
            cwd: source,
            encoding: 'utf8',
          },
        )
        if (
          initialized.status !== 0 &&
          initialized.stderr.includes('unknown option')
        ) {
          context.skip('requires Git with reftable support (2.45+)')
          return
        }
        expect(initialized.status, initialized.stderr).toBe(0)
      } else git('init', '-q')
      git('config', 'user.name', 'Release test')
      git('config', 'user.email', 'release@example.invalid')
      // Exercise the monorepo's nested-package layout too.
      mkdirSync(join(source, 'sdk/ts'), { recursive: true })
      writeFileSync(join(source, 'sdk/ts/package.json'), JSON.stringify(pkg))
      git('add', '.')
      git('commit', '-qm', 'fixture')
      let checkout = source
      if (layout === 'worktree') {
        checkout = join(base, 'linked')
        git('worktree', 'add', '--detach', checkout, 'HEAD')
      }
      const cwd = join(checkout, 'sdk/ts')
      expect(
        execFileSync('git', ['status', '--porcelain'], {
          cwd,
          encoding: 'utf8',
        }),
      ).toBe('')
      const actions: string[] = []
      await expect(
        runRelease(pkg, {
          head: () => checkoutHead(cwd, {}),
          metadata: () => null,
          github: async () => undefined,
          artifact: () => artifact,
          publishedArtifact,
          publish: () => actions.push('publish'),
          emit: (event: string) => actions.push(event),
        }),
      ).rejects.toThrow(
        layout === 'reftable'
          ? 'Git files ref storage'
          : 'standalone git clone',
      )
      expect(actions).toEqual([])
    },
  )

  test('requires clean source and matching workflow SHA, and hashes the exact packed artifact', () => {
    const cwd = mkdtempSync(join(tmpdir(), 'propamm-release-'))
    directories.push(cwd)
    const git = (...args: string[]) =>
      execFileSync('git', args, { cwd, encoding: 'utf8', stdio: 'pipe' }).trim()
    git('init', '-q')
    git('config', 'user.name', 'Release test')
    git('config', 'user.email', 'release@example.invalid')
    writeFileSync(
      join(cwd, 'package.json'),
      JSON.stringify({
        ...pkg,
        files: ['dist'],
        scripts: { prepack: 'exit 99' },
      }),
    )
    writeFileSync(join(cwd, '.gitignore'), 'dist/\n')
    git('add', '.')
    git('commit', '-qm', 'fixture')
    const commit = git('rev-parse', 'HEAD')
    mkdirSync(join(cwd, 'dist'))
    writeFileSync(join(cwd, 'dist/index.js'), 'export const value = 1\n')
    expect(checkoutHead(cwd, {})).toBe(commit)
    expect(
      checkoutHead(cwd, {
        CHANGESETS_OUTPUT: 'event-file',
        GITHUB_SHA: commit,
      }),
    ).toBe(commit)
    expect(() => checkoutHead(cwd, { GITHUB_SHA: other })).toThrow('GITHUB_SHA')
    expect(() =>
      checkoutHead(cwd, { CHANGESETS_OUTPUT: 'event-file' }),
    ).toThrow('GITHUB_SHA')
    const content = packArtifact(pkg, cwd)
    expect(packArtifact(pkg, cwd)).toBe(content)
    writeFileSync(join(cwd, 'dist/index.js'), 'export const value = 2\n')
    expect(packArtifact(pkg, cwd)).not.toBe(content)
    writeFileSync(join(cwd, 'unexpected'), 'not ignored')
    expect(() => checkoutHead(cwd, {})).toThrow('clean git checkout')
    rmSync(join(cwd, 'unexpected'))
    writeFileSync(
      join(cwd, 'package.json'),
      JSON.stringify({ ...pkg, description: 'dirty' }),
    )
    expect(() => checkoutHead(cwd, {})).toThrow('clean git checkout')
    git('add', '.')
    expect(() => checkoutHead(cwd, {})).toThrow('clean git checkout')
  }, 20_000)
})

async function withGitHub(
  routes: Record<string, { status: number; body: unknown }>,
  run: (env: Record<string, string>, requests: string[]) => Promise<void>,
) {
  const requests: string[] = []
  const server = createServer((request, response) => {
    const path = decodeURIComponent(request.url ?? '').replace(
      '/repos/fixture/repo/',
      '',
    )
    requests.push(path)
    const route = routes[path] ?? { status: 404, body: {} }
    response.writeHead(route.status, { 'content-type': 'application/json' })
    response.end(
      typeof route.body === 'string' ? route.body : JSON.stringify(route.body),
    )
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string')
    throw new Error('server address missing')
  try {
    await run(
      {
        GITHUB_TOKEN: 'fixture',
        GITHUB_REPOSITORY: 'fixture/repo',
        GITHUB_API_URL: `http://127.0.0.1:${address.port}`,
      },
      requests,
    )
  } finally {
    server.closeAllConnections()
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    )
  }
}

const tag = `${pkg.name}@${pkg.version}`
const tagPath = `git/ref/tags/${tag}`
const releasePath = `releases/tags/${tag}`
const ref = (type: string, sha: string) => ({
  status: 200,
  body: { ref: `refs/tags/${tag}`, object: { type, sha } },
})

describe('GitHub tag and release reads against a local HTTP server', () => {
  test.each([false, true])(
    'reads releases independently of existing lightweight tags (released=%s)',
    async (releaseExists) => {
      await withGitHub(
        {
          [tagPath]: ref('commit', head),
          ...(releaseExists
            ? {
                [releasePath]: {
                  status: 200,
                  body: { tag_name: tag, draft: false },
                },
              }
            : {}),
        },
        async (env, requests) => {
          expect(await githubState(tag, env)).toEqual({
            tagCommit: head,
            releaseExists,
          })
          expect(requests).toContain(releasePath)
        },
      )
    },
  )

  test('resolves annotated tags to their commit, not their tag-object SHA', async () => {
    await withGitHub(
      {
        [tagPath]: ref('tag', other),
        [`git/tags/${other}`]: {
          status: 200,
          body: { object: { type: 'commit', sha: head } },
        },
      },
      async (env) => {
        expect(await githubState(tag, env)).toEqual(tagged)
      },
    )
  })

  test('reports both missing for a new release', async () => {
    await withGitHub({}, async (env) =>
      expect(await githubState(tag, env)).toEqual(missing),
    )
  })

  test.each([
    { [tagPath]: { status: 403, body: {} } },
    { [tagPath]: { status: 200, body: 'not json' } },
    { [tagPath]: { status: 200, body: null } },
    {
      [tagPath]: ref('commit', head),
      [releasePath]: { status: 200, body: null },
    },
    { [tagPath]: { status: 200, body: [] } },
    { [tagPath]: ref('blob', head) },
    {
      [tagPath]: ref('tag', other),
      [`git/tags/${other}`]: {
        status: 200,
        body: { object: { type: 'tag', sha: other } },
      },
    },
    {
      [tagPath]: ref('commit', head),
      [releasePath]: { status: 500, body: {} },
    },
    {
      [tagPath]: ref('commit', head),
      [releasePath]: { status: 200, body: { tag_name: 'wrong', draft: false } },
    },
    {
      [tagPath]: ref('commit', head),
      [releasePath]: { status: 200, body: { tag_name: tag, draft: true } },
    },
    { [releasePath]: { status: 200, body: { tag_name: tag, draft: false } } },
  ])(
    'fails closed on malformed or unavailable GitHub state (%j)',
    async (routes) => {
      await withGitHub(routes, async (env) => {
        await expect(githubState(tag, env)).rejects.toThrow()
      })
    },
  )

  test('only fully manual runs can omit GitHub credentials', async () => {
    expect(await githubState(tag, {})).toBeUndefined()
    await expect(
      githubState(tag, { CHANGESETS_OUTPUT: 'event-file' }),
    ).rejects.toThrow('required')
    await expect(
      githubState(tag, { GITHUB_REPOSITORY: 'fixture/repo' }),
    ).rejects.toThrow('required')
  })
})
