// Everything about errors, in one namespace: the classes of the errors the SDK throws (each a `BaseError`, which
// extends viem's), and the helpers that decode, name and describe the reverts the contracts throw.
import {
  type Abi,
  ContractFunctionRevertedError,
  decodeErrorResult,
  type Hex,
  size as hexSize,
  isHex,
  sliceHex,
  toFunctionSelector,
} from 'viem'
import { Abis } from 'viem/tempo'
import { settlerAbi, venueAbi, venueFactoryAbi } from './generated/abis.js'
import {
  type TakerAccess,
  type TakerAccessName,
  takerAccessNames,
} from './generated/enums.js'
import { errorContracts } from './generated/internal.js'
import { type AbiErrorItem, signature } from './internal/abi.js'
import {
  type GlobalErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  show,
} from './internal/errors.js'
import type { ContractName } from './internal/types.js'
import { lowerHex } from './internal/validate.js'

export {
  AmountOutOfRangeError,
  type AmountOutOfRangeErrorType,
  BaseError,
  type BaseErrorParameters,
  type BaseErrorType,
  BatchTooLargeError,
  type BatchTooLargeErrorType,
  DuplicatePairError,
  type DuplicatePairErrorType,
  EmptyBatchError,
  type EmptyBatchErrorType,
  type GlobalErrorType,
  InvalidAddressError,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  InvalidHotWordError,
  type InvalidHotWordErrorType,
  InvalidOrderError,
  type InvalidOrderErrorType,
  InvalidPriceError,
  type InvalidPriceErrorType,
  InvalidShapeError,
  type InvalidShapeErrorType,
  MissingAccountError,
  type MissingAccountErrorType,
  SequenceExhaustedError,
  type SequenceExhaustedErrorType,
  SnapshotIncompleteError,
  type SnapshotIncompleteErrorType,
  SnapshotReorgedError,
  type SnapshotReorgedErrorType,
  UnexpectedResponseError,
  type UnexpectedResponseErrorType,
  UnknownPairError,
  type UnknownPairErrorType,
  UnknownVenueError,
  type UnknownVenueErrorType,
  UnseededPairError,
  type UnseededPairErrorType,
} from './internal/errors.js'

const errorsOf = (abi: Abi) =>
  abi.filter((item): item is AbiErrorItem => item.type === 'error')

/**
 * Every error the venue, Settler, factory and the TIP-20 precompile can revert with, each signature once.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 * import { decodeErrorResult } from 'viem'
 *
 * const { errorName } = decodeErrorResult({ abi: Errors.allErrorsAbi, data: '0x69495f5e' })
 * ```
 */
export const allErrorsAbi: readonly AbiErrorItem[] = (() => {
  const seen = new Set<string>()
  return [
    ...errorsOf(venueAbi),
    ...errorsOf(settlerAbi),
    ...errorsOf(venueFactoryAbi),
    ...errorsOf(Abis.tip20),
  ].filter((item) => {
    const sig = signature(item)
    if (seen.has(sig)) return false
    seen.add(sig)
    return true
  })
})()

/** Each declared error by its lowercase selector, with every contract that declares it: built once, here. */
const bySelector: ReadonlyMap<
  Hex,
  { item: AbiErrorItem; contracts: readonly ContractName[] }
> = (() => {
  const tip20 = new Set(errorsOf(Abis.tip20).map(signature))
  const declared: Readonly<Record<string, readonly ContractName[]>> =
    errorContracts
  return new Map(
    allErrorsAbi.map((item) => {
      const sig = signature(item)
      const contracts = [...(declared[sig] ?? [])]
      if (tip20.has(sig)) contracts.push('TIP20')
      return [toFunctionSelector(sig), { item, contracts }] as const
    }),
  )
})()

const ACCESS_TEXT: Record<TakerAccessName, string> = {
  none: 'the access check returned nothing (a zero read): treat it as a refusal',
  allowed: 'allowed',
  unknownPair: 'the pair is unknown or removed',
  priorityFeeTooHigh:
    "the transaction's priority fee is above the venue's taker cap",
  closed: 'the pair is closed',
  denied: 'the taker is on the venue deny list',
  unknownSponsor: 'the sponsor id is not registered on the venue',
  sponsorDisabled: 'the sponsor is switched off on the venue',
  sponsorNotAdmitted: 'the sponsor is not admitted on the pair',
  notListed: "the taker is not on the named sponsor's list for the pair",
}

