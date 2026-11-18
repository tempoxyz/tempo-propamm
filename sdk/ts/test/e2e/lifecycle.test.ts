// The Rust onchain test's flows through the TypeScript API, on anvil: pair setup, shapes, orders from one Sequencer,
// PostOutcome (a Tempo batch of posts included), refills and shape switches, cancels and cancelAll; sponsors,
// deny precedence, resets, two-step ownership and admin handovers, mid bands, fill logs; and every
// write's Sync twin, whose changed result must match its event as `extractEvent` reads it, through
// `propAmmActions()`. Fills go through the core's Settler in a test-only batch (`swap` in fixture.ts).
import {
  createClient,
  http,
  keccak256,
  type Log,
  maxUint32,
  toHex,
  zeroAddress,
  zeroHash,
} from 'viem'
import {
  estimateContractGas,
  getBlockNumber,
  sendTransactionSync,
  simulateContract,
  waitForTransactionReceipt,
  writeContractSync,
} from 'viem/actions'
import { Actions as TempoActions } from 'viem/tempo'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import {
  AccessMode,
  Actions,
  Errors,
  Events,
  Fees,
  Info,
  Post,
  PostOutcome,
  Price,
  propAmmActions,
  Quote,
  Sequencer,
  Shape,
  Snapshot,
  Venue,
} from '../../src/index.js'
import {
  type Fixture,
  mined,
  type PairSetup,
  setupPair,
  start,
  swapAtQuote,
} from './fixture.js'

let f: Fixture
let p: PairSetup

beforeAll(async () => {
  f = await start()
  p = await setupPair(f)
})
afterAll(async () => f?.stop())

describe('venue provenance', () => {
  test('recognizes a factory-created venue', async () => {
    expect(
      await Info.isVenue(f.client, {
        factory: f.core.factory,
        venue: f.venue,
      }),
    ).toBe(true)
  })

  test('rejects a non-venue contract', async () => {
    expect(
      await Info.isVenue(f.client, {
        factory: f.core.factory,
        venue: f.core.settler,
      }),
    ).toBe(false)
  })
})

const reverts = (name: string) => (e: unknown) => {
  const d = Errors.decode(e)
  expect(
    d?.errorName,
    `expected ${name}, got ${d?.errorName ?? String(e)}`,
  ).toBe(name)
  return true
}

async function swap(
  amount: bigint,
  exactIn: boolean,
  buyBase: boolean,
  account = f.accounts.taker,
  sponsorId = 0n,
) {
  const [tokenIn, tokenOut] = buyBase ? [f.quote, f.base] : [f.base, f.quote]
  return swapAtQuote(f, {
    venue: f.venue,
    pairIndex: p.pairIndex,
    tokenIn,
    tokenOut,
    exactIn,
    amount,
    sponsorId,
    account,
  })
}

/** Posts p's ladder at 1.085 with both sides refilled, as the suite's later tests expect it. */
async function requote() {
  await Actions.maker.orderSync(f.client, {
    venue: f.venue,
    order: {
      pairIndex: p.pairIndex,
      mid: Price.parse('1.085'),
      shapeId: 7,
      sequence: Sequencer.next(p.sequencer, p.pairIndex),
      validUntil: p.validUntil,
      refill: 'both',
    },
    account: f.accounts.agent,
  })
}

