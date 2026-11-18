import { maxUint32 } from 'viem'
import { getTransactionReceipt, sendTransactionSync } from 'viem/actions'
import { afterAll, beforeAll, expect, test } from 'vitest'
import {
  Actions,
  Errors,
  Events,
  Info,
  PostOutcome,
  Price,
  Sequencer,
} from '../../src/index.js'
import {
  type Fixture,
  mined,
  setupPair,
  start,
  swapAtQuote,
} from './fixture.js'

let f: Fixture
beforeAll(async () => {
  f = await start()
})
afterAll(async () => f?.stop())

test('recovers an exhausted sequence through the SDK and restarts its allocator without refilling', async () => {
  const p = await setupPair(f)
  const { client, venue, accounts } = f
  await swapAtQuote(f, {
    venue,
    pairIndex: p.pairIndex,
    tokenIn: f.quote,
    tokenOut: f.base,
    amount: 1_000_000n,
    exactIn: false,
    sponsorId: 0n,
    account: accounts.taker,
  })
  const consumed = await Info.consumed(client, {
    venue,
    pairIndex: p.pairIndex,
  })
  await Actions.maker.orderSync(client, {
    venue,
    account: accounts.agent,
    order: {
      pairIndex: p.pairIndex,
      shapeId: p.shapeId,
      mid: Price.parse('1.085'),
      sequence: Number(maxUint32),
      validUntil: p.validUntil,
    },
  })
  Sequencer.observe(p.sequencer, p.pairIndex, Number(maxUint32))
  await Actions.venue.setHaltedSync(client, {
    venue,
    halted: true,
    account: accounts.owner,
  })
  await Actions.venue.revokeAgentSync(client, {
    venue,
    agent: accounts.agent.address,
    account: accounts.owner,
  })
  // Application-owned durable generations, scoped to this chain, venue and pair.
  // This models a transactional adapter, not a contract or SDK epoch.
  const records = new Map([
    [p.pairIndex, { generation: 1, floor: Number(maxUint32) }],
    [65535, { generation: 1, floor: 40 }], // Unrelated pair must survive.
  ])
  async function maxMerge(generation: number, sequence: number) {
    const record = records.get(p.pairIndex)
    if (!record) throw new Error('missing pair')
    if (record.generation !== generation) throw new Error('stale generation')
    records.set(p.pairIndex, {
      generation: record.generation,
      floor: Math.max(record.floor, sequence),
    })
  }
  function currentFloor() {
    const record = records.get(p.pairIndex)
    if (!record) throw new Error('missing pair')
    return record.floor
  }
  const delayedOldWrite = () => maxMerge(1, Number(maxUint32))
  const reset = mined(
    await Actions.venue.resetHotWordSync(client, {
      venue,
      pairIndex: p.pairIndex,
      account: accounts.owner,
    }),
  )
  expect(reset.previousSeq).toBe(Number(maxUint32))
  expect(reset.pairIndex).toBe(p.pairIndex)
  expect(
    Events.parse(reset.receipt.logs).some(
      (e) => e.eventName === 'HotWordReset',
    ),
  ).toBe(true)
  expect(
    await Info.consumed(client, { venue, pairIndex: p.pairIndex }),
  ).toStrictEqual(consumed)
  expect(() => Sequencer.next(p.sequencer, p.pairIndex)).toThrow()
  // Reusing an unversioned max-merge after reset resurrects exhaustion.
  const unsafe = await Sequencer.seed(client, {
    venue,
    pairs: [p.pairIndex],
    last: [[p.pairIndex, currentFloor()]],
  })
  expect(() => Sequencer.next(unsafe, p.pairIndex)).toThrow(
    Errors.SequenceExhaustedError,
  )
  // Old writers/posts are fenced above. After confirmed reset, atomically CAS
  // generation 1 -> 2 and its floor -> 1; never delete the generation marker.
  const resetIdentity = reset.receipt.transactionHash
  let committedReset: typeof resetIdentity | undefined
  function transition(
    expectedGeneration: number,
    identity: typeof resetIdentity,
  ) {
    if (committedReset === identity) return // Retry must not clear later allocations.
    if (records.get(p.pairIndex)?.generation !== expectedGeneration)
      throw new Error('stale transition')
    records.set(p.pairIndex, { generation: 2, floor: 1 })
    committedReset = identity // Same atomic transaction as generation + floor.
  }
  transition(1, resetIdentity)
  await expect(delayedOldWrite()).rejects.toThrow('stale generation')
  let restarted = await Sequencer.seed(client, {
    venue,
    pairs: [p.pairIndex],
    last: [[p.pairIndex, currentFloor()]],
  })
  const first = Sequencer.next(restarted, p.pairIndex)
  expect(first).toBe(2)
  await maxMerge(2, first) // Crash after durable commit, before broadcast.
  // Restart reads only the current generation, not an old saved snapshot.
  restarted = await Sequencer.seed(client, {
    venue,
    pairs: [p.pairIndex],
    last: [[p.pairIndex, currentFloor()]],
  })
  const sequence = Sequencer.next(restarted, p.pairIndex)
  expect(sequence).toBe(3)
  await maxMerge(2, sequence)
  transition(1, resetIdentity) // Crash/retry after the new generation allocated.
  await maxMerge(2, first) // Late same-generation commit cannot lower 3.
  await expect(delayedOldWrite()).rejects.toThrow('stale generation')
  expect(records.get(p.pairIndex)).toEqual({ generation: 2, floor: 3 })
  expect(records.get(65535)).toEqual({ generation: 1, floor: 40 })
  await Actions.maker.orderSync(client, {
    venue,
    account: accounts.owner,
    order: {
      pairIndex: p.pairIndex,
      shapeId: p.shapeId,
      mid: Price.parse('1.085'),
      sequence,
      validUntil: p.validUntil,
    },
  })
  await Actions.venue.setHaltedSync(client, {
    venue,
    halted: false,
    account: accounts.owner,
  })
  await swapAtQuote(f, {
    venue,
    pairIndex: p.pairIndex,
    tokenIn: f.quote,
    tokenOut: f.base,
    amount: 1_000_000n,
    exactIn: false,
    sponsorId: 0n,
    account: accounts.taker,
  })
  expect(
    (await Info.consumed(client, { venue, pairIndex: p.pairIndex })).asks,
  ).toBe(consumed.asks + 1_000_000n)
})

