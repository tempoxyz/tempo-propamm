// Quote.local's precondition order and the ladder's edge cases on hand-built snapshots. The e2e differential suite holds
// the same functions to the deployed venue.
import { type Address, getAddress, maxUint128 } from 'viem'
import { assert, describe, expect, test } from 'vitest'
import {
  Book,
  Errors,
  Fees,
  HotWord,
  Ladder,
  Post,
  Price,
  Quote,
  Shape,
  Snapshot,
  Venue,
  VenueHookFlags,
} from '../src/index.js'

const VENUE: Address = '0x1111111111111111111111111111111111111111'
const SETTLER: Address = '0x2222222222222222222222222222222222222222'
const BASE: Address = getAddress('0x20c0000000000000000000000000000000000001')
const QUOTE: Address = getAddress('0x20c0000000000000000000000000000000000002')
const OTHER: Address = getAddress('0x20c0000000000000000000000000000000000003')
const NOW = 1_800_000_000n

const SHAPE = Shape.from({
  bids: [
    { size: 1_000, spread: 10 },
    { size: 2_000, spread: 30 },
  ],
  asks: [
    { size: 1_000, spread: 10 },
    { size: 2_000, spread: 30 },
  ],
})

function snapshot(
  overrides: {
    pair?: Partial<Snapshot.PairState> | undefined
    order?: Partial<Post.OrderRequest> | undefined
    halted?: boolean | undefined
    cap?: bigint | undefined
    baseFee?: bigint | null | undefined
  } = {},
): Snapshot.VenueSnapshot {
  const order = {
    pairIndex: 0,
    mid: Price.parse('1.085'),
    shapeId: 7,
    sequence: 2,
    validUntil: Number(NOW) + 60,
    ...overrides.order,
  }
  const hotWord = HotWord.withoutRefill(Post.order(order).word)
  const pair: Snapshot.PairState = {
    ok: true,
    pairIndex: 0,
    base: BASE,
    quote: QUOTE,
    sizeUnit: 1_000_000n,
    access: 'listed',
    hook: '0x0000000000000000000000000000000000000000',
    hookFlags: 0,
    hotWord,
    hot: HotWord.decode(hotWord),
    consumed: { bids: 0n, asks: 0n },
    midBand: { minMid: 0n, maxMid: 0n },
    shapeWords: SHAPE.words,
    shape: SHAPE,
    inventory: { base: 10n ** 12n, quote: 10n ** 12n },
    hookLiquidity: { base: 0n, quote: 0n },
    ...overrides.pair,
  }
  return {
    venue: VENUE,
    block: {
      number: 1n,
      hash: `0x${'ab'.repeat(32)}`,
      timestamp: NOW,
      baseFeePerGas:
        overrides.baseFee === undefined ? 20_000_000_000n : overrides.baseFee,
    },
    state: {
      owner: VENUE,
      pendingOwner: '0x0000000000000000000000000000000000000000',
      settler: SETTLER,
      factory: VENUE,
      halted: overrides.halted ?? false,
      deniedCount: 0,
      maxTakerPriorityFee: overrides.cap ?? Venue.noPriorityFeeCap,
      pairCount: 1,
    },
    pairs: [pair],
    sponsors: [],
    accounts: [],
    access: [],
  }
}

const buy = {
  pairIndex: 0,
  tokenIn: QUOTE,
  tokenOut: BASE,
  exactIn: false,
  amount: 1_000_000n,
  priorityFee: 0n,
}
const errorOf = (r: Quote.Result) => (r.ok ? 'ok' : r.error.errorName)

