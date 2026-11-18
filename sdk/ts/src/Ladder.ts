import { maxUint128 } from 'viem'
import { LadderMath } from './generated/constants.js'
import type * as HotWord from './HotWord.js'
import {
  AmountOutOfRangeError,
  type AmountOutOfRangeErrorType,
  type GlobalErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  InvalidHotWordError,
  type InvalidHotWordErrorType,
  InvalidPriceError,
  type InvalidPriceErrorType,
  InvalidShapeError,
  type InvalidShapeErrorType,
  show,
} from './internal/errors.js'
import * as checks from './internal/validate.js'
import * as Shape from './Shape.js'

/**
 * `LadderMath.Curve`: the walked side's pricing inputs, all integers, each within the width the venue stores it in:
 * the `uint16` widening and scales as numbers, the `uint96` mid and `uint64` size unit as bigints, as the SDK holds
 * every value of those widths.
 *
 * @example
 * ```ts
 * import { Ladder, Price } from '@tempoxyz/propamm-sdk'
 *
 * const curve: Ladder.Curve = Ladder.curve(
 *   { mid: Price.parse('1.085'), bidWiden: 0, askWiden: 0, widthScale: 1000, depthScale: 1000 },
 *   1_000_000n,
 *   true,
 * )
 * ```
 */
export type Curve = {
  /** Quote per 1 base, scaled by 1e18 (`uint96`). */
  mid: bigint
  /** `bidWiden` on the bid side, `askWiden` on the ask side, in 0.1 bp (`uint16`). */
  widen: number
  /** Multiplier on level spreads, per mille (`uint16`). */
  widthScale: number
  /** Multiplier on level sizes, per mille (`uint16`). */
  depthScale: number
  /** Base atoms per size step (`uint64`, at least 1: `addPair` refuses 0). */
  sizeUnit: bigint
  /** True when the taker sells base and walks the bids. */
  bid: boolean
}

/**
 * One fill's result, or the error `LadderMath.fill` reverts with.
 *
 * @example
 * ```ts
 * import type { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * function show(result: Ladder.FillResult) {
 *   return result.ok ? `${result.amountIn} in, ${result.amountOut} out` : result.error
 * }
 * ```
 */
export type FillResult =
  | { ok: true; amountIn: bigint; amountOut: bigint; baseFilled: bigint }
  | { ok: false; error: 'InsufficientDepth' | 'ZeroFill' }

/**
 * Base atoms each side's ladder has given up since the maker last refilled it (`Venue.consumed`, two `uint120`s).
 *
 * @example
 * ```ts
 * import type { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * const fresh: Ladder.Consumed = { bids: 0n, asks: 0n }
 * ```
 */
export type Consumed = { bids: bigint; asks: bigint }

// The `LadderMath` library's constants (contracts/src/v2/libraries/LadderMath.sol).

/**
 * `LadderMath.FACTOR_ONE`: a level's price factor at 1x, 1e8. A factor is the level's price over the mid, held over
 * this.
 *
 * @example
 * ```ts
 * import { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * Ladder.factorOne // 100000000n
 * ```
 */
export const factorOne = LadderMath.factorOne
/**
 * `LadderMath.SCALE_ONE`: 1x for `widthScale` and `depthScale`, which are per mille: 1000.
 *
 * @example
 * ```ts
 * import { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * Ladder.scaleOne // 1000n
 * ```
 */
export const scaleOne = LadderMath.scaleOne
/**
 * `LadderMath.DENOMINATOR`: the one denominator every fill divides by, 1e26: 1e18 (the mid's scale) x 1e8
 * ({@link factorOne}).
 *
 * @example
 * ```ts
 * import { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * Ladder.denominator // 100000000000000000000000000n
 * ```
 */
export const denominator = LadderMath.denominator
/**
 * 100% as a spread or widening, which are in 0.1 bp: 100,000 of them ({@link factorOne} over {@link scaleOne}).
 *
 * @example
 * ```ts
 * import { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * Ladder.spreadOne // 100000n: 10 bp is 100
 * ```
 */
