// Simulation and gas for steps. A step is one transaction from one signer: one call, or a Tempo `calls` batch (0x76) of
// several, which is atomic: if a call fails, no later call of the step runs and every effect of the step reverts.
// Several steps simulate in sequence, one block each with state carried, so a later step sees an earlier one.
import {
  type Account,
  type Address,
  type BlockOverrides,
  type BlockTag,
  type EncodeFunctionDataErrorType,
  type EstimateGasErrorType,
  encodeFunctionData,
  type GetBlockErrorType,
  type Hex,
  isHex,
  type Log,
  numberToHex,
  type SimulateBlocksErrorType,
  type StateOverride,
} from 'viem'
import {
  getBlock,
  simulateBlocks,
  estimateGas as viemEstimateGas,
} from 'viem/actions'
import type { PreparedCall } from './actions/internal/define.js'
import * as Errors from './Errors.js'
import * as Events from './Events.js'
import type { FeeParameters } from './Info.js'
import { isTempoChain } from './internal/chain.js'
import {
  EmptyBatchError,
  type EmptyBatchErrorType,
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  UnexpectedResponseError,
  type UnexpectedResponseErrorType,
} from './internal/errors.js'
import {
  assertPinnable,
  type ReadOptionsErrorType,
  readOptions,
} from './internal/read.js'
import type { AnyClient } from './internal/types.js'
import * as validate from './internal/validate.js'

/** The events `Events.parse` decodes from a call's logs. */
type DecodedEvents = ReturnType<typeof Events.parse>

/**
 * A call in a step: `{ to, data }` at least. A typed call (a `PreparedCall`) carries its ABI, so its result decodes;
 * its `abi`, `functionName` and `args` must encode its `data`.
 *
 * @example
 * ```ts
 * import { Actions, type Plan } from '@tempoxyz/propamm-sdk'
 *
 * const typed: Plan.Call = Actions.venue.setHalted.call({
 *   venue: '0x1111111111111111111111111111111111111111',
 *   halted: true,
 * })
 * const raw: Plan.Call = { to: typed.to, data: typed.data }
 * console.log(typed.functionName, raw.data === typed.data)
 * ```
 */
export type Call = Pick<PreparedCall, 'to' | 'data'> & {
  [key in 'abi' | 'functionName' | 'args' | 'signer' | 'contract']?:
    | PreparedCall[key]
    | undefined
}

/**
 * One transaction from one sender: one call, or a Tempo `calls` batch of several (a viem/tempo chain only), with the
 * fee fields it would pay (the venue's fee cap judges its priority fee). Under a cap, use `Fees.takerFields` and reuse
 * its result for simulation, gas estimation and submission; omitted fields simulate a zero priority fee.
 *
 * @example
 * ```ts
 * import { Actions, Fees, type Plan } from '@tempoxyz/propamm-sdk'
 *
 * const venue = '0x1111111111111111111111111111111111111111'
 * const step: Plan.Step = {
 *   account: '0x3333333333333333333333333333333333333333',
 *   calls: [
 *     Actions.venue.setHalted.call({ venue, halted: true }),
 *     Actions.venue.setHalted.call({ venue, halted: false }),
 *   ],
 *   ...Fees.takerFields(20_000_000_000n, 10n * Fees.gwei, Fees.gwei),
 * }
 * console.log(step.calls.length)
 * ```
 */
export type Step = FeeParameters & {
  account: Account | Address
  calls: readonly Call[]
}

/**
 * One call's result in a simulated step:
 * - `success`: it ran and its step succeeded; its decoded result (typed calls only, else null), gas and events.
 * - `failure`: it reverted, so its step reverts as a whole; the decoded revert and viem's error.
 * - `rolledBack`: it ran before its step's failing call, which undid it; its result and gas, and no events, as a
 *   reverted transaction emits none.
 * - `notRun`: it comes after its step's failing call, so it never runs.
 *
 * @example
 * ```ts
 * import { Actions, Plan } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const [step] = await Plan.simulate(client, {
 *   steps: [
 *     {
 *       account: '0x3333333333333333333333333333333333333333',
 *       calls: [Actions.venue.setHalted.call({ venue: '0x1111111111111111111111111111111111111111', halted: true })],
 *     },
 *   ],
 * })
 * const call: Plan.CallResult | undefined = step?.calls[0]
 * console.log(call?.status === 'failure' ? call.error?.errorName : call?.status)
 * ```
 */
