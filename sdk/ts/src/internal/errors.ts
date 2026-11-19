// Every error the SDK throws. The SDK validates every input before it encodes or sends anything and fails closed: a
// value it can't represent exactly is an error, never a rounding or a clamp. Each class carries the values it refused
// as fields; `Errors` re-exports them all.
import type { Address, Hex } from 'viem'
import { BaseError as ViemBaseError } from 'viem'
import { version } from '../version.js'

/** Where `docsPath` points: this package's README, so a path is an anchor such as `#errors`. */
const docsBaseUrl = 'https://github.com/tempoxyz/tempo-propamm/tree/main/sdk/ts'

/**
 * Any error a function can throw beyond the ones it names: ox's `GlobalErrorType`. Each function's `ErrorType` (such
 * as `Price.parse.ErrorType`) is the union of the SDK's error types it throws and this.
 *
 * @example
 * ```ts
 * import type { Price } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: Price.parse.ErrorType) {
 *   if (error.name === 'InvalidPriceError') console.log('not a price:', error.value)
 *   else console.log(error.message)
 * }
 * ```
 */
export type GlobalErrorType<name extends string = 'Error'> = Error & {
  name: name
}

/** What every error class takes after its message: a cause, details, a docs path and extra lines. */
export type BaseErrorParameters = {
  /** The error behind this one: its details become this error's, and `walk()` reaches it. */
  cause?: Error | undefined
  /** A longer explanation, used when there is no `cause`. */
  details?: string | undefined
  /** A path under the SDK's README, such as `#errors`. */
  docsPath?: string | undefined
  /** Extra lines for the message, after the short one. */
  metaMessages?: string[] | undefined
}

/** The input a refusal names: the parameter, and the value given for it. */
type Input = { parameter: string; value: unknown }

/** {@link BaseError}, narrowed by its `name`. */
export type BaseErrorType = BaseError & { name: 'BaseError' }

/**
 * The base of every error the SDK throws. It extends viem's `BaseError`, so `shortMessage`, `details`, `metaMessages`,
 * `walk()` and `instanceof` viem's `BaseError` work as they do for viem's own errors, but its `version` and its message
 * name this package (`@tempoxyz/propamm-sdk@<version>`), not viem.
 *
 * @example
 * ```ts
 * import { Errors, Price } from '@tempoxyz/propamm-sdk'
 *
 * try {
 *   Price.parse('1.5e3')
 * } catch (error) {
 *   if (error instanceof Errors.BaseError) console.log(error.shortMessage, error.version)
 * }
 * ```
 */
export class BaseError extends ViemBaseError {
  override name = 'BaseError'
  override version = `@tempoxyz/propamm-sdk@${version}`

  constructor(shortMessage: string, parameters: BaseErrorParameters = {}) {
    const { cause, details, docsPath, metaMessages } = parameters
    super(shortMessage, { cause, details, metaMessages })
    // viem's constructor wrote a message naming viem's version (and would link viem's docs): rebuild it.
    this.docsPath =
      cause instanceof BaseError ? cause.docsPath || docsPath : docsPath
    this.message = [
      shortMessage,
      '',
      ...(metaMessages ? [...metaMessages, ''] : []),
      ...(this.docsPath ? [`Docs: ${docsBaseUrl}${this.docsPath}`] : []),
      ...(this.details ? [`Details: ${this.details}`] : []),
      `Version: ${this.version}`,
    ].join('\n')
  }
}

/** {@link AmountOutOfRangeError}, narrowed by its `name`. */
export type AmountOutOfRangeErrorType = AmountOutOfRangeError & {
  name: 'AmountOutOfRangeError'
}

/**
 * An amount the call can't carry (above its ABI width, or negative), or zero where the call must move something.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.AmountOutOfRangeError) console.log(error.parameter, error.value)
 * }
 * ```
 */
export class AmountOutOfRangeError extends BaseError {
  override name = 'AmountOutOfRangeError'
  /** The amount's parameter. */
  readonly parameter: string
  /** The amount refused. */
  readonly value: unknown

  constructor(
    shortMessage: string,
    { parameter, value, ...rest }: Input & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.parameter = parameter
    this.value = value
  }
}

/** {@link BatchTooLargeError}, narrowed by its `name`. */
export type BatchTooLargeErrorType = BatchTooLargeError & {
  name: 'BatchTooLargeError'
}

