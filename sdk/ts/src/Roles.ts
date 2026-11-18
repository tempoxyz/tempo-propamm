// A pre-flight for who may send a call: reads the role the call's `signer` names at one block. The contract stays the
// authority; the e2e roles suite holds every builder's role to the contract's own gates.
import { type Account, type Address, isAddressEqual } from 'viem'
import type { PreparedCall, SignerRole } from './actions/internal/define.js'
import { venueAbi } from './generated/abis.js'
import {
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  MissingAccountError,
  type MissingAccountErrorType,
  type SnapshotIncompleteErrorType,
} from './internal/errors.js'
import {
  type MulticallParameters,
  type PinErrorType,
  pin,
  type Read,
  type ReadManyErrorType,
  type ReadParameters,
  readOf,
  readOptions,
  readValues,
  type ViewArgs,
  type ViewName,
} from './internal/read.js'
import type { AnyClient } from './internal/types.js'
import * as validate from './internal/validate.js'

/**
 * Whether an account holds the role a call needs: `{ ok: true }`, or the role it lacks and why.
 *
 * @example
 * ```ts
 * import { Actions, Roles } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const call = Actions.venue.setHalted.call({
 *   venue: '0x1111111111111111111111111111111111111111',
 *   halted: true,
 * })
 * const check: Roles.Check = await Roles.check(client, {
 *   call,
 *   account: '0x3333333333333333333333333333333333333333',
 * })
 * console.log(check.ok ? 'may send' : `${check.required.role}: ${check.reason}`)
 * ```
 */
export type Check =
  | { ok: true }
  | { ok: false; required: SignerRole; reason: string }

/**
 * Whether `account` (default: the client's) holds the role `call.signer` names, read at one block: the given
 * `blockNumber`, else the block `blockTag` names, else the latest. A pre-flight only: the contract stays the
 * authority, and a role can change before the call lands.
 *
 * @example
 * ```ts
 * import { Actions, Roles } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const call = Actions.venue.addPair.call({
 *   venue: '0x1111111111111111111111111111111111111111',
 *   base: '0x20C0000000000000000000000000000000000001',
 *   quote: '0x20C0000000000000000000000000000000000002',
 *   sizeUnit: 1_000_000n,
 * })
 * const check = await Roles.check(client, {
 *   call,
 *   account: '0x3333333333333333333333333333333333333333',
 *   blockTag: 'finalized',
 * })
 * console.log(check.ok)
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The call, the account to check and the read options.
 * @returns Whether the account holds the role.
 */
export async function check(
  client: AnyClient,
  parameters: check.Parameters,
): Promise<check.ReturnValue> {
  const { call, account: given, ...rest } = parameters
  if (typeof call !== 'object' || call === null)
    throw new InvalidArgumentError('call must be a prepared call', {
      parameter: 'call',
      value: call,
    })
  const role = roleOf(call.signer)
  const target = validate.address(call.address, 'call.address', {
    nonzero: true,
  })
  const account = given ?? client.account
  if (account === undefined)
    throw new MissingAccountError(
      'a role check needs an account, in the parameters or on the client',
    )
  const sender = validate.address(
    typeof account === 'string' ? account : account.address,
    'account',
    { nonzero: true },
  )
  if (role.role === 'anyone') return { ok: true }
  const options = {
    ...(await pin(client, readOptions(rest))),
    ...(parameters.multicallAddress === undefined
      ? {}
      : {
          multicallAddress: validate.address(
            parameters.multicallAddress,
            'multicallAddress',
          ),
        }),
  }
  const is = (a: Address) => isAddressEqual(a, sender)
  const refuse = (reason: string): Check => ({
    ok: false,
    required: role,
    reason,
  })
  // Each read's view and arguments, and its value, are typed by the ABI.
  const read = <const reads extends readonly Read[]>(reads: reads) =>
    readValues(client, reads, options)
  const venue = <name extends ViewName<typeof venueAbi>>(
    functionName: name,
    args?: ViewArgs<typeof venueAbi, name>,
  ) => readOf(target, venueAbi, functionName, args)
  switch (role.role) {
    case 'owner': {
      const [owner] = await read([venue('owner')])
      return is(owner)
        ? { ok: true }
        : refuse(`${sender} is not the venue's owner`)
    }
    case 'ownerOrAgent': {
      const [owner, agent] = await read([
        venue('owner'),
        venue('isUpdater', [sender]),
      ])
      return is(owner) || agent
        ? { ok: true }
        : refuse(`${sender} is neither the owner nor an agent`)
    }
    case 'pendingOwner': {
      const [pending] = await read([venue('pendingOwner')])
      return is(pending)
        ? { ok: true }
        : refuse(`${sender} is not the pending owner`)
    }
    case 'sponsorAdmin': {
      const [[admin]] = await read([venue('sponsor', [role.sponsorId])])
      return is(admin)
        ? { ok: true }
        : refuse(`${sender} is not sponsor ${role.sponsorId}'s admin`)
    }
    case 'pendingSponsorAdmin': {
      const [pending] = await read([
        venue('pendingSponsorAdmin', [role.sponsorId]),
      ])
      return is(pending)
        ? { ok: true }
        : refuse(`${sender} is not sponsor ${role.sponsorId}'s pending admin`)
    }
  }
}

export declare namespace check {
  /** The call (its `address` and `signer`), the account to check (default: the client's) and the read options. */
  type Parameters = Omit<ReadParameters, 'account'> &
    MulticallParameters & {
      call: Pick<PreparedCall, 'address' | 'signer'>
      account?: Account | Address | undefined
    }
  /** Whether the account holds the role. */
  type ReturnValue = Check
  /** The errors `check` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | MissingAccountErrorType
    | PinErrorType
    | ReadManyErrorType
    | SnapshotIncompleteErrorType
    | GlobalErrorType
}

const roles: ReadonlySet<string> = new Set([
  'anyone',
  'owner',
  'ownerOrAgent',
  'pendingOwner',
  'sponsorAdmin',
  'pendingSponsorAdmin',
])

/** The call's signer role, its fields checked before any read. */
function roleOf(role: SignerRole): SignerRole {
  if (
    typeof role !== 'object' ||
    role === null ||
    !roles.has((role as { role?: unknown }).role as string)
  )
    throw new InvalidArgumentError('call.signer is not a signer role', {
      parameter: 'call.signer',
      value: role,
    })
  switch (role.role) {
    case 'sponsorAdmin':
    case 'pendingSponsorAdmin':
      return { role: role.role, sponsorId: validate.sponsorId(role.sponsorId) }
    default:
      return role
  }
}
