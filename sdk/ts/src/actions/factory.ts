// The factory's one write: creating a venue at its CREATE2 address.
import type {
  Account,
  Address,
  Chain,
  Client,
  Hex,
  Log,
  Transport,
  UnionOmit,
  WriteContractErrorType,
  WriteContractReturnType,
  WriteContractSyncErrorType,
} from 'viem'
import { writeContract } from 'viem/actions'
import { venueFactoryAbi } from '../generated/abis.js'
import type {
  GlobalErrorType,
  InvalidAddressErrorType,
  InvalidArgumentErrorType,
} from '../internal/errors.js'
import * as validate from '../internal/validate.js'
import {
  type VenueFactoryAbi,
  type VenueFactoryCall,
  venueFactoryCall,
} from './internal/abis.js'
import {
  type EventArgs,
  type EventLog,
  type ExtractEventOptions,
  extractEvent as extractLog,
  type SyncReturnValue,
  send,
  sendSync,
  type WriteParameters,
  type WriteSyncParameters,
} from './internal/define.js'

/** The transaction fields, without the venue's `owner`: the transaction's `owner` is a multisig's, which viem/tempo
 * would sign as. */
const transaction = <parameters extends object>(parameters: parameters) =>
  ({ ...parameters, owner: undefined }) as parameters

/**
 * Creates `owner`'s venue at the factory's CREATE2 address for `salt` (`Info.predictVenue`), initialized with the
 * factory's default settler (anyone). Anyone may create it first; it is still `owner`'s.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
 * import { createClient, http, keccak256, toHex } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const hash = await Actions.factory.createVenue(client, {
 *   factory: '0x...',
 *   owner: '0x...',
 *   salt: keccak256(toHex('my venue')),
 * })
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The transaction hash.
 */
export async function createVenue<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: createVenue.Parameters<chain, account>,
): Promise<createVenue.ReturnValue> {
  return send(
    writeContract,
    client,
    transaction(parameters),
    createVenue.call(parameters),
  )
}

export namespace createVenue {
  /** The call's arguments. */
  export type Args = {
    /** The factory, from a deployment you verified. */
    factory: Address
    /** The venue's owner: not zero. */
    owner: Address
    /** The CREATE2 salt, 32 bytes: with `owner`, it fixes the address. */
    salt: Hex
  }

  /** The arguments and transaction fields. `owner` is the venue's, so there is no multisig `owner` field. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = UnionOmit<WriteParameters<chain, account>, 'owner'> & Args

  /** The transaction hash. */
  export type ReturnValue = WriteContractReturnType

  /** The SDK's refusals of its arguments, and viem's write errors. */
  export type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | WriteContractErrorType
    | GlobalErrorType

  /**
   * The validated `createVenue` call, for a `calls` batch, `Plan.simulate`, `Roles.check` or viem's contract actions.
   * @param args - Arguments.
   * @returns The call.
   */
  export function call(args: Args): VenueFactoryCall<'createVenue'> {
    const factory = validate.address(args.factory, 'factory', { nonzero: true })
    const owner = validate.notVirtual(
      validate.address(args.owner, 'owner', { nonzero: true }),
      'owner',
      'which never sends a transaction, so it could never run the venue',
    )
    return venueFactoryCall({
      factory,
      functionName: 'createVenue',
      args: [owner, validate.bytes32(args.salt, 'salt')],
      signer: { role: 'anyone' },
    })
  }

  /**
   * Extracts the `VenueCreated` event from logs.
   * @param logs - Logs.
   * @param options - `address`: only the logs this contract emitted, such as the call's `address`.
   * @returns The `VenueCreated` event.
   */
  export function extractEvent(
    logs: readonly Log[],
    options: ExtractEventOptions = {},
  ): EventLog<VenueFactoryAbi, 'VenueCreated'> {
    return extractLog(venueFactoryAbi, 'VenueCreated', logs, options)
  }
}

/**
 * Creates `owner`'s venue at the factory's CREATE2 address for `salt` (`Info.predictVenue`), initialized with the
 * factory's default settler (anyone). Anyone may create it first; it is still `owner`'s.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
 * import { createClient, http, keccak256, toHex } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({
 *   account: privateKeyToAccount('0x...'),
 *   chain: tempoModerato,
 *   transport: http(),
 * })
 *
 * const result = await Actions.factory.createVenueSync(client, {
 *   factory: '0x...',
 *   owner: '0x...',
 *   salt: keccak256(toHex('my venue')),
 * })
 * // A pending or reverted receipt carries no event: check the status first.
 * if (result.status === 'success') console.log(result.venue)
 * ```
 *
 * @param client - Client.
 * @param parameters - Parameters.
 * @returns The `VenueCreated` event's arguments and the receipt.
 */
export async function createVenueSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: createVenueSync.Parameters<chain, account>,
): Promise<createVenueSync.ReturnValue> {
  return sendSync(
    client,
    transaction(parameters),
    createVenue.call(parameters),
    (logs, options) => createVenue.extractEvent(logs, options).args,
  )
}

export namespace createVenueSync {
  /** The call's arguments. */
  export type Args = createVenue.Args

  /** The arguments, transaction fields and receipt wait. */
  export type Parameters<
    chain extends Chain | undefined = Chain | undefined,
    account extends Account | undefined = Account | undefined,
  > = createVenue.Parameters<chain, account> &
    WriteSyncParameters<chain, account>

  /** The `VenueCreated` event's arguments and the receipt. */
  export type ReturnValue = SyncReturnValue<
    EventArgs<VenueFactoryAbi, 'VenueCreated'>
  >

  /** `createVenue`'s errors, and viem's receipt errors. */
  export type ErrorType = createVenue.ErrorType | WriteContractSyncErrorType
}