/**
 * More accounts than one `setMembers` or `setDenied` takes (`Venue.maxBatch`, 100). The SDK never splits a batch: split
 * the list yourself. Each new account is about 255k gas, so at `Plan.gasLimit`'s 130% a batch of about 90 new accounts
 * still fits Tempo's 30M transaction cap and a full one of 100 doesn't (33.2M); 50 leaves room.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.BatchTooLargeError) console.log(`${error.size} accounts, at most ${error.maxSize}`)
 * }
 * ```
 */
export class BatchTooLargeError extends BaseError {
  override name = 'BatchTooLargeError'
  /** The accounts supplied. */
  readonly size: number
  /** The most one call takes. */
  readonly maxSize: number

  constructor(
    shortMessage: string,
    {
      size,
      maxSize,
      ...rest
    }: { size: number; maxSize: number } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.size = size
    this.maxSize = maxSize
  }
}

/** {@link DuplicatePairError}, narrowed by its `name`. */
export type DuplicatePairErrorType = DuplicatePairError & {
  name: 'DuplicatePairError'
}

/**
 * A `post` batch names one pair twice.
 *
 * @example
 * ```ts
 * import { Errors, Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * const order = { pairIndex: 0, mid: Price.one, shapeId: 0, sequence: 2, validUntil: 1_800_000_000 }
 * try {
 *   Post.bulkOrders([order, order])
 * } catch (error) {
 *   if (error instanceof Errors.DuplicatePairError) console.log(error.pairIndex) // 0
 * }
 * ```
 */
export class DuplicatePairError extends BaseError {
  override name = 'DuplicatePairError'
  /** The pair named twice. */
  readonly pairIndex: number

  constructor(
    shortMessage: string,
    { pairIndex, ...rest }: { pairIndex: number } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.pairIndex = pairIndex
  }
}

/** {@link EmptyBatchError}, narrowed by its `name`. */
export type EmptyBatchErrorType = EmptyBatchError & {
  name: 'EmptyBatchError'
}

/**
 * A batch (orders, cancels, `post` entries, a step's calls) with nothing in it.
 *
 * @example
 * ```ts
 * import { Errors, Post } from '@tempoxyz/propamm-sdk'
 *
 * try {
 *   Post.bulkOrders([])
 * } catch (error) {
 *   if (error instanceof Errors.EmptyBatchError) console.log(error.shortMessage)
 * }
 * ```
 */
export class EmptyBatchError extends BaseError {
  override name = 'EmptyBatchError'
}

/** {@link InvalidAddressError}, narrowed by its `name`. */
export type InvalidAddressErrorType = InvalidAddressError & {
  name: 'InvalidAddressError'
}

/**
 * An address the SDK refuses: not 20 bytes of hex, a mixed-case address whose EIP-55 checksum is wrong, or the zero
 * address, the venue itself or a TIP-1022 virtual address where the contract refuses one or it could never send.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.InvalidAddressError) console.log(error.parameter, error.address)
 * }
 * ```
 */
export class InvalidAddressError extends BaseError {
  override name = 'InvalidAddressError'
  /** The address's parameter. */
  readonly parameter: string
  /** The value refused. */
  readonly address: unknown

  constructor(
    shortMessage: string,
    {
      parameter,
      address,
      ...rest
    }: { parameter: string; address: unknown } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.parameter = parameter
    this.address = address
  }
}

/** {@link InvalidArgumentError}, narrowed by its `name`. */
export type InvalidArgumentErrorType = InvalidArgumentError & {
  name: 'InvalidArgumentError'
}

/**
 * Any other input the SDK refuses: an integer out of its ABI range, a malformed byte string, an incoherent option.
 *
 * @example
 * ```ts
 * import { Errors, Post } from '@tempoxyz/propamm-sdk'
 *
 * try {
 *   Post.unpack('0x1234')
 * } catch (error) {
 *   if (error instanceof Errors.InvalidArgumentError) console.log(error.parameter) // 'packed'
 * }
 * ```
 */
export class InvalidArgumentError extends BaseError {
  override name = 'InvalidArgumentError'
  /** The parameter refused, when one is. */
  readonly parameter: string | undefined
  /** The value refused, when there is one. */
  readonly value: unknown