const TEXT: Record<string, (args: readonly unknown[]) => string> = {
  InsufficientDepth: () =>
    "the ladder left after the side's consumed depth can't cover the fill",
  ZeroFill: () => 'the fill rounds to zero on one side',
  SideDisabled: ([baseIn]) =>
    `the ${baseIn ? 'bid' : 'ask'} side is switched off or has no depth`,
  QuoteExpired: ([validUntil]) =>
    `the maker's quote expired at ${String(validUntil)}`,
  VenueHalted: () => 'the venue is halted',
  UnknownPair: (args) => `pair ${String(args.at(-1))} is unknown or removed`,
  TokenMismatch: () => "the tokens are not the pair's base and quote",
  InsufficientInventory: ([token, available, required]) =>
    `the venue holds ${String(available)} of ${String(token)} but the fill needs ${String(required)}`,
  TakerPriorityFeeTooHigh: ([fee, cap]) =>
    `priority fee ${String(fee)} per gas is above the venue's taker cap of ${String(cap)}`,
  TakerNotAllowed: ([taker]) =>
    `${String(taker)} is not allowed on the pair (closed, or not on the named list)`,
  TakerDenied: ([taker]) => `${String(taker)} is denied on the venue`,
  UnknownSponsor: ([id]) => `sponsor ${String(id)} is not registered`,
  SponsorDisabled: ([id]) => `sponsor ${String(id)} is switched off`,
  SponsorNotAdmitted: ([pair, id]) =>
    `sponsor ${String(id)} is not admitted on pair ${String(pair)}`,
  InsufficientOutput: ([out, min]) =>
    `the swap pays ${String(out)}, below the minimum ${String(min)}`,
  ExcessiveInput: ([amountIn, max]) =>
    `the swap costs ${String(amountIn)}, above the maximum ${String(max)}`,
  DeadlineExpired: ([deadline]) =>
    `the swap's deadline ${String(deadline)} has passed`,
  UnknownVenue: ([venue]) =>
    `${String(venue)} is not a venue the factory created`,
  NotOwner: () => "the sender is not the venue's owner",
  NotOwnerOrUpdater: () =>
    "the sender is neither the venue's owner nor an agent (updater)",
  NotSponsorAdmin: ([id]) => `the sender is not sponsor ${String(id)}'s admin`,
}

/**
 * The revert data one error carries: viem's `ContractFunctionRevertedError.raw`, a `RawContractError`'s `data` (hex, or
 * `{ data }`), or the same shapes on any other error, such as an RPC error's `data`.
 */
function dataOf(error: unknown): Hex | undefined {
  if (error instanceof ContractFunctionRevertedError) return error.raw
  if (typeof error !== 'object' || error === null || !('data' in error))
    return undefined
  const { data } = error
  if (typeof data === 'string') return isHex(data) ? data : undefined
  if (
    typeof data === 'object' &&
    data !== null &&
    'data' in data &&
    typeof data.data === 'string' &&
    isHex(data.data)
  )
    return data.data
  return undefined
}

/** The first revert data in `error` or up to 15 causes, or undefined when it has none. */
function revertData(error: unknown): Hex | undefined {
  if (typeof error === 'string') return isHex(error) ? error : undefined
  // Never delegate to a recursive walk: RPC errors can carry arbitrarily deep or cyclic causes.
  const seen = new Set<object>()
  let e: unknown = error
  for (
    let depth = 0;
    depth < 16 && typeof e === 'object' && e !== null;
    depth++
  ) {
    if (seen.has(e)) return undefined
    seen.add(e)
    const data = dataOf(e)
    if (data !== undefined) return data
    e = 'cause' in e ? e.cause : undefined
  }
  return undefined
}

/**
 * Asserts that a raw read is a `TakerAccess` value (`IVenue.TakerAccess`, 0 to 9), such as the result of
 * `takerAccess` decoded by hand.
 *
 * @example
 * ```ts
 * import { Errors, TakerAccess } from '@tempoxyz/propamm-sdk'
 *
 * const raw: unknown = 1
 * Errors.assertAccess(raw)
 * if (raw === TakerAccess.Allowed) console.log('allowed')
 * ```
 *
 * @param access - The value read.
 * @throws {InvalidArgumentError} When `access` isn't a `TakerAccess` value.
 */
export function assertAccess(access: unknown): asserts access is TakerAccess {
  if (!validateAccess(access)) {
    throw new InvalidArgumentError(`not a TakerAccess value: ${show(access)}`, {
      parameter: 'access',
      value: access,
    })
  }
}

