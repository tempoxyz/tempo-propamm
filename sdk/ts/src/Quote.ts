import {
  type Address,
  isAddressEqual,
  maxUint128,
  maxUint256,
  zeroAddress,
} from 'viem'
import * as Fees from './Fees.js'
import { VenueHookFlags } from './generated/constants.js'
import { type TakerAccessName, takerAccessNames } from './generated/enums.js'
import * as HotWord from './HotWord.js'
import {
  AmountOutOfRangeError,
  type AmountOutOfRangeErrorType,
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  type InvalidHotWordErrorType,
  type InvalidPriceErrorType,
  type InvalidShapeErrorType,
  type SnapshotIncompleteErrorType,
  show,
} from './internal/errors.js'
import * as validate from './internal/validate.js'
import * as Ladder from './Ladder.js'
import * as Shape from './Shape.js'
import type { PairSnapshot } from './Snapshot.js'
import * as Snapshot from './Snapshot.js'

/**
 * What a quote reads: a `VenueSnapshot`, or any object with these fields.
 *
 * @example
 * ```ts
 * import { Quote, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const source: Quote.Source = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * console.log(source.block.timestamp)
 * ```
 */
export type Source = {
  block: { timestamp: bigint }
  state: { halted: boolean; maxTakerPriorityFee: bigint }
  pairs: readonly PairSnapshot[]
}

/**
 * A taker's access as `Info.takerAccess` or `Snapshot.get` read it (a `Snapshot.AccessState` is one): who, under which
 * sponsor id, and the outcome. Read it without fee fields; the quote's `priorityFee` stands for the fee.
 *
 * @example
 * ```ts
 * import { Info, Quote } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const taker = '0x3333333333333333333333333333333333333333'
 * const takerAccess: Quote.TakerAccess = {
 *   taker,
 *   sponsorId: 0n,
 *   access: await Info.takerAccess(client, {
 *     venue: '0x1111111111111111111111111111111111111111',
 *     pairIndex: 0,
 *     taker,
 *     sponsorId: 0n,
 *   }),
 * }
 * console.log(takerAccess.access)
 * ```
 */
export type TakerAccess = {
  taker: Address
  sponsorId: bigint
  access: TakerAccessName
  /** The pair it was read for, when known: it must be the quote's. */
  pairIndex?: number | undefined
}

/**
 * A swap to price.
 *
 * @example
 * ```ts
 * import { Quote } from '@tempoxyz/propamm-sdk'
 *
 * const request: Quote.Request = {
 *   pairIndex: 0,
 *   tokenIn: '0x20C0000000000000000000000000000000000002',
 *   tokenOut: '0x20C0000000000000000000000000000000000001',
 *   amount: 1_000_000n,
 *   exactIn: false,
 *   priorityFee: 0n,
 * }
 * console.log(request.amount)
 * ```
 */
export type Request = {
  pairIndex: number
  tokenIn: Address
  tokenOut: Address
  /** The input when `exactIn`, else the output, in token atoms: `[1, 2^128 - 1]`. */
  amount: bigint
  exactIn: boolean
  /**
   * The priority fee per gas of the transaction the swap runs in (`tx.gasprice - block.basefee`, 0 below the base
   * fee): the fee cap judges it. Required: the taker's wallet sets it, so no default is right, and 0 passes every cap.
   * `Fees.priorityFee(gasPrice, snapshot.block.baseFeePerGas)` computes it from a gas price.
   */
  priorityFee: bigint
  /**
   * The taker's access, to price as the taker's `fill` would rather than as `quote`: a refusal becomes `fill`'s revert
   * for it, after the fee cap and before inventory. Without it, the quote checks no access, as `Venue.quote` checks
   * none: check it with `Info.takerAccess` or `Snapshot.get`'s `access`.
   */
  takerAccess?: TakerAccess | undefined
}

/**
 * The error the venue reverts with, with viem's decoded argument types.
 *
 * @example
 * ```ts
 * import { Quote } from '@tempoxyz/propamm-sdk'
 *
 * const revert: Quote.Revert = { errorName: 'QuoteExpired', args: [1_800_000_000] }
 * console.log(revert.errorName)
 * ```
 */
export type Revert = { errorName: string; args: readonly unknown[] }

/**
 * A quote: the venue's amounts, or its revert.
 *
 * @example
 * ```ts
 * import { Quote, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const pair = Snapshot.pair(snapshot, 0)
 * const result: Quote.Result = Quote.local(snapshot, {
 *   pairIndex: 0,
 *   tokenIn: pair.quote,
 *   tokenOut: pair.base,
 *   amount: 1_000_000n,
 *   exactIn: false,
 *   priorityFee: 0n,
 * })
 * console.log(result.ok ? result.amountIn : result.error.errorName)
 * ```
 */
export type Result =
  | {
      ok: true
      amountIn: bigint
      amountOut: bigint
      /** The taker sells base (walks the bids). */
      baseIn: boolean
      /** Base moved on the walked side. */
      baseFilled: bigint
      /** Both sides' consumption after this fill. */
      consumedAfter: Ladder.Consumed
    }
  | { ok: false; error: Revert }