  constructor(
    shortMessage: string,
    {
      parameter,
      value,
      ...rest
    }: {
      parameter?: string | undefined
      value?: unknown
    } & BaseErrorParameters = {},
  ) {
    super(shortMessage, rest)
    this.parameter = parameter
    this.value = value
  }
}

/** {@link InvalidHotWordError}, narrowed by its `name`. */
export type InvalidHotWordErrorType = InvalidHotWordError & {
  name: 'InvalidHotWordError'
}

/**
 * A hot word the SDK refuses: not exactly 32 bytes, a field out of its bit width, flag bits a stored word never
 * carries, reserved flag bits, or a word `post` would revert on.
 *
 * @example
 * ```ts
 * import { Errors, HotWord } from '@tempoxyz/propamm-sdk'
 *
 * try {
 *   HotWord.decode('0x1234')
 * } catch (error) {
 *   if (error instanceof Errors.InvalidHotWordError) console.log(error.word) // '0x1234'
 * }
 * ```
 */
export class InvalidHotWordError extends BaseError {
  override name = 'InvalidHotWordError'
  /** The word, when the word itself is at fault. */
  readonly word: unknown
  /** Its flags (bits 240-255), when they are at fault. */
  readonly flags: number | undefined
  /** The pair of the `post` entry it came in. */
  readonly pairIndex: number | undefined
  /** The field or option refused, when one is. */
  readonly parameter: string | undefined
  /** The value refused for it. */
  readonly value: unknown

  constructor(
    shortMessage: string,
    {
      word,
      flags,
      pairIndex,
      parameter,
      value,
      ...rest
    }: {
      word?: unknown
      flags?: number | undefined
      pairIndex?: number | undefined
      parameter?: string | undefined
      value?: unknown
    } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.word = word
    this.flags = flags
    this.pairIndex = pairIndex
    this.parameter = parameter
    this.value = value
  }
}

/** {@link InvalidOrderError}, narrowed by its `name`. */
export type InvalidOrderErrorType = InvalidOrderError & {
  name: 'InvalidOrderError'
}

/**
 * An order or a cancel the venue could never accept, one field at a time: `parameter` names the field
 * (`'pairIndex'`, `'mid'`, `'shapeId'`, `'validUntil'`, `'sequence'`, `'bidWiden'`, `'askWiden'`, `'widthScale'`,
 * `'depthScale'`, `'sides'` or `'refill'`), `value` holds what was given, and `pairIndex` the order's pair once it is
 * known to be one. It is the `InvalidArgumentError` of an order's or a cancel's field (`instanceof` holds for both), so
 * one value refused anywhere in the SDK is an `InvalidArgumentError` with the same `parameter`, here narrowed to the
 * order it came in.
 *
 * @example
 * ```ts
 * import { Errors, Post, Price } from '@tempoxyz/propamm-sdk'
 *
 * try {
 *   Post.order({ pairIndex: 0, mid: Price.one, shapeId: 0, sequence: 1, validUntil: 1_800_000_000 })
 * } catch (error) {
 *   if (error instanceof Errors.InvalidOrderError) console.log(error.parameter, error.value) // 'sequence' 1
 * }
 * ```
 */
export class InvalidOrderError extends InvalidArgumentError {
  override name = 'InvalidOrderError'
  /** The field refused, such as `'validUntil'`. */
  declare readonly parameter: string
  /** The order's pair, when its `pairIndex` is valid. */
  readonly pairIndex: number | undefined

  constructor(
    shortMessage: string,
    {
      parameter,
      value,
      pairIndex,
      ...rest
    }: Input & { pairIndex?: number | undefined } & BaseErrorParameters,
  ) {
    super(shortMessage, { parameter, value, ...rest })
    this.pairIndex = pairIndex
  }
}

/** {@link InvalidPriceError}, narrowed by its `name`. */
export type InvalidPriceErrorType = InvalidPriceError & {
  name: 'InvalidPriceError'
}

/**
 * A price that is not an exact decimal of at most 18 places, or a mid out of range: 0 or above `uint96` where a post
 * must carry it, above `uint96` anywhere (a mid band's bounds, a ladder's curve). Every mid outside an order or cancel
 * request is refused with it; a request's is its `InvalidOrderError`.
 *
 * @example
 * ```ts
 * import { Errors, Price } from '@tempoxyz/propamm-sdk'
 *
 * try {
 *   Price.parse('1.5e3')
 * } catch (error) {
 *   if (error instanceof Errors.InvalidPriceError) console.log(error.value) // '1.5e3'
 * }
 * ```
 */