export const spreadOne = factorOne / scaleOne

const MAX_LEVELS = Number(Shape.maxLevels)
/** `Venue.Consumption`'s width for each side. */
const CONSUMED_BITS = 120

/**
 * `LadderMath.curve`: the pricing inputs of the side `baseIn` walks (the bids when the taker sells base). Each field
 * is checked against the hot word's width; a mid of 0, a pair never posted, still makes a curve (`Book` shows it),
 * and only {@link fill} needs a nonzero one.
 *
 * @example
 * ```ts
 * import { Ladder, Price } from '@tempoxyz/propamm-sdk'
 *
 * const bids = Ladder.curve(
 *   { mid: Price.parse('1.085'), bidWiden: 5, askWiden: 5, widthScale: 1000, depthScale: 1000 },
 *   1_000_000n,
 *   true,
 * )
 * ```
 *
 * @param hot - The hot word's pricing fields: `mid` (`uint96`), the widenings and scales (`uint16`).
 * @param sizeUnit - The pair's base atoms per size step (a nonzero `uint64`).
 * @param baseIn - True when the taker sells base, so the curve is the bids'.
 * @returns The curve.
 * @throws {InvalidPriceError} When `mid` isn't a `uint96`.
 * @throws {InvalidHotWordError} When a widening or scale isn't a `uint16`.
 * @throws {InvalidArgumentError} When `sizeUnit` isn't a nonzero `uint64` or `baseIn` isn't a boolean.
 */
export function curve(
  hot: Pick<
    HotWord.HotWord,
    'mid' | 'bidWiden' | 'askWiden' | 'widthScale' | 'depthScale'
  >,
  sizeUnit: bigint,
  baseIn: boolean,
): Curve {
  if (typeof hot !== 'object' || hot === null)
    throw new InvalidHotWordError(
      `a hot word's fields are an object, got ${show(hot)}`,
      { parameter: 'hot', value: hot },
    )
  const field = (name: 'bidWiden' | 'askWiden' | 'widthScale' | 'depthScale') =>
    hotField(hot[name], name)
  return {
    mid: checks.mid(hot.mid, 'mid'),
    widen: checks.bool(baseIn, 'baseIn')
      ? field('bidWiden')
      : field('askWiden'),
    widthScale: field('widthScale'),
    depthScale: field('depthScale'),
    sizeUnit: checkSizeUnit(sizeUnit, 'sizeUnit'),
    bid: baseIn,
  }
}

export declare namespace curve {
  type ErrorType =
    | InvalidPriceErrorType
    | InvalidHotWordErrorType
    | InvalidArgumentErrorType
    | GlobalErrorType
}

/** A hot-word widening or scale: a `uint16`, `InvalidHotWordError` otherwise, wherever it comes in. */
const hotField = (value: number, name: string) =>
  checks.uintNumber(value, 16, name, InvalidHotWordError)

/** A pair's size unit: a nonzero `uint64`, as `addPair` stores every pair's. */
function checkSizeUnit(value: bigint, name: string): bigint {
  checks.uintBigint(value, 64, name)
  if (value === 0n)
    throw new InvalidArgumentError(
      `${name} must be at least 1: addPair refuses 0, got ${show(value)}`,
      { parameter: name, value },
    )
  return value
}

/** A curve's integers as the math takes them: all bigints. */
type Checked = {
  mid: bigint
  widen: bigint
  widthScale: bigint
  depthScale: bigint
  sizeUnit: bigint
  bid: boolean
}

/**
 * Checks a curve against the widths {@link curve} gives it, for one built by hand (`mid` a `uint96`, `widen` and the
 * scales `uint16`s, `sizeUnit` a nonzero `uint64`, `bid` a boolean), each refused as {@link curve} refuses it.
 */
