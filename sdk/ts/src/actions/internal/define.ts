// What every action shares, as viem/tempo's actions have it: the prepared call (viem's `defineCall` shape, plus the
// contract it targets and the role that may send it), viem/tempo's write parameters, and the send, receipt and event
// steps each action's namespace delegates to.
import type {
  Abi,
  Account,
  Address,
  Chain,
  Client,
  ContractEventName,
  ContractFunctionArgs,
  ContractFunctionName,
  GetEventArgs,
  Hex,
  Log,
  Prettify,
  Transport,
  UnionPick,
  WriteContractSyncParameters,
} from 'viem'
import {
  encodeFunctionData,
  isAddressEqual,
  maxUint256,
  parseEventLogs,
} from 'viem'
import { type writeContract, writeContractSync } from 'viem/actions'
import type { Transaction } from 'viem/tempo'
import type { AbiErrorItem } from '../../internal/abi.js'
import {
  InvalidArgumentError,
  UnexpectedResponseError,
} from '../../internal/errors.js'
import type { ContractName } from '../../internal/types.js'
import * as validate from '../../internal/validate.js'
import type { PostRef } from '../../Post.js'

/**
 * Who may send a call, as the contract gates it. An agent is the venue's updater (the Rust SDK's `approve_agent`).
 * `Roles.check` reads it against the chain; the contract stays the authority.
 */
export type SignerRole =
  | { role: 'owner' }
  | { role: 'ownerOrAgent' }
  | { role: 'pendingOwner' }
  | { role: 'sponsorAdmin'; sponsorId: bigint }
  | { role: 'pendingSponsorAdmin'; sponsorId: bigint }
  | { role: 'anyone' }

/** The writes of `abi`: every write the SDK builds is `nonpayable`. */
export type WriteName<abi extends Abi> = ContractFunctionName<abi, 'nonpayable'>

/**
 * One function of `abi` and the errors its call can revert with: the ABI a call carries, so viem's errors name a
 * revert, and so an action's type holds one function item rather than its contract's whole ABI.
 */
export type FunctionAbi<
  abi extends Abi,
  functionName extends WriteName<abi>,
> = readonly [
  Extract<abi[number], { type: 'function'; name: functionName }>,
  ...AbiErrorItem[],
]

/**
 * One unsigned call, as viem/tempo's `defineCall` builds it: the typed call for viem's contract actions and
 * `multicall`, and `{ to, data }` for a Tempo `calls` batch or a plain transaction. It also names the contract it
 * targets and who may send it (`Roles.check`), and a `post` batch carries its entries (`PostOutcome`).
 */
export type PreparedCall<
  abi extends Abi = Abi,
  functionName extends string = string,
> = {
  /** The function and the errors its call can revert with. */
  abi: abi
  /** The contract called. */
  address: Address
  /** The function's arguments, validated. */
  args: functionName extends WriteName<abi>
    ? ContractFunctionArgs<abi, 'nonpayable', functionName>
    : readonly unknown[]
  /** The function called. */
  functionName: functionName
  /** The calldata. */
  data: Hex
  /** `address`, as a `calls` entry or a transaction names it. */
  to: Address
  /** The contract the call targets. */
  contract: ContractName
  /** Who may send it, as the contract gates it. */
  signer: SignerRole
  /** Each entry of a `post` batch, for `PostOutcome`. */
  posts?: readonly PostRef[] | undefined
}

/**
 * A write's transaction fields: viem/tempo's own (`viem/tempo`'s internal `WriteParameters`, which it doesn't export):
 * the sender (`account`, defaulting to the client's), the chain to sign for, gas, fees and nonce, and Tempo's
 * `feePayer`, `feeToken`, `keyAuthorization`, `nonceKey`, `owner`, `validAfter` and `validBefore`.
 * Supplied validity bounds must be positive safe-integer numbers, never strings or bigints.
 * Supply both bounds or neither unless nonceKey explicitly selects a non-expiring lane;
 * viem can otherwise select expiring nonces and supply time-dependent or random missing bounds.
 */
export type WriteParameters<
  chain extends Chain | undefined = Chain | undefined,
  account extends Account | undefined = Account | undefined,