export class InvalidPriceError extends BaseError {
  override name = 'InvalidPriceError'
  /** The text or mid refused. */
  readonly value: unknown
  /** The mid's parameter, such as `'minMid'`, when the call takes more than a price. */
  readonly parameter: string | undefined

  constructor(
    shortMessage: string,
    {
      value,
      parameter,
      ...rest
    }: {
      value: unknown
      parameter?: string | undefined
    } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.value = value
    this.parameter = parameter
  }
}

/** {@link InvalidShapeError}, narrowed by its `name`. */
export type InvalidShapeErrorType = InvalidShapeError & {
  name: 'InvalidShapeError'
}

/**
 * A shape `setShape` would refuse: a level out of range, too many levels, decreasing spreads, or words that aren't
 * the one canonical encoding (`reason`, as `ShapeWord.check` returns it).
 *
 * @example
 * ```ts
 * import { Errors, Shape } from '@tempoxyz/propamm-sdk'
 *
 * try {
 *   Shape.from({ bids: [{ size: 0, spread: 0 }], asks: [] })
 * } catch (error) {
 *   if (error instanceof Errors.InvalidShapeError) console.log(error.parameter) // 'bids[0].size'
 * }
 * ```
 */
export class InvalidShapeError extends BaseError {
  override name = 'InvalidShapeError'
  /** `ShapeWord.check`'s reason (1 reserved bits, 2 non-canonical, 3 spread decreases), when the words were checked. */
  readonly reason: number | undefined
  /** The ladder, level or field refused, such as `bids[2].spread`, when one is. */
  readonly parameter: string | undefined
  /** The value refused. */
  readonly value: unknown

  constructor(
    shortMessage: string,
    {
      reason,
      parameter,
      value,
      ...rest
    }: {
      reason?: number | undefined
      parameter?: string | undefined
      value?: unknown
    } & BaseErrorParameters = {},
  ) {
    super(shortMessage, rest)
    this.reason = reason
    this.parameter = parameter
    this.value = value
  }
}

/** {@link MissingAccountError}, narrowed by its `name`. */
export type MissingAccountErrorType = MissingAccountError & {
  name: 'MissingAccountError'
}

/**
 * A role check (`Roles.check`) with no account, in the parameters or on the client. A send without one is viem's own
 * `AccountNotFoundError`.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.MissingAccountError) console.log('pass an account, or give the client one')
 * }
 * ```
 */
export class MissingAccountError extends BaseError {
  override name = 'MissingAccountError'
}

/** {@link SequenceExhaustedError}, narrowed by its `name`. */
export type SequenceExhaustedErrorType = SequenceExhaustedError & {
  name: 'SequenceExhaustedError'
}

/**
 * A pair whose sequence would pass `uint32`.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.SequenceExhaustedError) console.log(`pair ${error.pairIndex} has no sequence left`)
 * }
 * ```
 */
export class SequenceExhaustedError extends BaseError {
  override name = 'SequenceExhaustedError'
  /** The pair. */
  readonly pairIndex: number

  constructor(
    shortMessage: string,
    { pairIndex, ...rest }: { pairIndex: number } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.pairIndex = pairIndex
  }
}

/** {@link SnapshotIncompleteError}, narrowed by its `name`. */
export type SnapshotIncompleteErrorType = SnapshotIncompleteError & {
  name: 'SnapshotIncompleteError'
}

/**
 * A read at one block came back without something the caller needs: a pair the snapshot didn't read or couldn't, a
 * failed read, or a result missing from a multicall.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.SnapshotIncompleteError) console.log(error.pairIndex, error.shortMessage)
 * }
 * ```
 */
export class SnapshotIncompleteError extends BaseError {
  override name = 'SnapshotIncompleteError'
  /** The pair, when one is missing. */
  readonly pairIndex: number | undefined

  constructor(
    shortMessage: string,
    {
      pairIndex,
      ...rest
    }: { pairIndex?: number | undefined } & BaseErrorParameters = {},
  ) {
    super(shortMessage, rest)
    this.pairIndex = pairIndex
  }
}

