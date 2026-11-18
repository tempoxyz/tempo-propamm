import {
  type DecodeEventLogErrorType,
  decodeEventLog,
  type Hex,
  isAddressEqual,
  type Log,
  toEventSelector,
} from 'viem'
import type { PreparedCall } from './actions/internal/define.js'
import { venueAbi } from './generated/abis.js'
import {
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
} from './internal/errors.js'
import * as validate from './internal/validate.js'
import type { PostRef } from './Post.js'

const outcomeAbi = venueAbi.filter(
  (item) =>
    item.type === 'event' &&
    (item.name === 'Posted' || item.name === 'HotWordReset'),
)
const outcomeTopics = new Set(outcomeAbi.map((event) => toEventSelector(event)))

/**
 * Which entries of a mined, successful order or cancel batch the venue stored. The venue skips an entry whose sequence
 * isn't above the stored one, without reverting or emitting, so a successful receipt alone doesn't mean a quote is
 * live.
 *
 * @example
 * ```ts
 * import { Actions, PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   chain: tempoModerato,
 *   transport: http(),
 *   account: privateKeyToAccount(`0x${'1'.repeat(64)}`),
 * })
 * const venue = '0x1111111111111111111111111111111111111111'
 * const order = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: 2, validUntil: 1_800_000_000 }
 * const { receipt } = await Actions.maker.orderSync(client, { venue, order })
 * const outcome = PostOutcome.fromReceipt(Actions.maker.order.call({ venue, order }), receipt)
 * if (outcome.status === 'success') {
 *   const stored: PostOutcome.PostOutcome = outcome
 *   console.log(stored.allAccepted, stored.skipped)
 * }
 * ```
 */
export type PostOutcome = {
  /** Entries a `Posted` event acknowledged, in request order. */
  accepted: PostRef[]
  /** Entries the venue ignored as stale, in request order. */
  skipped: PostRef[]
  allAccepted: boolean
}

/**
 * A call whose entries a receipt's `Posted` events acknowledge: an order, cancel or `post` call.
 *
 * @example
 * ```ts
 * import { Actions, type PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 *
 * const call: PostOutcome.PostCall = Actions.maker.cancel.call({
 *   venue: '0x1111111111111111111111111111111111111111',
 *   cancel: { pairIndex: 0, sequence: 9, mid: Price.one },
 * })
 * console.log(call.posts)
 * ```
 */
export type PostCall = Pick<PreparedCall, 'address' | 'posts'>

/**
 * What an outcome reads of a transaction receipt: viem's `TransactionReceipt` is one. A receipt whose `status` is
 * `'pending'`, or whose `blockNumber` or `blockHash` is null, is pending: it has no outcome yet.
 *
 * @example
 * ```ts
 * import { PostOutcome } from '@tempoxyz/propamm-sdk'
 *
 * const pending: PostOutcome.Receipt = { status: 'success', logs: [], blockNumber: null, blockHash: null }
 * console.log(pending.blockNumber === null)
 * ```
 */
export type Receipt = {
  /** viem's `'pending'` for a receipt from a block not yet sealed. */
  status: 'success' | 'reverted' | 'pending'
  logs: readonly Log[]
  /** Null while the transaction is pending. */
  blockNumber: bigint | null
  /** Null while the transaction is pending. */
  blockHash?: Hex | null | undefined
}

/**
 * The outcome of one call's transaction: `success` with the entries the venue stored and skipped; `reverted`, where it
 * stored none (none was skipped as stale either); `pending`, where nothing is known yet.
 *
 * @example
 * ```ts
 * import { Actions, PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 *
 * const call = Actions.maker.cancel.call({
 *   venue: '0x1111111111111111111111111111111111111111',
 *   cancel: { pairIndex: 0, sequence: 9, mid: Price.one },
 * })
 * const outcome: PostOutcome.ReceiptOutcome = PostOutcome.fromReceipt(call, {
 *   status: 'success',
 *   logs: [],
 *   blockNumber: null,
 * })
 * console.log(outcome.status) // 'pending': not 'every entry skipped'
 * ```
 */