> = UnionPick<
  WriteContractSyncParameters<never, never, never, chain, account>,
  | 'account'
  | 'chain'
  | 'gas'
  | 'maxFeePerGas'
  | 'maxPriorityFeePerGas'
  | 'nonce'
  | 'throwOnReceiptRevert'
> &
  UnionPick<
    Transaction.TransactionRequestTempo,
    | 'feePayer'
    | 'feeToken'
    | 'keyAuthorization'
    | 'nonceKey'
    | 'owner'
    | 'validAfter'
    | 'validBefore'
  >

/** How long a `*Sync` write waits for its receipt, as viem/tempo's `WriteSyncParameters`. */
export type WriteSyncParameters<
  chain extends Chain | undefined = Chain | undefined,
  account extends Account | undefined = Account | undefined,
> = UnionPick<
  WriteContractSyncParameters<never, never, never, chain, account>,
  'pollingInterval' | 'timeout'
>

/** An event's decoded arguments, every one present. */
export type EventArgs<
  abi extends Abi,
  eventName extends ContractEventName<abi>,
> = GetEventArgs<abi, eventName, { IndexedOnly: false; Required: true }>

/** A log decoded as `eventName`, as viem's `parseEventLogs` returns it. */
export type EventLog<
  abi extends Abi,
  eventName extends ContractEventName<abi>,
> = Log<bigint, number, false, undefined, true, abi, eventName>

/**
 * What a `*Sync` write returns: a union keyed on inclusion-aware `status` (a top-level key, since
 * TypeScript narrows a union only on one). `'success'` carries the action result beside the receipt, usually its
 * event's arguments; `'pending'`
 * (Tempo's receipt from before inclusion) and `'reverted'` (with `throwOnReceiptRevert: false`) carry the receipt alone,
 * since it has no final logs to read. Missing block number or hash means pending even if `receipt.status` says
 * success; the original receipt is preserved. Check `status` before reading the action result.
 *
 * @example
 * ```ts
 * import { Actions } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { privateKeyToAccount } from 'viem/accounts'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ account: privateKeyToAccount('0x...'), chain: tempoModerato, transport: http() })
 * const result: Actions.venue.setHaltedSync.ReturnValue = await Actions.venue.setHaltedSync(client, {
 *   venue: '0x...',
 *   halted: true,
 * })
 * if (result.status === 'success' && result.changed) console.log(result.halted)
 * else if (result.status === 'success') console.log('halt state was already requested')
 * else console.log('no receipt event:', result.receipt.status)
 * ```
 */
export type SyncReturnValue<args> =
  | Prettify<
      {
        /** `receipt.status`: mined and successful, so the arguments come from its logs. */
        status: 'success'
      } & args & {
          /** The receipt, mined and successful. */
          receipt: Transaction.TransactionReceipt<bigint, number, 'success'>
        }
    >
  | {
      /** Not yet included (`'pending'`), or reverted (with `throwOnReceiptRevert: false`). */
      status: 'reverted' | 'pending'
      /** The original receipt: status alone does not prove inclusion. */
      receipt: Omit<
        Transaction.TransactionReceipt,
        'blockNumber' | 'blockHash'
      > & {
        blockNumber: bigint | null
        blockHash: Hex | null
      }
    }

/** The options of an action's `extractEvent` and `extractEvents`. */
export type ExtractEventOptions = {
  /**
   * Only the logs this contract emitted. Without it a log of the event from any contract matches, and a receipt holds
   * every log of its transaction: a token's look-alike event, or another venue's in a batch. Pass the call's `address`
   * (each `*Sync` does).
   */
  address?: Address | undefined
}

/** @internal Builds a call: encodes its data and names its target. */
export function defineCall<const abi extends Abi, functionName extends string>(
  call: Omit<PreparedCall<abi, functionName>, 'data' | 'to'>,
): PreparedCall<abi, functionName> {
  return {
    ...call,
    data: encodeFunctionData(call as never),
    to: call.address,
  }
}

