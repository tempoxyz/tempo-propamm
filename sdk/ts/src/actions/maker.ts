// The Rust SDK's `Exchange` concepts over `post`: whole-ladder orders and cancels, each carrying the entries
// `PostOutcome` matches against `Posted`, and `cancelAll`, which cancels every live pair without halting the venue. Take
// every sequence from one `Sequencer`.
import {
  type Account,
  type Address,
  type Chain,
  type Client,
  type Hex,
  type Log,
  maxUint32,
  maxUint96,
  type Prettify,
  type Transport,
  type WriteContractErrorType,
  type WriteContractReturnType,
  type WriteContractSyncErrorType,
} from 'viem'
import { getBlock, writeContract } from 'viem/actions'
import { venueAbi } from '../generated/abis.js'
import * as HotWord from '../HotWord.js'
import {
  type DuplicatePairErrorType,
  EmptyBatchError,
  type EmptyBatchErrorType,
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  type InvalidHotWordErrorType,
  type InvalidOrderErrorType,
  type SnapshotIncompleteErrorType,
  UnexpectedResponseError,
} from '../internal/errors.js'
import {
  assertPinnable,
  type MulticallParameters,
  multicallOptions,
  type PinErrorType,
  type ReadManyErrorType,
  type ReadParameters,
  readMany,
  readOptions,
} from '../internal/read.js'
import type { AnyClient } from '../internal/types.js'
import * as validate from '../internal/validate.js'
import * as VenueReads from '../internal/venue.js'
import * as Post from '../Post.js'
import * as Price from '../Price.js'
import * as Sequencer from '../Sequencer.js'
import { type VenueAbi, type VenueCall, venueCall } from './internal/abis.js'
import {
  assertWriteValidity,
  type EventLog,
  type ExtractEventOptions,
  extractEvents as extractLogs,
  send,
  type WriteParameters,
  type WriteSyncParameters,
} from './internal/define.js'
import { type PostSyncReturnValue, sendPost } from './internal/post.js'

const target = (args: { venue: Address }) =>
  validate.address(args.venue, 'venue', { nonzero: true })

/** The last sequence a pair can store: no post replaces a word at it. */
const maxSequence = Number(maxUint32)

/** The `post` call for `entries`, carrying each entry for `PostOutcome`. */
function postCall(venue: Address, entries: Post.Entry[]): VenueCall<'post'> {
  const { packed, posts } = Post.pack(entries)
  return venueCall({
    venue,
    functionName: 'post',
    args: [packed],
    signer: { role: 'ownerOrAgent' },
    posts,
  })
}

/**
 * Atomically replaces the hot words of distinct pairs with whole-ladder orders (owner or agent). Their shapes
 * must already be set. A stale entry is skipped without an event, so a successful receipt alone doesn't mean
 * every quote is live: read the outcome.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
 *
 * const hash = await Actions.maker.bulkOrders(client, {
 *   venue: '0x...',
 *   orders: [
 *     {
 *       pairIndex: 0,
 *       mid: Price.parse('1.085'),
 *       shapeId: 7,
 *       sequence: Sequencer.next(sequencer, 0),
 *       validUntil: 1_800_000_000,
 *     },
 *     {
 *       pairIndex: 1,
 *       mid: Price.parse('1.085'),
 *       shapeId: 7,
 *       sequence: Sequencer.next(sequencer, 1),
 *       validUntil: 1_800_000_000,
 *     },
 *   ],
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function bulkOrders<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: bulkOrders.Parameters<chain, account>,
): Promise<bulkOrders.ReturnValue> {
  return send(writeContract, client, parameters, bulkOrders.call(parameters))
}

export namespace bulkOrders {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** One order per pair, each with a sequence from one `Sequencer`. */
    orders: readonly Post.OrderRequest[]
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments (an empty batch, a pair named twice, an order's field), and viem's write
   * errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | DuplicatePairErrorType
    | EmptyBatchErrorType
    | InvalidOrderErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `post` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'post'> {
    const venue = target(args)
    if (!Array.isArray(args.orders) || args.orders.length === 0)
      throw new EmptyBatchError('an order batch needs at least one order')
    return postCall(venue, Post.bulkOrders(args.orders))
  }

  /**
   * Extracts the `Posted` events from logs: one per entry stored, none for a stale one.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `Posted` events.
   */
  export function extractEvents(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'Posted'>[] {
    return extractLogs(venueAbi, 'Posted', logs, options)
  }
}

/**
 * Atomically replaces the hot words of distinct pairs with whole-ladder orders (owner or agent). Their shapes
 * must already be set. A stale entry is skipped without an event, so a successful receipt alone doesn't mean
 * every quote is live: read the outcome.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
 *
 * const result = await Actions.maker.bulkOrdersSync(client, {
 *   venue: '0x...',
 *   orders: [
 *     {
 *       pairIndex: 0,
 *       mid: Price.parse('1.085'),
 *       shapeId: 7,
 *       sequence: Sequencer.next(sequencer, 0),
 *       validUntil: 1_800_000_000,
 *     },
 *     {
 *       pairIndex: 1,
 *       mid: Price.parse('1.085'),
 *       shapeId: 7,
 *       sequence: Sequencer.next(sequencer, 1),
 *       validUntil: 1_800_000_000,
 *     },
 *   ],
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.outcome)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
 */
export async function bulkOrdersSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: bulkOrdersSync.Parameters<chain, account>,
): Promise<bulkOrdersSync.ReturnValue> {
  return sendPost(client, parameters, bulkOrders.call(parameters))
}