export type CallResult =
  | {
      status: 'success'
      /** The decoded return value for a typed call, else null. */
      result: unknown
      gasUsed: bigint
      logs: Log[]
      events: DecodedEvents
    }
  | {
      status: 'failure'
      /** The decoded revert (`Errors.decode`), or null for a failure that carries none. */
      error: Errors.Decoded | null
      /** viem's error for the revert. */
      cause: Error | undefined
      gasUsed: bigint
    }
  | { status: 'rolledBack'; result: unknown; gasUsed: bigint }
  | { status: 'notRun' }

/**
 * A simulated step: `success` with every call's result, or `failure`, the whole step reverted, with the index of the
 * call that failed and its decoded revert. `gasUsed` adds up the calls that ran.
 *
 * @example
 * ```ts
 * import { Actions, Plan } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const results: Plan.StepResult[] = await Plan.simulate(client, {
 *   steps: [
 *     {
 *       account: '0x3333333333333333333333333333333333333333',
 *       calls: [Actions.venue.setHalted.call({ venue: '0x1111111111111111111111111111111111111111', halted: true })],
 *     },
 *   ],
 * })
 * for (const r of results)
 *   console.log(r.status === 'success' ? r.gasUsed : `call ${r.failedCall}: ${r.error?.errorName}`)
 * ```
 */
export type StepResult =
  | { status: 'success'; calls: CallResult[]; gasUsed: bigint }
  | {
      status: 'failure'
      calls: CallResult[]
      /** The index of the call that reverted. */
      failedCall: number
      /** Its decoded revert, as in its call result. */
      error: Errors.Decoded | null
      gasUsed: bigint
    }

/**
 * Simulates steps in order with `eth_simulateV1`, one block per step with state carried, without validation, so no
 * fee balance or nonce is needed. Reports each call's status, gas, decoded result (typed calls decode through viem) or
 * decoded revert, and its decoded events.
 *
 * The steps follow one base block: `blockNumber`, else the block `blockTag` names (`'pending'` is refused), else the
 * latest, read first. Each step's block carries the base block's `baseFeePerGas`, so the venue judges a step's
 * priority fee as it would onchain (`eth_simulateV1` would otherwise run at base fee 0), and a timestamp one second
 * after the block before it, the least `eth_simulateV1` accepts (it would otherwise add 12 seconds a block, expiring
 * quotes that are still live). `blockOverrides` apply to every step's block on top of those; a `time` or `number` given
 * is the first step's, and each later step's is one more.
 *
 * A step is atomic, as the Tempo batch it stands for: viem simulates each call as its own transaction, so when one
 * reverts the SDK marks the step's earlier calls `rolledBack` and its later ones `notRun`, and simulates the later
 * steps again on the same base block, with that step left out (an empty block with the same overrides), so they never
 * see its effects. One `eth_simulateV1` when no step fails, one more per failed step that has steps after it.
 *
 * Calls of one step run as separate transactions in the simulation, so they share no transient storage (the propAMM
 * v2 contracts keep none across calls: their locks and hook state clear at the end of each call), and `gasUsed` is per
 * transaction and mostly omits Tempo's state-creation cost (TIP-1000: about 250k gas per new slot): use `estimateGas`
 * for a gas limit. A step of several calls needs a viem/tempo chain, as sending it would.
 *
 * @example
 * ```ts
 * import { Actions, Plan } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const venue = '0x1111111111111111111111111111111111111111'
 * const [haltAndResume, halt] = await Plan.simulate(client, {
 *   steps: [
 *     {
 *       account: '0x3333333333333333333333333333333333333333',
 *       calls: [
 *         Actions.venue.setHalted.call({ venue, halted: true }),
 *         Actions.venue.setHalted.call({ venue, halted: false }),
 *       ],
 *     },
 *     {
 *       account: '0x3333333333333333333333333333333333333333',
 *       calls: [Actions.venue.setHalted.call({ venue, halted: true })],
 *     },
 *   ],
 * })
 * // The first step halts the venue and resumes it; the second sees it running and halts it.
 * console.log(haltAndResume?.status, halt?.status)
 * ```
 *
 * @param client - A viem client: a viem/tempo chain for a step of several calls.
 * @param parameters - The steps, the base block (default the latest), and any block and state overrides.
 * @returns One result per step, in order.
 */
