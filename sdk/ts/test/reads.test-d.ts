// The read modules' types: every read's namespace names its parameters, value and errors; reads take viem/tempo's read
// parameters; the inputs a caller must not leave out (a quote's priority fee, a live book's state) are required; and
// results narrow on their status before their fields can be read.
import type {
  Account,
  Address,
  Log,
  ReadContractParameters,
  TransactionReceipt,
} from 'viem'
import { describe, expectTypeOf, test } from 'vitest'
import {
  type AnyClient,
  Book,
  type Errors,
  Info,
  Plan,
  PostOutcome,
  Quote,
  type ReadParameters,
  Roles,
  Sequencer,
  Snapshot,
} from '../src/index.js'

declare const client: AnyClient
declare const venue: Address
declare const pair: Snapshot.PairState
declare const source: Quote.Source

describe('read parameters', () => {
  test("are viem/tempo's: account, blockNumber, blockOverrides, blockTag and stateOverride", () => {
    expectTypeOf<keyof ReadParameters>().toEqualTypeOf<
      | 'account'
      | 'blockNumber'
      | 'blockOverrides'
      | 'blockTag'
      | 'stateOverride'
    >()
    expectTypeOf<ReadParameters['blockTag']>().toEqualTypeOf<
      ReadContractParameters['blockTag']
    >()
    for (const read of [
      Info.venueState,
      Info.sponsorState,
      Info.meta,
      Info.orders,
    ] as const)
      expectTypeOf(read).parameter(1).toExtend<ReadParameters>()
    expectTypeOf<Snapshot.get.Parameters>().toExtend<ReadParameters>()
    expectTypeOf<Sequencer.seed.Parameters>().toExtend<ReadParameters>()
  })

  test("take the checked account in place of the read's caller where the read is about an account", () => {
    expectTypeOf<Info.isDenied.Parameters['account']>().toEqualTypeOf<Address>()
    expectTypeOf<Info.isMember.Parameters['account']>().toEqualTypeOf<Address>()
    expectTypeOf<Roles.check.Parameters['account']>().toEqualTypeOf<
      Account | Address | undefined
    >()
  })
})

describe('namespaces', () => {
  test('name each read and its parameters, value and errors', () => {
    expectTypeOf(Info.venueState)
      .parameter(1)
      .toEqualTypeOf<Info.venueState.Parameters>()
    expectTypeOf(
      Info.venueState,
    ).returns.resolves.toEqualTypeOf<Info.VenueState>()
    expectTypeOf(Info.orders).returns.resolves.toEqualTypeOf<{
      blockNumber: bigint
      orders: Info.OrderState[]
    }>()
    expectTypeOf(
      Snapshot.get,
    ).returns.resolves.toEqualTypeOf<Snapshot.VenueSnapshot>()
    expectTypeOf(Plan.simulate).returns.resolves.toEqualTypeOf<
      Plan.StepResult[]
    >()
    expectTypeOf(Roles.check).returns.resolves.toEqualTypeOf<Roles.Check>()
    expectTypeOf<Errors.InvalidAddressErrorType>().toExtend<Info.isVenue.ErrorType>()
    expectTypeOf<Errors.UnknownPairErrorType>().toExtend<Info.orders.ErrorType>()
    expectTypeOf<Errors.UnknownVenueErrorType>().toExtend<Snapshot.get.ErrorType>()
    expectTypeOf<Errors.MissingAccountErrorType>().toExtend<Roles.check.ErrorType>()
    expectTypeOf<Errors.EmptyBatchErrorType>().toExtend<Plan.simulate.ErrorType>()
    expectTypeOf<Errors.UnseededPairErrorType>().toExtend<Sequencer.next.ErrorType>()
  })
})

