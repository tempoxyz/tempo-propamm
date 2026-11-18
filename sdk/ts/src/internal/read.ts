import type {
  Abi,
  Account,
  Address,
  BlockTag,
  ContractFunctionArgs,
  ContractFunctionName,
  ContractFunctionReturnType,
  GetBlockErrorType,
  GetBlockNumberErrorType,
  MulticallErrorType,
  ReadContractParameters,
} from 'viem'
import { encodeFunctionData, isAddressEqual } from 'viem'
import { getBlock, getBlockNumber, multicall, readContract } from 'viem/actions'
import { getAction } from 'viem/utils'
import {
  BaseError,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  SnapshotIncompleteError,
  show,
  UnexpectedResponseError,
  type UnexpectedResponseErrorType,
} from './errors.js'
import type { AnyClient } from './types.js'
import * as validate from './validate.js'

/**
 * viem/tempo's read options (`ReadParameters`), as every SDK read that makes an RPC call takes them: the caller
 * (`account`), the block (`blockNumber` or `blockTag`, default the latest) and overrides of the block's fields and of
 * state for the read.
 *
 * @example
 * ```ts
 * import { Info, type ReadParameters } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const at: ReadParameters = { blockNumber: 1_000_000n }
 * const state = await Info.venueState(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   ...at,
 * })
 * console.log(state.halted)
 * ```
 */
export type ReadParameters = Pick<
  ReadContractParameters<never, never, never>,
  'account' | 'blockNumber' | 'blockOverrides' | 'blockTag' | 'stateOverride'
>

/**
 * For a read that makes several calls: Multicall3's address, when the chain configures none (Tempo's chains don't).
 * Without either, the calls run deployless.
 *
 * @example
 * ```ts
 * import { type MulticallParameters, Snapshot } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const multicall: MulticallParameters = {
 *   multicallAddress: '0xcA11bde05977b3631167028862bE2a173976CA11',
 * }
 * const snapshot = await Snapshot.get(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   ...multicall,
 * })
 * console.log(snapshot.block.number)
 * ```
 */
export type MulticallParameters = {
  multicallAddress?: Address | undefined
}

/**
 * {@link MulticallParameters} checked, with only the field given: what a read spreads into {@link readMany}'s options.
 *
 * @param parameters - A read's parameters; fields other than `multicallAddress` are ignored.
 * @returns `multicallAddress`, checked, if given.
 */
export function multicallOptions(
  parameters: MulticallParameters,
): MulticallParameters {
  return parameters.multicallAddress === undefined
    ? {}
    : {
        multicallAddress: validate.address(
          parameters.multicallAddress,
          'multicallAddress',
        ),
      }
}

/** {@link ReadParameters} checked, with only the fields given: what a read spreads into viem's. */
export type ReadOptions = {
  account?: Account | Address | undefined
  blockNumber?: bigint | undefined
  blockTag?: BlockTag | undefined
  blockOverrides?: ReadParameters['blockOverrides']
  stateOverride?: ReadParameters['stateOverride']
}

/** The errors {@link readOptions} throws. */
export type ReadOptionsErrorType =
  | InvalidAddressErrorType
  | InvalidArgumentErrorType

/** The errors {@link pin} throws: the options' own (`'pending'` included), viem's for the block read, and a block the
 * node answers without a number. */
export type PinErrorType =
  | ReadOptionsErrorType
  | GetBlockErrorType
  | GetBlockNumberErrorType
  | UnexpectedResponseErrorType

const blockTags: ReadonlySet<string> = new Set([
  'earliest',
  'finalized',
  'latest',
  'pending',
  'safe',
])

// Keep this schema aligned with the pinned viem/ox BlockOverrides type. ox silently drops
// wrongly typed quantities; accepting them here would make Snapshot's context disagree with eth_call.
const overrideQuantities = [
  'baseFeePerGas',
  'blobBaseFee',
  'gasLimit',
  'number',
  'prevRandao',
  'time',
] as const

