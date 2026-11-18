// The reads at one block on anvil: Info.orders pins every call to one block and returns it, as Info.meta,
// Info.venueState, Roles.check and Sequencer.seed do; Quote.local with the taker's access folded in equals the
// Settler's fill revert; PostOutcome reads a real receipt by its status.
import {
  createClient,
  custom,
  type Hex,
  numberToHex,
  type TransactionReceipt,
} from 'viem'
import { getBlock, getBlockNumber } from 'viem/actions'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import {
  Actions,
  Errors,
  Fees,
  Info,
  PostOutcome,
  Price,
  Quote,
  Roles,
  Sequencer,
  Shape,
  Snapshot,
  Venue,
} from '../../src/index.js'
import {
  type Fixture,
  type PairSetup,
  setupPair,
  start,
  swap,
} from './fixture.js'

let f: Fixture
let p: PairSetup

beforeAll(async () => {
  f = await start()
  p = await setupPair(f)
})
afterAll(async () => f?.stop())

/** The latest block number, uncached: viem caches it for the client's polling interval. */
const latest = () => getBlockNumber(f.client, { cacheTime: 0 })

/** A client that forwards every request to anvil and records each `eth_call`'s block parameter: nothing is faked. */
function recording() {
  const blocks: unknown[] = []
  const methods: string[] = []
  const client = createClient({
    chain: f.client.chain,
    transport: custom({
      request: ({ method, params }) => {
        methods.push(method)
        if (method === 'eth_call') blocks.push((params as unknown[])[1])
        return f.client.request({ method, params } as never)
      },
    }),
  })
  return { client, blocks, methods }
}

