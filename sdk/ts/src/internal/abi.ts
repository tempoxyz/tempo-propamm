import type { Abi, AbiEvent } from 'viem'
import { formatAbiItem } from 'viem/utils'

/**
 * An `error` item of an ABI, as `Errors.allErrorsAbi` and `Errors.errorOf` hold them (viem exports a name for an
 * event's item, `AbiEvent`, but none for an error's).
 *
 * @example
 * ```ts
 * import { type AbiErrorItem, Errors } from '@tempoxyz/propamm-sdk'
 *
 * const zeroFill: AbiErrorItem | undefined = Errors.errorOf('0x69495f5e')
 * console.log(zeroFill?.name) // 'ZeroFill'
 * ```
 */
export type AbiErrorItem = Extract<Abi[number], { type: 'error' }>

/**
 * `Name(type,type)`: the canonical signature an error's or event's selector hashes, tuples expanded, as viem's
 * `formatAbiItem` writes it.
 *
 * @param item - The error or event.
 * @returns Its canonical signature.
 */
export function signature(item: AbiErrorItem | AbiEvent): string {
  return formatAbiItem(item)
}
