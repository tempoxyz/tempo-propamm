import {
  type Address,
  type GetBlockErrorType,
  type Hex,
  zeroAddress,
} from 'viem'
import { getBlock } from 'viem/actions'
import { Abis } from 'viem/tempo'
import type { venueAbi } from './generated/abis.js'
import { VenueHookFlags } from './generated/constants.js'
import type { AccessModeName, TakerAccessName } from './generated/enums.js'
import * as HotWord from './HotWord.js'
import type * as Info from './Info.js'
import {
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  SnapshotIncompleteError,
  type SnapshotIncompleteErrorType,
  SnapshotReorgedError,
  type SnapshotReorgedErrorType,
  UnexpectedResponseError,
  type UnexpectedResponseErrorType,
  UnknownVenueError,
  type UnknownVenueErrorType,
} from './internal/errors.js'
import {
  assertPinnable,
  type MulticallParameters,
  type Read,
  type ReadManyErrorType,
  type ReadParameters,
  type Result,
  readMany,
  readOf,
  readOptions,
  readValue,
  type ViewValue,
} from './internal/read.js'
import type { AnyClient } from './internal/types.js'
import * as validate from './internal/validate.js'
import * as VenueReads from './internal/venue.js'

const { view } = VenueReads

import type * as Ladder from './Ladder.js'
import * as Shape from './Shape.js'

/**
 * The block every read of a snapshot is pinned to. `timestamp` and `baseFeePerGas` are the ones the reads saw: the
 * block's own, or the `blockOverrides` given for them.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { block } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [],
 * })
 * const pinned: Snapshot.Block = block
 * console.log(pinned.number, pinned.timestamp)
 * ```
 */
export type Block = {
  number: bigint
  hash: Hex
  timestamp: bigint
  baseFeePerGas: bigint | null
}

/**
 * Everything `quote` and `fill` read for one pair, at the snapshot's block.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const pair: Snapshot.PairState = Snapshot.pair(snapshot, 0)
 * console.log(pair.hot.mid, pair.consumed, pair.inventory)
 * ```
 */
export type PairState = {
  ok: true
  pairIndex: number
  base: Address
  quote: Address
  sizeUnit: bigint
  /** Who may trade it, as `setPairAccess` takes it; `'none'` for a removed or unknown pair. */
  access: AccessModeName
  hook: Address
  hookFlags: number
  /** The stored hot word, raw. */
  hotWord: Hex
  /** The stored hot word, decoded (the initial word for a pair never posted). */
  hot: HotWord.HotWord
  consumed: Ladder.Consumed
  midBand: { minMid: bigint; maxMid: bigint }
  /** The active shape's words (`shape(pairIndex, hot.shapeId)`). */
  shapeWords: Shape.Words
  /** The active shape, or null if its words aren't canonical (`setShape` never stores such words). */
  shape: Shape.Shape | null
  /** The venue's inventory: its balances of the pair's tokens (the Rust SDK's `inventory`). */
  inventory: { base: bigint; quote: bigint }
  /** `hookLiquidity` for each token: 0 unless the pair's hook has `BEFORE_FILL`. */
  hookLiquidity: { base: bigint; quote: bigint }
}

/**
 * A pair the snapshot could not read: one of its reads failed, or its hot word didn't decode. It can't be quoted.
 * `error` is viem's error for the failed read (decode a revert in it with `Errors.decode`), or the SDK's.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 * })
 * const failed: Snapshot.PairFailure[] = snapshot.pairs.filter((p) => !p.ok)
 * console.log(failed.map((p) => [p.pairIndex, p.error.message]))
 * ```
 */
export type PairFailure = { ok: false; pairIndex: number; error: Error }

/**
 * One pair of a snapshot, read or not (`ok`).
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 * })
 * for (const pair of snapshot.pairs satisfies readonly Snapshot.PairSnapshot[])
 *   console.log(pair.pairIndex, pair.ok ? pair.hot.sequence : pair.error.message)
 * ```
 */
export type PairSnapshot = PairState | PairFailure