export type ReceiptOutcome =
  | ({ status: 'success' } & PostOutcome)
  | { status: 'reverted' }
  | { status: 'pending' }

/**
 * The outcome of a transaction of several post calls, per call in the order it sent them, as {@link ReceiptOutcome}.
 *
 * @example
 * ```ts
 * import { Actions, PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 *
 * const venue = '0x1111111111111111111111111111111111111111'
 * const calls = [Actions.maker.cancel.call({ venue, cancel: { pairIndex: 0, sequence: 9, mid: Price.one } })]
 * const outcome: PostOutcome.BatchReceiptOutcome = PostOutcome.fromBatchReceipt(calls, {
 *   status: 'reverted',
 *   logs: [],
 *   blockNumber: 1n,
 * })
 * console.log(outcome.status)
 * ```
 */
export type BatchReceiptOutcome =
  | { status: 'success'; outcomes: PostOutcome[] }
  | { status: 'reverted' }
  | { status: 'pending' }

/**
 * Matches `call`'s entries against the `Posted` events at its venue in a receipt, after reading the receipt's status:
 * a pending receipt (viem's `'pending'` status, or no block yet) is `pending` and a reverted one `reverted`, never
 * "every entry skipped". If the
 * transaction carried other posts to the venue, such as a Tempo batch of several calls, use {@link fromBatchReceipt}.
 * A receipt that resets one of this call's pairs is ambiguous: submit `resetHotWord` in a separate transaction, then
 * attribute its fresh posts from a later receipt.
 *
 * @example
 * ```ts
 * import { Actions, PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   chain: tempoModerato,
 *   transport: http(),
 *   account: privateKeyToAccount(`0x${'1'.repeat(64)}`),
 * })
 * const venue = '0x1111111111111111111111111111111111111111'
 * const order = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: 2, validUntil: 1_800_000_000 }
 * const { receipt } = await Actions.maker.orderSync(client, { venue, order })
 * const outcome = PostOutcome.fromReceipt(Actions.maker.order.call({ venue, order }), receipt)
 * console.log(outcome.status === 'success' && outcome.allAccepted)
 * ```
 *
 * @param call - The order, cancel or `post` call the transaction sent.
 * @param receipt - Its receipt.
 * @returns The outcome, by the receipt's status.
 */
export function fromReceipt(
  call: PostCall,
  receipt: Receipt,
): fromReceipt.ReturnValue {
  const batch = fromBatchReceipt([call], receipt)
  if (batch.status !== 'success') return batch
  return { status: 'success', ...(batch.outcomes[0] as PostOutcome) }
}

export declare namespace fromReceipt {
  /** The outcome, by the receipt's status. */
  type ReturnValue = ReceiptOutcome
  /** The errors `fromReceipt` throws. */
  type ErrorType = fromBatch.ErrorType
}

/**
 * Matches the post calls of one transaction, in the order it sent them, against its receipt, as {@link fromBatch} does,
 * after reading the receipt's status: a pending receipt is `pending` and a reverted one `reverted`.
 *
 * @example
 * ```ts
 * import { Actions, PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { sendTransactionSync } from 'viem/actions'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   chain: tempoModerato,
 *   transport: http(),
 *   account: privateKeyToAccount(`0x${'1'.repeat(64)}`),
 * })
 * const venue = '0x1111111111111111111111111111111111111111'
 * const order = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: 3, validUntil: 1_800_000_000 }
 * const calls = [
 *   Actions.maker.order.call({ venue, order }),
 *   Actions.maker.cancel.call({ venue, cancel: { pairIndex: 1, sequence: 9, mid: order.mid } }),
 * ]
 * const receipt = await sendTransactionSync(client, {
 *   calls: calls.map(({ to, data }) => ({ to, data })),
 * })
 * const outcome = PostOutcome.fromBatchReceipt(calls, receipt)
 * if (outcome.status === 'success') console.log(outcome.outcomes.map((o) => o.allAccepted))
 * ```
 *
 * @param calls - The post calls the transaction sent, in its order.
 * @param receipt - Its receipt.
 * @returns The outcomes, by the receipt's status.
 */
