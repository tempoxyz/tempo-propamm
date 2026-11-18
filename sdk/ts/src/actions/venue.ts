// Every venue write, as the Rust SDK's `Actions` names it where it has one and as the contract names it otherwise, with
// the role that may send it (IVenue's role NatSpec). An agent is the venue's updater. Each write has viem/tempo's
// anatomy: the action sends, `<name>Sync` waits for the receipt and returns its event result, and its namespace holds
// `call` (for a Tempo `calls` batch, `Plan.simulate` or viem's `simulateContract`) and `extractEvent`. Batches are
// atomic and never split.
import {
  type Account,
  type Address,
  type Chain,
  type Client,
  type Hex,
  isAddressEqual,
  type Log,
  type Transport,
  toEventSelector,
  type WriteContractErrorType,
  type WriteContractReturnType,
  type WriteContractSyncErrorType,
  zeroAddress,
  zeroHash,
} from 'viem'
import { writeContract } from 'viem/actions'
import { venueAbi, venueFactoryAbi } from '../generated/abis.js'
import { Venue, VenueHookFlags } from '../generated/constants.js'
import { AccessMode, type AccessModeName } from '../generated/enums.js'
import {
  AmountOutOfRangeError,
  type AmountOutOfRangeErrorType,
  BatchTooLargeError,
  type BatchTooLargeErrorType,
  type DuplicatePairErrorType,
  EmptyBatchError,
  type EmptyBatchErrorType,
  type GlobalErrorType,
  InvalidAddressError,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  type InvalidHotWordErrorType,
  type InvalidPriceErrorType,
  type InvalidShapeErrorType,
  show,
  UnexpectedResponseError,
  type UnexpectedResponseErrorType,
} from '../internal/errors.js'
import { type ReadManyErrorType, readOf, readValues } from '../internal/read.js'
import * as validate from '../internal/validate.js'
import * as VenueReads from '../internal/venue.js'
import * as Post from '../Post.js'
import * as Shape from '../Shape.js'
import { type VenueAbi, type VenueCall, venueCall } from './internal/abis.js'
import {
  type EventArgs,
  type EventLog,
  type ExtractEventOptions,
  extractEvent as extractLog,
  extractEvents as extractLogs,
  type SignerRole,
  type SyncReturnValue,
  send,
  sendSync,
  type WriteParameters,
  type WriteSyncParameters,
} from './internal/define.js'
import { type PostSyncReturnValue, sendPost } from './internal/post.js'

const owner: SignerRole = { role: 'owner' }
const ownerOrAgent: SignerRole = { role: 'ownerOrAgent' }
const maxBatch = Number(Venue.maxBatch)
const modes = {
  closed: AccessMode.Closed,
  listed: AccessMode.Listed,
  open: AccessMode.Open,
} as const

const target = (args: { venue: Address }) =>
  validate.address(args.venue, 'venue', { nonzero: true })

/**
 * An eventless successful write is a no-op only on a venue. Check the immutable factory relationship, not mutable
 * end-of-block access state: a later transaction in the same block may already have changed that state again.
 * `venue` is the validated call's checksummed address. This rejects codeless targets and ordinary fallback contracts;
 * callers still choose a trusted deployment (Info.isVenue with their verified factory), as for every SDK action.
 */
async function confirmEventlessVenue(
  client: Client,
  venue: Address,
  blockNumber: bigint,
): Promise<void> {
  const [factory] = await readValues(
    client,
    [VenueReads.read(venue, 'factory', undefined)],
    { blockNumber },
  )
  const [isVenue] = await readValues(
    client,
    [readOf(factory, venueFactoryAbi, 'isVenue', [venue])],
    { blockNumber },
  )
  if (!isVenue)
    throw new UnexpectedResponseError(
      'missing access event from an address its factory does not recognize as a venue',
      { value: venue },
    )
}

/** Rejects matching malformed receipt events before an access write can be classified as a no-op. */
function accessReceiptEvents<
  name extends 'UpdaterSet' | 'DenyUpdated' | 'HaltedSet',
>(
  name: name,
  logs: readonly Log[],
  options: ExtractEventOptions,
): EventLog<VenueAbi, name>[] {
  const normalized = logs.map((log) => ({
    ...log,
    topics: log.topics.map((topic) => topic.toLowerCase()) as typeof log.topics,
  }))
  const events = extractLogs(venueAbi, name, normalized, options)
  const signatures = {
    UpdaterSet: 'UpdaterSet(address,bool)',
    DenyUpdated: 'DenyUpdated(address,bool,address)',
    HaltedSet: 'HaltedSet(bool)',
  } as const
  const matching = normalized.filter(
    (log) =>
      log.topics[0] === toEventSelector(signatures[name]) &&
      (options.address === undefined ||
        isAddressEqual(log.address, options.address)),
  )
  // Strict parsing filters undecodable logs; their absence is not proof of a no-op.
  if (matching.length !== events.length)
    throw new UnexpectedResponseError(
      `receipt contains an undecodable ${name} event`,
      { value: options.address },
    )
  return events
}

/**
 * A member or deny batch: 1 to `Venue.maxBatch` accounts, none zero or the venue itself (`InvalidAddress` onchain), and,
 * when `adding` (listing or denying), none a TIP-1022 virtual address, which never calls a fill: listing or denying it
 * admits or blocks nobody. Removing one stays accepted, for cleanup.
 */
function batch(
  accounts: readonly Address[],
  venue: Address,
  adding: boolean,
): Address[] {
  if (!Array.isArray(accounts))
    throw new InvalidArgumentError('accounts must be an array', {
      parameter: 'accounts',
      value: accounts,
    })
  if (accounts.length === 0)
    throw new EmptyBatchError('an account batch needs at least one account')
  if (accounts.length > maxBatch)
    throw new BatchTooLargeError(
      `${accounts.length} accounts is above the venue's MAX_BATCH of ${maxBatch}: split them`,
      { size: accounts.length, maxSize: maxBatch },
    )
  return accounts.map((account, i) => {
    const name = `accounts[${i}]`
    const checked = notVenue(
      validate.address(account, name, { nonzero: true }),
      venue,
      name,
    )
    return adding
      ? validate.notVirtual(
          checked,
          name,
          'which never calls a fill: adding it admits or blocks nobody',
        )
      : checked
  })
}

/** Refuses the venue's own address where the venue does (`InvalidAddress` onchain). */
function notVenue(account: Address, venue: Address, name: string): Address {
  if (isAddressEqual(account, venue))
    throw new InvalidAddressError(`${name} ${account} is the venue itself`, {
      parameter: name,
      address: account,
    })
  return account
}

/**
 * Adds a pair, `Closed`, with `sizeUnit` base units per shape size step (owner). Both tokens must be distinct,
 * initialized Tempo TIP-20s recognized by the canonical TIP-20 factory; code alone is not enough
 * (`InvalidPairTokens`). Their decimals must match (`DecimalsMismatch`). These checks run onchain.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.addPair(client, {
 *   venue: '0x...',
 *   base: '0x20C0000000000000000000000000000000000001',
 *   quote: '0x20c0000000000000000000000000000000000002',
 *   sizeUnit: 1_000_000n,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function addPair<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: addPair.Parameters<chain, account>,
): Promise<addPair.ReturnValue> {
  return send(writeContract, client, parameters, addPair.call(parameters))
}

export namespace addPair {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The base token. */
    base: Address
    /** The quote token, not the base. */
    quote: Address
    /** Base atoms per shape size step: a nonzero `uint64`. */
    sizeUnit: bigint
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `addPair` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'addPair'> {
    const venue = target(args)
    const base = validate.address(args.base, 'base', { nonzero: true })
    const quote = validate.address(args.quote, 'quote', { nonzero: true })
    if (isAddressEqual(base, quote))
      throw new InvalidArgumentError('a pair needs two different tokens', {
        parameter: 'quote',
        value: quote,
      })
    const sizeUnit = validate.uintBigint(args.sizeUnit, 64, 'sizeUnit')
    if (sizeUnit === 0n)
      throw new InvalidArgumentError('sizeUnit must be nonzero', {
        parameter: 'sizeUnit',
        value: sizeUnit,
      })
    return venueCall({
      venue,
      functionName: 'addPair',
      args: [base, quote, sizeUnit],
      signer: owner,
    })
  }

  /**
   * Extracts the `PairAdded` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `PairAdded` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'PairAdded'> {
    return extractLog(venueAbi, 'PairAdded', logs, options)
  }
}

/**
 * Adds a pair, `Closed`, with `sizeUnit` base units per shape size step (owner). Both tokens must be distinct,
 * initialized Tempo TIP-20s recognized by the canonical TIP-20 factory; code alone is not enough
 * (`InvalidPairTokens`). Their decimals must match (`DecimalsMismatch`). These checks run onchain.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.addPairSync(client, {
 *   venue: '0x...',
 *   base: '0x20C0000000000000000000000000000000000001',
 *   quote: '0x20c0000000000000000000000000000000000002',
 *   sizeUnit: 1_000_000n,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.pairIndex)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `PairAdded` event's arguments and the receipt.
 */
