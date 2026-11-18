// Under exactOptionalPropertyTypes, every optional property the SDK exports takes an explicit `undefined`, as a caller
// forwarding its own optional value passes one. Each case passes `undefined` for every optional property it can.
import type { Account, Address, Chain, Client, Hex, Log, Transport } from 'viem'
import { describe, expectTypeOf, test } from 'vitest'
import {
  Actions,
  type AnyClient,
  type ContractName,
  Errors,
  Events,
  Info,
  Plan,
  Post,
  type PreparedCall,
  Quote,
  Roles,
  Sequencer,
  Snapshot,
} from '../src/index.js'

declare const client: AnyClient
declare const signer: Client<Transport, Chain, Account>
declare const logs: Log[]
declare const source: Quote.Source
const venue: Address = '0x1111111111111111111111111111111111111111'
const data: Hex = '0x'

describe('optional properties accept undefined', () => {
  test('reads', () => {
    expectTypeOf(Snapshot.get).toBeCallableWith(client, {
      venue,
      pairs: undefined,
      sponsors: undefined,
      accounts: undefined,
      access: undefined,
      blockNumber: undefined,
      multicallAddress: undefined,
      verifyHash: undefined,
    })
    expectTypeOf(Info.orders).toBeCallableWith(client, {
      venue,
      pairs: [0],
      account: undefined,
      blockNumber: undefined,
      blockOverrides: undefined,
      blockTag: undefined,
      stateOverride: undefined,
      multicallAddress: undefined,
    })
    expectTypeOf(Info.venueState).toBeCallableWith(client, {
      venue,
      blockNumber: undefined,
    })
    expectTypeOf(Info.quote).toBeCallableWith(client, {
      venue,
      pairIndex: 0,
      tokenIn: venue,
      tokenOut: venue,
      amount: 1n,
      exactIn: true,
      blockNumber: undefined,
      account: undefined,
      maxFeePerGas: undefined,
      maxPriorityFeePerGas: undefined,
    })
    expectTypeOf(Info.fills).toBeCallableWith(client, {
      venue,
      fromBlock: 0n,
      toBlock: 1n,
      pairIndex: undefined,
    })
    expectTypeOf(Sequencer.seed).toBeCallableWith(client, {
      venue,
      pairs: [0],
      gap: undefined,
      blockNumber: undefined,
      multicallAddress: undefined,
    })
    expectTypeOf(Roles.check).toBeCallableWith(client, {
      call: { address: venue, signer: { role: 'owner' } },
      account: undefined,
      blockNumber: undefined,
      blockOverrides: undefined,
      blockTag: undefined,
      stateOverride: undefined,
      multicallAddress: undefined,
    })
    expectTypeOf(Events.parse).toBeCallableWith(logs, {
      address: undefined,
      eventName: undefined,
    })
    expectTypeOf(Events.venue).toBeCallableWith(logs, {
      venue,
      eventName: undefined,
    })
  })

  test('pure modules', () => {
    expectTypeOf(Quote.local).toBeCallableWith(source, {
      pairIndex: 0,
      tokenIn: venue,
      tokenOut: venue,
      amount: 1n,
      exactIn: true,
      priorityFee: 0n,
      takerAccess: {
        taker: venue,
        sponsorId: 0n,
        access: 'allowed',
        pairIndex: undefined,
      },
    })
    expectTypeOf(Quote.local).toBeCallableWith(source, {
      pairIndex: 0,
      tokenIn: venue,
      tokenOut: venue,
      amount: 1n,
      exactIn: true,
      priorityFee: 0n,
      takerAccess: undefined,
    })
    expectTypeOf(Post.order).toBeCallableWith({
      pairIndex: 0,
      mid: 1n,
      shapeId: 0,
      sequence: 2,
      validUntil: 1,
      bidWiden: undefined,
      askWiden: undefined,
      widthScale: undefined,
      depthScale: undefined,
      sides: undefined,
      refill: undefined,
    })
  })

  test('simulation and gas', () => {
    const step = {
      account: venue,
      calls: [
        {
          to: venue,
          data,
          abi: undefined,
          functionName: undefined,
          args: undefined,
          signer: undefined,
          contract: undefined,
        },
      ],
      maxFeePerGas: undefined,
      maxPriorityFeePerGas: undefined,
    }
    expectTypeOf(Plan.simulate).toBeCallableWith(client, {
      steps: [step],
      blockNumber: undefined,
      blockTag: undefined,
      stateOverride: undefined,
    })
    expectTypeOf(Plan.estimateGas).toBeCallableWith(client, {
      ...step,
      blockNumber: undefined,
      blockTag: undefined,
      stateOverride: undefined,
    })
  })

  test('actions', () => {
    expectTypeOf(Actions.venue.withdraw.call).toBeCallableWith({
      venue,
      token: venue,
      to: venue,
      amount: 1n,
      memo: undefined,
    })
    expectTypeOf(Actions.venue.setHalted<Chain, Account>).toBeCallableWith(
      signer,
      {
        venue,
        halted: true,
        account: undefined,
        chain: undefined,
        gas: undefined,
        maxFeePerGas: undefined,
        maxPriorityFeePerGas: undefined,
        nonce: undefined,
        throwOnReceiptRevert: undefined,
        feePayer: undefined,
        feeToken: undefined,
        keyAuthorization: undefined,
        nonceKey: undefined,
        owner: undefined,
        validAfter: undefined,
        validBefore: undefined,
      },
    )
    expectTypeOf(Actions.venue.setHaltedSync<Chain, Account>).toBeCallableWith(
      signer,
      {
        venue,
        halted: true,
        pollingInterval: undefined,
        timeout: undefined,
      },
    )
    expectTypeOf({
      ...Actions.venue.setHalted.call({ venue, halted: true }),
      posts: undefined,
    }).toExtend<PreparedCall>()
  })

  test('errors', () => {
    expectTypeOf(Errors.InvalidArgumentError).toBeConstructibleWith('x', {
      parameter: undefined,
      value: undefined,
      cause: undefined,
      details: undefined,
      docsPath: undefined,
      metaMessages: undefined,
    })
    expectTypeOf(Errors.UnknownVenueError).toBeConstructibleWith('x', {
      venue,
      factory: undefined,
    })
  })
})