function overrideRecord(
  value: unknown,
  name: string,
  keys: readonly string[],
): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value))
    throw new InvalidArgumentError(
      `${name} must be an object, got ${show(value)}`,
      { parameter: name, value },
    )
  for (const key of Reflect.ownKeys(value))
    if (typeof key !== 'string' || !keys.includes(key))
      throw new InvalidArgumentError(
        `${name} has an unknown field ${String(key)}`,
        { parameter: name, value },
      )
  return value as Record<string, unknown>
}

function checkedBlockOverrides(
  value: NonNullable<ReadParameters['blockOverrides']>,
): NonNullable<ReadParameters['blockOverrides']> {
  const input = overrideRecord(value, 'blockOverrides', [
    ...overrideQuantities,
    'feeRecipient',
    'withdrawals',
  ])
  const result: NonNullable<ReadParameters['blockOverrides']> = {}
  for (const key of overrideQuantities) {
    const quantity = input[key]
    if (quantity !== undefined)
      result[key] = validate.uintBigint(
        quantity as bigint,
        256,
        `blockOverrides.${key}`,
      )
  }
  if (input.feeRecipient !== undefined)
    result.feeRecipient = validate.address(
      input.feeRecipient as string,
      'blockOverrides.feeRecipient',
    )
  if (input.withdrawals !== undefined) {
    if (!Array.isArray(input.withdrawals))
      throw new InvalidArgumentError(
        'blockOverrides.withdrawals must be an array',
        { parameter: 'blockOverrides.withdrawals', value: input.withdrawals },
      )
    result.withdrawals = Array.from(input.withdrawals, (value, i) => {
      const name = `blockOverrides.withdrawals[${i}]`
      const entry = overrideRecord(value, name, [
        'address',
        'amount',
        'index',
        'validatorIndex',
      ])
      const index = (key: 'index' | 'validatorIndex') => {
        const value = entry[key]
        if (
          typeof value !== 'number' ||
          !Number.isSafeInteger(value) ||
          value < 0
        )
          throw new InvalidArgumentError(
            `${name}.${key} must be a nonnegative safe integer`,
            { parameter: `${name}.${key}`, value },
          )
        return value
      }
      return {
        address: validate.address(entry.address as string, `${name}.address`),
        amount: validate.uintBigint(
          entry.amount as bigint,
          256,
          `${name}.amount`,
        ),
        index: index('index'),
        validatorIndex: index('validatorIndex'),
      }
    })
  }
  return result
}

/**
 * Checks a read's {@link ReadParameters} and keeps only the fields given. A block number and a tag together are
 * refused: they could name two blocks.
 *
 * @param parameters - A read's parameters; fields other than the read options are ignored.
 * @returns The read options given, checked.
 */
export function readOptions(parameters: ReadParameters): ReadOptions {
  const { account, blockNumber, blockOverrides, blockTag, stateOverride } =
    parameters
  if (blockNumber !== undefined && blockTag !== undefined)
    throw new InvalidArgumentError(
      'pass blockNumber or blockTag, not both: they could name two blocks',
      { parameter: 'blockTag', value: blockTag },
    )
  if (blockTag !== undefined && !blockTags.has(blockTag))
    throw new InvalidArgumentError(
      `blockTag must be one of ${[...blockTags].join(', ')}, got ${show(blockTag)}`,
      { parameter: 'blockTag', value: blockTag },
    )
  return {
    ...(account === undefined
      ? {}
      : { account: validate.account(account, 'account') }),
    ...(blockNumber === undefined
      ? {}
      : { blockNumber: validate.blockNumber(blockNumber) }),
    ...(blockTag === undefined ? {} : { blockTag }),
    ...(blockOverrides === undefined
      ? {}
      : { blockOverrides: checkedBlockOverrides(blockOverrides) }),
    ...(stateOverride === undefined ? {} : { stateOverride }),
  }
}

/**
 * Refuses `blockTag: 'pending'` for a read that pins one block: the pending block has no fixed state, and its number
 * names no block a call can read yet.
 *
 * @param options - Checked read options ({@link readOptions}).
 * @throws {InvalidArgumentError} When `blockTag` is `'pending'`.
 */