function checkCurve(c: Curve): Checked {
  if (typeof c !== 'object' || c === null)
    throw new InvalidArgumentError(`a curve is an object, got ${show(c)}`, {
      parameter: 'curve',
      value: c,
    })
  return {
    mid: checks.mid(c.mid, 'curve.mid'),
    widen: BigInt(hotField(c.widen, 'curve.widen')),
    widthScale: BigInt(hotField(c.widthScale, 'curve.widthScale')),
    depthScale: BigInt(hotField(c.depthScale, 'curve.depthScale')),
    sizeUnit: checkSizeUnit(c.sizeUnit, 'curve.sizeUnit'),
    bid: checks.bool(c.bid, 'curve.bid'),
  }
}

/** Checks a side's two words: `uint256`s that encode one side canonically, as `setShape` stores every side. */
function checkSide(w0: bigint, w1: bigint): void {
  checks.uintBigint(w0, 256, 'w0', InvalidShapeError)
  checks.uintBigint(w1, 256, 'w1', InvalidShapeError)
  const reason = Shape.checkSide(w0, w1)
  if (reason !== 0)
    throw new InvalidShapeError(
      `the side's words are not its canonical encoding (ShapeWord reason ${reason}): setShape never stores them`,
      { reason, parameter: 'w0', value: [w0, w1] },
    )
}

/** `LadderMath.factor`, on checked inputs. */
function factorOf(c: Checked, spread: bigint): bigint {
  const offset = spread * c.widthScale + c.widen * scaleOne
  if (!c.bid) return factorOne + offset
  return offset >= factorOne ? 0n : factorOne - offset
}

/** `LadderMath.effectiveSize`, on checked inputs. */
function sizeOf(c: Checked, rawSize: bigint): bigint {
  return (rawSize * c.sizeUnit * c.depthScale) / scaleOne
}

/** Level `i` of a checked side, as the math takes it. */
function levelOf(w0: bigint, w1: bigint, i: number) {
  const { size, spread } = Shape.rawLevel(w0, w1, i)
  return { size: BigInt(size), spread: BigInt(spread) }
}

/**
 * `LadderMath.factor`: a level's price factor over {@link factorOne}: `1e8 + spread x widthScale + widen x 1000` on
 * an ask, `1e8 - ...` on a bid, or 0 at or past the bid floor (that level and every deeper one hold nothing).
 *
 * @example
 * ```ts
 * import { Ladder, Price } from '@tempoxyz/propamm-sdk'
 *
 * const asks = Ladder.curve(
 *   { mid: Price.one, bidWiden: 0, askWiden: 0, widthScale: 1000, depthScale: 1000 },
 *   1n,
 *   false,
 * )
 * Ladder.factor(asks, 20) // 100020000n: 2 bp above the mid
 * ```
 *
 * @param c - The curve.
 * @param spread - The level's spread, in 0.1 bp (`uint16`).
 * @returns The factor, over 1e8.
 * @throws {InvalidArgumentError} When the curve isn't one, or its `sizeUnit` or `bid` is out of range.
 * @throws {InvalidPriceError} When the curve's mid isn't a `uint96`.
 * @throws {InvalidHotWordError} When the curve's widening or a scale isn't a `uint16`.
 * @throws {InvalidShapeError} When `spread` isn't a `uint16`.
 */
export function factor(c: Curve, spread: number): bigint {
  const k = checkCurve(c)
  return factorOf(
    k,
    BigInt(checks.uintNumber(spread, 16, 'spread', InvalidShapeError)),
  )
}

export declare namespace factor {
  type ErrorType = CurveErrorType | InvalidShapeErrorType | GlobalErrorType
}

/** The errors a curve's own check throws, for one built by hand. */
type CurveErrorType =
  | InvalidArgumentErrorType
  | InvalidHotWordErrorType
  | InvalidPriceErrorType