export function fromBatchReceipt(
  calls: readonly PostCall[],
  receipt: Receipt,
): fromBatchReceipt.ReturnValue {
  if (
    typeof receipt !== 'object' ||
    receipt === null ||
    !['success', 'reverted', 'pending'].includes(receipt.status) ||
    !Array.isArray(receipt.logs)
  )
    throw new InvalidArgumentError(
      "receipt must be a transaction receipt: { status: 'success' | 'reverted' | 'pending', logs, blockNumber }",
      { parameter: 'receipt', value: receipt },
    )
  // The calls are checked whatever the status, so a wrong call never hides behind a pending receipt.
  const outcomes = (logs: readonly Log[]) => fromBatch(calls, logs)
  if (
    receipt.status === 'pending' ||
    receipt.blockNumber === null ||
    receipt.blockHash === null
  ) {
    outcomes([])
    return { status: 'pending' }
  }
  if (receipt.status === 'reverted') {
    outcomes([])
    return { status: 'reverted' }
  }
  return { status: 'success', outcomes: outcomes(receipt.logs) }
}

export declare namespace fromBatchReceipt {
  /** The outcomes, by the receipt's status. */
  type ReturnValue = BatchReceiptOutcome
  /** The errors `fromBatchReceipt` throws. */
  type ErrorType = fromBatch.ErrorType
}

/**
 * Matches `call`'s entries against the `Posted` events at its venue (the Rust SDK's `PostOutcome::from_logs`). Other
 * contracts' and other events' logs are ignored. The logs must be a mined, successful transaction's: a reverted or
 * pending one has none and would read every entry skipped, so prefer {@link fromReceipt}, which reads the status. If
 * the transaction carried other posts to the venue, such as a Tempo batch of several calls, match them together with
 * {@link fromBatch}.
 *
 * @example
 * ```ts
 * import { Actions, PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   chain: tempoModerato,
 *   transport: http(),
 *   account: privateKeyToAccount(`0x${'1'.repeat(64)}`),
 * })
 * const venue = '0x1111111111111111111111111111111111111111'
 * const order = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: 2, validUntil: 1_800_000_000 }
 * // `orderSync` throws when the transaction reverts, so its receipt's logs are a successful one's.
 * const { receipt } = await Actions.maker.orderSync(client, { venue, order })
 * const outcome = PostOutcome.fromLogs(Actions.maker.order.call({ venue, order }), receipt.logs)
 * console.log(outcome.accepted, outcome.skipped)
 * ```
 *
 * @param call - The order, cancel or `post` call the transaction sent.
 * @param logs - The mined, successful transaction's logs.
 * @returns The entries the venue stored and skipped.
 */
export function fromLogs(
  call: PostCall,
  logs: readonly Log[],
): fromLogs.ReturnValue {
  return fromBatch([call], logs)[0] as PostOutcome
}

export declare namespace fromLogs {
  /** The entries the venue stored and skipped. */
  type ReturnValue = PostOutcome
  /** The errors `fromLogs` throws. */
  type ErrorType = fromBatch.ErrorType
}

