import type { Address } from 'viem'
import { describe, expectTypeOf, test } from 'vitest'
import { venueAbi } from '../src/generated/abis.js'
import { type Result, readOf, readValue } from '../src/internal/read.js'
import * as VenueReads from '../src/internal/venue.js'

declare const result: Result
const venue = '0x1111111111111111111111111111111111111111'

describe('expected read inference', () => {
  test('preserves each view result type', () => {
    expectTypeOf(
      readValue(result, readOf(venue, venueAbi, 'owner')),
    ).toEqualTypeOf<Address>()
    expectTypeOf(
      readValue(result, readOf(venue, venueAbi, 'consumed', [0])),
    ).toEqualTypeOf<readonly [bigint, bigint]>()
    expectTypeOf(
      VenueReads.view(result, VenueReads.read(venue, 'halted')),
    ).toEqualTypeOf<boolean>()
  })
})
