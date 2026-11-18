// Decoded reads (the Rust SDK's `Info`). Raw views stay plain `readContract` calls with `Abis.venueAbi`. Every read takes
// viem/tempo's read parameters (`account`, `blockNumber`, `blockTag`, `blockOverrides`, `stateOverride`); a read that
// makes more than one call resolves one block first (the given `blockNumber`, else the block `blockTag` names, else the
// latest) and makes every call at it.
import {
  type Address,
  type DecodeEventLogErrorType,
  decodeEventLog,
  type EncodeAbiParametersErrorType,
  type EncodeEventTopicsErrorType,
  encodeAbiParameters,
  encodeEventTopics,
  type GetLogsErrorType,
  getAbiItem,
  type Hex,
  type Log,
  numberToHex,
  type ReadContractErrorType,
} from 'viem'
import { readContract } from 'viem/actions'
import { formatLog } from 'viem/utils'
import { venueAbi, venueFactoryAbi } from './generated/abis.js'
import type { AccessModeName, TakerAccessName } from './generated/enums.js'
import * as HotWord from './HotWord.js'
import {
  AmountOutOfRangeError,
  type AmountOutOfRangeErrorType,
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  type InvalidHotWordErrorType,
  type InvalidShapeErrorType,
  type SnapshotIncompleteErrorType,
  UnexpectedResponseError,
  type UnexpectedResponseErrorType,
  UnknownPairError,
  type UnknownPairErrorType,
} from './internal/errors.js'
import {
  type MulticallParameters,
  type PinErrorType,
  pin,
  type ReadManyErrorType,
  type ReadOptionsErrorType,
  type ReadParameters,
  readMany,
  readOptions,
  readValues,
  type ViewValue,
} from './internal/read.js'
import type { AnyClient } from './internal/types.js'
import * as validate from './internal/validate.js'
import * as VenueReads from './internal/venue.js'
import type * as Ladder from './Ladder.js'
import * as Shape from './Shape.js'

/**
 * The fee fields of the transaction a read or a step stands for (`Info.quote`, `Info.takerAccess`, `Plan.Step`): the
 * venue's fee cap judges their priority fee, and an `eth_call` without them never sees the cap. Build the fields with
 * `Fees.takerFields` and reuse them for the read, simulation, gas estimate and submitted take.
 *
 * @example
 * ```ts
 * import { Fees, Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const fees: Info.FeeParameters = Fees.takerFields(
 *   20_000_000_000n,
 *   10n * Fees.gwei,
 *   Fees.gwei,
 * )
 * const access = await Info.takerAccess(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 *   taker: '0x3333333333333333333333333333333333333333',
 *   sponsorId: 0n,
 *   account: '0x3333333333333333333333333333333333333333',
 *   ...fees,
 * })
 * console.log(access)
 * ```
 */
export type FeeParameters = {
  maxFeePerGas?: bigint | undefined
  maxPriorityFeePerGas?: bigint | undefined
}

/** A contract to read: a nonzero address. */
const contract = (value: Address, name: string) =>
  validate.address(value, name, { nonzero: true })

const multicallAddress = (parameters: MulticallParameters) =>
  parameters.multicallAddress === undefined
    ? {}
    : {
        multicallAddress: validate.address(
          parameters.multicallAddress,
          'multicallAddress',
        ),
      }

/**
 * Whether `factory` created `venue` (`isVenue`, the check the Settler makes). The SDK infers no deployment: supply a
 * factory you verified, and check the client's chain with viem's `getChainId` (the Rust SDK's `Info::connect` does
 * both).
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const ok = await Info.isVenue(client, {
 *   factory: '0x2222222222222222222222222222222222222222',
 *   venue: '0x1111111111111111111111111111111111111111',
 * })
 * console.log(ok)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The factory, the venue and the read options.
 * @returns Whether the factory created the venue.
 */