export async function addPairSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: addPairSync.Parameters<chain, account>,
): Promise<addPairSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    addPair.call(parameters),
    (logs, options) => addPair.extractEvent(logs, options).args,
  )
}

export namespace addPairSync {
  /** The call's arguments. */
  export type Args = addPair.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = addPair.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** The `PairAdded` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'PairAdded'>>

  /** `addPair`'s errors, and viem's receipt errors. */
  export type ErrorType = addPair.ErrorType | WriteContractSyncErrorType
}

/**
 * Removes a pair for good; its index is never reused (owner). Delete its shapes first to earn their storage
 * credits.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.removePair(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function removePair<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: removePair.Parameters<chain, account>,
): Promise<removePair.ReturnValue> {
  return send(writeContract, client, parameters, removePair.call(parameters))
}

export namespace removePair {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `removePair` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'removePair'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'removePair',
      args: [validate.pairIndex(args.pairIndex)],
      signer: owner,
    })
  }

  /**
   * Extracts the `PairRemoved` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `PairRemoved` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'PairRemoved'> {
    return extractLog(venueAbi, 'PairRemoved', logs, options)
  }
}

/**
 * Removes a pair for good; its index is never reused (owner). Delete its shapes first to earn their storage
 * credits.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.removePairSync(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.pairIndex)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `PairRemoved` event's arguments and the receipt.
 */
export async function removePairSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: removePairSync.Parameters<chain, account>,
): Promise<removePairSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    removePair.call(parameters),
    (logs, options) => removePair.extractEvent(logs, options).args,
  )
}

export namespace removePairSync {
  /** The call's arguments. */
  export type Args = removePair.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = removePair.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `PairRemoved` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'PairRemoved'>>

  /** `removePair`'s errors, and viem's receipt errors. */
  export type ErrorType = removePair.ErrorType | WriteContractSyncErrorType
}

/**
 * Sets who may trade a pair (owner). Entering `open` requires a halted venue. Reopening re-arms the stored hot
 * word: post a fresh one first.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setPairAccess(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   mode: 'listed',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setPairAccess<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setPairAccess.Parameters<chain, account>,
): Promise<setPairAccess.ReturnValue> {
  return send(writeContract, client, parameters, setPairAccess.call(parameters))
}

export namespace setPairAccess {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
    /** Who may trade: no one, the named lists, or everyone not denied (`Info.Market`'s `access`). */
    mode: Exclude<AccessModeName, 'none'>
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setPairAccess` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setPairAccess'> {
    const venue = target(args)
    // `Object.hasOwn`, so a prototype key such as 'toString' is no mode.
    if (typeof args.mode !== 'string' || !Object.hasOwn(modes, args.mode))
      throw new InvalidArgumentError(
        `mode must be 'closed', 'listed' or 'open', got ${show(args.mode)}`,
        { parameter: 'mode', value: args.mode },
      )
    return venueCall({
      venue,
      functionName: 'setPairAccess',
      args: [validate.pairIndex(args.pairIndex), modes[args.mode]],
      signer: owner,
    })
  }

  /**
   * Extracts the `PairAccessUpdated` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `PairAccessUpdated` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'PairAccessUpdated'> {
    return extractLog(venueAbi, 'PairAccessUpdated', logs, options)
  }
}

/**
 * Sets who may trade a pair (owner). Entering `open` requires a halted venue. Reopening re-arms the stored hot
 * word: post a fresh one first.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setPairAccessSync(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   mode: 'listed',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.newMode)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `PairAccessUpdated` event's arguments and the receipt.
 */
export async function setPairAccessSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setPairAccessSync.Parameters<chain, account>,
): Promise<setPairAccessSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setPairAccess.call(parameters),
    (logs, options) => setPairAccess.extractEvent(logs, options).args,
  )
}

export namespace setPairAccessSync {
  /** The call's arguments. */
  export type Args = setPairAccess.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setPairAccess.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `PairAccessUpdated` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'PairAccessUpdated'>
  >

  /** `setPairAccess`'s errors, and viem's receipt errors. */
  export type ErrorType = setPairAccess.ErrorType | WriteContractSyncErrorType
}

/**
 * Closes a pair to every taker (owner or agent). Only the owner reopens it.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.closePair(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function closePair<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: closePair.Parameters<chain, account>,
): Promise<closePair.ReturnValue> {
  return send(writeContract, client, parameters, closePair.call(parameters))
}

export namespace closePair {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `closePair` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'closePair'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'closePair',
      args: [validate.pairIndex(args.pairIndex)],
      signer: ownerOrAgent,
    })
  }

  /**
   * Extracts the `PairAccessUpdated` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `PairAccessUpdated` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'PairAccessUpdated'> {
    return extractLog(venueAbi, 'PairAccessUpdated', logs, options)
  }
}

/**
 * Closes a pair to every taker (owner or agent). Only the owner reopens it.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.closePairSync(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.oldMode)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `PairAccessUpdated` event's arguments and the receipt.
 */
export async function closePairSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: closePairSync.Parameters<chain, account>,
): Promise<closePairSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    closePair.call(parameters),
    (logs, options) => closePair.extractEvent(logs, options).args,
  )
}

export namespace closePairSync {
  /** The call's arguments. */
  export type Args = closePair.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = closePair.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** The `PairAccessUpdated` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'PairAccessUpdated'>
  >

  /** `closePair`'s errors, and viem's receipt errors. */
  export type ErrorType = closePair.ErrorType | WriteContractSyncErrorType
}

/**
 * Resets a halted pair to its initial, unfillable hot word (owner), preserving consumed depth and configuration.
 * Follow the README's reset recovery protocol: fence old writers, durable writes and executable posts first
 * (halt does not block posts). Confirm the reset separately, then atomically transition this pair's durable
 * application generation and floor, rejecting old-generation writes. Recreate the sequencer from current-generation
 * reset state, post a fresh quote and only then resume. `Sequencer.observe` never lowers an existing counter;
 * neither SDK nor contract provides a reset epoch. Retrying the durable transition must not erase later allocations.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.resetHotWord(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function resetHotWord<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: resetHotWord.Parameters<chain, account>,
): Promise<resetHotWord.ReturnValue> {
  return send(writeContract, client, parameters, resetHotWord.call(parameters))
}

export namespace resetHotWord {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `resetHotWord` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'resetHotWord'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'resetHotWord',
      args: [validate.pairIndex(args.pairIndex)],
      signer: owner,
    })
  }

  /**
   * Extracts the `HotWordReset` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `HotWordReset` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'HotWordReset'> {
    return extractLog(venueAbi, 'HotWordReset', logs, options)
  }
}

/**
 * Resets a halted pair to its initial, unfillable hot word (owner), preserving consumed depth and configuration.
 * Follow the README's reset recovery protocol: fence old writers, durable writes and executable posts first
 * (halt does not block posts). Confirm the reset separately, then atomically transition this pair's durable
 * application generation and floor, rejecting old-generation writes. Recreate the sequencer from current-generation
 * reset state, post a fresh quote and only then resume. `Sequencer.observe` never lowers an existing counter;
 * neither SDK nor contract provides a reset epoch. Retrying the durable transition must not erase later allocations.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.resetHotWordSync(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.previousSeq)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `HotWordReset` event's arguments and the receipt.
 */
export async function resetHotWordSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: resetHotWordSync.Parameters<chain, account>,
): Promise<resetHotWordSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    resetHotWord.call(parameters),
    (logs, options) => resetHotWord.extractEvent(logs, options).args,
  )
}

export namespace resetHotWordSync {
  /** The call's arguments. */
  export type Args = resetHotWord.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = resetHotWord.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `HotWordReset` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'HotWordReset'>>

  /** `resetHotWord`'s errors, and viem's receipt errors. */
  export type ErrorType = resetHotWord.ErrorType | WriteContractSyncErrorType
}

/**
 * Registers a sponsor under a nonzero id the owner chooses, with `admin` as the only key that lists its users
 * (owner). It starts enabled and admitted on no pair.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.addSponsor(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   admin: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function addSponsor<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: addSponsor.Parameters<chain, account>,
): Promise<addSponsor.ReturnValue> {
  return send(writeContract, client, parameters, addSponsor.call(parameters))
}

export namespace addSponsor {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The sponsor id: a nonzero `uint64`, never reused. */
    sponsorId: bigint
    /** The key that alone edits the sponsor's lists: not zero, the venue or a TIP-1022 virtual address. */
    admin: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `addSponsor` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'addSponsor'> {
    const venue = target(args)
    const sponsorId = validate.sponsorId(args.sponsorId)
    if (sponsorId === 0n)
      throw new InvalidArgumentError(
        'sponsor id 0 is the home list, never a registered sponsor',
        { parameter: 'sponsorId', value: sponsorId },
      )
    const admin = validate.notVirtual(
      notVenue(
        validate.address(args.admin, 'admin', { nonzero: true }),
        venue,
        'admin',
      ),
      'admin',
      'which never sends a call',
    )
    return venueCall({
      venue,
      functionName: 'addSponsor',
      args: [sponsorId, admin],
      signer: owner,
    })
  }

  /**
   * Extracts the `SponsorAdded` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `SponsorAdded` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'SponsorAdded'> {
    return extractLog(venueAbi, 'SponsorAdded', logs, options)
  }
}

/**
 * Registers a sponsor under a nonzero id the owner chooses, with `admin` as the only key that lists its users
 * (owner). It starts enabled and admitted on no pair.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.addSponsorSync(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   admin: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.admin)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `SponsorAdded` event's arguments and the receipt.
 */
export async function addSponsorSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: addSponsorSync.Parameters<chain, account>,
): Promise<addSponsorSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    addSponsor.call(parameters),
    (logs, options) => addSponsor.extractEvent(logs, options).args,
  )
}

export namespace addSponsorSync {
  /** The call's arguments. */
  export type Args = addSponsor.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = addSponsor.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `SponsorAdded` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'SponsorAdded'>>

  /** `addSponsor`'s errors, and viem's receipt errors. */
  export type ErrorType = addSponsor.ErrorType | WriteContractSyncErrorType
}

/**
 * Switches a sponsor on (owner) or off (owner or agent) venue-wide. Its lists and admissions are kept.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setSponsorEnabled(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   enabled: false,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setSponsorEnabled<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setSponsorEnabled.Parameters<chain, account>,
): Promise<setSponsorEnabled.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    setSponsorEnabled.call(parameters),
  )
}

export namespace setSponsorEnabled {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The sponsor id. */
    sponsorId: bigint
    /** `true` switches it on, `false` off. */
    enabled: boolean
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setSponsorEnabled` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setSponsorEnabled'> {
    const venue = target(args)
    const enabled = validate.bool(args.enabled, 'enabled')
    return venueCall({
      venue,
      functionName: 'setSponsorEnabled',
      args: [validate.sponsorId(args.sponsorId), enabled],
      signer: enabled ? owner : ownerOrAgent,
    })
  }

  /**
   * Extracts the `SponsorEnabledSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `SponsorEnabledSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'SponsorEnabledSet'> {
    return extractLog(venueAbi, 'SponsorEnabledSet', logs, options)
  }
}

/**
 * Switches a sponsor on (owner) or off (owner or agent) venue-wide. Its lists and admissions are kept.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setSponsorEnabledSync(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   enabled: false,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.enabled)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `SponsorEnabledSet` event's arguments and the receipt.
 */
