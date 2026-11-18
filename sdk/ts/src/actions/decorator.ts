// `propAmmActions()`: every action bound to a client, for `client.extend(...)`, as viem/tempo's `tempoActions()` binds
// its own. `client.venue.setHalted(parameters)` is `Actions.venue.setHalted(client, parameters)`; `cancelAll.requests`
// takes the client from it too, and `call`, `extractEvent` and `extractEvents` need none.
import type { Account, Chain, Client, Transport } from 'viem'
import * as factoryActions from './factory.js'
import * as makerActions from './maker.js'
import * as venueActions from './venue.js'

/** What `fn` returns. */
type Result<fn> = fn extends (...args: never) => infer result ? result : never

/**
 * An action bound to the client: `(parameters)`, typed for the client's chain and account, with its helpers. `call`,
 * `extractEvent` and `extractEvents` need no client and are the action's own; `cancelAll.requests` takes its read's
 * parameters.
 */
type Bound<action, parameters> = ((parameters: parameters) => Result<action>) &
  (action extends { call: infer call } ? { call: call } : unknown) &
  (action extends {
    requests: (client: never, parameters: infer read) => infer result
  }
    ? { requests: (parameters: read) => result }
    : unknown) &
  (action extends { extractEvent: infer extract }
    ? { extractEvent: extract }
    : unknown) &
  (action extends { extractEvents: infer extract }
    ? { extractEvents: extract }
    : unknown)

/** The actions `propAmmActions()` adds to a client, grouped by the contract they call. */
export type Decorator<
  chain extends Chain | undefined = Chain | undefined,
  account extends Account | undefined = Account | undefined,