describe('reads at one block', () => {
  test('Info.orders makes every call at one block, the latest unless given, and returns it', async () => {
    const { agent } = f.accounts
    const { client, blocks, methods } = recording()
    const before = await Info.orders(client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    expect(before.blockNumber).toBe(await latest())
    expect(
      methods,
      'the latest block number, then two multicalls',
    ).toStrictEqual(['eth_blockNumber', 'eth_call', 'eth_call'])
    expect(blocks).toStrictEqual([
      numberToHex(before.blockNumber),
      numberToHex(before.blockNumber),
    ])

    // A new shape and an order naming it: a read pinned before them still sees the old pair, whole.
    const wide = Shape.from({
      bids: [{ size: 10_000, spread: 500 }],
      asks: [{ size: 10_000, spread: 500 }],
    })
    await Actions.venue.setShapeSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      shapeId: 9,
      shape: wide,
      account: agent,
    })
    await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        pairIndex: p.pairIndex,
        mid: Price.parse('1.1'),
        shapeId: 9,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        validUntil: p.validUntil,
      },
      account: agent,
    })
    expect(
      await Info.orders(f.client, {
        venue: f.venue,
        pairs: [p.pairIndex],
        blockNumber: before.blockNumber,
      }),
    ).toStrictEqual(before)
    const now = await Info.orders(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
      blockTag: 'latest',
    })
    expect(now.blockNumber).toBe(before.blockNumber + 2n)
    const [order] = now.orders
    assert(order)
    expect([order.hot.shapeId, order.shape.words]).toStrictEqual([
      9,
      wide.words,
    ])
    // The same pair as the snapshot at that block reads it.
    const pair = Snapshot.pair(
      await Snapshot.get(f.client, {
        venue: f.venue,
        pairs: [p.pairIndex],
        blockNumber: now.blockNumber,
      }),
      p.pairIndex,
    )
    expect([order.hot, order.consumed, order.shape]).toStrictEqual([
      pair.hot,
      pair.consumed,
      pair.shape,
    ])
    await expect(
      Info.orders(f.client, { venue: f.venue, pairs: [p.pairIndex + 5] }),
    ).rejects.toThrow(Errors.UnknownPairError)
  })

  test('Info.meta, Info.venueState and Sequencer.seed read one block too', async () => {
    const { client, blocks } = recording()
    const blockNumber = await latest()
    const [markets, state, sequencer] = await Promise.all([
      Info.meta(client, { venue: f.venue }),
      Info.venueState(client, { venue: f.venue }),
      Sequencer.seed(client, { venue: f.venue, pairs: [p.pairIndex] }),
    ])
    expect(new Set(blocks), 'every call at the latest block').toStrictEqual(
      new Set([numberToHex(blockNumber)]),
    )
    expect(markets.map((m) => m.pairIndex)).toStrictEqual([p.pairIndex])
    expect(state.pairCount).toBe(1)
    expect(Sequencer.last(sequencer, p.pairIndex)).toBe(
      Sequencer.last(p.sequencer, p.pairIndex),
    )
  })

  test("a read of one call takes blockTag 'pending'; one that pins a block refuses it", async () => {
    expect(
      await Info.isAgent(f.client, {
        venue: f.venue,
        agent: f.accounts.agent.address,
        blockTag: 'pending',
      }),
    ).toBe(true)
    expect(
      await Info.takerAccess(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        taker: f.accounts.taker.address,
        sponsorId: 0n,
        blockTag: 'pending',
      }),
    ).toBe('allowed')
    await expect(
      Info.venueState(f.client, { venue: f.venue, blockTag: 'pending' }),
    ).rejects.toThrow(Errors.InvalidArgumentError)
  })

  test('Roles.check reads the role at the block it is given', async () => {
    const { owner, other } = f.accounts
    const call = Actions.venue.setHalted.call({ venue: f.venue, halted: true })
    const before = await latest()
    await Actions.venue.approveAgentSync(f.client, {
      venue: f.venue,
      agent: other.address,
      account: owner,
    })
    expect(
      await Roles.check(f.client, {
        call,
        account: other.address,
        blockNumber: before,
      }),
    ).toMatchInlineSnapshot(`
      {
        "ok": false,
        "reason": "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f is neither the owner nor an agent",
        "required": {
          "role": "ownerOrAgent",
        },
      }
    `)
    expect(await Roles.check(f.client, { call, account: other })).toStrictEqual(
      { ok: true },
    )
    await Actions.venue.revokeAgentSync(f.client, {
      venue: f.venue,
      agent: other.address,
      account: owner,
    })
    await expect(
      Roles.check(f.client, { call }),
    ).rejects.toThrowErrorMatchingInlineSnapshot(`
      [MissingAccountError: a role check needs an account, in the parameters or on the client

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})

describe('taker access and the fee cap', () => {
  test("takerAllowed is exactly takerAccess's 'allowed', and fee fields above the cap read 'priorityFeeTooHigh'", async () => {
    const { agent, taker, stranger } = f.accounts
    const read = { venue: f.venue, pairIndex: p.pairIndex, sponsorId: 0n }
    const listed = { ...read, taker: taker.address }
    const unlisted = { ...read, taker: stranger.address }
    expect([
      await Info.takerAccess(f.client, listed),
      await Info.takerAllowed(f.client, listed),
      await Info.takerAccess(f.client, unlisted),
      await Info.takerAllowed(f.client, unlisted),
    ]).toStrictEqual(['allowed', true, 'notListed', false])

    await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
      venue: f.venue,
      cap: Fees.gwei,
      account: agent,
    })
    try {
      const { baseFeePerGas } = await getBlock(f.client)
      assert(baseFeePerGas !== null)
      // The read stands for the taker's transaction: its fee fields are the swap's.
      const paying = (tip: bigint) => ({
        ...listed,
        account: taker.address,
        ...Fees.feeFields(baseFeePerGas, tip),
      })
      expect([
        // Without fee fields an eth_call pays no priority fee, so it never sees the cap.
        await Info.takerAccess(f.client, listed),
        await Info.takerAccess(f.client, paying(Fees.gwei)),
        await Info.takerAccess(f.client, paying(2n * Fees.gwei)),
        await Info.takerAllowed(f.client, paying(2n * Fees.gwei)),
      ]).toStrictEqual(['allowed', 'allowed', 'priorityFeeTooHigh', false])
    } finally {
      await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
        venue: f.venue,
        cap: Venue.noPriorityFeeCap,
        account: agent,
      })
    }
  })
})

describe("Quote.local with the taker's access", () => {
  test("refuses as the Settler's fill does, with the same arguments", async () => {
    const { owner, taker, stranger } = f.accounts
    await Actions.venue.setDeniedSync(f.client, {
      venue: f.venue,
      accounts: [owner.address],
      deny: true,
      account: owner,
    })
    const cases = [
      { name: 'allowed', account: taker, sponsorId: 0n },
      { name: 'not listed', account: stranger, sponsorId: 0n },
      { name: 'denied', account: owner, sponsorId: 0n },
      { name: 'unknown sponsor', account: taker, sponsorId: 42n },
    ]
    const snapshot = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
      access: cases.map(({ account, sponsorId }) => ({
        taker: account.address,
        sponsorIds: [sponsorId],
      })),
    })
    const request = {
      pairIndex: p.pairIndex,
      tokenIn: f.quote,
      tokenOut: f.base,
      amount: 1_000_000n,
      exactIn: true,
      // The venue has no fee cap, which any priority fee passes.
      priorityFee: 0n,
    }
    const priced = Quote.local(snapshot, request)
    assert(priced.ok)
    const outcomes: Record<string, unknown> = {}
    for (const { name, account, sponsorId } of cases) {
      const local = Quote.local(snapshot, {
        ...request,
        takerAccess: Snapshot.access(snapshot, {
          pairIndex: p.pairIndex,
          taker: account.address,
          sponsorId,
        }),
      })
      const onchain = await swap(f, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        tokenIn: f.quote,
        tokenOut: f.base,
        exactIn: true,
        amountIn: priced.amountIn,
        amountOut: priced.amountOut,
        sponsorId,
        account,
      }).then(
        ({ fill }) => ({ ok: true, amountOut: fill?.amountOut }),
        (e: unknown) => {
          const decoded = Errors.decode(e)
          return {
            ok: false,
            errorName: decoded?.errorName,
            args: decoded?.args,
          }
        },
      )
      expect(
        local.ok
          ? { ok: true, amountOut: local.amountOut }
          : { ok: false, ...local.error },
        name,
      ).toStrictEqual(onchain)
      outcomes[name] = local.ok ? 'ok' : local.error.errorName
    }
    expect(outcomes).toMatchInlineSnapshot(`
      {
        "allowed": "ok",
        "denied": "TakerDenied",
        "not listed": "TakerNotAllowed",
        "unknown sponsor": "UnknownSponsor",
      }
    `)
    await Actions.venue.setDeniedSync(f.client, {
      venue: f.venue,
      accounts: [owner.address],
      deny: false,
      account: owner,
    })
  })
})

describe('PostOutcome from a real receipt', () => {
  test('reads a mined receipt as a success, its stale entries skipped', async () => {
    const { agent } = f.accounts
    const order = {
      pairIndex: p.pairIndex,
      mid: Price.parse('1.085'),
      shapeId: 7,
      sequence: Sequencer.next(p.sequencer, p.pairIndex),
      validUntil: p.validUntil,
    }
    const call = Actions.maker.order.call({ venue: f.venue, order })
    const { receipt } = await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order,
      account: agent,
    })
    expect(PostOutcome.fromReceipt(call, receipt)).toStrictEqual({
      status: 'success',
      ...PostOutcome.fromLogs(call, receipt.logs),
    })
    const stale = await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order,
      account: agent,
    })
    const outcome = PostOutcome.fromReceipt(
      call,
      stale.receipt as TransactionReceipt,
    )
    assert(outcome.status === 'success')
    expect(outcome.skipped).toStrictEqual(call.posts)
    expect(
      PostOutcome.fromReceipt(call, {
        ...receipt,
        blockHash: null as unknown as Hex,
        logs: [],
      }),
      'the same receipt while pending',
    ).toStrictEqual({ status: 'pending' })
  })
})
