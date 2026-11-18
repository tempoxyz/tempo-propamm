// Publish only from a clean checkout. A retry may ask changesets/action for a tag/release only after npm's gitHead
// and package contents both match this checkout. A completed release is a no-op, including on later main commits.
// The action consumes git-tag events even if the tag exists, so a missing GitHub release is recoverable separately.
// Its pinned pushTag implementation tolerates existing refs; we verify their peeled commit before emitting anything.
// Outside the action, publishing still verifies npm identity but only prints the tag it would request.

import { execFileSync, spawnSync } from 'node:child_process'
import {
  appendFileSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  artifactIdentity,
  MAX_ARCHIVE_BYTES,
  verifyIntegrity,
} from './artifact.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const isCommit = (value) =>
  typeof value === 'string' && /^[a-f0-9]{40}$/.test(value)
const isIntegrity = (value) =>
  typeof value === 'string' && /^sha512-[A-Za-z0-9+/]{86}==$/.test(value)

export const tagOf = (pkg) => `${pkg.name}@${pkg.version}`

/** The event requests both a tag and a release, even when only the release is missing. */
export const gitTagEvent = (pkg) =>
  `${JSON.stringify({ type: 'git-tag', tag: tagOf(pkg), packageName: pkg.name })}\n`

function checkVersion(pkg) {
  if (pkg.version === '0.0.0')
    throw new Error(
      'the package is at 0.0.0: version it first (npm run changeset:version)',
    )
}

/** Parse npm's JSON, never interpreting an empty response, malformed JSON or an unrelated error as absence. */
export function parseNpmMetadata(pkg, result) {
  let value
  try {
    value = JSON.parse(result.stdout)
  } catch {
    throw new Error(`npm view ${tagOf(pkg)} returned invalid JSON`)
  }
  if (result.status !== 0) {
    if (result.status !== null && value?.error?.code === 'E404') return null
    throw new Error(
      `npm view ${tagOf(pkg)} failed: ${value?.error?.code ?? result.status}`,
    )
  }
  if (value?.name !== pkg.name || value?.version !== pkg.version || value.error)
    throw new Error(`npm view ${tagOf(pkg)} returned unexpected metadata`)
  return value
}

export function npmMetadata(pkg, cwd = root) {
  return parseNpmMetadata(
    pkg,
    spawnSync(
      'npm',
      [
        'view',
        tagOf(pkg),
        '--json',
        '--fetch-retries=0',
        '--registry=https://registry.npmjs.org/',
      ],
      {
        cwd,
        encoding: 'utf8',
        timeout: 30_000,
      },
    ),
  )
}

/** npm records gitHead at publish time; reject dirty sources and a workflow targeting a different commit. */
export function checkoutHead(cwd = root, env = process.env) {
  const git = (...args) =>
    execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()
  // npm reads .git/HEAD directly rather than following Git's worktree gitfile.
  // Reject these layouts before publishing an immutable version with no gitHead.
  const gitRoot = git('rev-parse', '--show-toplevel')
  if (
    !statSync(join(gitRoot, '.git'), { throwIfNoEntry: false })?.isDirectory()
  )
    throw new Error(
      'release requires a standalone git clone with a .git directory; linked worktrees and separate git directories omit npm gitHead',
    )
  // npm resolves loose or packed refs, not Git's reftable backend. The config
  // query also works on older Git versions without --show-ref-format.
  if (
    git('config', '--get', '--default', 'files', 'extensions.refStorage') !==
    'files'
  )
    throw new Error(
      'release requires Git files ref storage so npm can record gitHead',
    )
  const head = git('rev-parse', 'HEAD')
  if (!isCommit(head)) throw new Error('cannot determine the release commit')
  if (git('status', '--porcelain', '--untracked-files=all'))
    throw new Error(
      'release requires a clean git checkout (including untracked files)',
    )
  if ((env.CHANGESETS_OUTPUT || env.GITHUB_SHA) && env.GITHUB_SHA !== head)
    throw new Error('GITHUB_SHA must match the release checkout HEAD')
  return head
}