/**
 * A sponsor as the snapshot read it: `Info.sponsorState`'s fields (all zero for an unregistered id), its id, and its
 * admission on every read pair.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { sponsors } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 *   sponsorIds: [42n],
 * })
 * const sponsor = sponsors[0]
 * if (sponsor?.ok) {
 *   const read: Snapshot.SponsorState = sponsor
 *   console.log(read.enabled, read.admitted[0])
 * }
 * ```
 */
export type SponsorState = Info.SponsorState & {
  ok: true
  sponsorId: bigint
  /** `pairSponsor(pairIndex, sponsorId)` for each read pair. */
  admitted: Readonly<Record<number, boolean>>
}

/**
 * A sponsor the snapshot could not read: one of its reads failed.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { sponsors } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   sponsorIds: [42n],
 * })
 * const failed: Snapshot.SponsorFailure[] = sponsors.filter((s) => !s.ok)
 * console.log(failed.length)
 * ```
 */
export type SponsorFailure = { ok: false; sponsorId: bigint; error: Error }

/**
 * One sponsor of a snapshot, read or not (`ok`), as {@link PairSnapshot} is one pair.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { sponsors } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   sponsorIds: [42n],
 * })
 * for (const sponsor of sponsors satisfies readonly Snapshot.SponsorSnapshot[])
 *   console.log(sponsor.sponsorId, sponsor.ok ? sponsor.admin : sponsor.error.message)
 * ```
 */
export type SponsorSnapshot = SponsorState | SponsorFailure

/**
 * Per-account venue state: whether the account is denied (`Info.isDenied`) and an agent (`Info.isAgent`).
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { accounts } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   accounts: ['0x3333333333333333333333333333333333333333'],
 * })
 * const read = accounts.filter((a): a is Snapshot.AccountState => a.ok)
 * console.log(read.map((a) => [a.account, a.isDenied, a.isAgent]))
 * ```
 */
export type AccountState = {
  ok: true
  account: Address
  isDenied: boolean
  isAgent: boolean
}

/**
 * An account the snapshot could not read.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { accounts } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   accounts: ['0x3333333333333333333333333333333333333333'],
 * })
 * const failed: Snapshot.AccountFailure[] = accounts.filter((a) => !a.ok)
 * console.log(failed.length)
 * ```
 */
export type AccountFailure = { ok: false; account: Address; error: Error }

/**
 * One account of a snapshot, read or not (`ok`).
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { accounts } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   accounts: ['0x3333333333333333333333333333333333333333'],
 * })
 * const snapshots: readonly Snapshot.AccountSnapshot[] = accounts
 * console.log(snapshots.length)
 * ```
 */
export type AccountSnapshot = AccountState | AccountFailure

/**
 * `takerAccess` and `isMember` for one taker, pair and sponsor id. Read without fee fields, so it never reports
 * `PriorityFeeTooHigh`, which a fill paying a priority fee above `state.maxTakerPriorityFee` reverts with first. Pass
 * it to `Quote.local` as `takerAccess` to price as the taker's fill would.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
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
 * const access: Snapshot.AccessState = Snapshot.access(snapshot, {
 *   pairIndex: 0,
 *   taker,
 *   sponsorId: 0n,
 * })
 * console.log(access.access, access.isMember)
 * ```
 */
export type AccessState = {
  ok: true
  pairIndex: number
  taker: Address
  sponsorId: bigint
  access: TakerAccessName
  isMember: boolean
}

/**
 * A taker, pair and sponsor id whose access the snapshot could not read.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { access } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 *   access: [{ taker: '0x3333333333333333333333333333333333333333', sponsorIds: [0n] }],
 * })
 * const failed: Snapshot.AccessFailure[] = access.filter((a) => !a.ok)
 * console.log(failed.length)
 * ```
 */
export type AccessFailure = {
  ok: false
  pairIndex: number
  taker: Address
  sponsorId: bigint
  error: Error
}

