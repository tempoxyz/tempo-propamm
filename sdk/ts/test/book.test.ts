import { describe, expect, test } from 'vitest'
import { Book, HotWord, Post, Price, Shape } from '../src/index.js'

const PAIR: Book.Pair = {
  hot: HotWord.decode(
    Post.order({
      pairIndex: 0,
      mid: Price.one,
      shapeId: 0,
      sequence: 2,
      validUntil: 1_800_000_060,
    }).word,
  ),
  sizeUnit: 10n,
  shapeWords: Shape.from({
    bids: [
      { size: 20, spread: 10 },
      { size: 30, spread: 20 },
      { size: 50, spread: 30 },
    ],
    asks: [
      { size: 20, spread: 10 },
      { size: 30, spread: 20 },
      { size: 50, spread: 30 },
    ],
  }).words,
  consumed: { bids: 0n, asks: 0n },
}
const SIDES = ['bids', 'asks'] as const
const LIVE = { at: 1_800_000_000n, halted: false }
const MAX_CONSUMED = (1n << 120n) - 1n

describe('Book consumption', () => {
  test.each(SIDES)(
    'validates %s even when reading the other side or no size unit',
    (field) => {
      for (const value of [-1n, 1n << 120n, 0, '0', null, undefined]) {
        const consumed = {
          ...PAIR.consumed,
          [field]: value,
        } as Book.Pair['consumed']
        for (const which of SIDES) {
          for (const sizeUnit of [0n, PAIR.sizeUnit]) {
            const pair = { ...PAIR, consumed, sizeUnit }
            const refusal = expect.objectContaining({
              name: 'InvalidArgumentError',
              parameter: `consumed.${field}`,
              value,
            })
            expect(() => Book.ladder(pair, which)).toThrow(refusal)
            expect(() => Book.side(pair, which, LIVE)).toThrow(refusal)
            expect(() => Book.remaining(pair, which, LIVE)).toThrow(refusal)
          }
        }
      }
    },
  )

  test('refuses consumption that is not an object with named SDK errors', () => {
    for (const consumed of [null, undefined, 'consumed', 0]) {
      const pair = { ...PAIR, consumed: consumed as never }
      expect(() => Book.ladder(pair, 'bids')).toThrow(
        expect.objectContaining({
          name: 'InvalidArgumentError',
          parameter: 'consumed',
          value: consumed,
        }),
      )
    }
  })

  test('subtracts each side independently across multiple levels', () => {
    const pair = { ...PAIR, consumed: { bids: 275n, asks: 675n } }
    expect(Book.ladder(pair, 'bids').map((row) => row.remaining)).toStrictEqual(
      [0n, 225n, 500n],
    )
    expect(Book.ladder(pair, 'asks').map((row) => row.remaining)).toStrictEqual(
      [0n, 0n, 325n],
    )
    expect(Book.remaining(pair, 'bids', LIVE)).toBe(725n)
    expect(Book.remaining(pair, 'asks', LIVE)).toBe(325n)
    for (const which of SIDES)
      expect(Book.ladder(pair, which).map((row) => row.depth)).toStrictEqual([
        200n,
        300n,
        500n,
      ])
  })

  test.each(SIDES)(
    'accepts zero and uint120 maximum consumption for %s',
    (which) => {
      const fresh = Book.ladder(PAIR, which)
      expect(fresh.map((row) => row.remaining)).toStrictEqual([
        200n,
        300n,
        500n,
      ])
      const exhausted = {
        ...PAIR,
        consumed: { bids: MAX_CONSUMED, asks: MAX_CONSUMED },
      }
      expect(
        Book.ladder(exhausted, which).map((row) => row.remaining),
      ).toStrictEqual([0n, 0n, 0n])
      expect(Book.ladder({ ...exhausted, sizeUnit: 0n }, which)).toStrictEqual(
        [],
      )
    },
  )
})
