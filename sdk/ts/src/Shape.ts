import { maxUint32 } from 'viem'
import { ShapeWord } from './generated/constants.js'
import {
  type GlobalErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  InvalidShapeError,
  type InvalidShapeErrorType,
  show,
} from './internal/errors.js'
import * as checks from './internal/validate.js'

/**
 * One ladder level: `size` in the pair's `sizeUnit` steps (`uint32`, at least 1), `spread` in 0.1 bp (`uint16`).
 *
 * @example
 * ```ts
 * import type { Shape } from '@tempoxyz/propamm-sdk'
 *
 * // 50,000 size steps, 2 bp from the mid at widthScale 1000.
 * const level: Shape.Level = { size: 50_000, spread: 20 }
 * ```
 */
export type Level = { size: number; spread: number }

/**
 * A shape's four `uint256` words: bid levels 1-5, bid levels 6-10, ask levels 1-5, ask levels 6-10 (`setShape`'s
 * `words`).
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const words: Shape.Words = Shape.empty.words // [0n, 0n, 0n, 0n]
 * ```
 */
export type Words = readonly [bigint, bigint, bigint, bigint]

/**
 * A canonical shape: both ladders and the words that encode them.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const shape: Shape.Shape = Shape.from({ bids: [{ size: 50_000, spread: 20 }], asks: [] })
 * ```
 */
export type Shape = {
  readonly bids: readonly Level[]
  readonly asks: readonly Level[]
  readonly words: Words
}

/**
 * `ShapeWord.check`'s result: 0 for a valid shape, else the `InvalidShape` reason ({@link reasonReservedBits},
 * {@link reasonNonCanonical} or {@link reasonSpreadDecreases}).
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const reason: Shape.Reason = Shape.check([0n, 0n, 0n, 0n]) // 0
 * ```
 */
export type Reason = 0 | 1 | 2 | 3

// The `ShapeWord` library's constants (contracts/src/v2/libraries/ShapeWord.sol).

/**
 * `ShapeWord.REASON_RESERVED_BITS` (a reason code, 1): a word sets a bit above level 5's (bits 240-255).
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.check([1n << 240n, 0n, 0n, 0n]) === Shape.reasonReservedBits // true
 * ```
 */
export const reasonReservedBits = ShapeWord.reasonReservedBits
/**
 * `ShapeWord.REASON_NON_CANONICAL` (a reason code, 2): a spread on an empty level, a level after a hole, or a second
 * word without level 5.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.check([0n, 1n, 0n, 0n]) === Shape.reasonNonCanonical // true
 * ```
 */
export const reasonNonCanonical = ShapeWord.reasonNonCanonical
/**
 * `ShapeWord.REASON_SPREAD_DECREASES` (a reason code, 3): a level's spread below the one before it.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const down = 1n | (3n << 32n) | ((1n | (2n << 32n)) << 48n)
 * Shape.check([down, 0n, 0n, 0n]) === Shape.reasonSpreadDecreases // true
 * ```
 */
export const reasonSpreadDecreases = ShapeWord.reasonSpreadDecreases
/**
 * `ShapeWord.LEVELS_PER_WORD`: 5 levels to a word, two words to a side.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.levelsPerWord // 5n
 * ```
 */
export const levelsPerWord = ShapeWord.levelsPerWord
/**
 * `ShapeWord.LEVEL_BITS`: a level's width in a word, 48 bits: a `uint32` size, then a `uint16` spread.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.levelBits // 48n
 * ```
 */
export const levelBits = ShapeWord.levelBits
/**
 * `ShapeWord.MAX_LEVELS`: 10 levels to a side.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.maxLevels // 10n
 * ```
 */
export const maxLevels = ShapeWord.maxLevels
/**
 * `ShapeWord.RESERVED_MASK`: a word's bits above level 5 (bits 240-255), which a canonical word leaves clear.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.reservedMask === 0xffffn << 240n // true
 * ```
 */
export const reservedMask = ShapeWord.reservedMask

const LEVELS_PER_WORD = Number(levelsPerWord)
const MAX_LEVELS = Number(maxLevels)

/** A reason in words, for messages. */
const REASONS: Record<Exclude<Reason, 0>, string> = {
  1: 'reserved bits set',
  2: 'non-canonical',
  3: 'a spread decreases',
}

/** `reason` as a message names it: `ShapeWord reason 2 (non-canonical)`. */
function describeReason(reason: Exclude<Reason, 0>): string {
  return `ShapeWord reason ${reason} (${REASONS[reason]})`
}

/**
 * No levels on either side: `setShape` with it deletes the shape.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.from({ bids: [], asks: [] }) // equals Shape.empty
 * ```
 */