describe('Quote.local', () => {
  test('prices a fill and its consumption', () => {
    const r = Quote.local(snapshot(), buy)
    assert(r.ok)
    // 1 base at 1.085 x (1 + 1 bp) = 1.0851085, rounded up for the maker.
    expect(r.amountIn).toBe(1_085_109n)
    expect(r.amountOut).toBe(1_000_000n)
    expect(r.baseIn).toBe(false)
    expect(r.consumedAfter).toStrictEqual({ bids: 0n, asks: 1_000_000n })
  })

  test.each([
    [true, true],
    [true, false],
    [false, true],
    [false, false],
  ])(
    'rejects malformed original side words (baseIn=%s, exactIn=%s)',
    (baseIn, exactIn) => {
      const request = {
        ...buy,
        exactIn,
        tokenIn: baseIn ? BASE : QUOTE,
        tokenOut: baseIn ? QUOTE : BASE,
      }
      for (const tail of [1n, 1n << 255n]) {
        const words: [bigint, bigint, bigint, bigint] = [...SHAPE.words]
        words[baseIn ? 1 : 3] = tail
        const reason = Shape.check(words)
        expect(reason).not.toBe(0)
        expect(() =>
          Quote.local(
            snapshot({ pair: { shapeWords: words, shape: null } }),
            request,
          ),
        ).toThrow(
          expect.objectContaining({ name: 'InvalidShapeError', reason }),
        )
      }
      for (const length of [1, 5, 6, 10]) {
        const levels = Array.from({ length }, (_, i) => ({
          size: 1_000,
          spread: i * 10,
        }))
        const shape = Shape.from({ bids: levels, asks: levels })
        expect(
          Quote.local(
            snapshot({ pair: { shapeWords: shape.words, shape } }),
            request,
          ).ok,
        ).toBe(true)
      }
    },
  )

  test("follows Venue.quote's precondition order", () => {
    const expired = { order: { validUntil: Number(NOW) - 1 } }
    // Each case breaks one precondition and every later one; the earliest wins.
    const cases: [string, Snapshot.VenueSnapshot, Quote.Request][] = [
      [
        'VenueHalted',
        snapshot({
          halted: true,
          ...expired,
          pair: { base: '0x0000000000000000000000000000000000000000' },
        }),
        { ...buy, amount: 0n },
      ],
      [
        'UnknownPair',
        snapshot({
          ...expired,
          pair: {
            base: '0x0000000000000000000000000000000000000000',
            access: 'none',
          },
        }),
        { ...buy, tokenIn: OTHER, amount: 0n },
      ],
      [
        'TokenMismatch',
        snapshot(expired),
        { ...buy, tokenIn: OTHER, amount: 0n },
      ],
      ['TokenMismatch', snapshot(), { ...buy, tokenIn: BASE, tokenOut: BASE }],
      ['ZeroAmount', snapshot(expired), { ...buy, amount: 0n }],
      [
        'QuoteExpired',
        snapshot({
          ...expired,
          order: { validUntil: Number(NOW) - 1, sides: 'neither' },
        }),
        buy,
      ],
      ['SideDisabled', snapshot({ order: { sides: 'bids' } }), buy],
      ['SideDisabled', snapshot({ order: { depthScale: 0 } }), buy],
      [
        'InsufficientDepth',
        snapshot({ pair: { inventory: { base: 0n, quote: 0n } } }),
        { ...buy, amount: 3_000_000_001n },
      ],
      [
        'ZeroFill',
        snapshot({ pair: { inventory: { base: 0n, quote: 0n } } }),
        {
          pairIndex: 0,
          tokenIn: QUOTE,
          tokenOut: BASE,
          exactIn: true,
          amount: 1n,
          priorityFee: 0n,
        },
      ],
      [
        'TakerPriorityFeeTooHigh',
        snapshot({ cap: 5n, pair: { inventory: { base: 0n, quote: 0n } } }),
        { ...buy, priorityFee: 6n },
      ],
      [
        'InsufficientInventory',
        snapshot({
          cap: 5n,
          pair: { inventory: { base: 999_999n, quote: 0n } },
        }),
        { ...buy, priorityFee: 5n },
      ],
    ]
    for (const [expected, s, request] of cases)
      expect(errorOf(Quote.local(s, request)), expected).toBe(expected)
  })

  test("returns the venue's error arguments as viem decodes them", () => {
    const expired = Quote.local(
      snapshot({ order: { validUntil: Number(NOW) - 1 } }),
      buy,
    )
    expect(expired).toStrictEqual({
      ok: false,
      error: { errorName: 'QuoteExpired', args: [Number(NOW) - 1] },
    })
    expect(
      Quote.local(snapshot({ order: { sides: 'bids' } }), buy),
    ).toStrictEqual({
      ok: false,
      error: { errorName: 'SideDisabled', args: [false] },
    })
    expect(
      Quote.local(snapshot({ cap: 5n }), { ...buy, priorityFee: 6n }),
    ).toStrictEqual({
      ok: false,
      error: { errorName: 'TakerPriorityFeeTooHigh', args: [6n, 5n] },
    })
    expect(
      Quote.local(
        snapshot({ pair: { inventory: { base: 7n, quote: 0n } } }),
        buy,
      ),
    ).toStrictEqual({
      ok: false,
      error: {
        errorName: 'InsufficientInventory',
        args: [BASE, 7n, 1_000_000n],
      },
    })
    expect(
      Quote.local(snapshot(), {
        ...buy,
        tokenIn: OTHER.toLowerCase() as Address,
      }),
    ).toStrictEqual({
      ok: false,
      error: { errorName: 'TokenMismatch', args: [OTHER, BASE] },
    })
    expect(
      Quote.local(
        snapshot({
          pair: { base: '0x0000000000000000000000000000000000000000' },
        }),
        buy,
      ),
    ).toStrictEqual({
      ok: false,
      error: { errorName: 'UnknownPair', args: [0] },
    })
  })

  test('counts hook liquidity only with BEFORE_FILL', () => {
    const short = {
      inventory: { base: 400_000n, quote: 0n },
      hookLiquidity: { base: 600_000n, quote: 0n },
    }
    expect(
      errorOf(
        Quote.local(
          snapshot({
            pair: { ...short, hookFlags: VenueHookFlags.beforeFill },
          }),
          buy,
        ),
      ),
    ).toBe('ok')
    expect(
      errorOf(
        Quote.local(
          snapshot({
            pair: { ...short, hookFlags: VenueHookFlags.afterFill },
          }),
          buy,
        ),
      ),
    ).toBe('InsufficientInventory')
    expect(
      Quote.local(
        snapshot({
          pair: {
            ...short,
            hookLiquidity: { base: 599_999n, quote: 0n },
            hookFlags: 1,
          },
        }),
        buy,
      ),
    ).toStrictEqual({
      ok: false,
      error: {
        errorName: 'InsufficientInventory',
        args: [BASE, 999_999n, 1_000_000n],
      },
    })
  })

  test('reports AmountOverflow for an output above uint128 and refuses amounts the ABI cannot carry', () => {
    const huge = Shape.from({
      bids: [{ size: 2 ** 32 - 1, spread: 0 }],
      asks: [],
    })
    const s = snapshot({
      order: { mid: (1n << 96n) - 1n, depthScale: 65_535 },
      pair: { sizeUnit: (1n << 64n) - 1n, shapeWords: huge.words, shape: huge },
    })
    expect(
      errorOf(
        Quote.local(s, {
          pairIndex: 0,
          tokenIn: BASE,
          tokenOut: QUOTE,
          exactIn: true,
          amount: 1n << 100n,
          priorityFee: 0n,
        }),
      ),
    ).toBe('AmountOverflow')
    expect(() =>
      Quote.local(snapshot(), { ...buy, amount: maxUint128 + 1n }),
    ).toThrow(Errors.AmountOutOfRangeError)
    expect(() => Quote.local(snapshot(), { ...buy, amount: -1n })).toThrow(
      Errors.AmountOutOfRangeError,
    )
    expect(() => Quote.local(snapshot(), { ...buy, pairIndex: 5 })).toThrow(
      Errors.SnapshotIncompleteError,
    )
  })
})

