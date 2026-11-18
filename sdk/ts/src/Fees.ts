// The venue's taker priority-fee cap, from both sides: what a take may pay (`allows`), what a post should pay
// (`makerTip`), and the fee fields that pay it in full (`feeFields`). `Venue._priorityFeeTooHigh` is the rule. A tip is
// a priority fee per gas: what a transaction's `maxPriorityFeePerGas` offers, and `tx.gasprice - block.basefee` as the
// venue judges it; every parameter here names it `priorityFee`, in wei per gas.
import { maxUint256 } from 'viem'
import { Venue } from './generated/constants.js'
import {
  type GlobalErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  show,
} from './internal/errors.js'
import { uintBigint as uint } from './internal/validate.js'

/**
 * 1 gwei, in wei (1e9).
 *
 * @example
 * ```ts
 * import { Fees } from '@tempoxyz/propamm-sdk'
 *
 * const tip = 2n * Fees.gwei // 2 gwei per gas
 * ```
 */
export const gwei = 1_000_000_000n

/**
 * How far above a venue's cap {@link makerTip} tips by default: 1 gwei, in wei per gas.
 *
 * @example
 * ```ts
 * import { Fees, Venue } from '@tempoxyz/propamm-sdk'
 *
 * Fees.makerTip(Venue.defaultTakerPriorityFeeCap) === Venue.defaultTakerPriorityFeeCap + Fees.defaultMakerMargin // true
 * ```
 */
export const defaultMakerMargin = gwei

/**
 * How far {@link feeFields} lets the base fee rise before the tip is cut: 3, a factor of the current base fee, as
 * viem's `estimateFeesPerGas` takes its `baseFeeMultiplier` (viem's default is 1.2). `Plan.gasEstimateMultiplier` is a
 * percentage instead (130n), as Forge's `--gas-estimate-multiplier` is: each follows the tool it mirrors.
 *
 * @example
 * ```ts
 * import { Fees } from '@tempoxyz/propamm-sdk'
 *
 * Fees.feeFields(10n * Fees.gwei, Fees.gwei, { baseFeeMultiplier: Fees.defaultBaseFeeMultiplier })
 * ```
 */
export const defaultBaseFeeMultiplier = 3

/**
 * Whether a venue's `maxTakerPriorityFee` means no cap: `Venue.noPriorityFeeCap` (`type(uint64).max`), a new venue's
 * setting, which the venue stores as 0 and never checks a fee against.
 *
 * @example
 * ```ts
 * import { Fees, Venue } from '@tempoxyz/propamm-sdk'
 *
 * Fees.isNoCap(Venue.noPriorityFeeCap) // true
 * Fees.isNoCap(Venue.defaultTakerPriorityFeeCap) // false
 * ```
 *
 * @param cap - The venue's `maxTakerPriorityFee`, in wei per gas (`uint64`).
 * @returns `true` for `type(uint64).max`.
 * @throws {InvalidArgumentError} When `cap` isn't a `uint64` bigint.
 */
export function isNoCap(cap: bigint): boolean {
  return uint(cap, 64, 'cap') === Venue.noPriorityFeeCap
}