export namespace bulkOrdersSync {
  /** The call's arguments. */
  export type Args = bulkOrders.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = bulkOrders.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt. */
  export type ReturnValue = PostSyncReturnValue

  /** `bulkOrders`'s errors, and viem's receipt errors. */
  export type ErrorType = bulkOrders.ErrorType | WriteContractSyncErrorType
}

/**
 * Replaces one pair's hot word with a whole-ladder order (owner or agent): a `bulkOrders` of one.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
 *
 * const hash = await Actions.maker.order(client, {
 *   venue: '0x...',
 *   order: {
 *     pairIndex: 0,
 *     mid: Price.parse('1.085'),
 *     shapeId: 7,
 *     sequence: Sequencer.next(sequencer, 0),
 *     validUntil: 1_800_000_000,
 *   },
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function order<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: order.Parameters<chain, account>,
): Promise<order.ReturnValue> {
  return send(writeContract, client, parameters, order.call(parameters))
}

export namespace order {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The order, with a sequence from one `Sequencer`. */
    order: Post.OrderRequest
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments (the venue, an order's field), and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | InvalidOrderErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `post` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'post'> {
    const venue = target(args)
    return postCall(venue, [Post.order(args.order)])
  }

  /**
   * Extracts the `Posted` events from logs: one per entry stored, none for a stale one.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `Posted` events.
   */
  export function extractEvents(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'Posted'>[] {
    return extractLogs(venueAbi, 'Posted', logs, options)
  }
}

/**
 * Replaces one pair's hot word with a whole-ladder order (owner or agent): a `bulkOrders` of one.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
 *
 * const result = await Actions.maker.orderSync(client, {
 *   venue: '0x...',
 *   order: {
 *     pairIndex: 0,
 *     mid: Price.parse('1.085'),
 *     shapeId: 7,
 *     sequence: Sequencer.next(sequencer, 0),
 *     validUntil: 1_800_000_000,
 *   },
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.outcome)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
 */
export async function orderSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: orderSync.Parameters<chain, account>,
): Promise<orderSync.ReturnValue> {
  return sendPost(client, parameters, order.call(parameters))
}

export namespace orderSync {
  /** The call's arguments. */
  export type Args = order.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = order.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt. */
  export type ReturnValue = PostSyncReturnValue

  /** `order`'s errors, and viem's receipt errors. */
  export type ErrorType = order.ErrorType | WriteContractSyncErrorType
}

