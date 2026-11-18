// Sequencer and PostOutcome at parity with sdk/rust/tests/sequence.rs.
import {
  DecodeLogDataMismatch,
  DecodeLogTopicsMismatch,
  encodeAbiParameters,
  encodeEventTopics,
  getAddress,
  type Log,
} from 'viem'
import { describe, expect, test } from 'vitest'
import {
  Abis,
  Actions,
  Errors,
  HotWord,
  Post,
  PostOutcome,
  Price,
  Sequencer,
} from '../src/index.js'

const VENUE = getAddress('0x1111111111111111111111111111111111111111')

describe('Sequencer', () => {
  test('out-of-order checkpoint commits need per-pair maxima before broadcast', async () => {
    const s = Sequencer.from([
      [0, 7],
      [1, 20],
    ])
    Sequencer.next(s, 0) // Task A allocates 8 and starts a slow write.
    const older = new Map(s.last)
    Sequencer.next(s, 0) // Task B allocates 9.
    Sequencer.observe(s, 2, 30)
    const newer = new Map(s.last)

    // Both tasks await their own commit before broadcast, but B commits first.
    let replaced = new Map(newer)
    expect(Sequencer.next(Sequencer.from(replaced), 0)).toBe(10)
    replaced = new Map(older) // A's late whole-map replacement loses B's floor.
    expect(Sequencer.next(Sequencer.from(replaced), 0)).toBe(9)
    expect(replaced.has(2)).toBe(false)

    // Model the adapter contract in the README: the body is one atomic commit.
    const durable = new Map<number, number>([[3, 40]])
    async function maxMerge(pairIndex: number, sequence: number) {
      durable.set(pairIndex, Math.max(durable.get(pairIndex) ?? 0, sequence))
    }
    const broadcasts: (number | undefined)[] = []
    for (const snapshot of [newer, older]) {
      for (const [pair, sequence] of snapshot) await maxMerge(pair, sequence)
      broadcasts.push(snapshot.get(0)) // Only after durable commit.
    }
    expect(broadcasts).toEqual([9, 8])
    expect(Sequencer.next(Sequencer.from(durable), 0)).toBe(10)
    expect([...durable]).toEqual([
      [3, 40],
      [0, 9],
      [1, 20],
      [2, 30],
    ])
  })

  test('a pair it was not made with joins it through observe, at its stored sequence', () => {
    // One state per venue, kept for the process's life: the venue adds pair 2 after it was made.
    const s = Sequencer.from([[0, 4]])
    expect(
      () => Sequencer.next(s, 2),
      'next has no floor to allocate above',
    ).toThrow(Errors.UnseededPairError)
    expect(Sequencer.last(s, 2), 'a refused next records nothing').toBe(
      undefined,
    )
    Sequencer.observe(s, 2, 1)
    expect(Sequencer.last(s, 2)).toBe(1)
    expect(Sequencer.next(s, 2), 'above the stored 1 a new pair carries').toBe(
      2,
    )
    Sequencer.observe(s, 2, 1)
    expect(Sequencer.next(s, 2), 'observing it again never lowers it').toBe(3)
    expect(
      Object.fromEntries(s.last),
      'the same state, both pairs',
    ).toStrictEqual({ 0: 4, 2: 3 })
    // The bounds hold for a new pair as for a known one.
    expect(() => Sequencer.observe(s, 70_000, 1)).toThrow(
      Errors.InvalidArgumentError,
    )
    expect(() => Sequencer.observe(s, 3, -1)).toThrow(
      Errors.InvalidArgumentError,
    )
    expect(Sequencer.last(s, 3), 'a refused observe records nothing').toBe(
      undefined,
    )
  })

  test('allocates from memory, never rereads, and only raises its floor', () => {
    const s = Sequencer.from([
      [0, 1],
      [5, 41],
    ])
    expect(Sequencer.next(s, 0)).toBe(2)
    expect(Sequencer.next(s, 0)).toBe(3)
    expect(Sequencer.last(s, 0)).toBe(3)
    Sequencer.observe(s, 0, 2)
    expect(Sequencer.last(s, 0), 'observe never lowers').toBe(3)
    Sequencer.observe(s, 0, 10)
    expect(Sequencer.next(s, 0)).toBe(11)
    expect(Sequencer.next(s, 5)).toBe(42)
    expect(Sequencer.last(s, 9)).toBe(undefined)
    expect(() => Sequencer.next(s, 9)).toThrow(Errors.UnseededPairError)
    expect(Sequencer.next(Sequencer.from({ 3: 7 }), 3)).toBe(8)
    expect(Object.fromEntries(s.last), 'a checkpoint').toStrictEqual({
      0: 11,
      5: 42,
    })
    expect(
      Sequencer.next(Sequencer.from(s.last), 0),
      'restored from a checkpoint',
    ).toBe(12)
  })

  test('shares one counter between everything that holds the state', () => {
    const s = Sequencer.from([[0, 1]])
    const holders = [s, { ...s }, s]
    expect(holders.map((h) => Sequencer.next(h, 0))).toStrictEqual([2, 3, 4])
    expect(Sequencer.last(s, 0)).toBe(4)
  })

  test('refuses to wrap, and refuses what it cannot count', () => {
    const s = Sequencer.from([[0, 2 ** 32 - 2]])
    expect(Sequencer.next(s, 0)).toBe(2 ** 32 - 1)
    expect(() => Sequencer.next(s, 0)).toThrowErrorMatchingInlineSnapshot(`
      [SequenceExhaustedError: pair 0 has exhausted its sequence numbers

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Sequencer.from([[0, 2 ** 32]]),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: sequence must be an integer in [0, 2^32 - 1], got 4294967296

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Sequencer.from([
        [0, 1],
        [0, 5],
      ]),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: pair 0 is given twice

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Sequencer.next({ last: {} } as never, 0),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: not a sequencer: make one with Sequencer.from or Sequencer.seed

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Sequencer.observe(Sequencer.from([[0, 1]]), 0, -1),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: sequence must be an integer in [0, 2^32 - 1], got -1

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})

function posted(
  address: `0x${string}`,
  pairIndex: number,
  word: `0x${string}`,
): Log {
  return {
    address,
    topics: encodeEventTopics({
      abi: Abis.venueAbi,
      eventName: 'Posted',
      args: { pairIndex },
    }) as Log['topics'],
    data: encodeAbiParameters([{ type: 'bytes32' }], [word]),
    blockHash: null,
    blockNumber: null,
    logIndex: null,
    transactionHash: null,
    transactionIndex: null,
    removed: false,
  } as unknown as Log
}

function reset(address: `0x${string}`, pairIndex: number): Log {
  return {
    address,
    topics: encodeEventTopics({
      abi: Abis.venueAbi,
      eventName: 'HotWordReset',
      args: { pairIndex },
    }) as Log['topics'],
    data: encodeAbiParameters([{ type: 'uint32' }], [6]),
    blockHash: null,
    blockNumber: null,
    logIndex: null,
    transactionHash: null,
    transactionIndex: null,
    removed: false,
  } as unknown as Log
}

describe('PostOutcome', () => {
  const order = (
    pairIndex: number,
    sequence: number,
    refill: HotWord.Sides = 'neither',
  ) => ({
    pairIndex,
    mid: Price.one,
    shapeId: 0,
    sequence,
    validUntil: 1,
    refill,
  })
  // The venue emits each accepted word with its refill bits cleared.
  const stored = (o: Post.OrderRequest) =>
    HotWord.withoutRefill(Post.order(o).word)
  const ref = (o: Post.OrderRequest) => ({
    pairIndex: o.pairIndex,
    sequence: o.sequence,
    word: stored(o),
  })

  const entrypoints = {
    fromLogs: (call: PostOutcome.PostCall, logs: Log[]) =>
      PostOutcome.fromLogs(call, logs),
    fromBatch: (call: PostOutcome.PostCall, logs: Log[]) =>
      PostOutcome.fromBatch([call], logs)[0],
    fromReceipt: (call: PostOutcome.PostCall, logs: Log[]) =>
      PostOutcome.fromReceipt(call, {
        status: 'success',
        blockNumber: 1n,
        logs,
      }),
    fromBatchReceipt: (call: PostOutcome.PostCall, logs: Log[]) => {
      const result = PostOutcome.fromBatchReceipt([call], {
        status: 'success',
        blockNumber: 1n,
        logs,
      })
      return result.status === 'success' ? result.outcomes[0] : result
    },
  }
  for (const [name, read] of Object.entries(entrypoints)) {
    for (const casing of ['uppercase', 'mixed'] as const) {
      test(`${name} accepts ${casing} selectors without relaxing malformed-log rejection`, () => {
        const o = order(0, 6)
        const call = Actions.maker.order.call({ venue: VENUE, order: o })
        const withCasing = (log: Log): Log => ({
          ...log,
          topics: log.topics.map((topic, index) =>
            index === 0
              ? (`0x${topic
                  .slice(2)
                  .split('')
                  .map((char, i) =>
                    casing === 'uppercase' || i % 2 === 0
                      ? char.toUpperCase()
                      : char,
                  )
                  .join('')}` as `0x${string}`)
              : topic,
          ) as Log['topics'],
        })
        const valid = withCasing(posted(VENUE, 0, stored(o)))
        const unrelatedReset = withCasing(reset(VENUE, 1))
        expect(read(call, [valid, unrelatedReset])).toMatchObject({
          allAccepted: true,
          accepted: [ref(o)],
          skipped: [],
        })
        expect(() => read(call, [valid, withCasing(reset(VENUE, 0))])).toThrow(
          Errors.InvalidArgumentError,
        )
        for (const original of [valid, unrelatedReset]) {
          expect(() => read(call, [{ ...original, data: '0x' }])).toThrow(
            DecodeLogDataMismatch,
          )
          expect(() =>
            read(call, [
              {
                ...original,
                topics: [original.topics[0] as `0x${string}`],
              },
            ]),
          ).toThrow(DecodeLogTopicsMismatch)
        }
        // Normalization must not mutate the caller's raw log.
        expect(valid).toStrictEqual(withCasing(posted(VENUE, 0, stored(o))))
      })
    }
    for (const eventName of ['Posted', 'HotWordReset'] as const) {
      for (const corruption of ['data', 'topics'] as const) {
        test(`${name} rejects malformed ${eventName} ${corruption} only at a matching venue`, () => {
          const o = order(0, 6)
          const call = Actions.maker.order.call({ venue: VENUE, order: o })
          const valid = posted(VENUE, 0, stored(o))
          const original = eventName === 'Posted' ? valid : reset(VENUE, 0)
          const malformed: Log =
            corruption === 'data'
              ? { ...original, data: '0x' }
              : { ...original, topics: [original.topics[0] as `0x${string}`] }
          expect(() => read(call, [valid, malformed])).toThrow(
            corruption === 'data'
              ? DecodeLogDataMismatch
              : DecodeLogTopicsMismatch,
          )
          expect(
            read(call, [
              {
                ...malformed,
                address: '0x2222222222222222222222222222222222222222',
              },
              { ...malformed, topics: [`0x${'ff'.repeat(32)}`] },
              { ...malformed, topics: [] },
              valid,
            ]),
          ).toMatchObject({
            allAccepted: true,
            accepted: [ref(o)],
            skipped: [],
          })
          expect(read(call, [])).toMatchObject({
            allAccepted: false,
            accepted: [],
            skipped: [ref(o)],
          })
          expect(() => read(call, [valid, reset(VENUE, 0)])).toThrow(
            Errors.InvalidArgumentError,
          )
          for (const receipt of [
            { status: 'pending' as const, blockNumber: 1n },
            { status: 'success' as const, blockNumber: null },
            { status: 'reverted' as const, blockNumber: 1n },
          ]) {
            const expected =
              receipt.status === 'reverted' ? 'reverted' : 'pending'
            expect(
              PostOutcome.fromReceipt(call, { ...receipt, logs: [malformed] }),
            ).toStrictEqual({ status: expected })
            expect(
              PostOutcome.fromBatchReceipt([call], {
                ...receipt,
                logs: [malformed],
              }),
            ).toStrictEqual({ status: expected })
          }
        })
      }
    }
  }

  test("splits a batch's entries into accepted and skipped by the venue's Posted events", () => {
    const orders = [0, 1, 2].map((pairIndex) =>
      order(pairIndex, 10 + pairIndex, 'both'),
    )
    const call = Actions.maker.bulkOrders.call({ venue: VENUE, orders })
    const [a, b, c] = orders as [
      Post.OrderRequest,
      Post.OrderRequest,
      Post.OrderRequest,
    ]
    const logs = [
      posted(VENUE, 0, stored(a)),
      // Another contract's Posted and a stale sequence's word don't count.
      posted('0x2222222222222222222222222222222222222222', 1, stored(b)),
      posted(VENUE, 1, stored(order(1, 10, 'both'))),
      posted(VENUE, 2, stored(c)),
    ]
    const outcome = PostOutcome.fromLogs(call, logs)
    expect(outcome.accepted).toStrictEqual([ref(a), ref(c)])
    expect(outcome.skipped).toStrictEqual([ref(b)])
    expect(outcome.allAccepted).toBe(false)
    expect(
      PostOutcome.fromLogs(call, []).skipped.length,
      'a reverted transaction has no logs',
    ).toBe(3)
    expect(() =>
      PostOutcome.fromLogs(
        Actions.venue.setHalted.call({ venue: VENUE, halted: true }),
        logs,
      ),
    ).toThrow(Errors.InvalidArgumentError)
  })

  test("matches the stored word, so a cancel at an order's sequence is not acknowledged by the order", () => {
    // A Tempo batch posting the pair twice at one sequence: the venue stores the first entry and skips the second.
    const o = order(0, 6)
    const first = Actions.maker.order.call({ venue: VENUE, order: o })
    const cancel = Actions.maker.cancel.call({
      venue: VENUE,
      cancel: { pairIndex: 0, sequence: 6, mid: o.mid },
    })
    const logs = [posted(VENUE, 0, stored(o))]
    expect(PostOutcome.fromLogs(first, logs).allAccepted).toBeTruthy()
    expect(PostOutcome.fromLogs(cancel, logs).skipped).toStrictEqual(
      cancel.posts,
    )
    const [orderOutcome, cancelOutcome] = PostOutcome.fromBatch(
      [first, cancel],
      logs,
    )
    expect(orderOutcome?.accepted).toStrictEqual(first.posts)
    expect(cancelOutcome?.skipped).toStrictEqual(cancel.posts)
  })

  test('claims each event once, so an identical repeat in one batch reads skipped', () => {
    const o = order(0, 6)
    const call = Actions.maker.order.call({ venue: VENUE, order: o })
    const outcomes = PostOutcome.fromBatch(
      [call, call],
      [posted(VENUE, 0, stored(o))],
    )
    expect(
      outcomes.map((x) => [x.accepted.length, x.skipped.length]),
    ).toStrictEqual([
      [1, 0],
      [0, 1],
    ])
    // A refill is emitted without its bits: the same word without a refill matches it too, once.
    const refill = Actions.maker.order.call({
      venue: VENUE,
      order: order(1, 7, 'asks'),
    })
    const plain = Actions.maker.order.call({ venue: VENUE, order: order(1, 7) })
    const logs = [posted(VENUE, 1, stored(order(1, 7)))]
    expect(
      PostOutcome.fromBatch([refill, plain], logs).map((x) => x.allAccepted),
    ).toStrictEqual([true, false])
    expect(() =>
      PostOutcome.fromBatch(
        [call, Actions.venue.setHalted.call({ venue: VENUE, halted: true })],
        logs,
      ),
    ).toThrow(Errors.InvalidArgumentError)
  })

  test('refuses same-pair reset receipts but still attributes an unrelated reset', () => {
    const o = order(0, 6)
    const call = Actions.maker.order.call({ venue: VENUE, order: o })
    const logs = [reset(VENUE, 0), posted(VENUE, 0, stored(o))]
    expect(() => PostOutcome.fromBatch([call, call], logs)).toThrow(
      Errors.InvalidArgumentError,
    )
    expect(
      PostOutcome.fromBatch(
        [call, call],
        [reset(VENUE, 1), posted(VENUE, 0, stored(o))],
      ).map((outcome) => outcome.allAccepted),
    ).toStrictEqual([true, false])
    expect(
      PostOutcome.fromBatch(
        [call, call],
        [
          reset('0x2222222222222222222222222222222222222222', 0),
          posted(VENUE, 0, stored(o)),
        ],
      ).map((outcome) => outcome.allAccepted),
    ).toStrictEqual([true, false])
  })

  test('reads a receipt by its status: pending and reverted are not every entry skipped', () => {
    const o = order(0, 6)
    const call = Actions.maker.order.call({ venue: VENUE, order: o })
    const cancel = Actions.maker.cancel.call({
      venue: VENUE,
      cancel: { pairIndex: 0, sequence: 6, mid: o.mid },
    })
    const logs = [posted(VENUE, 0, stored(o))]
    const mined = {
      blockNumber: 7n,
      blockHash: `0x${'ab'.repeat(32)}` as const,
    }
    expect({
      success: PostOutcome.fromReceipt(call, {
        status: 'success',
        logs,
        ...mined,
      }),
      'success, stale': PostOutcome.fromReceipt(cancel, {
        status: 'success',
        logs,
        ...mined,
      }),
      reverted: PostOutcome.fromReceipt(call, {
        status: 'reverted',
        logs: [],
        ...mined,
      }),
      'pending, no logs yet': PostOutcome.fromReceipt(call, {
        status: 'success',
        logs: [],
        blockNumber: null,
        blockHash: null,
      }),
      "pending, viem's status": PostOutcome.fromReceipt(call, {
        status: 'pending',
        logs,
        ...mined,
      }),
      'pending, by its hash': PostOutcome.fromReceipt(call, {
        status: 'success',
        logs: [],
        blockNumber: 7n,
        blockHash: null,
      }),
    }).toMatchInlineSnapshot(`
      {
        "pending, by its hash": {
          "status": "pending",
        },
        "pending, no logs yet": {
          "status": "pending",
        },
        "pending, viem's status": {
          "status": "pending",
        },
        "reverted": {
          "status": "reverted",
        },
        "success": {
          "accepted": [
            {
              "pairIndex": 0,
              "sequence": 6,
              "word": "0x00000000000600000000010003e803e800000000000000000de0b6b3a7640000",
            },
          ],
          "allAccepted": true,
          "skipped": [],
          "status": "success",
        },
        "success, stale": {
          "accepted": [],
          "allAccepted": false,
          "skipped": [
            {
              "pairIndex": 0,
              "sequence": 6,
              "word": "0x000300000006000000000000000003e800000000000000000de0b6b3a7640000",
            },
          ],
          "status": "success",
        },
      }
    `)
    expect(
      PostOutcome.fromBatchReceipt([call, cancel], {
        status: 'success',
        logs,
        ...mined,
      }),
    ).toStrictEqual({
      status: 'success',
      outcomes: PostOutcome.fromBatch([call, cancel], logs),
    })
    expect(() =>
      PostOutcome.fromReceipt(
        Actions.venue.setHalted.call({ venue: VENUE, halted: true }),
        { status: 'success', logs: [], blockNumber: null },
      ),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: the call is not an order or cancel batch

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      PostOutcome.fromReceipt(call, logs as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: receipt must be a transaction receipt: { status: 'success' | 'reverted' | 'pending', logs, blockNumber }

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})