export async function simulate(
  client: AnyClient,
  parameters: simulate.Parameters,
): Promise<simulate.ReturnValue> {
  if (typeof parameters !== 'object' || parameters === null)
    throw new InvalidArgumentError('parameters must be { steps }', {
      parameter: 'parameters',
      value: parameters,
    })
  if (!Array.isArray(parameters.steps))
    throw new InvalidArgumentError('steps must be an array of steps', {
      parameter: 'steps',
      value: parameters.steps,
    })
  const steps = parameters.steps.map((step, i) =>
    checkStep(client, step, `steps[${i}]`),
  )
  const options = readOptions({
    blockNumber: parameters.blockNumber,
    blockOverrides: parameters.blockOverrides,
    blockTag: parameters.blockTag,
    stateOverride: parameters.stateOverride,
  })
  assertPinnable(options)
  if (steps.length === 0) return []

  // The base block, read once: every simulation, and every re-simulation after a failed step, runs on it.
  const base = await getBlock(
    client,
    options.blockNumber !== undefined
      ? { blockNumber: options.blockNumber }
      : { blockTag: options.blockTag ?? 'latest' },
  )
  if (base.number === null)
    throw new UnexpectedResponseError(
      'the node answered the block to simulate on without a number',
      { value: base.number },
    )
  const { time, number, ...given } = options.blockOverrides ?? {}
  const firstTime = time ?? base.timestamp + 1n
  const blockOverrides = (i: number): BlockOverrides => ({
    ...(base.baseFeePerGas === null
      ? {}
      : { baseFeePerGas: base.baseFeePerGas }),
    ...given,
    time: firstTime + BigInt(i),
    ...(number === undefined ? {} : { number: number + BigInt(i) }),
  })

  const blocks: {
    blockOverrides: BlockOverrides
    calls: readonly unknown[]
    stateOverrides?: StateOverride
  }[] = steps.map((step, i) => ({
    blockOverrides: blockOverrides(i),
    calls: step.calls.map((call) => ({
      account: step.account,
      to: call.to,
      data: call.data,
      // A typed call decodes through viem: it encodes the same data (`checkStep`).
      ...(call.abi === undefined
        ? {}
        : {
            abi: call.abi,
            functionName: call.functionName,
            args: call.args,
          }),
      ...step.fees,
    })),
    ...(i === 0 && options.stateOverride !== undefined
      ? { stateOverrides: options.stateOverride }
      : {}),
  }))

  const results: StepResult[] = []
  for (;;) {
    const simulated = (await simulateBlocks(client, {
      blocks,
      validation: false,
      blockNumber: base.number,
    } as never)) as unknown as readonly SimulatedBlock[]
    if (simulated.length !== blocks.length)
      throw new UnexpectedResponseError(
        `eth_simulateV1 answered ${simulated.length} blocks for ${blocks.length} steps`,
        { value: simulated.length },
      )
    let failed = -1
    for (let i = results.length; i < steps.length; i++) {
      const result = stepResult(
        steps[i] as CheckedStep,
        (simulated[i] as SimulatedBlock).calls,
      )
      results.push(result)
      if (result.status === 'failure') {
        failed = i
        break
      }
    }
    if (failed === -1 || failed === steps.length - 1) return results
    // The batch reverts as a whole: the later steps run again without it, on the same base block and overrides.
    blocks[failed] = {
      ...(blocks[failed] as (typeof blocks)[number]),
      calls: [],
    }
  }
}

