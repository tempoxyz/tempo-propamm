// Ladder.fill (a port of LadderMath's level walk) against ladder-reference.mjs (an independent value-function model
// with binary search), imported straight from contracts/test/vectors, on seeded random cases across the full bounds.

import { maxUint128 } from 'viem'
import { assert, describe, expect, test } from 'vitest'
import { Ladder, Shape } from '../src/index.js'

type Reference = {
  priceLeg(p: {
    hot: {
      mid: bigint
      bidWiden: bigint
      askWiden: bigint
      widthScale: bigint
      depthScale: bigint
    }
    sizeUnit: bigint
    baseIn: boolean
    exactIn: boolean
    levels: [bigint, bigint][]
    amount: bigint
    consumed: bigint
  }):
    | { amountIn: bigint; amountOut: bigint; baseFilled: bigint }
    | { error: string }
  book(
    hot: unknown,
    sizeUnit: bigint,
    baseIn: boolean,
    levels: [bigint, bigint][],
  ): { depth: bigint; price: bigint }[]
  remainingBook(
    levels: { depth: bigint; price: bigint }[],
    consumed: bigint,
  ): { depth: bigint; price: bigint }[]
  totalDepth(levels: { depth: bigint; price: bigint }[]): bigint
  value(levels: { depth: bigint; price: bigint }[], base: bigint): bigint
}
const ref = (await import(
  new URL(
    '../../../contracts/test/vectors/ladder-reference.mjs',
    import.meta.url,
  ).href
)) as Reference

/** splitmix64, as the reference's generator. */
function rng(seed: bigint) {
  let s = seed & 0xffff_ffff_ffff_ffffn
  const next = () => {
    s = (s + 0x9e37_79b9_7f4a_7c15n) & 0xffff_ffff_ffff_ffffn
    let z = s
    z = ((z ^ (z >> 30n)) * 0xbf58_476d_1ce4_e5b9n) & 0xffff_ffff_ffff_ffffn
    z = ((z ^ (z >> 27n)) * 0x94d0_49bb_1331_11ebn) & 0xffff_ffff_ffff_ffffn
    return z ^ (z >> 31n)
  }
  const between = (lo: bigint, hi: bigint) => {
    if (hi <= lo) return lo
    let r = 0n
    for (let bits = 0n; bits < 192n; bits += 64n) r = (r << 64n) | next()
    return lo + (r % (hi - lo + 1n))
  }
  /** Log-uniform in [1, max]: every magnitude is as likely. */
  const magnitude = (max: bigint) => {
    const bits = between(1n, BigInt(max.toString(2).length))
    const hi = (1n << bits) - 1n
    return between(1n, hi < max ? hi : max)
  }
  return {
    between,
    magnitude,
    chance: (n: number) => between(0n, BigInt(n - 1)) === 0n,
  }
}

const SEED = BigInt(process.env.PROPAMM_FUZZ_SEED ?? '0x70726f70616d6d')
const RUNS = Number(process.env.PROPAMM_FUZZ_RUNS ?? '20000')

