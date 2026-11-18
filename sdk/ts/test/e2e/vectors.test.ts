// Replays the venue sections of the shared vectors (test/vectors.ts: the committed file, or the seeded random set
// PROPAMM_VECTORS names) against the core deployed as DeployV2 deploys it, on a local `anvil --network tempo` with real
// TIP-20 precompiles: `quotes` (one pair's posts, quotes and fills in order) must get the reference's amounts, reverts,
// consumption and inventory from `venue.quote` and from swaps through the Settler, `posts` (the batches both SDKs build)
// must store the reference's words and emit its refills, and `outcomes` (one transaction's post calls, sent as one Tempo
// batch) must emit the reference's `Posted` events, from which `PostOutcome.fromBatch` must read its outcomes. Every
// call is built from the vector's own numbers, not from the SDK's quote, so this holds the deployed contracts to the
// reference directly.
import {
  type Address,
  type Hex,
  keccak256,
  type LocalAccount,
  toHex,
} from 'viem'
import { readContract, sendTransactionSync } from 'viem/actions'
import { Actions as TempoActions } from 'viem/tempo'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import {
  Abis,
  Actions,
  Errors,
  Events,
  HotWord,
  Info,
  PostOutcome,
  type PreparedCall,
  type Shape,
} from '../../src/index.js'
import {
  committed,
  data,
  type OutcomeVector,
  type PostVector,
  postCall,
  type QuoteCase,
  referenceArgs,
} from '../vectors.js'
import { type Fixture, start, swap } from './fixture.js'

/** Pairs a `posts` replay adds; batches that name a higher index are encoding-only. */
const POST_PAIRS = 16

let f: Fixture
let venues = 0
beforeAll(async () => {
  f = await start()
})
afterAll(async () => f?.stop())

/** One Tempo batch from `account`, which must succeed. */
async function batch(
  account: LocalAccount,
  calls: readonly Pick<PreparedCall, 'to' | 'data'>[],
) {
  const receipt = await sendTransactionSync(f.client, {
    account,
    calls: calls.map(({ to, data }) => ({ to, data })),
    chain: f.client.chain,
  } as never)
  expect(receipt.status).toBe('success')
  return receipt
}

/** A new venue owned by `owner`, created in the same batch as `then(venue)`'s calls. */
async function newVenue(
  then: (venue: Address) => Pick<PreparedCall, 'to' | 'data'>[],
): Promise<Address> {
  const { owner } = f.accounts
  const salt = keccak256(toHex(`vectors ${++venues}`))
  const venue = await Info.predictVenue(f.client, {
    factory: f.core.factory,
    owner: owner.address,
    salt,
  })
  await batch(owner, [
    Actions.factory.createVenue.call({
      factory: f.core.factory,
      owner: owner.address,
      salt,
    }),
    ...then(venue),
  ])
  return venue
}

async function state(venue: Address) {
  const [bids, asks] = await readContract(f.client, {
    address: venue,
    abi: Abis.venueAbi,
    functionName: 'consumed',
    args: [0],
  })
  const balance = async (token: Address) =>
    (await TempoActions.token.getBalance(f.client, { token, account: venue }))
      .amount
  const base = await balance(f.base)
  const quote = await balance(f.quote)
  return {
    consumed: [bids.toString(), asks.toString()],
    inventory: [base.toString(), quote.toString()],
  }
}