/** {@link SnapshotReorgedError}, narrowed by its `name`. */
export type SnapshotReorgedErrorType = SnapshotReorgedError & {
  name: 'SnapshotReorgedError'
}

/**
 * The block a snapshot pinned changed while it read (`verifyHash`).
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.SnapshotReorgedError) console.log(error.blockNumber, error.hash, error.newHash)
 * }
 * ```
 */
export class SnapshotReorgedError extends BaseError {
  override name = 'SnapshotReorgedError'
  /** The block pinned. */
  readonly blockNumber: bigint
  /** Its hash when the snapshot started. */
  readonly hash: Hex
  /** Its hash after the reads. */
  readonly newHash: Hex | null

  constructor(
    shortMessage: string,
    {
      blockNumber,
      hash,
      newHash,
      ...rest
    }: {
      blockNumber: bigint
      hash: Hex
      newHash: Hex | null
    } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.blockNumber = blockNumber
    this.hash = hash
    this.newHash = newHash
  }
}

/** {@link UnexpectedResponseError}, narrowed by its `name`. */
export type UnexpectedResponseErrorType = UnexpectedResponseError & {
  name: 'UnexpectedResponseError'
}

/**
 * A node's answer the SDK can't use, though the input was fine: a block without a number, a simulation with another
 * number of results than calls, or a view that answers a value outside its ABI enum. Retry, or try another node.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.UnexpectedResponseError) console.log('the node answered', error.value)
 * }
 * ```
 */
export class UnexpectedResponseError extends BaseError {
  override name = 'UnexpectedResponseError'
  /** What the node answered. */
  readonly value: unknown

  constructor(
    shortMessage: string,
    { value, ...rest }: { value: unknown } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.value = value
  }
}

/** {@link UnknownPairError}, narrowed by its `name`. */
export type UnknownPairErrorType = UnknownPairError & {
  name: 'UnknownPairError'
}

/**
 * A pair index the venue doesn't have, or has removed.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.UnknownPairError) console.log(`no pair ${error.pairIndex}`)
 * }
 * ```
 */
export class UnknownPairError extends BaseError {
  override name = 'UnknownPairError'
  /** The pair. */
  readonly pairIndex: number

  constructor(
    shortMessage: string,
    { pairIndex, ...rest }: { pairIndex: number } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.pairIndex = pairIndex
  }
}

/** {@link UnknownVenueError}, narrowed by its `name`. */
export type UnknownVenueErrorType = UnknownVenueError & {
  name: 'UnknownVenueError'
}

/**
 * An address that doesn't answer the venue's views (`Snapshot.get`): it reverts them, has no code, or answers data that
 * doesn't decode. Whether a factory created a venue is `Info.isVenue`'s answer, not an error.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.UnknownVenueError) console.log(error.venue, error.cause)
 * }
 * ```
 */
export class UnknownVenueError extends BaseError {
  override name = 'UnknownVenueError'
  /** The address. */
  readonly venue: Address

  constructor(
    shortMessage: string,
    { venue, ...rest }: { venue: Address } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.venue = venue
  }
}

/** {@link UnseededPairError}, narrowed by its `name`. */
export type UnseededPairErrorType = UnseededPairError & {
  name: 'UnseededPairError'
}

/**
 * A `Sequencer` asked for a pair it was never seeded with.
 *
 * @example
 * ```ts
 * import { Errors } from '@tempoxyz/propamm-sdk'
 *
 * function explain(error: unknown) {
 *   if (error instanceof Errors.UnseededPairError) console.log(`seed pair ${error.pairIndex} first`)
 * }
 * ```
 */
export class UnseededPairError extends BaseError {
  override name = 'UnseededPairError'
  /** The pair. */
  readonly pairIndex: number

  constructor(
    shortMessage: string,
    { pairIndex, ...rest }: { pairIndex: number } & BaseErrorParameters,
  ) {
    super(shortMessage, rest)
    this.pairIndex = pairIndex
  }
}

/**
 * A value as an error message shows it: a bigint with its `n`, a string quoted, anything else as `String` writes it,
 * so a mid passed as the number `1` reads differently from `1n`. Internal: the package entry doesn't export it.
 *
 * @param value - The value refused.
 * @returns Its text.
 */
export function show(value: unknown): string {
  if (typeof value === 'bigint') return `${value}n`
  if (typeof value === 'string') return JSON.stringify(value)
  return String(value)
}