export async function setSponsorEnabledSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setSponsorEnabledSync.Parameters<chain, account>,
): Promise<setSponsorEnabledSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setSponsorEnabled.call(parameters),
    (logs, options) => setSponsorEnabled.extractEvent(logs, options).args,
  )
}

export namespace setSponsorEnabledSync {
  /** The call's arguments. */
  export type Args = setSponsorEnabled.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setSponsorEnabled.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `SponsorEnabledSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'SponsorEnabledSet'>
  >

  /** `setSponsorEnabled`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | setSponsorEnabled.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Admits a sponsor on a pair (owner) or removes it (owner or agent). Removal keeps its list there.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setPairSponsor(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   sponsorId: 42n,
 *   admitted: true,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setPairSponsor<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setPairSponsor.Parameters<chain, account>,
): Promise<setPairSponsor.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    setPairSponsor.call(parameters),
  )
}

export namespace setPairSponsor {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
    /** The sponsor id. */
    sponsorId: bigint
    /** `true` admits it, `false` removes it. */
    admitted: boolean
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setPairSponsor` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setPairSponsor'> {
    const venue = target(args)
    const admitted = validate.bool(args.admitted, 'admitted')
    return venueCall({
      venue,
      functionName: 'setPairSponsor',
      args: [
        validate.pairIndex(args.pairIndex),
        validate.sponsorId(args.sponsorId),
        admitted,
      ],
      signer: admitted ? owner : ownerOrAgent,
    })
  }

  /**
   * Extracts the `PairSponsorSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `PairSponsorSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'PairSponsorSet'> {
    return extractLog(venueAbi, 'PairSponsorSet', logs, options)
  }
}

/**
 * Admits a sponsor on a pair (owner) or removes it (owner or agent). Removal keeps its list there.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setPairSponsorSync(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   sponsorId: 42n,
 *   admitted: true,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.admitted)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `PairSponsorSet` event's arguments and the receipt.
 */
export async function setPairSponsorSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setPairSponsorSync.Parameters<chain, account>,
): Promise<setPairSponsorSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setPairSponsor.call(parameters),
    (logs, options) => setPairSponsor.extractEvent(logs, options).args,
  )
}

export namespace setPairSponsorSync {
  /** The call's arguments. */
  export type Args = setPairSponsor.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setPairSponsor.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `PairSponsorSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'PairSponsorSet'>
  >

  /** `setPairSponsor`'s errors, and viem's receipt errors. */
  export type ErrorType = setPairSponsor.ErrorType | WriteContractSyncErrorType
}

/**
 * Lists (`allowed`) or delists accounts on a pair under a sponsor id: the owner edits the home list (0), a
 * sponsor's admin alone edits its own. One atomic batch of 1 to `Venue.maxBatch` accounts, never split.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setMembers(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   sponsorId: 42n,
 *   accounts: ['0x...'],
 *   allowed: true,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setMembers<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setMembers.Parameters<chain, account>,
): Promise<setMembers.ReturnValue> {
  return send(writeContract, client, parameters, setMembers.call(parameters))
}

export namespace setMembers {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
    /** The sponsor id: 0 is the home list. */
    sponsorId: bigint
    /** 1 to `Venue.maxBatch` accounts, none zero or the venue. */
    accounts: readonly Address[]
    /** `true` lists them, `false` delists them. */
    allowed: boolean
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | BatchTooLargeErrorType
    | EmptyBatchErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setMembers` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setMembers'> {
    const venue = target(args)
    const sponsorId = validate.sponsorId(args.sponsorId)
    const allowed = validate.bool(args.allowed, 'allowed')
    return venueCall({
      venue,
      functionName: 'setMembers',
      args: [
        validate.pairIndex(args.pairIndex),
        sponsorId,
        batch(args.accounts, venue, allowed),
        allowed,
      ],
      signer: sponsorId === 0n ? owner : { role: 'sponsorAdmin', sponsorId },
    })
  }

  /**
   * Extracts the `MemberUpdated` events from logs, one per account.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `MemberUpdated` events.
   */
  export function extractEvents(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'MemberUpdated'>[] {
    const events = extractLogs(venueAbi, 'MemberUpdated', logs, options)
    if (events.length === 0)
      throw new InvalidArgumentError('the logs hold no `MemberUpdated` event', {
        parameter: 'logs',
      })
    return events
  }
}

/**
 * Lists (`allowed`) or delists accounts on a pair under a sponsor id: the owner edits the home list (0), a
 * sponsor's admin alone edits its own. One atomic batch of 1 to `Venue.maxBatch` accounts, never split.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setMembersSync(client, {
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
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns Each `MemberUpdated` event's arguments, in order, and the receipt.
 */
export async function setMembersSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setMembersSync.Parameters<chain, account>,
): Promise<setMembersSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setMembers.call(parameters),
    (logs, options) => ({
      updates: setMembers
        .extractEvents(logs, options)
        .map((event) => event.args),
    }),
  )
}

export namespace setMembersSync {
  /** The call's arguments. */
  export type Args = setMembers.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setMembers.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** Each `MemberUpdated` event's arguments, in order, and the receipt. */
  export type ReturnValue = SyncReturnValue<{
    /** Each `MemberUpdated` event's arguments, in order. */
    updates: EventArgs<VenueAbi, 'MemberUpdated'>[]
  }>

  /** `setMembers`'s errors, and viem's receipt errors. */
  export type ErrorType = setMembers.ErrorType | WriteContractSyncErrorType
}