describe('maker lifecycle', () => {
  test('posts from one sequencer and reports accepted and stale entries', async () => {
    const { agent, owner } = f.accounts
    const {
      orders: [order],
    } = await Info.orders(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    assert(order)
    expect(
      order.hot.sequence,
      'a fresh pair stores 1, so its first post is 2',
    ).toBe(2)
    expect(order.shape.words).toStrictEqual(p.shape.words)
    expect((await Info.meta(f.client, { venue: f.venue })).length).toBe(1)

    const sequence = Sequencer.next(p.sequencer, p.pairIndex)
    const call = Actions.maker.order.call({
      venue: f.venue,
      order: {
        pairIndex: p.pairIndex,
        mid: Price.parse('1.09'),
        shapeId: 7,
        sequence,
        validUntil: p.validUntil,
      },
    })
    await simulateContract(f.client, {
      ...Actions.maker.order.call({
        venue: f.venue,
        order: {
          pairIndex: p.pairIndex,
          mid: Price.parse('1.09'),
          shapeId: 7,
          sequence,
          validUntil: p.validUntil,
        },
      }),
      account: agent.address,
    })
    await expect(
      simulateContract(f.client, {
        ...Actions.maker.order.call({
          venue: f.venue,
          order: {
            pairIndex: p.pairIndex,
            mid: Price.one,
            shapeId: 7,
            sequence,
            validUntil: p.validUntil,
          },
        }),
        account: f.accounts.stranger.address,
      }),
    ).rejects.toSatisfy(reverts('NotOwnerOrUpdater'))
    const { receipt, posted } = mined(
      await Actions.maker.orderSync(f.client, {
        venue: f.venue,
        order: {
          pairIndex: p.pairIndex,
          mid: Price.parse('1.09'),
          shapeId: 7,
          sequence,
          validUntil: p.validUntil,
        },
        account: agent,
      }),
    )
    const outcome = PostOutcome.fromLogs(call, receipt.logs)
    expect(outcome.accepted).toStrictEqual(call.posts)
    expect(
      outcome.accepted.map((e) => [e.pairIndex, e.sequence]),
    ).toStrictEqual([[p.pairIndex, sequence]])
    expect(outcome.allAccepted).toBeTruthy()
    expect(posted).toStrictEqual([
      { pairIndex: p.pairIndex, hotWord: call.posts?.[0]?.word },
    ])

    // A stale entry succeeds onchain and is skipped without an event.
    const stale = {
      pairIndex: p.pairIndex,
      mid: Price.one,
      shapeId: 7,
      sequence,
      validUntil: p.validUntil,
    }
    const staleReceipt = await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: stale,
      account: owner,
    })
    expect(staleReceipt.receipt.status).toBe('success')
    const staleCall = Actions.maker.order.call({ venue: f.venue, order: stale })
    expect(
      PostOutcome.fromLogs(staleCall, staleReceipt.receipt.logs).skipped,
    ).toStrictEqual(staleCall.posts)
    expect(
      (await Info.orders(f.client, { venue: f.venue, pairs: [p.pairIndex] }))
        .orders[0]?.hot.mid,
    ).toBe(Price.parse('1.09'))
  })

  test('reads a Tempo batch posting one pair three times at one sequence: the first is stored, the cancel and the repeat are stale', async () => {
    const sequence = Sequencer.next(p.sequencer, p.pairIndex)
    const order = {
      pairIndex: p.pairIndex,
      mid: Price.parse('1.09'),
      shapeId: 7,
      sequence,
      validUntil: p.validUntil,
    }
    const requote = Actions.maker.order.call({ venue: f.venue, order })
    const cancel = Actions.maker.cancel.call({
      venue: f.venue,
      cancel: { pairIndex: p.pairIndex, sequence, mid: order.mid },
    })
    const calls = [requote, cancel, requote]
    const receipt = await sendTransactionSync(f.client, {
      account: f.accounts.agent,
      calls: calls.map(({ to, data }) => ({ to, data })),
      chain: f.client.chain,
      throwOnReceiptRevert: true,
    } as never)
    expect(receipt.type).toBe('0x76')
    expect(
      Events.venue(receipt.logs, { venue: f.venue, eventName: 'Posted' })
        .length,
    ).toBe(1)
    // Each call alone: the order's event doesn't acknowledge the cancel at its sequence.
    expect(PostOutcome.fromLogs(requote, receipt.logs).allAccepted).toBeTruthy()
    expect(PostOutcome.fromLogs(cancel, receipt.logs).skipped).toStrictEqual(
      cancel.posts,
    )
    // The batch together: the identical repeat reads stale too.
    expect(
      PostOutcome.fromBatch(calls, receipt.logs).map((o) => o.allAccepted),
    ).toStrictEqual([true, false, false])
    const {
      orders: [state],
    } = await Info.orders(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    expect(state?.hot.sequence).toBe(sequence)
    expect(state?.hot.sides, 'the cancel did not land').toBe('both')
  })

  test('consumes depth on fills, keeps it across a plain post, and refills on request', async () => {
    const { agent } = f.accounts
    const fill = await swap(500_000_000n, false, true)
    expect(fill.fill?.amountOut).toBe(500_000_000n)
    let consumed = await Info.consumed(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
    })
    expect(consumed).toStrictEqual({ bids: 0n, asks: 500_000_000n })
    const fromBlock = fill.receipt.blockNumber

    // A post without a refill keeps the consumption; it comes off the top of the new ladder.
    const order = {
      pairIndex: p.pairIndex,
      mid: Price.parse('1.09'),
      shapeId: 7,
      validUntil: p.validUntil,
    }
    await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        ...order,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        askWiden: 5,
      },
      account: agent,
    })
    consumed = await Info.consumed(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
    })
    expect(consumed.asks).toBe(500_000_000n)

    // A refill of the asks clears them and emits Refilled after Posted.
    const { receipt } = await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        ...order,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        refill: 'asks',
      },
      account: agent,
    })
    expect(
      Events.venue(receipt.logs, { venue: f.venue }).map((e) => e.eventName),
    ).toStrictEqual(['Posted', 'Refilled'])
    expect(
      await Info.consumed(f.client, { venue: f.venue, pairIndex: p.pairIndex }),
    ).toStrictEqual({ bids: 0n, asks: 0n })
    const {
      orders: [stored],
    } = await Info.orders(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    expect(stored?.hot.sides, 'the stored word carries no refill bits').toBe(
      'both',
    )

    const fills = await Info.fills(f.client, {
      venue: f.venue,
      fromBlock,
      toBlock: await getBlockNumber(f.client),
      pairIndex: p.pairIndex,
    })
    expect(fills.length).toBe(1)
    expect(fills[0]?.amountOut).toBe(500_000_000n)
    expect(fills[0]?.log.transactionHash).toBe(fill.receipt.transactionHash)
  })

  test('switches shapes safely: define a new id, then point the next order at it', async () => {
    const { agent } = f.accounts
    const wide = Shape.from({
      bids: [{ size: 10_000, spread: 500 }],
      asks: [{ size: 10_000, spread: 500 }],
    })
    await Actions.venue.setShapeSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      shapeId: 8,
      shape: wide,
      account: agent,
    })
    const before = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    const request = {
      pairIndex: p.pairIndex,
      tokenIn: f.quote,
      tokenOut: f.base,
      amount: 1_000_000n,
      exactIn: false,
    }
    const q7 = Quote.local(before, { ...request, priorityFee: 0n })
    await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        pairIndex: p.pairIndex,
        mid: Price.parse('1.09'),
        shapeId: 8,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        validUntil: p.validUntil,
      },
      account: agent,
    })
    const after = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    const q8 = Quote.local(after, { ...request, priorityFee: 0n })
    assert(q7.ok && q8.ok)
    expect(
      q8.amountIn > q7.amountIn,
      'the 5 bp shape costs more than the 1 bp one',
    ).toBeTruthy()
    expect(
      await Info.quote(f.client, { venue: f.venue, ...request }),
    ).toStrictEqual({ amountIn: q8.amountIn, amountOut: q8.amountOut })
    // Back to shape 7 for the rest of the suite.
    await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        pairIndex: p.pairIndex,
        mid: Price.parse('1.085'),
        shapeId: 7,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        validUntil: p.validUntil,
      },
      account: agent,
    })
  })

  test('cancels with a newer disabled word', async () => {
    const { agent } = f.accounts
    const { outcome } = mined(
      await Actions.maker.cancelSync(f.client, {
        venue: f.venue,
        cancel: {
          pairIndex: p.pairIndex,
          sequence: Sequencer.next(p.sequencer, p.pairIndex),
          mid: Price.one,
        },
        account: agent,
      }),
    )
    expect(outcome.allAccepted).toBe(true)
    await expect(
      Info.quote(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        tokenIn: f.quote,
        tokenOut: f.base,
        amount: 1n,
        exactIn: true,
      }),
    ).rejects.toSatisfy(reverts('QuoteExpired'))
  })

  test("cancelAll cancels every pair's quotes and leaves the venue running", async () => {
    const { agent, owner } = f.accounts
    await requote()
    // A second live pair, which p's sequencer doesn't track, under a band its stored mid (1.085) is above: the agent's
    // cancel must move inside it, or the whole batch reverts MidOutOfBand.
    const q = await setupPair(f)
    await Actions.venue.setMidBandSync(f.client, {
      venue: f.venue,
      pairIndex: q.pairIndex,
      minMid: Price.one,
      maxMid: Price.parse('1.05'),
      account: owner,
    })
    const {
      orders: [stored],
    } = await Info.orders(f.client, {
      venue: f.venue,
      pairs: [q.pairIndex],
    })
    assert(stored)
    const last = Sequencer.last(p.sequencer, p.pairIndex)
    assert(last !== undefined)
    const requests = await Actions.maker.cancelAll.requests(f.client, {
      venue: f.venue,
      sequencer: p.sequencer,
    })
    expect(requests).toStrictEqual({
      cancels: [
        {
          pairIndex: p.pairIndex,
          sequence: last + 1,
          mid: Price.parse('1.085'),
        },
        {
          pairIndex: q.pairIndex,
          sequence: stored.hot.sequence + 1,
          mid: Price.parse('1.05'),
        },
      ],
      skipped: [],
    })
    expect(
      Sequencer.last(p.sequencer, p.pairIndex),
      'requests reserves its cancel',
    ).toBe(last + 1)
    const { posted, outcome, skipped, receipt } = mined(
      await Actions.maker.cancelAllSync(f.client, {
        venue: f.venue,
        sequencer: p.sequencer,
        account: agent,
      }),
    )
    expect(receipt.status).toBe('success')
    expect(outcome.allAccepted).toBe(true)
    expect(skipped).toStrictEqual([])
    expect(
      Sequencer.last(p.sequencer, p.pairIndex),
      'the send records its cancel, so the next post outranks it',
    ).toBe(last + 2)
    expect(posted.map((e) => e.pairIndex)).toStrictEqual([
      p.pairIndex,
      q.pairIndex,
    ])
    expect(
      Events.venue(receipt.logs, { venue: f.venue }).map((e) => e.eventName),
      'no HaltedSet',
    ).toStrictEqual(['Posted', 'Posted'])
    expect((await Info.venueState(f.client, { venue: f.venue })).halted).toBe(
      false,
    )
    for (const order of (
      await Info.orders(f.client, {
        venue: f.venue,
        pairs: [p.pairIndex, q.pairIndex],
      })
    ).orders) {
      expect(order.hot.sides).toBe('neither')
      await expect(
        Info.quote(f.client, {
          venue: f.venue,
          pairIndex: order.market.pairIndex,
          tokenIn: f.quote,
          tokenOut: f.base,
          amount: 1n,
          exactIn: true,
        }),
      ).rejects.toSatisfy(reverts('QuoteExpired'))
    }
    // Halting stays its own explicit call, which only the owner undoes.
    await Actions.venue.setHaltedSync(f.client, {
      venue: f.venue,
      halted: true,
      account: agent,
    })
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.setHalted.call({
          venue: f.venue,
          halted: false,
        }),
        account: agent.address,
      }),
    ).rejects.toSatisfy(reverts('NotOwner'))
    await Actions.venue.setHaltedSync(f.client, {
      venue: f.venue,
      halted: false,
      account: owner,
    })
    await Actions.venue.removePairSync(f.client, {
      venue: f.venue,
      pairIndex: q.pairIndex,
      account: owner,
    })
    await requote()
  })

  test('cancelAll skips a pair at the last sequence and still cancels the rest', async () => {
    const { agent, owner } = f.accounts
    await requote()
    // r's word at uint32 max: no post can ever replace it (only closePair or setHalted stops it).
    const r = await setupPair(f)
    await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        pairIndex: r.pairIndex,
        mid: Price.parse('1.085'),
        shapeId: 7,
        sequence: Number(maxUint32),
        validUntil: r.validUntil,
      },
      account: agent,
    })
    // Untracked (stored + 1 would overflow), and tracked below and at the maximum: the stored word decides.
    const below = Sequencer.from([[r.pairIndex, 5]])
    const at = Sequencer.from([[r.pairIndex, Number(maxUint32)]])
    for (const sequencer of [undefined, p.sequencer, below, at]) {
      const { cancels, skipped } = await Actions.maker.cancelAll.requests(
        f.client,
        { venue: f.venue, sequencer },
      )
      expect(cancels.map((c) => c.pairIndex)).toStrictEqual([p.pairIndex])
      expect(skipped).toStrictEqual([
        { pairIndex: r.pairIndex, reason: 'sequenceExhausted' },
      ])
    }
    const { posted, outcome, skipped } = mined(
      await Actions.maker.cancelAllSync(f.client, {
        venue: f.venue,
        sequencer: p.sequencer,
        account: agent,
      }),
    )
    // Every cancel sent was stored, but r still quotes: `skipped` says so, `allAccepted` doesn't.
    expect(outcome.allAccepted).toBe(true)
    expect(skipped).toStrictEqual([
      { pairIndex: r.pairIndex, reason: 'sequenceExhausted' },
    ])
    expect(posted.map((e) => e.pairIndex)).toStrictEqual([p.pairIndex])
    const {
      orders: [cancelled, untouched],
    } = await Info.orders(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex, r.pairIndex],
    })
    expect(cancelled?.hot.sides).toBe('neither')
    expect(untouched?.hot.sequence).toBe(Number(maxUint32))
    await Actions.venue.removePairSync(f.client, {
      venue: f.venue,
      pairIndex: r.pairIndex,
      account: owner,
    })
    await requote()
  })

  test('bounds an agent by the mid band, never the owner', async () => {
    const { agent, owner } = f.accounts
    await Actions.venue.setMidBandSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      minMid: Price.one,
      maxMid: Price.parse('1.2'),
      account: owner,
    })
    const last = Sequencer.last(p.sequencer, p.pairIndex)
    assert(last !== undefined)
    const order = {
      pairIndex: p.pairIndex,
      mid: Price.parse('1.5'),
      shapeId: 7,
      validUntil: p.validUntil,
      sequence: last + 1,
    }
    await expect(
      simulateContract(f.client, {
        ...Actions.maker.order.call({
          venue: f.venue,
          order,
        }),
        account: agent.address,
      }),
    ).rejects.toSatisfy(reverts('MidOutOfBand'))
    await simulateContract(f.client, {
      ...Actions.maker.order.call({
        venue: f.venue,
        order,
      }),
      account: owner.address,
    })
    await Actions.venue.setMidBandSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      minMid: 0n,
      maxMid: 0n,
      account: owner,
    })
  })
})

