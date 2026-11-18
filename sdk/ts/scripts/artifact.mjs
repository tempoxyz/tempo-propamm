import { createHash, timingSafeEqual } from 'node:crypto'
import { gunzipSync } from 'node:zlib'

// Bound both the download and decompression; archives are never extracted.
export const MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
export const MAX_TAR_BYTES = 32 * 1024 * 1024
const block = 512
const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })
const metadataKeys = new Set([
  'mtime',
  'atime',
  'ctime',
  'uid',
  'gid',
  'uname',
  'gname',
  'SCHILY.dev',
  'SCHILY.ino',
  'SCHILY.nlink',
])

function fail(message) {
  throw new Error(`Invalid package archive: ${message}`)
}

function bounded(archive) {
  if (!(archive instanceof Uint8Array) || archive.length > MAX_ARCHIVE_BYTES)
    fail('compressed size exceeds limit or input is not bytes')
}

/** Authenticate the registry's exact compressed bytes before comparing contents. */
export function verifyIntegrity(archive, expected) {
  bounded(archive)
  if (
    typeof expected !== 'string' ||
    !/^sha512-[A-Za-z0-9+/]{86}==$/.test(expected)
  )
    throw new Error('Invalid registry SHA-512 integrity')
  const digest = Buffer.from(expected.slice(7), 'base64')
  if (digest.toString('base64') !== expected.slice(7))
    throw new Error('Invalid registry SHA-512 integrity')
  if (!timingSafeEqual(createHash('sha512').update(archive).digest(), digest))
    throw new Error('Registry archive integrity mismatch')
}

function text(bytes) {
  const end = bytes.indexOf(0)
  if (end !== -1 && bytes.subarray(end).some((value) => value !== 0))
    fail('data after NUL in header field')
  return utf8.decode(end === -1 ? bytes : bytes.subarray(0, end))
}

function octal(bytes) {
  const value = bytes
    .toString('latin1')
    .replace(/[\0 ]+$/, '')
    .replace(/^ +/, '')
  if (!/^[0-7]+$/.test(value)) fail('malformed octal header field')
  const number = Number.parseInt(value, 8)
  if (!Number.isSafeInteger(number)) fail('header integer overflow')
  return number
}

function safePath(path) {
  if (
    !path ||
    Buffer.byteLength(path) > 4096 ||
    [...path].some(
      (char) =>
        char === '\\' || char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127,
    ) ||
    path
      .split('/')
      .some(
        (part) => !part || part === '.' || part === '..' || part.includes(':'),
      )
  )
    fail('unsafe path')
  return path
}

// Only local PAX records emitted by npm are supported. Unknown extensions fail
// closed: in particular sparse files and link overrides must not look like files.
function paxFields(bytes) {
  if (bytes.length === 0) fail('empty PAX header')
  const fields = new Map()
  let offset = 0
  while (offset < bytes.length) {
    const space = bytes.indexOf(32, offset)
    if (space === -1 || space - offset > 8) fail('malformed PAX length')
    const digits = bytes.subarray(offset, space).toString('latin1')
    if (!/^[1-9][0-9]*$/.test(digits)) fail('malformed PAX length')
    const length = Number(digits)
    const end = offset + length
    if (end > bytes.length || end <= space + 2 || bytes[end - 1] !== 10)
      fail('truncated PAX record')
    const record = utf8.decode(bytes.subarray(space + 1, end - 1))
    const equal = record.indexOf('=')
    if (equal < 1 || record.includes('\0')) fail('malformed PAX record')
    const key = record.slice(0, equal)
    const value = record.slice(equal + 1)
    if (fields.has(key)) fail('duplicate PAX key')
    if (key !== 'path' && key !== 'size' && !metadataKeys.has(key))
      fail(`unsupported PAX key ${key}`)
    fields.set(key, value)
    offset = end
  }
  return fields
}

/** SHA-256 of sorted file paths, executable bits and exact bytes, not tar/gzip metadata. */
export function artifactIdentity(archive) {
  bounded(archive)
  const tar = gunzipSync(archive, { maxOutputLength: MAX_TAR_BYTES })
  if (tar.length % block !== 0) fail('truncated tar block')
  const entries = new Map()
  const files = []
  let pax
  let ended = false
  for (let offset = 0; offset < tar.length; ) {
    const header = tar.subarray(offset, offset + block)
    if (header.every((value) => value === 0)) {
      if (
        tar.length - offset < block * 2 ||
        tar.subarray(offset).some((value) => value !== 0)
      )
        fail('invalid tar terminator or trailing data')
      ended = true
      break
    }
    const checksum = header.reduce(
      (sum, value, index) => sum + (index >= 148 && index < 156 ? 32 : value),
      0,
    )
    if (octal(header.subarray(148, 156)) !== checksum)
      fail('header checksum mismatch')
    if (header.subarray(257, 265).toString('latin1') !== 'ustar\x0000')
      fail('unsupported tar format')
    const size = octal(header.subarray(124, 136))
    const mode = octal(header.subarray(100, 108))
    if (mode > 0o777) fail('unsupported file mode')
    if (text(header.subarray(157, 257))) fail('link target is forbidden')
    const type = header[156]
    if (![0, 48, 53, 120].includes(type)) fail('unsupported entry type')
    const name = text(header.subarray(0, 100))
    const prefix = text(header.subarray(345, 500))
    const headerPath = prefix ? `${prefix}/${name}` : name
    safePath(
      type === 53 && headerPath.endsWith('/')
        ? headerPath.slice(0, -1)
        : headerPath,
    )
    const start = offset + block
    const next = start + Math.ceil(size / block) * block
    if (next > tar.length) fail('truncated entry')
    if (tar.subarray(start + size, next).some((value) => value !== 0))
      fail('nonzero entry padding')
    const bytes = tar.subarray(start, start + size)
    offset = next
    if (type === 120) {
      if (pax) fail('consecutive PAX headers')
      pax = paxFields(bytes)
      continue
    }
    if (pax?.has('size') && pax.get('size') !== String(size))
      fail('PAX size disagrees with header')
    let path = pax?.get('path') ?? headerPath
    pax = undefined
    const directory = type === 53
    if (directory && path.endsWith('/')) path = path.slice(0, -1)
    safePath(path)
    if (!(path.startsWith('package/') || (directory && path === 'package')))
      fail('entry outside package/')
    if (entries.has(path)) fail('duplicate path')
    entries.set(path, directory)
    if (directory) {
      if (size !== 0) fail('directory contains data')
      continue
    }
    files.push([
      path,
      mode & 0o111,
      size,
      createHash('sha256').update(bytes).digest('hex'),
    ])
  }
  if (!ended || pax || files.length === 0)
    fail('missing terminator, orphan PAX or empty package')
  for (const path of entries.keys()) {
    for (
      let slash = path.lastIndexOf('/');
      slash !== -1;
      slash = path.lastIndexOf('/', slash - 1)
    ) {
      if (entries.get(path.slice(0, slash)) === false)
        fail('file is also a parent directory')
    }
  }
  // JSON supplies unambiguous framing; sorting is byte-independent of locale.
  files.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
  return `sha256-${createHash('sha256').update('npm-file-identity-v1\n').update(JSON.stringify(files)).digest('hex')}`
}
