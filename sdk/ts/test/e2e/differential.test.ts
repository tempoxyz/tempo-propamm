// Differential fuzz against the deployed venue: random canonical shapes, hot words and size units, fills that walk
// consumption across levels to depth and past it, re-posts with and without refills, sides switched off, binding
// inventory and expiry. Before every fill, random probes must get the same answer from Quote.local (one snapshot), from
// the independent BigInt reference (contracts/test/vectors/ladder-reference.mjs, `venueQuote`) and from venue.quote at
// the snapshot's block; every fill, through the Settler at exactly that quote, must match its amounts and consumption.
//
// PROPAMM_FUZZ_SEED picks the seed (printed in every failure), PROPAMM_FUZZ_RUNS the number of cases (default 40).
import type { Address } from 'viem'
import { Actions as TempoActions } from 'viem/tempo'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import {
  Abis,
  Actions,
  Book,
  Errors,
  Fees,
  type HotWord,
  Info,
  Price,
  Quote,
  Sequencer,
  Shape,
  Snapshot,
  Venue,
} from '../../src/index.js'
import { readMany } from '../../src/internal/read.js'
import { referenceArgs } from '../vectors.js'
import { type Fixture, mined, setupPair, start, swap } from './fixture.js'

type Reference = {
  venueQuote(
    state: {
      sizeUnit: bigint
      timestamp: bigint
      hot: bigint
      shapes: Map<number, readonly bigint[]>
      consumed: { bids: bigint; asks: bigint }
      inventory: { base: bigint; quote: bigint }
    },
    request: { baseIn: boolean; exactIn: boolean; amount: bigint },
  ):
    | { amountIn: bigint; amountOut: bigint; baseFilled: bigint }
    | { error: string; args: unknown[] }
}
const ref = (await import(
  new URL(
    '../../../../contracts/test/vectors/ladder-reference.mjs',
    import.meta.url,
  ).href
)) as Reference

const SEED = BigInt(process.env.PROPAMM_FUZZ_SEED ?? '0x646966666572')
const RUNS = Number(process.env.PROPAMM_FUZZ_RUNS ?? '40')
const FILLS = 8
const PROBES = 10
const FUND = 10n ** 16n

let f: Fixture
beforeAll(async () => {
  f = await start()
  const { owner, agent } = f.accounts
  await Actions.venue.approveAgentSync(f.client, {
    venue: f.venue,
    agent: agent.address,
    account: owner,
  })
  await TempoActions.token.transferSync(f.client, {
    token: f.base,
    to: f.venue,
    amount: FUND,
    account: owner,
  })
  await TempoActions.token.transferSync(f.client, {
    token: f.quote,
    to: f.venue,
    amount: FUND,
    account: owner,
  })
})
afterAll(async () => f?.stop())

/** The venue's balance of a token: viem/tempo's own read. */
const balance = async (token: Address) =>
  (await TempoActions.token.getBalance(f.client, { token, account: f.venue }))
    .amount

function rng(seed: bigint) {
  let s = seed & 0xffff_ffff_ffff_ffffn
  const next = () => {
    s = (s + 0x9e37_79b9_7f4a_7c15n) & 0xffff_ffff_ffff_ffffn
    let z = s
    z = ((z ^ (z >> 30n)) * 0xbf58_476d_1ce4_e5b9n) & 0xffff_ffff_ffff_ffffn
    z = ((z ^ (z >> 27n)) * 0x94d0_49bb_1331_11ebn) & 0xffff_ffff_ffff_ffffn
    return z ^ (z >> 31n)
  }
  const between = (lo: bigint, hi: bigint) =>
    hi <= lo ? lo : lo + (((next() << 64n) | next()) % (hi - lo + 1n))
  const int = (lo: number, hi: number) =>
    Number(between(BigInt(lo), BigInt(hi)))
  const magnitude = (max: bigint) => {
    const bits = between(1n, BigInt(max.toString(2).length))
    const hi = (1n << bits) - 1n
    return between(1n, hi < max ? hi : max)
  }
  return {
    between,
    int,
    magnitude,
    chance: (n: number) => int(0, n - 1) === 0,
    pick: <T>(xs: readonly T[]) => xs[int(0, xs.length - 1)] as T,
  }
}

type Hot = Omit<HotWord.HotWord, 'sequence' | 'shapeId' | 'validUntil'>

