// Ladder's bounds: every input held to the width the venue stores it in, so no out-of-range value prices a fill the
// chain could never produce, and the edges of each width still price exactly as the BigInt reference does.
import { maxUint128 } from 'viem'
import { describe, expect, test } from 'vitest'
import { Errors, type HotWord, Ladder, Price, Shape } from '../src/index.js'

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
}
const ref = (await import(
  new URL(
    '../../../contracts/test/vectors/ladder-reference.mjs',
    import.meta.url,
  ).href
)) as Reference

type Hot = Pick<
  HotWord.HotWord,
  'mid' | 'bidWiden' | 'askWiden' | 'widthScale' | 'depthScale'
>
const hot = (over: Partial<Hot> = {}): Hot => ({
  mid: Price.one,
  bidWiden: 0,
  askWiden: 0,
  widthScale: 1000,
  depthScale: 1000,
  ...over,
})

/** What `fn` throws. */
function thrown(fn: () => unknown): Errors.BaseError {
  try {
    fn()
  } catch (error) {
    if (error instanceof Errors.BaseError) return error
    throw error
  }
  throw new Error('expected a throw')
}

describe('the bid floor', () => {
  test('is reached by spread x widthScale, within the hot word: widen alone stops short', () => {
    // 1999 x 50,000 + 40 x 1000 = 99,990,000: level 1 is 1e4 above the floor; 2000 x 50,000 = 1e8 reaches it.
    const [w0, w1] = Shape.encodeSide([
      { size: 10, spread: 1999 },
      { size: 10, spread: 2000 },
    ])
    const deep = Ladder.curve(
      hot({ widthScale: 50_000, bidWiden: 40 }),
      1n,
      true,
    )
    expect(Ladder.factor(deep, 1999)).toBe(10_000n)
    expect(Ladder.factor(deep, 2000)).toBe(0n)
    expect(Ladder.depth(deep, w0, w1), 'level 2 is at the floor').toBe(10n)
    expect(Ladder.fill(deep, w0, w1, true, 11n, 0n)).toStrictEqual({
      ok: false,
      error: 'InsufficientDepth',
    })
    expect(Ladder.fill(deep, w0, w1, true, 10n, 0n)).toStrictEqual({
      ok: false,
      error: 'ZeroFill',
    })
    // The widest widening a hot word carries, 6.5535%, leaves a spread-0 bid far above the floor.
    const widest = Ladder.curve(hot({ bidWiden: 65_535 }), 1n, true)
    expect(Ladder.factor(widest, 0)).toBe(Ladder.factorOne - 65_535_000n)
    // The asks have no floor.
    const asks = Ladder.curve(
      hot({ widthScale: 65_535, askWiden: 65_535 }),
      1n,
      false,
    )
    expect(Ladder.factor(asks, 65_535)).toBe(
      Ladder.factorOne + 65_535n * 65_535n + 65_535_000n,
    )
  })
})

