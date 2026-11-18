import { type Hex, isHex, numberToHex } from 'viem'
import { HotWord as Constants } from './generated/constants.js'
import {
  type GlobalErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  InvalidHotWordError,
  type InvalidHotWordErrorType,
  type InvalidPriceErrorType,
  show,
} from './internal/errors.js'
import * as checks from './internal/validate.js'

/**
 * Which of a pair's sides take fills (the Rust SDK's `Sides`). A taker selling base walks the bids; one buying base
 * walks the asks. As a refill, the sides whose consumed depth a post resets.
 *
 * @example
 * ```ts
 * import type { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * const sides: HotWord.Sides = 'asks' // the bids are off
 * ```
 */
export type Sides = 'both' | 'bids' | 'asks' | 'neither'

/**
 * Every field of a hot word, as `HotWord.Fields` in contracts/src/v2/libraries/HotWord.sol lays them out from bit 0
 * (`seq` there is `sequence` here), `flags` raw.
 *
 * @example
 * ```ts
 * import { HotWord, Price } from '@tempoxyz/propamm-sdk'
 *
 * const fields: HotWord.Fields = {
 *   mid: Price.parse('1.085'),
 *   bidWiden: 0,
 *   askWiden: 0,
 *   widthScale: 1000,
 *   depthScale: 1000,
 *   shapeId: 7,
 *   validUntil: 1_800_000_060,
 *   sequence: 2,
 *   flags: 0,
 * }
 * HotWord.fromFields(fields)
 * ```
 */
export type Fields = {
  /** Quote per 1 base, scaled by 1e18 (`uint96`, bits 0-95). 0 only in a pair never posted. */
  mid: bigint
  /** Extra spread on every bid level, in 0.1 bp (`uint16`, bits 96-111). */
  bidWiden: number
  /** Extra spread on every ask level, in 0.1 bp (`uint16`, bits 112-127). */
  askWiden: number
  /** Multiplier on ladder spreads, per mille: 1000 is 1x (`uint16`, bits 128-143). */
  widthScale: number
  /** Multiplier on ladder sizes, per mille: 0 offers no depth (`uint16`, bits 144-159). */
  depthScale: number
  /** The active shape, 0-255 (`uint8`, bits 160-167). */
  shapeId: number
  /** Inclusive Unix seconds: the pair fills while `block.timestamp <= validUntil` (`uint40`, bits 168-207). */
  validUntil: number
  /** The word's `seq`, strictly increasing per pair; a new pair stores 1 (`uint32`, bits 208-239). */
  sequence: number
  /** Bit 0 bids off, bit 1 asks off, bit 2 refill bids, bit 3 refill asks; 4-15 reserved (`uint16`, bits 240-255). */
  flags: number
}

/**
 * A stored or emitted hot word, decoded: the venue never stores the refill bits, so only `sides` is left of the
 * flags. The Rust SDK's `HotWord`.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * const hot: HotWord.HotWord = HotWord.decode(HotWord.initial)
 * hot.sequence // 1
 * ```
 */
export type HotWord = Omit<Fields, 'flags'> & { sides: Sides }

/**
 * A `post` entry's word, decoded: it may also carry refill bits.
 *
 * @example
 * ```ts
 * import { HotWord, Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const { word } = Post.order({
 *   pairIndex: 0,
 *   mid: Price.one,
 *   shapeId: 0,
 *   sequence: 2,
 *   validUntil: 1_800_000_000,
 *   refill: 'asks',
 * })
 * const entry: HotWord.Entry = HotWord.decodeEntry(word)
 * entry.refill // 'asks'
 * ```
 */
export type Entry = HotWord & { refill: Sides }

// The `HotWord` library's constants (contracts/src/v2/libraries/HotWord.sol), its flags in bits 240-255.

/**
 * `HotWord.FLAG_BIDS_OFF`, flag bit 0 (value 1): the bids take no fills.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.sidesFlags('asks') === HotWord.flagBidsOff // true
 * ```
 */
export const flagBidsOff = Constants.flagBidsOff
/**
 * `HotWord.FLAG_ASKS_OFF`, flag bit 1 (value 2): the asks take no fills.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.sidesFlags('bids') === HotWord.flagAsksOff // true
 * ```
 */
export const flagAsksOff = Constants.flagAsksOff
/**
 * `HotWord.FLAG_REFILL_BIDS`, flag bit 2 (value 4): an accepted `post` entry resets the bids' consumed depth to 0.
 * Never stored.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.refillFlags('bids') === HotWord.flagRefillBids // true
 * ```
 */
export const flagRefillBids = Constants.flagRefillBids
/**
 * `HotWord.FLAG_REFILL_ASKS`, flag bit 3 (value 8): an accepted `post` entry resets the asks' consumed depth to 0.
 * Never stored.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.refillFlags('asks') === HotWord.flagRefillAsks // true
 * ```
 */