/**
 * `LadderMath.effectiveSize`: the base atoms a level holds, `floor(rawSize x sizeUnit x depthScale / 1000)`, floored
 * per level.
 *
 * @example
 * ```ts
 * import { Ladder, Price } from '@tempoxyz/propamm-sdk'
 *
 * const half = Ladder.curve(
 *   { mid: Price.one, bidWiden: 0, askWiden: 0, widthScale: 1000, depthScale: 500 },
 *   1_000_000n,
 *   true,
 * )
 * Ladder.effectiveSize(half, 50_000) // 25000000000n
 * ```
 *
 * @param c - The curve.
 * @param rawSize - The level's size, in size steps (`uint32`).
 * @returns The level's base atoms.
 * @throws {InvalidArgumentError} When the curve isn't one, or its `sizeUnit` or `bid` is out of range.
 * @throws {InvalidPriceError} When the curve's mid isn't a `uint96`.
 * @throws {InvalidHotWordError} When the curve's widening or a scale isn't a `uint16`.
 * @throws {InvalidShapeError} When `rawSize` isn't a `uint32`.
 */
export function effectiveSize(c: Curve, rawSize: number): bigint {
  const k = checkCurve(c)
  return sizeOf(
    k,
    BigInt(checks.uintNumber(rawSize, 32, 'rawSize', InvalidShapeError)),
  )
}

export declare namespace effectiveSize {
  type ErrorType = CurveErrorType | InvalidShapeErrorType | GlobalErrorType
}

/**
 * `LadderMath.fill`, line for line: prices one fill from `consumed` base atoms down the side's ladder, rounding once
 * toward the maker. `amount` is the input when `exactIn`, else the output. `InsufficientDepth` takes precedence over
 * `ZeroFill`, as onchain.
 *
 * Every input is held to what the venue could pass: the curve's widths, a nonzero mid, a `sizeUnit` of at least 1
 * (`addPair` refuses 0), an amount in `[1, 2^128 - 1]`, a `consumed` that fits the venue's `uint120`, and a side
 * `setShape` could have stored (canonical, `w1` 0 unless level 5 has size, as `Shape.continues` says). For such
 * input the result is exactly `LadderMath.fill`'s.
 *
 * @example
 * ```ts
 * import { Ladder, Price, Shape } from '@tempoxyz/propamm-sdk'
 *
 * const shape = Shape.from({ bids: [{ size: 50_000, spread: 20 }], asks: [{ size: 50_000, spread: 20 }] })
 * const [w0, w1] = Shape.side(shape.words, 'bids')
 * const bids = Ladder.curve(
 *   { mid: Price.parse('1.085'), bidWiden: 0, askWiden: 0, widthScale: 1000, depthScale: 1000 },
 *   1_000_000n,
 *   true,
 * )
 * // Sell 1,000 base atoms into the bids, exact in, from a fresh side.
 * const result = Ladder.fill(bids, w0, w1, true, 1_000n, 0n)
 * if (result.ok) console.log(result.amountOut)
 * ```
 *
 * @param c - The walked side's curve.
 * @param w0 - The side's first word (levels 1-5).
 * @param w1 - The side's second word (levels 6-10): 0 unless level 5 has size.
 * @param exactIn - True when `amount` is the taker's input, false when it is the output.
 * @param amount - The input or output, in token atoms (`[1, 2^128 - 1]`).
 * @param consumed - Base atoms the side's ladder has already given up (`uint120`); the walk starts after them.
 * @returns The amounts and the base moved, or the error the venue reverts with.
 * @throws {AmountOutOfRangeError} When `amount` is outside `[1, 2^128 - 1]`.
 * @throws {InvalidPriceError} When the curve's mid is 0 or not a `uint96`.
 * @throws {InvalidHotWordError} When the curve's widening or a scale isn't a `uint16`.
 * @throws {InvalidArgumentError} When the curve isn't one, `exactIn` or `consumed` is out of range, or `sizeUnit` is
 * not a nonzero `uint64`.
 * @throws {InvalidShapeError} When `w0` and `w1` aren't a side `setShape` could store.
 */
