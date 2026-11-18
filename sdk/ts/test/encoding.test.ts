// Encoding at parity with sdk/rust/tests/encoding.rs, plus the exact ShapeWord reasons and the refill bits.
import { decodeFunctionData, numberToHex, size, sliceHex } from 'viem'
import { describe, expect, test } from 'vitest'
import {
  Abis,
  Actions,
  Errors,
  HotWord,
  Post,
  Price,
  Shape,
} from '../src/index.js'

const VENUE = '0x1111111111111111111111111111111111111111'

/** splitmix64 for reproducible property cases. */
function rng(seed: bigint) {
  let s = seed
  return (bits: number) => {
    s = (s + 0x9e37_79b9_7f4a_7c15n) & 0xffff_ffff_ffff_ffffn
    let z = s
    z = ((z ^ (z >> 30n)) * 0xbf58_476d_1ce4_e5b9n) & 0xffff_ffff_ffff_ffffn
    z = ((z ^ (z >> 27n)) * 0x94d0_49bb_1331_11ebn) & 0xffff_ffff_ffff_ffffn
    z ^= z >> 31n
    let out = z
    for (let have = 64; have < bits; have += 64) out = (out << 64n) | z
    return out & ((1n << BigInt(bits)) - 1n)
  }
}

describe('Price', () => {
  test('is exact and never silently rounds', () => {
    for (const value of [
      '1',
      '1.085',
      '0.000000000000000001',
      '79228162514.264337593543950335',
    ]) {
      expect(Price.format(Price.parse(value))).toBe(value)
    }
    for (const bad of [
      '',
      '0',
      '-1',
      '+1',
      ' 1',
      '1 ',
      '1e18',
      '.1',
      '1.',
      '1.2.3',
      'NaN',
      '0x10',
      '1,5',
      '1.0000000000000000001',
      '79228162514.264337593543950336',
      '9'.repeat(43),
    ]) {
      expect(() => Price.parse(bad), bad).toThrow(Errors.InvalidPriceError)
    }
    expect(Price.parse('1.085')).toBe(1_085_000_000_000_000_000n)
    expect(Price.parse('2')).toBe(2n * Price.one)
    expect(Price.format(1n)).toBe('0.000000000000000001')
  })

  test('asserts and validates a mid a post can carry, and builds one from either form', () => {
    expect(Price.assert(Price.one)).toBe(undefined)
    expect(Price.assert((1n << 96n) - 1n)).toBe(undefined)
    for (const bad of [0n, -1n, 1n << 96n, 1 as never, '1' as never]) {
      expect(() => Price.assert(bad), String(bad)).toThrow(
        Errors.InvalidPriceError,
      )
      expect(Price.validate(bad), String(bad)).toBe(false)
    }
    expect(Price.validate(1n)).toBe(true)
    expect(Price.from('1.085')).toBe(Price.parse('1.085'))
    expect(Price.from(1_085_000_000_000_000_000n)).toBe(Price.parse('1.085'))
    expect(() => Price.from(0n)).toThrow(Errors.InvalidPriceError)
    expect(() => Price.from('0')).toThrow(Errors.InvalidPriceError)
  })

  test("formats the whole uint96 field: 0 is an unposted pair's mid", () => {
    // `HotWord.initial`, the word `addPair` stores, carries mid 0 until the first post.
    expect(Price.format(HotWord.decode(HotWord.initial).mid)).toBe('0')
    expect(Price.format((1n << 96n) - 1n)).toBe(
      '79228162514.264337593543950335',
    )
    expect(Price.format(Price.one)).toBe('1')
    // `parse` refuses what no post can carry, so `parse(format(0n))` throws.
    expect(() => Price.parse(Price.format(0n))).toThrow(
      Errors.InvalidPriceError,
    )
    for (const bad of [-1n, 1n << 96n, 5 as never]) {
      expect(() => Price.format(bad), String(bad)).toThrow(
        Errors.InvalidPriceError,
      )
    }
  })

  test('name the bad value in each refusal', () => {
    const messages = [
      () => Price.parse('1.5e3'),
      () => Price.parse('0'),
      () => Price.assert(1n << 96n),
      () => Price.format(-1n),
    ].map((fn) => {
      try {
        fn()
      } catch (error) {
        return (error as Errors.InvalidPriceError).shortMessage
      }
      throw new Error('expected a throw')
    })
    expect(messages).toMatchInlineSnapshot(`
      [
        "price must be an unsigned decimal with at most 18 places, got "1.5e3"",
        "a mid must be a nonzero uint96 bigint (quote per base, scaled by 1e18), got 0n",
        "a mid must be a nonzero uint96 bigint (quote per base, scaled by 1e18), got 79228162514264337593543950336n",
        "a mid to format must be a uint96 bigint, got -1n",
      ]
    `)
  })
})