> = {
  factory: {
    /**
     * Creates `owner`'s venue at the factory's CREATE2 address for `salt` (`Info.predictVenue`), initialized with the
     * factory's default settler (anyone). Anyone may create it first; it is still `owner`'s.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http, keccak256, toHex } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.factory.createVenue({
     *   factory: '0x...',
     *   owner: '0x...',
     *   salt: keccak256(toHex('my venue')),
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    createVenue: Bound<
      typeof factoryActions.createVenue,
      factoryActions.createVenue.Parameters<chain, account>
    >
    /**
     * Creates `owner`'s venue at the factory's CREATE2 address for `salt` (`Info.predictVenue`), initialized with the
     * factory's default settler (anyone). Anyone may create it first; it is still `owner`'s.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http, keccak256, toHex } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.factory.createVenueSync({
     *   factory: '0x...',
     *   owner: '0x...',
     *   salt: keccak256(toHex('my venue')),
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.venue)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `VenueCreated` event's arguments and the receipt.
     */
    createVenueSync: Bound<
      typeof factoryActions.createVenueSync,
      factoryActions.createVenueSync.Parameters<chain, account>
    >
  }
  maker: {
    /**
     * Atomically replaces the hot words of distinct pairs with whole-ladder orders (owner or agent). Their shapes must
     * already be set. A stale entry is skipped without an event, so a successful receipt alone doesn't mean every quote
     * is live: read the outcome.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
     *
     * const hash = await client.maker.bulkOrders({
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
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    bulkOrders: Bound<
      typeof makerActions.bulkOrders,
      makerActions.bulkOrders.Parameters<chain, account>
    >
    /**
     * Atomically replaces the hot words of distinct pairs with whole-ladder orders (owner or agent). Their shapes must
     * already be set. A stale entry is skipped without an event, so a successful receipt alone doesn't mean every quote
     * is live: read the outcome.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
     *
     * const result = await client.maker.bulkOrdersSync({
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
     * @param parameters - Parameters.
     * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
     */
    bulkOrdersSync: Bound<
      typeof makerActions.bulkOrdersSync,
      makerActions.bulkOrdersSync.Parameters<chain, account>
    >
    /**
     * Replaces one pair's hot word with a whole-ladder order (owner or agent): a `bulkOrders` of one.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
     *
     * const hash = await client.maker.order({
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
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    order: Bound<
      typeof makerActions.order,
      makerActions.order.Parameters<chain, account>
    >
    /**
     * Replaces one pair's hot word with a whole-ladder order (owner or agent): a `bulkOrders` of one.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
     *
     * const result = await client.maker.orderSync({
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
     * @param parameters - Parameters.
     * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
     */
    orderSync: Bound<
      typeof makerActions.orderSync,
      makerActions.orderSync.Parameters<chain, account>
    >
    /**
     * Cancels both sides of distinct pairs with newer disabled words (owner or agent). A newer in-flight post
     * supersedes a cancel: `cancelAll` reads every pair for you, and `Actions.venue.closePair` is a stop no later post
     * undoes.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
     *
     * const hash = await client.maker.bulkCancel({
     *   venue: '0x...',
     *   cancels: [
     *     { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.085') },
     *     { pairIndex: 1, sequence: Sequencer.next(sequencer, 1), mid: Price.parse('0.92') },
     *   ],
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    bulkCancel: Bound<
      typeof makerActions.bulkCancel,
      makerActions.bulkCancel.Parameters<chain, account>
    >
    /**
     * Cancels both sides of distinct pairs with newer disabled words (owner or agent). A newer in-flight post
     * supersedes a cancel: `cancelAll` reads every pair for you, and `Actions.venue.closePair` is a stop no later post
     * undoes.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
     *
     * const result = await client.maker.bulkCancelSync({
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
     * @param parameters - Parameters.
     * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
     */
    bulkCancelSync: Bound<
      typeof makerActions.bulkCancelSync,
      makerActions.bulkCancelSync.Parameters<chain, account>
    >
    /**
     * Cancels both sides of one pair with a newer disabled word (owner or agent): a `bulkCancel` of one.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
     *
     * const hash = await client.maker.cancel({
     *   venue: '0x...',
     *   cancel: { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.085') },
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    cancel: Bound<
      typeof makerActions.cancel,
      makerActions.cancel.Parameters<chain, account>
    >
    /**
     * Cancels both sides of one pair with a newer disabled word (owner or agent): a `bulkCancel` of one.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0] })
     *
     * const result = await client.maker.cancelSync({
     *   venue: '0x...',
     *   cancel: { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.085') },
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.outcome)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
     */
    cancelSync: Bound<
      typeof makerActions.cancelSync,
      makerActions.cancelSync.Parameters<chain, account>
    >
    /**
     * Cancels every live pair's quotes in one atomic `post`, without halting the venue (owner or agent). It reads the
     * venue's pairs at one block (`cancelAll.requests`) and posts each a cancel: a newer word with no sides, at its
     * stored mid (moved inside the pair's mid band, so an agent's cancel passes it) and its next sequence, above both
     * the stored one and, for a pair `sequencer` tracks, its counter. Before it sends, it records each cancel in
     * `sequencer` (a pair it didn't track joins it at the cancel's sequence), so the pair's next post outranks the
     * cancel. A newer post already in flight supersedes a cancel: pass the `sequencer` your posts draw from, and read
     * the outcome (`cancelAllSync`).
     *
     * Some live pairs get no cancel (`requests`' `skipped`, which `cancelAllSync` returns): one never posted to has no
     * quote, and one whose stored word is at `uint32` max can't be replaced by any post, so only `closePair` or
     * `setHalted` stops it. When no pair gets a cancel it sends nothing and throws `EmptyBatchError`, naming the
     * skipped pairs. To stop every fill outright, `Actions.venue.setHalted`; to stop one pair for good,
     * `Actions.venue.closePair`.
     *
     * @example
     * ```ts
     * import { propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
     *
     * const hash = await client.maker.cancelAll({
     *   venue: '0x...',
     *   sequencer,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    cancelAll: Bound<
      typeof makerActions.cancelAll,
      makerActions.cancelAll.Parameters<chain, account>
    >
    /**
     * Cancels every live pair's quotes in one atomic `post`, without halting the venue (owner or agent), and waits for
     * the receipt: `cancelAll`, which records each cancel in `sequencer` before it sends. `skipped` lists the live
     * pairs it sent no cancel (`cancelAll.requests`' reasons): those still quote if they did. `outcome` reads the
     * cancels it sent: one it reports skipped was superseded by a newer post, so that pair still quotes too. So
     * `outcome.allAccepted` alone doesn't mean every pair is cancelled: check `skipped` as well.
     *
     * @example
     * ```ts
     * import { propAmmActions, Sequencer } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const sequencer = await Sequencer.seed(client, { venue: '0x...', pairs: [0, 1] })
     *
     * const result = await client.maker.cancelAllSync({
     *   venue: '0x...',
     *   sequencer,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.outcome)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `Posted` events' arguments, which cancels the venue stored or skipped as superseded, the live pairs
     * no cancel went to, and the receipt.
     */
    cancelAllSync: Bound<
      typeof makerActions.cancelAllSync,
      makerActions.cancelAllSync.Parameters<chain, account>
    >
  }
  venue: {
    /**
     * Adds a pair, `Closed`, with `sizeUnit` base units per shape size step (owner). Both tokens must be distinct,
     * initialized Tempo TIP-20s recognized by the canonical TIP-20 factory; code alone is not enough
     * (`InvalidPairTokens`). Their decimals must match (`DecimalsMismatch`). These checks run onchain.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.addPair({
     *   venue: '0x...',
     *   base: '0x20C0000000000000000000000000000000000001',
     *   quote: '0x20c0000000000000000000000000000000000002',
     *   sizeUnit: 1_000_000n,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    addPair: Bound<
      typeof venueActions.addPair,
      venueActions.addPair.Parameters<chain, account>
    >
    /**
     * Adds a pair, `Closed`, with `sizeUnit` base units per shape size step (owner). Both tokens must be distinct,
     * initialized Tempo TIP-20s recognized by the canonical TIP-20 factory; code alone is not enough
     * (`InvalidPairTokens`). Their decimals must match (`DecimalsMismatch`). These checks run onchain.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.addPairSync({
     *   venue: '0x...',
     *   base: '0x20C0000000000000000000000000000000000001',
     *   quote: '0x20c0000000000000000000000000000000000002',
     *   sizeUnit: 1_000_000n,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.pairIndex)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `PairAdded` event's arguments and the receipt.
     */
    addPairSync: Bound<
      typeof venueActions.addPairSync,
      venueActions.addPairSync.Parameters<chain, account>
    >
    /**
     * Removes a pair for good; its index is never reused (owner). Delete its shapes first to earn their storage
     * credits.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.removePair({
     *   venue: '0x...',
     *   pairIndex: 0,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    removePair: Bound<
      typeof venueActions.removePair,
      venueActions.removePair.Parameters<chain, account>
    >
    /**
     * Removes a pair for good; its index is never reused (owner). Delete its shapes first to earn their storage
     * credits.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.removePairSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.pairIndex)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `PairRemoved` event's arguments and the receipt.
     */
    removePairSync: Bound<
      typeof venueActions.removePairSync,
      venueActions.removePairSync.Parameters<chain, account>
    >
    /**
     * Sets who may trade a pair (owner). Entering `open` requires a halted venue. Reopening re-arms the stored hot
     * word: post a fresh one first.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setPairAccess({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   mode: 'listed',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setPairAccess: Bound<
      typeof venueActions.setPairAccess,
      venueActions.setPairAccess.Parameters<chain, account>
    >
    /**
     * Sets who may trade a pair (owner). Entering `open` requires a halted venue. Reopening re-arms the stored hot
     * word: post a fresh one first.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setPairAccessSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   mode: 'listed',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.newMode)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `PairAccessUpdated` event's arguments and the receipt.
     */
    setPairAccessSync: Bound<
      typeof venueActions.setPairAccessSync,
      venueActions.setPairAccessSync.Parameters<chain, account>
    >
    /**
     * Closes a pair to every taker (owner or agent). Only the owner reopens it.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.closePair({
     *   venue: '0x...',
     *   pairIndex: 0,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    closePair: Bound<
      typeof venueActions.closePair,
      venueActions.closePair.Parameters<chain, account>
    >
    /**
     * Closes a pair to every taker (owner or agent). Only the owner reopens it.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.closePairSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.oldMode)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `PairAccessUpdated` event's arguments and the receipt.
     */
    closePairSync: Bound<
      typeof venueActions.closePairSync,
      venueActions.closePairSync.Parameters<chain, account>
    >
    /**
     * Resets a halted pair to its initial, unfillable hot word (owner), preserving consumed depth and configuration.
     * Follow the README's reset recovery protocol: fence old writers, durable writes and executable posts first (halt
     * does not block posts). Confirm the reset separately, then atomically transition this pair's durable application
     * generation and floor, rejecting old-generation writes. Recreate the sequencer from current-generation reset
     * state, post a fresh quote and only then resume. `Sequencer.observe` never lowers an existing counter; neither SDK
     * nor contract provides a reset epoch. Retrying the durable transition must not erase later allocations.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.resetHotWord({
     *   venue: '0x...',
     *   pairIndex: 0,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    resetHotWord: Bound<
      typeof venueActions.resetHotWord,
      venueActions.resetHotWord.Parameters<chain, account>
    >
    /**
     * Resets a halted pair to its initial, unfillable hot word (owner), preserving consumed depth and configuration.
     * Follow the README's reset recovery protocol: fence old writers, durable writes and executable posts first (halt
     * does not block posts). Confirm the reset separately, then atomically transition this pair's durable application
     * generation and floor, rejecting old-generation writes. Recreate the sequencer from current-generation reset
     * state, post a fresh quote and only then resume. `Sequencer.observe` never lowers an existing counter; neither SDK
     * nor contract provides a reset epoch. Retrying the durable transition must not erase later allocations.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.resetHotWordSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.previousSeq)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `HotWordReset` event's arguments and the receipt.
     */
    resetHotWordSync: Bound<
      typeof venueActions.resetHotWordSync,
      venueActions.resetHotWordSync.Parameters<chain, account>
    >
    /**
     * Registers a sponsor under a nonzero id the owner chooses, with `admin` as the only key that lists its users
     * (owner). It starts enabled and admitted on no pair.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.addSponsor({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   admin: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    addSponsor: Bound<
      typeof venueActions.addSponsor,
      venueActions.addSponsor.Parameters<chain, account>
    >
    /**
     * Registers a sponsor under a nonzero id the owner chooses, with `admin` as the only key that lists its users
     * (owner). It starts enabled and admitted on no pair.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.addSponsorSync({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   admin: '0x...',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.admin)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `SponsorAdded` event's arguments and the receipt.
     */
    addSponsorSync: Bound<
      typeof venueActions.addSponsorSync,
      venueActions.addSponsorSync.Parameters<chain, account>
    >
    /**
     * Switches a sponsor on (owner) or off (owner or agent) venue-wide. Its lists and admissions are kept.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setSponsorEnabled({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   enabled: false,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setSponsorEnabled: Bound<
      typeof venueActions.setSponsorEnabled,
      venueActions.setSponsorEnabled.Parameters<chain, account>
    >
    /**
     * Switches a sponsor on (owner) or off (owner or agent) venue-wide. Its lists and admissions are kept.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setSponsorEnabledSync({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   enabled: false,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.enabled)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `SponsorEnabledSet` event's arguments and the receipt.
     */
    setSponsorEnabledSync: Bound<
      typeof venueActions.setSponsorEnabledSync,
      venueActions.setSponsorEnabledSync.Parameters<chain, account>
    >
    /**
     * Admits a sponsor on a pair (owner) or removes it (owner or agent). Removal keeps its list there.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setPairSponsor({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   sponsorId: 42n,
     *   admitted: true,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setPairSponsor: Bound<
      typeof venueActions.setPairSponsor,
      venueActions.setPairSponsor.Parameters<chain, account>
    >
    /**
     * Admits a sponsor on a pair (owner) or removes it (owner or agent). Removal keeps its list there.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setPairSponsorSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   sponsorId: 42n,
     *   admitted: true,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.admitted)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `PairSponsorSet` event's arguments and the receipt.
     */
    setPairSponsorSync: Bound<
      typeof venueActions.setPairSponsorSync,
      venueActions.setPairSponsorSync.Parameters<chain, account>
    >
    /**
     * Lists (`allowed`) or delists accounts on a pair under a sponsor id: the owner edits the home list (0), a
     * sponsor's admin alone edits its own. One atomic batch of 1 to `Venue.maxBatch` accounts, never split.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setMembers({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   sponsorId: 42n,
     *   accounts: ['0x...'],
     *   allowed: true,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setMembers: Bound<
      typeof venueActions.setMembers,
      venueActions.setMembers.Parameters<chain, account>
    >
    /**
     * Lists (`allowed`) or delists accounts on a pair under a sponsor id: the owner edits the home list (0), a
     * sponsor's admin alone edits its own. One atomic batch of 1 to `Venue.maxBatch` accounts, never split.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setMembersSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   sponsorId: 42n,
     *   accounts: ['0x...'],
     *   allowed: true,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.updates)
     * ```
     *
     * @param parameters - Parameters.
     * @returns Each `MemberUpdated` event's arguments, in order, and the receipt.
     */
    setMembersSync: Bound<
      typeof venueActions.setMembersSync,
      venueActions.setMembersSync.Parameters<chain, account>
    >
    /**
     * Starts handing a sponsor's lists to `newAdmin`, who must accept (sponsor admin).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.transferSponsorAdmin({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   newAdmin: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    transferSponsorAdmin: Bound<
      typeof venueActions.transferSponsorAdmin,
      venueActions.transferSponsorAdmin.Parameters<chain, account>
    >
    /**
     * Starts handing a sponsor's lists to `newAdmin`, who must accept (sponsor admin).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.transferSponsorAdminSync({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   newAdmin: '0x...',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.pendingAdmin)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `SponsorAdminTransferStarted` event's arguments and the receipt.
     */
    transferSponsorAdminSync: Bound<
      typeof venueActions.transferSponsorAdminSync,
      venueActions.transferSponsorAdminSync.Parameters<chain, account>
    >
    /**
     * Cancels a pending sponsor-admin transfer without changing the sponsor's current admin (sponsor admin). Safe to
     * repeat.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.cancelSponsorAdminTransfer({
     *   venue: '0x...',
     *   sponsorId: 42n,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    cancelSponsorAdminTransfer: Bound<
      typeof venueActions.cancelSponsorAdminTransfer,
      venueActions.cancelSponsorAdminTransfer.Parameters<chain, account>
    >
    /**
     * Cancels a pending sponsor-admin transfer without changing the sponsor's current admin (sponsor admin). Safe to
     * repeat.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.cancelSponsorAdminTransferSync({
     *   venue: '0x...',
     *   sponsorId: 42n,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.pendingAdmin)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `SponsorAdminTransferStarted` event's arguments and the receipt.
     */
    cancelSponsorAdminTransferSync: Bound<
      typeof venueActions.cancelSponsorAdminTransferSync,
      venueActions.cancelSponsorAdminTransferSync.Parameters<chain, account>
    >
    /**
     * Takes over a sponsor's lists (pending sponsor admin).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.acceptSponsorAdmin({
     *   venue: '0x...',
     *   sponsorId: 42n,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    acceptSponsorAdmin: Bound<
      typeof venueActions.acceptSponsorAdmin,
      venueActions.acceptSponsorAdmin.Parameters<chain, account>
    >
    /**
     * Takes over a sponsor's lists (pending sponsor admin).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.acceptSponsorAdminSync({
     *   venue: '0x...',
     *   sponsorId: 42n,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.newAdmin)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `SponsorAdminTransferred` event's arguments and the receipt.
     */
    acceptSponsorAdminSync: Bound<
      typeof venueActions.acceptSponsorAdminSync,
      venueActions.acceptSponsorAdminSync.Parameters<chain, account>
    >
    /**
     * Gives a sponsor a new admin and voids every earlier listing under its id, at once and for good (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.resetSponsor({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   newAdmin: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    resetSponsor: Bound<
      typeof venueActions.resetSponsor,
      venueActions.resetSponsor.Parameters<chain, account>
    >
    /**
     * Gives a sponsor a new admin and voids every earlier listing under its id, at once and for good (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.resetSponsorSync({
     *   venue: '0x...',
     *   sponsorId: 42n,
     *   newAdmin: '0x...',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.generation)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `SponsorReset` event's arguments and the receipt.
     */
    resetSponsorSync: Bound<
      typeof venueActions.resetSponsorSync,
      venueActions.resetSponsorSync.Parameters<chain, account>
    >
    /**
     * Denies accounts (owner or agent) or lifts their denial (owner). A denial overrides every list and `open`. One
     * atomic batch of 1 to `Venue.maxBatch` accounts, never split.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setDenied({
     *   venue: '0x...',
     *   accounts: ['0x...'],
     *   deny: true,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setDenied: Bound<
      typeof venueActions.setDenied,
      venueActions.setDenied.Parameters<chain, account>
    >
    /**
     * Denies accounts (owner or agent) or lifts their denial (owner). A denial overrides every list and `open`. One
     * atomic batch of 1 to `Venue.maxBatch` accounts, never split.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setDeniedSync({
     *   venue: '0x...',
     *   accounts: ['0x...'],
     *   deny: true,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.updates)
     * ```
     *
     * @param parameters - Parameters.
     * @returns Each changed denial's `DenyUpdated` arguments, in order (possibly empty), and the receipt.
     */
    setDeniedSync: Bound<
      typeof venueActions.setDeniedSync,
      venueActions.setDeniedSync.Parameters<chain, account>
    >
    /**
     * Installs, replaces or removes (`hook` zero, `flags` 0) a pair's hook (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions, VenueHookFlags } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setPairHook({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   hook: '0x...',
     *   flags: VenueHookFlags.beforeFill,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setPairHook: Bound<
      typeof venueActions.setPairHook,
      venueActions.setPairHook.Parameters<chain, account>
    >
    /**
     * Installs, replaces or removes (`hook` zero, `flags` 0) a pair's hook (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions, VenueHookFlags } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setPairHookSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   hook: '0x...',
     *   flags: VenueHookFlags.beforeFill,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.hook, result.flags)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `PairHookSet` event's arguments and the receipt.
     */
    setPairHookSync: Bound<
      typeof venueActions.setPairHookSync,
      venueActions.setPairHookSync.Parameters<chain, account>
    >
    /**
     * Makes `agent` an updater, the contract's `setUpdater(agent, true)` (owner): it may post, set shapes and the taker
     * fee cap and use the narrowing switches. Unlike a Hyperliquid API wallet it holds onchain powers, but never
     * custody.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.approveAgent({
     *   venue: '0x...',
     *   agent: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    approveAgent: Bound<
      typeof venueActions.approveAgent,
      venueActions.approveAgent.Parameters<chain, account>
    >
    /**
     * Makes `agent` an updater, the contract's `setUpdater(agent, true)` (owner): it may post, set shapes and the taker
     * fee cap and use the narrowing switches. Unlike a Hyperliquid API wallet it holds onchain powers, but never
     * custody.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.approveAgentSync({
     *   venue: '0x...',
     *   agent: '0x...',
     * })
     * // `changed` is false when the agent was already approved.
     * if (result.status === 'success' && result.changed) console.log(result.updater)
     * ```
     *
     * @param parameters - Parameters.
     * @returns Whether the updater permission changed, its `UpdaterSet` arguments when it did, and the receipt.
     */
    approveAgentSync: Bound<
      typeof venueActions.approveAgentSync,
      venueActions.approveAgentSync.Parameters<chain, account>
    >
    /**
     * Revokes an agent's updater powers, the contract's `setUpdater(agent, false)` (owner). Its quotes stay live.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.revokeAgent({
     *   venue: '0x...',
     *   agent: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    revokeAgent: Bound<
      typeof venueActions.revokeAgent,
      venueActions.revokeAgent.Parameters<chain, account>
    >
    /**
     * Revokes an agent's updater powers, the contract's `setUpdater(agent, false)` (owner). Its quotes stay live.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.revokeAgentSync({
     *   venue: '0x...',
     *   agent: '0x...',
     * })
     * // `changed` is false when the agent was already revoked.
     * if (result.status === 'success' && result.changed) console.log(result.updater)
     * ```
     *
     * @param parameters - Parameters.
     * @returns Whether the updater permission changed, its `UpdaterSet` arguments when it did, and the receipt.
     */
    revokeAgentSync: Bound<
      typeof venueActions.revokeAgentSync,
      venueActions.revokeAgentSync.Parameters<chain, account>
    >
    /**
     * Repoints the venue at another settler (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setSettler({
     *   venue: '0x...',
     *   settler: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setSettler: Bound<
      typeof venueActions.setSettler,
      venueActions.setSettler.Parameters<chain, account>
    >
    /**
     * Repoints the venue at another settler (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setSettlerSync({
     *   venue: '0x...',
     *   settler: '0x...',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.settler)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `SettlerSet` event's arguments and the receipt.
     */
    setSettlerSync: Bound<
      typeof venueActions.setSettlerSync,
      venueActions.setSettlerSync.Parameters<chain, account>
    >
    /**
     * Halts every fill on the venue (owner or agent) or resumes them (owner). Resuming re-arms every unexpired word:
     * refresh them first. To pull quotes without halting, use `Actions.maker.cancelAll`.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setHalted({
     *   venue: '0x...',
     *   halted: true,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setHalted: Bound<
      typeof venueActions.setHalted,
      venueActions.setHalted.Parameters<chain, account>
    >
    /**
     * Halts every fill on the venue (owner or agent) or resumes them (owner). Resuming re-arms every unexpired word:
     * refresh them first. To pull quotes without halting, use `Actions.maker.cancelAll`.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setHaltedSync({
     *   venue: '0x...',
     *   halted: true,
     * })
     * // `changed` is false when the venue was already in the requested state.
     * if (result.status === 'success' && result.changed) console.log(result.halted)
     * ```
     *
     * @param parameters - Parameters.
     * @returns Whether the halt state changed, its `HaltedSet` arguments when it did, and the receipt.
     */
    setHaltedSync: Bound<
      typeof venueActions.setHaltedSync,
      venueActions.setHaltedSync.Parameters<chain, account>
    >
    /**
     * Moves inventory to `to`, with exact debit and credit checks onchain (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.withdraw({
     *   venue: '0x...',
     *   token: '0x20C0000000000000000000000000000000000001',
     *   to: '0x...',
     *   amount: 1_000_000n,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    withdraw: Bound<
      typeof venueActions.withdraw,
      venueActions.withdraw.Parameters<chain, account>
    >
    /**
     * Moves inventory to `to`, with exact debit and credit checks onchain (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.withdrawSync({
     *   venue: '0x...',
     *   token: '0x20C0000000000000000000000000000000000001',
     *   to: '0x...',
     *   amount: 1_000_000n,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.amount)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `Withdrawn` event's arguments and the receipt.
     */
    withdrawSync: Bound<
      typeof venueActions.withdrawSync,
      venueActions.withdrawSync.Parameters<chain, account>
    >
    /**
     * Proposes a new owner, who must accept (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.transferOwnership({
     *   venue: '0x...',
     *   newOwner: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    transferOwnership: Bound<
      typeof venueActions.transferOwnership,
      venueActions.transferOwnership.Parameters<chain, account>
    >
    /**
     * Proposes a new owner, who must accept (owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.transferOwnershipSync({
     *   venue: '0x...',
     *   newOwner: '0x...',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.pendingOwner)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `OwnershipTransferStarted` event's arguments and the receipt.
     */
    transferOwnershipSync: Bound<
      typeof venueActions.transferOwnershipSync,
      venueActions.transferOwnershipSync.Parameters<chain, account>
    >
    /**
     * Cancels a pending ownership transfer without changing the current owner (owner). Safe to repeat.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.cancelOwnershipTransfer({ venue: '0x...' })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    cancelOwnershipTransfer: Bound<
      typeof venueActions.cancelOwnershipTransfer,
      venueActions.cancelOwnershipTransfer.Parameters<chain, account>
    >
    /**
     * Cancels a pending ownership transfer without changing the current owner (owner). Safe to repeat.
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.cancelOwnershipTransferSync({ venue: '0x...' })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.pendingOwner)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `OwnershipTransferStarted` event's arguments and the receipt.
     */
    cancelOwnershipTransferSync: Bound<
      typeof venueActions.cancelOwnershipTransferSync,
      venueActions.cancelOwnershipTransferSync.Parameters<chain, account>
    >
    /**
     * Takes custody and administration of the venue (pending owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.acceptOwnership({
     *   venue: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    acceptOwnership: Bound<
      typeof venueActions.acceptOwnership,
      venueActions.acceptOwnership.Parameters<chain, account>
    >
    /**
     * Takes custody and administration of the venue (pending owner).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.acceptOwnershipSync({
     *   venue: '0x...',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.newOwner)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `OwnershipTransferred` event's arguments and the receipt.
     */
    acceptOwnershipSync: Bound<
      typeof venueActions.acceptOwnershipSync,
      venueActions.acceptOwnershipSync.Parameters<chain, account>
    >
    /**
     * Replaces the hot words of distinct pairs from raw entries (owner or agent; `Actions.maker` builds orders and
     * cancels). The batch is atomic, but a stale entry is skipped without an event, so a successful receipt alone does
     * not mean every word is live: read the outcome.
     *
     * @example
     * ```ts
     * import { Post, Price, propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.post({
     *   venue: '0x...',
     *   entries: [
     *     Post.order({
     *       pairIndex: 0,
     *       mid: Price.parse('1.085'),
     *       shapeId: 7,
     *       sequence: 2,
     *       validUntil: 1_800_000_000,
     *     }),
     *   ],
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    post: Bound<
      typeof venueActions.post,
      venueActions.post.Parameters<chain, account>
    >
    /**
     * Replaces the hot words of distinct pairs from raw entries (owner or agent; `Actions.maker` builds orders and
     * cancels). The batch is atomic, but a stale entry is skipped without an event, so a successful receipt alone does
     * not mean every word is live: read the outcome.
     *
     * @example
     * ```ts
     * import { Post, Price, propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.postSync({
     *   venue: '0x...',
     *   entries: [
     *     Post.order({
     *       pairIndex: 0,
     *       mid: Price.parse('1.085'),
     *       shapeId: 7,
     *       sequence: 2,
     *       validUntil: 1_800_000_000,
     *     }),
     *   ],
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.outcome)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
     */
    postSync: Bound<
      typeof venueActions.postSync,
      venueActions.postSync.Parameters<chain, account>
    >
    /**
     * Defines, redefines or deletes (`Shape.empty`) one of a pair's 256 shapes (owner or agent). Editing the active
     * shape reprices at once: define a new id, confirm it, then switch to it in the next order.
     *
     * @example
     * ```ts
     * import { propAmmActions, Shape } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setShape({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   shapeId: 7,
     *   shape: Shape.from({
     *     bids: [{ size: 50_000, spread: 20 }],
     *     asks: [{ size: 50_000, spread: 20 }],
     *   }),
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setShape: Bound<
      typeof venueActions.setShape,
      venueActions.setShape.Parameters<chain, account>
    >
    /**
     * Defines, redefines or deletes (`Shape.empty`) one of a pair's 256 shapes (owner or agent). Editing the active
     * shape reprices at once: define a new id, confirm it, then switch to it in the next order.
     *
     * @example
     * ```ts
     * import { propAmmActions, Shape } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setShapeSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   shapeId: 7,
     *   shape: Shape.from({
     *     bids: [{ size: 50_000, spread: 20 }],
     *     asks: [{ size: 50_000, spread: 20 }],
     *   }),
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.shapeId)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `ShapeSet` event's arguments and the receipt.
     */
    setShapeSync: Bound<
      typeof venueActions.setShapeSync,
      venueActions.setShapeSync.Parameters<chain, account>
    >
    /**
     * Caps the priority fee per gas of every transaction that fills (owner or agent); `Venue.noPriorityFeeCap` removes
     * the cap. Post above it (`Fees.makerTip`).
     *
     * @example
     * ```ts
     * import { Fees, propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setMaxTakerPriorityFee({
     *   venue: '0x...',
     *   cap: 5n * Fees.gwei,
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setMaxTakerPriorityFee: Bound<
      typeof venueActions.setMaxTakerPriorityFee,
      venueActions.setMaxTakerPriorityFee.Parameters<chain, account>
    >
    /**
     * Caps the priority fee per gas of every transaction that fills (owner or agent); `Venue.noPriorityFeeCap` removes
     * the cap. Post above it (`Fees.makerTip`).
     *
     * @example
     * ```ts
     * import { Fees, propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setMaxTakerPriorityFeeSync({
     *   venue: '0x...',
     *   cap: 5n * Fees.gwei,
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.cap)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `MaxTakerPriorityFeeSet` event's arguments and the receipt.
     */
    setMaxTakerPriorityFeeSync: Bound<
      typeof venueActions.setMaxTakerPriorityFeeSync,
      venueActions.setMaxTakerPriorityFeeSync.Parameters<chain, account>
    >
    /**
     * Sets the taker fee cap to `Venue.defaultTakerPriorityFeeCap`, 10 gwei per gas (owner or agent).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.enableTakerPriorityFeeCap({
     *   venue: '0x...',
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    enableTakerPriorityFeeCap: Bound<
      typeof venueActions.enableTakerPriorityFeeCap,
      venueActions.enableTakerPriorityFeeCap.Parameters<chain, account>
    >
    /**
     * Sets the taker fee cap to `Venue.defaultTakerPriorityFeeCap`, 10 gwei per gas (owner or agent).
     *
     * @example
     * ```ts
     * import { propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.enableTakerPriorityFeeCapSync({
     *   venue: '0x...',
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.cap)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `MaxTakerPriorityFeeSet` event's arguments and the receipt.
     */
    enableTakerPriorityFeeCapSync: Bound<
      typeof venueActions.enableTakerPriorityFeeCapSync,
      venueActions.enableTakerPriorityFeeCapSync.Parameters<chain, account>
    >
    /**
     * Bounds the mids an agent can post for a pair to `[minMid, maxMid]`, or clears the band with `(0, 0)` (owner). The
     * owner's own posts are never band-checked.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const hash = await client.venue.setMidBand({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   minMid: Price.parse('1.05'),
     *   maxMid: Price.parse('1.12'),
     * })
     * ```
     *
     * @param parameters - Parameters.
     * @returns The transaction hash.
     */
    setMidBand: Bound<
      typeof venueActions.setMidBand,
      venueActions.setMidBand.Parameters<chain, account>
    >
    /**
     * Bounds the mids an agent can post for a pair to `[minMid, maxMid]`, or clears the band with `(0, 0)` (owner). The
     * owner's own posts are never band-checked.
     *
     * @example
     * ```ts
     * import { Price, propAmmActions } from '@tempoxyz/propamm-sdk'
     * import { createClient, http } from 'viem'
     * import { privateKeyToAccount } from 'viem/accounts'
     * import { tempoModerato } from 'viem/chains'
     *
     * const client = createClient({
     *   account: privateKeyToAccount('0x...'),
     *   chain: tempoModerato,
     *   transport: http(),
     * }).extend(propAmmActions())
     *
     * const result = await client.venue.setMidBandSync({
     *   venue: '0x...',
     *   pairIndex: 0,
     *   minMid: Price.parse('1.05'),
     *   maxMid: Price.parse('1.12'),
     * })
     * // A pending or reverted receipt carries no event: check the status first.
     * if (result.status === 'success') console.log(result.minMid, result.maxMid)
     * ```
     *
     * @param parameters - Parameters.
     * @returns The `MidBandSet` event's arguments and the receipt.
     */
    setMidBandSync: Bound<
      typeof venueActions.setMidBandSync,
      venueActions.setMidBandSync.Parameters<chain, account>
    >
  }
}

