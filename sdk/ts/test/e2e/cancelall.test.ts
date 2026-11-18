// cancelAll on anvil, each case on a venue of its own: the mids it cancels at (inside a band, at its minMid), the pairs it
// skips and reports, a first order still unmined when it reads, a sequencer whose counter is exhausted, the sequencer it
// reserves in `requests` and the send, and nothing to cancel.
import {
  type Address,
  encodeAbiParameters,
  keccak256,
  maxUint32,
  toHex,
} from 'viem'
import { getTransactionCount, getTransactionReceipt } from 'viem/actions'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import { Actions, Errors, Info, Price, Sequencer } from '../../src/index.js'
import { type Fixture, LADDER, mined, start } from './fixture.js'

let f: Fixture
let validUntil: number

beforeAll(async () => {
  f = await start()
  const block = await f.client.request({
    method: 'eth_getBlockByNumber',
    params: ['latest', false],
  })
  validUntil =
    Number(BigInt((block as { timestamp: `0x${string}` }).timestamp)) + 3_600
})
afterAll(async () => f?.stop())

let venues = 0

/** A venue of `owner`'s with the agent approved and `pairs` pairs, each with shape 7 and nothing posted. */
async function venueWith(pairs: number): Promise<Address> {
  const { owner, agent } = f.accounts
  const { venue } = mined(
    await Actions.factory.createVenueSync(f.client, {
      factory: f.core.factory,
      owner: owner.address,
      salt: keccak256(toHex(`cancelAll ${++venues}`)),
      account: owner,
    }),
  )
  await Actions.venue.approveAgentSync(f.client, {
    venue,
    agent: agent.address,
    account: owner,
  })
  for (let pairIndex = 0; pairIndex < pairs; pairIndex++) {
    await Actions.venue.addPairSync(f.client, {
      venue,
      base: f.base,
      quote: f.quote,
      sizeUnit: 1_000_000n,
      account: owner,
    })
    await Actions.venue.setShapeSync(f.client, {
      venue,
      pairIndex,
      shapeId: 7,
      shape: LADDER,
      account: agent,
    })
  }
  return venue
}

const order = (
  pairIndex: number,
  sequence: number,
  mid = Price.parse('1.085'),
) => ({
  pairIndex,
  mid,
  shapeId: 7,
  sequence,
  validUntil,
})

/** Each pair's stored word, as `[sequence, mid, sides]`. */
async function words(venue: Address, pairs: number[]) {
  const { orders } = await Info.orders(f.client, { venue, pairs })
  return orders.map((o) => [o.hot.sequence, o.hot.mid, o.hot.sides])
}

const automine = (on: boolean) =>
  f.client.request({
    method: 'evm_setAutomine' as never,
    params: [on] as never,
  })