async function replayQuotes(c: QuoteCase): Promise<number> {
  const { owner, taker } = f.accounts
  const [base, quote] = [BigInt(c.inventory[0]), BigInt(c.inventory[1])]
  const venue = await newVenue((venue) => [
    Actions.venue.addPair.call({
      venue,
      base: f.base,
      quote: f.quote,
      sizeUnit: BigInt(c.sizeUnit),
    }),
    Actions.venue.setMembers.call({
      venue,
      pairIndex: 0,
      sponsorId: 0n,
      accounts: [taker.address],
      allowed: true,
    }),
    Actions.venue.setPairAccess.call({ venue, pairIndex: 0, mode: 'listed' }),
    ...(base > 0n
      ? [
          TempoActions.token.transfer.call({
            token: f.base,
            to: venue,
            amount: base,
          }),
        ]
      : []),
    ...(quote > 0n
      ? [
          TempoActions.token.transfer.call({
            token: f.quote,
            to: venue,
            amount: quote,
          }),
        ]
      : []),
  ])
  let fills = 0
  for (const [j, s] of c.steps.entries()) {
    const label = `${c.name}: step ${j} ${s.op}`
    if (s.op === 'setShape') {
      const words = s.words.map((w) => BigInt(w)) as unknown as Shape.Words
      await batch(owner, [
        Actions.venue.setShape.call({
          venue,
          pairIndex: 0,
          shapeId: s.shapeId,
          shape: words,
        }),
      ])
    } else if (s.op === 'post') {
      const before = await readContract(f.client, {
        address: venue,
        abi: Abis.venueAbi,
        functionName: 'hotWord',
        args: [0],
      })
      await batch(owner, [
        Actions.venue.post.call({
          venue,
          entries: [{ pairIndex: 0, word: s.word }],
        }),
      ])
      const after = await readContract(f.client, {
        address: venue,
        abi: Abis.venueAbi,
        functionName: 'hotWord',
        args: [0],
      })
      expect(after, `${label}: stored word`).toBe(
        s.accepted ? HotWord.withoutRefill(s.word) : before,
      )
    } else {
      const [tokenIn, tokenOut] = s.baseIn
        ? [f.base, f.quote]
        : [f.quote, f.base]
      // The case's clock, whatever the chain's: every word a fill runs under is live at any time.
      const quoted = await readContract(f.client, {
        address: venue,
        abi: Abis.venueAbi,
        functionName: 'quote',
        args: [0, tokenIn, tokenOut, BigInt(s.amount), s.exactIn],
        blockOverrides: { time: BigInt(c.timestamp) },
      }).then(
        ([amountIn, amountOut]) => ({ ok: true as const, amountIn, amountOut }),
        (e: unknown) => ({ ok: false as const, error: Errors.decode(e) }),
      )
      if (s.expect === 'ok') {
        assert(
          quoted.ok,
          `${label}: expected ok, venue reverted ${quoted.ok ? '' : quoted.error?.errorName}`,
        )
        expect(quoted.amountIn.toString(), `${label}: quote amountIn`).toBe(
          s.amountIn,
        )
        expect(quoted.amountOut.toString(), `${label}: quote amountOut`).toBe(
          s.amountOut,
        )
      } else {
        assert(
          !quoted.ok,
          `${label}: expected ${s.expect}, venue quoted ${quoted.ok ? `${quoted.amountIn}/${quoted.amountOut}` : ''}`,
        )
        expect(quoted.error?.errorName, label).toBe(s.expect)
        expect(
          referenceArgs(quoted.error?.args ?? [], {
            base: f.base,
            quote: f.quote,
          }),
          `${label}: args`,
        ).toStrictEqual(s.args)
      }
      if (s.op === 'fill' && s.expect === 'ok') {
        // The reference's own bounds: exact in pays `amount` for at least its `amountOut`, exact out at most its
        // `amountIn` for `amount`. A different fill reverts in the Settler.
        const [amountIn, amountOut] = [BigInt(s.amountIn), BigInt(s.amountOut)]
        const { fill } = await swap(f, {
          venue,
          pairIndex: 0,
          tokenIn,
          tokenOut,
          exactIn: s.exactIn,
          amountIn,
          amountOut,
          account: taker,
        })
        assert(fill, `${label}: no Fill`)
        expect(fill.amountIn, `${label}: fill amountIn`).toBe(amountIn)
        expect(fill.amountOut, `${label}: fill amountOut`).toBe(amountOut)
        fills++
      }
    }
    expect(
      await state(venue),
      `${label}: consumed and inventory`,
    ).toStrictEqual({ consumed: s.consumed, inventory: s.inventory })
  }
  return fills
}