/** Compare installed file bytes, names and executable bits, not gzip headers or compression output. */
export function packArtifact(pkg, cwd = root) {
  const destination = mkdtempSync(join(tmpdir(), 'propamm-release-pack-'))
  try {
    const packed = JSON.parse(
      execFileSync(
        'npm',
        [
          'pack',
          '--ignore-scripts',
          '--json',
          '--pack-destination',
          destination,
        ],
        { cwd, encoding: 'utf8' },
      ),
    )
    const entry = packed[0]
    if (
      packed.length !== 1 ||
      entry?.name !== pkg.name ||
      entry?.version !== pkg.version ||
      !isIntegrity(entry?.integrity) ||
      typeof entry.filename !== 'string' ||
      !/^[a-zA-Z0-9._-]+\.tgz$/.test(entry.filename)
    )
      throw new Error('npm pack returned unexpected package identity')
    const bytes = readFileSync(join(destination, entry.filename))
    verifyIntegrity(bytes, entry.integrity)
    return artifactIdentity(bytes)
  } finally {
    rmSync(destination, { recursive: true, force: true })
  }
}

/** Only the public npm registry is a valid source; never forward credentials or follow redirects. */
export function registryTarballUrl(metadata) {
  let url
  try {
    url = new URL(metadata?.dist?.tarball)
  } catch {
    throw new Error('npm tarball URL missing or invalid')
  }
  if (
    url.origin !== 'https://registry.npmjs.org' ||
    url.username ||
    url.password ||
    url.hash ||
    url.search
  )
    throw new Error('npm tarball URL must use the public npm registry')
  return url.href
}

export async function registryArtifact(metadata) {
  const response = await fetch(registryTarballUrl(metadata), {
    redirect: 'error',
    signal: AbortSignal.timeout(30_000),
  })
  if (response.status === 404) return null
  if (!response.ok) throw new Error(`npm tarball: HTTP ${response.status}`)
  const chunks = []
  let size = 0
  for await (const chunk of response.body) {
    size += chunk.length
    if (size > MAX_ARCHIVE_BYTES)
      throw new Error('npm tarball exceeds size limit')
    chunks.push(chunk)
  }
  const bytes = Buffer.concat(chunks)
  verifyIntegrity(bytes, metadata.dist.integrity)
  return artifactIdentity(bytes)
}

/** Read tag and release independently, peeling annotated tags without trusting API-provided URLs. */
export async function githubState(tag, env = process.env) {
  const { GITHUB_TOKEN: token, GITHUB_REPOSITORY: repo } = env
  if (!token && !repo && !env.CHANGESETS_OUTPUT) return undefined
  if (!token || !repo)
    throw new Error(
      'GitHub token and repository are required to check release state',
    )
  const api = env.GITHUB_API_URL ?? 'https://api.github.com'
  const get = async (path) => {
    const response = await fetch(`${api}/repos/${repo}/${path}`, {
      headers: {
        authorization: `Bearer ${token}`,
        accept: 'application/vnd.github+json',
      },
    })
    if (response.status === 404) return null
    if (!response.ok) throw new Error(`GET ${path}: HTTP ${response.status}`)
    const body = await response.json()
    if (!body || typeof body !== 'object' || Array.isArray(body))
      throw new Error(`GET ${path}: invalid JSON object`)
    return body
  }
  const ref = await get(`git/ref/tags/${encodeURIComponent(tag)}`)
  let tagCommit = null
  if (ref !== null) {
    if (ref.ref !== `refs/tags/${tag}`)
      throw new Error('GitHub returned an unexpected tag ref')
    let object = ref.object
    const seen = new Set()
    while (object?.type === 'tag') {
      if (!isCommit(object.sha) || seen.has(object.sha) || seen.size >= 8)
        throw new Error('cannot resolve annotated release tag')
      seen.add(object.sha)
      object = (await get(`git/tags/${object.sha}`))?.object
    }
    if (object?.type !== 'commit' || !isCommit(object.sha))
      throw new Error('release tag does not resolve to a commit')
    tagCommit = object.sha
  }
  const release = await get(`releases/tags/${encodeURIComponent(tag)}`)
  if (release !== null && (release.tag_name !== tag || release.draft !== false))
    throw new Error('GitHub returned an unexpected or draft release')
  if (release !== null && tagCommit === null)
    throw new Error('GitHub release exists without its tag')
  return { tagCommit, releaseExists: release !== null }
}