export const flagRefillAsks = Constants.flagRefillAsks
/**
 * `HotWord.FLAGS_REFILL`: both refill bits (value 12).
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.refillFlags('both') === HotWord.flagsRefill // true
 * ```
 */
export const flagsRefill = Constants.flagsRefill
/**
 * `HotWord.FLAGS_MASK`: every flag bit `post` accepts, bits 0-3 (value 15); bits 4-15 are reserved.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * const reserved = (flags: number) => (flags & ~HotWord.flagsMask) !== 0
 * ```
 */
export const flagsMask = Constants.flagsMask
/**
 * `HotWord.INITIAL`, the 32-byte word `addPair` stores: sequence 1, everything else 0, so the pair can't fill until
 * its first post (at sequence 2 or more).
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.decode(HotWord.initial).sequence // 1
 * HotWord.isWellFormed(HotWord.initial) // false: mid 0
 * ```
 */
export const initial: Hex = Constants.initial

const LAYOUT = [
  ['mid', 96],
  ['bidWiden', 16],
  ['askWiden', 16],
  ['widthScale', 16],
  ['depthScale', 16],
  ['shapeId', 8],
  ['validUntil', 40],
  ['sequence', 32],
  ['flags', 16],
] as const

/**
 * The off flags for the sides that take fills.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.sidesFlags('neither') // 3: both sides off
 * ```
 *
 * @param sides - The sides that take fills.
 * @returns The flag bits, 0 to 3.
 * @throws {InvalidArgumentError} When `sides` isn't a `Sides` value.
 */
export function sidesFlags(sides: Sides): number {
  switch (checks.sides(sides, 'sides')) {
    case 'both':
      return 0
    case 'bids':
      return flagAsksOff
    case 'asks':
      return flagBidsOff
    case 'neither':
      return flagBidsOff | flagAsksOff
  }
}

export declare namespace sidesFlags {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * The refill flags for the sides a post refills.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.refillFlags('both') // 12
 * ```
 *
 * @param sides - The sides whose consumed depth the post resets.
 * @returns The flag bits: 0, 4, 8 or 12.
 * @throws {InvalidArgumentError} When `sides` isn't a `Sides` value.
 */
export function refillFlags(sides: Sides): number {
  switch (checks.sides(sides, 'refill')) {
    case 'both':
      return flagsRefill
    case 'bids':
      return flagRefillBids
    case 'asks':
      return flagRefillAsks
    case 'neither':
      return 0
  }
}

export declare namespace refillFlags {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * The sides that take fills under a word's flags: the inverse of {@link sidesFlags}. The refill bits (2-3) are ignored.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.sidesFromFlags(HotWord.flagAsksOff) // 'bids'
 * HotWord.sidesFromFlags(HotWord.sidesFlags('neither') | HotWord.refillFlags('both')) // 'neither'
 * ```
 *
 * @param flags - A word's flag bits (0 to 15; `post` refuses the reserved bits 4-15).
 * @returns The sides that take fills.
 * @throws {InvalidArgumentError} When `flags` isn't an integer in [0, 15].
 */
export function sidesFromFlags(flags: number): Sides {
  return sidesOf(publicFlags(flags))
}

export declare namespace sidesFromFlags {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * The sides a post with these flags refills: the inverse of {@link refillFlags}. The off bits (0-1) are ignored.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.refillFromFlags(HotWord.flagsRefill) // 'both'
 * HotWord.refillFromFlags(HotWord.flagAsksOff) // 'neither'
 * ```
 *
 * @param flags - A word's flag bits (0 to 15; `post` refuses the reserved bits 4-15).
 * @returns The sides whose consumed depth the post resets.
 * @throws {InvalidArgumentError} When `flags` isn't an integer in [0, 15].
 */
export function refillFromFlags(flags: number): Sides {
  return refillOf(publicFlags(flags))
}

export declare namespace refillFromFlags {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/** `flags` as the public decoders take it: an integer with no reserved bit (4-15) set. */
function publicFlags(flags: number): number {
  // Bounded before any bit test: `&` truncates to 32 bits, so 2**32 + 1 would pass a mask check alone.
  if (!Number.isSafeInteger(flags) || flags < 0 || flags > flagsMask) {
    throw new InvalidArgumentError(
      `flags must be an integer in [0, ${flagsMask}], got ${show(flags)}`,
      {
        parameter: 'flags',
        value: flags,
      },
    )
  }
  return flags
}

function sidesOf(offBits: number): Sides {
  const bidsOff = (offBits & flagBidsOff) !== 0
  const asksOff = (offBits & flagAsksOff) !== 0
  if (bidsOff && asksOff) return 'neither'
  if (bidsOff) return 'asks'
  if (asksOff) return 'bids'
  return 'both'
}

function refillOf(flags: number): Sides {
  const bids = (flags & flagRefillBids) !== 0
  const asks = (flags & flagRefillAsks) !== 0
  if (bids && asks) return 'both'
  if (bids) return 'bids'
  if (asks) return 'asks'
  return 'neither'
}

/**
 * Packs every field into a word (Solidity's `HotWord.pack`), each checked against its bit width. No other rule: the
 * venue's own are {@link isWellFormed}'s. The inverse of {@link toFields}.
 *
 * @example
 * ```ts
 * import { HotWord, Price } from '@tempoxyz/propamm-sdk'
 *
 * const word = HotWord.fromFields({
 *   mid: Price.one,
 *   bidWiden: 0,
 *   askWiden: 0,
 *   widthScale: 1000,
 *   depthScale: 1000,
 *   shapeId: 0,
 *   validUntil: 1_800_000_000,
 *   sequence: 2,
 *   flags: HotWord.sidesFlags('both'),
 * })
 * ```
 *
 * @param fields - Every field, `flags` raw.
 * @returns The 32-byte word.
 * @throws {InvalidPriceError} When `mid` isn't a `uint96` bigint (0 is a word's own, never posted).
 * @throws {InvalidHotWordError} When another field is out of its bit width; `parameter` names it.
 */
export function fromFields(fields: Fields): Hex {
  if (typeof fields !== 'object' || fields === null)
    throw new InvalidHotWordError(
      `a hot word's fields are an object, got ${show(fields)}`,
      { parameter: 'fields', value: fields },
    )
  let word = 0n
  let at = 0n
  for (const [name, bits] of LAYOUT) {
    const value = fields[name]
    const v =
      name === 'mid'
        ? checks.mid(value as bigint, 'mid')
        : typeof value === 'bigint'
          ? checks.uintBigint(value, bits, name, InvalidHotWordError)
          : BigInt(checks.uintNumber(value, bits, name, InvalidHotWordError))
    word |= v << at
    at += BigInt(bits)
  }
  return numberToHex(word, { size: 32 })
}

