// `propAmmActions()`'s types: every action, bound to the client's chain and account, with its helpers bound too.
import type { Address, Hash, Log, PrivateKeyAccount } from 'viem'
import { createClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/chains'
import { tempoActions } from 'viem/tempo'
import { describe, expectTypeOf, test } from 'vitest'
import {
  type Actions,
  type PropAmmActions,
  propAmmActions,
  type Sequencer,
} from '../src/index.js'

const venue: Address = '0x1111111111111111111111111111111111111111'
declare const logs: Log[]
declare const sequencer: Sequencer.Sequencer

const client = createClient({
  account: privateKeyToAccount(`0x${'11'.repeat(32)}`),
  chain: tempoModerato,
  transport: http(),
})
  .extend(tempoActions())
  .extend(propAmmActions())

describe('propAmmActions', () => {
  test('binds every action of every group, and nothing else', () => {
    expectTypeOf<keyof PropAmmActions['factory']>().toEqualTypeOf<
      keyof typeof Actions.factory
    >()
    expectTypeOf<keyof PropAmmActions['maker']>().toEqualTypeOf<
      keyof typeof Actions.maker
    >()
    expectTypeOf<keyof PropAmmActions['venue']>().toEqualTypeOf<
      keyof typeof Actions.venue
    >()
  })

  test("an action takes its parameters for the client's chain and account, which it may omit", () => {
    expectTypeOf(client.venue.setHalted)
      .parameter(0)
      .toEqualTypeOf<
        Actions.venue.setHalted.Parameters<
          typeof tempoModerato,
          PrivateKeyAccount
        >
      >()
    expectTypeOf(client.venue.setHalted).toBeCallableWith({
      venue,
      halted: true,
    })
    expectTypeOf(client.venue.cancelOwnershipTransfer).toBeCallableWith({
      venue,
    })
    expectTypeOf(client.venue.cancelSponsorAdminTransfer).toBeCallableWith({
      venue,
      sponsorId: 42n,
    })
    expectTypeOf(client.venue.setHalted).returns.toEqualTypeOf<Promise<Hash>>()
    expectTypeOf(client.venue.setHaltedSync).returns.toEqualTypeOf<
      Promise<Actions.venue.setHaltedSync.ReturnValue>
    >()
    expectTypeOf(client.maker.cancelAllSync).toBeCallableWith({
      venue,
      sequencer,
    })
    // viem/tempo's own actions sit beside them.
    expectTypeOf(client.token.transferSync).toBeFunction()
  })

  test('helpers are bound to the client, and client-less ones are as they are', () => {
    expectTypeOf(client.venue.setHalted.call).toEqualTypeOf<
      typeof Actions.venue.setHalted.call
    >()
    expectTypeOf(client.venue.setHalted.extractEvent).toEqualTypeOf<
      typeof Actions.venue.setHalted.extractEvent
    >()
    expectTypeOf(client.venue.setMembers.extractEvents).toEqualTypeOf<
      typeof Actions.venue.setMembers.extractEvents
    >()
    // Simulation and gas are viem's own actions over `call()`: no binding carries them.
    // @ts-expect-error: no bound simulate.
    client.factory.createVenue.simulate
    // @ts-expect-error: no bound estimateGas.
    client.venue.setHalted.estimateGas
    expectTypeOf(client.maker.cancelAll.requests).toBeCallableWith({
      venue,
      sequencer,
    })
    expectTypeOf(client.maker.order.extractEvents(logs)).toEqualTypeOf<
      ReturnType<typeof Actions.maker.order.extractEvents>
    >()
  })
})