/**
 * Cancels both sides of distinct pairs with newer disabled words (owner or agent). A newer in-flight post
 * supersedes a cancel: `cancelAll` reads every pair for you, and `Actions.venue.closePair` is a stop no later
 * post undoes.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
 *
 * const hash = await Actions.maker.bulkCancel(client, {
 *   venue: '0x...',
 *   cancels: [
 *     { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.085') },
 *     { pairIndex: 1, sequence: Sequencer.next(sequencer, 1), mid: Price.parse('0.92') },
 *   ],
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function bulkCancel<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: bulkCancel.Parameters<chain, account>,
): Promise<bulkCancel.ReturnValue> {
  return send(writeContract, client, parameters, bulkCancel.call(parameters))
}

export namespace bulkCancel {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** One cancel per pair, each with a sequence from one `Sequencer`. */
    cancels: readonly Post.CancelRequest[]
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments (an empty batch, a pair named twice, an order's field), and viem's write
   * errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | DuplicatePairErrorType
    | EmptyBatchErrorType
    | InvalidOrderErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `post` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'post'> {
    const venue = target(args)
    if (!Array.isArray(args.cancels) || args.cancels.length === 0)
      throw new EmptyBatchError('a cancel batch needs at least one cancel')
    return postCall(venue, Post.bulkCancel(args.cancels))
  }

  /**
   * Extracts the `Posted` events from logs: one per entry stored, none for a stale one.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `Posted` events.
   */
  export function extractEvents(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'Posted'>[] {
    return extractLogs(venueAbi, 'Posted', logs, options)
  }
}

/**
 * Cancels both sides of distinct pairs with newer disabled words (owner or agent). A newer in-flight post
 * supersedes a cancel: `cancelAll` reads every pair for you, and `Actions.venue.closePair` is a stop no later
 * post undoes.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
 *
 * const result = await Actions.maker.bulkCancelSync(client, {
 *   venue: '0x...',
 *   cancels: [
 *     { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.085') },
 *     { pairIndex: 1, sequence: Sequencer.next(sequencer, 1), mid: Price.parse('0.92') },
 *   ],
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.outcome)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
 */
export async function bulkCancelSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: bulkCancelSync.Parameters<chain, account>,
): Promise<bulkCancelSync.ReturnValue> {
  return sendPost(client, parameters, bulkCancel.call(parameters))
}

export namespace bulkCancelSync {
  /** The call's arguments. */
  export type Args = bulkCancel.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = bulkCancel.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt. */
  export type ReturnValue = PostSyncReturnValue

  /** `bulkCancel`'s errors, and viem's receipt errors. */
  export type ErrorType = bulkCancel.ErrorType | WriteContractSyncErrorType
}

/**
 * Cancels both sides of one pair with a newer disabled word (owner or agent): a `bulkCancel` of one.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
 *
 * const hash = await Actions.maker.cancel(client, {
 *   venue: '0x...',
 *   cancel: { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.085') },
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function cancel<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancel.Parameters<chain, account>,
): Promise<cancel.ReturnValue> {
  return send(writeContract, client, parameters, cancel.call(parameters))
}

export namespace cancel {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The cancel, with a sequence from one `Sequencer`. */
    cancel: Post.CancelRequest
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments (the venue, an order's field), and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | InvalidOrderErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `post` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'post'> {
    const venue = target(args)
    return postCall(venue, [Post.cancel(args.cancel)])
  }

  /**
   * Extracts the `Posted` events from logs: one per entry stored, none for a stale one.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `Posted` events.
   */
  export function extractEvents(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'Posted'>[] {
    return extractLogs(venueAbi, 'Posted', logs, options)
  }
}

/**
 * Cancels both sides of one pair with a newer disabled word (owner or agent): a `bulkCancel` of one.
 *
 * @example
 * ```ts
 * import { Actions, Price, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
 *
 * const result = await Actions.maker.cancelSync(client, {
 *   venue: '0x...',
 *   cancel: { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.085') },
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.outcome)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
 */
export async function cancelSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancelSync.Parameters<chain, account>,
): Promise<cancelSync.ReturnValue> {
  return sendPost(client, parameters, cancel.call(parameters))
}

export namespace cancelSync {
  /** The call's arguments. */
  export type Args = cancel.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = cancel.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt. */
  export type ReturnValue = PostSyncReturnValue

  /** `cancel`'s errors, and viem's receipt errors. */
  export type ErrorType = cancel.ErrorType | WriteContractSyncErrorType
}