/**
 * Matches the post calls of one transaction, in the order it sent them, against its logs (the Rust SDK's
 * `PostOutcome::from_batch`). Each entry claims the first unclaimed `Posted` event at its venue for its pair and its
 * word as the venue stores it, refill bits cleared. The venue applies or skips entries in that same order, so an entry
 * that repeats an earlier one's pair and sequence reads skipped, even with an identical word. A `HotWordReset` for a
 * pair this function attributes makes the receipt ambiguous, so it throws: send the reset separately, then attribute
 * fresh posts from a later receipt. As for {@link fromLogs}, the logs must be a mined, successful transaction's:
 * {@link fromBatchReceipt} reads the status.
 *
 * @example
 * ```ts
 * import { Actions, PostOutcome, Price } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { sendTransactionSync } from 'viem/actions'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   chain: tempoModerato,
 *   transport: http(),
 *   account: privateKeyToAccount(`0x${'1'.repeat(64)}`),
 * })
 * const venue = '0x1111111111111111111111111111111111111111'
 * const order = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: 4, validUntil: 1_800_000_000 }
 * const calls = [Actions.maker.order.call({ venue, order }), Actions.maker.order.call({ venue, order })]
 * const receipt = await sendTransactionSync(client, {
 *   calls: calls.map(({ to, data }) => ({ to, data })),
 *   throwOnReceiptRevert: true,
 * })
 * // The repeat at the same sequence reads skipped.
 * console.log(PostOutcome.fromBatch(calls, receipt.logs).map((o) => o.allAccepted))
 * ```
 *
 * @param calls - The post calls the transaction sent, in its order.
 * @param logs - The mined, successful transaction's logs.
 * @returns One outcome per call, in call order.
 */
export function fromBatch(
  calls: readonly PostCall[],
  logs: readonly Log[],
): fromBatch.ReturnValue {
  if (!Array.isArray(calls))
    throw new InvalidArgumentError('calls must be an array of post calls', {
      parameter: 'calls',
      value: calls,
    })
  if (!Array.isArray(logs))
    throw new InvalidArgumentError('logs must be an array of logs', {
      parameter: 'logs',
      value: logs,
    })
  for (const [i, call] of calls.entries()) {
    if (!call?.posts || call.posts.length === 0)
      throw new InvalidArgumentError(
        'the call is not an order or cancel batch',
        { parameter: `calls[${i}]`, value: call },
      )
    validate.address(call.address, `calls[${i}].address`)
  }
  // parseEventLogs silently drops malformed logs, even with strict: true.
  // Select relevant raw logs first, then decode each without swallowing errors.
  const events: {
    address: PostCall['address']
    args: { pairIndex: number; hotWord: Hex }
  }[] = []
  for (const log of logs) {
    const selector = log.topics[0]?.toLowerCase() as Hex | undefined
    if (!selector || !outcomeTopics.has(selector)) continue
    if (
      !calls.some(
        (call) => call.address.toLowerCase() === log.address.toLowerCase(),
      )
    )
      continue
    validate.address(log.address, 'logs[].address')
    const event = decodeEventLog({
      abi: outcomeAbi,
      data: log.data,
      // viem matches event signatures case-sensitively; normalize only topic0.
      topics: [selector, ...log.topics.slice(1)],
      strict: true,
    })
    if (event.eventName === 'HotWordReset') {
      if (
        calls.some(
          (call) =>
            isAddressEqual(log.address, call.address) &&
            (call.posts as readonly PostRef[]).some(
              (entry) => entry.pairIndex === event.args.pairIndex,
            ),
        )
      )
        throw new InvalidArgumentError(
          'post outcomes are ambiguous across a HotWordReset for the same venue and pair: send resetHotWord in a separate transaction',
          { parameter: 'logs' },
        )
    } else events.push({ ...event, address: log.address })
  }
  const claimed = events.map(() => false)
  return calls.map((call) => {
    const accepted: PostRef[] = []
    const skipped: PostRef[] = []
    for (const entry of call.posts as readonly PostRef[]) {
      const i = events.findIndex(
        (event, k) =>
          !claimed[k] &&
          isAddressEqual(event.address, call.address) &&
          event.args.pairIndex === entry.pairIndex &&
          event.args.hotWord.toLowerCase() === entry.word.toLowerCase(),
      )
      if (i === -1) skipped.push(entry)
      else {
        claimed[i] = true
        accepted.push(entry)
      }
    }
    return { accepted, skipped, allAccepted: skipped.length === 0 }
  })
}

export declare namespace fromBatch {
  /** One outcome per call, in call order. */
  type ReturnValue = PostOutcome[]
  /** The errors `fromBatch` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | DecodeEventLogErrorType
    | GlobalErrorType
}