export function assertPinnable(options: Pick<ReadOptions, 'blockTag'>): void {
  if (options.blockTag === 'pending')
    throw new InvalidArgumentError(
      "blockTag 'pending' names no fixed block for this read to pin: pass 'latest' or a blockNumber",
      { parameter: 'blockTag', value: options.blockTag },
    )
}

/**
 * The options with one block pinned: `blockNumber` as given, else the number of the block `blockTag` names, else the
 * latest block's number (read uncached). A read that makes more than one call pins first, so every call reads one
 * block; viem may split a long multicall into several `eth_call`s, which `latest` alone could spread across blocks.
 * `'pending'` is refused ({@link assertPinnable}).
 *
 * @param client - A viem client.
 * @param options - Checked read options ({@link readOptions}).
 * @returns The options, with `blockNumber` set and no `blockTag`.
 */
export async function pin(
  client: AnyClient,
  options: ReadOptions,
): Promise<ReadOptions & { blockNumber: bigint }> {
  assertPinnable(options)
  if (options.blockNumber !== undefined)
    return { ...options, blockNumber: options.blockNumber }
  const { blockTag, ...rest } = options
  if (blockTag === undefined || blockTag === 'latest')
    return {
      ...rest,
      blockNumber: await getBlockNumber(client, { cacheTime: 0 }),
    }
  const block = await getBlock(client, { blockTag })
  if (block.number === null)
    throw new UnexpectedResponseError(
      `the node answered the ${blockTag} block without a number to pin the reads to`,
      { value: block.number },
    )
  return { ...rest, blockNumber: block.number }
}

/** A view (or pure function) of `abi`: what a {@link Read} may call. */
export type ViewName<abi extends Abi> = ContractFunctionName<
  abi,
  'pure' | 'view'
>
/** A view's arguments, from the ABI. */
export type ViewArgs<
  abi extends Abi,
  functionName extends ViewName<abi>,
> = ContractFunctionArgs<abi, 'pure' | 'view', functionName>
/** A view's decoded value, from the ABI. */
export type ViewValue<
  abi extends Abi,
  functionName extends ViewName<abi>,
> = ContractFunctionReturnType<abi, 'pure' | 'view', functionName>

/** One call of a {@link readMany}: make one with {@link readOf} (or `VenueReads.read`), which types it by the ABI. */
export type Read<
  abi extends Abi = Abi,
  functionName extends string = string,
> = {
  address: Address
  abi: abi
  functionName: functionName
  args?: readonly unknown[] | undefined
}

/**
 * One view call for a {@link readMany}, its name and arguments checked against `abi` at compile time.
 *
 * @param address - The contract.
 * @param abi - Its ABI.
 * @param functionName - One of its views.
 * @param args - The view's arguments, as the ABI types them.
 * @returns The read.
 */
export function readOf<
  const abi extends Abi,
  functionName extends ViewName<abi>,
>(
  address: Address,
  abi: abi,
  functionName: functionName,
  args?: ViewArgs<abi, functionName>,
): Read<abi, functionName> {
  return {
    address,
    abi,
    functionName,
    args: (args ?? []) as readonly unknown[],
  }
}

/** One call's outcome in a {@link readMany}: viem's multicall result, with the read that produced it. */
export type Result =
  | { status: 'success'; result: unknown; read: Read }
  | { status: 'failure'; error: Error; read: Read; aggregateFailure?: true }

/** The errors {@link readMany} throws: viem's for the multicall. A call that fails on its own is a failed result. */
export type ReadManyErrorType = MulticallErrorType

/**
 * Runs reads in one multicall, each allowed to fail on its own, with the read options given (pin a block first with
 * {@link pin}). Uses the chain's Multicall3, else `multicallAddress`, else a deployless call (no address assumed;
 * Tempo's chains configure none).
 *
 * @param client - A viem client.
 * @param reads - The calls, in order.
 * @param options - Checked read options and an optional Multicall3 address.
 * @returns One result per call, in order.
 */