/** @internal Validate before any wallet call, or cancel-all sequence reservation. */
export function assertWriteValidity(parameters: object): void {
  const { nonceKey, validAfter, validBefore } = parameters as WriteParameters
  // viem 2.56.9 accepts uint256 lanes and the expiring sentinel, not arbitrary runtime values.
  if (
    nonceKey !== undefined &&
    nonceKey !== 'expiring' &&
    (typeof nonceKey !== 'bigint' || nonceKey < 0n || nonceKey > maxUint256)
  )
    throw new InvalidArgumentError(
      "nonceKey must be a uint256 bigint or 'expiring'",
      { parameter: 'nonceKey', value: nonceKey },
    )
  for (const [parameter, value] of [
    ['validAfter', validAfter],
    ['validBefore', validBefore],
  ] as const) {
    if (value !== undefined && (!Number.isSafeInteger(value) || value <= 0))
      throw new InvalidArgumentError(
        `${parameter} must be a positive safe-integer number`,
        { parameter, value },
      )
  }
  // Missing nonceKey can select expiring nonces through fee sponsorship or concurrency.
  // Do not predict viem's random lower bound or race its wall-clock upper bound:
  // partial windows need an explicit non-expiring lane, even if they might be valid.
  if (
    (nonceKey === undefined ||
      nonceKey === 'expiring' ||
      nonceKey === maxUint256) &&
    (validAfter === undefined) !== (validBefore === undefined)
  ) {
    const parameter = validAfter === undefined ? 'validAfter' : 'validBefore'
    throw new InvalidArgumentError(
      'supply both validity bounds or neither, or select an explicit non-expiring nonceKey',
      { parameter },
    )
  }
  // A complete supplied window must also have increasing bounds.
  if (
    validAfter !== undefined &&
    validBefore !== undefined &&
    validBefore <= validAfter
  )
    throw new InvalidArgumentError(
      'validBefore must be greater than validAfter',
      {
        parameter: 'validBefore',
        value: validBefore,
      },
    )
}

/** @internal The write fields of `parameters`, so an action's own arguments never reach a transaction request. */
function pickWrite(parameters: object) {
  const {
    account,
    chain,
    feePayer,
    feeToken,
    gas,
    keyAuthorization,
    maxFeePerGas,
    maxPriorityFeePerGas,
    nonce,
    nonceKey,
    owner,
    validAfter,
    validBefore,
  } = parameters as WriteParameters
  assertWriteValidity({ nonceKey, validAfter, validBefore })
  return {
    account,
    chain,
    feePayer,
    feeToken,
    gas,
    keyAuthorization,
    maxFeePerGas,
    maxPriorityFeePerGas,
    nonce,
    nonceKey,
    owner,
    validAfter,
    validBefore,
  }
}

/**
 * @internal Sends `call` through viem's `writeContract` or `writeContractSync` with the write fields of `parameters`.
 * viem wraps a revert in its `ContractFunctionExecutionError`, decoded over the call's ABI (`Errors.decode` reads it
 * too).
 */
export async function send<
  action extends typeof writeContract | typeof writeContractSync,
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  action: action,
  client: Client<Transport, chain, account>,
  parameters: object,
  call: PreparedCall,
): Promise<ReturnType<action>> {
  const { pollingInterval, throwOnReceiptRevert, timeout } =
    parameters as WriteParameters & WriteSyncParameters
  const write = pickWrite(parameters)
  const account = write.account === undefined ? client.account : write.account
  const chain = write.chain === undefined ? client.chain : write.chain
  // Validate at the signing boundary, after viem's final preparation (including eth_fillTransaction).
  // Pass the guarded account explicitly: bound wallet actions must not fall back to their hoisted account.
  if (account && typeof account !== 'string' && account.type === 'local') {
    // Tempo prepares the supported sentinel as the reserved expiring lane.
    const nonceKey = write.nonceKey === 'expiring' ? maxUint256 : write.nonceKey
    const signTransaction: typeof account.signTransaction = async (
      transaction,
      options,
    ) => {
      if (chain && transaction.chainId !== chain.id)
        throw new UnexpectedResponseError(
          'prepared transaction chainId does not match the requested chain',
          { value: transaction.chainId },
        )
      const preparedNonceKey =
        'nonceKey' in transaction ? transaction.nonceKey : undefined
      if (
        nonceKey !== undefined &&
        (preparedNonceKey === undefined
          ? 0n
          : typeof preparedNonceKey === 'bigint' ||
              typeof preparedNonceKey === 'number' ||
              typeof preparedNonceKey === 'string'
            ? BigInt(preparedNonceKey)
            : undefined) !== nonceKey
      )
        throw new UnexpectedResponseError(
          'prepared transaction nonceKey does not match the requested nonceKey',
          {
            value: 'nonceKey' in transaction ? transaction.nonceKey : undefined,
          },
        )
      return account.signTransaction(transaction, options)
    }
    // Use a fresh target: a proxy of the account cannot override a frozen own signer.
    // Inherit property presence, but read getters and call other methods on the original
    // receiver so class/private state remains valid. Never expose its unguarded signer.
    write.account = new Proxy(Object.create(account), {
      get(_target, property) {
        if (property === 'signTransaction') return signTransaction
        const value = Reflect.get(account, property, account)
        return typeof value === 'function' ? value.bind(account) : value
      },
    })
  }
  return (await action(client, {
    ...write,
    pollingInterval,
    throwOnReceiptRevert,
    timeout,
    abi: call.abi,
    address: call.address,
    functionName: call.functionName,
    args: call.args,
  } as never)) as never
}