/**
 * Cancels every live pair's quotes in one atomic `post`, without halting the venue (owner or agent). It reads the venue's
 * pairs at one block (`cancelAll.requests`) and posts each a cancel: a newer word with no sides, at its stored mid
 * (moved inside the pair's mid band, so an agent's cancel passes it) and its next sequence, above both the stored one
 * and, for a pair `sequencer` tracks, its counter. Before it sends, it records each cancel in `sequencer` (a pair it
 * didn't track joins it at the cancel's sequence), so the pair's next post outranks the cancel. A newer post already in flight supersedes a cancel: pass the
 * `sequencer` your posts draw from, and read the outcome (`cancelAllSync`).
 *
 * Some live pairs get no cancel (`requests`' `skipped`, which `cancelAllSync` returns): one never posted to has no
 * quote, and one whose stored word is at `uint32` max can't be replaced by any post, so only `closePair` or `setHalted`
 * stops it. When no pair gets a cancel it sends nothing and throws `EmptyBatchError`, naming the skipped pairs. To stop
 * every fill outright, `Actions.venue.setHalted`; to stop one pair for good, `Actions.venue.closePair`.
 *
 * @example
 * ```ts
 * import { Actions, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
 *
 * const hash = await Actions.maker.cancelAll(client, {
 *   venue: '0x...',
 *   sequencer,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function cancelAll<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancelAll.Parameters<chain, account>,
): Promise<cancelAll.ReturnValue> {
  assertWriteValidity(parameters)
  const requests = plan(
    await readPairs(client, parameters),
    parameters.sequencer,
  )
  return send(
    writeContract,
    client,
    parameters,
    cancelCall(parameters.venue, requests),
  )
}

export namespace cancelAll {
  /** The action's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /**
     * The allocator your posts take their sequences from. A pair it tracks cancels above its counter (and the stored
     * sequence), and discovery reserves the cancel in it. A pair it doesn't track cancels at its stored sequence plus one,
     * which an unmined post at that sequence would beat.
     */
    sequencer?: Sequencer.Sequencer | undefined
  }

  /** `call`'s arguments: the cancels `requests` read. */
  export type CallArgs = {
    /** The venue. */
    venue: Address
    /** One cancel per pair. */
    cancels: readonly Post.CancelRequest[]
  }

  /** Why `requests` gives a live pair no cancel. */
  export type SkipReason =
    /** Its word is still the one `addPair` stored, mid 0, and `sequencer` holds no later sequence for it: no quote. */
    | 'neverPosted'
    /** Its stored word is at `uint32` max: no post can replace it, so only `closePair` or `setHalted` stops it. */
    | 'sequenceExhausted'

  /** A live pair `requests` gives no cancel, and why. */
  export type SkippedPair = {
    /** The pair. */
    pairIndex: number
    /** Why it gets no cancel. */
    reason: SkipReason
  }

  /** What `requests` reads: a cancel per live pair it can cancel, and every other live pair, in pair order. */
  export type Requests = {
    /** One cancel per pair it can cancel, in pair order: `call`'s `cancels`. */
    cancels: Post.CancelRequest[]
    /** Every live pair it gives no cancel, in pair order. A removed pair isn't live and isn't listed. */
    skipped: SkippedPair[]
  }

  /** The arguments, an optional Multicall3 address and the transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & MulticallParameters & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals, the reads' errors, `EmptyBatchError` when no pair gets a cancel, and viem's write errors. */
  export type ErrorType =
    | requests.ErrorType
    | EmptyBatchErrorType
    | WriteContractErrorType

  /**
   * Reads one cancel per live pair at one block (`blockNumber`, else the block `blockTag` names, else the latest), and
   * the live pairs it gives none (`skipped`). Each cancel is at the pair's stored mid, moved inside its mid band if it
   * has one, and the pair's next sequence: one above the stored sequence, or above `sequencer`'s counter for a pair it
   * tracks if that is higher (`max(last, stored) + 1`). A pair still on the word `addPair` stored (mid 0) is skipped as
   * `neverPosted`, unless `sequencer` holds a later sequence for it, whose post may still be unmined: then it is
   * cancelled at its band's `minMid`, or at `Price.one` without a band. A pair whose stored word is at `uint32` max is
   * skipped as `sequenceExhausted`; if only `sequencer`'s counter is, the cancel falls back to the stored sequence plus
   * one. After all pinned reads and validation succeed, it synchronously reserves every cancel in the shared
   * `sequencer`, including pairs it did not track, without lowering any counter. Concurrent discovery and `next`
   * calls therefore allocate above these reservations. Persist the updated checkpoint before sending the cancels
   * yourself (`cancelAll.call`); see `Sequencer` for durable max-merge and writer fencing. Reservations are not
   * rolled back if the cancels are abandoned or sending fails. With a sequencer, only the latest un-overridden
   * state is accepted: omit `blockNumber`, `stateOverride` and `blockOverrides`, and omit `blockTag` or use `latest`.
   * Historical and hypothetical discovery remains available without a sequencer and reserves nothing.
   * Every read is pinned by canonical block hash (EIP-1898); a reorg or a node without hash-selector support rejects
   * discovery before any sequences are allocated or cancellations are sent.
   *
   * @example
   * ```ts
   * import { Actions, Sequencer } from '@tempoxyz/propamm-sdk'
   * import { createClient, http } from 'viem'
   * import { tempoModerato } from 'viem/chains'
   *
   * const client = createClient({ chain: tempoModerato, transport: http() })
   * const venue = '0x1111111111111111111111111111111111111111'
   * const sequencer = await Sequencer.seed(client, { venue, pairs: [0, 1] })
   *
   * const { cancels, skipped } = await Actions.maker.cancelAll.requests(client, { venue, sequencer })
   * for (const { pairIndex, reason } of skipped) console.log(`pair ${pairIndex} gets no cancel: ${reason}`)
   * if (cancels.length > 0) console.log(Actions.maker.cancelAll.call({ venue, cancels }).data)
   * ```
   *
   * @param client - Client.
   * @param parameters - The venue, the sequencer, the read options and an optional Multicall3 address.
   * @returns The cancels, and the live pairs skipped, in pair order.
   */
  export async function requests<chain extends Chain | undefined>(
    client: Client<Transport, chain>,
    parameters: requests.Parameters,
  ): Promise<requests.ReturnValue> {
    if (parameters.sequencer !== undefined) {
      for (const parameter of [
        'blockNumber',
        'blockOverrides',
        'stateOverride',
      ] as const)
        if (parameters[parameter] !== undefined)
          throw new InvalidArgumentError(
            'sequencer reservations require latest state without read overrides',
            { parameter, value: parameters[parameter] },
          )
      if (parameters.blockTag !== undefined && parameters.blockTag !== 'latest')
        throw new InvalidArgumentError(
          'sequencer reservations require blockTag latest',
          { parameter: 'blockTag', value: parameters.blockTag },
        )
    }
    return plan(await readPairs(client, parameters), parameters.sequencer)
  }

  export namespace requests {
    /** The venue, the sequencer, the read options and an optional Multicall3 address. */
    export type Parameters = Omit<ReadParameters, 'account'> &
      MulticallParameters &
      Args

    /** The cancels, and the live pairs skipped, in pair order. */
    export type ReturnValue = Requests

    /** The SDK's refusals of its arguments, the block read's errors and the reads' errors. */
    export type ErrorType =
      | InvalidAddressErrorType
      | InvalidArgumentErrorType
      | InvalidHotWordErrorType
      | PinErrorType
      | ReadManyErrorType
      | SnapshotIncompleteErrorType
      | GlobalErrorType
  }

  /**
   * The validated `post` call for cancels `requests` read, for a `calls` batch, `Plan.simulate`, `Roles.check` or
   * viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: CallArgs): VenueCall<'post'> {
    const venue = target(args)
    if (!Array.isArray(args.cancels) || args.cancels.length === 0)
      throw new EmptyBatchError('no pair has a quote to cancel')
    return postCall(venue, Post.bulkCancel(args.cancels))
  }

  /**
   * Extracts the `Posted` events from logs: one per cancel stored, none for one a newer post superseded.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `Posted` events.
   */
  export function extractEvents(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'Posted'>[] {
    return extractLogs(venueAbi, 'Posted', logs, options)
  }
}