export function fill(
  c: Curve,
  w0: bigint,
  w1: bigint,
  exactIn: boolean,
  amount: bigint,
  consumed: bigint,
): FillResult {
  if (typeof amount !== 'bigint' || amount < 1n || amount > maxUint128) {
    throw new AmountOutOfRangeError(
      `amount must be in [1, 2^128 - 1], got ${show(amount)}`,
      { parameter: 'amount', value: amount },
    )
  }
  checks.uintBigint(consumed, CONSUMED_BITS, 'consumed')
  const k = checkCurve(c)
  // `LadderMath.fill`'s precondition, which the venue enforces: a nonzero mid (and a pair, so a nonzero size unit).
  if (k.mid === 0n)
    throw new InvalidPriceError(
      'a fill needs a nonzero mid: the pair was never posted',
      { parameter: 'curve.mid', value: k.mid },
    )
  checkSide(w0, w1)
  checks.bool(exactIn, 'exactIn')

  // Selling base exact-in and buying base exact-out both walk toward a base target; the other two toward a quote
  // target, held scaled by the denominator.
  const baseTarget = k.bid === exactIn
  let remaining = baseTarget ? amount : amount * denominator
  let numerator = 0n
  let baseFilled = 0n
  let done = false
  let offset = consumed

  for (let i = 0; i < MAX_LEVELS; i++) {
    const { size: rawSize, spread } = levelOf(w0, w1, i)
    if (rawSize === 0n) break
    const f = factorOf(k, spread)
    if (f === 0n) break

    // The levels earlier fills took, and any empty level, hold nothing for this one.
    let available = sizeOf(k, rawSize)
    if (offset >= available) {
      offset -= available
      continue
    }
    available -= offset
    offset = 0n

    const unitPrice = k.mid * f
    if (baseTarget) {
      const take = available < remaining ? available : remaining
      numerator += take * unitPrice
      baseFilled += take
      remaining -= take
      if (remaining === 0n) {
        done = true
        break
      }
    } else {
      const value = available * unitPrice
      if (k.bid) {
        // Wants quote exact-out: the smallest base whose value covers the remaining quote.
        if (value >= remaining) {
          baseFilled += (remaining + unitPrice - 1n) / unitPrice
          done = true
          break
        }
        baseFilled += available
        remaining -= value
      } else {
        // Pays quote exact-in: the most base the remaining quote buys. Deeper asks are never cheaper.
        if (value > remaining) {
          baseFilled += remaining / unitPrice
          done = true
          break
        }
        baseFilled += available
        remaining -= value
        if (remaining < unitPrice) {
          done = true
          break
        }
      }
    }
  }

  if (!done) return { ok: false, error: 'InsufficientDepth' }

  let amountIn: bigint
  let amountOut: bigint
  if (baseTarget) {
    if (k.bid) {
      amountIn = amount
      amountOut = numerator / denominator
    } else {
      amountIn = (numerator + denominator - 1n) / denominator
      amountOut = amount
    }
  } else if (k.bid) {
    amountIn = baseFilled
    amountOut = amount
  } else {
    amountIn = amount
    amountOut = baseFilled
  }
  if (amountIn === 0n || amountOut === 0n)
    return { ok: false, error: 'ZeroFill' }
  return { ok: true, amountIn, amountOut, baseFilled }
}

export declare namespace fill {
  type ErrorType =
    | AmountOutOfRangeErrorType
    | CurveErrorType
    | InvalidShapeErrorType
    | GlobalErrorType
}