/**
 * One taker, pair and sponsor id's access in a snapshot, read or not (`ok`).
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { access } = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 *   access: [{ taker: '0x3333333333333333333333333333333333333333', sponsorIds: [0n] }],
 * })
 * const snapshots: readonly Snapshot.AccessSnapshot[] = access
 * console.log(snapshots.length)
 * ```
 */
export type AccessSnapshot = AccessState | AccessFailure

/**
 * One venue's state at one block. The venue-wide `state` is always read (`Snapshot.get` throws otherwise); each pair,
 * sponsor, account and access entry is read or not on its own (`ok`).
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot: Snapshot.VenueSnapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 * })
 * console.log(snapshot.block.number, snapshot.state.halted, snapshot.pairs.length)
 * ```
 */
export type VenueSnapshot = {
  venue: Address
  block: Block
  /** The venue-wide state a fill reads (`Info.venueState`). */
  state: Info.VenueState
  pairs: readonly PairSnapshot[]
  sponsors: readonly SponsorSnapshot[]
  accounts: readonly AccountSnapshot[]
  access: readonly AccessSnapshot[]
}

/**
 * Reads one venue at one block: its state, the pairs asked for (configuration, hot word, consumed depth, mid band,
 * active shape, balances and hook liquidity), and the sponsors, accounts and taker access asked for. Every read pins
 * the block (`blockNumber`, else the block `blockTag` names, else the latest), so a quote made from the snapshot is the
 * venue's own at that block (`Quote.local`).
 *
 * It makes two multicalls, three when `pairs` is `'all'` (the default): the venue state first, for its pair count;
 * then the pairs, sponsors, accounts and access; then the active shapes, the venue's balance of every pair token (once
 * each) and the hook liquidity of hooked pairs. Around them, one block read (two with `verifyHash`).
 *
 * Failures: if the venue-wide state can't be read, nothing can: it throws viem's error when the node fails the read,
 * and `UnknownVenueError` when the address doesn't answer the venue views. Any other read that fails, or answers a
 * value the SDK can't decode, fails only its own entry, which then reads `{ ok: false, error }`; every other entry
 * stands. `Snapshot.pair` and `Snapshot.access` throw `SnapshotIncompleteError` for a failed entry.
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 *   access: [{ taker: '0x3333333333333333333333333333333333333333', sponsorIds: [42n, 0n] }],
 * })
 * console.log(snapshot.block.number, Snapshot.pair(snapshot, 0).hot.mid)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, what to read and the read options.
 * @returns The venue's state at one block.
 */
