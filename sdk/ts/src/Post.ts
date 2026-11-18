import {
  concatHex,
  type Hex,
  size as hexSize,
  isHex,
  numberToHex,
  sliceHex,
} from 'viem'
import * as Private from './generated/internal.js'
import * as HotWord from './HotWord.js'
import {
  DuplicatePairError,
  type DuplicatePairErrorType,
  EmptyBatchError,
  type EmptyBatchErrorType,
  type GlobalErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  InvalidHotWordError,
  type InvalidHotWordErrorType,
  InvalidOrderError,
  type InvalidOrderErrorType,
  show,
} from './internal/errors.js'
import * as checks from './internal/validate.js'
import * as Price from './Price.js'

/**
 * The complete replacement for one pair's hot word (the Rust SDK's `OrderRequest`). The optional fields take
 * `OrderRequest::new`'s defaults: no widening, both scales 1000, both sides on, no refill. A word's
 * {@link HotWord.Fields} make one as they are, `flags` in place of `sides` and `refill`, so an order built or held as
 * raw fields needs no conversion: `{ pairIndex, ...fields }`.
 *
 * @example
 * ```ts
 * import { type Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const order: Post.OrderRequest = {
 *   pairIndex: 0,
 *   mid: Price.parse('1.085'),
 *   shapeId: 7,
 *   sequence: 2,
 *   validUntil: 1_800_000_060,
 *   refill: 'asks',
 * }
 * ```
 */
export type OrderRequest = OrderRequest.Fields &
  (OrderRequest.NamedSides | OrderRequest.RawFlags)

export declare namespace OrderRequest {
  /** Every order's fields but its sides. */
  type Fields = {
    /** The pair, from 0 (`uint16`). */
    pairIndex: number
    /** Quote per 1 base, scaled by 1e18: a nonzero `uint96`, such as `Price.parse('1.085')`. */
    mid: bigint
    /** The shape the word makes active, 0-255: one `setShape` already defined. */
    shapeId: number
    /** Above the pair's stored sequence (`uint32`); a new pair stores 1, so its first post is 2 or more. */
    sequence: number
    /** Inclusive Unix seconds, below 2^40. No implicit clock or default expiry. */
    validUntil: number
    /** Extra spread on every bid level, in 0.1 bp (`uint16`, default 0). */
    bidWiden?: number | undefined
    /** Extra spread on every ask level, in 0.1 bp (`uint16`, default 0). */
    askWiden?: number | undefined
    /** Multiplier on the shape's spreads, per mille (`uint16`, default 1000: 1x). */
    widthScale?: number | undefined
    /** Multiplier on the shape's sizes, per mille (`uint16`, default 1000: 1x; 0 offers nothing). */
    depthScale?: number | undefined
  }
  /** The sides by name (the Rust SDK's `sides` and `refill`). */
  type NamedSides = {
    /** The sides that take fills (default `'both'`). */
    sides?: HotWord.Sides | undefined
    /** The sides whose consumed depth this post resets (default `'neither'`). The venue applies it once and stores
     * the word without it. */
    refill?: HotWord.Sides | undefined
    flags?: undefined
  }
  /** The sides as a word's raw flag bits, as `HotWord.Fields` holds them: never with `sides` or `refill`. */
  type RawFlags = {
    /** Bit 0 bids off, 1 asks off, 2 refill bids, 3 refill asks, 0 to 15 (`post` refuses the reserved bits 4-15). */
    flags: number
    sides?: undefined
    refill?: undefined
  }
}

/**
 * A cancel (the Rust SDK's `CancelRequest`): a newer word with no sides, `depthScale` 0, `validUntil` 0 and shape 0,
 * at `mid` (which must satisfy an agent's mid band). A newer in-flight post supersedes it; `closePair` or
 * `setHalted(true)` is a stop no later post undoes.
 *
 * @example
 * ```ts
 * import { type Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const cancel: Post.CancelRequest = { pairIndex: 0, sequence: 3, mid: Price.parse('1.085') }
 * ```
 */