export declare namespace simulate {
  /** The steps, the block to simulate on (default the latest) with any block overrides for every step's block, and any
   * state override, applied before the first. */
  type Parameters = {
    steps: readonly Step[]
    blockNumber?: bigint | undefined
    blockTag?: BlockTag | undefined
    blockOverrides?: BlockOverrides | undefined
    stateOverride?: StateOverride | undefined
  }
  /** One result per step, in order. */
  type ReturnValue = StepResult[]
  /** The errors `simulate` throws. */
  type ErrorType =
    | EmptyBatchErrorType
    | EncodeFunctionDataErrorType
    | GetBlockErrorType
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadOptionsErrorType
    | SimulateBlocksErrorType
    | UnexpectedResponseErrorType
    | GlobalErrorType
}

/**
 * The exact gas of a step as one transaction (`eth_estimateGas`, with `calls` for a batch on a viem/tempo chain),
 * Tempo's state creation included. A step that depends on an earlier step not yet mined can't be estimated exactly:
 * its simulated gas is only a floor.
 *
 * @example
 * ```ts
 * import { Actions, Plan } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const venue = '0x1111111111111111111111111111111111111111'
 * const gas = await Plan.estimateGas(client, {
 *   account: '0x3333333333333333333333333333333333333333',
 *   calls: [Actions.venue.setHalted.call({ venue, halted: true })],
 * })
 * console.log(Plan.gasLimit(gas))
 * ```
 *
 * @param client - A viem client: a viem/tempo chain for a step of several calls.
 * @param parameters - The step, and the block to estimate on with any state override.
 * @returns The step's gas.
 */
export async function estimateGas(
  client: AnyClient,
  parameters: estimateGas.Parameters,
): Promise<estimateGas.ReturnValue> {
  const step = checkStep(client, parameters, 'step')
  const at = readOptions({
    blockNumber: parameters.blockNumber,
    blockTag: parameters.blockTag,
    stateOverride: parameters.stateOverride,
  })
  const [call] = step.calls as [Call]
  // viem's Tempo formatter clears fees for estimateGas, including explicit ones.
  // Keep its estimate-specific formatting (calls, account/key hints, etc.) and
  // restore only the caller's fees. Scope the formatter to this estimate; never
  // mutate the shared chain or bypass viem's preparation and error handling.
  const formatter = client.chain?.formatters?.transactionRequest
  const estimateClient =
    client.chain &&
    formatter &&
    (step.fees.maxFeePerGas !== undefined ||
      step.fees.maxPriorityFeePerGas !== undefined)
      ? {
          ...client,
          // A public client's action closes over the original client. Let viem's
          // getAction use its fallback with this scoped client for nested estimates
          // during local-account preparation (e.g. without eth_fillTransaction).
          estimateGas: undefined,
          chain: {
            ...client.chain,
            formatters: {
              ...client.chain?.formatters,
              transactionRequest: {
                ...formatter,
                format: (...args: Parameters<typeof formatter.format>) => ({
                  ...formatter.format(...args),
                  ...(args[1] === 'estimateGas'
                    ? {
                        ...(step.fees.maxFeePerGas !== undefined
                          ? {
                              maxFeePerGas: numberToHex(step.fees.maxFeePerGas),
                            }
                          : {}),
                        ...(step.fees.maxPriorityFeePerGas !== undefined
                          ? {
                              maxPriorityFeePerGas: numberToHex(
                                step.fees.maxPriorityFeePerGas,
                              ),
                            }
                          : {}),
                      }
                    : {}),
                }),
              },
            },
          },
        }
      : client
  return viemEstimateGas(estimateClient, {
    account: step.account,
    // Full local-account preparation may return eth_fillTransaction gas before
    // viem sends the requested block and state override to eth_estimateGas.
    // Keep the account for chain formatting, but use address-style preparation.
    ...(at.blockNumber !== undefined ||
    at.blockTag !== undefined ||
    at.stateOverride !== undefined
      ? { prepare: ['blobVersionedHashes'] }
      : {}),
    ...(step.calls.length === 1
      ? { to: call.to, data: call.data }
      : { calls: step.calls.map((c) => ({ to: c.to, data: c.data })) }),
    ...step.fees,
    ...at,
  } as never)
}