export async function get(
  client: AnyClient,
  parameters: get.Parameters,
): Promise<get.ReturnValue> {
  // Every input is checked before the first read.
  const venue = validate.address(parameters.venue, 'venue', { nonzero: true })
  const options = readOptions(parameters)
  const multicallAddress =
    parameters.multicallAddress === undefined
      ? undefined
      : validate.address(parameters.multicallAddress, 'multicallAddress')
  const requestedPairs =
    parameters.pairs === undefined || parameters.pairs === 'all'
      ? undefined
      : list(parameters.pairs, 'pairs').map((pairIndex) =>
          validate.pairIndex(pairIndex),
        )
  const sponsorIds = list(parameters.sponsorIds ?? [], 'sponsorIds').map(
    validate.sponsorId,
  )
  const accounts = list(parameters.accounts ?? [], 'accounts').map((a) =>
    validate.address(a, 'account'),
  )
  const takers = list(parameters.access ?? [], 'access').map(
    ({ taker, sponsorIds: ids }) => ({
      taker: validate.address(taker, 'taker'),
      sponsorIds: list(ids, 'access[].sponsorIds').map(validate.sponsorId),
    }),
  )

  assertPinnable(options)

  const block = await getBlock(
    client,
    options.blockNumber !== undefined
      ? { blockNumber: options.blockNumber }
      : { blockTag: options.blockTag ?? 'latest' },
  )
  if (block.number === null || block.hash === null)
    throw new UnexpectedResponseError(
      'the node answered the block to snapshot without a number or hash',
      { value: { number: block.number, hash: block.hash } },
    )
  const overrides = options.blockOverrides
  const pinned: Block = {
    number: block.number,
    hash: block.hash,
    timestamp: overrides?.time ?? block.timestamp,
    baseFeePerGas: overrides?.baseFeePerGas ?? block.baseFeePerGas ?? null,
  }
  const { blockTag: _, ...at } = options
  const read = (reads: readonly Read[]) =>
    readMany(client, reads, {
      ...at,
      blockNumber: pinned.number,
      multicallAddress,
    })
  const v = VenueReads.read

  // Round 0, only for 'all': the venue state, for its pair count. Otherwise the state joins round 1.
  let state: Info.VenueState | undefined
  if (requestedPairs === undefined)
    state = venueState(venue, await read(VenueReads.state(venue)))
  const pairIndexes =
    requestedPairs ??
    Array.from({ length: (state as Info.VenueState).pairCount }, (_, i) => i)
  const accessKeys = takers.flatMap(({ taker, sponsorIds: ids }) =>
    pairIndexes.flatMap((pairIndex) =>
      ids.map((sponsorId) => ({ pairIndex, taker, sponsorId })),
    ),
  )

  // Round 1: the venue state (unless round 0 read it), every pair's config, hot word, consumption and band, sponsors,
  // accounts, access.
  const stateReads = state === undefined ? VenueReads.state(venue) : []
  const round1 = cursor(
    await read([
      ...stateReads,
      ...pairIndexes.flatMap((i) => [
        v(venue, 'pair', [i]),
        v(venue, 'hotWord', [i]),
        v(venue, 'consumed', [i]),
        v(venue, 'midBand', [i]),
      ]),
      ...sponsorIds.flatMap((id) => [
        v(venue, 'sponsor', [id]),
        v(venue, 'pendingSponsorAdmin', [id]),
        ...pairIndexes.map((i) => v(venue, 'pairSponsor', [i, id])),
      ]),
      ...accounts.flatMap((a) => [
        v(venue, 'denied', [a]),
        v(venue, 'isUpdater', [a]),
      ]),
      ...accessKeys.flatMap(({ pairIndex, taker, sponsorId }) => [
        v(venue, 'takerAccess', [pairIndex, taker, sponsorId]),
        v(venue, 'isMember', [pairIndex, sponsorId, taker]),
      ]),
    ]),
  )
  state ??= venueState(venue, round1.take(stateReads.length))

  type Live = {
    pairIndex: number
    pair: PairConfig
    hotWord: Hex
    hot: HotWord.HotWord
    consumed: Ladder.Consumed
    midBand: { minMid: bigint; maxMid: bigint }
  }
  const partial: (Live | PairFailure)[] = pairIndexes.map((pairIndex) =>
    entry(
      round1.take(4),
      (r): Live => {
        const hotWord = view(r[1], v(venue, 'hotWord', [pairIndex]))
        const [bids, asks] = view(r[2], v(venue, 'consumed', [pairIndex]))
        const [minMid, maxMid] = view(r[3], v(venue, 'midBand', [pairIndex]))
        return {
          pairIndex,
          pair: view(r[0], v(venue, 'pair', [pairIndex])),
          hotWord,
          hot: HotWord.decode(hotWord),
          consumed: { bids, asks },
          midBand: { minMid, maxMid },
        }
      },
      (error) => ({ ok: false, pairIndex, error }),
    ),
  )

  const sponsors = sponsorIds.map((sponsorId) =>
    entry(
      round1.take(2 + pairIndexes.length),
      (r): SponsorState => {
        const [admin, enabled, generation] = view(
          r[0],
          v(venue, 'sponsor', [sponsorId]),
        )
        const admitted: Record<number, boolean> = {}
        pairIndexes.forEach((pairIndex, k) => {
          admitted[pairIndex] = view(
            r[2 + k],
            v(venue, 'pairSponsor', [pairIndex, sponsorId]),
          )
        })
        return {
          ok: true,
          sponsorId,
          admin,
          pendingAdmin: view(
            r[1],
            v(venue, 'pendingSponsorAdmin', [sponsorId]),
          ),
          enabled,
          generation: Number(generation),
          admitted,
        }
      },
      (error): SponsorFailure => ({ ok: false, sponsorId, error }),
    ),
  )
  const accountStates = accounts.map((account) =>
    entry(
      round1.take(2),
      (r): AccountState => ({
        ok: true,
        account,
        isDenied: view(r[0], v(venue, 'denied', [account])),
        isAgent: view(r[1], v(venue, 'isUpdater', [account])),
      }),
      (error): AccountFailure => ({ ok: false, account, error }),
    ),
  )
  const access = accessKeys.map(({ pairIndex, taker, sponsorId }) =>
    entry(
      round1.take(2),
      (r): AccessState => ({
        ok: true,
        pairIndex,
        taker,
        sponsorId,
        access: VenueReads.accessName(
          view(r[0], v(venue, 'takerAccess', [pairIndex, taker, sponsorId])),
        ),
        isMember: view(
          r[1],
          v(venue, 'isMember', [pairIndex, sponsorId, taker]),
        ),
      }),
      (error): AccessFailure => ({
        ok: false,
        pairIndex,
        taker,
        sponsorId,
        error,
      }),
    ),
  )

  // Round 2: the active shapes, the venue's balances of every pair token (once each), and hook liquidity.
  const live = partial.filter((p): p is Live => !('ok' in p))
  const tokens = [
    ...new Set(
      live.flatMap((p) =>
        p.pair.base === zeroAddress ? [] : [p.pair.base, p.pair.quote],
      ),
    ),
  ]
  const hooked = live.filter(
    (p) => (p.pair.hookFlags & VenueHookFlags.beforeFill) !== 0,
  )
  const round2 = cursor(
    await read([
      ...live.map((p) => v(venue, 'shape', [p.pairIndex, p.hot.shapeId])),
      ...tokens.map((token) => readOf(token, Abis.tip20, 'balanceOf', [venue])),
      ...hooked.flatMap((p) => [
        v(venue, 'hookLiquidity', [p.pairIndex, p.pair.base]),
        v(venue, 'hookLiquidity', [p.pairIndex, p.pair.quote]),
      ]),
    ]),
  )
  const shapes = new Map(live.map((p) => [p.pairIndex, round2.take(1)]))
  const inventory = new Map(
    tokens.map((t) => [t.toLowerCase(), round2.take(1)[0] as Result]),
  )
  const hookLiquidity = new Map(
    hooked.map((p) => [p.pairIndex, round2.take(2)]),
  )
  const balance = (token: Address): Result[] =>
    token === zeroAddress ? [] : [inventory.get(token.toLowerCase()) as Result]

  const pairs: PairSnapshot[] = partial.map((p) => {
    if ('ok' in p) return p
    const { pairIndex, pair, hotWord, hot, consumed, midBand } = p
    const hooks = hookLiquidity.get(pairIndex) ?? []
    return entry(
      [
        ...(shapes.get(pairIndex) as Result[]),
        ...balance(pair.base),
        ...balance(pair.quote),
        ...hooks,
      ],
      ([words, ...rest]): PairState => {
        const shapeWords: Shape.Words = view(
          words,
          v(venue, 'shape', [pairIndex, hot.shapeId]),
        )
        // The venue's balance of each pair token (none for a removed pair's zero address), then the hook's liquidity.
        const balances =
          pair.base === zeroAddress
            ? []
            : [pair.base, pair.quote].map((token, i) =>
                readValue(
                  rest[i],
                  readOf(token, Abis.tip20, 'balanceOf', [venue]),
                ),
              )
        const liquidity = hooks.map((r, i) =>
          view(
            r,
            v(venue, 'hookLiquidity', [
              pairIndex,
              i === 0 ? pair.base : pair.quote,
            ]),
          ),
        )
        const [base = 0n, quote = 0n] =
          pair.base === zeroAddress ? [0n, 0n] : balances
        const [hookBase = 0n, hookQuote = 0n] = liquidity
        return {
          ok: true,
          pairIndex,
          base: pair.base,
          quote: pair.quote,
          sizeUnit: pair.sizeUnit,
          access: VenueReads.accessModeName(pair.access),
          hook: pair.hook,
          hookFlags: pair.hookFlags,
          hotWord,
          hot,
          consumed,
          midBand,
          shapeWords,
          shape:
            Shape.check(shapeWords) === 0 ? Shape.fromWords(shapeWords) : null,
          inventory: { base, quote },
          hookLiquidity: { base: hookBase, quote: hookQuote },
        }
      },
      (error): PairFailure => ({ ok: false, pairIndex, error }),
    )
  })

  if (parameters.verifyHash) {
    const again = await getBlock(client, { blockNumber: pinned.number })
    if (again.hash !== pinned.hash) {
      throw new SnapshotReorgedError(
        `block ${pinned.number} changed from ${pinned.hash} to ${String(again.hash)}`,
        { blockNumber: pinned.number, hash: pinned.hash, newHash: again.hash },
      )
    }
  }

  return {
    venue,
    block: pinned,
    state,
    pairs,
    sponsors,
    accounts: accountStates,
    access,
  }
}

