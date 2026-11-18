// The actions' types: parameters for the client's chain and account, with viem/tempo's transaction fields; return
// values; calls narrowed to their own function, which viem's contract actions take as they are; typed events; and
// error types that include viem's.
import {
  type Account,
  type Address,
  type Chain,
  type Client,
  createClient,
  encodeFunctionData,
  type GetBlockErrorType,
  type GetBlockNumberErrorType,
  type Hash,
  type Hex,
  http,
  type Log,
  type Transport,
  type WriteContractErrorType,
  type WriteContractSyncErrorType,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import {
  estimateContractGas,
  simulateContract,
  writeContract,
} from 'viem/actions'
import { tempoModerato } from 'viem/chains'
import type { Transaction } from 'viem/tempo'
import { describe, expectTypeOf, test } from 'vitest'
import {
  type AccessModeName,
  Actions,
  type Errors,
  type HotWord,
  type Info,
  type Post,
  type PostOutcome,
  type PreparedCall,
  type Sequencer,
  type Snapshot,
  type WriteParameters,
} from '../src/index.js'

const venue: Address = '0x1111111111111111111111111111111111111111'
declare const logs: Log[]
declare const sequencer: Sequencer.Sequencer
declare const anonymous: Client<Transport, typeof tempoModerato, undefined>

const client = createClient({
  account: privateKeyToAccount(`0x${'11'.repeat(32)}`),
  chain: tempoModerato,
  transport: http(),
})

describe('parameters', () => {
  test("the sender defaults to the client's account, and is required without one", () => {
    expectTypeOf(
      Actions.venue.setHalted(client, { venue, halted: true }),
    ).resolves.toEqualTypeOf<Hash>()
    Actions.venue.setHalted(anonymous, { venue, halted: true, account: venue })
    // @ts-expect-error: the client has no account to send from.
    Actions.venue.setHalted(anonymous, { venue, halted: true })
  })

  test("take viem/tempo's transaction fields", () => {
    expectTypeOf<keyof WriteParameters>().toEqualTypeOf<
      | 'account'
      | 'chain'
      | 'gas'
      | 'maxFeePerGas'
      | 'maxPriorityFeePerGas'
      | 'nonce'
      | 'throwOnReceiptRevert'
      | 'feePayer'
      | 'feeToken'
      | 'keyAuthorization'
      | 'nonceKey'
      | 'owner'
      | 'validAfter'
      | 'validBefore'
    >()
    expectTypeOf<WriteParameters['feeToken']>().toEqualTypeOf<
      Transaction.TransactionRequestTempo['feeToken']
    >()
    expectTypeOf<WriteParameters['nonceKey']>().toEqualTypeOf<
      Transaction.TransactionRequestTempo['nonceKey']
    >()
    Actions.venue.setHaltedSync(client, {
      venue,
      halted: true,
      feePayer: true,
      feeToken: '0x20c0000000000000000000000000000000000001',
      nonceKey: 'expiring',
      validAfter: 1,
      validBefore: 1_800_000_000,
      timeout: 10_000,
    })
  })

  test("createVenue's owner is the venue's, so it takes no multisig owner field", () => {
    expectTypeOf<
      Actions.factory.createVenue.Parameters['owner']
    >().toEqualTypeOf<Address>()
  })

  test("one call simulates and estimates through viem's own actions, at the block and state given", () => {
    const call = Actions.venue.setHalted.call({ venue, halted: true })
    expectTypeOf(
      simulateContract(client, {
        ...call,
        account: venue,
        blockTag: 'latest',
        stateOverride: [],
      }),
    ).resolves.toHaveProperty('request')
    expectTypeOf(
      estimateContractGas(client, { ...call, account: venue }),
    ).resolves.toEqualTypeOf<bigint>()
    // The per-action helpers are gone: viem's actions take every call as it is.
    // @ts-expect-error: no per-action simulate.
    Actions.venue.setHalted.simulate
    // @ts-expect-error: no per-action estimateGas.
    Actions.maker.cancelAll.estimateGas
    expectTypeOf(Actions.maker.cancelAll.requests).toBeCallableWith(client, {
      venue,
      sequencer,
      blockNumber: 1n,
      multicallAddress: venue,
    })
    expectTypeOf<Actions.maker.cancelAllSync.Args>().toEqualTypeOf<Actions.maker.cancelAll.Args>()
  })
})

describe('orders', () => {
  test("a word's raw fields make an order as they are", () => {
    expectTypeOf<
      { pairIndex: number } & HotWord.Fields
    >().toExtend<Post.OrderRequest>()
    expectTypeOf<Post.OrderRequest['flags']>().toEqualTypeOf<
      number | undefined
    >()
  })

  test('flags never come with named sides or refill', () => {
    type Fields = Post.OrderRequest.Fields
    expectTypeOf<
      Fields & { sides: 'bids'; refill: 'asks' }
    >().toExtend<Post.OrderRequest>()
    expectTypeOf<Fields & { flags: number }>().toExtend<Post.OrderRequest>()
    expectTypeOf<
      Fields & { flags: number; sides: 'bids' }
    >().not.toExtend<Post.OrderRequest>()
    expectTypeOf<
      Fields & { flags: number; refill: 'asks' }
    >().not.toExtend<Post.OrderRequest>()
  })
})

describe('return values', () => {
  test('a write returns its hash, its Sync twin its event beside a successful receipt, or the receipt alone', () => {
    type Success = Transaction.TransactionReceipt<bigint, number, 'success'>
    type Unmined = Omit<
      Transaction.TransactionReceipt,
      'blockNumber' | 'blockHash'
    > & {
      blockNumber: bigint | null
      blockHash: Hex | null
    }
    expectTypeOf(Actions.venue.setHalted).returns.toEqualTypeOf<Promise<Hash>>()
    type Failed = { status: 'reverted' | 'pending'; receipt: Unmined }
    expectTypeOf<Actions.venue.setHaltedSync.ReturnValue>().toEqualTypeOf<
      | { status: 'success'; changed: true; halted: boolean; receipt: Success }
      | { status: 'success'; changed: false; receipt: Success }
      | Failed
    >()
    expectTypeOf<Actions.venue.addPairSync.ReturnValue>().toEqualTypeOf<
      | {
          status: 'success'
          pairIndex: number
          base: Address
          quote: Address
          sizeUnit: bigint
          receipt: Success
        }
      | Failed
    >()
    expectTypeOf<
      Extract<
        Actions.venue.setMembersSync.ReturnValue,
        { status: 'success' }
      >['updates'][number]
    >().toEqualTypeOf<{
      pairIndex: number
      sponsorId: bigint
      account: Address
      allowed: boolean
    }>()
    expectTypeOf<Actions.maker.cancelAllSync.ReturnValue>().toEqualTypeOf<
      | {
          status: 'success'
          posted: { pairIndex: number; hotWord: Hex }[]
          outcome: PostOutcome.PostOutcome
          receipt: Success
          skipped: Actions.maker.cancelAll.SkippedPair[]
        }
      | {
          status: 'reverted' | 'pending'
          receipt: Unmined
          skipped: Actions.maker.cancelAll.SkippedPair[]
        }
    >()
    expectTypeOf<Actions.maker.cancelAll.requests.ReturnValue>().toEqualTypeOf<{
      cancels: Post.CancelRequest[]
      skipped: {
        pairIndex: number
        reason: 'neverPosted' | 'sequenceExhausted'
      }[]
    }>()
    expectTypeOf<Actions.maker.orderSync.ReturnValue>().toEqualTypeOf<Actions.venue.postSync.ReturnValue>()
  })

  test("a Sync result's fields are read only once its status is a success", async () => {
    const result = await Actions.venue.addPairSync(client, {
      venue,
      base: venue,
      quote: venue,
      sizeUnit: 1n,
    })
    // @ts-expect-error: a pending or reverted receipt carries no event.
    result.pairIndex
    if (result.status === 'success') {
      expectTypeOf(result.pairIndex).toEqualTypeOf<number>()
      expectTypeOf(result.receipt.status).toEqualTypeOf<'success'>()
    } else
      expectTypeOf(result).toEqualTypeOf<{
        status: 'reverted' | 'pending'
        receipt: Unmined
      }>()
    type Unmined = Omit<
      Transaction.TransactionReceipt,
      'blockNumber' | 'blockHash'
    > & {
      blockNumber: bigint | null
      blockHash: Hex | null
    }
  })

  test('extractEvent returns the typed log, extractEvents a list of them, from an address if given', () => {
    expectTypeOf(Actions.venue.withdraw.extractEvent).toBeCallableWith(logs, {
      address: venue,
    })
    expectTypeOf(Actions.maker.order.extractEvents).toBeCallableWith(logs, {
      address: venue,
    })
    expectTypeOf(Actions.venue.withdraw.extractEvent(logs).args).toEqualTypeOf<{
      token: Address
      to: Address
      amount: bigint
      memo: Hex
    }>()
    expectTypeOf(
      Actions.venue.withdraw.extractEvent(logs).eventName,
    ).toEqualTypeOf<'Withdrawn'>()
    expectTypeOf(
      Actions.venue.cancelOwnershipTransfer.extractEvent(logs).args,
    ).toEqualTypeOf<{ owner: Address; pendingOwner: Address }>()
    expectTypeOf(
      Actions.venue.cancelSponsorAdminTransfer.extractEvent(logs).args,
    ).toEqualTypeOf<{
      sponsorId: bigint
      admin: Address
      pendingAdmin: Address
    }>()
    expectTypeOf(
      Actions.venue.setDenied.extractEvents(logs)[0]?.args.denied,
    ).toEqualTypeOf<boolean | undefined>()
  })
})

describe('calls', () => {
  const call = Actions.venue.setHalted.call({ venue, halted: true })

  test('are narrowed to their own function', () => {
    expectTypeOf(call.functionName).toEqualTypeOf<'setHalted'>()
    expectTypeOf(call.args).toEqualTypeOf<readonly [boolean]>()
    expectTypeOf(call.abi[0].name).toEqualTypeOf<'setHalted'>()
    expectTypeOf(
      Actions.maker.order.call({
        venue,
        order: {
          pairIndex: 0,
          mid: 1n,
          shapeId: 0,
          sequence: 2,
          validUntil: 1,
        },
      }).args,
    ).toEqualTypeOf<readonly [Hex]>()
    expectTypeOf(call).toExtend<PreparedCall>()
  })

  test("go to viem's contract actions and encoders as they are", () => {
    expectTypeOf(
      simulateContract(client, { ...call, account: venue }),
    ).resolves.toHaveProperty('request')
    expectTypeOf(writeContract(client, call)).resolves.toEqualTypeOf<Hash>()
    expectTypeOf(encodeFunctionData(call)).toEqualTypeOf<Hex>()
  })
})

describe('errors', () => {
  test("are the SDK's refusals and viem's errors", () => {
    expectTypeOf<WriteContractErrorType>().toExtend<Actions.venue.withdraw.ErrorType>()
    expectTypeOf<Errors.AmountOutOfRangeErrorType>().toExtend<Actions.venue.withdraw.ErrorType>()
    expectTypeOf<Errors.InvalidShapeErrorType>().toExtend<Actions.venue.setShape.ErrorType>()
    expectTypeOf<WriteContractSyncErrorType>().toExtend<Actions.venue.setShapeSync.ErrorType>()
    // cancelAll reads at one block it pins, and throws EmptyBatchError when no pair gets a cancel.
    expectTypeOf<GetBlockNumberErrorType>().toExtend<Actions.maker.cancelAll.ErrorType>()
    expectTypeOf<GetBlockErrorType>().toExtend<Actions.maker.cancelAll.requests.ErrorType>()
    expectTypeOf<Errors.EmptyBatchErrorType>().toExtend<Actions.maker.cancelAllSync.ErrorType>()
    // Its cancels carry stored mids, at most one per pair, so it throws neither of these.
    expectTypeOf<Errors.InvalidPriceErrorType>().not.toExtend<Actions.maker.cancelAll.ErrorType>()
    expectTypeOf<Errors.DuplicatePairErrorType>().not.toExtend<Actions.maker.cancelAll.ErrorType>()
    // A pair with no sequence left is skipped, not thrown for.
    expectTypeOf<Errors.SequenceExhaustedErrorType>().not.toExtend<Actions.maker.cancelAll.ErrorType>()
  })
})

describe('access modes', () => {
  test('read as setPairAccess writes them: lowercase names', () => {
    const market = {} as Info.Market
    expectTypeOf(Actions.venue.setPairAccess.call).toBeCallableWith({
      venue,
      pairIndex: market.pairIndex,
      mode: market.access,
    })
    expectTypeOf<Info.Market['access']>().toEqualTypeOf<
      'closed' | 'listed' | 'open'
    >()
    expectTypeOf<Snapshot.PairState['access']>().toEqualTypeOf<AccessModeName>()
    expectTypeOf<AccessModeName>().toEqualTypeOf<
      'none' | 'closed' | 'listed' | 'open'
    >()
    // No pair is set to none: only a removed or unknown one reads it.
    Actions.venue.setPairAccess.call({
      venue,
      pairIndex: 0,
      // @ts-expect-error: 'none' is no mode a pair can be set to.
      mode: 'none',
    })
  })
})

describe('generics', () => {
  test("follow the client's chain and account, as viem's do", () => {
    expectTypeOf<
      Actions.venue.setHalted.Parameters<Chain, Account>['account']
    >().toEqualTypeOf<Account | Address | null | undefined>()
  })
})

// Every public send wrapper runs the shared validity preflight, including Sync twins.
test('all write errors expose validity refusals and their parameter/value metadata', () => {
  type WriteErrors = {
    'maker.bulkOrders': Actions.maker.bulkOrders.ErrorType
    'maker.bulkOrdersSync': Actions.maker.bulkOrdersSync.ErrorType
    'maker.order': Actions.maker.order.ErrorType
    'maker.orderSync': Actions.maker.orderSync.ErrorType
    'maker.bulkCancel': Actions.maker.bulkCancel.ErrorType
    'maker.bulkCancelSync': Actions.maker.bulkCancelSync.ErrorType
    'maker.cancel': Actions.maker.cancel.ErrorType
    'maker.cancelSync': Actions.maker.cancelSync.ErrorType
    'maker.cancelAll': Actions.maker.cancelAll.ErrorType
    'maker.cancelAllSync': Actions.maker.cancelAllSync.ErrorType
    'venue.addPair': Actions.venue.addPair.ErrorType
    'venue.addPairSync': Actions.venue.addPairSync.ErrorType
    'venue.removePair': Actions.venue.removePair.ErrorType
    'venue.removePairSync': Actions.venue.removePairSync.ErrorType
    'venue.setPairAccess': Actions.venue.setPairAccess.ErrorType
    'venue.setPairAccessSync': Actions.venue.setPairAccessSync.ErrorType
    'venue.closePair': Actions.venue.closePair.ErrorType
    'venue.closePairSync': Actions.venue.closePairSync.ErrorType
    'venue.resetHotWord': Actions.venue.resetHotWord.ErrorType
    'venue.resetHotWordSync': Actions.venue.resetHotWordSync.ErrorType
    'venue.addSponsor': Actions.venue.addSponsor.ErrorType
    'venue.addSponsorSync': Actions.venue.addSponsorSync.ErrorType
    'venue.setSponsorEnabled': Actions.venue.setSponsorEnabled.ErrorType
    'venue.setSponsorEnabledSync': Actions.venue.setSponsorEnabledSync.ErrorType
    'venue.setPairSponsor': Actions.venue.setPairSponsor.ErrorType
    'venue.setPairSponsorSync': Actions.venue.setPairSponsorSync.ErrorType
    'venue.setMembers': Actions.venue.setMembers.ErrorType
    'venue.setMembersSync': Actions.venue.setMembersSync.ErrorType
    'venue.transferSponsorAdmin': Actions.venue.transferSponsorAdmin.ErrorType
    'venue.transferSponsorAdminSync': Actions.venue.transferSponsorAdminSync.ErrorType
    'venue.cancelSponsorAdminTransfer': Actions.venue.cancelSponsorAdminTransfer.ErrorType
    'venue.cancelSponsorAdminTransferSync': Actions.venue.cancelSponsorAdminTransferSync.ErrorType
    'venue.acceptSponsorAdmin': Actions.venue.acceptSponsorAdmin.ErrorType
    'venue.acceptSponsorAdminSync': Actions.venue.acceptSponsorAdminSync.ErrorType
    'venue.resetSponsor': Actions.venue.resetSponsor.ErrorType
    'venue.resetSponsorSync': Actions.venue.resetSponsorSync.ErrorType
    'venue.setDenied': Actions.venue.setDenied.ErrorType
    'venue.setDeniedSync': Actions.venue.setDeniedSync.ErrorType
    'venue.setPairHook': Actions.venue.setPairHook.ErrorType
    'venue.setPairHookSync': Actions.venue.setPairHookSync.ErrorType
    'venue.approveAgent': Actions.venue.approveAgent.ErrorType
    'venue.approveAgentSync': Actions.venue.approveAgentSync.ErrorType
    'venue.revokeAgent': Actions.venue.revokeAgent.ErrorType
    'venue.revokeAgentSync': Actions.venue.revokeAgentSync.ErrorType
    'venue.setSettler': Actions.venue.setSettler.ErrorType
    'venue.setSettlerSync': Actions.venue.setSettlerSync.ErrorType
    'venue.setHalted': Actions.venue.setHalted.ErrorType
    'venue.setHaltedSync': Actions.venue.setHaltedSync.ErrorType
    'venue.withdraw': Actions.venue.withdraw.ErrorType
    'venue.withdrawSync': Actions.venue.withdrawSync.ErrorType
    'venue.transferOwnership': Actions.venue.transferOwnership.ErrorType
    'venue.transferOwnershipSync': Actions.venue.transferOwnershipSync.ErrorType
    'venue.cancelOwnershipTransfer': Actions.venue.cancelOwnershipTransfer.ErrorType
    'venue.cancelOwnershipTransferSync': Actions.venue.cancelOwnershipTransferSync.ErrorType
    'venue.acceptOwnership': Actions.venue.acceptOwnership.ErrorType
    'venue.acceptOwnershipSync': Actions.venue.acceptOwnershipSync.ErrorType
    'venue.post': Actions.venue.post.ErrorType
    'venue.postSync': Actions.venue.postSync.ErrorType
    'venue.setShape': Actions.venue.setShape.ErrorType
    'venue.setShapeSync': Actions.venue.setShapeSync.ErrorType
    'venue.setMaxTakerPriorityFee': Actions.venue.setMaxTakerPriorityFee.ErrorType
    'venue.setMaxTakerPriorityFeeSync': Actions.venue.setMaxTakerPriorityFeeSync.ErrorType
    'venue.enableTakerPriorityFeeCap': Actions.venue.enableTakerPriorityFeeCap.ErrorType
    'venue.enableTakerPriorityFeeCapSync': Actions.venue.enableTakerPriorityFeeCapSync.ErrorType
    'venue.setMidBand': Actions.venue.setMidBand.ErrorType
    'venue.setMidBandSync': Actions.venue.setMidBandSync.ErrorType
    'factory.createVenue': Actions.factory.createVenue.ErrorType
    'factory.createVenueSync': Actions.factory.createVenueSync.ErrorType
  }
  type ValidityErrors = {
    [action in keyof WriteErrors]: Extract<
      WriteErrors[action],
      { name: 'InvalidArgumentError' }
    >
  }
  expectTypeOf<ValidityErrors>().toEqualTypeOf<{
    [action in keyof WriteErrors]: Errors.InvalidArgumentErrorType
  }>()
  type Metadata = {
    [action in keyof WriteErrors]: Pick<
      ValidityErrors[action],
      'parameter' | 'value'
    >
  }
  expectTypeOf<Metadata>().toEqualTypeOf<{
    [action in keyof WriteErrors]: {
      readonly parameter: string | undefined
      readonly value: unknown
    }
  }>()
})
