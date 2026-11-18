// `Events`' types: a union over every SDK event that `eventName` narrows, typed from the ABIs.
import type { Address, Hex, Log } from 'viem'
import { describe, expectTypeOf, test } from 'vitest'
import { Events } from '../src/index.js'

declare const logs: Log[]
const venue: Address = '0x1111111111111111111111111111111111111111'

describe('Events', () => {
  test('parse returns the union, and eventName narrows each variant', () => {
    const [event] = Events.parse(logs)
    expectTypeOf(event).toEqualTypeOf<Events.Event | undefined>()
    if (event?.eventName === 'Posted')
      expectTypeOf(event.args).toEqualTypeOf<{
        pairIndex: number
        hotWord: Hex
      }>()
    if (event?.eventName === 'Transfer')
      expectTypeOf(event.args).toEqualTypeOf<{
        from: Address
        to: Address
        amount: bigint
      }>()
    expectTypeOf<Events.Event['eventName']>().toEqualTypeOf<Events.EventName>()
  })

  test('an eventName option narrows the result', () => {
    expectTypeOf(Events.parse(logs, { eventName: 'Fill' })).toEqualTypeOf<
      Events.Event<'Fill'>[]
    >()
    expectTypeOf(
      Events.parse(logs, { eventName: ['Posted', 'Refilled'] }),
    ).toEqualTypeOf<Events.Event<'Posted' | 'Refilled'>[]>()
    expectTypeOf(
      Events.venue(logs, { venue, eventName: 'Fill' })[0]?.args.amountOut,
    ).toEqualTypeOf<bigint | undefined>()
    // @ts-expect-error: no SDK contract emits it.
    Events.parse(logs, { eventName: 'Posed' })
    // @ts-expect-error: a TIP-20 event, not the venue's.
    Events.venue(logs, { venue, eventName: 'Transfer' })
  })

  test('the venue events are the venue ABI events', () => {
    expectTypeOf<
      Events.VenueEvent['eventName']
    >().toEqualTypeOf<Events.VenueEventName>()
    expectTypeOf<Events.VenueEvent<'Posted'>>().toEqualTypeOf<
      Events.Event<'Posted'>
    >()
  })
})