export declare namespace assertAccess {
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * Whether a raw read is a `TakerAccess` value (`IVenue.TakerAccess`, 0 to 9).
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * Errors.validateAccess(1) // true: Allowed
 * Errors.validateAccess(10) // false
 * ```
 *
 * @param access - The value read.
 * @returns `true` when `access` is an integer from 0 to 9.
 */
export function validateAccess(access: unknown): access is TakerAccess {
  return (
    typeof access === 'number' &&
    Number.isInteger(access) &&
    access >= 0 &&
    access < takerAccessNames.length
  )
}

export declare namespace validateAccess {
  type ErrorType = GlobalErrorType
}

/**
 * A decoded revert.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * const decoded: Errors.Decoded | null = Errors.decode('0x69495f5e')
 * if (decoded) console.log(decoded.errorName, decoded.contracts)
 * ```
 */
export type Decoded = {
  /** The error's name, or null for a selector none of the SDK's contracts declares (and for no data). */
  errorName: string | null
  /** Its decoded arguments, in declaration order. */
  args: readonly unknown[]
  /** The 4-byte selector, in lowercase, or null when the revert carried fewer than 4 bytes. */
  selector: Hex | null
  /** Every contract that declares this error (a `ZeroAddress()` revert could come from any of four). Empty for
   * `Error(string)`, `Panic(uint256)` and unknown selectors. */
  contracts: readonly ContractName[]
  /** The raw revert data, as found. */
  data: Hex | null
}

/**
 * Decodes a revert from viem's error chain (a `ContractFunctionRevertedError`, a `RawContractError`, or any error
 * whose cause carries revert data) or from raw revert data, over every error in {@link allErrorsAbi}, with viem's
 * `decodeErrorResult` (which also knows `Error(string)` and `Panic(uint256)`). Error-chain searches inspect the
 * outer error and at most 15 causes, stopping at cycles, to bound work on untrusted RPC errors.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * const decoded = Errors.decode('0x69495f5e')
 * decoded?.errorName // 'ZeroFill'
 * decoded?.contracts // ['Venue']
 * ```
 *
 * @param error - What a call threw (any value), or raw revert data.
 * @returns The decoded revert, or null when no revert data is found within that search limit.
 */
export function decode(error: unknown): Decoded | null {
  const data = revertData(error)
  if (data === undefined) return null
  if (hexSize(data) < 4)
    return { errorName: null, args: [], selector: null, contracts: [], data }
  // viem matches selectors in lowercase, as it writes them.
  const selector = lowerHex(sliceHex(data, 0, 4))
  const contracts = bySelector.get(selector)?.contracts
  try {
    const { errorName, args } = decodeErrorResult({
      abi: allErrorsAbi,
      data: lowerHex(data),
    })
    return {
      errorName,
      args: args ?? [],
      selector,
      contracts: contracts ?? [],
      data,
    }
  } catch {
    return { errorName: null, args: [], selector, contracts: [], data }
  }
}

export declare namespace decode {
  type ErrorType = GlobalErrorType
}

/**
 * One line of English for a decoded revert: the ladder, access, fee-cap and role errors in words, else `Name(args)`.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * Errors.describe({ errorName: 'ZeroFill', args: [], selector: '0x69495f5e' })
 * // 'the fill rounds to zero on one side'
 * ```
 *
 * @param decoded - A revert from {@link decode}, or its name, arguments and selector.
 * @returns The description.
 */
export function describe(
  decoded: Pick<Decoded, 'errorName' | 'args' | 'selector'>,
): string {
  if (decoded.errorName === null)
    return decoded.selector
      ? `unknown revert ${decoded.selector}`
      : 'reverted without data'
  const text = TEXT[decoded.errorName]
  if (text) return text(decoded.args)
  return `${decoded.errorName}(${decoded.args.map(String).join(', ')})`
}

export declare namespace describe {
  type ErrorType = GlobalErrorType
}

/**
 * One line of English for a `TakerAccess` value or name.
 *
 * @example
 * ```ts
 * import { Errors, TakerAccess } from '@tempoxyz/propamm-sdk'
 *
 * Errors.describeAccess(TakerAccess.Closed) // 'the pair is closed'
 * Errors.describeAccess('denied') // 'the taker is on the venue deny list'
 * ```
 *
 * @param access - The value, or its name.
 * @returns The description; for a number that isn't a `TakerAccess`, says so.
 */
export function describeAccess(access: TakerAccess | TakerAccessName): string {
  const name = typeof access === 'number' ? takerAccessNames[access] : access
  return name ? ACCESS_TEXT[name] : `unknown access result ${show(access)}`
}

export declare namespace describeAccess {
  type ErrorType = GlobalErrorType
}

/**
 * The error a selector names, if any of the SDK's contracts or the TIP-20 precompile declares it. Looks it up in a
 * table built once, when the module loads.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * Errors.errorOf('0x69495f5e')?.name // 'ZeroFill'
 * ```
 *
 * @param selector - A 4-byte error selector, in either case.
 * @returns The error's ABI item, or undefined when nothing declares it.
 */
export function errorOf(selector: Hex): AbiErrorItem | undefined {
  return typeof selector === 'string'
    ? bySelector.get(lowerHex(selector))?.item
    : undefined
}

export declare namespace errorOf {
  type ErrorType = GlobalErrorType
}
