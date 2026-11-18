// A pair's book, from a snapshot: `side` is what a taker can take now, `ladder` the posted ladder whatever its
// switches. Both are after the side's consumed depth; neither checks inventory or the taker's access.
import * as HotWord from './HotWord.js'
import {
  type GlobalErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  type InvalidHotWordErrorType,
  type InvalidPriceErrorType,
  type InvalidShapeErrorType,
  show,
} from './internal/errors.js'
import * as validate from './internal/validate.js'
import * as Ladder from './Ladder.js'
import * as Shape from './Shape.js'
import type { PairState } from './Snapshot.js'

/**
 * One level of a side as a book row.
 *
 * @example
 * ```ts
 * import { Book, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const rows: Book.Row[] = Book.ladder(Snapshot.pair(snapshot, 0), 'asks')
 * console.log(rows.map((r) => [r.level, r.priceX1e26, r.remaining]))
 * ```
 */
export type Row = {
  /** 0-9. */
  level: number
  /** The level's distance from mid in 0.1 bp: `spread * widthScale / 1000 + widen`, as a rational over 1000. */
  offsetTenthBpX1000: bigint
  /** The level's price, quote per base scaled by 1e26 (`mid * factor`): exact, for display divide by 1e26. */
  priceX1e26: bigint
  /** The level's effective size in base units. */
  depth: bigint
  /** What is left of it after the side's consumed depth. */
  remaining: bigint
}

/**
 * What a book reads of a pair: a `Snapshot.PairState`, or any object with these fields.
 *
 * @example
 * ```ts
 * import { Book, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const pair: Book.Pair = Snapshot.pair(snapshot, 0)
 * console.log(Book.ladder(pair, 'bids').length)
 * ```
 */
export type Pair = Pick<
  PairState,
  'hot' | 'sizeUnit' | 'shapeWords' | 'consumed'
>

/**
 * What the venue applies on top of the ladder: the time a fill would run at (`at`, Unix seconds, as a block's
 * `timestamp`) and whether the venue is halted. From a snapshot: `{ at: snapshot.block.timestamp, halted:
 * snapshot.state.halted }`.
 *
 * @example
 * ```ts
 * import { Book, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * // The book a minute from now, if nothing else changes.
 * const later: Book.State = { at: snapshot.block.timestamp + 60n, halted: snapshot.state.halted }
 * console.log(Book.remaining(Snapshot.pair(snapshot, 0), 'asks', later))
 * ```
 */
export type State = {
  /** Unix seconds: a quote is live through its `validUntil`, inclusive. */
  at: bigint
  halted: boolean
}

/**
 * The side's posted ladder as book rows, from the top, after its consumed depth: `'bids'` (where takers sell base) or
 * `'asks'` (where they buy it). Undecorated: it shows the ladder whether or not the side is switched off, its depth
 * scale is 0, the quote has expired or the venue is halted; {@link side} applies those. A bid level at or past the
 * floor, and every deeper one, is left out, as `LadderMath` leaves it out. No strategy and no floats: rendering is the
 * app's.
 *
 * @example
 * ```ts
 * import { Book, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const posted = Book.ladder(Snapshot.pair(snapshot, 0), 'bids')
 * console.log(posted.reduce((sum, row) => sum + row.depth, 0n))
 * ```
 *
 * @param pair - The pair, from a snapshot.
 * @param which - `'bids'` or `'asks'`.
 * @returns The side's levels, from the top; none for a removed or unknown pair (`sizeUnit` 0).
 * @throws {InvalidArgumentError} When either consumed depth isn't a `uint120` bigint, even when `sizeUnit` is 0.
 */