/**
 * A side's whole depth in base atoms, before any consumption: every level above the bid floor.
 *
 * @example
 * ```ts
 * import { Ladder, Price, Shape } from '@tempoxyz/propamm-sdk'
 *
 * const [w0, w1] = Shape.encodeSide([{ size: 50_000, spread: 20 }, { size: 50_000, spread: 40 }])
 * const asks = Ladder.curve(
 *   { mid: Price.one, bidWiden: 0, askWiden: 0, widthScale: 1000, depthScale: 1000 },
 *   1_000_000n,
 *   false,
 * )
 * Ladder.depth(asks, w0, w1) // 100000000000n
 * ```
 *
 * @param c - The side's curve.
 * @param w0 - The side's first word.
 * @param w1 - The side's second word.
 * @returns The depth.
 * @throws {InvalidArgumentError} When the curve isn't one, or its `sizeUnit` or `bid` is out of range.
 * @throws {InvalidPriceError} When the curve's mid isn't a `uint96`.
 * @throws {InvalidHotWordError} When the curve's widening or a scale isn't a `uint16`.
 * @throws {InvalidShapeError} When `w0` and `w1` aren't a side `setShape` could store.
 */
export function depth(c: Curve, w0: bigint, w1: bigint): bigint {
  const k = checkCurve(c)
  checkSide(w0, w1)
  let total = 0n
  for (let i = 0; i < MAX_LEVELS; i++) {
    const { size, spread } = levelOf(w0, w1, i)
    if (size === 0n || factorOf(k, spread) === 0n) break
    total += sizeOf(k, size)
  }
  return total
}

export declare namespace depth {
  type ErrorType = CurveErrorType | InvalidShapeErrorType | GlobalErrorType
}

/** A side's consumption, checked as the venue's `uint120`. */
function checkConsumed(consumed: Consumed): void {
  if (typeof consumed !== 'object' || consumed === null)
    throw new InvalidArgumentError(
      `consumption is { bids, asks }, got ${show(consumed)}`,
      { parameter: 'consumed', value: consumed },
    )
  checks.uintBigint(consumed.bids, CONSUMED_BITS, 'consumed.bids')
  checks.uintBigint(consumed.asks, CONSUMED_BITS, 'consumed.asks')
}

/**
 * The consumption after a fill: the walked side gains `baseFilled`, the other is unchanged.
 *
 * @example
 * ```ts
 * import { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * Ladder.applyFill({ bids: 0n, asks: 5n }, true, 3n) // { bids: 3n, asks: 5n }
 * ```
 *
 * @param consumed - The consumption before.
 * @param baseIn - True when the fill sold base, walking the bids.
 * @param baseFilled - The fill's `baseFilled`.
 * @returns The consumption after.
 * @throws {InvalidArgumentError} When a side or `baseFilled` isn't a `uint120`, or `baseIn` isn't a boolean.
 */
export function applyFill(
  consumed: Consumed,
  baseIn: boolean,
  baseFilled: bigint,
): Consumed {
  checkConsumed(consumed)
  checks.uintBigint(baseFilled, CONSUMED_BITS, 'baseFilled')
  return checks.bool(baseIn, 'baseIn')
    ? { bids: consumed.bids + baseFilled, asks: consumed.asks }
    : { bids: consumed.bids, asks: consumed.asks + baseFilled }
}

export declare namespace applyFill {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * The consumption after an accepted post that refills `refill`: those sides drop to 0.
 *
 * @example
 * ```ts
 * import { Ladder } from '@tempoxyz/propamm-sdk'
 *
 * Ladder.applyRefill({ bids: 3n, asks: 5n }, 'asks') // { bids: 3n, asks: 0n }
 * ```
 *
 * @param consumed - The consumption before.
 * @param refill - The sides the post refills.
 * @returns The consumption after.
 * @throws {InvalidArgumentError} When a side isn't a `uint120` or `refill` isn't a `Sides` value.
 */
export function applyRefill(
  consumed: Consumed,
  refill: HotWord.Sides,
): Consumed {
  checkConsumed(consumed)
  checks.sides(refill, 'refill')
  return {
    bids: refill === 'both' || refill === 'bids' ? 0n : consumed.bids,
    asks: refill === 'both' || refill === 'asks' ? 0n : consumed.asks,
  }
}

export declare namespace applyRefill {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}