describe('the widths the venue stores', () => {
  test('price exactly as the reference at each edge', () => {
    const levels: [bigint, bigint][] = [
      [0xffff_ffffn, 0n],
      [0xffff_ffffn, 65_535n],
    ]
    const [w0, w1] = Shape.encodeSide(
      levels.map(([size, spread]) => ({
        size: Number(size),
        spread: Number(spread),
      })),
    )
    const edges = {
      mid: (1n << 96n) - 1n,
      bidWiden: 65_535n,
      askWiden: 65_535n,
      widthScale: 65_535n,
      depthScale: 65_535n,
    }
    const sizeUnit = (1n << 64n) - 1n
    for (const [baseIn, exactIn] of [
      [true, true],
      [true, false],
      [false, true],
      [false, false],
    ] as const) {
      for (const [amount, consumed] of [
        [1n, 0n],
        [maxUint128, 0n],
        [1n, (1n << 120n) - 1n],
        [1_000_000n, 1n << 100n],
      ] as const) {
        const curve = Ladder.curve(
          {
            mid: edges.mid,
            bidWiden: Number(edges.bidWiden),
            askWiden: Number(edges.askWiden),
            widthScale: Number(edges.widthScale),
            depthScale: Number(edges.depthScale),
          },
          sizeUnit,
          baseIn,
        )
        const got = Ladder.fill(curve, w0, w1, exactIn, amount, consumed)
        const want = ref.priceLeg({
          hot: edges,
          sizeUnit,
          baseIn,
          exactIn,
          levels,
          amount,
          consumed,
        })
        const label = `${baseIn} ${exactIn} ${amount} ${consumed}`
        if ('error' in want)
          expect(got, label).toStrictEqual({ ok: false, error: want.error })
        else expect(got, label).toStrictEqual({ ok: true, ...want })
      }
    }
  })

  test('refuse a hot-word field, mid or size unit out of its width in curve', () => {
    for (const [over, name] of [
      [{ bidWiden: 65_536 }, 'bidWiden'],
      [{ bidWiden: 100_000 }, 'bidWiden'],
      [{ widthScale: 65_536 }, 'widthScale'],
      [{ depthScale: -1 }, 'depthScale'],
      [{ depthScale: 1.5 }, 'depthScale'],
    ] as const) {
      expect(() => Ladder.curve(hot(over), 1n, true), name).toThrow(
        expect.objectContaining({
          name: 'InvalidHotWordError',
          parameter: name,
        }),
      )
    }
    // Only the walked side's widening is read.
    expect(Ladder.curve(hot({ askWiden: 65_536 }), 1n, true).widen).toBe(0)
    expect(() => Ladder.curve(hot({ mid: 1n << 96n }), 1n, true)).toThrow(
      Errors.InvalidPriceError,
    )
    for (const sizeUnit of [-1n, 1n << 64n, 1 as never]) {
      expect(() => Ladder.curve(hot(), sizeUnit, true)).toThrow(
        expect.objectContaining({ parameter: 'sizeUnit' }),
      )
    }
    expect(() => Ladder.curve(hot(), 1n, 1 as never)).toThrow(
      expect.objectContaining({ parameter: 'baseIn' }),
    )
  })

  test('refuse a hand-built curve, consumption, amount or side fill could never see', () => {
    const [w0, w1] = Shape.encodeSide([{ size: 10, spread: 0 }])
    const curve = Ladder.curve(hot(), 1n, true)
    const fill =
      (
        change: Partial<Ladder.Curve> = {},
        args: Partial<{
          w0: bigint
          w1: bigint
          exactIn: boolean
          amount: bigint
          consumed: bigint
        }> = {},
      ) =>
      () =>
        Ladder.fill(
          { ...curve, ...change },
          args.w0 ?? w0,
          args.w1 ?? w1,
          args.exactIn ?? true,
          args.amount ?? 1n,
          args.consumed ?? 0n,
        )
    // In range, every one of these prices.
    expect(fill()()).toStrictEqual({
      ok: true,
      amountIn: 1n,
      amountOut: 1n,
      baseFilled: 1n,
    })
    const refusals = [
      fill({ widen: 1 << 16 }),
      fill({ widthScale: 1 << 16 }),
      fill({ depthScale: -1 }),
      fill({ depthScale: 1n as never }),
      fill({ sizeUnit: 0n }),
      fill({ sizeUnit: 1n << 64n }),
      fill({ mid: 0n }),
      fill({ mid: 1n << 96n }),
      fill({ bid: 'yes' as never }),
      fill({}, { consumed: 1n << 120n }),
      fill({}, { consumed: -1n }),
      fill({}, { amount: 0n }),
      fill({}, { amount: maxUint128 + 1n }),
      fill({}, { exactIn: 1 as never }),
      // A spread on level 5's empty neighbour, a second word without level 5, a decreasing spread, reserved bits.
      fill({}, { w0: w0 | (1n << 80n) }),
      fill({}, { w1: 1n }),
      fill(
        {},
        { w0: Shape.encodeSide([{ size: 1, spread: 9 }])[0] | (1n << 48n) },
      ),
      fill({}, { w0: w0 | (1n << 255n) }),
      fill({}, { w0: -1n }),
      fill({}, { w1: 1n << 256n }),
    ].map((fn) => {
      const e = thrown(fn) as Errors.BaseError & { parameter?: unknown }
      return `${e.name} ${String(e.parameter)}: ${e.shortMessage}`
    })
    expect(refusals).toMatchInlineSnapshot(`
      [
        "InvalidHotWordError curve.widen: curve.widen must be an integer in [0, 65535], got 65536",
        "InvalidHotWordError curve.widthScale: curve.widthScale must be an integer in [0, 65535], got 65536",
        "InvalidHotWordError curve.depthScale: curve.depthScale must be an integer in [0, 65535], got -1",
        "InvalidHotWordError curve.depthScale: curve.depthScale must be an integer in [0, 65535], got 1n",
        "InvalidArgumentError curve.sizeUnit: curve.sizeUnit must be at least 1: addPair refuses 0, got 0n",
        "InvalidArgumentError curve.sizeUnit: curve.sizeUnit must be a bigint in [0, 2^64 - 1], got 18446744073709551616n",
        "InvalidPriceError curve.mid: a fill needs a nonzero mid: the pair was never posted",
        "InvalidPriceError curve.mid: curve.mid must be a uint96 bigint (quote per base, scaled by 1e18), got 79228162514264337593543950336n",
        "InvalidArgumentError curve.bid: curve.bid must be a boolean, got "yes"",
        "InvalidArgumentError consumed: consumed must be a bigint in [0, 2^120 - 1], got 1329227995784915872903807060280344576n",
        "InvalidArgumentError consumed: consumed must be a bigint in [0, 2^120 - 1], got -1n",
        "AmountOutOfRangeError amount: amount must be in [1, 2^128 - 1], got 0n",
        "AmountOutOfRangeError amount: amount must be in [1, 2^128 - 1], got 340282366920938463463374607431768211456n",
        "InvalidArgumentError exactIn: exactIn must be a boolean, got 1",
        "InvalidShapeError w0: the side's words are not its canonical encoding (ShapeWord reason 2): setShape never stores them",
        "InvalidShapeError w0: the side's words are not its canonical encoding (ShapeWord reason 2): setShape never stores them",
        "InvalidShapeError w0: the side's words are not its canonical encoding (ShapeWord reason 3): setShape never stores them",
        "InvalidShapeError w0: the side's words are not its canonical encoding (ShapeWord reason 1): setShape never stores them",
        "InvalidShapeError w0: w0 must be a bigint in [0, 2^256 - 1], got -1n",
        "InvalidShapeError w1: w1 must be a bigint in [0, 2^256 - 1], got 115792089237316195423570985008687907853269984665640564039457584007913129639936n",
      ]
    `)
  })

  test('refuse a spread, size, consumption or side out of its width in the helpers', () => {
    const asks = Ladder.curve(hot(), 1n, false)
    expect(() => Ladder.factor(asks, 1 << 16)).toThrow(
      expect.objectContaining({
        name: 'InvalidShapeError',
        parameter: 'spread',
      }),
    )
    expect(() => Ladder.factor({ ...asks, widen: -1 }, 0)).toThrow(
      expect.objectContaining({
        name: 'InvalidHotWordError',
        parameter: 'curve.widen',
      }),
    )
    expect(() => Ladder.effectiveSize(asks, 2 ** 32)).toThrow(
      expect.objectContaining({
        name: 'InvalidShapeError',
        parameter: 'rawSize',
      }),
    )
    // A size unit of 0 is no pair's, for every helper, as for fill.
    for (const run of [
      () => Ladder.curve(hot(), 0n, true),
      () => Ladder.factor({ ...asks, sizeUnit: 0n }, 0),
      () => Ladder.effectiveSize({ ...asks, sizeUnit: 0n }, 1),
      () => Ladder.depth({ ...asks, sizeUnit: 0n }, 0n, 0n),
    ])
      expect(run).toThrow(
        expect.objectContaining({
          name: 'InvalidArgumentError',
          value: 0n,
        }),
      )
    expect(() => Ladder.depth(asks, 0n, 1n)).toThrow(
      expect.objectContaining({ name: 'InvalidShapeError', reason: 2 }),
    )
    expect(() => Ladder.applyFill({ bids: -1n, asks: 0n }, true, 1n)).toThrow(
      expect.objectContaining({ parameter: 'consumed.bids' }),
    )
    expect(() =>
      Ladder.applyFill({ bids: 0n, asks: 0n }, true, 1n << 120n),
    ).toThrow(expect.objectContaining({ parameter: 'baseFilled' }))
    expect(() =>
      Ladder.applyRefill({ bids: 0n, asks: 0n }, 'all' as never),
    ).toThrow(expect.objectContaining({ parameter: 'refill' }))
    expect(Ladder.applyRefill({ bids: 3n, asks: 4n }, 'both')).toStrictEqual({
      bids: 0n,
      asks: 0n,
    })
  })
})
