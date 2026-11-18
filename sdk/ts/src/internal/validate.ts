// The SDK's input checks, shared by every module: one checker per kind of value, each returning its value or throwing
// the one class that kind is refused with, naming the parameter and the value (as `show` writes it). Internal: the
// package entry exports none of these.
import {
  type Account,
  type Address,
  getAddress,
  type Hex,
  isAddress,
  isHex,
  maxUint96,
  size,
  zeroAddress,
} from 'viem'
import { VirtualAddress } from 'viem/tempo'
import type * as HotWord from '../HotWord.js'
import {
  type BaseError,
  InvalidAddressError,
  InvalidArgumentError,
  InvalidPriceError,
  show,
} from './errors.js'

/** An error class a range check can throw: it takes the parameter refused and the value given. */
export type RangeErrorClass = new (
  shortMessage: string,
  parameters: { parameter: string; value: unknown },
) => BaseError

/** `[min, max]` as a message writes it: decimal up to 16 bits, `2^bits - 1` above. */
function range(min: number | bigint, bits: number): string {
  return `[${min}, ${bits <= 16 ? 2 ** bits - 1 : `2^${bits} - 1`}]`
}

/**
 * Whether `value` is a safe integer in `[0, 2^bits - 1]`: the rule every `uint8` to `uint48` input is held to.
 *
 * @param value - The value.
 * @param bits - The ABI width.
 * @returns `true` when it fits.
 */
export function isUintNumber(value: unknown, bits: number): value is number {
  return (
    Number.isSafeInteger(value) &&
    (value as number) >= 0 &&
    (value as number) <= 2 ** bits - 1
  )
}

/**
 * A safe integer in `[0, 2^bits - 1]`, for the ABI's `uint8` to `uint48` (viem types them as numbers).
 *
 * @param value - The value.
 * @param bits - The ABI width.
 * @param name - The parameter, as the error names it.
 * @param error - The class to throw (`InvalidArgumentError` by default).
 * @returns `value`.
 * @throws {InvalidArgumentError} Or `error`, naming `name` and the value, when it doesn't fit.
 */
export function uintNumber(
  value: number,
  bits: number,
  name: string,
  error: RangeErrorClass = InvalidArgumentError,
): number {
  if (!isUintNumber(value, bits)) {
    throw new error(
      `${name} must be an integer in ${range(0, bits)}, got ${show(value)}`,
      { parameter: name, value },
    )
  }
  return value
}

/**
 * Hex in lower case, still `Hex` (a string's `toLowerCase` forgets the type): the form selectors, words and data are
 * compared in.
 *
 * @param value - Hex.
 * @returns It in lower case.
 */
export const lowerHex = (value: Hex): Hex => value.toLowerCase() as Hex

/**
 * A bigint in `[0, 2^bits - 1]`, for the ABI's `uint64` and wider.
 *
 * @param value - The value.
 * @param bits - The ABI width.
 * @param name - The parameter, as the error names it.
 * @param error - The class to throw (`InvalidArgumentError` by default).
 * @returns `value`.
 * @throws {InvalidArgumentError} Or `error`, naming `name` and the value, when it doesn't fit.
 */
export function uintBigint(
  value: bigint,
  bits: number,
  name: string,
  error: RangeErrorClass = InvalidArgumentError,
): bigint {
  if (typeof value !== 'bigint' || value < 0n || value >> BigInt(bits) !== 0n) {
    throw new error(
      `${name} must be a bigint in [0, 2^${bits} - 1], got ${show(value)}`,
      { parameter: name, value },
    )
  }
  return value
}

/** A pair index, a `uint16`, from 0 (`InvalidArgumentError` otherwise, or `error`). */
export const pairIndex = (
  value: number,
  error: RangeErrorClass = InvalidArgumentError,
) => uintNumber(value, 16, 'pairIndex', error)
/** A shape id, a `uint8` (`InvalidArgumentError` otherwise). */
export const shapeId = (value: number) => uintNumber(value, 8, 'shapeId')
/** A sponsor id, a `uint64`; 0 is the pair's home list (`InvalidArgumentError` otherwise). */
export const sponsorId = (value: bigint) => uintBigint(value, 64, 'sponsorId')
/** A block number, a `uint64` (`InvalidArgumentError` otherwise). */
export const blockNumber = (value: bigint) =>
  uintBigint(value, 64, 'blockNumber')