describe('owner and access lifecycle', () => {
  test('enters Open only while halted', async () => {
    const { owner } = f.accounts
    // A read names the mode as the write takes it.
    const market = await Info.market(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
    })
    expect(market.access).toBe('listed')
    await Actions.venue.setPairAccessSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      mode: market.access,
      account: owner,
    })
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.setPairAccess.call({
          venue: f.venue,
          pairIndex: p.pairIndex,
          mode: 'open',
        }),
        account: owner.address,
      }),
    ).rejects.toSatisfy(reverts('NotHalted'))
    await Actions.venue.setHaltedSync(f.client, {
      venue: f.venue,
      halted: true,
      account: owner,
    })
    await Actions.venue.setPairAccessSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      mode: 'open',
      account: owner,
    })
    await Actions.venue.setHaltedSync(f.client, {
      venue: f.venue,
      halted: false,
      account: owner,
    })
    // Open admits a stranger under any id; Listed doesn't.
    expect(
      await Info.takerAccess(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        taker: f.accounts.stranger.address,
        sponsorId: 99n,
      }),
    ).toBe('allowed')
    await Actions.venue.setPairAccessSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      mode: 'listed',
      account: owner,
    })
    expect(
      await Info.takerAccess(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        taker: f.accounts.stranger.address,
        sponsorId: 0n,
      }),
    ).toBe('notListed')
  })

  test('registers sponsors, whose admins alone list; denials override every list; resets void old listings', async () => {
    const { owner, agent, sponsorAdmin, stranger, newAdmin } = f.accounts
    const access = (taker = stranger.address, sponsorId = 42n) =>
      Info.takerAccess(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        taker,
        sponsorId,
      })
    await Actions.venue.addSponsorSync(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      admin: sponsorAdmin.address,
      account: owner,
    })
    expect(await access()).toBe('sponsorNotAdmitted')
    await Actions.venue.setPairSponsorSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      sponsorId: 42n,
      admitted: true,
      account: owner,
    })
    expect(
      await Info.pairSponsor(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        sponsorId: 42n,
      }),
    ).toBe(true)
    expect(await access()).toBe('notListed')
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.setMembers.call({
          venue: f.venue,
          pairIndex: p.pairIndex,
          sponsorId: 42n,
          accounts: [stranger.address],
          allowed: true,
        }),
        account: owner.address,
      }),
    ).rejects.toSatisfy(reverts('NotSponsorAdmin'))
    await Actions.venue.setMembersSync(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      sponsorId: 42n,
      accounts: [stranger.address],
      allowed: true,
      account: sponsorAdmin,
    })
    expect(
      await Info.isMember(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        sponsorId: 42n,
        account: stranger.address,
      }),
    ).toBe(true)
    expect(await access()).toBe('allowed')
    const fill = await swap(1_000_000n, true, true, stranger, 42n)
    expect(fill.fill?.sponsorId).toBe(42n)

    // The agent switches the sponsor off; only the owner switches it back, and the list survives.
    await Actions.venue.setSponsorEnabledSync(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      enabled: false,
      account: agent,
    })
    expect(await access()).toBe('sponsorDisabled')
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.setSponsorEnabled.call({
          venue: f.venue,
          sponsorId: 42n,
          enabled: true,
        }),
        account: agent.address,
      }),
    ).rejects.toSatisfy(reverts('NotOwner'))
    await Actions.venue.setSponsorEnabledSync(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      enabled: true,
      account: owner,
    })
    expect(await access()).toBe('allowed')

    // A denial overrides every list; the agent denies, only the owner lifts.
    await Actions.venue.setDeniedSync(f.client, {
      venue: f.venue,
      accounts: [stranger.address],
      deny: true,
      account: agent,
    })
    expect(await access()).toBe('denied')
    expect(
      await Info.isDenied(f.client, {
        venue: f.venue,
        account: stranger.address,
      }),
    ).toBe(true)
    expect(
      (await Info.venueState(f.client, { venue: f.venue })).deniedCount,
    ).toBe(1)
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.setDenied.call({
          venue: f.venue,
          accounts: [stranger.address],
          deny: false,
        }),
        account: agent.address,
      }),
    ).rejects.toSatisfy(reverts('NotOwner'))
    await Actions.venue.setDeniedSync(f.client, {
      venue: f.venue,
      accounts: [stranger.address],
      deny: false,
      account: owner,
    })
    expect(await access()).toBe('allowed')

    // Cancellation clears the nominee without changing the admin, and is safe to repeat.
    await Actions.venue.transferSponsorAdminSync(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      newAdmin: newAdmin.address,
      account: sponsorAdmin,
    })
    expect(
      (await Info.sponsorState(f.client, { venue: f.venue, sponsorId: 42n }))
        .pendingAdmin,
    ).toBe(newAdmin.address)
    expect(
      mined(
        await Actions.venue.cancelSponsorAdminTransferSync(f.client, {
          venue: f.venue,
          sponsorId: 42n,
          account: sponsorAdmin,
        }),
      ).pendingAdmin,
    ).toBe(zeroAddress)
    expect(
      await Info.sponsorState(f.client, { venue: f.venue, sponsorId: 42n }),
    ).toMatchObject({ admin: sponsorAdmin.address, pendingAdmin: zeroAddress })
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.acceptSponsorAdmin.call({
          venue: f.venue,
          sponsorId: 42n,
        }),
        account: newAdmin.address,
      }),
    ).rejects.toSatisfy(reverts('NotPendingSponsorAdmin'))
    expect(
      mined(
        await Actions.venue.cancelSponsorAdminTransferSync(f.client, {
          venue: f.venue,
          sponsorId: 42n,
          account: sponsorAdmin,
        }),
      ).pendingAdmin,
    ).toBe(zeroAddress)

    // A fresh transfer still completes normally and keeps the list; a reset voids it for good.
    await Actions.venue.transferSponsorAdminSync(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      newAdmin: newAdmin.address,
      account: sponsorAdmin,
    })
    await Actions.venue.acceptSponsorAdminSync(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      account: newAdmin,
    })
    expect(
      (await Info.sponsorState(f.client, { venue: f.venue, sponsorId: 42n }))
        .admin,
    ).toBe(newAdmin.address)
    expect(await access()).toBe('allowed')
    await Actions.venue.resetSponsorSync(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      newAdmin: sponsorAdmin.address,
      account: owner,
    })
    const state = await Info.sponsorState(f.client, {
      venue: f.venue,
      sponsorId: 42n,
    })
    expect(state.generation).toBe(2)
    expect(await access(), 'a reset voids every earlier listing').toBe(
      'notListed',
    )
  })

  test('hands the venue over in two steps', async () => {
    const { owner, newOwner } = f.accounts
    await Actions.venue.transferOwnershipSync(f.client, {
      venue: f.venue,
      newOwner: newOwner.address,
      account: owner,
    })
    expect(
      (await Info.venueState(f.client, { venue: f.venue })).pendingOwner,
    ).toBe(newOwner.address)
    expect(
      mined(
        await Actions.venue.cancelOwnershipTransferSync(f.client, {
          venue: f.venue,
          account: owner,
        }),
      ).pendingOwner,
    ).toBe(zeroAddress)
    expect(await Info.venueState(f.client, { venue: f.venue })).toMatchObject({
      owner: owner.address,
      pendingOwner: zeroAddress,
    })
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.acceptOwnership.call({
          venue: f.venue,
        }),
        account: newOwner.address,
      }),
    ).rejects.toSatisfy(reverts('NotPendingOwner'))
    expect(
      mined(
        await Actions.venue.cancelOwnershipTransferSync(f.client, {
          venue: f.venue,
          account: owner,
        }),
      ).pendingOwner,
    ).toBe(zeroAddress)
    // A fresh proposal still works after an idempotent cancellation.
    await Actions.venue.transferOwnershipSync(f.client, {
      venue: f.venue,
      newOwner: newOwner.address,
      account: owner,
    })
    await Actions.venue.acceptOwnershipSync(f.client, {
      venue: f.venue,
      account: newOwner,
    })
    expect((await Info.venueState(f.client, { venue: f.venue })).owner).toBe(
      newOwner.address,
    )
    await Actions.venue.transferOwnershipSync(f.client, {
      venue: f.venue,
      newOwner: owner.address,
      account: newOwner,
    })
    await Actions.venue.acceptOwnershipSync(f.client, {
      venue: f.venue,
      account: owner,
    })
  })

  test('withdraws with exact deltas and enables the default fee cap', async () => {
    const { owner, agent } = f.accounts
    const balance = async () =>
      (
        await TempoActions.token.getBalance(f.client, {
          token: f.base,
          account: f.venue,
        })
      ).amount
    const before = await balance()
    await Actions.venue.withdrawSync(f.client, {
      venue: f.venue,
      token: f.base,
      to: owner.address,
      amount: 1_000n,
      account: owner,
    })
    expect(await balance()).toBe(before - 1_000n)
    await Actions.venue.enableTakerPriorityFeeCapSync(f.client, {
      venue: f.venue,
      account: agent,
    })
    expect(
      (await Info.venueState(f.client, { venue: f.venue })).maxTakerPriorityFee,
    ).toBe(10_000_000_000n)
  })
})