export async function readMany(
  client: AnyClient,
  reads: readonly Read[],
  options: ReadOptions & { multicallAddress?: Address | undefined } = {},
): Promise<Result[]> {
  if (reads.length === 0) return []
  const { account, multicallAddress, ...at } = options
  const where = client.chain?.contracts?.multicall3
    ? {}
    : multicallAddress
      ? { multicallAddress }
      : { deployless: true }
  // viem's allowFailure also turns a rejected aggregate3 into per-view failures.
  // Capture that boundary before it does so: a failed aggregate says nothing about
  // any venue. Disable its cross-request scheduler so every aggregate passes this
  // boundary, retaining the configured chunk size and the original rejection.
  const batch = client.batch?.multicall
  const aggregateErrors = new Set<unknown>()
  const aggregateClient = {
    ...client,
    batch: { ...client.batch, multicall: false },
    readContract: async (parameters: Parameters<typeof readContract>[1]) => {
      try {
        return await getAction(client, readContract, 'readContract')(parameters)
      } catch (error) {
        aggregateErrors.add(error)
        throw error
      }
    },
  }
  const results = await multicall(aggregateClient, {
    batchSize: typeof batch === 'object' ? batch.batchSize : undefined,
    deployless: typeof batch === 'object' ? batch.deployless : undefined,
    contracts: reads,
    allowFailure: true,
    // Multicall3 is the caller of every call in it; `account` is the multicall's own sender.
    ...(account === undefined
      ? {}
      : {
          account: typeof account === 'string' ? account : account.address,
        }),
    ...at,
    ...where,
  } as never)
  return results.map(
    (r, i) =>
      ({
        ...r,
        read: reads[i],
        ...(r.status === 'failure' && aggregateErrors.has(r.error)
          ? { aggregateFailure: true }
          : {}),
      }) as Result,
  )
}

/** The values of `reads`, in order, each typed by the view it calls. */
export type Values<reads extends readonly Read[]> = {
  -readonly [K in keyof reads]: reads[K] extends Read<infer abi, infer name>
    ? abi extends Abi
      ? name extends ViewName<abi>
        ? ViewValue<abi, name>
        : unknown
      : unknown
    : unknown
}

/**
 * Runs `reads` in one multicall ({@link readMany}) and returns their values, each typed by the view it calls: every
 * read must succeed (a failed one throws viem's error for it).
 *
 * @param client - A viem client.
 * @param reads - The reads, in order.
 * @param options - Checked read options and an optional Multicall3 address.
 * @returns Their values, in order.
 */
export async function readValues<const reads extends readonly Read[]>(
  client: AnyClient,
  reads: reads,
  options: ReadOptions & { multicallAddress?: Address | undefined } = {},
): Promise<Values<reads>> {
  const results = await readMany(client, reads, options)
  return reads.map((r, i) => readValue(results[i], r)) as Values<reads>
}

/**
 * Returns a successful read's value after checking its ABI, view, target and ABI-encoded arguments against the expected read.
 * A failed matching read throws viem's error.
 *
 * @param result - The read's result.
 * @param expected - The intended read, independent of the result's producing read.
 * @param what - The read, for the error (default its view's name).
 * @returns Its value, as the ABI types it.
 */
export function readValue<
  const abi extends Abi,
  functionName extends ViewName<abi>,
>(
  result: Result | undefined,
  expected: Read<abi, functionName>,
  what: string = expected.functionName,
): ViewValue<abi, functionName> {
  if (!result) {
    throw new SnapshotIncompleteError(
      `${what}: the multicall returned no result for it`,
    )
  }
  if (
    result.read.abi !== expected.abi ||
    result.read.functionName !== expected.functionName ||
    !isAddressEqual(result.read.address, expected.address) ||
    encodeFunctionData(result.read as never) !==
      encodeFunctionData(expected as never)
  )
    throw new BaseError(
      `${what}: decoded from a different ${result.read.functionName} read (an SDK bug: please report it)`,
    )
  if (result.status !== 'success') throw result.error
  return result.result as ViewValue<abi, functionName>
}