export declare namespace estimateGas {
  /** The step, and the block to estimate on (default the latest) with any state override. */
  type Parameters = Step & {
    blockNumber?: bigint | undefined
    blockTag?: BlockTag | undefined
    stateOverride?: StateOverride | undefined
  }
  /** The step's gas. */
  type ReturnValue = bigint
  /** The errors `estimateGas` throws. */
  type ErrorType =
    | EmptyBatchErrorType
    | EncodeFunctionDataErrorType
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ReadOptionsErrorType
    | EstimateGasErrorType
    | GlobalErrorType
}

/**
 * The gas limit `gasLimit` sets, as a percentage of the estimate: Forge's default `--gas-estimate-multiplier`, which is
 * a percentage too. `Fees.defaultBaseFeeMultiplier` is a factor (3) instead, as viem's `baseFeeMultiplier` is.
 *
 * @example
 * ```ts
 * import { Plan } from '@tempoxyz/propamm-sdk'
 *
 * console.log(Plan.gasEstimateMultiplier) // 130n: a 30% margin
 * ```
 */
export const gasEstimateMultiplier = 130n

/**
 * A gas limit from an exact estimate: 130% of it (`gasEstimateMultiplier`, Forge's default), rounded up. At this limit a
 * `setMembers` or `setDenied` of about 90 new accounts (about 255k gas each) still fits Tempo's 30M transaction cap, a
 * full `Venue.maxBatch` of 100 doesn't (33.2M), and 50 (16.6M) leaves room.
 *
 * @example
 * ```ts
 * import { Plan } from '@tempoxyz/propamm-sdk'
 *
 * console.log(Plan.gasLimit(100_000n)) // 130000n
 * ```
 *
 * @param estimate - The step's gas, from `estimateGas`.
 * @returns The gas limit to send it with.
 */
export function gasLimit(estimate: bigint): gasLimit.ReturnValue {
  const gas = validate.uintBigint(estimate, 64, 'estimate')
  return (gas * gasEstimateMultiplier + 99n) / 100n
}