export type CancelRequest = {
  /** The pair, from 0 (`uint16`). */
  pairIndex: number
  /** Above the pair's stored sequence (`uint32`, at least 2). */
  sequence: number
  /** Quote per 1 base, scaled by 1e18: a nonzero `uint96`. */
  mid: bigint
}

/**
 * One `post` entry: a pair and the 32-byte word to post for it.
 *
 * @example
 * ```ts
 * import { Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const entry: Post.Entry = Post.order({ pairIndex: 0, mid: Price.one, shapeId: 0, sequence: 2, validUntil: 1_800_000_000 })
 * ```
 */
export type Entry = {
  /** The pair, from 0 (`uint16`). */
  pairIndex: number
  /** Exactly 32 bytes of hex, refill bits included. */
  word: Hex
}

/**
 * An entry of a `post` batch as `PostOutcome` matches it against `Posted` events: its pair, its sequence and its word
 * as the venue stores and emits it (refill bits cleared).
 *
 * @example
 * ```ts
 * import { Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const { posts } = Post.pack([Post.order({ pairIndex: 0, mid: Price.one, shapeId: 0, sequence: 2, validUntil: 1_800_000_000 })])
 * const ref: Post.PostRef | undefined = posts[0] // { pairIndex: 0, sequence: 2, word: '0x…' }
 * ```
 */
export type PostRef = { pairIndex: number; sequence: number; word: Hex }

const ENTRY_BYTES = Number(Private.Venue.postEntryBytes)

/** Each field `order` checks, in its order, with its range and unit. Rust's types hold all but two of these; the two
 * it checks at run time, `validUntil` then `sequence`, keep its order. */
const ORDER_FIELDS = [
  ['shapeId', 8, 0, ''],
  ['validUntil', 40, 0, 'inclusive Unix seconds'],
  // A fresh pair stores sequence 1, so no post at 1 or below is ever accepted.
  ['sequence', 32, 2, 'above the 1 a new pair stores'],
  ['bidWiden', 16, 0, '0.1 bp'],
  ['askWiden', 16, 0, '0.1 bp'],
  ['widthScale', 16, 0, 'per mille'],
  ['depthScale', 16, 0, 'per mille'],
] as const

/**
 * Encodes an order's entry (the Rust SDK's `OrderRequest::encode`), checking every field. Each bad field throws
 * `InvalidOrderError` naming it (`parameter`) and the value given (`value`), with the order's `pairIndex` once that is
 * valid, in this order: `pairIndex`, `mid`, `shapeId`, `validUntil`, `sequence` (whose floor is 2: a new pair stores
 * 1), the widenings and scales, then `sides` and `refill`, or `flags` in their place. `validUntil` comes before
 * `sequence`, as in the Rust SDK, so both name the same first fault.
 *
 * @example
 * ```ts
 * import { Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const { pairIndex, word } = Post.order({
 *   pairIndex: 0,
 *   mid: Price.parse('1.085'),
 *   shapeId: 7,
 *   sequence: 2,
 *   validUntil: 1_800_000_060,
 * })
 * ```
 *
 * @example
 * ```ts
 * import { HotWord, Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * // A word's raw fields as they are, `flags` included: here both sides on, refilling the asks.
 * const fields: HotWord.Fields = {
 *   mid: Price.parse('1.085'),
 *   bidWiden: 0,
 *   askWiden: 0,
 *   widthScale: 1000,
 *   depthScale: 1000,
 *   shapeId: 7,
 *   validUntil: 1_800_000_060,
 *   sequence: 5,
 *   flags: HotWord.flagRefillAsks,
 * }
 * const entry = Post.order({ pairIndex: 0, ...fields })
 * ```
 *
 * @param request - The order.
 * @returns Its `post` entry.
 * @throws {InvalidOrderError} When a field is out of range; `parameter` names it and `value` holds it.
 */