/**
 * Starts handing a sponsor's lists to `newAdmin`, who must accept (sponsor admin).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.transferSponsorAdmin(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   newAdmin: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function transferSponsorAdmin<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: transferSponsorAdmin.Parameters<chain, account>,
): Promise<transferSponsorAdmin.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    transferSponsorAdmin.call(parameters),
  )
}

export namespace transferSponsorAdmin {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The sponsor id. */
    sponsorId: bigint
    /** The successor: not zero, the venue or a TIP-1022 virtual address. */
    newAdmin: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `transferSponsorAdmin` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'transferSponsorAdmin'> {
    const venue = target(args)
    const sponsorId = validate.sponsorId(args.sponsorId)
    const newAdmin = validate.notVirtual(
      notVenue(
        validate.address(args.newAdmin, 'newAdmin', { nonzero: true }),
        venue,
        'newAdmin',
      ),
      'newAdmin',
      'which could never accept',
    )
    return venueCall({
      venue,
      functionName: 'transferSponsorAdmin',
      args: [sponsorId, newAdmin],
      signer: { role: 'sponsorAdmin', sponsorId },
    })
  }

  /**
   * Extracts the `SponsorAdminTransferStarted` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `SponsorAdminTransferStarted` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'SponsorAdminTransferStarted'> {
    return extractLog(venueAbi, 'SponsorAdminTransferStarted', logs, options)
  }
}

/**
 * Starts handing a sponsor's lists to `newAdmin`, who must accept (sponsor admin).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.transferSponsorAdminSync(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   newAdmin: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.pendingAdmin)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `SponsorAdminTransferStarted` event's arguments and the receipt.
 */
export async function transferSponsorAdminSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: transferSponsorAdminSync.Parameters<chain, account>,
): Promise<transferSponsorAdminSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    transferSponsorAdmin.call(parameters),
    (logs, options) => transferSponsorAdmin.extractEvent(logs, options).args,
  )
}

export namespace transferSponsorAdminSync {
  /** The call's arguments. */
  export type Args = transferSponsorAdmin.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = transferSponsorAdmin.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `SponsorAdminTransferStarted` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'SponsorAdminTransferStarted'>
  >

  /** `transferSponsorAdmin`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | transferSponsorAdmin.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Cancels a pending sponsor-admin transfer without changing the sponsor's current admin (sponsor admin). Safe to
 * repeat.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.cancelSponsorAdminTransfer(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function cancelSponsorAdminTransfer<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancelSponsorAdminTransfer.Parameters<chain, account>,
): Promise<cancelSponsorAdminTransfer.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    cancelSponsorAdminTransfer.call(parameters),
  )
}

export namespace cancelSponsorAdminTransfer {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The sponsor id. */
    sponsorId: bigint
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `cancelSponsorAdminTransfer` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'cancelSponsorAdminTransfer'> {
    const venue = target(args)
    const sponsorId = validate.sponsorId(args.sponsorId)
    return venueCall({
      venue,
      functionName: 'cancelSponsorAdminTransfer',
      args: [sponsorId],
      signer: { role: 'sponsorAdmin', sponsorId },
    })
  }

  /**
   * Extracts the `SponsorAdminTransferStarted` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `SponsorAdminTransferStarted` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'SponsorAdminTransferStarted'> {
    return extractLog(venueAbi, 'SponsorAdminTransferStarted', logs, options)
  }
}

/**
 * Cancels a pending sponsor-admin transfer without changing the sponsor's current admin (sponsor admin). Safe to
 * repeat.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.cancelSponsorAdminTransferSync(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.pendingAdmin)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `SponsorAdminTransferStarted` event's arguments and the receipt.
 */
export async function cancelSponsorAdminTransferSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancelSponsorAdminTransferSync.Parameters<chain, account>,
): Promise<cancelSponsorAdminTransferSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    cancelSponsorAdminTransfer.call(parameters),
    (logs, options) =>
      cancelSponsorAdminTransfer.extractEvent(logs, options).args,
  )
}

export namespace cancelSponsorAdminTransferSync {
  /** The call's arguments. */
  export type Args = cancelSponsorAdminTransfer.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = cancelSponsorAdminTransfer.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `SponsorAdminTransferStarted` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'SponsorAdminTransferStarted'>
  >

  /** `cancelSponsorAdminTransfer`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | cancelSponsorAdminTransfer.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Takes over a sponsor's lists (pending sponsor admin).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.acceptSponsorAdmin(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function acceptSponsorAdmin<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: acceptSponsorAdmin.Parameters<chain, account>,
): Promise<acceptSponsorAdmin.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    acceptSponsorAdmin.call(parameters),
  )
}

export namespace acceptSponsorAdmin {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The sponsor id. */
    sponsorId: bigint
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `acceptSponsorAdmin` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'acceptSponsorAdmin'> {
    const venue = target(args)
    const sponsorId = validate.sponsorId(args.sponsorId)
    return venueCall({
      venue,
      functionName: 'acceptSponsorAdmin',
      args: [sponsorId],
      signer: { role: 'pendingSponsorAdmin', sponsorId },
    })
  }

  /**
   * Extracts the `SponsorAdminTransferred` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `SponsorAdminTransferred` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'SponsorAdminTransferred'> {
    return extractLog(venueAbi, 'SponsorAdminTransferred', logs, options)
  }
}

/**
 * Takes over a sponsor's lists (pending sponsor admin).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.acceptSponsorAdminSync(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.newAdmin)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `SponsorAdminTransferred` event's arguments and the receipt.
 */
export async function acceptSponsorAdminSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: acceptSponsorAdminSync.Parameters<chain, account>,
): Promise<acceptSponsorAdminSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    acceptSponsorAdmin.call(parameters),
    (logs, options) => acceptSponsorAdmin.extractEvent(logs, options).args,
  )
}

export namespace acceptSponsorAdminSync {
  /** The call's arguments. */
  export type Args = acceptSponsorAdmin.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = acceptSponsorAdmin.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `SponsorAdminTransferred` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'SponsorAdminTransferred'>
  >

  /** `acceptSponsorAdmin`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | acceptSponsorAdmin.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Gives a sponsor a new admin and voids every earlier listing under its id, at once and for good (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.resetSponsor(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   newAdmin: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function resetSponsor<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: resetSponsor.Parameters<chain, account>,
): Promise<resetSponsor.ReturnValue> {
  return send(writeContract, client, parameters, resetSponsor.call(parameters))
}

export namespace resetSponsor {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The sponsor id. */
    sponsorId: bigint
    /** The new admin: not zero, the venue or a TIP-1022 virtual address. */
    newAdmin: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `resetSponsor` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'resetSponsor'> {
    const venue = target(args)
    const sponsorId = validate.sponsorId(args.sponsorId)
    const newAdmin = validate.notVirtual(
      notVenue(
        validate.address(args.newAdmin, 'newAdmin', { nonzero: true }),
        venue,
        'newAdmin',
      ),
      'newAdmin',
      'which never sends a call',
    )
    return venueCall({
      venue,
      functionName: 'resetSponsor',
      args: [sponsorId, newAdmin],
      signer: owner,
    })
  }

  /**
   * Extracts the `SponsorReset` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `SponsorReset` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'SponsorReset'> {
    return extractLog(venueAbi, 'SponsorReset', logs, options)
  }
}

/**
 * Gives a sponsor a new admin and voids every earlier listing under its id, at once and for good (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.resetSponsorSync(client, {
 *   venue: '0x...',
 *   sponsorId: 42n,
 *   newAdmin: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.generation)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `SponsorReset` event's arguments and the receipt.
 */
export async function resetSponsorSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: resetSponsorSync.Parameters<chain, account>,
): Promise<resetSponsorSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    resetSponsor.call(parameters),
    (logs, options) => resetSponsor.extractEvent(logs, options).args,
  )
}

export namespace resetSponsorSync {
  /** The call's arguments. */
  export type Args = resetSponsor.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = resetSponsor.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `SponsorReset` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'SponsorReset'>>

  /** `resetSponsor`'s errors, and viem's receipt errors. */
  export type ErrorType = resetSponsor.ErrorType | WriteContractSyncErrorType
}

