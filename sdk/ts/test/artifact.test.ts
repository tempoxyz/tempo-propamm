import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { gunzipSync, gzipSync } from 'node:zlib'
import { describe, expect, test } from 'vitest'
import {
  artifactIdentity,
  MAX_ARCHIVE_BYTES,
  MAX_TAR_BYTES,
  verifyIntegrity,
} from '../scripts/artifact.mjs'

function checksum(header: Buffer) {
  header.fill(32, 148, 156)
  const sum = header.reduce((total, byte) => total + byte, 0)
  header.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148, 'ascii')
  return header
}

function entry(
  path = 'package/index.js',
  contents = 'hello',
  options: {
    type?: string
    mode?: number
    mtime?: number
    uid?: number
    prefix?: string
  } = {},
) {
  const data = Buffer.from(contents)
  const header = Buffer.alloc(512)
  header.write(path, 0, 100)
  const octal = (offset: number, width: number, value: number) =>
    header.write(
      `${value.toString(8).padStart(width - 1, '0')}\0`,
      offset,
      'ascii',
    )
  octal(100, 8, options.mode ?? 0o644)
  octal(108, 8, options.uid ?? 0)
  octal(116, 8, 0)
  octal(124, 12, data.length)
  octal(136, 12, options.mtime ?? 1)
  header.write(options.type ?? '0', 156, 'ascii')
  header.write('ustar\x0000', 257, 'ascii')
  if (options.prefix) header.write(options.prefix, 345, 155)
  checksum(header)
  return Buffer.concat([
    header,
    data,
    Buffer.alloc((512 - (data.length % 512)) % 512),
  ])
}

function archive(...entries: Buffer[]) {
  return gzipSync(Buffer.concat([...entries, Buffer.alloc(1024)]))
}

function sri(bytes: Uint8Array) {
  return `sha512-${createHash('sha512').update(bytes).digest('base64')}`
}

function pax(key: string, value: string) {
  const record = ` ${key}=${value}\n`
  let length = Buffer.byteLength(record) + 1
  while (String(length).length + Buffer.byteLength(record) !== length)
    length = String(length).length + Buffer.byteLength(record)
  return `${length}${record}`
}

const original = archive(entry())