export function order(request: OrderRequest): Entry {
  if (typeof request !== 'object' || request === null)
    throw new InvalidOrderError(`an order is an object, got ${show(request)}`, {
      parameter: 'request',
      value: request,
    })
  // The SDK's one pairIndex check, refused as this order's field.
  const pairIndex = checks.pairIndex(request.pairIndex, InvalidOrderError)
  const refuse = (parameter: string, value: unknown, rule: string) =>
    new InvalidOrderError(
      `pair ${pairIndex}: ${parameter} ${rule}, got ${show(value)}`,
      {
        parameter,
        value,
        pairIndex,
      },
    )
  if (!Price.validate(request.mid))
    throw refuse(
      'mid',
      request.mid,
      'must be a nonzero uint96 bigint (quote per base, scaled by 1e18)',
    )
  const fields = {
    shapeId: request.shapeId,
    validUntil: request.validUntil,
    sequence: request.sequence,
    bidWiden: request.bidWiden === undefined ? 0 : request.bidWiden,
    askWiden: request.askWiden === undefined ? 0 : request.askWiden,
    widthScale: request.widthScale === undefined ? 1000 : request.widthScale,
    depthScale: request.depthScale === undefined ? 1000 : request.depthScale,
  }
  for (const [name, bits, min, unit] of ORDER_FIELDS) {
    const value = fields[name]
    if (!checks.isUintNumber(value, bits) || value < min) {
      const max = bits <= 16 ? String(2 ** bits - 1) : `2^${bits} - 1`
      throw refuse(
        name,
        value,
        `must be an integer in [${min}, ${max}]${unit ? ` (${unit})` : ''}`,
      )
    }
  }
  if (request.flags !== undefined) {
    // Raw flag bits, as a word's HotWord.Fields hold them, in place of the named sides. The type already rules out
    // both at once; a caller without it (JavaScript, a cast) is refused here.
    const flags = request.flags
    const named = request as { sides?: unknown; refill?: unknown }
    if (named.sides !== undefined || named.refill !== undefined)
      throw refuse('flags', flags, 'must not come with sides or refill')
    if (!checks.isUintNumber(flags, 16) || (flags & ~HotWord.flagsMask) !== 0)
      throw refuse(
        'flags',
        flags,
        `must be an integer in [0, ${HotWord.flagsMask}] (bits 4-15 are reserved)`,
      )
    return {
      pairIndex,
      word: HotWord.fromFields({ mid: request.mid, ...fields, flags }),
    }
  }
  const sides = request.sides === undefined ? 'both' : request.sides
  const refill = request.refill === undefined ? 'neither' : request.refill
  for (const [name, value] of [
    ['sides', sides],
    ['refill', refill],
  ] as const) {
    if (!checks.isSides(value))
      throw refuse(name, value, "must be 'both', 'bids', 'asks' or 'neither'")
  }
  const word = HotWord.fromFields({
    mid: request.mid,
    ...fields,
    flags: HotWord.sidesFlags(sides) | HotWord.refillFlags(refill),
  })
  return { pairIndex, word }
}

export declare namespace order {
  type ErrorType = InvalidOrderErrorType | GlobalErrorType
}

/**
 * Encodes a batch of orders (the Rust SDK's `bulk_orders`), request by request: a pair already in the batch is
 * refused before the request's own fields are checked, as the Rust SDK does, so both name the same first fault.
 *
 * @example
 * ```ts
 * import { Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const entries = Post.bulkOrders([
 *   { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: 2, validUntil: 1_800_000_060 },
 *   { pairIndex: 1, mid: Price.parse('0.92'), shapeId: 7, sequence: 5, validUntil: 1_800_000_060 },
 * ])
 * const { packed } = Post.pack(entries)
 * ```
 *
 * @param requests - The orders, at most one per pair.
 * @returns Their entries, in order.
 * @throws {EmptyBatchError} When there are none.
 * @throws {DuplicatePairError} When two name one pair.
 * @throws {InvalidOrderError} When an order's field is out of range.
 */
export function bulkOrders(requests: readonly OrderRequest[]): Entry[] {
  return batch(requests, order)
}