/**
 * Denies accounts (owner or agent) or lifts their denial (owner). A denial overrides every list and `open`. One
 * atomic batch of 1 to `Venue.maxBatch` accounts, never split.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setDenied(client, {
 *   venue: '0x...',
 *   accounts: ['0x...'],
 *   deny: true,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setDenied<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setDenied.Parameters<chain, account>,
): Promise<setDenied.ReturnValue> {
  return send(writeContract, client, parameters, setDenied.call(parameters))
}

export namespace setDenied {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** 1 to `Venue.maxBatch` accounts, none zero or the venue. */
    accounts: readonly Address[]
    /** `true` denies them, `false` lifts their denial. */
    deny: boolean
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | BatchTooLargeErrorType
    | EmptyBatchErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setDenied` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setDenied'> {
    const venue = target(args)
    const deny = validate.bool(args.deny, 'deny')
    return venueCall({
      venue,
      functionName: 'setDenied',
      args: [batch(args.accounts, venue, deny), deny],
      signer: deny ? ownerOrAgent : owner,
    })
  }

  /**
   * Extracts the `DenyUpdated` events from logs, one per account.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `DenyUpdated` events.
   */
  export function extractEvents(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'DenyUpdated'>[] {
    const events = extractLogs(venueAbi, 'DenyUpdated', logs, options)
    if (events.length === 0)
      throw new InvalidArgumentError('the logs hold no `DenyUpdated` event', {
        parameter: 'logs',
      })
    return events
  }
}

/**
 * Denies accounts (owner or agent) or lifts their denial (owner). A denial overrides every list and `open`. One
 * atomic batch of 1 to `Venue.maxBatch` accounts, never split.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setDeniedSync(client, {
 *   venue: '0x...',
 *   accounts: ['0x...'],
 *   deny: true,
 * })
 * // `updates` is empty when every requested denial already had this value.
 * if (result.status === 'success') console.log(result.updates)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns Each changed denial's `DenyUpdated` arguments, in order (possibly empty), and the receipt.
 */
export async function setDeniedSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setDeniedSync.Parameters<chain, account>,
): Promise<setDeniedSync.ReturnValue> {
  const call = setDenied.call(parameters)
  return sendSync(
    client,
    parameters,
    call,
    async (logs, options, blockNumber) => {
      const updates = accessReceiptEvents('DenyUpdated', logs, options).map(
        (event) => event.args,
      )
      const missing = call.args[0].filter(
        (account) =>
          !updates.some((update) => isAddressEqual(update.account, account)),
      )
      if (missing.length)
        await confirmEventlessVenue(client, call.address, blockNumber)
      return { updates }
    },
  )
}

export namespace setDeniedSync {
  /** The call's arguments. */
  export type Args = setDenied.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setDenied.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** Each changed denial's `DenyUpdated` arguments, in order (possibly empty), and the receipt. */
  export type ReturnValue = SyncReturnValue<{
    /** Each changed denial's `DenyUpdated` arguments, in order; empty when every entry was already set. */
    updates: EventArgs<VenueAbi, 'DenyUpdated'>[]
  }>

  /** `setDenied`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | setDenied.ErrorType
    | WriteContractSyncErrorType
    | ReadManyErrorType
    | UnexpectedResponseErrorType
}

/**
 * Installs, replaces or removes (`hook` zero, `flags` 0) a pair's hook (owner).
 *
 * @example
 * ```ts
 * import { Actions, VenueHookFlags } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setPairHook(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   hook: '0x...',
 *   flags: VenueHookFlags.beforeFill,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setPairHook<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setPairHook.Parameters<chain, account>,
): Promise<setPairHook.ReturnValue> {
  return send(writeContract, client, parameters, setPairHook.call(parameters))
}

export namespace setPairHook {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
    /** The hook, or zero to remove it. */
    hook: Address
    /** The `VenueHookFlags` it runs with: 0 exactly when `hook` is zero, and `takeInput` only with `afterFill`. */
    flags: number
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setPairHook` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setPairHook'> {
    const venue = target(args)
    const hook = validate.address(args.hook, 'hook')
    const flags = validate.uintNumber(args.flags, 8, 'flags')
    const removing = isAddressEqual(hook, zeroAddress)
    const incoherent =
      (flags & ~VenueHookFlags.all) !== 0 ||
      ((flags & VenueHookFlags.takeInput) !== 0 &&
        (flags & VenueHookFlags.afterFill) === 0) ||
      removing !== (flags === 0)
    if (incoherent)
      throw new InvalidArgumentError(
        `hook flags ${flags} don't fit hook ${hook} (InvalidHookFlags onchain)`,
        { parameter: 'flags', value: flags },
      )
    return venueCall({
      venue,
      functionName: 'setPairHook',
      args: [validate.pairIndex(args.pairIndex), hook, flags],
      signer: owner,
    })
  }

  /**
   * Extracts the `PairHookSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `PairHookSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'PairHookSet'> {
    return extractLog(venueAbi, 'PairHookSet', logs, options)
  }
}

/**
 * Installs, replaces or removes (`hook` zero, `flags` 0) a pair's hook (owner).
 *
 * @example
 * ```ts
 * import { Actions, VenueHookFlags } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setPairHookSync(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   hook: '0x...',
 *   flags: VenueHookFlags.beforeFill,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.hook, result.flags)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `PairHookSet` event's arguments and the receipt.
 */
export async function setPairHookSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setPairHookSync.Parameters<chain, account>,
): Promise<setPairHookSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setPairHook.call(parameters),
    (logs, options) => setPairHook.extractEvent(logs, options).args,
  )
}

export namespace setPairHookSync {
  /** The call's arguments. */
  export type Args = setPairHook.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setPairHook.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `PairHookSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'PairHookSet'>>

  /** `setPairHook`'s errors, and viem's receipt errors. */
  export type ErrorType = setPairHook.ErrorType | WriteContractSyncErrorType
}

/**
 * Makes `agent` an updater, the contract's `setUpdater(agent, true)` (owner): it may post, set shapes and the
 * taker fee cap and use the narrowing switches. Unlike a Hyperliquid API wallet it holds onchain powers, but
 * never custody.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.approveAgent(client, {
 *   venue: '0x...',
 *   agent: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function approveAgent<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: approveAgent.Parameters<chain, account>,
): Promise<approveAgent.ReturnValue> {
  return send(writeContract, client, parameters, approveAgent.call(parameters))
}

export namespace approveAgent {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The agent: not zero. */
    agent: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setUpdater` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setUpdater'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'setUpdater',
      args: [
        validate.notVirtual(
          validate.address(args.agent, 'agent', { nonzero: true }),
          'agent',
          'which never sends a transaction, so it could never post',
        ),
        true,
      ],
      signer: owner,
    })
  }

  /**
   * Extracts the `UpdaterSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `UpdaterSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'UpdaterSet'> {
    return extractLog(venueAbi, 'UpdaterSet', logs, options)
  }
}

/**
 * Makes `agent` an updater, the contract's `setUpdater(agent, true)` (owner): it may post, set shapes and the
 * taker fee cap and use the narrowing switches. Unlike a Hyperliquid API wallet it holds onchain powers, but
 * never custody.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.approveAgentSync(client, {
 *   venue: '0x...',
 *   agent: '0x...',
 * })
 * // `changed` is false when the agent was already approved.
 * if (result.status === 'success' && result.changed) console.log(result.updater)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns Whether the updater permission changed, its `UpdaterSet` arguments when it did, and the receipt.
 */
export async function approveAgentSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: approveAgentSync.Parameters<chain, account>,
): Promise<approveAgentSync.ReturnValue> {
  const call = approveAgent.call(parameters)
  return sendSync(
    client,
    parameters,
    call,
    async (logs, options, blockNumber): Promise<approveAgentSync.Change> => {
      const [event] = accessReceiptEvents('UpdaterSet', logs, options)
      if (event) return { changed: true, ...event.args }
      await confirmEventlessVenue(client, call.address, blockNumber)
      return { changed: false }
    },
  )
}

export namespace approveAgentSync {
  /** The call's arguments. */
  export type Args = approveAgent.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = approveAgent.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** A successful approval either changed the permission or found it already allowed. */
  export type Change =
    | ({ changed: true } & EventArgs<VenueAbi, 'UpdaterSet'>)
    | { changed: false }

  /** Whether the updater permission changed, its event arguments when it did, and the receipt. */
  export type ReturnValue = SyncReturnValue<Change>