export const empty: Shape = { bids: [], asks: [], words: [0n, 0n, 0n, 0n] }

/**
 * Builds a canonical shape: at most ten levels per side, sizes in `[1, 2^32 - 1]` size steps, spreads in
 * `[0, 65535]` tenths of a bp that never decrease from one level to the next. A side may be empty (it holds no
 * depth).
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const shape = Shape.from({
 *   bids: [{ size: 50_000, spread: 20 }, { size: 100_000, spread: 40 }],
 *   asks: [{ size: 50_000, spread: 20 }],
 * })
 * shape.words // the four words setShape takes
 * ```
 *
 * @param ladders - Each side's levels, from the top.
 * @returns The shape, with copies of the levels and their words.
 * @throws {InvalidShapeError} When a side has more than ten levels, or a level is out of range or below the spread
 * before it; `parameter` names it (such as `bids[2].spread`).
 */
export function from(ladders: {
  bids: readonly Level[]
  asks: readonly Level[]
}): Shape {
  if (typeof ladders !== 'object' || ladders === null)
    throw new InvalidShapeError(
      `a shape's ladders are { bids, asks }, got ${show(ladders)}`,
      { parameter: 'ladders', value: ladders },
    )
  const [b0, b1] = encodeSide(ladders.bids, 'bids')
  const [a0, a1] = encodeSide(ladders.asks, 'asks')
  const words: Words = [b0, b1, a0, a1]
  assert(words)
  return { bids: ladders.bids.map(copy), asks: ladders.asks.map(copy), words }
}