describe('post batches', () => {
  test('pack big-endian pair indexes and 34-byte entries', () => {
    const a = Post.order({
      pairIndex: 0x1234,
      mid: Price.parse('1.085'),
      shapeId: 7,
      sequence: 2,
      validUntil: 1_800_000_060,
    })
    const b = Post.order({
      pairIndex: 0xabcd,
      mid: Price.parse('2'),
      shapeId: 255,
      sequence: 2 ** 32 - 1,
      validUntil: 2 ** 40 - 1,
    })
    const call = Actions.maker.bulkOrders.call({
      venue: VENUE,
      orders: [
        {
          pairIndex: 0x1234,
          mid: Price.parse('1.085'),
          shapeId: 7,
          sequence: 2,
          validUntil: 1_800_000_060,
        },
        {
          pairIndex: 0xabcd,
          mid: Price.parse('2'),
          shapeId: 255,
          sequence: 2 ** 32 - 1,
          validUntil: 2 ** 40 - 1,
        },
      ],
    })
    const { functionName, args } = decodeFunctionData({
      abi: Abis.venueAbi,
      data: call.data,
    })
    expect(functionName).toBe('post')
    const packed = args[0] as `0x${string}`
    expect(size(packed)).toBe(68)
    expect(sliceHex(packed, 0, 2)).toBe('0x1234')
    expect(sliceHex(packed, 2, 34)).toBe(a.word)
    expect(sliceHex(packed, 34, 36)).toBe('0xabcd')
    expect(sliceHex(packed, 36)).toBe(b.word)
    expect(call.posts).toStrictEqual([
      { pairIndex: 0x1234, sequence: 2, word: a.word },
      { pairIndex: 0xabcd, sequence: 2 ** 32 - 1, word: b.word },
    ])
    expect(Post.unpack(packed)).toStrictEqual([a, b])
    expect(call.signer).toStrictEqual({ role: 'ownerOrAgent' })
  })

  test('refuse empty batches, duplicate pairs and words post would revert on', () => {
    const order = {
      pairIndex: 3,
      mid: Price.one,
      shapeId: 0,
      sequence: 5,
      validUntil: 1,
    }
    expect(() =>
      Actions.maker.bulkOrders.call({ venue: VENUE, orders: [order, order] }),
    ).toThrow(Errors.DuplicatePairError)
    expect(() =>
      Actions.maker.bulkOrders.call({ venue: VENUE, orders: [] }),
    ).toThrow(Errors.EmptyBatchError)
    expect(() =>
      Actions.venue.post.call({ venue: VENUE, entries: [] }),
    ).toThrow(Errors.EmptyBatchError)
    expect(
      () => Post.pack([{ pairIndex: 0, word: HotWord.initial }]),
      'zero mid',
    ).toThrow(Errors.InvalidHotWordError)
    const reserved = HotWord.fromFields({
      ...HotWord.toFields(Post.order(order).word),
      flags: 16,
    })
    expect(
      () => Post.pack([{ pairIndex: 0, word: reserved }]),
      'reserved flag bit',
    ).toThrow(Errors.InvalidHotWordError)
    expect(() => Post.unpack('0x1234')).toThrow(Errors.InvalidArgumentError)
    expect(() => Post.pack([null as never])).toThrow(
      expect.objectContaining({
        name: 'InvalidArgumentError',
        parameter: 'entries[0]',
      }),
    )
  })

  test('refuse a word that is not exactly 32 bytes, never padding a short one', () => {
    const { word } = Post.order({
      pairIndex: 7,
      mid: Price.one,
      shapeId: 0,
      sequence: 2,
      validUntil: 1,
    })
    // The word with its leading zero byte dropped: 31 bytes that would pad back to the same word.
    const short = `0x${word.slice(4)}` as const
    expect(BigInt(short)).toBe(BigInt(word))
    for (const bad of [
      short,
      `${word}00`,
      `${word}0`,
      '0x',
      '0x1234',
    ] as const) {
      expect(() => Post.pack([{ pairIndex: 7, word: bad }]), bad).toThrow(
        expect.objectContaining({
          name: 'InvalidHotWordError',
          pairIndex: 7,
          parameter: 'entries[0].word',
          word: bad,
        }),
      )
      expect(() => HotWord.decode(bad), bad).toThrow(Errors.InvalidHotWordError)
      expect(HotWord.validate(bad), bad).toBe(false)
    }
    expect(
      (() => {
        try {
          Post.pack([{ pairIndex: 7, word: short }])
        } catch (error) {
          return (error as Errors.InvalidHotWordError).shortMessage
        }
      })(),
    ).toMatchInlineSnapshot(
      `"pair 7's word must be exactly 32 bytes of hex, got "0x000000000200000000010003e803e800000000000000000de0b6b3a7640000""`,
    )
    expect(() => HotWord.assert('0x1234')).toThrow(Errors.InvalidHotWordError)
    expect(HotWord.assert(word)).toBe(undefined)
    // Case doesn't matter; `pack` writes lowercase.
    const upper = `0x${word.slice(2).toUpperCase()}` as const
    expect(HotWord.validate(upper)).toBe(true)
    expect(Post.pack([{ pairIndex: 7, word: upper }]).packed).toBe(
      Post.pack([{ pairIndex: 7, word }]).packed,
    )
  })

  test('cancel by disabling both sides, for one pair or all of them', () => {
    const call = Actions.maker.bulkCancel.call({
      venue: VENUE,
      cancels: [{ pairIndex: 42, sequence: 99, mid: Price.one }],
    })
    const [{ word }] = Post.unpack(
      decodeFunctionData({ abi: Abis.venueAbi, data: call.data })
        .args[0] as `0x${string}`,
    ) as [Post.Entry]
    const hot = HotWord.decode(word)
    expect(hot.sides).toBe('neither')
    expect(hot.sequence).toBe(99)
    expect(hot.depthScale).toBe(0)
    expect(hot.validUntil).toBe(0)
    expect(hot.shapeId).toBe(0)
    expect(hot.mid).toBe(Price.one)
    const all = Actions.maker.cancelAll.call({
      venue: VENUE,
      cancels: [{ pairIndex: 42, sequence: 99, mid: Price.one }],
    })
    expect(all.data, 'cancelAll posts cancels, never setHalted').toBe(call.data)
    expect(all.signer).toStrictEqual({ role: 'ownerOrAgent' })
  })

  test('bound the sequence and expiry: a fresh pair stores seq 1, so its first post is 2', () => {
    const initial = HotWord.decode(HotWord.initial)
    expect(initial.mid).toBe(0n)
    expect(initial.sequence).toBe(1)
    expect(initial.validUntil).toBe(0)
    expect(HotWord.isWellFormed(HotWord.initial)).toBe(false)
    const base = { pairIndex: 0, mid: Price.one, shapeId: 0, validUntil: 1 }
    expect(() => Post.order({ ...base, sequence: 1 })).toThrow(
      Errors.InvalidOrderError,
    )
    expect(() => Post.order({ ...base, sequence: 0 })).toThrow(
      Errors.InvalidOrderError,
    )
    expect(() => Post.order({ ...base, sequence: 2 ** 32 })).toThrow(
      Errors.InvalidOrderError,
    )
    expect(() =>
      Post.order({ ...base, sequence: 2, validUntil: 2 ** 40 }),
    ).toThrow(Errors.InvalidOrderError)
    expect(() => Post.order({ ...base, sequence: 2, validUntil: -1 })).toThrow(
      Errors.InvalidOrderError,
    )
    expect(() => Post.order({ ...base, sequence: 2, mid: 0n })).toThrow(
      Errors.InvalidOrderError,
    )
    expect(() => Post.order({ ...base, sequence: 2, shapeId: 256 })).toThrow(
      Errors.InvalidOrderError,
    )
    expect(() =>
      Post.order({ ...base, sequence: 2, pairIndex: 65_536 }),
    ).toThrow(Errors.InvalidOrderError)
    expect(() =>
      Post.order({ ...base, sequence: 2, widthScale: 65_536 }),
    ).toThrow(Errors.InvalidOrderError)
    expect(
      HotWord.decode(Post.order({ ...base, sequence: 2 ** 32 - 1 }).word)
        .sequence,
    ).toBe(2 ** 32 - 1)
  })

  test.each([
    ['bidWiden', 0],
    ['askWiden', 0],
    ['widthScale', 1000],
    ['depthScale', 1000],
    ['sides', 'both'],
    ['refill', 'neither'],
  ] as const)(
    'default %s only when omitted or undefined, never null',
    (field, fallback) => {
      const base: Post.OrderRequest = {
        pairIndex: 3,
        mid: Price.one,
        shapeId: 0,
        sequence: 2,
        validUntil: 1_800_000_000,
      }
      const omitted = Post.order(base)
      expect(Post.order({ ...base, [field]: undefined })).toStrictEqual(omitted)
      expect(Post.order({ ...base, [field]: fallback })).toStrictEqual(omitted)
      expect(HotWord.decodeEntry(omitted.word)[field]).toBe(fallback)
      expect(() =>
        Post.order({ ...base, [field]: null } as unknown as Post.OrderRequest),
      ).toThrowError(
        expect.objectContaining({
          name: 'InvalidOrderError',
          parameter: field,
          value: null,
          pairIndex: 3,
        }),
      )
    },
  )

  test('refuse each bad field with one InvalidOrderError naming it and its value', () => {
    const base: Post.OrderRequest = {
      pairIndex: 3,
      mid: Price.one,
      shapeId: 0,
      sequence: 2,
      validUntil: 1_800_000_000,
    }
    const cases: [string, Partial<Record<keyof Post.OrderRequest, unknown>>][] =
      [
        ['pairIndex', { pairIndex: 65_536 }],
        ['pairIndex', { pairIndex: -1 }],
        ['mid', { mid: 0n }],
        ['mid', { mid: 1 }],
        ['mid', { mid: 1n << 96n }],
        ['shapeId', { shapeId: 256 }],
        ['validUntil', { validUntil: 2 ** 40 }],
        ['validUntil', { validUntil: 1.5 }],
        ['sequence', { sequence: 1 }],
        ['sequence', { sequence: 2 ** 32 }],
        ['bidWiden', { bidWiden: 65_536 }],
        ['askWiden', { askWiden: -1 }],
        ['widthScale', { widthScale: 65_536 }],
        ['depthScale', { depthScale: '1000' }],
        ['sides', { sides: 'up' }],
        ['refill', { refill: 'all' }],
      ]
    const refusals = cases.map(([field, change]) => {
      const request = { ...base, ...change } as Post.OrderRequest
      let error: unknown
      try {
        Post.order(request)
      } catch (e) {
        error = e
      }
      expect(error, field).toBeInstanceOf(Errors.InvalidOrderError)
      const e = error as Errors.InvalidOrderError
      expect([e.parameter, e.value], field).toStrictEqual([
        field,
        change[field as keyof Post.OrderRequest],
      ])
      expect(e.pairIndex, field).toBe(field === 'pairIndex' ? undefined : 3)
      return e.shortMessage
    })
    expect(refusals).toMatchInlineSnapshot(`
      [
        "pairIndex must be an integer in [0, 65535], got 65536",
        "pairIndex must be an integer in [0, 65535], got -1",
        "pair 3: mid must be a nonzero uint96 bigint (quote per base, scaled by 1e18), got 0n",
        "pair 3: mid must be a nonzero uint96 bigint (quote per base, scaled by 1e18), got 1",
        "pair 3: mid must be a nonzero uint96 bigint (quote per base, scaled by 1e18), got 79228162514264337593543950336n",
        "pair 3: shapeId must be an integer in [0, 255], got 256",
        "pair 3: validUntil must be an integer in [0, 2^40 - 1] (inclusive Unix seconds), got 1099511627776",
        "pair 3: validUntil must be an integer in [0, 2^40 - 1] (inclusive Unix seconds), got 1.5",
        "pair 3: sequence must be an integer in [2, 2^32 - 1] (above the 1 a new pair stores), got 1",
        "pair 3: sequence must be an integer in [2, 2^32 - 1] (above the 1 a new pair stores), got 4294967296",
        "pair 3: bidWiden must be an integer in [0, 65535] (0.1 bp), got 65536",
        "pair 3: askWiden must be an integer in [0, 65535] (0.1 bp), got -1",
        "pair 3: widthScale must be an integer in [0, 65535] (per mille), got 65536",
        "pair 3: depthScale must be an integer in [0, 65535] (per mille), got "1000"",
        "pair 3: sides must be 'both', 'bids', 'asks' or 'neither', got "up"",
        "pair 3: refill must be 'both', 'bids', 'asks' or 'neither', got "all"",
      ]
    `)
    // The Rust SDK's order: an expiry past uint40 before a sequence of 1.
    expect(() =>
      Post.order({ ...base, validUntil: 2 ** 40, sequence: 1 }),
    ).toThrow(expect.objectContaining({ parameter: 'validUntil' }))
    // A cancel names the same fields, and a request that isn't an object is refused as one.
    expect(() =>
      Post.cancel({ pairIndex: 3, sequence: 1, mid: Price.one }),
    ).toThrow(expect.objectContaining({ parameter: 'sequence', value: 1 }))
    for (const bad of [null, 5, 'order']) {
      expect(() => Post.order(bad as never)).toThrow(
        expect.objectContaining({
          name: 'InvalidOrderError',
          parameter: 'request',
        }),
      )
      expect(() => Post.bulkOrders([bad as never])).toThrow(
        Errors.InvalidOrderError,
      )
      expect(() => Post.bulkCancel([bad as never])).toThrow(
        Errors.InvalidOrderError,
      )
    }
  })

  test('set refill bits that stored words never carry', () => {
    const order = {
      pairIndex: 0,
      mid: Price.parse('1.085'),
      shapeId: 7,
      sequence: 2,
      validUntil: 1_800_000_060,
    }
    const plain = BigInt(Post.order(order).word)
    for (const [refill, bits] of [
      ['neither', 0n],
      ['bids', 4n],
      ['asks', 8n],
      ['both', 12n],
    ] as const) {
      const word = Post.order({ ...order, refill }).word
      expect(BigInt(word)).toBe(plain | (bits << 240n))
      // The venue stores and emits the word with the refill bits cleared.
      expect(BigInt(HotWord.withoutRefill(word))).toBe(plain)
      expect(HotWord.decodeEntry(word).refill).toBe(refill)
      if (bits === 0n) HotWord.decode(word)
      else
        expect(() => HotWord.decode(word)).toThrow(Errors.InvalidHotWordError)
    }
    const cancelledRefill = Post.order({
      ...order,
      sides: 'neither',
      refill: 'both',
    }).word
    expect(BigInt(cancelledRefill) >> 240n).toBe(15n)
    for (const [sides, flags] of [
      ['both', 0],
      ['bids', 2],
      ['asks', 1],
      ['neither', 3],
    ] as const) {
      const word = Post.order({ ...order, sides }).word
      expect(HotWord.toFields(word).flags).toBe(flags)
      expect(HotWord.decode(word).sides).toBe(sides)
      expect(HotWord.sideOff(HotWord.decode(word), true)).toBe(
        sides === 'asks' || sides === 'neither',
      )
      expect(HotWord.sideOff(HotWord.decode(word), false)).toBe(
        sides === 'bids' || sides === 'neither',
      )
    }
  })

  test('name the field, flags or word each hot-word refusal is about', () => {
    const fields = HotWord.toFields(
      Post.order({
        pairIndex: 0,
        mid: Price.one,
        shapeId: 0,
        sequence: 2,
        validUntil: 1,
      }).word,
    )
    const refusals = [
      () => HotWord.fromFields({ ...fields, mid: 1n << 96n }),
      () => HotWord.fromFields({ ...fields, validUntil: 2 ** 40 }),
      () => HotWord.fromFields({ ...fields, flags: 1.5 }),
      () => HotWord.fromFields(null as never),
      () => HotWord.decode(HotWord.fromFields({ ...fields, flags: 4 })),
      () => HotWord.decodeEntry(HotWord.fromFields({ ...fields, flags: 16 })),
      () => HotWord.sidesFlags('up' as never),
      () => HotWord.refillFlags('all' as never),
      () => HotWord.toFields(`0x${'00'.repeat(33)}`),
    ].map((fn) => {
      try {
        fn()
      } catch (error) {
        // A mid is a price, and a sides value an argument, wherever they come in; the rest is the word's own.
        const e = error as Errors.InvalidHotWordError
        return [e.name, e.parameter ?? e.flags ?? null, e.shortMessage]
      }
      throw new Error('expected a throw')
    })
    expect(refusals).toMatchInlineSnapshot(`
      [
        [
          "InvalidPriceError",
          "mid",
          "mid must be a uint96 bigint (quote per base, scaled by 1e18), got 79228162514264337593543950336n",
        ],
        [
          "InvalidHotWordError",
          "validUntil",
          "validUntil must be an integer in [0, 2^40 - 1], got 1099511627776",
        ],
        [
          "InvalidHotWordError",
          "flags",
          "flags must be an integer in [0, 65535], got 1.5",
        ],
        [
          "InvalidHotWordError",
          "fields",
          "a hot word's fields are an object, got null",
        ],
        [
          "InvalidHotWordError",
          4,
          "stored hot words carry only the off flags (0-3), got flags 4",
        ],
        [
          "InvalidHotWordError",
          16,
          "reserved flag bits (4-15) set, got flags 16",
        ],
        [
          "InvalidArgumentError",
          "sides",
          "sides must be 'both', 'bids', 'asks' or 'neither', got "up"",
        ],
        [
          "InvalidArgumentError",
          "refill",
          "refill must be 'both', 'bids', 'asks' or 'neither', got "all"",
        ],
        [
          "InvalidHotWordError",
          null,
          "a hot word is exactly 32 bytes of hex, got "0x000000000000000000000000000000000000000000000000000000000000000000"",
        ],
      ]
    `)
  })

  test('decode flags into sides and refills: the inverses of sidesFlags and refillFlags', () => {
    const all: HotWord.Sides[] = ['both', 'bids', 'asks', 'neither']
    for (const off of all)
      for (const refill of all) {
        const flags = HotWord.sidesFlags(off) | HotWord.refillFlags(refill)
        expect(
          [HotWord.sidesFromFlags(flags), HotWord.refillFromFlags(flags)],
          `flags ${flags}`,
        ).toEqual([off, refill])
      }
    // Every flag value 0-15 decodes the way a word with those flags does.
    for (let flags = 0; flags <= HotWord.flagsMask; flags++) {
      const entry = HotWord.decodeEntry(
        HotWord.fromFields({
          ...HotWord.toFields(HotWord.initial),
          mid: Price.one,
          flags,
        }),
      )
      expect([
        HotWord.sidesFromFlags(flags),
        HotWord.refillFromFlags(flags),
      ]).toEqual([entry.sides, entry.refill])
    }
    const refusals = [
      16,
      -1,
      1.5,
      Number.NaN,
      2 ** 53,
      2 ** 32 + 1,
      2 ** 33 + 4,
    ].flatMap((flags) =>
      [HotWord.sidesFromFlags, HotWord.refillFromFlags].map((fn) => {
        try {
          fn(flags)
        } catch (error) {
          const e = error as Errors.InvalidArgumentError
          return [e.name, e.parameter, e.shortMessage]
        }
        throw new Error('expected a throw')
      }),
    )
    expect(
      new Set(refusals.map(([name, parameter]) => `${name}:${parameter}`)),
    ).toEqual(new Set(['InvalidArgumentError:flags']))
    expect(refusals[0]?.[2]).toBe('flags must be an integer in [0, 15], got 16')
  })

  test("take a word's raw fields as they are: flags in place of sides and refill, the same word", () => {
    const fields: HotWord.Fields = {
      mid: Price.parse('1.085'),
      bidWiden: 3,
      askWiden: 4,
      widthScale: 900,
      depthScale: 1100,
      shapeId: 7,
      validUntil: 1_800_000_060,
      sequence: 5,
      flags: 0,
    }
    const all: HotWord.Sides[] = ['both', 'bids', 'asks', 'neither']
    for (const sides of all)
      for (const refill of all) {
        const flags = HotWord.sidesFlags(sides) | HotWord.refillFlags(refill)
        const named = Post.order({
          pairIndex: 2,
          ...fields,
          flags: undefined,
          sides,
          refill,
        })
        const raw = Post.order({ pairIndex: 2, ...fields, flags })
        expect(raw, `flags ${flags}`).toStrictEqual(named)
        expect(HotWord.toFields(raw.word)).toStrictEqual({ ...fields, flags })
      }
    // A stored word's fields requote it as they are.
    const stored = HotWord.toFields(
      Post.order({ pairIndex: 0, ...fields, flags: HotWord.flagBidsOff }).word,
    )
    expect(
      HotWord.decodeEntry(
        Post.order({ pairIndex: 0, ...stored, sequence: stored.sequence + 1 })
          .word,
      ),
    ).toMatchObject({ sides: 'asks', refill: 'neither', sequence: 6 })
    const refusals = [
      { ...fields, flags: 16 },
      { ...fields, flags: -1 },
      { ...fields, flags: 1.5 },
      // The type rules these two out; a caller without it (JavaScript, a cast) is refused at run time.
      { ...fields, flags: 0, sides: 'both' as const },
      { ...fields, flags: 0, refill: 'neither' as const },
    ].map((request) => {
      try {
        Post.order({ pairIndex: 2, ...request } as Post.OrderRequest)
      } catch (error) {
        const e = error as Errors.InvalidOrderError
        return [e.name, e.parameter, e.pairIndex, e.shortMessage]
      }
      throw new Error('expected a throw')
    })
    expect(refusals).toStrictEqual([
      [
        'InvalidOrderError',
        'flags',
        2,
        'pair 2: flags must be an integer in [0, 15] (bits 4-15 are reserved), got 16',
      ],
      [
        'InvalidOrderError',
        'flags',
        2,
        'pair 2: flags must be an integer in [0, 15] (bits 4-15 are reserved), got -1',
      ],
      [
        'InvalidOrderError',
        'flags',
        2,
        'pair 2: flags must be an integer in [0, 15] (bits 4-15 are reserved), got 1.5',
      ],
      [
        'InvalidOrderError',
        'flags',
        2,
        'pair 2: flags must not come with sides or refill, got 0',
      ],
      [
        'InvalidOrderError',
        'flags',
        2,
        'pair 2: flags must not come with sides or refill, got 0',
      ],
    ])
    // The other fields are checked first, in their usual order.
    expect(() =>
      Post.order({ pairIndex: 2, ...fields, sequence: 1, flags: 16 }),
    ).toThrow(/sequence/)
  })

  test('round-trip every hot-word field (seeded)', () => {
    const next = rng(42n)
    const sides = ['both', 'bids', 'asks', 'neither'] as const
    for (let i = 0; i < 2_000; i++) {
      const fields = {
        mid: next(96) || 1n,
        bidWiden: Number(next(16)),
        askWiden: Number(next(16)),
        widthScale: Number(next(16)),
        depthScale: Number(next(16)),
        shapeId: Number(next(8)),
        validUntil: Number(next(40)),
        sequence: Math.max(2, Number(next(32))),
        sides: sides[Number(next(2))] as HotWord.Sides,
      }
      const { word } = Post.order({ pairIndex: 0, ...fields })
      expect(HotWord.decode(word)).toStrictEqual(fields)
      expect(HotWord.fromFields({ ...HotWord.toFields(word) })).toBe(word)
    }
    expect(
      () => HotWord.decode('0x1234567'.padEnd(67, '0') as `0x${string}`),
      '33 bytes',
    ).toThrow(Errors.InvalidHotWordError)
    expect(() => HotWord.decode('0xzz')).toThrow(Errors.InvalidHotWordError)
  })
})