  /** `approveAgent`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | approveAgent.ErrorType
    | WriteContractSyncErrorType
    | ReadManyErrorType
    | UnexpectedResponseErrorType
}

/**
 * Revokes an agent's updater powers, the contract's `setUpdater(agent, false)` (owner). Its quotes stay live.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.revokeAgent(client, {
 *   venue: '0x...',
 *   agent: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function revokeAgent<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: revokeAgent.Parameters<chain, account>,
): Promise<revokeAgent.ReturnValue> {
  return send(writeContract, client, parameters, revokeAgent.call(parameters))
}

export namespace revokeAgent {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The agent: not zero. */
    agent: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setUpdater` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setUpdater'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'setUpdater',
      args: [validate.address(args.agent, 'agent', { nonzero: true }), false],
      signer: owner,
    })
  }

  /**
   * Extracts the `UpdaterSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `UpdaterSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'UpdaterSet'> {
    return extractLog(venueAbi, 'UpdaterSet', logs, options)
  }
}

/**
 * Revokes an agent's updater powers, the contract's `setUpdater(agent, false)` (owner). Its quotes stay live.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.revokeAgentSync(client, {
 *   venue: '0x...',
 *   agent: '0x...',
 * })
 * // `changed` is false when the agent was already revoked.
 * if (result.status === 'success' && result.changed) console.log(result.updater)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns Whether the updater permission changed, its `UpdaterSet` arguments when it did, and the receipt.
 */
export async function revokeAgentSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: revokeAgentSync.Parameters<chain, account>,
): Promise<revokeAgentSync.ReturnValue> {
  const call = revokeAgent.call(parameters)
  return sendSync(
    client,
    parameters,
    call,
    async (logs, options, blockNumber): Promise<revokeAgentSync.Change> => {
      const [event] = accessReceiptEvents('UpdaterSet', logs, options)
      if (event) return { changed: true, ...event.args }
      await confirmEventlessVenue(client, call.address, blockNumber)
      return { changed: false }
    },
  )
}

export namespace revokeAgentSync {
  /** The call's arguments. */
  export type Args = revokeAgent.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = revokeAgent.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** A successful revocation either changed the permission or found it already revoked. */
  export type Change =
    | ({ changed: true } & EventArgs<VenueAbi, 'UpdaterSet'>)
    | { changed: false }

  /** Whether the updater permission changed, its event arguments when it did, and the receipt. */
  export type ReturnValue = SyncReturnValue<Change>

  /** `revokeAgent`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | revokeAgent.ErrorType
    | WriteContractSyncErrorType
    | ReadManyErrorType
    | UnexpectedResponseErrorType
}

/**
 * Repoints the venue at another settler (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setSettler(client, {
 *   venue: '0x...',
 *   settler: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setSettler<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setSettler.Parameters<chain, account>,
): Promise<setSettler.ReturnValue> {
  return send(writeContract, client, parameters, setSettler.call(parameters))
}

export namespace setSettler {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The settler: nonzero and not a TIP-1022 virtual address. */
    settler: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setSettler` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setSettler'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'setSettler',
      args: [
        validate.notVirtual(
          validate.address(args.settler, 'settler', { nonzero: true }),
          'settler',
          'which never sends a call, so it could never settle a fill',
        ),
      ],
      signer: owner,
    })
  }

  /**
   * Extracts the `SettlerSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `SettlerSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'SettlerSet'> {
    return extractLog(venueAbi, 'SettlerSet', logs, options)
  }
}

/**
 * Repoints the venue at another settler (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setSettlerSync(client, {
 *   venue: '0x...',
 *   settler: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.settler)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `SettlerSet` event's arguments and the receipt.
 */
export async function setSettlerSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setSettlerSync.Parameters<chain, account>,
): Promise<setSettlerSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setSettler.call(parameters),
    (logs, options) => setSettler.extractEvent(logs, options).args,
  )
}

export namespace setSettlerSync {
  /** The call's arguments. */
  export type Args = setSettler.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setSettler.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `SettlerSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'SettlerSet'>>

  /** `setSettler`'s errors, and viem's receipt errors. */
  export type ErrorType = setSettler.ErrorType | WriteContractSyncErrorType
}

/**
 * Halts every fill on the venue (owner or agent) or resumes them (owner). Resuming re-arms every unexpired word:
 * refresh them first. To pull quotes without halting, use `Actions.maker.cancelAll`.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setHalted(client, {
 *   venue: '0x...',
 *   halted: true,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setHalted<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setHalted.Parameters<chain, account>,
): Promise<setHalted.ReturnValue> {
  return send(writeContract, client, parameters, setHalted.call(parameters))
}

export namespace setHalted {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** `true` halts, `false` resumes. */
    halted: boolean
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setHalted` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setHalted'> {
    const venue = target(args)
    const halted = validate.bool(args.halted, 'halted')
    return venueCall({
      venue,
      functionName: 'setHalted',
      args: [halted],
      signer: halted ? ownerOrAgent : owner,
    })
  }

  /**
   * Extracts the `HaltedSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `HaltedSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'HaltedSet'> {
    return extractLog(venueAbi, 'HaltedSet', logs, options)
  }
}

/**
 * Halts every fill on the venue (owner or agent) or resumes them (owner). Resuming re-arms every unexpired word:
 * refresh them first. To pull quotes without halting, use `Actions.maker.cancelAll`.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setHaltedSync(client, {
 *   venue: '0x...',
 *   halted: true,
 * })
 * // `changed` is false when the venue was already in the requested state.
 * if (result.status === 'success' && result.changed) console.log(result.halted)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns Whether the halt state changed, its `HaltedSet` arguments when it did, and the receipt.
 */
export async function setHaltedSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setHaltedSync.Parameters<chain, account>,
): Promise<setHaltedSync.ReturnValue> {
  const call = setHalted.call(parameters)
  return sendSync(
    client,
    parameters,
    call,
    async (logs, options, blockNumber): Promise<setHaltedSync.Change> => {
      const [event] = accessReceiptEvents('HaltedSet', logs, options)
      if (event) return { changed: true, ...event.args }
      await confirmEventlessVenue(client, call.address, blockNumber)
      return { changed: false }
    },
  )
}

export namespace setHaltedSync {
  /** The call's arguments. */
  export type Args = setHalted.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setHalted.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** A successful request either changed the halt state or found it already requested. */
  export type Change =
    | ({ changed: true } & EventArgs<VenueAbi, 'HaltedSet'>)
    | { changed: false }

  /** Whether the halt state changed, its event arguments when it did, and the receipt. */
  export type ReturnValue = SyncReturnValue<Change>

  /** `setHalted`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | setHalted.ErrorType
    | WriteContractSyncErrorType
    | ReadManyErrorType
    | UnexpectedResponseErrorType
}

/**
 * Moves inventory to `to`, with exact debit and credit checks onchain (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.withdraw(client, {
 *   venue: '0x...',
 *   token: '0x20C0000000000000000000000000000000000001',
 *   to: '0x...',
 *   amount: 1_000_000n,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function withdraw<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: withdraw.Parameters<chain, account>,
): Promise<withdraw.ReturnValue> {
  return send(writeContract, client, parameters, withdraw.call(parameters))
}

export namespace withdraw {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The TIP-20 to move. */
    token: Address
    /** The recipient: not zero or the venue. */
    to: Address
    /** Token atoms: a nonzero `uint256`. */
    amount: bigint
    /** A `bytes32` memo (default zero). */
    memo?: Hex | undefined
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | AmountOutOfRangeErrorType
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `withdraw` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'withdraw'> {
    const venue = target(args)
    const token = validate.address(args.token, 'token', { nonzero: true })
    // v2 pays `to` as given and checks its exact credit, which a TIP-1022 forward to its master never gives.
    const to = validate.notVirtual(
      validate.address(args.to, 'to', { nonzero: true }),
      'to',
      "which forwards to its master, so the venue's exact-credit check would revert",
    )
    if (isAddressEqual(to, venue))
      throw new InvalidAddressError('a withdrawal must leave the venue', {
        parameter: 'to',
        address: to,
      })
    const amount = validate.uintBigint(
      args.amount,
      256,
      'amount',
      AmountOutOfRangeError,
    )
    if (amount === 0n)
      throw new AmountOutOfRangeError('a withdrawal moves a nonzero amount', {
        parameter: 'amount',
        value: amount,
      })
    const memo =
      args.memo === undefined ? zeroHash : validate.bytes32(args.memo, 'memo')
    return venueCall({
      venue,
      functionName: 'withdraw',
      args: [token, to, amount, memo],
      signer: owner,
    })
  }

  /**
   * Extracts the `Withdrawn` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `Withdrawn` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'Withdrawn'> {
    return extractLog(venueAbi, 'Withdrawn', logs, options)
  }
}

/**
 * Moves inventory to `to`, with exact debit and credit checks onchain (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.withdrawSync(client, {
 *   venue: '0x...',
 *   token: '0x20C0000000000000000000000000000000000001',
 *   to: '0x...',
 *   amount: 1_000_000n,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.amount)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `Withdrawn` event's arguments and the receipt.
 */
export async function withdrawSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: withdrawSync.Parameters<chain, account>,
): Promise<withdrawSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    withdraw.call(parameters),
    (logs, options) => withdraw.extractEvent(logs, options).args,
  )
}

export namespace withdrawSync {
  /** The call's arguments. */
  export type Args = withdraw.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = withdraw.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** The `Withdrawn` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'Withdrawn'>>