/** A successful Sync result. */
type Success<result> = Extract<result, { status: 'success' }>

/** A changed Sync result's event fields are the event `extract` reads from its successful receipt. */
function fromEvent<result extends { status: string }>(
  result: result,
  extract: (logs: Log[]) => { args: object },
): Omit<Success<result>, 'receipt' | 'status'> {
  const {
    receipt,
    status: _,
    changed,
    ...args
  } = mined(result) as Success<result> & {
    changed?: boolean
    receipt: { logs: Log[] }
    status: 'success'
  }
  if (changed !== undefined) expect(changed).toBe(true)
  expect(args).toStrictEqual(extract(receipt.logs).args)
  return args as never
}

/** A Sync result's `updates` are the events `extract` reads from its receipt. */
function fromEvents<result extends { status: string }>(
  result: result,
  extract: (logs: Log[]) => { args: object }[],
): Success<result> extends { updates: infer updates } ? updates : never {
  const { receipt, updates } = mined(result) as unknown as {
    receipt: { logs: Log[] }
    updates: readonly object[]
  }
  expect(updates).toStrictEqual(extract(receipt.logs).map((e) => e.args))
  return updates as never
}

/** A post Sync result: its `Posted` events are the ones `extract` reads, and every entry was stored. */
function stored(
  result: Actions.venue.postSync.ReturnValue,
  extract: (logs: Log[]) => { args: object }[],
) {
  const { receipt, posted, outcome } = mined(result)
  expect(posted).toStrictEqual(extract(receipt.logs).map((e) => e.args))
  expect(outcome.allAccepted).toBe(true)
  return posted.map((e) => e.pairIndex)
}

