// Fees against the venue's own rule, `Venue._priorityFeeTooHigh(invertedCap)`: `invertedCap != 0 && fee > ~invertedCap`,
// with the cap stored bit-inverted in a uint64, so 0 (a new venue) reads as `NO_PRIORITY_FEE_CAP`, no cap.
import { describe, expect, test } from 'vitest'
import { Errors, Fees, Venue } from '../src/index.js'

const MASK = (1n << 64n) - 1n
/** `Venue._priorityFeeTooHigh`, on the cap as `setMaxTakerPriorityFee` stores it. */
const tooHigh = (cap: bigint, fee: bigint) => {
  const inverted = ~cap & MASK
  return inverted !== 0n && fee > (~inverted & MASK)
}
/** What an EIP-1559 transaction pays per gas above the base fee at inclusion. */
const effectiveTip = (
  fields: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint },
  baseFee: bigint,
) => {
  const room = fields.maxFeePerGas - baseFee
  return room < fields.maxPriorityFeePerGas ? room : fields.maxPriorityFeePerGas
}

const caps = [
  0n,
  1n,
  Fees.gwei,
  Venue.defaultTakerPriorityFeeCap,
  MASK - 1n,
  Venue.noPriorityFeeCap,
]

describe('Fees', () => {
  test('allows exactly the takes Venue._priorityFeeTooHigh lets through', () => {
    for (const cap of caps) {
      for (const fee of [
        0n,
        1n,
        cap === 0n ? 0n : cap - 1n,
        cap,
        cap + 1n,
        MASK,
        MASK + 1n,
        1n << 200n,
      ]) {
        expect(Fees.allows(cap, fee), `${cap} ${fee}`).toBe(!tooHigh(cap, fee))
      }
      expect(Fees.isNoCap(cap)).toBe(cap === Venue.noPriorityFeeCap)
    }
  })

  test("tips a post past every take's cap, and pays the tip while the base fee stays in range", () => {
    for (const cap of caps) {
      const tip = Fees.makerTip(cap)
      if (Fees.isNoCap(cap)) expect(tip).toBe(Fees.defaultMakerMargin)
      else {
        expect(tip).toBe(cap + Fees.defaultMakerMargin)
        expect(Fees.allows(cap, tip), 'no take tips as much').toBe(false)
      }
      const baseFee = 10n * Fees.gwei
      const fields = Fees.feeFields(baseFee, tip)
      expect(fields).toStrictEqual({
        maxFeePerGas: 3n * baseFee + tip,
        maxPriorityFeePerGas: tip,
      })
      // The whole tip while the base fee at inclusion is at most 3x today's; less once it is past that.
      for (const inclusion of [0n, baseFee, 3n * baseFee])
        expect(effectiveTip(fields, inclusion)).toBe(tip)
      expect(effectiveTip(fields, 3n * baseFee + 1n)).toBe(tip - 1n)
    }
    expect(Fees.priorityFee(30n, 20n)).toBe(10n)
    expect(Fees.priorityFee(10n, 20n)).toBe(0n)
  })

  test('builds fields only for a taker priority fee the venue accepts', () => {
    const baseFee = 10n * Fees.gwei
    const fields = Fees.takerFields(
      baseFee,
      Venue.defaultTakerPriorityFeeCap,
      Fees.gwei,
    )
    expect(fields).toStrictEqual(Fees.feeFields(baseFee, Fees.gwei))
    expect(
      Fees.takerFields(baseFee, Venue.noPriorityFeeCap, 2n * Fees.gwei),
    ).toStrictEqual(Fees.feeFields(baseFee, 2n * Fees.gwei))
    expect(() =>
      Fees.takerFields(
        baseFee,
        Venue.defaultTakerPriorityFeeCap,
        Venue.defaultTakerPriorityFeeCap + 1n,
      ),
    ).toThrow(/priorityFee must not exceed the venue's cap/)
  })

  test("scales the base fee by a named multiplier, as viem's estimateFeesPerGas does", () => {
    const baseFee = 10n * Fees.gwei
    expect(Fees.defaultBaseFeeMultiplier).toBe(3)
    // viem's default, 1.2: 12 gwei of base fee headroom.
    expect(
      Fees.feeFields(baseFee, Fees.gwei, { baseFeeMultiplier: 1.2 }),
    ).toStrictEqual({
      maxFeePerGas: 13n * Fees.gwei,
      maxPriorityFeePerGas: Fees.gwei,
    })
    expect(
      Fees.feeFields(baseFee, 0n, { baseFeeMultiplier: 1 }).maxFeePerGas,
    ).toBe(baseFee)
    expect(
      Fees.feeFields(7n, 0n, { baseFeeMultiplier: 1.25 }).maxFeePerGas,
    ).toBe(8n)
    expect(
      Fees.feeFields(baseFee, 1n, { baseFeeMultiplier: undefined }),
    ).toStrictEqual(Fees.feeFields(baseFee, 1n))
  })

  test('refuse what no venue or transaction carries, naming it', () => {
    const refusals = [
      () => Fees.isNoCap(MASK + 1n),
      () => Fees.allows(-1n, 0n),
      () => Fees.allows(0n, -1n),
      () => Fees.makerTip(10 as never),
      () => Fees.makerTip(MASK + 1n),
      () => Fees.makerTip(10n, 0n),
      () => Fees.priorityFee(-1n, 0n),
      () => Fees.feeFields(1n, 1 as never),
      () => Fees.feeFields(1n, 1n, { baseFeeMultiplier: 0.5 }),
      () => Fees.feeFields(1n, 1n, { baseFeeMultiplier: Number.NaN }),
      () => Fees.takerFields(1n, 1n, 2n),
    ].map((fn) => {
      try {
        fn()
      } catch (error) {
        expect(error).toBeInstanceOf(Errors.InvalidArgumentError)
        const e = error as Errors.InvalidArgumentError
        return `${e.parameter}: ${e.shortMessage}`
      }
      throw new Error('expected a throw')
    })
    expect(refusals).toMatchInlineSnapshot(`
      [
        "cap: cap must be a bigint in [0, 2^64 - 1], got 18446744073709551616n",
        "cap: cap must be a bigint in [0, 2^64 - 1], got -1n",
        "priorityFee: priorityFee must be a bigint in [0, 2^256 - 1], got -1n",
        "cap: cap must be a bigint in [0, 2^64 - 1], got 10",
        "cap: cap must be a bigint in [0, 2^64 - 1], got 18446744073709551616n",
        "margin: a maker tip margin is at least 1 wei per gas, got 0n",
        "gasPrice: gasPrice must be a bigint in [0, 2^256 - 1], got -1n",
        "priorityFee: priorityFee must be a bigint in [0, 2^256 - 1], got 1",
        "baseFeeMultiplier: baseFeeMultiplier must be a finite number of at least 1, got 0.5",
        "baseFeeMultiplier: baseFeeMultiplier must be a finite number of at least 1, got NaN",
        "priorityFee: priorityFee must not exceed the venue's cap, got 2n above 1n",
      ]
    `)
  })
})