  /** `withdraw`'s errors, and viem's receipt errors. */
  export type ErrorType = withdraw.ErrorType | WriteContractSyncErrorType
}

/**
 * Proposes a new owner, who must accept (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.transferOwnership(client, {
 *   venue: '0x...',
 *   newOwner: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function transferOwnership<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: transferOwnership.Parameters<chain, account>,
): Promise<transferOwnership.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    transferOwnership.call(parameters),
  )
}

export namespace transferOwnership {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The proposed owner: not zero or a TIP-1022 virtual address. */
    newOwner: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `transferOwnership` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'transferOwnership'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'transferOwnership',
      args: [
        validate.notVirtual(
          validate.address(args.newOwner, 'newOwner', { nonzero: true }),
          'newOwner',
          'which could never accept',
        ),
      ],
      signer: owner,
    })
  }

  /**
   * Extracts the `OwnershipTransferStarted` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `OwnershipTransferStarted` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'OwnershipTransferStarted'> {
    return extractLog(venueAbi, 'OwnershipTransferStarted', logs, options)
  }
}

/**
 * Proposes a new owner, who must accept (owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.transferOwnershipSync(client, {
 *   venue: '0x...',
 *   newOwner: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.pendingOwner)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `OwnershipTransferStarted` event's arguments and the receipt.
 */
export async function transferOwnershipSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: transferOwnershipSync.Parameters<chain, account>,
): Promise<transferOwnershipSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    transferOwnership.call(parameters),
    (logs, options) => transferOwnership.extractEvent(logs, options).args,
  )
}

export namespace transferOwnershipSync {
  /** The call's arguments. */
  export type Args = transferOwnership.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = transferOwnership.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `OwnershipTransferStarted` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'OwnershipTransferStarted'>
  >

  /** `transferOwnership`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | transferOwnership.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Cancels a pending ownership transfer without changing the current owner (owner). Safe to repeat.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.cancelOwnershipTransfer(client, {
 *   venue: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function cancelOwnershipTransfer<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancelOwnershipTransfer.Parameters<chain, account>,
): Promise<cancelOwnershipTransfer.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    cancelOwnershipTransfer.call(parameters),
  )
}

export namespace cancelOwnershipTransfer {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `cancelOwnershipTransfer` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'cancelOwnershipTransfer'> {
    return venueCall({
      venue: target(args),
      functionName: 'cancelOwnershipTransfer',
      args: [],
      signer: owner,
    })
  }

  /**
   * Extracts the `OwnershipTransferStarted` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `OwnershipTransferStarted` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'OwnershipTransferStarted'> {
    return extractLog(venueAbi, 'OwnershipTransferStarted', logs, options)
  }
}

/**
 * Cancels a pending ownership transfer without changing the current owner (owner). Safe to repeat.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.cancelOwnershipTransferSync(client, {
 *   venue: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.pendingOwner)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `OwnershipTransferStarted` event's arguments and the receipt.
 */
export async function cancelOwnershipTransferSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: cancelOwnershipTransferSync.Parameters<chain, account>,
): Promise<cancelOwnershipTransferSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    cancelOwnershipTransfer.call(parameters),
    (logs, options) => cancelOwnershipTransfer.extractEvent(logs, options).args,
  )
}

export namespace cancelOwnershipTransferSync {
  /** The call's arguments. */
  export type Args = cancelOwnershipTransfer.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = cancelOwnershipTransfer.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `OwnershipTransferStarted` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'OwnershipTransferStarted'>
  >

  /** `cancelOwnershipTransfer`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | cancelOwnershipTransfer.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Takes custody and administration of the venue (pending owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.acceptOwnership(client, {
 *   venue: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function acceptOwnership<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: acceptOwnership.Parameters<chain, account>,
): Promise<acceptOwnership.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    acceptOwnership.call(parameters),
  )
}

export namespace acceptOwnership {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `acceptOwnership` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'acceptOwnership'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'acceptOwnership',
      args: [],
      signer: { role: 'pendingOwner' },
    })
  }

  /**
   * Extracts the `OwnershipTransferred` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `OwnershipTransferred` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'OwnershipTransferred'> {
    return extractLog(venueAbi, 'OwnershipTransferred', logs, options)
  }
}

/**
 * Takes custody and administration of the venue (pending owner).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.acceptOwnershipSync(client, {
 *   venue: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.newOwner)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `OwnershipTransferred` event's arguments and the receipt.
 */
export async function acceptOwnershipSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: acceptOwnershipSync.Parameters<chain, account>,
): Promise<acceptOwnershipSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    acceptOwnership.call(parameters),
    (logs, options) => acceptOwnership.extractEvent(logs, options).args,
  )
}

export namespace acceptOwnershipSync {
  /** The call's arguments. */
  export type Args = acceptOwnership.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = acceptOwnership.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `OwnershipTransferred` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'OwnershipTransferred'>
  >

  /** `acceptOwnership`'s errors, and viem's receipt errors. */
  export type ErrorType = acceptOwnership.ErrorType | WriteContractSyncErrorType
}

/**
 * Replaces the hot words of distinct pairs from raw entries (owner or agent; `Actions.maker` builds orders and
 * cancels). The batch is atomic, but a stale entry is skipped without an event, so a successful receipt alone
 * does not mean every word is live: read the outcome.
 *
 * @example
 * ```ts
 * import { Actions, Post, Price } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.post(client, {
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
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function post<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: post.Parameters<chain, account>,
): Promise<post.ReturnValue> {
  return send(writeContract, client, parameters, post.call(parameters))
}

export namespace post {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** One entry per pair: its pair and its word. */
    entries: readonly Post.Entry[]
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | DuplicatePairErrorType
    | EmptyBatchErrorType
    | InvalidHotWordErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `post` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'post'> {
    const venue = target(args)
    const { packed, posts } = Post.pack(args.entries)
    return venueCall({
      venue,
      functionName: 'post',
      args: [packed],
      signer: ownerOrAgent,
      posts,
    })
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
 * Replaces the hot words of distinct pairs from raw entries (owner or agent; `Actions.maker` builds orders and
 * cancels). The batch is atomic, but a stale entry is skipped without an event, so a successful receipt alone
 * does not mean every word is live: read the outcome.
 *
 * @example
 * ```ts
 * import { Actions, Post, Price } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.postSync(client, {
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
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt.
 */
export async function postSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: postSync.Parameters<chain, account>,
): Promise<postSync.ReturnValue> {
  return sendPost(client, parameters, post.call(parameters))
}

export namespace postSync {
  /** The call's arguments. */
  export type Args = post.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = post.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** The `Posted` events' arguments, which entries the venue stored or skipped as stale, and the receipt. */
  export type ReturnValue = PostSyncReturnValue

  /** `post`'s errors, and viem's receipt errors. */
  export type ErrorType = post.ErrorType | WriteContractSyncErrorType
}

/**
 * Defines, redefines or deletes (`Shape.empty`) one of a pair's 256 shapes (owner or agent). Editing the active
 * shape reprices at once: define a new id, confirm it, then switch to it in the next order.
 *
 * @example
 * ```ts
 * import { Actions, Shape } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setShape(client, {
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
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setShape<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setShape.Parameters<chain, account>,
): Promise<setShape.ReturnValue> {
  return send(writeContract, client, parameters, setShape.call(parameters))
}

export namespace setShape {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
    /** The shape id, 0 to 255. */
    shapeId: number
    /** The ladder (`Shape.from`) or its four words, in `ShapeWord`'s one canonical encoding. */
    shape: Shape.Shape | Shape.Words
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | InvalidShapeErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setShape` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setShape'> {
    const venue = target(args)
    // A `Shape` carries its words; anything else must be the words themselves, which `Shape.check` checks.
    const words =
      typeof args.shape === 'object' &&
      args.shape !== null &&
      !Array.isArray(args.shape) &&
      'words' in args.shape
        ? args.shape.words
        : (args.shape as Shape.Words)
    Shape.assert(words)
    return venueCall({
      venue,
      functionName: 'setShape',
      args: [
        validate.pairIndex(args.pairIndex),
        validate.shapeId(args.shapeId),
        [...words],
      ],
      signer: ownerOrAgent,
    })
  }

  /**
   * Extracts the `ShapeSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `ShapeSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'ShapeSet'> {
    return extractLog(venueAbi, 'ShapeSet', logs, options)
  }
}

/**
 * Defines, redefines or deletes (`Shape.empty`) one of a pair's 256 shapes (owner or agent). Editing the active
 * shape reprices at once: define a new id, confirm it, then switch to it in the next order.
 *
 * @example
 * ```ts
 * import { Actions, Shape } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setShapeSync(client, {
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
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `ShapeSet` event's arguments and the receipt.
 */
export async function setShapeSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setShapeSync.Parameters<chain, account>,
): Promise<setShapeSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setShape.call(parameters),
    (logs, options) => setShape.extractEvent(logs, options).args,
  )
}

export namespace setShapeSync {
  /** The call's arguments. */
  export type Args = setShape.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setShape.Parameters<chain, account> & WriteSyncParameters<chain, account>

  /** The `ShapeSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'ShapeSet'>>

  /** `setShape`'s errors, and viem's receipt errors. */
  export type ErrorType = setShape.ErrorType | WriteContractSyncErrorType
}

/**
 * Caps the priority fee per gas of every transaction that fills (owner or agent); `Venue.noPriorityFeeCap`
 * removes the cap. Post above it (`Fees.makerTip`).
 *
 * @example
 * ```ts
 * import { Actions, Fees } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setMaxTakerPriorityFee(client, {
 *   venue: '0x...',
 *   cap: 5n * Fees.gwei,
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setMaxTakerPriorityFee<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setMaxTakerPriorityFee.Parameters<chain, account>,
): Promise<setMaxTakerPriorityFee.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    setMaxTakerPriorityFee.call(parameters),
  )
}

export namespace setMaxTakerPriorityFee {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The cap per gas, in wei: a `uint64`. */
    cap: bigint
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setMaxTakerPriorityFee` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setMaxTakerPriorityFee'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'setMaxTakerPriorityFee',
      args: [validate.uintBigint(args.cap, 64, 'cap')],
      signer: ownerOrAgent,
    })
  }

  /**
   * Extracts the `MaxTakerPriorityFeeSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `MaxTakerPriorityFeeSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'MaxTakerPriorityFeeSet'> {
    return extractLog(venueAbi, 'MaxTakerPriorityFeeSet', logs, options)
  }
}

/**
 * Caps the priority fee per gas of every transaction that fills (owner or agent); `Venue.noPriorityFeeCap`
 * removes the cap. Post above it (`Fees.makerTip`).
 *
 * @example
 * ```ts
 * import { Actions, Fees } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setMaxTakerPriorityFeeSync(client, {
 *   venue: '0x...',
 *   cap: 5n * Fees.gwei,
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.cap)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `MaxTakerPriorityFeeSet` event's arguments and the receipt.
 */
export async function setMaxTakerPriorityFeeSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setMaxTakerPriorityFeeSync.Parameters<chain, account>,
): Promise<setMaxTakerPriorityFeeSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setMaxTakerPriorityFee.call(parameters),
    (logs, options) => setMaxTakerPriorityFee.extractEvent(logs, options).args,
  )
}