/** A client for `account` with every action bound (`propAmmActions()`). */
const decorated = (account: (typeof f.accounts)[keyof typeof f.accounts]) =>
  createClient({
    account,
    chain: f.client.chain,
    transport: http(f.rpc),
    pollingInterval: 50,
  }).extend(propAmmActions())

describe('every write', () => {
  test('returns its event from its Sync twin, as its extractEvent reads it, through the decorated clients', async () => {
    const { owner, agent, sponsorAdmin, newOwner, newAdmin, taker } = f.accounts
    const [o, a, s] = [
      decorated(owner),
      decorated(agent),
      decorated(sponsorAdmin),
    ]
    const salt = keccak256(toHex('every write'))

    const created = fromEvent(
      await o.factory.createVenueSync({
        factory: f.core.factory,
        owner: owner.address,
        salt,
      }),
      Actions.factory.createVenue.extractEvent,
    )
    const venue = created.venue
    expect(created).toStrictEqual({
      venue: await Info.predictVenue(f.client, {
        factory: f.core.factory,
        owner: owner.address,
        salt,
      }),
      owner: owner.address,
      salt,
    })

    const [first, second] = [
      fromEvent(
        await o.venue.addPairSync({
          venue,
          base: f.base,
          quote: f.quote,
          sizeUnit: 1_000_000n,
        }),
        Actions.venue.addPair.extractEvent,
      ),
      fromEvent(
        await o.venue.addPairSync({
          venue,
          base: f.quote,
          quote: f.base,
          sizeUnit: 1_000_000n,
        }),
        Actions.venue.addPair.extractEvent,
      ),
    ]
    expect([first.pairIndex, second.pairIndex]).toStrictEqual([0, 1])
    expect(
      fromEvent(
        await o.venue.approveAgentSync({ venue, agent: agent.address }),
        Actions.venue.approveAgent.extractEvent,
      ),
    ).toStrictEqual({ updater: agent.address, allowed: true })
    for (const pairIndex of [0, 1])
      expect(
        fromEvent(
          await a.venue.setShapeSync({
            venue,
            pairIndex,
            shapeId: 7,
            shape: p.shape,
          }),
          Actions.venue.setShape.extractEvent,
        ),
      ).toStrictEqual({ pairIndex, shapeId: 7, words: p.shape.words })
    expect(
      fromEvents(
        await o.venue.setMembersSync({
          venue,
          pairIndex: 0,
          sponsorId: 0n,
          accounts: [taker.address],
          allowed: true,
        }),
        Actions.venue.setMembers.extractEvents,
      ),
    ).toStrictEqual([
      { pairIndex: 0, sponsorId: 0n, account: taker.address, allowed: true },
    ])
    expect(
      fromEvent(
        await o.venue.setPairAccessSync({
          venue,
          pairIndex: 0,
          mode: 'listed',
        }),
        Actions.venue.setPairAccess.extractEvent,
      ),
    ).toStrictEqual({
      pairIndex: 0,
      oldMode: AccessMode.Closed,
      newMode: AccessMode.Listed,
    })
    expect(
      fromEvent(
        await o.venue.setMidBandSync({
          venue,
          pairIndex: 0,
          minMid: Price.one,
          maxMid: Price.parse('1.2'),
        }),
        Actions.venue.setMidBand.extractEvent,
      ),
    ).toStrictEqual({
      pairIndex: 0,
      minMid: Price.one,
      maxMid: Price.parse('1.2'),
    })

    // Quoting: raw entries, orders and cancels, all through `post`.
    const sequencer = await Sequencer.seed(f.client, { venue, pairs: [0, 1] })
    const order = (pairIndex: number) => ({
      pairIndex,
      mid: Price.parse('1.085'),
      shapeId: 7,
      sequence: Sequencer.next(sequencer, pairIndex),
      validUntil: p.validUntil,
    })
    expect(
      stored(
        await a.venue.postSync({ venue, entries: [Post.order(order(0))] }),
        Actions.venue.post.extractEvents,
      ),
    ).toStrictEqual([0])
    expect(
      stored(
        await a.maker.bulkOrdersSync({ venue, orders: [order(0), order(1)] }),
        Actions.maker.bulkOrders.extractEvents,
      ),
    ).toStrictEqual([0, 1])
    expect(
      stored(
        await a.maker.orderSync({ venue, order: order(1) }),
        Actions.maker.order.extractEvents,
      ),
    ).toStrictEqual([1])
    const cancel = (pairIndex: number) => ({
      pairIndex,
      sequence: Sequencer.next(sequencer, pairIndex),
      mid: Price.parse('1.085'),
    })
    expect(
      stored(
        await a.maker.bulkCancelSync({
          venue,
          cancels: [cancel(0), cancel(1)],
        }),
        Actions.maker.bulkCancel.extractEvents,
      ),
    ).toStrictEqual([0, 1])
    expect(
      stored(
        await a.maker.cancelSync({ venue, cancel: cancel(0) }),
        Actions.maker.cancel.extractEvents,
      ),
    ).toStrictEqual([0])
    expect(
      stored(
        await a.maker.cancelAllSync({ venue, sequencer }),
        Actions.maker.cancelAll.extractEvents,
      ),
    ).toStrictEqual([0, 1])

    // The fee cap, hooks, the settler and the narrowing switches.
    expect(
      fromEvent(
        await a.venue.setMaxTakerPriorityFeeSync({ venue, cap: Fees.gwei }),
        Actions.venue.setMaxTakerPriorityFee.extractEvent,
      ),
    ).toStrictEqual({
      previousCap: Venue.noPriorityFeeCap,
      cap: Fees.gwei,
      by: agent.address,
    })
    expect(
      fromEvent(
        await a.venue.enableTakerPriorityFeeCapSync({ venue }),
        Actions.venue.enableTakerPriorityFeeCap.extractEvent,
      ),
    ).toStrictEqual({
      previousCap: Fees.gwei,
      cap: Venue.defaultTakerPriorityFeeCap,
      by: agent.address,
    })
    expect(
      fromEvent(
        await o.venue.setPairHookSync({
          venue,
          pairIndex: 0,
          hook: zeroAddress,
          flags: 0,
        }),
        Actions.venue.setPairHook.extractEvent,
      ),
    ).toStrictEqual({ pairIndex: 0, hook: zeroAddress, flags: 0 })
    expect(
      fromEvent(
        await o.venue.setSettlerSync({ venue, settler: f.core.settler }),
        Actions.venue.setSettler.extractEvent,
      ),
    ).toStrictEqual({ settler: f.core.settler })
    expect(
      fromEvent(
        await a.venue.closePairSync({ venue, pairIndex: 0 }),
        Actions.venue.closePair.extractEvent,
      ),
    ).toStrictEqual({
      pairIndex: 0,
      oldMode: AccessMode.Listed,
      newMode: AccessMode.Closed,
    })
    expect(
      fromEvent(
        await a.venue.setHaltedSync({ venue, halted: true }),
        Actions.venue.setHalted.extractEvent,
      ),
    ).toStrictEqual({ halted: true })
    expect(
      fromEvent(
        await o.venue.setHaltedSync({ venue, halted: false }),
        Actions.venue.setHalted.extractEvent,
      ),
    ).toStrictEqual({ halted: false })
    expect(
      fromEvents(
        await a.venue.setDeniedSync({
          venue,
          accounts: [taker.address],
          deny: true,
        }),
        Actions.venue.setDenied.extractEvents,
      ),
    ).toStrictEqual([
      { account: taker.address, denied: true, by: agent.address },
    ])

    // Sponsors.
    expect(
      fromEvent(
        await o.venue.addSponsorSync({
          venue,
          sponsorId: 7n,
          admin: sponsorAdmin.address,
        }),
        Actions.venue.addSponsor.extractEvent,
      ),
    ).toStrictEqual({ sponsorId: 7n, admin: sponsorAdmin.address })
    expect(
      fromEvent(
        await o.venue.setPairSponsorSync({
          venue,
          pairIndex: 1,
          sponsorId: 7n,
          admitted: true,
        }),
        Actions.venue.setPairSponsor.extractEvent,
      ),
    ).toStrictEqual({
      pairIndex: 1,
      sponsorId: 7n,
      admitted: true,
      by: owner.address,
    })
    expect(
      fromEvent(
        await a.venue.setSponsorEnabledSync({
          venue,
          sponsorId: 7n,
          enabled: false,
        }),
        Actions.venue.setSponsorEnabled.extractEvent,
      ),
    ).toStrictEqual({ sponsorId: 7n, enabled: false, by: agent.address })
    expect(
      fromEvent(
        await s.venue.transferSponsorAdminSync({
          venue,
          sponsorId: 7n,
          newAdmin: newAdmin.address,
        }),
        Actions.venue.transferSponsorAdmin.extractEvent,
      ),
    ).toStrictEqual({
      sponsorId: 7n,
      admin: sponsorAdmin.address,
      pendingAdmin: newAdmin.address,
    })
    expect(
      fromEvent(
        await decorated(newAdmin).venue.acceptSponsorAdminSync({
          venue,
          sponsorId: 7n,
        }),
        Actions.venue.acceptSponsorAdmin.extractEvent,
      ),
    ).toStrictEqual({
      sponsorId: 7n,
      previousAdmin: sponsorAdmin.address,
      newAdmin: newAdmin.address,
    })
    expect(
      fromEvent(
        await o.venue.resetSponsorSync({
          venue,
          sponsorId: 7n,
          newAdmin: sponsorAdmin.address,
        }),
        Actions.venue.resetSponsor.extractEvent,
      ),
    ).toStrictEqual({
      sponsorId: 7n,
      previousAdmin: newAdmin.address,
      newAdmin: sponsorAdmin.address,
      generation: 2,
    })

    // Custody and administration.
    await TempoActions.token.transferSync(f.client, {
      token: f.base,
      to: venue,
      amount: 1_000n,
      account: owner,
    })
    expect(
      fromEvent(
        await o.venue.withdrawSync({
          venue,
          token: f.base,
          to: owner.address,
          amount: 1_000n,
        }),
        Actions.venue.withdraw.extractEvent,
      ),
    ).toStrictEqual({
      token: f.base,
      to: owner.address,
      amount: 1_000n,
      memo: zeroHash,
    })
    expect(
      fromEvent(
        await o.venue.revokeAgentSync({ venue, agent: agent.address }),
        Actions.venue.revokeAgent.extractEvent,
      ),
    ).toStrictEqual({ updater: agent.address, allowed: false })
    expect(
      fromEvent(
        await o.venue.removePairSync({ venue, pairIndex: 1 }),
        Actions.venue.removePair.extractEvent,
      ),
    ).toStrictEqual({ pairIndex: 1 })
    expect(
      fromEvent(
        await o.venue.transferOwnershipSync({
          venue,
          newOwner: newOwner.address,
        }),
        Actions.venue.transferOwnership.extractEvent,
      ),
    ).toStrictEqual({ owner: owner.address, pendingOwner: newOwner.address })
    expect(
      fromEvent(
        await decorated(newOwner).venue.acceptOwnershipSync({ venue }),
        Actions.venue.acceptOwnership.extractEvent,
      ),
    ).toStrictEqual({
      previousOwner: owner.address,
      newOwner: newOwner.address,
    })
  })

  test("sends each group's bound action that returns a hash", async () => {
    const { owner, agent } = f.accounts
    const [o, a] = [decorated(owner), decorated(agent)]
    const sent = async (hash: Promise<`0x${string}`>) => {
      const receipt = await waitForTransactionReceipt(f.client, {
        hash: await hash,
      })
      expect(receipt.status).toBe('success')
      return receipt.logs
    }
    const salt = keccak256(toHex('bound hashes'))
    const created = Actions.factory.createVenue.extractEvent(
      await sent(
        o.factory.createVenue({
          factory: f.core.factory,
          owner: owner.address,
          salt,
        }),
      ),
    ).args
    expect(created.owner).toBe(owner.address)
    expect(
      Actions.venue.setHalted.extractEvent(
        await sent(o.venue.setHalted({ venue: created.venue, halted: true })),
        { address: created.venue },
      ).args,
    ).toStrictEqual({ halted: true })
    const order = {
      pairIndex: p.pairIndex,
      mid: Price.parse('1.085'),
      shapeId: 7,
      sequence: Sequencer.next(p.sequencer, p.pairIndex),
      validUntil: p.validUntil,
    }
    expect(
      Actions.maker.order.extractEvents(
        await sent(a.maker.order({ venue: f.venue, order })),
        { address: f.venue },
      ),
    ).toHaveLength(1)
  })

  test("estimates gas and simulates a call with viem's own actions, with the decorated client", async () => {
    const o = createClient({
      account: f.accounts.owner,
      chain: f.client.chain,
      transport: http(f.rpc),
    }).extend(propAmmActions())
    const call = o.venue.setHalted.call({ venue: f.venue, halted: true })
    const gas = await estimateContractGas(o, call)
    expect(gas > 21_000n).toBe(true)
    // `simulateContract` returns the request `writeContract` sends.
    const { request } = await simulateContract(o, {
      ...call,
      account: f.accounts.owner,
      blockTag: 'latest',
    })
    expect(request.functionName).toBe('setHalted')
    const receipt = await writeContractSync(o, request)
    expect(
      Actions.venue.setHalted.extractEvent(receipt.logs).args,
    ).toStrictEqual({ halted: true })
    expect(
      (await o.maker.cancelAll.requests({ venue: f.venue })).cancels,
    ).toHaveLength(1)
  })
})