export async function isVenue(
  client: AnyClient,
  parameters: isVenue.Parameters,
): Promise<isVenue.ReturnValue> {
  // An argument here, not the contract read: the factory answers false for any address it didn't create.
  const venue = validate.address(parameters.venue, 'venue')
  return readContract(client, {
    address: contract(parameters.factory, 'factory'),
    abi: venueFactoryAbi,
    functionName: 'isVenue',
    args: [venue],
    ...readOptions(parameters),
  })
}

export declare namespace isVenue {
  /** The factory you verified, the address to check and the read options. */
  type Parameters = ReadParameters & { factory: Address; venue: Address }
  /** Whether the factory created the venue. */
  type ReturnValue = boolean
  /** The errors `isVenue` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | ReadOptionsErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * The address the factory deploys `owner`'s venue at for `salt` (CREATE2), before or after `createVenue`.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http, keccak256, toHex } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const venue = await Info.predictVenue(client, {
 *   factory: '0x2222222222222222222222222222222222222222',
 *   owner: '0x3333333333333333333333333333333333333333',
 *   salt: keccak256(toHex('my venue')),
 * })
 * console.log(venue)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The factory, the owner, the salt and the read options.
 * @returns The venue's address.
 */
export async function predictVenue(
  client: AnyClient,
  parameters: predictVenue.Parameters,
): Promise<predictVenue.ReturnValue> {
  return readContract(client, {
    address: contract(parameters.factory, 'factory'),
    abi: venueFactoryAbi,
    functionName: 'predictVenue',
    args: [
      validate.address(parameters.owner, 'owner'),
      validate.bytes32(parameters.salt, 'salt'),
    ],
    ...readOptions(parameters),
  })
}

export declare namespace predictVenue {
  /** The factory, the venue's owner, the CREATE2 salt and the read options. */
  type Parameters = ReadParameters & {
    factory: Address
    owner: Address
    salt: Hex
  }
  /** The venue's address. */
  type ReturnValue = Address
  /** The errors `predictVenue` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * Venue-wide permissions, emergency stop and fee cap: the venue-wide state a fill reads (`Snapshot.get`'s `state`).
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const state: Info.VenueState = await Info.venueState(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 * })
 * console.log(state.halted, state.maxTakerPriorityFee)
 * ```
 */
export type VenueState = {
  owner: Address
  pendingOwner: Address
  settler: Address
  factory: Address
  halted: boolean
  deniedCount: number
  /** `Venue.noPriorityFeeCap` for none. */
  maxTakerPriorityFee: bigint
  pairCount: number
}

/**
 * Reads {@link VenueState} in one multicall at one block.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const state = await Info.venueState(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   blockTag: 'finalized',
 * })
 * console.log(state.owner)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue and the read options.
 * @returns The venue-wide state.
 */
export async function venueState(
  client: AnyClient,
  parameters: venueState.Parameters,
): Promise<venueState.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const options = {
    ...(await pin(client, readOptions(parameters))),
    ...multicallAddress(parameters),
  }
  const results = await readMany(client, VenueReads.state(venue), options)
  return VenueReads.stateFrom(venue, results)
}

export declare namespace venueState {
  /** The venue and the read options. */
  type Parameters = ReadParameters &
    MulticallParameters & {
      venue: Address
    }
  /** The venue-wide state. */
  type ReturnValue = VenueState
  /** The errors `venueState` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | PinErrorType
    | ReadManyErrorType
    | SnapshotIncompleteErrorType
    | GlobalErrorType
}

/**
 * Whether `agent` is one of the venue's updaters (`approveAgent`). The owner's authority is separate.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const agent = await Info.isAgent(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   agent: '0x3333333333333333333333333333333333333333',
 * })
 * console.log(agent)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the account and the read options.
 * @returns Whether the account is an agent.
 */
export async function isAgent(
  client: AnyClient,
  parameters: isAgent.Parameters,
): Promise<isAgent.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  return readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'isUpdater',
    args: [validate.address(parameters.agent, 'agent')],
    ...readOptions(parameters),
  })
}