export declare namespace from {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

/**
 * Decodes four words, which must form a canonical shape: the Rust SDK's `Shape::from_words`.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const shape = Shape.fromWords([0x140000c350n, 0n, 0x140000c350n, 0n])
 * shape.bids // [{ size: 50000, spread: 20 }]
 * ```
 *
 * @param words - The four words, as `setShape` takes them and the venue's `shape` returns them.
 * @returns The shape, with its own copy of the words.
 * @throws {InvalidShapeError} When they aren't four `uint256` words, or aren't canonical (`reason`, as
 * `ShapeWord.check` returns it).
 */
export function fromWords(words: readonly bigint[]): Shape {
  const source = asWords(words)
  const w: Words = [source[0], source[1], source[2], source[3]]
  assert(w)
  return {
    bids: decodeSide(w[0], w[1]),
    asks: decodeSide(w[2], w[3]),
    words: w,
  }
}

export declare namespace fromWords {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

/**
 * `ShapeWord.check`: 0 when all four words form a valid shape, else the first reason, bids before asks.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.check(Shape.empty.words) // 0
 * Shape.check([0n, 1n, 0n, 0n]) // 2: a second word without level 5
 * ```
 *
 * @param words - The four words.
 * @returns The reason, 0 for none.
 * @throws {InvalidShapeError} When they aren't four `uint256` words.
 */
export function check(words: readonly bigint[]): Reason {
  const w = asWords(words)
  const reason = checkSide(w[0], w[1])
  return reason !== 0 ? reason : checkSide(w[2], w[3])
}

export declare namespace check {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

/**
 * Asserts that four words are a canonical shape, one `setShape` accepts.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.assert(Shape.empty.words) // passes
 * Shape.assert([0n, 1n, 0n, 0n]) // throws InvalidShapeError, reason 2
 * ```
 *
 * @param words - The four words.
 * @throws {InvalidShapeError} When they aren't four `uint256` words, or aren't canonical (`reason` set).
 */
export function assert(words: readonly bigint[]): asserts words is Words {
  const reason = check(words)
  if (reason !== 0)
    throw new InvalidShapeError(
      `shape words are not canonical: ${describeReason(reason)}`,
      { reason, parameter: 'words', value: words },
    )
}

export declare namespace assert {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

/**
 * Whether four words are a canonical shape, one `setShape` accepts.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * Shape.validate(Shape.empty.words) // true
 * Shape.validate([0n, 1n, 0n, 0n]) // false
 * ```
 *
 * @param words - The four words.
 * @returns `true` when they are four `uint256` words `ShapeWord.check` accepts.
 */
export function validate(words: readonly bigint[]): boolean {
  try {
    return check(words) === 0
  } catch {
    return false
  }
}

export declare namespace validate {
  type ErrorType = GlobalErrorType
}

/**
 * `ShapeWord.checkSide`, walked in the same order: reserved bits, then each level.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const [w0, w1] = Shape.encodeSide([{ size: 1, spread: 0 }])
 * Shape.checkSide(w0, w1) // 0
 * ```
 *
 * @param w0 - The side's first word (levels 1-5).
 * @param w1 - The side's second word (levels 6-10).
 * @returns The reason, 0 for none.
 * @throws {InvalidShapeError} When a word isn't a `uint256`.
 */
export function checkSide(w0: bigint, w1: bigint): Reason {
  checkWord(w0, 'w0')
  checkWord(w1, 'w1')
  if ((w0 & reservedMask) !== 0n || (w1 & reservedMask) !== 0n)
    return reasonReservedBits
  let ended = false
  let lastSpread = 0n
  for (let i = 0; i < MAX_LEVELS; i++) {
    const { size, spread } = levelOf(w0, w1, i)
    if (ended) {
      if (size !== 0n || spread !== 0n) return reasonNonCanonical
    } else if (size === 0n) {
      if (spread !== 0n) return reasonNonCanonical
      ended = true
    } else {
      if (spread < lastSpread) return reasonSpreadDecreases
      lastSpread = spread
    }
  }
  return 0
}

export declare namespace checkSide {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

/**
 * The levels a side holds: every level before its first empty one. Doesn't check the encoding is canonical
 * ({@link checkSide} does). The inverse of {@link encodeSide}.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const [w0, w1] = Shape.encodeSide([{ size: 50_000, spread: 20 }])
 * Shape.decodeSide(w0, w1) // [{ size: 50000, spread: 20 }]
 * ```
 *
 * @param w0 - The side's first word (levels 1-5).
 * @param w1 - The side's second word (levels 6-10).
 * @returns The levels, from the top.
 * @throws {InvalidShapeError} When a word isn't a `uint256`.
 */
export function decodeSide(w0: bigint, w1: bigint): Level[] {
  checkWord(w0, 'w0')
  checkWord(w1, 'w1')
  const out: Level[] = []
  for (let i = 0; i < MAX_LEVELS; i++) {
    const { size, spread } = levelOf(w0, w1, i)
    if (size === 0n) break
    out.push({ size: Number(size), spread: Number(spread) })
  }
  return out
}

export declare namespace decodeSide {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

/**
 * A side's two words: the bids are words 0 and 1, the asks 2 and 3.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const shape = Shape.from({ bids: [], asks: [{ size: 1, spread: 0 }] })
 * const [w0, w1] = Shape.side(shape.words, 'asks') // [1n, 0n]
 * ```
 *
 * @param words - The four words.
 * @param which - `'bids'` or `'asks'`.
 * @returns The side's two words.
 * @throws {InvalidShapeError} When `words` aren't four `uint256` words.
 * @throws {InvalidArgumentError} When `which` is neither side.
 */
export function side(
  words: Words,
  which: 'bids' | 'asks',
): readonly [bigint, bigint] {
  const w = asWords(words)
  return checks.side(which, 'which') === 'bids' ? [w[0], w[1]] : [w[2], w[3]]
}

export declare namespace side {
  type ErrorType =
    | InvalidShapeErrorType
    | InvalidArgumentErrorType
    | GlobalErrorType
}

/**
 * `ShapeWord.continues`: whether a side continues into its second word, that is whether level 5 has size. In a
 * canonical side the second word is nonzero only then, and the venue reads it only then.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const [w0] = Shape.encodeSide([{ size: 1, spread: 0 }])
 * Shape.continues(w0) // false: the venue reads no second word
 * ```
 *
 * @param w0 - The side's first word.
 * @returns `true` when level 5 has size.
 * @throws {InvalidShapeError} When `w0` isn't a `uint256`.
 */
export function continues(w0: bigint): boolean {
  checkWord(w0, 'w0')
  return levelOf(w0, 0n, LEVELS_PER_WORD - 1).size !== 0n
}

export declare namespace continues {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

/**
 * `ShapeWord.level`: level `i` (0-9) of a side, raw, as a `Level` holds it: its `uint32` size and `uint16` spread, as
 * numbers. An empty level is `{ size: 0, spread: 0 }` in a canonical side.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const [w0, w1] = Shape.encodeSide([{ size: 50_000, spread: 20 }])
 * Shape.rawLevel(w0, w1, 0) // { size: 50000, spread: 20 }
 * ```
 *
 * @param w0 - The side's first word (levels 1-5).
 * @param w1 - The side's second word (levels 6-10).
 * @param i - The level, 0 to 9.
 * @returns The level's size steps and spread.
 * @throws {InvalidShapeError} When a word isn't a `uint256`.
 * @throws {InvalidArgumentError} When `i` isn't an integer in `[0, 9]`.
 */
export function rawLevel(w0: bigint, w1: bigint, i: number): Level {
  checkWord(w0, 'w0')
  checkWord(w1, 'w1')
  if (!Number.isSafeInteger(i) || i < 0 || i >= MAX_LEVELS) {
    throw new InvalidArgumentError(
      `a level index is an integer in [0, ${MAX_LEVELS - 1}], got ${show(i)}`,
      { parameter: 'i', value: i },
    )
  }
  const { size, spread } = levelOf(w0, w1, i)
  return { size: Number(size), spread: Number(spread) }
}

export declare namespace rawLevel {
  type ErrorType =
    | InvalidShapeErrorType
    | InvalidArgumentErrorType
    | GlobalErrorType
}

/** `ShapeWord.level` on checked words and index. */
function levelOf(
  w0: bigint,
  w1: bigint,
  i: number,
): { size: bigint; spread: bigint } {
  const word = i < LEVELS_PER_WORD ? w0 : w1
  const j = BigInt(i < LEVELS_PER_WORD ? i : i - LEVELS_PER_WORD)
  return {
    size: (word >> (levelBits * j)) & 0xffff_ffffn,
    spread: (word >> (levelBits * j + 32n)) & 0xffffn,
  }
}

/**
 * Encodes one side into its two words, refusing a level {@link from} would refuse. The inverse of
 * {@link decodeSide}.
 *
 * @example
 * ```ts
 * import { Shape } from '@tempoxyz/propamm-sdk'
 *
 * const [w0, w1] = Shape.encodeSide([{ size: 50_000, spread: 20 }])
 * w0 // 0x140000c350n: spread 20 above size 50,000
 * ```
 *
 * @param ladder - The side's levels, from the top: at most ten.
 * @param name - The side's name in an error's `parameter` (`'bids'`, `'asks'`); `'side'` by default.
 * @returns The side's two words.
 * @throws {InvalidShapeError} When the ladder has more than ten levels, or a level is out of range or below the
 * spread before it.
 */
export function encodeSide(
  ladder: readonly Level[],
  name = 'side',
): [bigint, bigint] {
  if (!Array.isArray(ladder))
    throw new InvalidShapeError(
      `${name} must be an array of levels, got ${show(ladder)}`,
      { parameter: name, value: ladder },
    )
  if (ladder.length > MAX_LEVELS) {
    throw new InvalidShapeError(
      `${name}: at most ${MAX_LEVELS} levels per side, got ${ladder.length}`,
      { parameter: name, value: ladder.length },
    )
  }
  const words: [bigint, bigint] = [0n, 0n]
  let last = 0
  for (let i = 0; i < ladder.length; i++) {
    const level = ladder[i]
    if (typeof level !== 'object' || level === null) {
      throw new InvalidShapeError(
        `${name}[${i}] must be a level, got ${show(level)}`,
        { parameter: `${name}[${i}]`, value: level },
      )
    }
    const { size, spread } = level
    if (!Number.isSafeInteger(size) || size < 1 || size > Number(maxUint32)) {
      throw new InvalidShapeError(
        `${name}[${i}].size must be an integer in [1, 2^32 - 1], got ${show(size)}`,
        { parameter: `${name}[${i}].size`, value: size },
      )
    }
    if (!Number.isSafeInteger(spread) || spread < 0 || spread > 0xffff) {
      throw new InvalidShapeError(
        `${name}[${i}].spread must be an integer in [0, 65535], got ${show(spread)}`,
        { parameter: `${name}[${i}].spread`, value: spread },
      )
    }
    if (spread < last) {
      throw new InvalidShapeError(
        `${name}[${i}].spread ${spread} is below the level before it (${last})`,
        { parameter: `${name}[${i}].spread`, value: spread },
      )
    }
    last = spread
    const slot = BigInt(size) | (BigInt(spread) << 32n)
    const w = i < LEVELS_PER_WORD ? 0 : 1
    words[w] =
      (words[w] as bigint) | (slot << (levelBits * BigInt(i % LEVELS_PER_WORD)))
  }
  return words
}

export declare namespace encodeSide {
  type ErrorType = InvalidShapeErrorType | GlobalErrorType
}

function checkWord(word: bigint, parameter: string): void {
  if (typeof word !== 'bigint' || word < 0n || word >> 256n !== 0n)
    throw new InvalidShapeError(
      `a shape word is a uint256 bigint, got ${show(word)}`,
      { parameter, value: word },
    )
}

/** Whether an array holds exactly four entries, the length of `Words`. */
const isFour = (words: readonly bigint[]): words is Words => words.length === 4

function asWords(words: readonly bigint[]): Words {
  if (!Array.isArray(words) || !isFour(words))
    throw new InvalidShapeError(
      `a shape is four uint256 words, got ${show(words)}`,
      { parameter: 'words', value: words },
    )
  for (const [i, w] of words.entries()) checkWord(w, `words[${i}]`)
  return words
}

const copy = (level: Level): Level => ({
  size: level.size,
  spread: level.spread,
})
