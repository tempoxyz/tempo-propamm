import { maxUint96 } from 'viem'
import {
  type GlobalErrorType,
  InvalidPriceError,
  type InvalidPriceErrorType,
  show,
} from './internal/errors.js'

/**
 * 1.0 as a mid: quote per 1 base, scaled by 1e18 (18 decimals).
 *
 * @example
 * ```ts
 * import { Price } from '@tempoxyz/propamm-sdk'
 *
 * Price.from(2n * Price.one) // 2000000000000000000n: the mid 2.0
 * ```
 */
export const one = 10n ** 18n

/**
 * Parses an exact unsigned decimal of at most 18 places into a mid: quote per 1 base, scaled by 1e18. No floats:
 * `'1.085'` is exactly `1_085_000_000_000_000_000n`. Refuses signs, whitespace, exponents, a bare `.` on either side,
 * excess precision, 0 and anything above `uint96`, the hot word's mid field.
 *
 * @example
 * ```ts
 * import { Price } from '@tempoxyz/propamm-sdk'
 *
 * Price.parse('1.085') // 1085000000000000000n
 * ```
 *
 * @param value - The decimal, such as `'1.085'`.
 * @returns The mid, a nonzero `uint96`.
 * @throws {InvalidPriceError} When `value` isn't such a decimal, or is 0 or above `uint96` once scaled.
 */
export function parse(value: string): bigint {
  const match =
    typeof value === 'string' ? /^(\d+)(?:\.(\d{1,18}))?$/.exec(value) : null
  if (!match) {
    throw new InvalidPriceError(
      `price must be an unsigned decimal with at most 18 places, got ${show(value)}`,
      { value },
    )
  }
  const whole = BigInt(match[1] as string)
  const fraction = match[2] ?? ''
  const scaled =
    whole * one +
    (fraction ? BigInt(fraction) * 10n ** BigInt(18 - fraction.length) : 0n)
  assert(scaled)
  return scaled
}

export declare namespace parse {
  type ErrorType = InvalidPriceErrorType | GlobalErrorType
}

/**
 * A mid from a decimal (`Price.parse`) or a scaled `bigint` (checked as `Price.assert` checks it): the Rust SDK's
 * `Price` from a string and `Price::from_scaled`.
 *
 * @example
 * ```ts
 * import { Price } from '@tempoxyz/propamm-sdk'
 *
 * Price.from('1.085') // 1085000000000000000n
 * Price.from(1_085_000_000_000_000_000n) // the same mid
 * ```
 *
 * @param value - A decimal of at most 18 places, or a mid already scaled by 1e18.
 * @returns The mid, a nonzero `uint96`.
 * @throws {InvalidPriceError} When `value` is neither a valid decimal nor a valid mid.
 */
export function from(value: string | bigint): bigint {
  if (typeof value === 'string') return parse(value)
  assert(value)
  return value
}

export declare namespace from {
  type ErrorType = parse.ErrorType | assert.ErrorType
}

/**
 * The shortest exact decimal for a mid: `Price.format(Price.parse(s)) === s` for every canonical `s`. Formats the
 * whole `uint96` field, so 0, the mid of a pair never posted, is `'0'`, though `Price.parse` refuses `'0'`: no post
 * can carry it.
 *
 * @example
 * ```ts
 * import { Price } from '@tempoxyz/propamm-sdk'
 *
 * Price.format(1_085_000_000_000_000_000n) // '1.085'
 * Price.format(0n) // '0': a pair never posted
 * ```
 *
 * @param mid - Quote per 1 base, scaled by 1e18: a `uint96`, 0 included.
 * @returns The decimal, with no trailing zeros and no `.` for a whole number.
 * @throws {InvalidPriceError} When `mid` isn't a `uint96` bigint.
 */
export function format(mid: bigint): string {
  if (typeof mid !== 'bigint' || mid < 0n || mid > maxUint96) {
    throw new InvalidPriceError(
      `a mid to format must be a uint96 bigint, got ${show(mid)}`,
      { value: mid },
    )
  }
  const whole = mid / one
  const fraction = (mid % one).toString().padStart(18, '0').replace(/0+$/, '')
  return fraction ? `${whole}.${fraction}` : whole.toString()
}

export declare namespace format {
  type ErrorType = InvalidPriceErrorType | GlobalErrorType
}

/**
 * Asserts that `mid` is a mid a post can carry: a nonzero `uint96`, quote per 1 base scaled by 1e18.
 *
 * @example
 * ```ts
 * import { Price } from '@tempoxyz/propamm-sdk'
 *
 * Price.assert(Price.one) // passes
 * Price.assert(0n) // throws InvalidPriceError
 * ```
 *
 * @param mid - The mid.
 * @throws {InvalidPriceError} When `mid` is 0, negative, above `uint96` or not a bigint.
 */
export function assert(mid: bigint): void {
  if (!validate(mid)) {
    throw new InvalidPriceError(
      `a mid must be a nonzero uint96 bigint (quote per base, scaled by 1e18), got ${show(mid)}`,
      { value: mid },
    )
  }
}

export declare namespace assert {
  type ErrorType = InvalidPriceErrorType | GlobalErrorType
}

/**
 * Whether `mid` is a mid a post can carry: a nonzero `uint96`, quote per 1 base scaled by 1e18.
 *
 * @example
 * ```ts
 * import { Price } from '@tempoxyz/propamm-sdk'
 *
 * Price.validate(Price.one) // true
 * Price.validate(0n) // false
 * ```
 *
 * @param mid - The mid.
 * @returns `true` for a nonzero `uint96` bigint, else `false`.
 */
export function validate(mid: bigint): boolean {
  return typeof mid === 'bigint' && mid > 0n && mid <= maxUint96
}

export declare namespace validate {
  type ErrorType = GlobalErrorType
}