export declare namespace isAgent {
  /** The venue, the account to check and the read options. */
  type Parameters = ReadParameters & { venue: Address; agent: Address }
  /** Whether the account is an agent. */
  type ReturnValue = boolean
  /** The errors `isAgent` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | ReadOptionsErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * A sponsor's admin, pending admin, switch and list generation. All zero for an unregistered id, 0 included: the home
 * list belongs to the venue's current owner, not to a registered admin.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const sponsor: Info.SponsorState = await Info.sponsorState(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   sponsorId: 42n,
 * })
 * console.log(sponsor.enabled)
 * ```
 */
export type SponsorState = {
  admin: Address
  pendingAdmin: Address
  enabled: boolean
  generation: number
}

/**
 * Reads {@link SponsorState} in one multicall at one block.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const sponsor = await Info.sponsorState(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   sponsorId: 42n,
 * })
 * console.log(sponsor.admin, sponsor.generation)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the sponsor id and the read options.
 * @returns The sponsor's state.
 */
export async function sponsorState(
  client: AnyClient,
  parameters: sponsorState.Parameters,
): Promise<sponsorState.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const sponsorId = validate.sponsorId(parameters.sponsorId)
  const options = {
    ...(await pin(client, readOptions(parameters))),
    ...multicallAddress(parameters),
  }
  const [[admin, enabled, generation], pendingAdmin] = await readValues(
    client,
    [
      VenueReads.read(venue, 'sponsor', [sponsorId]),
      VenueReads.read(venue, 'pendingSponsorAdmin', [sponsorId]),
    ],
    options,
  )
  return {
    admin,
    pendingAdmin,
    enabled,
    generation: Number(generation),
  }
}

export declare namespace sponsorState {
  /** The venue, the sponsor id and the read options. */
  type Parameters = ReadParameters &
    MulticallParameters & {
      venue: Address
      sponsorId: bigint
    }
  /** The sponsor's state. */
  type ReturnValue = SponsorState
  /** The errors `sponsorState` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | PinErrorType
    | ReadManyErrorType
    | SnapshotIncompleteErrorType
    | GlobalErrorType
}

/**
 * Whether the sponsor is admitted on the pair, and only that: not whether it is enabled or a taker listed. Sponsor id
 * 0, the home list, reads whether the pair is live.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const admitted = await Info.pairSponsor(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 *   sponsorId: 42n,
 * })
 * console.log(admitted)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the pair, the sponsor id and the read options.
 * @returns Whether the sponsor is admitted on the pair.
 */
export async function pairSponsor(
  client: AnyClient,
  parameters: pairSponsor.Parameters,
): Promise<pairSponsor.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  return readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'pairSponsor',
    args: [
      validate.pairIndex(parameters.pairIndex),
      validate.sponsorId(parameters.sponsorId),
    ],
    ...readOptions(parameters),
  })
}

export declare namespace pairSponsor {
  /** The venue, the pair, the sponsor id and the read options. */
  type Parameters = ReadParameters & {
    venue: Address
    pairIndex: number
    sponsorId: bigint
  }
  /** Whether the sponsor is admitted on the pair. */
  type ReturnValue = boolean
  /** The errors `pairSponsor` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * Current-generation membership of the sponsor's list on the pair, and only that: `takerAccess` is the effective
 * check. `account` is the member to check; the read's own caller is not configurable here.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const listed = await Info.isMember(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 *   sponsorId: 0n,
 *   account: '0x3333333333333333333333333333333333333333',
 * })
 * console.log(listed)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the pair, the sponsor id, the account and the read options.
 * @returns Whether the account is on the list.
 */
export async function isMember(
  client: AnyClient,
  parameters: isMember.Parameters,
): Promise<isMember.ReturnValue> {
  const { account, ...rest } = parameters
  const venue = contract(parameters.venue, 'venue')
  return readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'isMember',
    args: [
      validate.pairIndex(parameters.pairIndex),
      validate.sponsorId(parameters.sponsorId),
      validate.address(account, 'account'),
    ],
    ...readOptions(rest),
  })
}

