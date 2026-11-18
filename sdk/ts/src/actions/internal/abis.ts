// Each write's ABI, narrowed to its own function and the errors its call can revert with, so viem names a revert and
// each action's declaration holds one function item rather than its contract's whole ABI.
import type { Abi, Address } from 'viem'
import { Abis } from 'viem/tempo'
import { venueAbi, venueFactoryAbi } from '../../generated/abis.js'
import type { AbiErrorItem } from '../../internal/abi.js'
import { InvalidArgumentError } from '../../internal/errors.js'
import * as validate from '../../internal/validate.js'
import {
  defineCall,
  type FunctionAbi,
  type PreparedCall,
  type SignerRole,
  type WriteName,
} from './define.js'

export type VenueAbi = typeof venueAbi
export type VenueFactoryAbi = typeof venueFactoryAbi

/** A venue write's call. */
export type VenueCall<functionName extends WriteName<VenueAbi>> = PreparedCall<
  FunctionAbi<VenueAbi, functionName>,
  functionName
>
/** A factory write's call. */
export type VenueFactoryCall<functionName extends WriteName<VenueFactoryAbi>> =
  PreparedCall<FunctionAbi<VenueFactoryAbi, functionName>, functionName>
const errorsOf = (abi: Abi) =>
  abi.filter((item): item is AbiErrorItem => item.type === 'error')

const venueErrors = errorsOf(venueAbi)
const tip20Errors = errorsOf(Abis.tip20)
/** The factory initializes each venue in the call that creates it, so a venue's revert can surface through it. */
const venueFactoryErrors = [...errorsOf(venueFactoryAbi), ...venueErrors]

/** @internal Narrows a write ABI to its named function and errors. */
export function narrow<abi extends Abi, functionName extends WriteName<abi>>(
  abi: abi,
  functionName: functionName,
  errors: readonly AbiErrorItem[],
): FunctionAbi<abi, functionName> {
  const items = abi.filter(
    (i) => i.type === 'function' && i.name === functionName,
  )
  if (items.length !== 1)
    throw new InvalidArgumentError(
      `${functionName} must name exactly one ABI function, found ${items.length}`,
      { parameter: 'functionName', value: functionName },
    )
  return [items[0], ...errors] as unknown as FunctionAbi<abi, functionName>
}

/** @internal A venue write's call, to the venue checked. `withdraw` moves a TIP-20, so it decodes TIP-20's errors too. */
export function venueCall<functionName extends WriteName<VenueAbi>>(call: {
  venue: Address
  functionName: functionName
  args: VenueCall<functionName>['args']
  signer: SignerRole
  posts?: VenueCall<functionName>['posts']
}): VenueCall<functionName> {
  return defineCall({
    abi: narrow(
      venueAbi,
      call.functionName,
      call.functionName === 'withdraw'
        ? [...venueErrors, ...tip20Errors]
        : venueErrors,
    ),
    address: validate.address(call.venue, 'venue', { nonzero: true }),
    args: call.args,
    functionName: call.functionName,
    contract: 'Venue',
    signer: call.signer,
    ...(call.posts ? { posts: call.posts } : {}),
  } as never)
}

/** @internal A factory write's call, to the factory checked. */
export function venueFactoryCall<
  functionName extends WriteName<VenueFactoryAbi>,
>(call: {
  factory: Address
  functionName: functionName
  args: VenueFactoryCall<functionName>['args']
  signer: SignerRole
}): VenueFactoryCall<functionName> {
  return defineCall({
    abi: narrow(venueFactoryAbi, call.functionName, venueFactoryErrors),
    address: validate.address(call.factory, 'factory', { nonzero: true }),
    args: call.args,
    functionName: call.functionName,
    contract: 'VenueFactory',
    signer: call.signer,
  } as never)
}