/**
 * @internal Sends `call` through viem's `writeContractSync` (`throwOnReceiptRevert` defaulting to `true`), and reads its
 * result from the receipt's logs that `call`'s own contract emitted. Pending or missing inclusion fields mean no
 * outcome yet, matching `PostOutcome.fromReceipt`; a reverted receipt also has no result to read.
 */
export async function sendSync<
  chain extends Chain | undefined,
  account extends Account | undefined,
  args extends object,
>(
  client: Client<Transport, chain, account>,
  parameters: object,
  call: PreparedCall,
  read: (
    logs: readonly Log[],
    options: ExtractEventOptions,
    blockNumber: bigint,
  ) => args | Promise<args>,
): Promise<SyncReturnValue<args>> {
  const { throwOnReceiptRevert = true } = parameters as WriteSyncParameters &
    WriteParameters
  const receipt: Transaction.TransactionReceipt = await send(
    writeContractSync,
    client,
    { ...parameters, throwOnReceiptRevert },
    call,
  )
  // Match PostOutcome's inclusion check before interpreting any event or reading post-state.
  if (
    receipt.status === 'pending' ||
    receipt.blockNumber == null ||
    receipt.blockHash == null
  )
    return { status: 'pending', receipt } as never
  if (receipt.status !== 'success')
    return { status: receipt.status, receipt } as never
  return {
    status: receipt.status,
    ...(await read(
      receipt.logs,
      { address: call.address },
      receipt.blockNumber,
    )),
    receipt,
  } as never
}

/** @internal Every log of `logs` that decodes as `abi`'s `eventName`, in order, from `options.address` if given. */
export function extractEvents<
  const abi extends Abi,
  eventName extends ContractEventName<abi>,
>(
  abi: abi,
  eventName: eventName,
  logs: readonly Log[],
  options: ExtractEventOptions = {},
): EventLog<abi, eventName>[] {
  if (!Array.isArray(logs))
    throw new InvalidArgumentError('logs must be an array of logs', {
      parameter: 'logs',
      value: logs,
    })
  if (typeof options !== 'object' || options === null)
    throw new InvalidArgumentError('options must be { address }', {
      parameter: 'options',
      value: options,
    })
  const address =
    options.address === undefined
      ? undefined
      : validate.address(options.address, 'address')
  const events = parseEventLogs({
    abi,
    eventName,
    logs: logs as Log[],
    strict: true,
  } as never) as never as EventLog<abi, eventName>[]
  return address === undefined
    ? events
    : events.filter((log) => isAddressEqual(log.address, address))
}

/**
 * @internal The first log of `logs` that decodes as `abi`'s `eventName`, from `options.address` if given;
 * `InvalidArgumentError` when none does.
 */
export function extractEvent<
  const abi extends Abi,
  eventName extends ContractEventName<abi>,
>(
  abi: abi,
  eventName: eventName,
  logs: readonly Log[],
  options: ExtractEventOptions = {},
): EventLog<abi, eventName> {
  const [log] = extractEvents(abi, eventName, logs, options)
  if (!log)
    throw new InvalidArgumentError(
      `the logs hold no \`${eventName}\` event${options.address === undefined ? '' : ` from ${options.address}`}`,
      { parameter: 'logs' },
    )
  return log
}