export declare namespace isMember {
  /** The venue, the pair, the sponsor id, the member to check and the read options. */
  type Parameters = Omit<ReadParameters, 'account'> & {
    venue: Address
    pairIndex: number
    sponsorId: bigint
    account: Address
  }
  /** Whether the account is on the list. */
  type ReturnValue = boolean
  /** The errors `isMember` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * Whether the account is on the venue's deny list, which overrides every list and `open`. `account` is the account to
 * check; the read's own caller is not configurable here.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const denied = await Info.isDenied(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   account: '0x3333333333333333333333333333333333333333',
 * })
 * console.log(denied)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the account and the read options.
 * @returns Whether the account is denied.
 */
export async function isDenied(
  client: AnyClient,
  parameters: isDenied.Parameters,
): Promise<isDenied.ReturnValue> {
  const { account, ...rest } = parameters
  const venue = contract(parameters.venue, 'venue')
  return readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'denied',
    args: [validate.address(account, 'account')],
    ...readOptions(rest),
  })
}

export declare namespace isDenied {
  /** The venue, the account to check and the read options. */
  type Parameters = Omit<ReadParameters, 'account'> & {
    venue: Address
    account: Address
  }
  /** Whether the account is denied. */
  type ReturnValue = boolean
  /** The errors `isDenied` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | ReadOptionsErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * A live pair's configuration.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const market: Info.Market = await Info.market(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 * })
 * console.log(market.base, market.quote, market.sizeUnit)
 * ```
 */
export type Market = {
  pairIndex: number
  base: Address
  quote: Address
  sizeUnit: bigint
  /** Who may trade it, as `setPairAccess` takes it: a live pair is never `'none'`. */
  access: Exclude<AccessModeName, 'none'>
  hook: Address
  hookFlags: number
}

/** The venue's `pair` view, as viem decodes it. */
/** A pair's config as the venue's `pair` view returns it (its type from the ABI). */
type PairView = ViewValue<typeof venueAbi, 'pair'>

function toMarket(pairIndex: number, p: PairView): Market {
  if (BigInt(p.base) === 0n)
    throw new UnknownPairError(`pair ${pairIndex} is unknown or removed`, {
      pairIndex,
    })
  return {
    pairIndex,
    base: p.base,
    quote: p.quote,
    sizeUnit: p.sizeUnit,
    access: VenueReads.liveAccessMode(p.access),
    hook: p.hook,
    hookFlags: p.hookFlags,
  }
}

/**
 * One pair's configuration; `UnknownPairError` for a removed or unknown index.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const market = await Info.market(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 * })
 * console.log(market.access)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the pair and the read options.
 * @returns The pair's configuration.
 */
export async function market(
  client: AnyClient,
  parameters: market.Parameters,
): Promise<market.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const pairIndex = validate.pairIndex(parameters.pairIndex)
  const p = await readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'pair',
    args: [pairIndex],
    ...readOptions(parameters),
  })
  return toMarket(pairIndex, p)
}

export declare namespace market {
  /** The venue, the pair and the read options. */
  type Parameters = ReadParameters & { venue: Address; pairIndex: number }
  /** The pair's configuration. */
  type ReturnValue = Market
  /** The errors `market` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | UnknownPairErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * Every live pair (the Rust SDK's `meta`), at one block: the pair count and then every index below it. Removed indexes
 * are never reused and are skipped.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const markets = await Info.meta(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 * })
 * console.log(markets.map((m) => m.pairIndex))
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue and the read options.
 * @returns The live pairs, by index.
 */
export async function meta(
  client: AnyClient,
  parameters: meta.Parameters,
): Promise<meta.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const options = await pin(client, readOptions(parameters))
  const count = VenueReads.pairCount(
    await readContract(client, {
      address: venue,
      abi: venueAbi,
      functionName: 'pairCount',
      ...options,
    }),
  )
  const r = await readMany(
    client,
    Array.from({ length: count }, (_, i) =>
      VenueReads.read(venue, 'pair', [i]),
    ),
    { ...options, ...multicallAddress(parameters) },
  )
  const out: Market[] = []
  r.forEach((result, pairIndex) => {
    const p = VenueReads.view(
      result,
      VenueReads.read(venue, 'pair', [pairIndex]),
      `pair(${pairIndex})`,
    )
    if (BigInt(p.base) !== 0n) out.push(toMarket(pairIndex, p))
  })
  return out
}

