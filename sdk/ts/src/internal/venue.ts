// The venue reads `Info` and `Snapshot` share, so both decode the venue-wide state and taker access one way.
import type { Address } from 'viem'
import { validateAccess } from '../Errors.js'
import { venueAbi } from '../generated/abis.js'
import {
  type AccessModeName,
  accessModeNames,
  type TakerAccessName,
  takerAccessNames,
} from '../generated/enums.js'
import type * as Info from '../Info.js'
import { show, UnexpectedResponseError } from './errors.js'
import {
  type Read,
  type Result,
  readOf,
  readValue,
  type ViewArgs,
  type ViewName,
  type ViewValue,
} from './read.js'
import { isUintNumber } from './validate.js'

/** A venue view. */
export type View = ViewName<typeof venueAbi>

/** One venue view to read, for a multicall: its name and arguments typed by the venue ABI. */
export const read = <functionName extends View>(
  venue: Address,
  functionName: functionName,
  args?: ViewArgs<typeof venueAbi, functionName>,
): Read<typeof venueAbi, functionName> =>
  readOf(venue, venueAbi, functionName, args)

/**
 * A venue view's value, checked against the intended read's ABI, name, target and arguments.
 */
export const view = <functionName extends View>(
  result: Result | undefined,
  expected: Read<typeof venueAbi, functionName>,
  what?: string,
): ViewValue<typeof venueAbi, functionName> => readValue(result, expected, what)

/** The views of `Info.VenueState`, in its field order. */
export const stateViews = [
  'owner',
  'pendingOwner',
  'settler',
  'factory',
  'halted',
  'deniedCount',
  'maxTakerPriorityFee',
  'pairCount',
] as const

/**
 * The reads of `Info.VenueState`, in its field order.
 *
 * @param venue - The venue.
 * @returns Its venue-state reads.
 */
export function state(venue: Address): Read[] {
  return stateViews.map((name) => read(venue, name))
}

/**
 * `Info.VenueState` from the results of {@link state}'s reads, in its order (each must have succeeded).
 *
 * @param venue - The intended venue.
 * @param results - The reads' results.
 * @returns The venue state.
 */
export function stateFrom(
  venue: Address,
  results: readonly Result[],
): Info.VenueState {
  return {
    owner: view(results[0], read(venue, 'owner')),
    pendingOwner: view(results[1], read(venue, 'pendingOwner')),
    settler: view(results[2], read(venue, 'settler')),
    factory: view(results[3], read(venue, 'factory')),
    halted: view(results[4], read(venue, 'halted')),
    deniedCount: Number(view(results[5], read(venue, 'deniedCount'))),
    maxTakerPriorityFee: view(results[6], read(venue, 'maxTakerPriorityFee')),
    pairCount: pairCount(view(results[7], read(venue, 'pairCount'))),
  }
}

/**
 * A decoded `pairCount`, checked before it sizes arrays or pair-read batches. The ABI returns a uint16 number;
 * an out-of-domain response is never an input error or permission to allocate more pairs.
 *
 * @param count - The value read.
 * @returns The count, in [0, 65535].
 */
export function pairCount(count: unknown): number {
  if (!isUintNumber(count, 16))
    throw new UnexpectedResponseError(
      `pairCount answered ${show(count)}, outside uint16 (0 to 65535)`,
      { value: count },
    )
  return count
}

/**
 * A `takerAccess` result as its name. A value outside the enum is the node's (or the address's) answer, never an input:
 * `UnexpectedResponseError`.
 *
 * @param code - The value read.
 * @returns Its `TakerAccess` name.
 */
export function accessName(code: unknown): TakerAccessName {
  if (!validateAccess(code))
    throw new UnexpectedResponseError(
      `takerAccess answered ${show(code)}, outside TakerAccess (0 to 9)`,
      { value: code },
    )
  return takerAccessNames[code] as TakerAccessName
}

/**
 * A pair's `AccessMode` as its name. A value outside the enum is the node's (or the address's) answer, never an
 * input: `UnexpectedResponseError`.
 *
 * @param code - The value read.
 * @returns Its `AccessMode` name; `'none'` for a removed or unknown pair.
 */
export function accessModeName(code: unknown): AccessModeName {
  const name =
    typeof code === 'number' && Number.isInteger(code)
      ? accessModeNames[code]
      : undefined
  if (name === undefined)
    throw new UnexpectedResponseError(
      `pair answered access ${show(code)}, outside AccessMode (0 to 3)`,
      { value: code },
    )
  return name
}

/**
 * A live pair's `AccessMode` as its name: never `'none'`, which only a removed or unknown pair reads.
 *
 * @param code - The value read.
 * @returns Its name.
 */
export function liveAccessMode(code: unknown): Exclude<AccessModeName, 'none'> {
  const name = accessModeName(code)
  if (name === 'none')
    throw new UnexpectedResponseError(
      'a live pair answered access None, which addPair never stores',
      { value: code },
    )
  return name
}