export declare namespace fromFields {
  type ErrorType =
    | InvalidHotWordErrorType
    | InvalidPriceErrorType
    | GlobalErrorType
}

/**
 * Unpacks every field of a word (Solidity's `HotWord.unpack`), `flags` raw. The inverse of {@link fromFields}; never
 * throws for a 32-byte word.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.toFields(HotWord.initial).sequence // 1
 * ```
 *
 * @param word - The word: exactly 32 bytes of hex.
 * @returns Its fields.
 * @throws {InvalidHotWordError} When `word` isn't exactly 32 bytes of hex.
 */
export function toFields(word: Hex): Fields {
  let rest = toWord(word)
  const out: Record<string, bigint | number> = {}
  for (const [name, bits] of LAYOUT) {
    const v = rest & ((1n << BigInt(bits)) - 1n)
    out[name] = name === 'mid' ? v : Number(v)
    rest >>= BigInt(bits)
  }
  return out as Fields
}

export declare namespace toFields {
  type ErrorType = InvalidHotWordErrorType | GlobalErrorType
}

/**
 * Decodes a stored or `Posted` word (the Rust SDK's `HotWord::decode`). Strict: flags above 3 (the refill bits, which
 * the venue never stores, and the reserved bits) are an error. The initial word (mid 0, sequence 1) decodes.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * const hot = HotWord.decode(HotWord.initial)
 * hot.mid // 0n: never posted
 * hot.sides // 'both'
 * ```
 *
 * @param word - The word: exactly 32 bytes of hex.
 * @returns The decoded word.
 * @throws {InvalidHotWordError} When `word` isn't exactly 32 bytes of hex, or carries a flag above bit 1.
 */
export function decode(word: Hex): HotWord {
  const { flags, ...fields } = toFields(word)
  if (flags > (flagBidsOff | flagAsksOff)) {
    throw new InvalidHotWordError(
      `stored hot words carry only the off flags (0-3), got flags ${flags}`,
      { word, flags },
    )
  }
  return { ...fields, sides: sidesOf(flags) }
}

export declare namespace decode {
  type ErrorType = InvalidHotWordErrorType | GlobalErrorType
}