export declare namespace meta {
  /** The venue and the read options. */
  type Parameters = ReadParameters &
    MulticallParameters & {
      venue: Address
    }
  /** The live pairs, by index. */
  type ReturnValue = Market[]
  /** The errors `meta` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | PinErrorType
    | ReadContractErrorType
    | ReadManyErrorType
    | SnapshotIncompleteErrorType
    | GlobalErrorType
}

/**
 * A pair's posted ladder at a block: not proof a taker can fill (access, halt, expiry, depth and inventory apply).
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { orders } = await Info.orders(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0],
 * })
 * const order: Info.OrderState | undefined = orders[0]
 * console.log(order?.hot.mid)
 * ```
 */
export type OrderState = {
  market: Market
  hot: HotWord.HotWord
  shape: Shape.Shape
  halted: boolean
  consumed: Ladder.Consumed
}

/**
 * The posted ladders of the pairs asked for, one per pair in request order, with the block they were read at: the
 * given `blockNumber`, else the block `blockTag` names, else the latest. Every read is at that one block (two
 * multicalls: the hot words name the shapes to read), so a pair's shape, hot word and consumption always agree.
 * `UnknownPairError` for a removed or unknown pair.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { blockNumber, orders } = await Info.orders(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0, 1],
 * })
 * console.log(blockNumber, orders.map((o) => o.hot.sequence))
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the pairs and the read options.
 * @returns The block read and each pair's posted ladder.
 */
export async function orders(
  client: AnyClient,
  parameters: orders.Parameters,
): Promise<orders.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  if (!Array.isArray(parameters.pairs))
    throw new InvalidArgumentError('pairs must be an array of pair indexes', {
      parameter: 'pairs',
      value: parameters.pairs,
    })
  const pairs = parameters.pairs.map((pairIndex) =>
    validate.pairIndex(pairIndex),
  )
  const options = {
    ...(await pin(client, readOptions(parameters))),
    ...multicallAddress(parameters),
  }
  const first = await readMany(
    client,
    [
      VenueReads.read(venue, 'halted'),
      ...pairs.flatMap((pairIndex) => [
        VenueReads.read(venue, 'pair', [pairIndex]),
        VenueReads.read(venue, 'hotWord', [pairIndex]),
        VenueReads.read(venue, 'consumed', [pairIndex]),
      ]),
    ],
    options,
  )
  const halted = VenueReads.view(first[0], VenueReads.read(venue, 'halted'))
  const read = pairs.map((pairIndex, k) => {
    const at = 1 + 3 * k
    const market = toMarket(
      pairIndex,
      VenueReads.view(
        first[at],
        VenueReads.read(venue, 'pair', [pairIndex]),
        `pair(${pairIndex})`,
      ),
    )
    const hot = HotWord.decode(
      VenueReads.view(
        first[at + 1],
        VenueReads.read(venue, 'hotWord', [pairIndex]),
        `hotWord(${pairIndex})`,
      ),
    )
    const [bids, asks] = VenueReads.view(
      first[at + 2],
      VenueReads.read(venue, 'consumed', [pairIndex]),
      `consumed(${pairIndex})`,
    )
    return { market, hot, consumed: { bids, asks } }
  })
  const shapes = await readMany(
    client,
    read.map(({ market, hot }) =>
      VenueReads.read(venue, 'shape', [market.pairIndex, hot.shapeId]),
    ),
    options,
  )
  return {
    blockNumber: options.blockNumber,
    orders: read.map(({ market, hot, consumed }, k) => ({
      market,
      hot,
      shape: Shape.fromWords(
        VenueReads.view(
          shapes[k],
          VenueReads.read(venue, 'shape', [market.pairIndex, hot.shapeId]),
          `shape(${market.pairIndex}, ${hot.shapeId})`,
        ),
      ),
      halted,
      consumed,
    })),
  }
}