export declare namespace isNoCap {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * The priority fee the venue judges, per gas: `tx.gasprice - block.basefee`, or 0 when the gas price is below the base
 * fee (only a call simulated without fees has one).
 *
 * @example
 * ```ts
 * import { Fees } from '@tempoxyz/propamm-sdk'
 *
 * Fees.priorityFee(12n * Fees.gwei, 10n * Fees.gwei) // 2 gwei
 * ```
 *
 * @param gasPrice - The transaction's effective gas price, in wei per gas.
 * @param baseFee - The block's base fee, in wei per gas.
 * @returns The priority fee, in wei per gas.
 * @throws {InvalidArgumentError} When either isn't a `uint256` bigint.
 */
export function priorityFee(gasPrice: bigint, baseFee: bigint): bigint {
  uint(gasPrice, 256, 'gasPrice')
  uint(baseFee, 256, 'baseFee')
  return gasPrice > baseFee ? gasPrice - baseFee : 0n
}

export declare namespace priorityFee {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * Whether a transaction whose priority fee is `priorityFee` passes a venue's cap, exactly as
 * `Venue._priorityFeeTooHigh` decides: always without a cap, else when `priorityFee <= cap`. `fill` and `quote` revert
 * `TakerPriorityFeeTooHigh` otherwise.
 *
 * @example
 * ```ts
 * import { Fees, Venue } from '@tempoxyz/propamm-sdk'
 *
 * Fees.allows(Venue.defaultTakerPriorityFeeCap, 10n * Fees.gwei) // true: at the cap
 * Fees.allows(Venue.defaultTakerPriorityFeeCap, 11n * Fees.gwei) // false
 * ```
 *
 * @param cap - The venue's `maxTakerPriorityFee`, in wei per gas (`uint64`).
 * @param priorityFee - The transaction's priority fee, in wei per gas (see {@link priorityFee}).
 * @returns `true` when the venue would let the take through its cap.
 * @throws {InvalidArgumentError} When `cap` isn't a `uint64` or `priorityFee` a `uint256` bigint.
 */
export function allows(cap: bigint, priorityFee: bigint): boolean {
  uint(priorityFee, 256, 'priorityFee')
  return isNoCap(cap) || priorityFee <= cap
}

export declare namespace allows {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * The priority fee (tip) every `post` (and `setShape`) should pay: strictly above the cap, by `margin`, so no take can
 * pay as much.
 * A builder that orders by priority fee then puts the post ahead of every take pending with it at the quote it
 * replaces. A streaming builder, such as Tempo's, orders by arrival: a take that reaches it first still fills at the
 * old quote. Without a cap, `margin` alone.
 *
 * @example
 * ```ts
 * import { Fees, Venue } from '@tempoxyz/propamm-sdk'
 *
 * Fees.makerTip(Venue.defaultTakerPriorityFeeCap) // 11 gwei
 * Fees.makerTip(Venue.noPriorityFeeCap) // 1 gwei: no cap to clear
 * ```
 *
 * @param cap - The venue's `maxTakerPriorityFee`, in wei per gas (`uint64`).
 * @param margin - How far above the cap, in wei per gas: at least 1 ({@link defaultMakerMargin} by default).
 * @returns The tip, in wei per gas.
 * @throws {InvalidArgumentError} When `cap` isn't a `uint64` bigint, or `margin` isn't a bigint of at least 1.
 */
export function makerTip(
  cap: bigint,
  margin: bigint = defaultMakerMargin,
): bigint {
  const noCap = isNoCap(cap)
  if (typeof margin !== 'bigint' || margin < 1n)
    throw new InvalidArgumentError(
      `a maker tip margin is at least 1 wei per gas, got ${show(margin)}`,
      { parameter: 'margin', value: margin },
    )
  return noCap ? margin : cap + margin
}

export declare namespace makerTip {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * EIP-1559 fee fields that pay `priorityFee` in full, the venue-cap-aware counterpart of viem's `estimateFeesPerGas`:
 * the same formula, `maxFeePerGas = baseFee x baseFeeMultiplier + priorityFee`, but with the tip fixed rather than
 * estimated, since the venue judges it against its cap (a post tips {@link makerTip}, a take at most the cap), and with
 * more headroom by default (3, not viem's 1.2). The whole tip is paid while the base fee at inclusion stays at or under
 * `baseFee x baseFeeMultiplier`; above that the effective tip shrinks, which a post above the cap can't afford. A
 * multiplier with decimals scales the base fee exactly as viem's does.
 *
 * @example
 * ```ts
 * import { Fees, Venue } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { getBlock } from 'viem/actions'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const { baseFeePerGas } = await getBlock(client)
 * const fees = Fees.feeFields(baseFeePerGas ?? 0n, Fees.makerTip(Venue.defaultTakerPriorityFeeCap))
 * // Pass fees.maxFeePerGas and fees.maxPriorityFeePerGas to the post.
 * ```
 *
 * @param baseFee - The current base fee, in wei per gas.
 * @param priorityFee - The priority fee (tip) to pay in full, in wei per gas.
 * @param options - `baseFeeMultiplier`: how far the base fee may rise before the tip is cut, at least 1
 * ({@link defaultBaseFeeMultiplier} by default).
 * @returns `maxFeePerGas` and `maxPriorityFeePerGas`, in wei per gas.
 * @throws {InvalidArgumentError} When `baseFee` or `priorityFee` isn't a `uint256` bigint, or `baseFeeMultiplier` isn't a
 * finite number of at least 1.
 */
export function feeFields(
  baseFee: bigint,
  priorityFee: bigint,
  options: feeFields.Options = {},
): { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint } {
  uint(baseFee, 256, 'baseFee')
  uint(priorityFee, 256, 'priorityFee')
  const multiplier = options.baseFeeMultiplier ?? defaultBaseFeeMultiplier
  if (
    typeof multiplier !== 'number' ||
    !Number.isFinite(multiplier) ||
    multiplier < 1
  )
    throw new InvalidArgumentError(
      `baseFeeMultiplier must be a finite number of at least 1, got ${show(multiplier)}`,
      { parameter: 'baseFeeMultiplier', value: multiplier },
    )
  // viem's `estimateFeesPerGas` scaling: the multiplier as a fraction over a power of ten.
  const decimals = multiplier.toString().split('.')[1]?.length ?? 0
  const denominator = 10 ** decimals
  const scaled =
    (baseFee * BigInt(Math.round(multiplier * denominator))) /
    BigInt(denominator)
  const maxFeePerGas = scaled + priorityFee
  if (maxFeePerGas > maxUint256)
    throw new InvalidArgumentError('the fee fields overflow uint256', {
      parameter: 'priorityFee',
      value: priorityFee,
    })
  return { maxFeePerGas, maxPriorityFeePerGas: priorityFee }
}

export declare namespace feeFields {
  type Options = {
    /** How many times the current base fee may rise to before the tip is cut, at least 1. @default 3 */
    baseFeeMultiplier?: number | undefined
  }
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * EIP-1559 fee fields for a taker under `cap`: validates the priority fee the transaction will actually offer, then
 * returns the same fields as {@link feeFields}. Reuse the returned fields for `Plan.simulate`, gas estimation and the
 * submitted take. An `eth_call` or estimate without fee fields offers a zero priority fee, so it can pass this cap
 * while the submitted transaction fails.
 *
 * @example
 * ```ts
 * import { Fees, Venue } from '@tempoxyz/propamm-sdk'
 *
 * const fees = Fees.takerFields(
 *   20_000_000_000n,
 *   Venue.defaultTakerPriorityFeeCap,
 *   Fees.gwei,
 * )
 * // Spread `fees` into the simulation, gas estimate and submitted swap.
 * ```
 *
 * @param baseFee - The current base fee, in wei per gas.
 * @param cap - The venue's `maxTakerPriorityFee`, in wei per gas (`uint64`).
 * @param priorityFee - The priority fee the taker's transaction will offer, in wei per gas.
 * @param options - `baseFeeMultiplier`: how far the base fee may rise before the tip is cut, at least 1
 * ({@link defaultBaseFeeMultiplier} by default).
 * @returns `maxFeePerGas` and `maxPriorityFeePerGas`, in wei per gas, for the allowed take.
 * @throws {InvalidArgumentError} When a field is invalid, or `priorityFee` is above `cap`.
 */
export function takerFields(
  baseFee: bigint,
  cap: bigint,
  priorityFee: bigint,
  options: takerFields.Options = {},
): { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint } {
  const fields = feeFields(baseFee, priorityFee, options)
  if (!allows(cap, priorityFee))
    throw new InvalidArgumentError(
      `priorityFee must not exceed the venue's cap, got ${show(priorityFee)} above ${show(cap)}`,
      { parameter: 'priorityFee', value: priorityFee },
    )
  return fields
}

export declare namespace takerFields {
  type Options = feeFields.Options
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}