const fail = (errorName: string, ...args: unknown[]): Result => ({
  ok: false,
  error: { errorName, args },
})

/**
 * `Venue.quote`, locally, as a price: the same checks in the same order, from the same state, so it returns the
 * venue's amounts or its revert. In order: `VenueHalted`, `UnknownPair`, `TokenMismatch`, `ZeroAmount`,
 * `QuoteExpired`, `SideDisabled`, the ladder (`InsufficientDepth`, `ZeroFill`), `AmountOverflow`,
 * `TakerPriorityFeeTooHigh` (`priorityFee` against the cap), then, only with `takerAccess`, `fill`'s refusal for it
 * (`TakerNotAllowed`, `TakerDenied`, `UnknownSponsor`, `SponsorDisabled`, `SponsorNotAdmitted`), then
 * `InsufficientInventory` (balance plus `hookLiquidity` when the hook has `BEFORE_FILL`).
 *
 * It prices only: it sends nothing, and checks no access unless given `takerAccess`. An argument the ABI can't carry
 * (an amount above `uint128`, a malformed address or fee) is the SDK's refusal, thrown before any of the venue's checks.
 *
 * @example
 * ```ts
 * import { Fees, Quote, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const taker = '0x3333333333333333333333333333333333333333'
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 *   access: [{ taker, sponsorIds: [0n] }],
 * })
 * const pair = Snapshot.pair(snapshot, 0)
 * const q = Quote.local(snapshot, {
 *   pairIndex: 0,
 *   tokenIn: pair.quote,
 *   tokenOut: pair.base,
 *   amount: 1_000_000n,
 *   exactIn: true,
 *   priorityFee: Fees.gwei,
 *   takerAccess: Snapshot.access(snapshot, { pairIndex: 0, taker, sponsorId: 0n }),
 * })
 * console.log(q.ok ? q.amountOut : q.error.errorName)
 * ```
 *
 * @param source - A snapshot, or any object with its block timestamp, venue state and pairs.
 * @param request - The swap, its priority fee and, optionally, the taker's access.
 * @returns The amounts and the consumption after the fill, or the venue's revert.
 */
export function local(
  source: Source,
  request: local.Parameters,
): local.ReturnValue {
  checkAmount(request.amount)
  // An argument the ABI can't carry is the SDK's refusal, before any of the venue's checks; the venue's own revert
  // arguments name the tokens checksummed, as viem decodes them.
  const checked = {
    ...request,
    tokenIn: validate.address(request.tokenIn, 'tokenIn'),
    tokenOut: validate.address(request.tokenOut, 'tokenOut'),
  }
  const fee = validate.uintBigint(request.priorityFee, 256, 'priorityFee')
  const access = takerAccessOf(request.takerAccess, request.pairIndex)
  if (source.state.halted) return fail('VenueHalted')
  const priced = price(source, checked)
  if (!priced.ok) return priced.result
  const { pair, result } = priced
  // `fill`'s access check starts with the cap, where `quote` checks it: the two refuse an over-cap swap alike.
  if (!Fees.allows(source.state.maxTakerPriorityFee, fee)) {
    return fail(
      'TakerPriorityFeeTooHigh',
      fee,
      source.state.maxTakerPriorityFee,
    )
  }
  if (access) {
    const refusal = refuse(access, request.pairIndex, fee, source)
    if (refusal) return refusal
  }
  return inventory(pair, checked.tokenOut, result)
}

export declare namespace local {
  /** The swap, its priority fee and, optionally, the taker's access. */
  type Parameters = Request
  /** The amounts and the consumption after the fill, or the venue's revert. */
  type ReturnValue = Result
  /**
   * The errors `local` throws: the SDK's refusals of inputs the venue's ABI can't carry, a pair the source lacks, and,
   * for a hand-built `Source`, a hot word, mid or shape no venue could store (`Ladder.curve`'s and `Ladder.fill`'s).
   */
  type ErrorType =
    | AmountOutOfRangeErrorType
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | InvalidHotWordErrorType
    | InvalidPriceErrorType
    | InvalidShapeErrorType
    | SnapshotIncompleteErrorType
    | GlobalErrorType
}

/** An amount the ABI can carry (`uint128`); 0 is the venue's own `ZeroAmount`. */
function checkAmount(amount: bigint) {
  if (typeof amount !== 'bigint' || amount < 0n || amount > maxUint128) {
    throw new AmountOutOfRangeError(
      `amount must be a uint128, got ${show(amount)}`,
      { parameter: 'amount', value: amount },
    )
  }
}