export declare namespace orders {
  /** The venue, the pairs to read and the read options. */
  type Parameters = ReadParameters &
    MulticallParameters & {
      venue: Address
      pairs: readonly number[]
    }
  /** The block every read was made at, and one posted ladder per pair, in request order. */
  type ReturnValue = { blockNumber: bigint; orders: OrderState[] }
  /** The errors `orders` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | InvalidHotWordErrorType
    | InvalidShapeErrorType
    | PinErrorType
    | ReadManyErrorType
    | SnapshotIncompleteErrorType
    | UnknownPairErrorType
    | GlobalErrorType
}

/**
 * Base each side's fills have taken since the maker last refilled it.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { bids, asks } = await Info.consumed(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 * })
 * console.log(bids, asks)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the pair and the read options.
 * @returns Each side's consumed base.
 */
export async function consumed(
  client: AnyClient,
  parameters: consumed.Parameters,
): Promise<consumed.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const [bids, asks] = await readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'consumed',
    args: [validate.pairIndex(parameters.pairIndex)],
    ...readOptions(parameters),
  })
  return { bids, asks }
}

export declare namespace consumed {
  /** The venue, the pair and the read options. */
  type Parameters = ReadParameters & { venue: Address; pairIndex: number }
  /** Each side's consumed base. */
  type ReturnValue = Ladder.Consumed
  /** The errors `consumed` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * What the pair's hook can add to the venue's balance of `token` for a fill (`hookLiquidity`): 0 unless the hook has
 * `BEFORE_FILL`. The venue's own balance of a token is viem/tempo's `Actions.token.getBalance(client, { token,
 * account: venue })`; `Snapshot.get` reads both for every pair token at one block.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const extra = await Info.hookLiquidity(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 *   token: '0x20C0000000000000000000000000000000000001',
 * })
 * console.log(extra)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the pair, the token and the read options.
 * @returns The hook's liquidity for the token, in token atoms.
 */
export async function hookLiquidity(
  client: AnyClient,
  parameters: hookLiquidity.Parameters,
): Promise<hookLiquidity.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  return readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'hookLiquidity',
    args: [
      validate.pairIndex(parameters.pairIndex),
      validate.address(parameters.token, 'token'),
    ],
    ...readOptions(parameters),
  })
}

export declare namespace hookLiquidity {
  /** The venue, the pair, the token and the read options. */
  type Parameters = ReadParameters & {
    venue: Address
    pairIndex: number
    token: Address
  }
  /** The hook's liquidity for the token, in token atoms. */
  type ReturnValue = bigint
  /** The errors `hookLiquidity` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * The venue's own `quote`, inventory and hook liquidity included. Pass the swap's fee fields to see the fee cap: an
 * `eth_call` without them never does. Throws viem's revert error (decode it with `Errors.decode`).
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { amountIn, amountOut } = await Info.quote(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 *   tokenIn: '0x20C0000000000000000000000000000000000002',
 *   tokenOut: '0x20C0000000000000000000000000000000000001',
 *   amount: 1_000_000n,
 *   exactIn: false,
 * })
 * console.log(amountIn, amountOut)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The swap, its fee fields and the read options.
 * @returns The amounts in and out, in token atoms.
 */
export async function quote(
  client: AnyClient,
  parameters: quote.Parameters,
): Promise<quote.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const [amountIn, amountOut] = (await readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'quote',
    args: [
      validate.pairIndex(parameters.pairIndex),
      validate.address(parameters.tokenIn, 'tokenIn'),
      validate.address(parameters.tokenOut, 'tokenOut'),
      validate.uintBigint(
        parameters.amount,
        128,
        'amount',
        AmountOutOfRangeError,
      ),
      validate.bool(parameters.exactIn, 'exactIn'),
    ],
    ...readOptions(parameters),
    ...fees(parameters),
  } as never)) as readonly [bigint, bigint]
  return { amountIn, amountOut }
}