describe('differential fuzz vs the deployed venue', () => {
  test(`agrees on ${RUNS} cases (seed ${SEED})`, async () => {
    const r = rng(SEED)
    const { owner, agent, taker } = f.accounts
    const stats = {
      probes: 0,
      ok: 0,
      fills: 0,
      errors: {} as Record<string, number>,
    }
    const blockTime = async () =>
      (await Snapshot.get(f.client, { venue: f.venue, pairs: [] })).block
        .timestamp

    for (let run = 0; run < RUNS; run++) {
      const where = `seed ${SEED} case ${run}`
      // A new pair per case: a random size unit, ladder and hot word.
      const sizeUnit = r.pick([
        1n,
        1_000n,
        1_000_000n,
        1_000_000_000n,
        r.magnitude(10n ** 9n),
      ])
      const { pairIndex } = mined(
        await Actions.venue.addPairSync(f.client, {
          venue: f.venue,
          base: f.base,
          quote: f.quote,
          sizeUnit,
          account: owner,
        }),
      )
      await Actions.venue.setMembersSync(f.client, {
        venue: f.venue,
        pairIndex,
        sponsorId: 0n,
        accounts: [taker.address],
        allowed: true,
        account: owner,
      })
      await Actions.venue.setPairAccessSync(f.client, {
        venue: f.venue,
        pairIndex,
        mode: 'listed',
        account: owner,
      })
      const maxSize = BigInt(
        Math.max(1, Math.min(2 ** 32 - 1, Number(10n ** 13n / sizeUnit))),
      )
      const ladder = () => {
        const levels: Shape.Level[] = []
        let spread = 0
        for (let i = r.int(r.chance(8) ? 0 : 1, 10); i > 0; i--) {
          spread = Math.min(
            65_535,
            spread + (r.chance(3) ? 0 : r.int(0, r.chance(5) ? 5_000 : 200)),
          )
          levels.push({
            size: Number(
              r.chance(10)
                ? 1n
                : r.magnitude(r.chance(10) ? 0xffff_ffffn : maxSize),
            ),
            spread,
          })
        }
        return levels
      }
      const shape = Shape.from({ bids: ladder(), asks: ladder() })
      const shapeId = r.int(0, 255)
      await Actions.venue.setShapeSync(f.client, {
        venue: f.venue,
        pairIndex,
        shapeId,
        shape,
        account: agent,
      })
      const randomHot = (): Hot => ({
        mid: r.chance(10)
          ? r.magnitude(Price.parse('1000000'))
          : Price.parse('0.5') + r.between(0n, Price.parse('1.5')),
        bidWiden: r.chance(3)
          ? 0
          : r.chance(10)
            ? r.int(60_000, 65_535)
            : r.int(0, 500),
        askWiden: r.chance(3) ? 0 : r.int(0, 500),
        widthScale: r.chance(3) ? 1000 : r.int(0, 3000),
        depthScale: r.chance(4) ? 1000 : r.int(1, 3000),
        sides: 'both',
      })
      const sequencer = Sequencer.from([[pairIndex, 1]])
      let hot = randomHot()
      let validUntil = Number(await blockTime()) + 3_600
      const post = async (refill: HotWord.Sides) => {
        await Actions.maker.orderSync(f.client, {
          venue: f.venue,
          order: {
            pairIndex,
            ...hot,
            shapeId,
            validUntil,
            sequence: Sequencer.next(sequencer, pairIndex),
            refill,
          },
          account: agent,
        })
      }
      await post('both')
      let expired = false

      for (let step = 0; step < FILLS; step++) {
        if (expired) {
          validUntil = Number(await blockTime()) + 3_600
          await post('neither')
          expired = false
        }
        // Now and then: a re-post without a refill, a side or the depth switched off, a binding withdrawal, expiry.
        if (r.chance(5)) {
          hot = { ...randomHot(), sides: hot.sides }
          await post(
            r.chance(3) ? r.pick(['bids', 'asks', 'both'] as const) : 'neither',
          )
        }
        if (r.chance(8)) {
          hot = {
            ...hot,
            ...(r.chance(2)
              ? { sides: r.pick(['bids', 'asks', 'neither'] as const) }
              : { depthScale: 0 }),
          }
          await post('neither')
        } else if (hot.sides !== 'both' || hot.depthScale === 0) {
          hot = { ...hot, sides: 'both', depthScale: hot.depthScale || 1000 }
          await post('neither')
        }
        if (r.chance(10)) {
          const token = r.pick([f.base, f.quote])
          const held = await balance(token)
          if (held > 1n) {
            await Actions.venue.withdrawSync(f.client, {
              venue: f.venue,
              token,
              to: owner.address,
              amount: held - r.between(0n, held / 1000n + 1n),
              account: owner,
            })
          }
        }
        if (r.chance(12)) {
          await f.increaseTime(
            Math.max(1, validUntil - Number(await blockTime()) + 1),
          )
          expired = true
        }

        const snapshot = await Snapshot.get(f.client, {
          venue: f.venue,
          pairs: [pairIndex],
        })
        const pair = Snapshot.pair(snapshot, pairIndex)
        const probes = Array.from({ length: PROBES }, () => {
          const baseIn = r.chance(2)
          const exactIn = r.chance(2)
          // The posted ladder's depth, live or not, so probes reach depth on an expired or disabled side too.
          const remaining = Book.ladder(pair, baseIn ? 'bids' : 'asks').reduce(
            (sum, row) => sum + row.remaining,
            0n,
          )
          const baseTarget = baseIn === exactIn
          const scale = baseTarget
            ? remaining
            : (remaining * pair.hot.mid) / Price.one
          const amount = r.chance(20)
            ? 0n
            : r.chance(3)
              ? r.magnitude(1n << 70n)
              : r.chance(2)
                ? scale + r.between(0n, 4n) - 2n
                : r.between(1n, scale + 1n)
          const [tokenIn, tokenOut] = baseIn
            ? [pair.base, pair.quote]
            : [pair.quote, pair.base]
          return {
            pairIndex,
            tokenIn,
            tokenOut,
            exactIn,
            amount: amount < 0n ? 0n : amount,
            // venue.quote below runs in an eth_call without fee fields: priority fee 0.
            priorityFee: 0n,
          }
        })
        const chain = await readMany(
          f.client,
          probes.map((q) => ({
            address: f.venue,
            abi: Abis.venueAbi,
            functionName: 'quote',
            args: [q.pairIndex, q.tokenIn, q.tokenOut, q.amount, q.exactIn],
          })),
          { blockNumber: snapshot.block.number },
        )
        const state = {
          sizeUnit: pair.sizeUnit,
          timestamp: snapshot.block.timestamp,
          hot: BigInt(pair.hotWord),
          shapes: new Map([[pair.hot.shapeId, pair.shapeWords]]),
          consumed: pair.consumed,
          inventory: pair.inventory,
        }
        probes.forEach((probe, i) => {
          const local = Quote.local(snapshot, probe)
          const reference = ref.venueQuote(state, {
            baseIn: probe.tokenIn === pair.base,
            exactIn: probe.exactIn,
            amount: probe.amount,
          })
          const onchain = chain[i]
          const label = `${where} step ${step} probe ${i}: ${JSON.stringify(probe, (_, v) => (typeof v === 'bigint' ? v.toString() : v))}`
          stats.probes++
          if (onchain?.status === 'success') {
            const [amountIn, amountOut] = onchain.result as readonly [
              bigint,
              bigint,
            ]
            assert(
              local.ok,
              `${label}: venue quoted ${amountIn}/${amountOut}, local reverted ${local.ok ? '' : local.error.errorName}`,
            )
            expect(local.amountIn, `${label}: amountIn`).toBe(amountIn)
            expect(local.amountOut, `${label}: amountOut`).toBe(amountOut)
            assert(
              !('error' in reference),
              `${label}: venue quoted, the reference reverted ${'error' in reference ? reference.error : ''}`,
            )
            expect(
              [reference.amountIn, reference.amountOut],
              `${label}: reference amounts`,
            ).toStrictEqual([amountIn, amountOut])
            stats.ok++
          } else {
            const decoded = Errors.decode(onchain?.error)
            assert(
              !local.ok,
              `${label}: venue reverted ${decoded?.errorName}, local quoted ${local.ok ? local.amountOut : ''}`,
            )
            expect(local.error.errorName, label).toBe(decoded?.errorName)
            expect(local.error.args, `${label}: args`).toStrictEqual(
              decoded?.args,
            )
            assert(
              'error' in reference,
              `${label}: venue reverted ${decoded?.errorName}, the reference quoted`,
            )
            expect(reference.error, `${label}: reference error`).toBe(
              decoded?.errorName,
            )
            expect(
              reference.args.map(String),
              `${label}: reference args`,
            ).toStrictEqual(
              referenceArgs(decoded?.args ?? [], {
                base: pair.base,
                quote: pair.quote,
              }),
            )
            stats.errors[local.error.errorName] =
              (stats.errors[local.error.errorName] ?? 0) + 1
          }
        })

        // Fill one quotable probe through the Settler at exactly its local quote; its event and the new consumption must
        // match.
        const fillable = probes.find((q) => {
          const l = Quote.local(snapshot, q)
          return l.ok && l.amountIn < 10n ** 16n
        })
        if (!fillable) continue
        const quoted = Quote.local(snapshot, fillable)
        assert(quoted.ok)
        const { fill } = await swap(f, {
          venue: f.venue,
          ...fillable,
          amountIn: quoted.amountIn,
          amountOut: quoted.amountOut,
          account: taker,
        })
        assert(fill, `${where} step ${step}: no Fill`)
        expect(fill.amountIn, `${where} step ${step}: fill amountIn`).toBe(
          quoted.amountIn,
        )
        expect(fill.amountOut, `${where} step ${step}: fill amountOut`).toBe(
          quoted.amountOut,
        )
        expect(
          await Info.consumed(f.client, { venue: f.venue, pairIndex }),
          `${where} step ${step}: consumed`,
        ).toStrictEqual(quoted.consumedAfter)
        stats.fills++
      }
      // Refund what withdrawals took, for the next case.
      for (const token of [f.base, f.quote] as Address[]) {
        const held = await balance(token)
        if (held < FUND)
          await TempoActions.token.transferSync(f.client, {
            token,
            to: f.venue,
            amount: FUND - held,
            account: owner,
          })
      }
    }

    if (process.env.PROPAMM_FUZZ_VERBOSE) console.log(stats)
    expect(stats.fills >= RUNS * 2, JSON.stringify(stats)).toBeTruthy()
    for (const name of ['InsufficientDepth', 'SideDisabled', 'ZeroAmount'])
      expect(
        (stats.errors[name] ?? 0) > 0,
        `${name} never probed: ${JSON.stringify(stats)}`,
      ).toBeTruthy()
  })

  test('agrees on the fee cap: an over-cap probe reverts with the same arguments, locally and onchain', async () => {
    const { agent, taker } = f.accounts
    const { pairIndex } = await setupPair(f, { fund: 0n })
    await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
      venue: f.venue,
      cap: Fees.gwei,
      account: agent,
    })
    const snapshot = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [pairIndex],
    })
    const pair = Snapshot.pair(snapshot, pairIndex)
    const request = {
      pairIndex,
      tokenIn: pair.quote,
      tokenOut: pair.base,
      amount: 1_000n,
      exactIn: false,
    }
    for (const tip of [Fees.gwei, 2n * Fees.gwei]) {
      const local = Quote.local(snapshot, { ...request, priorityFee: tip })
      const fees = Fees.feeFields(snapshot.block.baseFeePerGas ?? 0n, tip)
      const onchain = await Info.quote(f.client, {
        venue: f.venue,
        ...request,
        ...fees,
        account: taker.address,
        blockNumber: snapshot.block.number,
      }).then(
        (q) => ({ ok: true as const, ...q }),
        (e: unknown) => ({ ok: false as const, error: Errors.decode(e) }),
      )
      if (tip <= Fees.gwei) {
        assert(local.ok && onchain.ok, 'at the cap')
        expect([onchain.amountIn, onchain.amountOut]).toStrictEqual([
          local.amountIn,
          local.amountOut,
        ])
      } else {
        assert(!local.ok && !onchain.ok, 'over the cap')
        expect(local.error).toStrictEqual({
          errorName: 'TakerPriorityFeeTooHigh',
          args: [2n * Fees.gwei, Fees.gwei],
        })
        expect(onchain.error?.errorName).toBe(local.error.errorName)
        expect(onchain.error?.args).toStrictEqual(local.error.args)
      }
    }
    await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
      venue: f.venue,
      cap: Venue.noPriorityFeeCap,
      account: agent,
    })
  })
})