/**
 * Cancels every live pair's quotes in one atomic `post`, without halting the venue (owner or agent), and waits for the
 * receipt: `cancelAll`, which records each cancel in `sequencer` before it sends. `skipped` lists the
 * live pairs it sent no cancel (`cancelAll.requests`' reasons): those still quote if they did. `outcome` reads the
 * cancels it sent: one it reports skipped was superseded by a newer post, so that pair still quotes too. So
 * `outcome.allAccepted` alone doesn't mean every pair is cancelled: check `skipped` as well.
 *
 * @example
 * ```ts
 * import { Actions, Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
 *
 * const result = await Actions.maker.cancelAllSync(client, {
 *   venue: '0x...',
 *   sequencer,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.outcome, result.skipped)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `Posted` events' arguments, which cancels the venue stored or skipped as superseded, the live pairs no
 * cancel went to, and the receipt.
 */
export async function cancelAllSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancelAllSync.Parameters<chain, account>,
): Promise<cancelAllSync.ReturnValue> {
  assertWriteValidity(parameters)
  const requests = plan(
    await readPairs(client, parameters),
    parameters.sequencer,
  )
  const result = await sendPost(
    client,
    parameters,
    cancelCall(parameters.venue, requests),
  )
  return { ...result, skipped: requests.skipped } as never
}