export declare namespace quote {
  /** The swap (the input when `exactIn`, else the output, in token atoms), its fee fields and the read options. */
  type Parameters = ReadParameters &
    FeeParameters & {
      venue: Address
      pairIndex: number
      tokenIn: Address
      tokenOut: Address
      amount: bigint
      exactIn: boolean
    }
  /** The amounts in and out, in token atoms. */
  type ReturnValue = { amountIn: bigint; amountOut: bigint }
  /** The errors `quote` throws: viem's revert error carries the venue's. */
  type ErrorType =
    | AmountOutOfRangeErrorType
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadContractErrorType
    | GlobalErrorType
}

/**
 * The fill's own access check for one taker and sponsor id, in its order (`TakerAccess`). Without fee fields it never
 * reports `PriorityFeeTooHigh`.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const access = await Info.takerAccess(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 *   taker: '0x3333333333333333333333333333333333333333',
 *   sponsorId: 0n,
 * })
 * console.log(access) // 'allowed', 'notListed', ...
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The pair, the taker, the sponsor id, the fee fields and the read options.
 * @returns The access check's outcome, by name.
 */
export async function takerAccess(
  client: AnyClient,
  parameters: takerAccess.Parameters,
): Promise<takerAccess.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const code = await readContract(client, {
    address: venue,
    abi: venueAbi,
    functionName: 'takerAccess',
    args: [
      validate.pairIndex(parameters.pairIndex),
      validate.address(parameters.taker, 'taker'),
      validate.sponsorId(parameters.sponsorId),
    ],
    ...readOptions(parameters),
    ...fees(parameters),
  } as never)
  return VenueReads.accessName(code)
}