export declare namespace get {
  /** The venue, what to read and the read options. */
  type Parameters = ReadParameters &
    MulticallParameters & {
      venue: Address
      /** The pairs to read (default `'all'`: every index below `pairCount`, removed ones included). */
      pairs?: readonly number[] | 'all' | undefined
      /** Sponsor ids to read (views can't enumerate them), as `access` names them. */
      sponsorIds?: readonly bigint[] | undefined
      /** Accounts whose deny and agent state to read. */
      accounts?: readonly Address[] | undefined
      /** Takers whose access to read, under each sponsor id, on every read pair. */
      access?:
        | readonly { taker: Address; sponsorIds: readonly bigint[] }[]
        | undefined
      /** Re-read the block hash after the reads and throw `SnapshotReorgedError` if it changed. */
      verifyHash?: boolean | undefined
    }
  /** The venue's state at one block. */
  type ReturnValue = VenueSnapshot
  /** The errors `get` throws: the SDK's refusals of its arguments (`blockTag: 'pending'` included), viem's for the block
   * read and the multicalls (a node that fails the venue state's read included), a block without a number,
   * `UnknownVenueError` for an address that doesn't answer the venue views, and `SnapshotReorgedError`. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | UnknownVenueErrorType
    | SnapshotReorgedErrorType
    | UnexpectedResponseErrorType
    | GetBlockErrorType
    | ReadManyErrorType
    | GlobalErrorType
}

/**
 * The pair at `pairIndex`, which the snapshot must have read successfully (`SnapshotIncompleteError` otherwise).
 *
 * @example
 * ```ts
 * import { Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * console.log(Snapshot.pair(snapshot, 0).consumed)
 * ```
 *
 * @param snapshot - A snapshot, or any object with its `pairs`.
 * @param pairIndex - The pair.
 * @returns The pair's state.
 */
export function pair(
  snapshot: Pick<VenueSnapshot, 'pairs'>,
  pairIndex: number,
): pair.ReturnValue {
  const p = snapshot.pairs.find((x) => x.pairIndex === pairIndex)
  if (!p)
    throw new SnapshotIncompleteError(
      `the snapshot did not read pair ${pairIndex}`,
      { pairIndex },
    )
  if (!p.ok)
    throw new SnapshotIncompleteError(
      `pair ${pairIndex} could not be read: ${short(p.error)}`,
      { pairIndex, cause: p.error },
    )
  return p
}

export declare namespace pair {
  /** The pair's state. */
  type ReturnValue = PairState
  /** The errors `pair` throws. */
  type ErrorType = SnapshotIncompleteErrorType | GlobalErrorType
}

/**
 * The access the snapshot read for one taker, pair and sponsor id, which it must have read successfully
 * (`SnapshotIncompleteError` otherwise): what `Quote.local` takes as `takerAccess`.
 *
 * @example
 * ```ts
 * import { Quote, Snapshot } from '@tempoxyz/propamm-sdk'
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
 *   exactIn: false,
 *   priorityFee: 0n,
 *   takerAccess: Snapshot.access(snapshot, { pairIndex: 0, taker, sponsorId: 0n }),
 * })
 * console.log(q.ok)
 * ```
 *
 * @param snapshot - A snapshot, or any object with its `access`.
 * @param key - The pair, the taker and the sponsor id.
 * @returns The access the snapshot read.
 */
export function access(
  snapshot: Pick<VenueSnapshot, 'access'>,
  key: { pairIndex: number; taker: Address; sponsorId: bigint },
): access.ReturnValue {
  const taker = validate.address(key.taker, 'taker')
  const a = snapshot.access.find(
    (x) =>
      x.pairIndex === key.pairIndex &&
      x.sponsorId === key.sponsorId &&
      x.taker.toLowerCase() === taker.toLowerCase(),
  )
  const what = `${taker}'s access to pair ${key.pairIndex} under sponsor ${key.sponsorId}`
  if (!a)
    throw new SnapshotIncompleteError(`the snapshot did not read ${what}`, {
      pairIndex: key.pairIndex,
    })
  if (!a.ok)
    throw new SnapshotIncompleteError(
      `${what} could not be read: ${short(a.error)}`,
      { pairIndex: key.pairIndex, cause: a.error },
    )
  return a
}

export declare namespace access {
  /** The access the snapshot read. */
  type ReturnValue = AccessState
  /** The errors `access` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | SnapshotIncompleteErrorType
    | GlobalErrorType
}

/** The venue's `pair` view, as viem decodes it. */
/** A pair's config as the venue's `pair` view returns it (its type from the ABI). */
type PairConfig = ViewValue<typeof venueAbi, 'pair'>

/** Reads a multicall's results in order, a slice at a time. */
function cursor(results: readonly Result[]) {
  let at = 0
  return {
    take(n: number): Result[] {
      const slice = results.slice(at, at + n)
      at += n
      return slice
    },
  }
}

/** The venue state from its reads, which must all succeed: without it the venue can't be read at all. */
function venueState(
  venue: Address,
  results: readonly Result[],
): Info.VenueState {
  const failed = VenueReads.stateViews.findIndex(
    (_, i) => results[i]?.status !== 'success',
  )
  if (failed !== -1) {
    const r = results[failed]
    // The node failing the read is viem's error for it; only an address that doesn't answer the views isn't a venue.
    if (r?.status === 'failure' && r.aggregateFailure) throw r.error
    throw new UnknownVenueError(`${venue} did not answer the venue views`, {
      venue,
      ...(r?.status === 'failure' ? { cause: r.error } : {}),
    })
  }
  return VenueReads.stateFrom(venue, results)
}

/**
 * One entry from its reads: `build` over their results when every read succeeded (it decodes each with `view`, typed
 * by the view it names), else `fail` with the first failed read's error. An error `build` throws (a value the SDK
 * can't decode) fails the entry too.
 */
function entry<T, F>(
  results: readonly Result[],
  build: (results: readonly Result[]) => T,
  fail: (error: Error) => F,
): T | F {
  for (const r of results) if (r.status !== 'success') return fail(r.error)
  try {
    return build(results)
  } catch (e) {
    return fail(e instanceof Error ? e : new Error(String(e)))
  }
}

/** An error's one-line message: viem's and the SDK's `shortMessage`, else its message. */
function short(error: Error): string {
  return (error as { shortMessage?: string }).shortMessage ?? error.message
}

/** An array input, refused before any read if it isn't one. */
function list<T>(value: readonly T[], parameter: string): readonly T[] {
  if (!Array.isArray(value))
    throw new InvalidArgumentError(`${parameter} must be an array`, {
      parameter,
      value,
    })
  return value
}