describe('required inputs', () => {
  test("a quote's priority fee", () => {
    expectTypeOf<Quote.Request['priorityFee']>().toEqualTypeOf<bigint>()
    const request = {
      pairIndex: 0,
      tokenIn: venue,
      tokenOut: venue,
      amount: 1n,
      exactIn: true,
    }
    // @ts-expect-error: no silent priority fee.
    Quote.local(source, request)
    Quote.local(source, { ...request, priorityFee: 0n })
  })

  test("a snapshot's access is a quote's takerAccess", () => {
    expectTypeOf<Snapshot.AccessState>().toExtend<Quote.TakerAccess>()
    expectTypeOf(Snapshot.access).returns.toExtend<Quote.TakerAccess>()
  })

  test("a live book's time and halt; the posted ladder needs neither", () => {
    // @ts-expect-error: a live side needs { at, halted }.
    Book.side(pair, 'asks')
    // @ts-expect-error: so does the base it can still give.
    Book.remaining(pair, 'bids')
    expectTypeOf(Book.side).parameter(2).toEqualTypeOf<Book.State>()
    expectTypeOf(Book.ladder).returns.toEqualTypeOf<Book.Row[]>()
    expectTypeOf<Book.State>().toEqualTypeOf<{ at: bigint; halted: boolean }>()
  })
})

describe('results narrow on their status', () => {
  test('a snapshot entry', () => {
    const entry = {} as Snapshot.VenueSnapshot['sponsors'][number]
    // @ts-expect-error: a failed entry has no admin.
    entry.admin
    if (entry.ok) expectTypeOf(entry.admin).toEqualTypeOf<Address>()
    else expectTypeOf(entry.error).toEqualTypeOf<Error>()
  })

  test('a simulated call and step', () => {
    const call = {} as Plan.CallResult
    // @ts-expect-error: a call that never ran used no gas.
    call.gasUsed
    if (call.status === 'success')
      expectTypeOf(call.events).toEqualTypeOf<
        ReturnType<typeof import('../src/index.js').Events.parse>
      >()
    if (call.status === 'failure')
      expectTypeOf(call.error).toEqualTypeOf<Errors.Decoded | null>()
    const step = {} as Plan.StepResult
    // @ts-expect-error: only a failed step names its failed call.
    step.failedCall
    if (step.status === 'failure')
      expectTypeOf(step.failedCall).toEqualTypeOf<number>()
  })

  test("a receipt's post outcome", () => {
    expectTypeOf<TransactionReceipt>().toExtend<PostOutcome.Receipt>()
    const outcome = {} as PostOutcome.ReceiptOutcome
    // @ts-expect-error: a pending or reverted receipt has no entries to read as skipped.
    outcome.skipped
    if (outcome.status === 'success')
      expectTypeOf(outcome.skipped).toEqualTypeOf<
        PostOutcome.PostOutcome['skipped']
      >()
    expectTypeOf(PostOutcome.fromLogs)
      .parameter(1)
      .toEqualTypeOf<readonly Log[]>()
  })
})

describe('Sequencer', () => {
  test('is a state value, written only through next and observe', () => {
    const sequencer = Sequencer.from()
    expectTypeOf(sequencer).toEqualTypeOf<Sequencer.Sequencer>()
    expectTypeOf(sequencer.last).toEqualTypeOf<ReadonlyMap<number, number>>()
    // @ts-expect-error: the counters are read-only outside next and observe.
    sequencer.last.set(0, 1)
    expectTypeOf(Sequencer.next).returns.toEqualTypeOf<number>()
    expectTypeOf(Sequencer.last).returns.toEqualTypeOf<number | undefined>()
    expectTypeOf(
      Sequencer.seed,
    ).returns.resolves.toEqualTypeOf<Sequencer.Sequencer>()
  })
})

describe('optional properties accept undefined', () => {
  test('in the new parameters', () => {
    expectTypeOf(Snapshot.get).toBeCallableWith(client, {
      venue,
      account: undefined,
      blockNumber: undefined,
      blockOverrides: undefined,
      blockTag: undefined,
      stateOverride: undefined,
      multicallAddress: undefined,
      verifyHash: undefined,
    })
    expectTypeOf(Sequencer.seed).toBeCallableWith(client, {
      venue,
      pairs: [0],
      gap: undefined,
      blockTag: undefined,
      stateOverride: undefined,
    })
    expectTypeOf(PostOutcome.fromReceipt).toBeCallableWith(
      { address: venue, posts: undefined },
      { status: 'success', logs: [], blockNumber: 1n, blockHash: undefined },
    )
  })
})