export declare namespace bulkOrders {
  type ErrorType =
    | EmptyBatchErrorType
    | DuplicatePairErrorType
    | InvalidOrderErrorType
    | GlobalErrorType
}

/**
 * {@link bulkOrders} for cancels (the Rust SDK's `bulk_cancel`).
 *
 * @example
 * ```ts
 * import { Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const entries = Post.bulkCancel([
 *   { pairIndex: 0, sequence: 3, mid: Price.parse('1.085') },
 *   { pairIndex: 1, sequence: 6, mid: Price.parse('0.92') },
 * ])
 * ```
 *
 * @param requests - The cancels, at most one per pair.
 * @returns Their entries, in order.
 * @throws {EmptyBatchError} When there are none.
 * @throws {DuplicatePairError} When two name one pair.
 * @throws {InvalidOrderError} When a cancel's field is out of range.
 */
export function bulkCancel(requests: readonly CancelRequest[]): Entry[] {
  return batch(requests, cancel)
}

export declare namespace bulkCancel {
  type ErrorType = bulkOrders.ErrorType
}

function batch<T extends { pairIndex: number }>(
  requests: readonly T[],
  encode: (request: T) => Entry,
): Entry[] {
  if (!Array.isArray(requests) || requests.length === 0)
    throw new EmptyBatchError('a post needs at least one entry')
  const seen = new Set<number>()
  return requests.map((request) => {
    // A request that isn't an object reaches `encode`, which refuses it.
    const pairIndex =
      typeof request === 'object' && request !== null
        ? request.pairIndex
        : undefined
    if (pairIndex !== undefined) {
      if (seen.has(pairIndex)) {
        throw new DuplicatePairError(
          `pair ${pairIndex} appears twice in one batch`,
          { pairIndex },
        )
      }
      seen.add(pairIndex)
    }
    return encode(request)
  })
}

/**
 * A cancel's entry (see {@link CancelRequest}): the Rust SDK's `cancel`.
 *
 * @example
 * ```ts
 * import { HotWord, Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const { word } = Post.cancel({ pairIndex: 0, sequence: 3, mid: Price.parse('1.085') })
 * HotWord.decode(word).sides // 'neither'
 * ```
 *
 * @param request - The cancel.
 * @returns Its `post` entry.
 * @throws {InvalidOrderError} When a field is out of range; `parameter` names it and `value` holds it.
 */
export function cancel(request: CancelRequest): Entry {
  if (typeof request !== 'object' || request === null)
    throw new InvalidOrderError(`a cancel is an object, got ${show(request)}`, {
      parameter: 'request',
      value: request,
    })
  return order({
    pairIndex: request.pairIndex,
    mid: request.mid,
    shapeId: 0,
    sequence: request.sequence,
    validUntil: 0,
    depthScale: 0,
    sides: 'neither',
  })
}

export declare namespace cancel {
  type ErrorType = InvalidOrderErrorType | GlobalErrorType
}

/**
 * Packs entries into `post`'s bytes: `[uint16 pairIndex][bytes32 word]` per entry, big endian. Refuses an empty
 * batch, two entries for one pair, a word that isn't exactly 32 bytes (never padding a short one) and a word `post`
 * would revert on (zero mid or reserved flag bits), and returns each entry's {@link PostRef} for `PostOutcome`. The
 * inverse of {@link unpack}.
 *
 * @example
 * ```ts
 * import { Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const { packed, posts } = Post.pack([
 *   Post.order({ pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: 2, validUntil: 1_800_000_060 }),
 * ])
 * // packed: post's argument; posts: what PostOutcome matches
 * ```
 *
 * @param entries - The entries, at most one per pair.
 * @returns `post`'s bytes, lowercase, and each entry's {@link PostRef}.
 * @throws {EmptyBatchError} When there are none.
 * @throws {DuplicatePairError} When two name one pair.
 * @throws {InvalidArgumentError} When a `pairIndex` isn't a `uint16`, or an entry isn't an object.
 * @throws {InvalidHotWordError} When a word isn't exactly 32 bytes of hex, or `post` would revert on it.
 */