/** Binds `names` of `actions` to `client`, each with its helpers. A helper is an action's own property (`call` too:
 * every function inherits one). */
function bind<actions extends Record<string, unknown>>(
  client: Client<Transport, Chain | undefined, Account | undefined>,
  actions: actions,
  names: readonly (keyof actions & string)[],
): Record<string, unknown> {
  const bound: Record<string, unknown> = {}
  for (const name of names) {
    const action = actions[name] as (
      client: unknown,
      parameters: unknown,
    ) => unknown
    const own = (key: string) =>
      Object.hasOwn(action, key)
        ? (
            action as unknown as Record<string, (...args: unknown[]) => unknown>
          )[key]
        : undefined
    const helpers: Record<string, unknown> = {}
    for (const key of ['requests']) {
      const helper = own(key)
      if (helper)
        helpers[key] = (parameters: unknown) => helper(client, parameters)
    }
    for (const key of ['call', 'extractEvent', 'extractEvents']) {
      const helper = own(key)
      if (helper) helpers[key] = helper
    }
    bound[name] = Object.assign(
      (parameters: unknown) => action(client, parameters),
      helpers,
    )
  }
  return bound
}

/**
 * Adds every propAMM action to a viem client, grouped as `Actions` groups them (`client.venue.*`, `client.maker.*`,
 * `client.factory.*`), each bound to the client, as viem/tempo's `tempoActions()` does.
 *
 * @example
 * ```ts
 * import { propAmmActions } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 * import { tempoActions } from 'viem/tempo'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *   .extend(tempoActions())
 *   .extend(propAmmActions())
 *
 * const { receipt } = await client.venue.setHaltedSync({ venue: '0x...', halted: true })
 * ```
 *
 * @returns A decorator for `client.extend`.
 */