describe('error types', () => {
  test('narrow on their names', () => {
    expectTypeOf<
      Errors.InvalidAddressErrorType['name']
    >().toEqualTypeOf<'InvalidAddressError'>()
    expectTypeOf<Errors.BaseErrorType['name']>().toEqualTypeOf<'BaseError'>()
    expectTypeOf<Errors.InvalidAddressError>().toExtend<Errors.BaseError>()
  })
})

describe('one definition per type', () => {
  test('the client, the contract names and the venue and sponsor state', () => {
    expectTypeOf<PreparedCall['contract']>().toEqualTypeOf<ContractName>()
    expectTypeOf<
      Errors.Decoded['contracts'][number]
    >().toEqualTypeOf<ContractName>()
    expectTypeOf<
      Snapshot.VenueSnapshot['state']
    >().toEqualTypeOf<Info.VenueState>()
    expectTypeOf<Snapshot.SponsorState>().toExtend<Info.SponsorState>()
    expectTypeOf<
      Omit<Snapshot.SponsorState, 'ok' | 'sponsorId' | 'admitted'>
    >().toEqualTypeOf<Info.SponsorState>()
    // Each list of a snapshot is its entries read or not, as `pairs` is.
    expectTypeOf<Snapshot.VenueSnapshot['sponsors'][number]>().toEqualTypeOf<
      Snapshot.SponsorState | Snapshot.SponsorFailure
    >()
    expectTypeOf<Snapshot.VenueSnapshot['accounts'][number]>().toEqualTypeOf<
      Snapshot.AccountState | Snapshot.AccountFailure
    >()
    expectTypeOf<Snapshot.VenueSnapshot['access'][number]>().toEqualTypeOf<
      Snapshot.AccessState | Snapshot.AccessFailure
    >()
  })
})