export namespace cancelAllSync {
  /** The action's arguments. */
  export type Args = cancelAll.Args

  /** The arguments, an optional Multicall3 address, the transaction fields and the receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = cancelAll.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** `post`'s Sync result, keyed on `status` (`SyncReturnValue`), with the live pairs no cancel went to beside it in both
   * variants: they are known before the post is sent. */
  export type ReturnValue = PostSyncReturnValue extends infer result
    ? result extends unknown
      ? Prettify<
          result & {
            /** The live pairs no cancel went to (`cancelAll.requests`' `skipped`), in pair order. */
            skipped: cancelAll.SkippedPair[]
          }
        >
      : never
    : never

  /** `cancelAll`'s errors, and viem's receipt errors. */
  export type ErrorType = cancelAll.ErrorType | WriteContractSyncErrorType
}

/** One pair as `cancelAll` reads it: its stored word and its mid band. */
type PairRead = { pairIndex: number; word: Hex; minMid: bigint; maxMid: bigint }

/** Every pair's stored word and mid band, at one block: the pair count, then each pair's two views. */
async function readPairs(
  client: AnyClient,
  parameters: cancelAll.requests.Parameters,
): Promise<PairRead[]> {
  const venue = target(parameters)
  // Checks the state's shape (`Sequencer.last` refuses anything `from` or `seed` didn't make).
  if (parameters.sequencer !== undefined)
    Sequencer.last(parameters.sequencer, 0)
  // Multicall3 is the caller of every view: the read's own `account` is irrelevant.
  const { account: _account, ...options } = readOptions(parameters)
  assertPinnable(options)
  const block = await getBlock(
    client,
    options.blockNumber !== undefined
      ? { blockNumber: options.blockNumber }
      : { blockTag: options.blockTag ?? 'latest' },
  )
  if (block.number === null || block.hash === null)
    throw new UnexpectedResponseError(
      'the node answered the cancellation block without a number or hash',
      { value: { number: block.number, hash: block.hash } },
    )
  const { blockNumber: _number, blockTag: _tag, ...overrides } = options
  // A height can change between pairCount and its dependent reads (or between
  // multicall chunks). EIP-1898 binds every call to the same canonical state;
  // an unsupported selector or an orphaned block must fail, never fall back.
  const at = {
    ...overrides,
    blockHash: block.hash,
    requireCanonical: true,
    ...multicallOptions(parameters),
  }
  const [count] = await readMany(
    client,
    [VenueReads.read(venue, 'pairCount')],
    at,
  )
  const pairs = Array.from(
    {
      length: VenueReads.pairCount(
        VenueReads.view(count, VenueReads.read(venue, 'pairCount')),
      ),
    },
    (_, i) => i,
  )
  const results = await readMany(
    client,
    pairs.flatMap((pairIndex) => [
      VenueReads.read(venue, 'hotWord', [pairIndex]),
      VenueReads.read(venue, 'midBand', [pairIndex]),
    ]),
    at,
  )
  return pairs.map((pairIndex) => {
    const [minMid, maxMid] = VenueReads.view(
      results[2 * pairIndex + 1],
      VenueReads.read(venue, 'midBand', [pairIndex]),
      `midBand(${pairIndex})`,
    )
    if (
      minMid < 0n ||
      minMid > maxUint96 ||
      maxMid < 0n ||
      maxMid > maxUint96 ||
      (maxMid === 0n ? minMid !== 0n : minMid === 0n || minMid > maxMid)
    )
      throw new UnexpectedResponseError(
        `midBand(${pairIndex}) answered an invalid band`,
        { value: { pairIndex, minMid, maxMid } },
      )
    return {
      pairIndex,
      word: VenueReads.view(
        results[2 * pairIndex],
        VenueReads.read(venue, 'hotWord', [pairIndex]),
        `hotWord(${pairIndex})`,
      ),
      minMid,
      maxMid,
    }
  })
}