test('refuses to attribute a real batch with a stale post before reset and its accepted identical post after', async () => {
  const p = await setupPair(f)
  const { client, venue, accounts } = f
  const {
    orders: [before],
  } = await Info.orders(client, { venue, pairs: [p.pairIndex] })
  if (!before) throw new Error('pair has no initial hot word')
  const stale = Actions.maker.order.call({
    venue,
    order: {
      pairIndex: p.pairIndex,
      shapeId: p.shapeId,
      mid: Price.parse('1.09'),
      sequence: before.hot.sequence,
      validUntil: p.validUntil,
    },
  })
  await Actions.venue.setHaltedSync(client, {
    venue,
    halted: true,
    account: accounts.owner,
  })
  const reset = Actions.venue.resetHotWord.call({
    venue,
    pairIndex: p.pairIndex,
  })
  const receipt = await sendTransactionSync(client, {
    account: accounts.owner,
    chain: client.chain,
    calls: [stale, reset, stale].map(({ to, data }) => ({ to, data })),
    throwOnReceiptRevert: true,
  })
  expect(
    Events.venue(receipt.logs, { venue, eventName: 'Posted' }),
  ).toHaveLength(1)
  expect(
    Events.venue(receipt.logs, { venue, eventName: 'HotWordReset' }),
  ).toHaveLength(1)
  expect(() => PostOutcome.fromBatch([stale, stale], receipt.logs)).toThrow(
    Errors.InvalidArgumentError,
  )
  expect(
    (await Info.orders(client, { venue, pairs: [p.pairIndex] })).orders[0]?.hot
      .sequence,
  ).toBe(before.hot.sequence)
  await Actions.venue.setHaltedSync(client, {
    venue,
    halted: false,
    account: accounts.owner,
  })
})