function verifyPublished(pkg, metadata) {
  if (
    metadata?.name !== pkg.name ||
    metadata?.version !== pkg.version ||
    !isCommit(metadata.gitHead) ||
    !isIntegrity(metadata.dist?.integrity)
  )
    throw new Error(
      `npm identity missing or invalid for ${tagOf(pkg)} (gitHead and sha512 integrity required)`,
    )
}

/** Decide before any write. Completion may be a no-op on later main commits; any recovery must use the original. */
export function plan({ pkg, metadata, github, head }) {
  checkVersion(pkg)
  if (metadata !== null) verifyPublished(pkg, metadata)
  const expectedCommit = metadata?.gitHead ?? head
  if (github?.tagCommit && github.tagCommit !== expectedCommit)
    throw new Error('release tag points to a different source commit')
  if (metadata !== null && github?.tagCommit && github.releaseExists)
    return { publish: false, tag: false }
  if (metadata !== null && metadata.gitHead !== head)
    throw new Error(
      'npm gitHead does not match this checkout; retry the original release commit',
    )
  return { publish: metadata === null, tag: github?.releaseExists !== true }
}

/** Post-publish reads can lag. Retry only absence/incomplete identity, never a conflicting identity or API error. */
async function publishedArtifact(pkg, io, head, artifact) {
  const delays = [0, 1000, 2000, 4000, 8000, 15000, 30000]
  for (const delay of delays) {
    if (delay)
      await (
        io.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)))
      )(delay)
    const metadata = io.metadata()
    if (metadata === null) continue
    if (metadata.gitHead !== undefined && metadata.gitHead !== head)
      throw new Error(
        'published npm identity does not match the release source',
      )
    if (
      metadata.dist?.integrity !== undefined &&
      !isIntegrity(metadata.dist.integrity)
    )
      throw new Error('published npm identity has invalid integrity')
    if (
      metadata.gitHead === undefined ||
      metadata.dist?.integrity === undefined ||
      metadata.dist?.tarball === undefined
    )
      continue
    verifyPublished(pkg, metadata)
    const remote = await io.publishedArtifact(metadata)
    if (remote === null) continue
    if (remote !== artifact)
      throw new Error(
        'published npm artifact identity does not match this checkout',
      )
    return
  }
  throw new Error(
    'npm identity is not visible after bounded readback retries; retry recovery without republishing',
  )
}

/** Injectable I/O keeps release transitions testable without publishing anything. */
export async function runRelease(pkg, io) {
  checkVersion(pkg)
  const head = io.head()
  const metadata = io.metadata()
  const github = await io.github(tagOf(pkg))
  const step = plan({ pkg, metadata, github, head })
  if (!step.publish && !step.tag) return step
  const artifact = io.artifact()
  if (step.publish) {
    io.publish()
    // The CLI may race with another publisher or skip a package. Its exit code alone proves nothing.
    await publishedArtifact(pkg, io, head, artifact)
  } else if ((await io.publishedArtifact(metadata)) !== artifact) {
    throw new Error(
      'npm artifact identity does not match this checkout; refusing release recovery',
    )
  }
  if (step.tag) {
    if (io.head() !== head || io.artifact() !== artifact)
      throw new Error('release source or artifact changed while publishing')
    io.emit(gitTagEvent(pkg))
  }
  return step
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
  const step = await runRelease(pkg, {
    head: () => checkoutHead(),
    metadata: () => npmMetadata(pkg),
    github: (tag) => githubState(tag),
    artifact: () => packArtifact(pkg),
    publishedArtifact: (metadata) => registryArtifact(metadata),
    publish: () => {
      // Do not let the CLI emit a default v<version> event or tag. Only verified results reach the action.
      const { CHANGESETS_OUTPUT: _, ...env } = process.env
      execFileSync(
        'npx',
        ['--no-install', 'changeset', 'publish', '--no-git-tag'],
        {
          cwd: root,
          stdio: 'inherit',
          env: { ...env, NPM_CONFIG_IGNORE_SCRIPTS: 'true' },
        },
      )
    },
    emit: (event) => {
      if (process.env.CHANGESETS_OUTPUT)
        appendFileSync(process.env.CHANGESETS_OUTPUT, event)
      else process.stdout.write(`the release's tag would be ${tagOf(pkg)}\n`)
    },
  })
  if (!step.publish && !step.tag)
    process.stdout.write(`${tagOf(pkg)} is already released\n`)
}