/**
 * A mid: quote per 1 base scaled by 1e18, a `uint96` bigint, nonzero with `nonzero` (a post carries one). Every mid the
 * SDK takes is refused with `InvalidPriceError`, wherever it comes in.
 *
 * @param value - The mid.
 * @param name - The parameter, as the error names it.
 * @param options - `nonzero`: refuse 0.
 * @returns `value`.
 * @throws {InvalidPriceError} When it isn't a `uint96` bigint, or is 0 where `nonzero` refuses it.
 */
export function mid(
  value: bigint,
  name: string,
  options: { nonzero?: boolean | undefined } = {},
): bigint {
  const min = options.nonzero ? 1n : 0n
  if (typeof value !== 'bigint' || value < min || value > maxUint96)
    throw new InvalidPriceError(
      `${name} must be a${options.nonzero ? ' nonzero' : ''} uint96 bigint (quote per base, scaled by 1e18), got ${show(value)}`,
      { parameter: name, value },
    )
  return value
}

const SIDES: readonly HotWord.Sides[] = ['both', 'bids', 'asks', 'neither']

/**
 * Whether `value` is a `HotWord.Sides` value: `'both'`, `'bids'`, `'asks'` or `'neither'`.
 *
 * @param value - The value.
 * @returns `true` for a `Sides` value.
 */
export function isSides(value: unknown): value is HotWord.Sides {
  return SIDES.includes(value as HotWord.Sides)
}

/**
 * A `HotWord.Sides` value: the sides that take fills, or that a post refills.
 *
 * @param value - The value.
 * @param name - The parameter, as the error names it (`'sides'`, `'refill'`).
 * @returns `value`.
 * @throws {InvalidArgumentError} When it isn't one.
 */
export function sides(value: HotWord.Sides, name: string): HotWord.Sides {
  if (!isSides(value))
    throw new InvalidArgumentError(
      `${name} must be 'both', 'bids', 'asks' or 'neither', got ${show(value)}`,
      { parameter: name, value },
    )
  return value
}

/**
 * One side of a ladder or a shape: `'bids'` (where takers sell base) or `'asks'` (where they buy it).
 *
 * @param value - The value.
 * @param name - The parameter, as the error names it.
 * @returns `value`.
 * @throws {InvalidArgumentError} When it is neither.
 */
export function side(value: 'bids' | 'asks', name: string): 'bids' | 'asks' {
  if (value !== 'bids' && value !== 'asks')
    throw new InvalidArgumentError(
      `${name} must be 'bids' or 'asks', got ${show(value)}`,
      { parameter: name, value },
    )
  return value
}

/**
 * The address checksummed. Strict: an all-lowercase or all-uppercase address, which EIP-55 treats as carrying no
 * checksum, is accepted, but one in mixed case must carry its own EIP-55 checksum, since a wrong one is most likely a
 * typo, never silently re-checksummed. `nonzero` also refuses `address(0)`.
 *
 * @param value - The address.
 * @param name - The parameter, as the error names it.
 * @param options - `nonzero`: refuse the zero address.
 * @returns The address, checksummed.
 * @throws {InvalidAddressError} When it isn't an address, fails its checksum, or is zero where `nonzero` refuses it.
 */
export function address(
  value: string,
  name: string,
  options: { nonzero?: boolean | undefined } = {},
): Address {
  if (typeof value !== 'string' || !isAddress(value, { strict: false })) {
    throw new InvalidAddressError(`${name} is not an address: ${show(value)}`, {
      parameter: name,
      address: value,
    })
  }
  const digits = value.slice(2)
  const mixedCase =
    digits !== digits.toLowerCase() && digits !== digits.toUpperCase()
  if (mixedCase && !isAddress(value, { strict: true })) {
    throw new InvalidAddressError(
      `${name} ${value} is in mixed case but fails its EIP-55 checksum: check it for a typo`,
      { parameter: name, address: value },
    )
  }
  const checksummed = getAddress(value)
  if (options.nonzero && checksummed === zeroAddress) {
    throw new InvalidAddressError(`${name} must not be the zero address`, {
      parameter: name,
      address: value,
    })
  }
  return checksummed
}