test('a checkpointed restart cancel wins when the previous run post lands first', async () => {
  const p = await setupPair(f)
  const { client, venue, accounts } = f
  let run = await Sequencer.seed(client, {
    venue,
    pairs: [p.pairIndex],
    gap: 16,
  })
  const pendingSequence = Sequencer.next(run, p.pairIndex)
  const checkpoint = Object.fromEntries(run.last)
  await client.request({
    method: 'evm_setAutomine' as never,
    params: [false] as never,
  })
  try {
    const oldPost = await Actions.maker.order(client, {
      venue,
      account: accounts.agent,
      order: {
        pairIndex: p.pairIndex,
        shapeId: p.shapeId,
        mid: Price.one,
        sequence: pendingSequence,
        validUntil: p.validUntil,
      },
    })
    const unsafe = await Sequencer.seed(client, {
      venue,
      pairs: [p.pairIndex],
      gap: 16,
    })
    expect(Sequencer.next(unsafe, p.pairIndex)).toBe(pendingSequence)
    const duplicateCancel = await Actions.maker.cancel(client, {
      venue,
      account: accounts.agent,
      cancel: {
        pairIndex: p.pairIndex,
        mid: Price.one,
        sequence: pendingSequence,
      },
    })
    run = await Sequencer.seed(client, {
      venue,
      pairs: [p.pairIndex],
      gap: 16,
      last: checkpoint,
    })
    // Another crash after allocation, before broadcast: the durable floor still advances.
    const allocated = Sequencer.next(run, p.pairIndex)
    run = await Sequencer.seed(client, {
      venue,
      pairs: [p.pairIndex],
      gap: 16,
      last: Object.fromEntries(run.last),
    })
    const safeSequence = Sequencer.next(run, p.pairIndex)
    expect(safeSequence).toBe(pendingSequence + 2)
    expect(safeSequence).toBeGreaterThan(allocated)
    const safeCancel = await Actions.maker.cancel(client, {
      venue,
      account: accounts.agent,
      cancel: {
        pairIndex: p.pairIndex,
        mid: Price.one,
        sequence: safeSequence,
      },
    })
    await client.request({ method: 'evm_mine' as never, params: [] as never })
    const receipts = await Promise.all(
      [oldPost, duplicateCancel, safeCancel].map((hash) =>
        getTransactionReceipt(client, { hash }),
      ),
    )
    const calls = [
      Actions.maker.order.call({
        venue,
        order: {
          pairIndex: p.pairIndex,
          shapeId: p.shapeId,
          mid: Price.one,
          sequence: pendingSequence,
          validUntil: p.validUntil,
        },
      }),
      Actions.maker.cancel.call({
        venue,
        cancel: {
          pairIndex: p.pairIndex,
          mid: Price.one,
          sequence: pendingSequence,
        },
      }),
      Actions.maker.cancel.call({
        venue,
        cancel: {
          pairIndex: p.pairIndex,
          mid: Price.one,
          sequence: safeSequence,
        },
      }),
    ]
    expect(
      receipts.map((receipt, i) => {
        const call = calls[i]
        if (!call) throw new Error('missing post call')
        return PostOutcome.fromReceipt(call, receipt)
      }),
    ).toMatchObject([
      { status: 'success', allAccepted: true },
      { status: 'success', allAccepted: false },
      { status: 'success', allAccepted: true },
    ])
    const { orders } = await Info.orders(client, {
      venue,
      pairs: [p.pairIndex],
    })
    expect(orders[0]?.hot).toMatchObject({
      sequence: safeSequence,
      sides: 'neither',
    })
  } finally {
    await client.request({
      method: 'evm_setAutomine' as never,
      params: [true] as never,
    })
  }
})