/**
 * Decodes a `post` entry's word: refill bits allowed, reserved bits (4-15) refused, as `post` refuses them.
 *
 * @example
 * ```ts
 * import { HotWord, Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const { word } = Post.order({
 *   pairIndex: 0,
 *   mid: Price.one,
 *   shapeId: 0,
 *   sequence: 2,
 *   validUntil: 1_800_000_000,
 *   refill: 'both',
 * })
 * HotWord.decodeEntry(word).refill // 'both'
 * ```
 *
 * @param word - The entry's word: exactly 32 bytes of hex.
 * @returns The decoded entry.
 * @throws {InvalidHotWordError} When `word` isn't exactly 32 bytes of hex, or sets a reserved flag bit.
 */
export function decodeEntry(word: Hex): Entry {
  const { flags, ...fields } = toFields(word)
  if ((flags & ~flagsMask) !== 0) {
    throw new InvalidHotWordError(
      `reserved flag bits (4-15) set, got flags ${flags}`,
      { word, flags },
    )
  }
  return { ...fields, sides: sidesOf(flags), refill: refillOf(flags) }
}

export declare namespace decodeEntry {
  type ErrorType = InvalidHotWordErrorType | GlobalErrorType
}

/**
 * `HotWord.isWellFormed`: whether `post` accepts the word, a nonzero mid and no reserved flag bits.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.isWellFormed(HotWord.initial) // false: mid 0
 * ```
 *
 * @param word - The word: exactly 32 bytes of hex.
 * @returns `true` when `post` would accept it.
 * @throws {InvalidHotWordError} When `word` isn't exactly 32 bytes of hex.
 */
export function isWellFormed(word: Hex): boolean {
  const { mid, flags } = toFields(word)
  return mid !== 0n && (flags & ~flagsMask) === 0
}

export declare namespace isWellFormed {
  type ErrorType = InvalidHotWordErrorType | GlobalErrorType
}

/**
 * `HotWord.withoutRefill`: the word as `post` stores and emits it, its refill bits cleared.
 *
 * @example
 * ```ts
 * import { HotWord, Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const order = { pairIndex: 0, mid: Price.one, shapeId: 0, sequence: 2, validUntil: 1_800_000_000 }
 * HotWord.withoutRefill(Post.order({ ...order, refill: 'both' }).word) === Post.order(order).word // true
 * ```
 *
 * @param word - The word: exactly 32 bytes of hex.
 * @returns The word without bits 242 and 243.
 * @throws {InvalidHotWordError} When `word` isn't exactly 32 bytes of hex.
 */
export function withoutRefill(word: Hex): Hex {
  const w = toWord(word) & ~(BigInt(flagsRefill) << 240n)
  return numberToHex(w, { size: 32 })
}

export declare namespace withoutRefill {
  type ErrorType = InvalidHotWordErrorType | GlobalErrorType
}

/**
 * `HotWord.sideOff`: whether the side a taker walks is off. A taker selling base (`baseIn`) walks the bids.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.sideOff({ sides: 'asks' }, true) // true: the bids are off
 * ```
 *
 * @param hot - The decoded word, or just its `sides`.
 * @param baseIn - True when the taker sells base.
 * @returns `true` when that side takes no fills.
 */
export function sideOff(hot: Pick<HotWord, 'sides'>, baseIn: boolean): boolean {
  return hot.sides === 'neither' || hot.sides === (baseIn ? 'asks' : 'bids')
}

export declare namespace sideOff {
  type ErrorType = GlobalErrorType
}

/**
 * Whether `word` is a hot word: exactly 32 bytes of hex, nothing shorter to pad and nothing longer. Says nothing of
 * its fields: {@link decode} holds a stored word's, {@link decodeEntry} an entry's, {@link isWellFormed} `post`'s.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.validate(HotWord.initial) // true
 * HotWord.validate('0x01') // false: one byte, never padded
 * ```
 *
 * @param word - The value.
 * @returns `true` for exactly 32 bytes of hex, in either case.
 */
export function validate(word: Hex): boolean {
  return typeof word === 'string' && word.length === 66 && isHex(word)
}

export declare namespace validate {
  type ErrorType = GlobalErrorType
}

/**
 * Asserts that `word` is a hot word: exactly 32 bytes of hex.
 *
 * @example
 * ```ts
 * import { HotWord } from '@tempoxyz/propamm-sdk'
 *
 * HotWord.assert(HotWord.initial) // passes
 * HotWord.assert('0x01') // throws InvalidHotWordError
 * ```
 *
 * @param word - The value.
 * @throws {InvalidHotWordError} When `word` isn't exactly 32 bytes of hex.
 */
export function assert(word: Hex): void {
  if (!validate(word)) {
    throw new InvalidHotWordError(
      `a hot word is exactly 32 bytes of hex, got ${show(word)}`,
      { word },
    )
  }
}

export declare namespace assert {
  type ErrorType = InvalidHotWordErrorType | GlobalErrorType
}

function toWord(word: Hex): bigint {
  assert(word)
  return BigInt(word)
}