async function replayPost(p: PostVector): Promise<boolean> {
  if (
    p.expect !== 'ok' ||
    p.posts.some(([pairIndex]) => pairIndex >= POST_PAIRS)
  )
    return false
  const venue = await newVenue((venue) =>
    Array.from({ length: POST_PAIRS }, () =>
      Actions.venue.addPair.call({
        venue,
        base: f.base,
        quote: f.quote,
        sizeUnit: 1n,
      }),
    ),
  )
  const receipt = await batch(f.accounts.owner, [
    {
      to: venue,
      data: Actions.venue.post.call({ venue, entries: unpack(p.packed) }).data,
    },
  ])
  const events = Events.venue(receipt.logs, { venue })
  const posted = events
    .filter((e) => e.eventName === 'Posted')
    .map((e) => [Number(e.args.pairIndex), e.args.hotWord])
  expect(posted, `${p.name}: Posted`).toStrictEqual(
    p.posts.map(([pairIndex], k) => [pairIndex, p.stored[k]]),
  )
  const refilled = events
    .filter((e) => e.eventName === 'Refilled')
    .map((e) => [Number(e.args.pairIndex), e.args.bids, e.args.asks])
  const expected = p.posts.flatMap(([pairIndex], k) => {
    const bits = p.refills[k] as number
    return bits === 0 ? [] : [[pairIndex, (bits & 4) !== 0, (bits & 8) !== 0]]
  })
  expect(refilled, `${p.name}: Refilled`).toStrictEqual(expected)
  for (const [k, [pairIndex]] of p.posts.entries()) {
    const word = await readContract(f.client, {
      address: venue,
      abi: Abis.venueAbi,
      functionName: 'hotWord',
      args: [pairIndex],
    })
    expect(word, `${p.name}: pair ${pairIndex}`).toBe(p.stored[k])
  }
  return true
}

async function replayOutcome(v: OutcomeVector): Promise<void> {
  const venue = await newVenue((venue) =>
    Array.from({ length: POST_PAIRS }, () =>
      Actions.venue.addPair.call({
        venue,
        base: f.base,
        quote: f.quote,
        sizeUnit: 1n,
      }),
    ),
  )
  const calls = v.calls.map((c) => postCall(venue, c))
  const receipt = await batch(f.accounts.owner, calls)
  const posted = Events.venue(receipt.logs, { venue, eventName: 'Posted' }).map(
    (e) => [Number(e.args.pairIndex), e.args.hotWord],
  )
  expect(posted, `${v.name}: Posted`).toStrictEqual(v.posted)
  expect(
    PostOutcome.fromBatch(calls, receipt.logs).map((o) => ({
      accepted: o.accepted.map((e) => [e.pairIndex, e.sequence]),
      skipped: o.skipped.map((e) => [e.pairIndex, e.sequence]),
    })),
    `${v.name}: outcomes`,
  ).toStrictEqual(v.outcomes)
}

/** The vector's own bytes, as entries: the call must carry exactly `packed`. */
function unpack(packed: Hex) {
  const entries = []
  for (let at = 2; at < packed.length; at += 68) {
    entries.push({
      pairIndex: Number.parseInt(packed.slice(at, at + 4), 16),
      word: `0x${packed.slice(at + 4, at + 68)}` as Hex,
    })
  }
  return entries
}

describe('shared vectors on the deployed core', () => {
  test(`quotes and fills every quotes case as the reference does (${data.quotes.length} cases)`, async () => {
    let fills = 0
    for (const c of data.quotes) fills += await replayQuotes(c)
    if (committed) expect(fills >= 40, `${fills} fills`).toBeTruthy()
  })

  test(`stores and refills every post batch as the reference does (${data.posts.length} batches)`, async () => {
    let replayed = 0
    for (const p of data.posts) if (await replayPost(p)) replayed++
    if (committed) expect(replayed >= 6, `${replayed} replayed`).toBeTruthy()
  })

  test(`emits the reference's Posted events for every batch of post calls, and PostOutcome reads them (${data.outcomes.length} batches)`, async () => {
    for (const v of data.outcomes) await replayOutcome(v)
  })
})