export function pack(entries: readonly Entry[]): pack.ReturnValue {
  if (!Array.isArray(entries) || entries.length === 0)
    throw new EmptyBatchError('a post needs at least one entry')
  const seen = new Set<number>()
  const parts: Hex[] = []
  const posts: PostRef[] = []
  for (const [i, entry] of entries.entries()) {
    if (typeof entry !== 'object' || entry === null)
      throw new InvalidArgumentError(
        `entries[${i}] must be a post entry, got ${show(entry)}`,
        { parameter: `entries[${i}]`, value: entry },
      )
    const pairIndex = checks.pairIndex(entry.pairIndex)
    if (seen.has(pairIndex))
      throw new DuplicatePairError(
        `pair ${pairIndex} appears twice in one batch`,
        { pairIndex },
      )
    seen.add(pairIndex)
    // Exactly 32 bytes: a shorter word is a truncation, never padded.
    if (!HotWord.validate(entry.word)) {
      throw new InvalidHotWordError(
        `pair ${pairIndex}'s word must be exactly 32 bytes of hex, got ${show(entry.word)}`,
        { word: entry.word, pairIndex, parameter: `entries[${i}].word` },
      )
    }
    if (!HotWord.isWellFormed(entry.word)) {
      throw new InvalidHotWordError(
        `pair ${pairIndex}'s word has a zero mid or reserved flag bits`,
        { word: entry.word, pairIndex, parameter: `entries[${i}].word` },
      )
    }
    const word = checks.lowerHex(entry.word)
    parts.push(numberToHex(pairIndex, { size: 2 }), word)
    posts.push({
      pairIndex,
      sequence: HotWord.decodeEntry(word).sequence,
      word: HotWord.withoutRefill(word),
    })
  }
  return { packed: concatHex(parts), posts }
}

export declare namespace pack {
  /** `post`'s argument and each entry's {@link PostRef}. */
  type ReturnValue = {
    /** `post`'s argument: 34 bytes per entry. */
    packed: Hex
    /** Each entry's pair, sequence and stored word, in order. */
    posts: PostRef[]
  }
  type ErrorType =
    | EmptyBatchErrorType
    | DuplicatePairErrorType
    | InvalidArgumentErrorType
    | InvalidHotWordErrorType
    | GlobalErrorType
}

/**
 * Splits `post`'s bytes back into entries: the inverse of {@link pack}. Refuses a length `post` would revert on
 * (`MalformedPost`); doesn't check the words.
 *
 * @example
 * ```ts
 * import { Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const entry = Post.order({ pairIndex: 3, mid: Price.one, shapeId: 0, sequence: 2, validUntil: 1_800_000_000 })
 * Post.unpack(Post.pack([entry]).packed) // [entry]
 * ```
 *
 * @param packed - `post`'s bytes.
 * @returns The entries, in order.
 * @throws {InvalidArgumentError} When `packed` isn't whole bytes of hex, or isn't a nonzero multiple of 34 bytes.
 */
export function unpack(packed: Hex): Entry[] {
  if (!isHex(packed) || packed.length % 2 !== 0) {
    throw new InvalidArgumentError('post bytes must be hex of whole bytes', {
      parameter: 'packed',
      value: packed,
    })
  }
  const length = hexSize(packed)
  if (length === 0 || length % ENTRY_BYTES !== 0) {
    throw new InvalidArgumentError(
      `post bytes must be a nonzero multiple of ${ENTRY_BYTES}, got ${length}`,
      { parameter: 'packed', value: packed },
    )
  }
  const out: Entry[] = []
  for (let at = 0; at < length; at += ENTRY_BYTES) {
    out.push({
      pairIndex: Number(BigInt(sliceHex(packed, at, at + 2))),
      word: sliceHex(packed, at + 2, at + ENTRY_BYTES),
    })
  }
  return out
}

export declare namespace unpack {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}