/**
 * Refuses a TIP-1022 virtual address where it can only be a mistake: it forwards what it receives to its master and
 * signs nothing, so it never sends a transaction, accepts a role, or takes a fill.
 *
 * @param value - The address, already checked.
 * @param name - The parameter, as the error names it.
 * @param why - What it could never do, for the message (`'which could never accept'`).
 * @returns `value`.
 * @throws {InvalidAddressError} When it is a virtual address.
 */
export function notVirtual(value: Address, name: string, why: string): Address {
  if (VirtualAddress.isVirtual(value))
    throw new InvalidAddressError(
      `${name} ${value} is a TIP-1022 virtual address, ${why}`,
      { parameter: name, address: value },
    )
  return value
}

/**
 * A sender: a viem account as given (its address checked), or an address checked.
 *
 * @param value - The account or address.
 * @param name - The parameter, as the error names it.
 * @returns The account as given, or the address checksummed.
 * @throws {InvalidArgumentError} When it is neither an address nor an account.
 * @throws {InvalidAddressError} When its address isn't one.
 */
export function account(
  value: Account | Address,
  name: string,
): Account | Address {
  if (typeof value === 'string') return address(value, name)
  if (typeof value !== 'object' || value === null)
    throw new InvalidArgumentError(
      `${name} must be an address or an account, got ${show(value)}`,
      { parameter: name, value },
    )
  address(value.address, `${name}.address`)
  return value
}

/**
 * EIP-1559 fee fields as given, each checked as a `uint256`, and only those given.
 *
 * @param value - The fields.
 * @param prefix - The parameters' prefix, as the error names them (such as `'steps[0].'`).
 * @returns The fields given, checked.
 * @throws {InvalidArgumentError} When a field isn't a `uint256` bigint.
 */
export function fees(
  value: {
    maxFeePerGas?: bigint | undefined
    maxPriorityFeePerGas?: bigint | undefined
  },
  prefix = '',
): { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint } {
  return {
    ...(value.maxFeePerGas === undefined
      ? {}
      : {
          maxFeePerGas: uintBigint(
            value.maxFeePerGas,
            256,
            `${prefix}maxFeePerGas`,
          ),
        }),
    ...(value.maxPriorityFeePerGas === undefined
      ? {}
      : {
          maxPriorityFeePerGas: uintBigint(
            value.maxPriorityFeePerGas,
            256,
            `${prefix}maxPriorityFeePerGas`,
          ),
        }),
  }
}

/**
 * 32 bytes of hex, as a `bytes32` argument takes them. `size` rounds an odd nibble count up, so the length's parity is
 * checked too: 63 nibbles are not 32 bytes.
 *
 * @param value - The bytes.
 * @param name - The parameter, as the error names it.
 * @returns `value`.
 * @throws {InvalidArgumentError} When it isn't exactly 32 bytes of hex.
 */
export function bytes32(value: Hex, name: string): Hex {
  if (!isHex(value) || value.length % 2 !== 0 || size(value) !== 32) {
    throw new InvalidArgumentError(
      `${name} must be 32 bytes of hex, got ${show(value)}`,
      { parameter: name, value },
    )
  }
  return value
}

/**
 * A boolean, not merely a truthy value.
 *
 * @param value - The value.
 * @param name - The parameter, as the error names it.
 * @returns `value`.
 * @throws {InvalidArgumentError} When it isn't a boolean.
 */
export function bool(value: boolean, name: string): boolean {
  if (typeof value !== 'boolean') {
    throw new InvalidArgumentError(
      `${name} must be a boolean, got ${show(value)}`,
      { parameter: name, value },
    )
  }
  return value
}