export function decorator() {
  return <
    transport extends Transport,
    chain extends Chain | undefined,
    account extends Account | undefined,
  >(
    client: Client<transport, chain, account>,
  ): Decorator<chain, account> => {
    return {
      factory: bind(client, factoryActions, ['createVenue', 'createVenueSync']),
      maker: bind(client, makerActions, [
        'bulkCancel',
        'bulkCancelSync',
        'bulkOrders',
        'bulkOrdersSync',
        'cancel',
        'cancelAll',
        'cancelAllSync',
        'cancelSync',
        'order',
        'orderSync',
      ]),
      venue: bind(client, venueActions, [
        'acceptOwnership',
        'acceptOwnershipSync',
        'acceptSponsorAdmin',
        'acceptSponsorAdminSync',
        'addPair',
        'addPairSync',
        'addSponsor',
        'addSponsorSync',
        'approveAgent',
        'approveAgentSync',
        'cancelOwnershipTransfer',
        'cancelOwnershipTransferSync',
        'cancelSponsorAdminTransfer',
        'cancelSponsorAdminTransferSync',
        'closePair',
        'closePairSync',
        'enableTakerPriorityFeeCap',
        'enableTakerPriorityFeeCapSync',
        'post',
        'postSync',
        'removePair',
        'removePairSync',
        'resetHotWord',
        'resetHotWordSync',
        'resetSponsor',
        'resetSponsorSync',
        'revokeAgent',
        'revokeAgentSync',
        'setDenied',
        'setDeniedSync',
        'setHalted',
        'setHaltedSync',
        'setMaxTakerPriorityFee',
        'setMaxTakerPriorityFeeSync',
        'setMembers',
        'setMembersSync',
        'setMidBand',
        'setMidBandSync',
        'setPairAccess',
        'setPairAccessSync',
        'setPairHook',
        'setPairHookSync',
        'setPairSponsor',
        'setPairSponsorSync',
        'setSettler',
        'setSettlerSync',
        'setShape',
        'setShapeSync',
        'setSponsorEnabled',
        'setSponsorEnabledSync',
        'transferOwnership',
        'transferOwnershipSync',
        'transferSponsorAdmin',
        'transferSponsorAdminSync',
        'withdraw',
        'withdrawSync',
      ]),
    } as never
  }
}