describe('Quote.local priority fee and taker access', () => {
  const TAKER = getAddress('0x3333333333333333333333333333333333333333')
  const access = (name: Quote.TakerAccess['access']) => ({
    taker: TAKER,
    sponsorId: 42n,
    access: name,
  })

  test('takes no silent priority fee: one is required, and checked as a uint256', () => {
    const { priorityFee: _, ...noFee } = buy
    expect(() =>
      Quote.local(snapshot({ cap: 5n }), noFee as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: priorityFee must be a bigint in [0, 2^256 - 1], got undefined

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Quote.local(snapshot(), { ...buy, priorityFee: -1n }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: priorityFee must be a bigint in [0, 2^256 - 1], got -1n

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(
      errorOf(Quote.local(snapshot({ cap: 5n }), { ...buy, priorityFee: 5n })),
      'at the cap',
    ).toBe('ok')
  })

  test("folds in the taker's access as fill's revert, after the fee cap and before inventory", () => {
    const names = [
      'allowed',
      'unknownPair',
      'priorityFeeTooHigh',
      'closed',
      'denied',
      'unknownSponsor',
      'sponsorDisabled',
      'sponsorNotAdmitted',
      'notListed',
      'none',
    ] as const
    expect(
      Object.fromEntries(
        names.map((name) => [
          name,
          Quote.local(snapshot({ cap: 10n }), {
            ...buy,
            priorityFee: 3n,
            takerAccess: access(name),
          }),
        ]),
      ),
    ).toMatchInlineSnapshot(`
      {
        "allowed": {
          "amountIn": 1085109n,
          "amountOut": 1000000n,
          "baseFilled": 1000000n,
          "baseIn": false,
          "consumedAfter": {
            "asks": 1000000n,
            "bids": 0n,
          },
          "ok": true,
        },
        "closed": {
          "error": {
            "args": [
              "0x3333333333333333333333333333333333333333",
            ],
            "errorName": "TakerNotAllowed",
          },
          "ok": false,
        },
        "denied": {
          "error": {
            "args": [
              "0x3333333333333333333333333333333333333333",
            ],
            "errorName": "TakerDenied",
          },
          "ok": false,
        },
        "none": {
          "error": {
            "args": [
              "0x3333333333333333333333333333333333333333",
            ],
            "errorName": "TakerNotAllowed",
          },
          "ok": false,
        },
        "notListed": {
          "error": {
            "args": [
              "0x3333333333333333333333333333333333333333",
            ],
            "errorName": "TakerNotAllowed",
          },
          "ok": false,
        },
        "priorityFeeTooHigh": {
          "error": {
            "args": [
              3n,
              10n,
            ],
            "errorName": "TakerPriorityFeeTooHigh",
          },
          "ok": false,
        },
        "sponsorDisabled": {
          "error": {
            "args": [
              42n,
            ],
            "errorName": "SponsorDisabled",
          },
          "ok": false,
        },
        "sponsorNotAdmitted": {
          "error": {
            "args": [
              0,
              42n,
            ],
            "errorName": "SponsorNotAdmitted",
          },
          "ok": false,
        },
        "unknownPair": {
          "error": {
            "args": [
              0,
            ],
            "errorName": "UnknownPair",
          },
          "ok": false,
        },
        "unknownSponsor": {
          "error": {
            "args": [
              42n,
            ],
            "errorName": "UnknownSponsor",
          },
          "ok": false,
        },
      }
    `)
    const denied = { ...buy, takerAccess: access('denied') }
    expect(
      errorOf(Quote.local(snapshot({ order: { sides: 'bids' } }), denied)),
      'pricing first',
    ).toBe('SideDisabled')
    expect(
      errorOf(
        Quote.local(snapshot({ cap: 5n }), { ...denied, priorityFee: 6n }),
      ),
      'then the fee cap',
    ).toBe('TakerPriorityFeeTooHigh')
    expect(
      errorOf(
        Quote.local(
          snapshot({ pair: { inventory: { base: 0n, quote: 0n } } }),
          denied,
        ),
      ),
      'then access, before inventory',
    ).toBe('TakerDenied')
  })

  test('refuses an access read for another pair, or one it cannot read', () => {
    expect(() =>
      Quote.local(snapshot(), {
        ...buy,
        takerAccess: { ...access('allowed'), pairIndex: 1 },
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: takerAccess was read for pair 1, not the quote's pair 0

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Quote.local(snapshot(), {
        ...buy,
        takerAccess: access('Maybe' as never),
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: takerAccess.access is not a TakerAccess name: "Maybe"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Quote.local(snapshot(), {
        ...buy,
        takerAccess: { ...access('allowed'), taker: '0x1234' },
      }),
    ).toThrow(Errors.InvalidAddressError)
  })
})

describe('ladder edge cases', () => {
  const curve = (
    mid: bigint,
    baseIn: boolean,
    over: Partial<HotWord.HotWord> = {},
    sizeUnit = 1n,
  ) =>
    Ladder.curve(
      {
        mid,
        bidWiden: 0,
        askWiden: 0,
        widthScale: 1000,
        depthScale: 1000,
        ...over,
      },
      sizeUnit,
      baseIn,
    )
  const side = (levels: Shape.Level[]) => Shape.encodeSide(levels)

  test('rounds once toward the maker', () => {
    // Sell 3 base at mid 0.5 + floor: 1.5 floors to 1. Buy 3 at 0.5 ceils to 2.
    const [w0, w1] = side([{ size: 10, spread: 0 }])
    expect(
      Ladder.fill(curve(Price.parse('0.5'), true), w0, w1, true, 3n, 0n),
    ).toStrictEqual({ ok: true, amountIn: 3n, amountOut: 1n, baseFilled: 3n })
    expect(
      Ladder.fill(curve(Price.parse('0.5'), false), w0, w1, false, 3n, 0n),
    ).toStrictEqual({ ok: true, amountIn: 2n, amountOut: 3n, baseFilled: 3n })
    // Pay 3 quote at 2.0: buys 1 base and the maker keeps the dust.
    expect(
      Ladder.fill(curve(Price.parse('2'), false), w0, w1, true, 3n, 0n),
    ).toStrictEqual({ ok: true, amountIn: 3n, amountOut: 1n, baseFilled: 1n })
    // Want 3 quote at 2.0: sells 2 base (the least that covers it).
    expect(
      Ladder.fill(curve(Price.parse('2'), true), w0, w1, false, 3n, 0n),
    ).toStrictEqual({ ok: true, amountIn: 2n, amountOut: 3n, baseFilled: 2n })
  })

  test('reports ZeroFill when either side rounds to zero, InsufficientDepth first', () => {
    const [w0, w1] = side([{ size: 10, spread: 0 }])
    expect(
      Ladder.fill(curve(Price.parse('0.5'), true), w0, w1, true, 1n, 0n),
    ).toStrictEqual({ ok: false, error: 'ZeroFill' })
    expect(
      Ladder.fill(curve(Price.parse('2'), false), w0, w1, true, 1n, 0n),
    ).toStrictEqual({ ok: false, error: 'ZeroFill' })
    // 11 base at a price that floors to zero needs more than the book: depth wins.
    expect(Ladder.fill(curve(1n, true), w0, w1, true, 11n, 0n)).toStrictEqual({
      ok: false,
      error: 'InsufficientDepth',
    })
    expect(Ladder.fill(curve(1n, true), w0, w1, true, 10n, 0n)).toStrictEqual({
      ok: false,
      error: 'ZeroFill',
    })
  })

  test('walks from consumed and skips empty levels', () => {
    const [w0, w1] = side([
      { size: 10, spread: 0 },
      { size: 10, spread: 100 },
    ])
    const c = curve(Price.one, false)
    // 10 consumed: the next fill starts on level 2, at 1.01.
    expect(Ladder.fill(c, w0, w1, false, 10n, 10n)).toStrictEqual({
      ok: true,
      amountIn: 11n,
      amountOut: 10n,
      baseFilled: 10n,
    })
    expect(Ladder.fill(c, w0, w1, false, 1n, 20n)).toStrictEqual({
      ok: false,
      error: 'InsufficientDepth',
    })
    expect(
      Ladder.fill(c, w0, w1, false, 1n, 25n),
      'consumed past depth',
    ).toStrictEqual({ ok: false, error: 'InsufficientDepth' })
    // depthScale 999 floors a size-1 level to 0: it holds nothing and doesn't end the side.
    const [z0, z1] = side([
      { size: 1, spread: 0 },
      { size: 1_000, spread: 50 },
    ])
    const thin = curve(Price.one, false, { depthScale: 999 })
    expect(Ladder.effectiveSize(thin, 1)).toBe(0n)
    expect(Ladder.fill(thin, z0, z1, false, 100n, 0n)).toStrictEqual({
      ok: true,
      amountIn: 101n,
      amountOut: 100n,
      baseFilled: 100n,
    })
    // The bid floor, reached with widths a hot word can carry: test/ladder.test.ts.
    expect(Ladder.applyRefill({ bids: 3n, asks: 4n }, 'bids')).toStrictEqual({
      bids: 0n,
      asks: 4n,
    })
    expect(Ladder.applyFill({ bids: 3n, asks: 4n }, true, 2n)).toStrictEqual({
      bids: 5n,
      asks: 4n,
    })
    expect(() => Ladder.fill(c, w0, w1, true, 0n, 0n)).toThrow(
      Errors.AmountOutOfRangeError,
    )
  })
})

describe('Book', () => {
  const live = (s: Snapshot.VenueSnapshot) => ({
    at: s.block.timestamp,
    halted: s.state.halted,
  })

  test('shows the posted ladder as rows after its consumption', () => {
    const s = snapshot({
      pair: { consumed: { bids: 0n, asks: 1_500_000_000n } },
    })
    const pair = Snapshot.pair(s, 0)
    expect(Book.ladder(pair, 'asks')).toMatchInlineSnapshot(`
      [
        {
          "depth": 1000000000n,
          "level": 0,
          "offsetTenthBpX1000": 10000n,
          "priceX1e26": 108510850000000000000000000n,
          "remaining": 0n,
        },
        {
          "depth": 2000000000n,
          "level": 1,
          "offsetTenthBpX1000": 30000n,
          "priceX1e26": 108532550000000000000000000n,
          "remaining": 1500000000n,
        },
      ]
    `)
    expect(Book.side(pair, 'asks', live(s))).toStrictEqual(
      Book.ladder(pair, 'asks'),
    )
    expect(Book.remaining(pair, 'bids', live(s))).toBe(3_000_000_000n)
    expect(Book.remaining(pair, 'asks', live(s))).toBe(1_500_000_000n)
  })

  test('shows no live depth where Venue.quote would refuse: halted, expired, a side off or depth 0', () => {
    const cases: Record<string, Snapshot.VenueSnapshot> = {
      halted: snapshot({ halted: true }),
      expired: snapshot({ order: { validUntil: Number(NOW) - 1 } }),
      'asks off': snapshot({ order: { sides: 'bids' } }),
      'both off': snapshot({ order: { sides: 'neither' } }),
      'depth scale 0': snapshot({ order: { depthScale: 0 } }),
      'live through validUntil, inclusive': snapshot({
        order: { validUntil: Number(NOW) },
      }),
    }
    expect(
      Object.fromEntries(
        Object.entries(cases).map(([name, s]) => {
          const pair = Snapshot.pair(s, 0)
          return [
            name,
            {
              live: Book.remaining(pair, 'asks', live(s)),
              posted: Book.ladder(pair, 'asks').reduce(
                (sum, row) => sum + row.remaining,
                0n,
              ),
              quote: errorOf(Quote.local(s, { ...buy, priorityFee: 0n })),
            },
          ]
        }),
      ),
    ).toMatchInlineSnapshot(`
      {
        "asks off": {
          "live": 0n,
          "posted": 3000000000n,
          "quote": "SideDisabled",
        },
        "both off": {
          "live": 0n,
          "posted": 3000000000n,
          "quote": "SideDisabled",
        },
        "depth scale 0": {
          "live": 0n,
          "posted": 0n,
          "quote": "SideDisabled",
        },
        "expired": {
          "live": 0n,
          "posted": 3000000000n,
          "quote": "QuoteExpired",
        },
        "halted": {
          "live": 0n,
          "posted": 3000000000n,
          "quote": "VenueHalted",
        },
        "live through validUntil, inclusive": {
          "live": 3000000000n,
          "posted": 3000000000n,
          "quote": "ok",
        },
      }
    `)
    // A later time expires a live book.
    const s = snapshot()
    expect(
      Book.side(Snapshot.pair(s, 0), 'bids', {
        at: NOW + 61n,
        halted: false,
      }),
    ).toStrictEqual([])
  })

  test('refuses a side or a state it cannot read', () => {
    const pair = Snapshot.pair(snapshot(), 0)
    expect(() =>
      Book.ladder(pair, 'up' as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: which must be 'bids' or 'asks', got "up"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Book.side(pair, 'asks', { at: 1, halted: false } as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: at must be a bigint in [0, 2^64 - 1], got 1

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Book.remaining(pair, 'asks', undefined as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: state must be { at, halted }

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})

describe('Fees', () => {
  test('posts strictly above the cap', () => {
    expect(Fees.makerTip(10n)).toBe(10n + Fees.gwei)
    expect(Fees.makerTip(Venue.noPriorityFeeCap, 1n)).toBe(1n)
    expect(() => Fees.makerTip(10n, 0n)).toThrow(Errors.InvalidArgumentError)
    expect(Fees.priorityFee(30n, 20n)).toBe(10n)
    expect(Fees.priorityFee(10n, 20n)).toBe(0n)
    expect(
      Fees.allows(10n, 10n) &&
        !Fees.allows(10n, 11n) &&
        Fees.allows(Venue.noPriorityFeeCap, 1n << 70n),
    ).toBeTruthy()
    expect(Fees.feeFields(2n, 5n)).toStrictEqual({
      maxFeePerGas: 11n,
      maxPriorityFeePerGas: 5n,
    })
    expect(Venue.defaultTakerPriorityFeeCap).toBe(10n * Fees.gwei)
  })
})