export declare namespace gasLimit {
  /** The gas limit to send the step with. */
  type ReturnValue = bigint
  /** The errors `gasLimit` throws. */
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/** A step checked: its sender, calls and fee fields. */
type CheckedStep = {
  account: Account | Address
  calls: readonly Call[]
  fees: { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint }
}

/** A block `simulateBlocks` returns, as `simulate` reads it. */
type SimulatedBlock = {
  number: bigint | null
  calls: readonly {
    status: 'success' | 'failure'
    gasUsed: bigint
    data: Hex
    logs?: Log[] | undefined
    result?: unknown
    error?: Error | undefined
  }[]
}

/** Checks a step before any request: its sender, its calls (at least one), each call's ABI against its data, its fees,
 * and a viem/tempo chain for a batch. */
function checkStep(client: AnyClient, step: Step, name: string): CheckedStep {
  if (typeof step !== 'object' || step === null)
    throw new InvalidArgumentError(`${name} must be { account, calls }`, {
      parameter: name,
      value: step,
    })
  const account = validate.account(step.account, `${name}.account`)
  if (!Array.isArray(step.calls))
    throw new InvalidArgumentError(`${name}.calls must be an array of calls`, {
      parameter: `${name}.calls`,
      value: step.calls,
    })
  if (step.calls.length === 0)
    throw new EmptyBatchError(`${name} needs at least one call`)
  if (step.calls.length > 1 && !isTempoChain(client.chain))
    throw new InvalidArgumentError(
      `${name} has several calls, a Tempo calls batch: use a viem/tempo chain`,
      { parameter: 'client', value: client.chain?.id },
    )
  const calls = step.calls.map((call, i) =>
    checkCall(call, `${name}.calls[${i}]`),
  )
  return { account, calls, fees: validate.fees(step, `${name}.`) }
}

/** A call's target and data, and, for a typed call, that its ABI encodes that data. */
function checkCall(call: Call, name: string): Call {
  if (typeof call !== 'object' || call === null)
    throw new InvalidArgumentError(`${name} must be { to, data }`, {
      parameter: name,
      value: call,
    })
  const to = validate.address(call.to, `${name}.to`)
  if (!isHex(call.data) || call.data.length % 2 !== 0)
    throw new InvalidArgumentError(`${name}.data must be bytes of hex`, {
      parameter: `${name}.data`,
      value: call.data,
    })
  if (
    call.abi === undefined &&
    call.functionName === undefined &&
    call.args === undefined
  )
    return { to, data: call.data }
  if (call.abi === undefined || call.functionName === undefined)
    throw new InvalidArgumentError(
      `${name} has args or a functionName without its abi: pass all three, or only { to, data }`,
      { parameter: name, value: call },
    )
  let encoded: Hex
  try {
    encoded = encodeFunctionData({
      abi: call.abi,
      functionName: call.functionName,
      args: call.args ?? [],
    } as never)
  } catch (cause) {
    throw new InvalidArgumentError(
      `${name}'s abi, functionName and args do not encode a call`,
      {
        parameter: name,
        value: call.functionName,
        ...(cause instanceof Error ? { cause } : {}),
      },
    )
  }
  if (encoded.toLowerCase() !== call.data.toLowerCase())
    throw new InvalidArgumentError(
      `${name}'s abi, functionName and args encode other data than its data`,
      { parameter: `${name}.data`, value: call.data },
    )
  return {
    to,
    data: call.data,
    abi: call.abi,
    functionName: call.functionName,
    args: call.args ?? [],
  }
}

/** One step's result from its simulated calls: atomic, so a failed call fails the step, undoes the calls before it and
 * runs none after it. */
function stepResult(
  step: CheckedStep,
  simulated: SimulatedBlock['calls'],
): StepResult {
  if (simulated.length !== step.calls.length)
    throw new UnexpectedResponseError(
      `eth_simulateV1 answered ${simulated.length} results for a step of ${step.calls.length} calls`,
      { value: simulated.length },
    )
  const failedCall = simulated.findIndex((c) => c.status !== 'success')
  const gasUsed = simulated
    .slice(0, failedCall === -1 ? undefined : failedCall + 1)
    .reduce((sum, c) => sum + c.gasUsed, 0n)
  if (failedCall === -1)
    return {
      status: 'success',
      calls: simulated.map((c) => {
        const logs = c.logs ?? []
        return {
          status: 'success',
          result: c.result ?? null,
          gasUsed: c.gasUsed,
          logs,
          events: Events.parse(logs),
        }
      }),
      gasUsed,
    }
  const failure = simulated[failedCall] as SimulatedBlock['calls'][number]
  const error = Errors.decode(failure.data ?? '0x')
  return {
    status: 'failure',
    calls: simulated.map((c, i): CallResult => {
      if (i < failedCall)
        return {
          status: 'rolledBack',
          result: c.result ?? null,
          gasUsed: c.gasUsed,
        }
      if (i === failedCall)
        return {
          status: 'failure',
          error,
          cause: c.error,
          gasUsed: c.gasUsed,
        }
      return { status: 'notRun' }
    }),
    failedCall,
    error,
    gasUsed,
  }
}