describe('Ladder.fill vs the BigInt reference', () => {
  test(`agrees on ${RUNS} seeded cases (seed ${SEED})`, () => {
    const r = rng(SEED)
    const directions: [boolean, boolean][] = [
      [true, true],
      [false, false],
      [false, true],
      [true, false],
    ]
    const counts: Record<string, number> = {}
    for (let run = 0; run < RUNS; run++) {
      const pick16 = () =>
        r.chance(4) ? r.between(0n, 65_535n) : r.between(0n, 2_000n)
      const hot = {
        mid: r.chance(8) ? (1n << 96n) - 1n : r.magnitude((1n << 96n) - 1n),
        bidWiden: r.chance(3) ? 0n : pick16(),
        askWiden: r.chance(3) ? 0n : pick16(),
        widthScale: r.chance(3) ? 1000n : r.between(0n, 65_535n),
        depthScale: r.chance(8) ? 65_535n : r.between(1n, 5_000n),
      }
      const sizeUnit = r.chance(8)
        ? (1n << 64n) - 1n
        : r.magnitude((1n << 64n) - 1n)
      const count = Number(r.between(0n, 10n))
      const levels: [bigint, bigint][] = []
      let spread = 0n
      for (let i = 0; i < count; i++) {
        spread += r.chance(3) ? 0n : r.between(0n, r.chance(4) ? 20_000n : 500n)
        if (spread > 65_535n) spread = 65_535n
        levels.push([r.chance(10) ? 1n : r.magnitude(0xffff_ffffn), spread])
      }
      const [baseIn, exactIn] = directions[run % 4] as [boolean, boolean]
      const book = ref.book(hot, sizeUnit, baseIn, levels)
      const depth = ref.totalDepth(book)
      const consumed = r.chance(3)
        ? 0n
        : r.chance(10)
          ? depth + r.between(0n, 10n)
          : r.between(0n, depth)
      const left = ref.remainingBook(book, consumed)
      const leftDepth = ref.totalDepth(left)
      const baseTarget = baseIn === exactIn
      // Amounts: random magnitudes, and the edges of what the book left can cover.
      const edge = baseTarget
        ? leftDepth
        : ref.value(left, leftDepth) / Ladder.denominator
      let amount = r.chance(2)
        ? r.magnitude(maxUint128)
        : edge + r.between(0n, 4n) - 2n
      if (amount < 1n) amount = 1n
      if (amount > maxUint128) amount = maxUint128

      const expected = ref.priceLeg({
        hot,
        sizeUnit,
        baseIn,
        exactIn,
        levels,
        amount,
        consumed,
      })
      const [b0, b1] = Shape.encodeSide(
        levels.map(([size, sp]) => ({
          size: Number(size),
          spread: Number(sp),
        })),
      )
      const curve = Ladder.curve(
        {
          mid: hot.mid,
          bidWiden: Number(hot.bidWiden),
          askWiden: Number(hot.askWiden),
          widthScale: Number(hot.widthScale),
          depthScale: Number(hot.depthScale),
        },
        sizeUnit,
        baseIn,
      )
      const got = Ladder.fill(curve, b0, b1, exactIn, amount, consumed)
      const context = () =>
        JSON.stringify(
          { run, hot, sizeUnit, baseIn, exactIn, levels, amount, consumed },
          (_, v) => (typeof v === 'bigint' ? v.toString() : v),
        )
      if ('error' in expected) {
        expect(got, context()).toStrictEqual({
          ok: false,
          error: expected.error,
        })
        counts[expected.error] = (counts[expected.error] ?? 0) + 1
        continue
      }
      assert(
        got.ok,
        `${context()}: expected ok, got ${got.ok ? '' : got.error}`,
      )
      expect(got.amountIn, `${context()}: amountIn`).toBe(expected.amountIn)
      expect(got.amountOut, `${context()}: amountOut`).toBe(expected.amountOut)
      expect(got.baseFilled, `${context()}: baseFilled`).toBe(
        expected.baseFilled,
      )
      counts.ok = (counts.ok ?? 0) + 1

      // One rounding, toward the maker, by less than one unit of the rounded token.
      const v = (b: bigint) => ref.value(left, b)
      const scaled = (x: bigint) => x * Ladder.denominator
      if (baseIn && exactIn) {
        const exact = v(amount)
        expect(
          scaled(got.amountOut) <= exact && exact < scaled(got.amountOut + 1n),
          `${context()}: sell exact in floors`,
        ).toBeTruthy()
      } else if (!baseIn && !exactIn) {
        const exact = v(amount)
        expect(
          scaled(got.amountIn) >= exact && exact > scaled(got.amountIn - 1n),
          `${context()}: buy exact out ceils`,
        ).toBeTruthy()
      } else if (!baseIn && exactIn) {
        expect(
          v(got.amountOut) <= scaled(amount),
          `${context()}: pay quote never overpays`,
        ).toBeTruthy()
        if (got.amountOut < leftDepth)
          expect(
            v(got.amountOut + 1n) > scaled(amount),
            `${context()}: pay quote buys the most`,
          ).toBeTruthy()
      } else {
        expect(
          v(got.amountIn) >= scaled(amount),
          `${context()}: want quote covers`,
        ).toBeTruthy()
        expect(
          v(got.amountIn - 1n) < scaled(amount),
          `${context()}: want quote takes the least`,
        ).toBeTruthy()
      }
    }
    if (process.env.PROPAMM_FUZZ_VERBOSE) console.log(counts)
    // Every outcome is exercised.
    expect((counts.ok ?? 0) > RUNS / 4, JSON.stringify(counts)).toBeTruthy()
    expect(
      (counts.InsufficientDepth ?? 0) > RUNS / 50,
      JSON.stringify(counts),
    ).toBeTruthy()
    expect((counts.ZeroFill ?? 0) > 0, JSON.stringify(counts)).toBeTruthy()
  })
})