export declare namespace takerAccess {
  /** The venue, the pair, the taker, the sponsor id, the fee fields and the read options. */
  type Parameters = ReadParameters &
    FeeParameters & {
      venue: Address
      pairIndex: number
      taker: Address
      sponsorId: bigint
    }
  /** The access check's outcome, by name. */
  type ReturnValue = TakerAccessName
  /** The errors `takerAccess` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadContractErrorType
    | UnexpectedResponseErrorType
    | GlobalErrorType
}

/**
 * Exactly `takerAccess(...) === 'allowed'`.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const allowed = await Info.takerAllowed(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairIndex: 0,
 *   taker: '0x3333333333333333333333333333333333333333',
 *   sponsorId: 42n,
 * })
 * console.log(allowed)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - As {@link takerAccess} takes them.
 * @returns Whether the taker may fill.
 */
export async function takerAllowed(
  client: AnyClient,
  parameters: takerAllowed.Parameters,
): Promise<takerAllowed.ReturnValue> {
  return (await takerAccess(client, parameters)) === 'allowed'
}

export declare namespace takerAllowed {
  /** As {@link takerAccess} takes them. */
  type Parameters = takerAccess.Parameters
  /** Whether the taker may fill. */
  type ReturnValue = boolean
  /** The errors `takerAllowed` throws. */
  type ErrorType = takerAccess.ErrorType
}

/**
 * A decoded `Fill` with its log (block, transaction, index, and `removed` for reorg handling).
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const fills: Info.Fill[] = await Info.fills(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   fromBlock: 1_000n,
 *   toBlock: 2_000n,
 * })
 * console.log(fills.map((f) => [f.amountIn, f.amountOut, f.log.transactionHash]))
 * ```
 */
export type Fill = {
  pairIndex: number
  taker: Address
  ref: Hex
  sponsorId: bigint
  baseIn: boolean
  amountIn: bigint
  amountOut: bigint
  makerMid: bigint
  /** the hot word's sequence the fill priced against (the event's `seq`) */
  sequence: number
  log: Log
}

/**
 * The venue's `Fill` logs in a bounded block range, optionally for one pair. Callers own pagination, confirmations and
 * reorg handling. Malformed Fill logs from the venue reject the entire page; they are never silently omitted.
 *
 * @example
 * ```ts
 * import { Info } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const fills = await Info.fills(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   fromBlock: 1_000n,
 *   toBlock: 2_000n,
 *   pairIndex: 0,
 * })
 * console.log(fills.length)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, the inclusive block range and an optional pair.
 * @returns The fills, in log order.
 */
export async function fills(
  client: AnyClient,
  parameters: fills.Parameters,
): Promise<fills.ReturnValue> {
  const venue = contract(parameters.venue, 'venue')
  const fromBlock = validate.uintBigint(parameters.fromBlock, 64, 'fromBlock')
  const toBlock = validate.uintBigint(parameters.toBlock, 64, 'toBlock')
  if (fromBlock > toBlock)
    throw new InvalidArgumentError('fromBlock is after toBlock', {
      parameter: 'fromBlock',
      value: fromBlock,
    })
  const pairIndex =
    parameters.pairIndex === undefined
      ? undefined
      : validate.pairIndex(parameters.pairIndex)
  const fillEvent = getAbiItem({ abi: venueAbi, name: 'Fill' })
  const dataInputs = fillEvent.inputs.filter((input) => !input.indexed)
  const topics = encodeEventTopics({
    abi: venueAbi,
    eventName: 'Fill',
    args: pairIndex === undefined ? undefined : { pairIndex },
  })
  // getLogs(event) calls parseEventLogs internally and can discard malformed
  // recognized logs before we see them. Request the filtered raw wire page.
  const logs = await client.request({
    method: 'eth_getLogs',
    params: [
      {
        address: venue,
        topics,
        fromBlock: numberToHex(fromBlock),
        toBlock: numberToHex(toBlock),
      },
    ],
  })
  const fills: Fill[] = []
  for (const raw of logs) {
    if (
      raw.address.toLowerCase() !== venue.toLowerCase() ||
      raw.topics[0]?.toLowerCase() !== topics[0]?.toLowerCase()
    )
      continue
    const event = decodeEventLog({
      abi: venueAbi,
      eventName: 'Fill',
      data: raw.data,
      topics: [topics[0] as Hex, ...raw.topics.slice(1)],
      strict: true,
    })
    const args = event.args
    // viem's strict decoder does not enforce all ABI widths, padding or trailing
    // bytes. Round-trip every word to accept only the canonical Fill encoding.
    const canonicalTopics = encodeEventTopics({
      abi: venueAbi,
      eventName: 'Fill',
      args,
    })
    const canonicalData = encodeAbiParameters(
      dataInputs,
      dataInputs.map((input) => args[input.name]),
    )
    if (
      raw.data.toLowerCase() !== canonicalData.toLowerCase() ||
      raw.topics.length !== canonicalTopics.length ||
      raw.topics.some(
        (topic, i) =>
          topic.toLowerCase() !==
          (canonicalTopics[i] as Hex | undefined)?.toLowerCase(),
      )
    )
      throw new UnexpectedResponseError('Fill log is not canonically encoded', {
        value: raw,
      })
    if (pairIndex !== undefined && args.pairIndex !== pairIndex) continue
    const { seq, ...rest } = args
    const log = { ...formatLog(raw), ...event }
    fills.push({ ...rest, sequence: seq, log })
  }
  return fills
}

export declare namespace fills {
  /** The venue, the inclusive block range and an optional pair. */
  type Parameters = {
    venue: Address
    fromBlock: bigint
    toBlock: bigint
    pairIndex?: number | undefined
  }
  /** The fills, in log order. */
  type ReturnValue = Fill[]
  /** The errors `fills` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | GetLogsErrorType
    | DecodeEventLogErrorType
    | EncodeAbiParametersErrorType
    | EncodeEventTopicsErrorType
    | UnexpectedResponseErrorType
    | GlobalErrorType
}

/** The fee fields given, each checked as a `uint256`. */
const fees = (p: FeeParameters) => validate.fees(p)