/** The taker's access, checked: its taker, sponsor id and outcome, and its pair the quote's. */
function takerAccessOf(
  access: TakerAccess | undefined,
  pairIndex: number,
): TakerAccess | undefined {
  if (access === undefined) return undefined
  if (typeof access !== 'object' || access === null)
    throw new InvalidArgumentError(
      'takerAccess must be { taker, sponsorId, access }',
      { parameter: 'takerAccess', value: access },
    )
  if (!takerAccessNames.includes(access.access))
    throw new InvalidArgumentError(
      `takerAccess.access is not a TakerAccess name: ${show(access.access)}`,
      { parameter: 'takerAccess.access', value: access.access },
    )
  if (access.pairIndex !== undefined && access.pairIndex !== pairIndex)
    throw new InvalidArgumentError(
      `takerAccess was read for pair ${access.pairIndex}, not the quote's pair ${pairIndex}`,
      { parameter: 'takerAccess.pairIndex', value: access.pairIndex },
    )
  return {
    taker: validate.address(access.taker, 'takerAccess.taker'),
    sponsorId: validate.sponsorId(access.sponsorId),
    access: access.access,
  }
}

/** `Venue._refuse`: `fill`'s revert for a taker the access check refuses, or undefined when it allows them. */
function refuse(
  { taker, sponsorId, access }: TakerAccess,
  pairIndex: number,
  fee: bigint,
  source: Source,
): Result | undefined {
  switch (access) {
    case 'allowed':
      return undefined
    case 'unknownPair':
      return fail('UnknownPair', pairIndex)
    case 'priorityFeeTooHigh':
      return fail(
        'TakerPriorityFeeTooHigh',
        fee,
        source.state.maxTakerPriorityFee,
      )
    case 'denied':
      return fail('TakerDenied', taker)
    case 'unknownSponsor':
      return fail('UnknownSponsor', sponsorId)
    case 'sponsorDisabled':
      return fail('SponsorDisabled', sponsorId)
    case 'sponsorNotAdmitted':
      return fail('SponsorNotAdmitted', pairIndex, sponsorId)
    default:
      // `closed` and `notListed`, and `none`, which the access check never returns.
      return fail('TakerNotAllowed', taker)
  }
}

type Priced =
  | {
      ok: true
      pair: Snapshot.PairState
      result: Extract<Result, { ok: true }>
    }
  | { ok: false; result: Result }

/** `Venue._price`: the token binding, the amount, the hot word, the active shape, the consumed depth and the ladder. */
function price(
  source: Source,
  request: Omit<Request, 'priorityFee' | 'takerAccess'>,
): Priced {
  const pair = Snapshot.pair(source, request.pairIndex)
  // A hand-built source's tokens are checked as the request's are, so the comparisons below never throw viem's error.
  const base = validate.address(pair.base, 'pair.base')
  const quote = validate.address(pair.quote, 'pair.quote')
  if (base === zeroAddress)
    return { ok: false, result: fail('UnknownPair', request.pairIndex) }
  const baseIn = isAddressEqual(request.tokenIn, base)
  const bound = baseIn
    ? isAddressEqual(request.tokenOut, quote)
    : isAddressEqual(request.tokenIn, quote) &&
      isAddressEqual(request.tokenOut, base)
  if (!bound)
    return {
      ok: false,
      result: fail('TokenMismatch', request.tokenIn, request.tokenOut),
    }
  if (request.amount === 0n) return { ok: false, result: fail('ZeroAmount') }
  const hot = pair.hot
  if (source.block.timestamp > hot.validUntil)
    return { ok: false, result: fail('QuoteExpired', hot.validUntil) }
  if (hot.depthScale === 0 || HotWord.sideOff(hot, baseIn))
    return { ok: false, result: fail('SideDisabled', baseIn) }

  // Validate the supplied side in Ladder.fill before walking it. A canonical side
  // already has a zero second word when level 5 is empty; never hide malformed tails.
  const [w0, w1] = Shape.side(pair.shapeWords, baseIn ? 'bids' : 'asks')
  const consumed = baseIn ? pair.consumed.bids : pair.consumed.asks
  const r = Ladder.fill(
    Ladder.curve(hot, pair.sizeUnit, baseIn),
    w0,
    w1,
    request.exactIn,
    request.amount,
    consumed,
  )
  if (!r.ok) return { ok: false, result: fail(r.error) }
  if (r.amountIn > maxUint128 || r.amountOut > maxUint128)
    return { ok: false, result: fail('AmountOverflow') }
  return {
    ok: true,
    pair,
    result: {
      ok: true,
      amountIn: r.amountIn,
      amountOut: r.amountOut,
      baseIn,
      baseFilled: r.baseFilled,
      consumedAfter: Ladder.applyFill(pair.consumed, baseIn, r.baseFilled),
    },
  }
}

function inventory(
  pair: Snapshot.PairState,
  tokenOut: Address,
  result: Extract<Result, { ok: true }>,
): Result {
  const baseOut = isAddressEqual(tokenOut, pair.base)
  const balance = baseOut ? pair.inventory.base : pair.inventory.quote
  if (balance >= result.amountOut) return result
  const extra =
    (pair.hookFlags & VenueHookFlags.beforeFill) !== 0
      ? baseOut
        ? pair.hookLiquidity.base
        : pair.hookLiquidity.quote
      : 0n
  const available = extra > maxUint256 - balance ? maxUint256 : balance + extra
  if (available < result.amountOut)
    return fail('InsufficientInventory', tokenOut, available, result.amountOut)
  return result
}