/**
 * Plans every cancel before recording them in `sequencer` (including previously untracked pairs).
 * Planning and reservation run synchronously after discovery, so no allocation can interleave between them.
 */
function plan(
  pairs: readonly PairRead[],
  sequencer: Sequencer.Sequencer | undefined,
): cancelAll.Requests {
  const cancels: Post.CancelRequest[] = []
  const skipped: cancelAll.SkippedPair[] = []
  for (const { pairIndex, word, minMid, maxMid } of pairs) {
    // Zero is a removed pair: it isn't live, so there is nothing to cancel or report.
    if (BigInt(word) === 0n) continue
    const stored = HotWord.decode(word)
    // No post can replace a word at the last sequence.
    if (stored.sequence >= maxSequence) {
      skipped.push({ pairIndex, reason: 'sequenceExhausted' })
      continue
    }
    const last =
      sequencer === undefined ? undefined : Sequencer.last(sequencer, pairIndex)
    // A zero mid is the word `addPair` stored, which no taker can fill: nothing to cancel, unless the sequencer has
    // handed out a later sequence for the pair, whose post may still be unmined.
    if (stored.mid === 0n && (last === undefined || last <= stored.sequence)) {
      skipped.push({ pairIndex, reason: 'neverPosted' })
      continue
    }
    const floor =
      last === undefined || last < stored.sequence ? stored.sequence : last
    // A sequencer counter at the last sequence (the stored word below it) falls back to the stored sequence plus one.
    const sequence = floor >= maxSequence ? stored.sequence + 1 : floor + 1
    // An agent's entries must sit inside the pair's band (`maxMid` 0 for none, else `0 < minMid <= maxMid`).
    const mid =
      stored.mid === 0n
        ? maxMid === 0n
          ? Price.one
          : minMid
        : maxMid === 0n
          ? stored.mid
          : stored.mid < minMid
            ? minMid
            : stored.mid > maxMid
              ? maxMid
              : stored.mid
    cancels.push({ pairIndex, sequence, mid })
  }
  // Validate every cancel with the send path's encoder before reserving any sequence.
  if (cancels.length !== 0) Post.bulkCancel(cancels)
  // Finish planning the entire batch before mutating the shared allocator; observe never lowers an exhausted floor.
  if (sequencer !== undefined)
    for (const { pairIndex, sequence } of cancels)
      Sequencer.observe(sequencer, pairIndex, sequence)
  return { cancels, skipped }
}

/** The `post` call of `requests`' cancels, or `EmptyBatchError`, naming the skipped pairs, when there are none. */
function cancelCall(
  venue: Address,
  requests: cancelAll.Requests,
): VenueCall<'post'> {
  if (requests.cancels.length === 0)
    throw new EmptyBatchError('no live pair has a quote cancelAll can cancel', {
      metaMessages: requests.skipped.map(
        ({ pairIndex, reason }) => `pair ${pairIndex}: ${reason}`,
      ),
    })
  return cancelAll.call({ venue, cancels: requests.cancels })
}