export namespace setMaxTakerPriorityFeeSync {
  /** The call's arguments. */
  export type Args = setMaxTakerPriorityFee.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setMaxTakerPriorityFee.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `MaxTakerPriorityFeeSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'MaxTakerPriorityFeeSet'>
  >

  /** `setMaxTakerPriorityFee`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | setMaxTakerPriorityFee.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Sets the taker fee cap to `Venue.defaultTakerPriorityFeeCap`, 10 gwei per gas (owner or agent).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.enableTakerPriorityFeeCap(client, {
 *   venue: '0x...',
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function enableTakerPriorityFeeCap<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: enableTakerPriorityFeeCap.Parameters<chain, account>,
): Promise<enableTakerPriorityFeeCap.ReturnValue> {
  return send(
    writeContract,
    client,
    parameters,
    enableTakerPriorityFeeCap.call(parameters),
  )
}

export namespace enableTakerPriorityFeeCap {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `enableTakerPriorityFeeCap` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'enableTakerPriorityFeeCap'> {
    const venue = target(args)
    return venueCall({
      venue,
      functionName: 'enableTakerPriorityFeeCap',
      args: [],
      signer: ownerOrAgent,
    })
  }

  /**
   * Extracts the `MaxTakerPriorityFeeSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `MaxTakerPriorityFeeSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'MaxTakerPriorityFeeSet'> {
    return extractLog(venueAbi, 'MaxTakerPriorityFeeSet', logs, options)
  }
}

/**
 * Sets the taker fee cap to `Venue.defaultTakerPriorityFeeCap`, 10 gwei per gas (owner or agent).
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.enableTakerPriorityFeeCapSync(client, {
 *   venue: '0x...',
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.cap)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `MaxTakerPriorityFeeSet` event's arguments and the receipt.
 */
export async function enableTakerPriorityFeeCapSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: enableTakerPriorityFeeCapSync.Parameters<chain, account>,
): Promise<enableTakerPriorityFeeCapSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    enableTakerPriorityFeeCap.call(parameters),
    (logs, options) =>
      enableTakerPriorityFeeCap.extractEvent(logs, options).args,
  )
}

export namespace enableTakerPriorityFeeCapSync {
  /** The call's arguments. */
  export type Args = enableTakerPriorityFeeCap.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = enableTakerPriorityFeeCap.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `MaxTakerPriorityFeeSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueAbi, 'MaxTakerPriorityFeeSet'>
  >

  /** `enableTakerPriorityFeeCap`'s errors, and viem's receipt errors. */
  export type ErrorType =
    | enableTakerPriorityFeeCap.ErrorType
    | WriteContractSyncErrorType
}

/**
 * Bounds the mids an agent can post for a pair to `[minMid, maxMid]`, or clears the band with `(0, 0)` (owner).
 * The owner's own posts are never band-checked.
 *
 * @example
 * ```ts
 * import { Actions, Price } from '@tempoxyz/propamm-sdk'
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
 * const hash = await Actions.venue.setMidBand(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   minMid: Price.parse('1.05'),
 *   maxMid: Price.parse('1.12'),
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function setMidBand<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setMidBand.Parameters<chain, account>,
): Promise<setMidBand.ReturnValue> {
  return send(writeContract, client, parameters, setMidBand.call(parameters))
}

export namespace setMidBand {
  /** The call's arguments. */
  export type Args = {
    /** The venue. */
    venue: Address
    /** The pair, from 0. */
    pairIndex: number
    /** The lowest mid, 18 decimals; 0 with `maxMid` 0 clears the band. */
    minMid: bigint
    /** The highest mid, at least `minMid`. */
    maxMid: bigint
  }

  /** The arguments and transaction fields. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = WriteParameters<chain, account> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | InvalidPriceErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `setMidBand` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueCall<'setMidBand'> {
    const venue = target(args)
    const minMid = validate.mid(args.minMid, 'minMid')
    const maxMid = validate.mid(args.maxMid, 'maxMid')
    const set = maxMid !== 0n
    if (set ? minMid === 0n || minMid > maxMid : minMid !== 0n)
      throw new InvalidArgumentError(
        'a mid band is (0, 0) or 0 < minMid <= maxMid (InvalidMidBand onchain)',
        {
          parameter: 'minMid',
          value: minMid,
          metaMessages: [`minMid: ${show(minMid)}`, `maxMid: ${show(maxMid)}`],
        },
      )
    return venueCall({
      venue,
      functionName: 'setMidBand',
      args: [validate.pairIndex(args.pairIndex), minMid, maxMid],
      signer: owner,
    })
  }

  /**
   * Extracts the `MidBandSet` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `MidBandSet` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueAbi, 'MidBandSet'> {
    return extractLog(venueAbi, 'MidBandSet', logs, options)
  }
}

/**
 * Bounds the mids an agent can post for a pair to `[minMid, maxMid]`, or clears the band with `(0, 0)` (owner).
 * The owner's own posts are never band-checked.
 *
 * @example
 * ```ts
 * import { Actions, Price } from '@tempoxyz/propamm-sdk'
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
 * const result = await Actions.venue.setMidBandSync(client, {
 *   venue: '0x...',
 *   pairIndex: 0,
 *   minMid: Price.parse('1.05'),
 *   maxMid: Price.parse('1.12'),
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.minMid, result.maxMid)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `MidBandSet` event's arguments and the receipt.
 */
export async function setMidBandSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: setMidBandSync.Parameters<chain, account>,
): Promise<setMidBandSync.ReturnValue> {
  return sendSync(
    client,
    parameters,
    setMidBand.call(parameters),
    (logs, options) => setMidBand.extractEvent(logs, options).args,
  )
}

export namespace setMidBandSync {
  /** The call's arguments. */
  export type Args = setMidBand.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = setMidBand.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `MidBandSet` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<EventArgs<VenueAbi, 'MidBandSet'>>

  /** `setMidBand`'s errors, and viem's receipt errors. */
  export type ErrorType = setMidBand.ErrorType | WriteContractSyncErrorType
}