describe('Shape', () => {
  test('owns decoded words independently of the caller and encodes the original shape', () => {
    const original = Shape.from({
      bids: Array.from({ length: 6 }, (_, i) => ({ size: i + 1, spread: i })),
      asks: Array.from({ length: 6 }, (_, i) => ({
        size: i + 7,
        spread: i + 2,
      })),
    })
    const words: bigint[] = [...original.words]
    const shape = Shape.fromWords(words)
    words.fill(0n)

    expect(shape.words).not.toBe(words)
    expect(shape).toStrictEqual(original)
    expect(Shape.fromWords(shape.words)).toStrictEqual(shape)
    const call = Actions.venue.setShape.call({
      venue: VENUE,
      pairIndex: 0,
      shapeId: 7,
      shape,
    })
    expect(
      decodeFunctionData({ abi: Abis.venueAbi, data: call.data }).args,
    ).toStrictEqual([0, 7, original.words])
  })

  test('rejects ambiguous or non-monotone ladders', () => {
    expect(() =>
      Shape.from({ bids: [{ size: 0, spread: 0 }], asks: [] }),
    ).toThrow(Errors.InvalidShapeError)
    expect(() =>
      Shape.from({
        bids: [
          { size: 1, spread: 20 },
          { size: 2, spread: 19 },
        ],
        asks: [],
      }),
    ).toThrow(Errors.InvalidShapeError)
    expect(() =>
      Shape.from({
        bids: Array.from({ length: 11 }, () => ({ size: 1, spread: 10 })),
        asks: [],
      }),
    ).toThrow(Errors.InvalidShapeError)
    expect(() =>
      Shape.from({ bids: [{ size: 2 ** 32, spread: 0 }], asks: [] }),
    ).toThrow(Errors.InvalidShapeError)
    expect(() =>
      Shape.from({ bids: [], asks: [{ size: 1, spread: 65_536 }] }),
    ).toThrow(Errors.InvalidShapeError)
    expect(() =>
      Shape.from({ bids: [], asks: [{ size: 1.5, spread: 0 }] }),
    ).toThrow(Errors.InvalidShapeError)
    const shape = Shape.from({
      bids: Array.from({ length: 10 }, () => ({ size: 50_000, spread: 20 })),
      asks: [{ size: 2 ** 32 - 1, spread: 65_535 }],
    })
    expect(Shape.fromWords(shape.words)).toStrictEqual(shape)
    expect(Shape.from({ bids: [], asks: [] })).toStrictEqual(Shape.empty)
    expect(Shape.check(Shape.empty.words)).toBe(0)
  })

  test("returns ShapeWord.check's exact reason, bids before asks", () => {
    const one = Shape.from({
      bids: [{ size: 5, spread: 3 }],
      asks: [{ size: 5, spread: 3 }],
    }).words
    const reserved = 1n << 240n
    expect(Shape.check([one[0] | reserved, one[1], one[2], one[3]])).toBe(
      Shape.reasonReservedBits,
    )
    expect(Shape.check([one[0], one[1], one[2], reserved])).toBe(
      Shape.reasonReservedBits,
    )
    // A spread on an empty level, and a level after a hole.
    expect(Shape.check([one[0] | (1n << (48n + 32n)), 0n, 0n, 0n])).toBe(
      Shape.reasonNonCanonical,
    )
    expect(Shape.check([one[0] | (7n << 96n), 0n, 0n, 0n])).toBe(
      Shape.reasonNonCanonical,
    )
    expect(
      Shape.check([one[0], 1n, 0n, 0n]),
      'second word without level 5',
    ).toBe(Shape.reasonNonCanonical)
    // Decreasing spreads.
    const down = BigInt(5) | (3n << 32n) | ((BigInt(5) | (2n << 32n)) << 48n)
    expect(Shape.check([0n, 0n, down, 0n])).toBe(Shape.reasonSpreadDecreases)
    // Bids are checked first.
    expect(Shape.check([one[0], 1n, down, 0n])).toBe(Shape.reasonNonCanonical)
    expect(() => Shape.fromWords([0n, 0n, down, 0n])).toThrow(
      expect.objectContaining({ name: 'InvalidShapeError', reason: 3 }),
    )
    expect(() => Shape.check([0n, 0n, 0n])).toThrow(Errors.InvalidShapeError)
    expect(() => Shape.check([0n, 0n, 0n, 1n << 256n])).toThrow(
      Errors.InvalidShapeError,
    )
  })

  test('asserts and validates words, and decodes a side back to its levels', () => {
    const shape = Shape.from({
      bids: Array.from({ length: 6 }, (_, i) => ({ size: i + 1, spread: i })),
      asks: [{ size: 7, spread: 3 }],
    })
    expect(Shape.assert(shape.words)).toBe(undefined)
    expect(Shape.validate(shape.words)).toBe(true)
    for (const bad of [
      [0n, 1n, 0n, 0n],
      [1n << 240n, 0n, 0n, 0n],
      [0n, 0n, 0n],
      [0n, 0n, 0n, -1n],
      [0n, 0n, 0n, 1n << 256n],
      'words',
    ] as const) {
      expect(() => Shape.assert(bad as never), String(bad)).toThrow(
        Errors.InvalidShapeError,
      )
      expect(Shape.validate(bad as never), String(bad)).toBe(false)
    }
    const [b0, b1] = Shape.side(shape.words, 'bids')
    expect(Shape.decodeSide(b0, b1)).toStrictEqual(shape.bids)
    expect(Shape.encodeSide(Shape.decodeSide(b0, b1))).toStrictEqual([b0, b1])
    // Six bid levels continue into the second word; one ask level doesn't.
    expect(Shape.continues(b0)).toBe(true)
    expect(Shape.continues(Shape.side(shape.words, 'asks')[0])).toBe(false)
    expect(() => Shape.side(shape.words, 'both' as never)).toThrow(
      Errors.InvalidArgumentError,
    )
    expect(() => Shape.rawLevel(-1n, 0n, 0)).toThrow(Errors.InvalidShapeError)
    expect(() => Shape.checkSide(0n, 1 as never)).toThrow(
      Errors.InvalidShapeError,
    )
  })

  test('rejects sparse ladder slots before encoding either word', () => {
    const sparse: Shape.Level[][] = [new Array(1), new Array(10)]
    for (const index of [0, 2, 5, 9]) {
      const ladder = Array.from({ length: 10 }, () => ({ size: 1, spread: 0 }))
      delete ladder[index]
      sparse.push(ladder)
    }
    for (const ladder of sparse) {
      const index = Array.from({ length: ladder.length }, (_, i) => i).find(
        (i) => !(i in ladder),
      )
      for (const name of ['side', 'bids', 'asks'] as const) {
        const encode = () =>
          name === 'side'
            ? Shape.encodeSide(ladder)
            : Shape.from({ bids: [], asks: [], [name]: ladder })
        expect(encode).toThrow(
          expect.objectContaining({
            name: 'InvalidShapeError',
            parameter: `${name}[${index}]`,
            value: undefined,
          }),
        )
      }
    }
    for (const length of [0, 5, 6, 10]) {
      const ladder = Array.from({ length }, (_, i) => ({
        size: i + 1,
        spread: i,
      }))
      const words = Shape.encodeSide(ladder)
      expect(Shape.checkSide(...words)).toBe(0)
      expect(Shape.decodeSide(...words)).toStrictEqual(ladder)
    }
  })

  test('name the level, field and value each refusal is about', () => {
    const refusals = [
      () => Shape.from({ bids: [{ size: 0, spread: 0 }], asks: [] }),
      () => Shape.from({ bids: [], asks: [{ size: 1, spread: 65_536 }] }),
      () =>
        Shape.from({
          bids: [
            { size: 1, spread: 20 },
            { size: 1, spread: 19 },
          ],
          asks: [],
        }),
      () =>
        Shape.from({
          bids: Array.from({ length: 11 }, () => ({ size: 1, spread: 0 })),
          asks: [],
        }),
      () => Shape.from({ bids: [null as never], asks: [] }),
      () => Shape.from(null as never),
      () => Shape.fromWords([0n, 1n, 0n, 0n]),
      () => Shape.check([0n, 0n, 0n, 1.5 as never]),
    ].map((fn) => {
      try {
        fn()
      } catch (error) {
        const e = error as Errors.InvalidShapeError
        expect(e).toBeInstanceOf(Errors.InvalidShapeError)
        return [e.parameter, e.reason, e.shortMessage]
      }
      throw new Error('expected a throw')
    })
    expect(refusals).toMatchInlineSnapshot(`
      [
        [
          "bids[0].size",
          undefined,
          "bids[0].size must be an integer in [1, 2^32 - 1], got 0",
        ],
        [
          "asks[0].spread",
          undefined,
          "asks[0].spread must be an integer in [0, 65535], got 65536",
        ],
        [
          "bids[1].spread",
          undefined,
          "bids[1].spread 19 is below the level before it (20)",
        ],
        [
          "bids",
          undefined,
          "bids: at most 10 levels per side, got 11",
        ],
        [
          "bids[0]",
          undefined,
          "bids[0] must be a level, got null",
        ],
        [
          "ladders",
          undefined,
          "a shape's ladders are { bids, asks }, got null",
        ],
        [
          "words",
          2,
          "shape words are not canonical: ShapeWord reason 2 (non-canonical)",
        ],
        [
          "words[3]",
          undefined,
          "a shape word is a uint256 bigint, got 1.5",
        ],
      ]
    `)
  })

  test('encodes into setShape words', () => {
    const shape = Shape.from({
      bids: [{ size: 50_000, spread: 20 }],
      asks: [{ size: 50_000, spread: 20 }],
    })
    expect(shape.words).toStrictEqual([
      50_000n | (20n << 32n),
      0n,
      50_000n | (20n << 32n),
      0n,
    ])
    const call = Actions.venue.setShape.call({
      venue: VENUE,
      pairIndex: 0,
      shapeId: 7,
      shape,
    })
    expect(
      decodeFunctionData({ abi: Abis.venueAbi, data: call.data }).args,
    ).toStrictEqual([0, 7, shape.words])
    expect(numberToHex(shape.words[0])).toBe('0x140000c350')
  })
})