describe('package artifact identity', () => {
  test('real offline npm pack supports executable files, Unicode, prefixes and PAX long paths', () => {
    const dir = mkdtempSync(join(tmpdir(), 'propamm-artifact-'))
    try {
      const longName = `${'long'.repeat(35)}.js`
      const deep = ['directory'.repeat(8), 'nested'.repeat(12)].join('/')
      const pkg = { name: 'artifact-fixture', version: '1.0.0', bin: 'cli.js' }
      const manifest = JSON.stringify(pkg)
      const cli = '#!/usr/bin/env node\nconsole.log("fixture")\n'
      const files = [
        ['package.json', manifest],
        ['cli.js', cli],
        [longName, 'long path bytes'],
        [`${deep}/file.js`, 'prefix bytes'],
        ['日本語.js', 'unicode bytes'],
      ] as const
      mkdirSync(join(dir, deep), { recursive: true })
      for (const [path, bytes] of files) writeFileSync(join(dir, path), bytes)
      chmodSync(join(dir, 'cli.js'), 0o755)
      // No network, install, lifecycle script or publish. Destination is removed below.
      const packed = JSON.parse(
        execFileSync(
          'npm',
          ['pack', '--json', '--ignore-scripts', '--offline'],
          {
            cwd: dir,
            encoding: 'utf8',
            timeout: 30_000,
          },
        ),
      )[0] as { filename: string; integrity: string }
      const tarball = readFileSync(join(dir, packed.filename))
      const tar = gunzipSync(tarball)
      expect(tar.includes(Buffer.from('PaxHeader/'))).toBe(true)
      const recompressed = gzipSync(tar, { level: 0 })
      expect(sri(recompressed)).not.toBe(packed.integrity)
      verifyIntegrity(tarball, packed.integrity)
      verifyIntegrity(recompressed, sri(recompressed))
      expect(() => verifyIntegrity(recompressed, packed.integrity)).toThrow(
        'integrity mismatch',
      )
      expect(artifactIdentity(recompressed)).toBe(artifactIdentity(tarball))
      // A separately built tar, different order and metadata, has the same files.
      const canonical = files.toReversed().flatMap(([path, bytes]) => [
        entry('PaxHeader/file', pax('path', `package/${path}`), {
          type: 'x',
        }),
        entry('package/file', bytes, {
          mode: path === 'cli.js' ? 0o755 : 0o644,
        }),
      ])
      expect(artifactIdentity(archive(...canonical))).toBe(
        artifactIdentity(tarball),
      )
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }, 40_000)

  test('ignores order, ownership, time, directory entries and non-executable permission differences', () => {
    const a = archive(entry(), entry('package/other', 'other'))
    const b = archive(
      entry('package/', '', { type: '5', mode: 0o755 }),
      entry('package/other', 'other', { uid: 123, mtime: 999 }),
      entry('package/index.js', 'hello', { mode: 0o600 }),
    )
    expect(artifactIdentity(a)).toBe(artifactIdentity(b))
    expect(artifactIdentity(a)).toMatch(/^sha256-[a-f0-9]{64}$/)
  })

  test.each([
    entry('package/index.js', 'hellO'),
    entry('package/renamed.js'),
    entry('package/index.js', 'hello', { mode: 0o755 }),
    entry('package/index.js', 'hello', { mode: 0o744 }),
  ])(
    'changed bytes, paths or executable bits change identity (%#)',
    (changed) => {
      expect(artifactIdentity(archive(changed))).not.toBe(
        artifactIdentity(original),
      )
    },
  )

  test('preserves binary bytes and every executable bit', () => {
    expect(artifactIdentity(archive(entry('package/data', 'a\0b')))).not.toBe(
      artifactIdentity(archive(entry('package/data', 'a\0c'))),
    )
    expect(
      artifactIdentity(archive(entry('package/cli', 'x', { mode: 0o755 }))),
    ).not.toBe(
      artifactIdentity(archive(entry('package/cli', 'x', { mode: 0o744 }))),
    )
    expect(() =>
      artifactIdentity(archive(entry('package/cli', 'x', { mode: 0o4755 }))),
    ).toThrow('mode')
  })

  test('PAX and USTAR prefix paths resolve to the same canonical path', () => {
    const prefixed = archive(entry('index.js', 'hello', { prefix: 'package' }))
    const extended = archive(
      entry(
        'PaxHeader/file',
        pax('path', 'package/index.js') + pax('size', '5'),
        { type: 'x' },
      ),
      entry('package/fallback'),
    )
    expect(artifactIdentity(prefixed)).toBe(artifactIdentity(original))
    expect(artifactIdentity(extended)).toBe(artifactIdentity(original))
  })

  test.each([
    '../escape',
    '/package/index.js',
    'other/index.js',
    'package/../escape',
    'package/./file',
    'package//file',
    'package/a\\b',
    'package/C:drive',
    'package/a\0b',
    'package/file/',
  ])('rejects unsafe path %s', (path) => {
    expect(() => artifactIdentity(archive(entry(path)))).toThrow()
    expect(() =>
      artifactIdentity(
        archive(
          entry('PaxHeader/file', pax('path', path), { type: 'x' }),
          entry(),
        ),
      ),
    ).toThrow()
  })

  test.each(['1', '2', '3', '4', '6', '7', 'g', 'L', 'K', 'S'])(
    'rejects links and unsupported type %s',
    (type) => {
      expect(() =>
        artifactIdentity(archive(entry('package/file', '', { type }))),
      ).toThrow('unsupported entry type')
    },
  )

  test('rejects duplicate and file/directory conflicting paths in either order', () => {
    const duplicatePax = entry(
      'PaxHeader/file',
      pax('path', 'package/index.js'),
      { type: 'x' },
    )
    for (const entries of [
      [entry(), entry()],
      [entry(), duplicatePax, entry('package/other')],
      [entry(), entry('package/index.js/child')],
      [entry('package/index.js/child'), entry()],
      [entry(), entry('package/index.js/', '', { type: '5' })],
    ])
      expect(() => artifactIdentity(archive(...entries))).toThrow()
  })

  test('rejects malformed headers, checksums, truncation, padding and trailers', () => {
    const corrupt = entry()
    corrupt[0] = 99
    const badSize = entry()
    badSize.fill(57, 124, 136)
    checksum(badSize.subarray(0, 512))
    const badFormat = entry()
    badFormat[257] = 0
    checksum(badFormat.subarray(0, 512))
    const nonzeroPadding = entry()
    nonzeroPadding[600] = 1
    const linkTarget = entry()
    linkTarget.write('package/target', 157)
    checksum(linkTarget.subarray(0, 512))
    const badUtf8 = entry()
    badUtf8[10] = 255
    checksum(badUtf8.subarray(0, 512))
    for (const bytes of [
      corrupt,
      badSize,
      badFormat,
      nonzeroPadding,
      linkTarget,
      badUtf8,
    ])
      expect(() => artifactIdentity(archive(bytes))).toThrow()
    for (const bytes of [
      Buffer.alloc(1024),
      entry(),
      entry().subarray(0, 512),
      Buffer.concat([entry(), Buffer.alloc(512)]),
      Buffer.concat([entry(), Buffer.alloc(1024), entry()]),
      Buffer.concat([entry(), Buffer.alloc(1025)]),
    ])
      expect(() => artifactIdentity(gzipSync(bytes))).toThrow()
    expect(() => artifactIdentity(original.subarray(0, -1))).toThrow()
  })

  test.each([
    '',
    '99 path=package/file\n',
    '0 path=package/file\n',
    'x path=package/file\n',
    pax('path', 'package/file') + pax('path', 'package/other'),
    pax('linkpath', 'package/file'),
    pax('GNU.sparse.size', '5'),
    pax('size', '999'),
    pax('size', '-1'),
    pax('size', '05'),
  ])(
    'rejects ambiguous, truncated and unsupported PAX records (%#)',
    (records) => {
      expect(() =>
        artifactIdentity(
          archive(entry('PaxHeader/file', records, { type: 'x' }), entry()),
        ),
      ).toThrow()
    },
  )

  test('rejects orphan and consecutive PAX records', () => {
    const extended = entry('PaxHeader/file', pax('path', 'package/index.js'), {
      type: 'x',
    })
    expect(() => artifactIdentity(archive(extended))).toThrow()
    expect(() =>
      artifactIdentity(archive(extended, extended, entry())),
    ).toThrow()
  })

  test('bounds compressed and decompressed input', () => {
    const huge = Buffer.alloc(MAX_ARCHIVE_BYTES + 1)
    expect(() => artifactIdentity(huge)).toThrow('compressed size')
    expect(() => verifyIntegrity(huge, sri(huge))).toThrow('compressed size')
    const bomb = gzipSync(Buffer.alloc(MAX_TAR_BYTES + 1))
    expect(() => artifactIdentity(bomb)).toThrow()
  })

  test('authenticates the exact archive and rejects invalid or absent SHA-512 SRI', () => {
    expect(() => verifyIntegrity(original, sri(original))).not.toThrow()
    for (const integrity of [
      '',
      'sha1-anything',
      `${sri(original)} `,
      'sha512-AAAA',
      `sha512-${'A'.repeat(85)}B==`,
      sri(Buffer.from('different bytes')),
    ])
      expect(() => verifyIntegrity(original, integrity)).toThrow(/integrity/i)
  })
})