export function ladder(pair: Pair, which: 'bids' | 'asks'): ladder.ReturnValue {
  const baseIn = validate.side(which, 'which') === 'bids'
  if (typeof pair !== 'object' || pair === null)
    throw new InvalidArgumentError(
      'pair must be a snapshot pair: { hot, sizeUnit, shapeWords, consumed }',
      { parameter: 'pair', value: pair },
    )
  const consumed = pair.consumed
  if (typeof consumed !== 'object' || consumed === null)
    throw new InvalidArgumentError(
      `consumption is { bids, asks }, got ${show(consumed)}`,
      { parameter: 'consumed', value: consumed },
    )
  const bids = validate.uintBigint(consumed.bids, 120, 'consumed.bids')
  const asks = validate.uintBigint(consumed.asks, 120, 'consumed.asks')
  const [w0, w1] = Shape.side(pair.shapeWords, which)
  // A removed or unknown pair stores no size unit (`addPair` refuses 0), and has no ladder.
  if (pair.sizeUnit === 0n) return []
  const c = Ladder.curve(pair.hot, pair.sizeUnit, baseIn)
  let skip = baseIn ? bids : asks
  const rows: Row[] = []
  for (let i = 0; i < 10; i++) {
    const { size, spread } = Shape.rawLevel(w0, w1, i)
    if (size === 0) break
    const f = Ladder.factor(c, spread)
    if (f === 0n) break
    const depth = Ladder.effectiveSize(c, size)
    const taken = skip < depth ? skip : depth
    skip -= taken
    rows.push({
      level: i,
      offsetTenthBpX1000: BigInt(spread * c.widthScale + c.widen * 1000),
      priceX1e26: c.mid * f,
      depth,
      remaining: depth - taken,
    })
  }
  return rows
}

export declare namespace ladder {
  /** The side's levels, from the top. */
  type ReturnValue = Row[]
  /** The errors `ladder` throws: an invalid side, pair or consumption, and the hot word, size unit or shape `Ladder.curve` and
   * `Shape` refuse. */
  type ErrorType =
    | InvalidArgumentErrorType
    | InvalidHotWordErrorType
    | InvalidPriceErrorType
    | InvalidShapeErrorType
    | GlobalErrorType
}

/**
 * The side a taker can take from at `state.at`, as book rows after its consumed depth: {@link ladder}'s rows, or none
 * when the venue is halted, the quote has expired (`at > validUntil`), or the side is switched off or has depth scale
 * 0. Those are `Venue.quote`'s `VenueHalted`, `QuoteExpired` and `SideDisabled`; the rows don't check inventory or
 * the taker's access (`Quote.local` and `Info.takerAccess` do).
 *
 * @example
 * ```ts
 * import { Book, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const asks = Book.side(Snapshot.pair(snapshot, 0), 'asks', {
 *   at: snapshot.block.timestamp,
 *   halted: snapshot.state.halted,
 * })
 * console.log(asks.length === 0 ? 'no asks' : asks[0]?.priceX1e26)
 * ```
 *
 * @param pair - The pair, from a snapshot.
 * @param which - `'bids'` or `'asks'`.
 * @param state - The time a fill would run at and whether the venue is halted.
 * @returns The side's live levels, from the top, or none.
 */
export function side(
  pair: Pair,
  which: 'bids' | 'asks',
  state: State,
): side.ReturnValue {
  const baseIn = validate.side(which, 'which') === 'bids'
  if (typeof state !== 'object' || state === null)
    throw new InvalidArgumentError('state must be { at, halted }', {
      parameter: 'state',
      value: state,
    })
  const at = validate.uintBigint(state.at, 64, 'at')
  const halted = validate.bool(state.halted, 'halted')
  const hot = pair.hot
  if (
    halted ||
    at > BigInt(hot.validUntil) ||
    hot.depthScale === 0 ||
    HotWord.sideOff(hot, baseIn)
  )
    return []
  return ladder(pair, which)
}

export declare namespace side {
  /** The side's live levels, from the top, or none. */
  type ReturnValue = Row[]
  /** The errors `side` throws: `ladder`'s, and a `state` that isn't one. */
  type ErrorType = ladder.ErrorType
}

/**
 * The base a side can still give at `state.at` before it needs a refill: the sum of {@link side}'s `remaining`, so 0
 * when the venue is halted, the quote has expired or the side is off.
 *
 * @example
 * ```ts
 * import { Book, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const left = Book.remaining(Snapshot.pair(snapshot, 0), 'bids', {
 *   at: snapshot.block.timestamp,
 *   halted: snapshot.state.halted,
 * })
 * console.log(left)
 * ```
 *
 * @param pair - The pair, from a snapshot.
 * @param which - `'bids'` or `'asks'`.
 * @param state - The time a fill would run at and whether the venue is halted.
 * @returns The side's live base, in base atoms.
 */
export function remaining(
  pair: Pair,
  which: 'bids' | 'asks',
  state: State,
): remaining.ReturnValue {
  return side(pair, which, state).reduce((sum, row) => sum + row.remaining, 0n)
}

export declare namespace remaining {
  /** The side's live base, in base atoms. */
  type ReturnValue = bigint
  /** The errors `remaining` throws: `side`'s. */
  type ErrorType = side.ErrorType
}