describe('cancelAll', () => {
  test.each([
    [0n, 1n],
    [1n, 0n],
    [2n, 1n],
  ])(
    'rejects impossible midBand (%s, %s) before reserving any sequence',
    async (minMid, maxMid) => {
      const { agent } = f.accounts
      const venue = await venueWith(2)
      await Actions.maker.orderSync(f.client, {
        venue,
        order: order(0, 2),
        account: agent,
      })
      // Corrupt the real venue's packed MidBand mapping (Venue storage slot 8),
      // simulating an ABI-valid response no canonical setMidBand can produce.
      const slot = keccak256(
        encodeAbiParameters([{ type: 'uint16' }, { type: 'uint256' }], [1, 8n]),
      )
      await f.client.request({
        method: 'anvil_setStorageAt' as never,
        params: [
          venue,
          slot,
          toHex(minMid | (maxMid << 96n), { size: 32 }),
        ] as never,
      })
      const nonce = await getTransactionCount(f.client, {
        address: agent.address,
      })
      for (const action of ['requests', 'send', 'sync']) {
        const sequencer = Sequencer.from([
          [0, 2],
          [1, Number(maxUint32) - 1],
        ])
        const parameters = { venue, sequencer, account: agent }
        await expect(
          action === 'requests'
            ? Actions.maker.cancelAll.requests(f.client, parameters)
            : action === 'send'
              ? Actions.maker.cancelAll(f.client, parameters)
              : Actions.maker.cancelAllSync(f.client, parameters),
        ).rejects.toMatchObject({
          name: 'UnexpectedResponseError',
          value: { pairIndex: 1, minMid, maxMid },
        })
        expect(Sequencer.last(sequencer, 0)).toBe(2)
        expect(Sequencer.last(sequencer, 1)).toBe(Number(maxUint32) - 1)
        expect(Sequencer.next(sequencer, 1)).toBe(Number(maxUint32))
      }
      expect(
        await getTransactionCount(f.client, { address: agent.address }),
      ).toBe(nonce)
    },
  )

  test('cancels a first order still unmined when it reads, at the band minMid or Price.one, and that order never quotes', async () => {
    const { owner, agent } = f.accounts
    const venue = await venueWith(2)
    // Pair 1 has a band: an agent's cancel must sit inside it.
    await Actions.venue.setMidBandSync(f.client, {
      venue,
      pairIndex: 1,
      minMid: Price.parse('1.1'),
      maxMid: Price.parse('1.2'),
      account: owner,
    })
    const sequencer = await Sequencer.seed(f.client, { venue, pairs: [0, 1] })
    await automine(false)
    try {
      // The first orders go out but aren't mined: both pairs still store the word addPair wrote (mid 0, sequence 1).
      const posted = await Actions.maker.bulkOrders(f.client, {
        venue,
        orders: [
          order(0, Sequencer.next(sequencer, 0)),
          order(1, Sequencer.next(sequencer, 1), Price.parse('1.15')),
        ],
        account: agent,
      })
      expect(await words(venue, [0, 1])).toStrictEqual([
        [1, 0n, 'both'],
        [1, 0n, 'both'],
      ])
      // The sequencer has handed out 2 for each, so the read cancels both above it.
      const requests = await Actions.maker.cancelAll.requests(f.client, {
        venue,
        sequencer,
      })
      expect(requests).toStrictEqual({
        cancels: [
          { pairIndex: 0, sequence: 3, mid: Price.one },
          { pairIndex: 1, sequence: 3, mid: Price.parse('1.1') },
        ],
        skipped: [],
      })
      const cancelled = await Actions.maker.cancelAll(f.client, {
        venue,
        sequencer,
        account: agent,
      })
      await f.client.request({
        method: 'evm_mine' as never,
        params: [] as never,
      })
      for (const hash of [posted, cancelled])
        expect((await getTransactionReceipt(f.client, { hash })).status).toBe(
          'success',
        )
    } finally {
      await automine(true)
    }
    // The orders landed first and the cancels replaced them in the same block: neither pair quotes.
    expect(await words(venue, [0, 1])).toStrictEqual([
      [4, Price.one, 'neither'],
      [4, Price.parse('1.1'), 'neither'],
    ])
    expect(Sequencer.last(sequencer, 0)).toBe(4)
  })

  test('moves a stored mid below the band up to its minMid', async () => {
    const { owner, agent } = f.accounts
    const venue = await venueWith(1)
    const sequencer = await Sequencer.seed(f.client, { venue, pairs: [0] })
    await Actions.maker.orderSync(f.client, {
      venue,
      order: order(0, Sequencer.next(sequencer, 0)),
      account: agent,
    })
    // The band comes after the post: the stored 1.085 is below it.
    await Actions.venue.setMidBandSync(f.client, {
      venue,
      pairIndex: 0,
      minMid: Price.parse('1.1'),
      maxMid: Price.parse('1.2'),
      account: owner,
    })
    const { outcome, skipped } = mined(
      await Actions.maker.cancelAllSync(f.client, {
        venue,
        sequencer,
        account: agent,
      }),
    )
    expect([outcome.allAccepted, skipped]).toStrictEqual([true, []])
    expect(await words(venue, [0])).toStrictEqual([
      [3, Price.parse('1.1'), 'neither'],
    ])
  })

  test('skips and reports a never-posted pair and an exhausted one, and cancels the rest', async () => {
    const { agent } = f.accounts
    const venue = await venueWith(3)
    const sequencer = await Sequencer.seed(f.client, {
      venue,
      pairs: [0, 1, 2],
    })
    // Pair 0 is posted, pair 1 never is, pair 2's word is at the last sequence.
    await Actions.maker.bulkOrdersSync(f.client, {
      venue,
      orders: [
        order(0, Sequencer.next(sequencer, 0)),
        order(2, Number(maxUint32)),
      ],
      account: agent,
    })
    const requests = await Actions.maker.cancelAll.requests(f.client, {
      venue,
      sequencer,
    })
    expect(requests.skipped).toStrictEqual([
      { pairIndex: 1, reason: 'neverPosted' },
      { pairIndex: 2, reason: 'sequenceExhausted' },
    ])
    const { outcome, skipped } = mined(
      await Actions.maker.cancelAllSync(f.client, {
        venue,
        sequencer,
        account: agent,
      }),
    )
    // Every cancel sent was stored, which doesn't mean every pair is cancelled: pair 2 still quotes.
    expect(outcome.allAccepted).toBe(true)
    expect(outcome.accepted.map((e) => e.pairIndex)).toStrictEqual([0])
    expect(skipped).toStrictEqual(requests.skipped)
    expect(await words(venue, [0, 1, 2])).toStrictEqual([
      [4, Price.parse('1.085'), 'neither'],
      [1, 0n, 'both'],
      [Number(maxUint32), Price.parse('1.085'), 'both'],
    ])
  })

  test("falls back to the stored sequence plus one when only the sequencer's counter is exhausted", async () => {
    const { agent } = f.accounts
    const venue = await venueWith(1)
    await Actions.maker.orderSync(f.client, {
      venue,
      order: order(0, 2),
      account: agent,
    })
    const exhausted = Sequencer.from([[0, Number(maxUint32)]])
    expect(
      await Actions.maker.cancelAll.requests(f.client, {
        venue,
        sequencer: exhausted,
      }),
    ).toStrictEqual({
      cancels: [{ pairIndex: 0, sequence: 3, mid: Price.parse('1.085') }],
      skipped: [],
    })
    const { outcome } = mined(
      await Actions.maker.cancelAllSync(f.client, {
        venue,
        sequencer: exhausted,
        account: agent,
      }),
    )
    expect(outcome.allAccepted).toBe(true)
    expect(await words(venue, [0])).toStrictEqual([
      [3, Price.parse('1.085'), 'neither'],
    ])
    expect(Sequencer.last(exhausted, 0)).toBe(Number(maxUint32))
  })

  test('manual cancellation reserves before a requote, so the requote is accepted after the cancel', async () => {
    const { agent } = f.accounts
    const venue = await venueWith(2)
    await Actions.maker.bulkOrdersSync(f.client, {
      venue,
      orders: [order(0, 2), order(1, 5)],
      account: agent,
    })
    const sequencer = Sequencer.from([[0, 10]])
    const { cancels } = await Actions.maker.cancelAll.requests(f.client, {
      venue,
      sequencer,
    })
    const next = Sequencer.next(sequencer, 0)
    const { outcome: cancelled } = mined(
      await Actions.maker.bulkCancelSync(f.client, {
        venue,
        cancels,
        account: agent,
      }),
    )
    expect(cancelled.allAccepted).toBe(true)
    const { outcome } = mined(
      await Actions.maker.orderSync(f.client, {
        venue,
        order: order(0, next),
        account: agent,
      }),
    )
    expect(
      outcome.allAccepted,
      'the requote must not reuse the manual cancel sequence',
    ).toBe(true)
    expect(next).toBe(12)
    expect(Sequencer.next(sequencer, 1)).toBe(7)
  })

  test('concurrent discovery reserves above allocations made while RPC reads are pending', async () => {
    const { agent } = f.accounts
    const venue = await venueWith(2)
    await Actions.maker.bulkOrdersSync(f.client, {
      venue,
      orders: [order(0, 2), order(1, 2)],
      account: agent,
    })
    const sequencer = Sequencer.from([
      [0, 10],
      [1, 20],
    ])
    const first = Actions.maker.cancelAll.requests(f.client, {
      venue,
      sequencer,
    })
    const second = Actions.maker.cancelAll.requests(f.client, {
      venue,
      sequencer,
    })
    expect(Sequencer.next(sequencer, 0)).toBe(11)
    expect(Sequencer.next(sequencer, 1)).toBe(21)
    const results = await Promise.all([first, second])
    for (const [pairIndex, sequences] of [
      [0, [12, 13]],
      [1, [22, 23]],
    ] as const) {
      expect(
        results
          .map(({ cancels }) => cancels[pairIndex]?.sequence)
          .sort((a, b) => (a ?? 0) - (b ?? 0)),
      ).toStrictEqual(sequences)
      expect(Sequencer.next(sequencer, pairIndex)).toBe(sequences[1] + 1)
    }
  })

  test.each([
    { blockNumber: 0n },
    { blockTag: 'earliest' as const },
    { blockTag: 'safe' as const },
    { blockTag: 'finalized' as const },
    { blockTag: 'pending' as const },
    { stateOverride: [] },
    { blockOverrides: {} },
  ])(
    'refuses hypothetical or historical sequencer reservations: %s',
    async (options) => {
      const venue = await venueWith(1)
      await Actions.maker.orderSync(f.client, {
        venue,
        order: order(0, 2),
        account: f.accounts.agent,
      })
      const sequencer = Sequencer.from([[0, 10]])
      const before = [...sequencer.last]
      await expect(
        Actions.maker.cancelAll.requests(f.client, {
          venue,
          sequencer,
          ...options,
        }),
      ).rejects.toBeInstanceOf(Errors.InvalidArgumentError)
      expect([...sequencer.last]).toStrictEqual(before)
    },
  )

  test('historical discovery stays read-only without a sequencer, while explicit latest reserves', async () => {
    const venue = await venueWith(1)
    await Actions.maker.orderSync(f.client, {
      venue,
      order: order(0, 2),
      account: f.accounts.agent,
    })
    const block = await f.client.request({
      method: 'eth_getBlockByNumber',
      params: ['latest', false],
    })
    assert(block?.number !== null && block?.number !== undefined)
    const blockNumber = BigInt(block.number)
    await Actions.maker.orderSync(f.client, {
      venue,
      order: order(0, 5),
      account: f.accounts.agent,
    })
    const historical = await Actions.maker.cancelAll.requests(f.client, {
      venue,
      blockNumber,
    })
    expect(historical.cancels[0]?.sequence).toBe(3)
    const sequencer = Sequencer.from([])
    const latest = await Actions.maker.cancelAll.requests(f.client, {
      venue,
      sequencer,
      blockTag: 'latest',
    })
    expect(latest.cancels[0]?.sequence).toBe(6)
    expect(Sequencer.next(sequencer, 0)).toBe(7)
  })

  test('failed discovery leaves every shared sequencer floor unchanged', async () => {
    const venue = await venueWith(1)
    const sequencer = Sequencer.from([
      [0, 10],
      [1, 20],
    ])
    const before = [...sequencer.last]
    await expect(
      Actions.maker.cancelAll.requests(f.client, {
        venue,
        sequencer,
        multicallAddress: f.accounts.stranger.address,
      }),
    ).rejects.toThrow()
    expect([...sequencer.last]).toStrictEqual(before)
  })

  test("the send records a cancel for a pair the sequencer doesn't track, so that pair's first post outranks it", async () => {
    const { agent } = f.accounts
    const venue = await venueWith(2)
    await Actions.maker.bulkOrdersSync(f.client, {
      venue,
      orders: [order(0, 2), order(1, 5)],
      account: agent,
    })
    // The sequencer was made before pair 1 quoted: it tracks only pair 0.
    const sequencer = Sequencer.from([[0, 2]])
    const { cancels } = await Actions.maker.cancelAll.requests(f.client, {
      venue,
      sequencer,
    })
    expect(cancels.map((c) => [c.pairIndex, c.sequence])).toStrictEqual([
      [0, 3],
      [1, 6],
    ])
    expect(Sequencer.last(sequencer, 1), 'requests reserves the new pair').toBe(
      6,
    )
    await Actions.maker.cancelAllSync(f.client, {
      venue,
      sequencer,
      account: agent,
    })
    expect(
      [Sequencer.last(sequencer, 0), Sequencer.last(sequencer, 1)],
      'both cancels recorded',
    ).toStrictEqual([4, 7])
    const { outcome } = mined(
      await Actions.maker.orderSync(f.client, {
        venue,
        order: order(1, Sequencer.next(sequencer, 1)),
        account: agent,
      }),
    )
    expect(outcome.allAccepted, "pair 1's first post outranks its cancel").toBe(
      true,
    )
  })

  test('with nothing to cancel, sends nothing and throws EmptyBatchError naming the skipped pairs', async () => {
    const { agent } = f.accounts
    const venue = await venueWith(2)
    expect(
      await Actions.maker.cancelAll.requests(f.client, { venue }),
    ).toStrictEqual({
      cancels: [],
      skipped: [
        { pairIndex: 0, reason: 'neverPosted' },
        { pairIndex: 1, reason: 'neverPosted' },
      ],
    })
    const nonce = await getTransactionCount(f.client, {
      address: agent.address,
    })
    for (const send of [Actions.maker.cancelAll, Actions.maker.cancelAllSync]) {
      const error = await send(f.client, { venue, account: agent }).catch(
        (e: unknown) => e,
      )
      assert(error instanceof Errors.EmptyBatchError)
      expect([error.shortMessage, error.metaMessages]).toStrictEqual([
        'no live pair has a quote cancelAll can cancel',
        ['pair 0: neverPosted', 'pair 1: neverPosted'],
      ])
    }
    expect(
      await getTransactionCount(f.client, { address: agent.address }),
      'nothing was sent',
    ).toBe(nonce)
  })
})
