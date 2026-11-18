// The pure modules' public types: ox-style assertions return void, validations return booleans or narrow, each
// function names its ErrorType, and the decoded shapes have exactly the fields the contracts carry.
import type { Hex } from 'viem'
import { describe, expectTypeOf, test } from 'vitest'
import {
  Errors,
  Fees,
  HotWord,
  type Ladder,
  Post,
  Price,
  Shape,
  type TakerAccess,
} from '../src/index.js'

describe('Price', () => {
  test('asserts return void, validates return a boolean, from takes either form', () => {
    expectTypeOf(Price.assert).returns.toEqualTypeOf<void>()
    expectTypeOf(Price.validate).returns.toEqualTypeOf<boolean>()
    expectTypeOf(Price.from).parameter(0).toEqualTypeOf<string | bigint>()
    expectTypeOf(Price.from).returns.toEqualTypeOf<bigint>()
    expectTypeOf(Price.format).parameter(0).toEqualTypeOf<bigint>()
    expectTypeOf<Price.parse.ErrorType>().toEqualTypeOf<
      Errors.InvalidPriceErrorType | Errors.GlobalErrorType
    >()
    expectTypeOf<Price.from.ErrorType>().toEqualTypeOf<
      Errors.InvalidPriceErrorType | Errors.GlobalErrorType
    >()
  })
})

describe('Errors', () => {
  test('assertAccess and validateAccess narrow a raw read to TakerAccess', () => {
    expectTypeOf(Errors.assertAccess).returns.toEqualTypeOf<void>()
    const raw: unknown = 1
    if (Errors.validateAccess(raw))
      expectTypeOf(raw).toEqualTypeOf<TakerAccess>()
    const read: unknown = 1
    Errors.assertAccess(read)
    expectTypeOf(read).toEqualTypeOf<TakerAccess>()
  })

  test('decode and errorOf return their declared shapes', () => {
    expectTypeOf(Errors.decode).returns.toEqualTypeOf<Errors.Decoded | null>()
    expectTypeOf<Errors.Decoded['selector']>().toEqualTypeOf<Hex | null>()
    expectTypeOf(Errors.errorOf).parameter(0).toEqualTypeOf<Hex>()
    expectTypeOf<
      NonNullable<ReturnType<typeof Errors.errorOf>>['type']
    >().toEqualTypeOf<'error'>()
    expectTypeOf<Errors.GlobalErrorType>().toExtend<Error>()
    expectTypeOf<
      Errors.InvalidOrderErrorType['name']
    >().toEqualTypeOf<'InvalidOrderError'>()
  })
})

describe('HotWord', () => {
  test("takes 32-byte hex words, never bigints, and names its fields as Solidity's", () => {
    expectTypeOf(HotWord.decode).parameter(0).toEqualTypeOf<Hex>()
    expectTypeOf(HotWord.toFields).parameter(0).toEqualTypeOf<Hex>()
    expectTypeOf(HotWord.fromFields).returns.toEqualTypeOf<Hex>()
    expectTypeOf(HotWord.assert).returns.toEqualTypeOf<void>()
    expectTypeOf(HotWord.validate).returns.toEqualTypeOf<boolean>()
    expectTypeOf<keyof HotWord.Fields>().toEqualTypeOf<
      | 'mid'
      | 'bidWiden'
      | 'askWiden'
      | 'widthScale'
      | 'depthScale'
      | 'shapeId'
      | 'validUntil'
      | 'sequence'
      | 'flags'
    >()
    expectTypeOf<HotWord.HotWord>().toEqualTypeOf<
      Omit<HotWord.Fields, 'flags'> & { sides: HotWord.Sides }
    >()
    expectTypeOf<HotWord.HotWord['sequence']>().toEqualTypeOf<number>()
    expectTypeOf<HotWord.Entry['refill']>().toEqualTypeOf<HotWord.Sides>()
    expectTypeOf<HotWord.Sides>().toEqualTypeOf<
      'both' | 'bids' | 'asks' | 'neither'
    >()
    expectTypeOf(HotWord.initial).toEqualTypeOf<Hex>()
    expectTypeOf<HotWord.decode.ErrorType>().toEqualTypeOf<
      Errors.InvalidHotWordErrorType | Errors.GlobalErrorType
    >()
  })
})

describe('Shape', () => {
  test('words are four bigints; reasons are ShapeWord codes', () => {
    expectTypeOf<Shape.Words>().toEqualTypeOf<
      readonly [bigint, bigint, bigint, bigint]
    >()
    expectTypeOf<Shape.Shape['words']>().toEqualTypeOf<Shape.Words>()
    expectTypeOf(Shape.check).returns.toEqualTypeOf<Shape.Reason>()
    expectTypeOf<Shape.Reason>().toEqualTypeOf<0 | 1 | 2 | 3>()
    expectTypeOf(Shape.assert).returns.toEqualTypeOf<void>()
    expectTypeOf(Shape.validate).returns.toEqualTypeOf<boolean>()
    expectTypeOf(Shape.decodeSide).returns.toEqualTypeOf<Shape.Level[]>()
    expectTypeOf(Shape.encodeSide).returns.toEqualTypeOf<[bigint, bigint]>()
    expectTypeOf(Shape.continues).returns.toEqualTypeOf<boolean>()
    expectTypeOf(Shape.from).returns.toEqualTypeOf<Shape.Shape>()
  })
})

describe('Ladder', () => {
  test('a fill result narrows on ok', () => {
    const result = {} as Ladder.FillResult
    if (result.ok) {
      expectTypeOf(result.amountIn).toEqualTypeOf<bigint>()
      expectTypeOf(result.baseFilled).toEqualTypeOf<bigint>()
    } else
      expectTypeOf(result.error).toEqualTypeOf<
        'InsufficientDepth' | 'ZeroFill'
      >()
    // The uint16 fields are numbers and the uint64 and wider ones bigints, as everywhere else.
    expectTypeOf<Ladder.Curve>().toEqualTypeOf<{
      mid: bigint
      widen: number
      widthScale: number
      depthScale: number
      sizeUnit: bigint
      bid: boolean
    }>()
    expectTypeOf(Shape.rawLevel).returns.toEqualTypeOf<Shape.Level>()
    expectTypeOf<Ladder.Consumed>().toEqualTypeOf<{
      bids: bigint
      asks: bigint
    }>()
    expectTypeOf<Ladder.fill.ErrorType>().toEqualTypeOf<
      | Errors.AmountOutOfRangeErrorType
      | Errors.InvalidPriceErrorType
      | Errors.InvalidArgumentErrorType
      | Errors.InvalidHotWordErrorType
      | Errors.InvalidShapeErrorType
      | Errors.GlobalErrorType
    >()
  })
})

describe('Post', () => {
  test('order throws one error class; pack names its result', () => {
    expectTypeOf<Post.order.ErrorType>().toEqualTypeOf<
      Errors.InvalidOrderErrorType | Errors.GlobalErrorType
    >()
    expectTypeOf(Post.pack).returns.toEqualTypeOf<Post.pack.ReturnValue>()
    expectTypeOf<Post.pack.ReturnValue>().toEqualTypeOf<{
      packed: Hex
      posts: Post.PostRef[]
    }>()
    expectTypeOf(Post.unpack).returns.toEqualTypeOf<Post.Entry[]>()
    expectTypeOf<Post.CancelRequest>().toEqualTypeOf<{
      pairIndex: number
      sequence: number
      mid: bigint
    }>()
    expectTypeOf(Post.cancel).toBeCallableWith({
      pairIndex: 0,
      sequence: 2,
      mid: 1n,
    })
  })
})

describe('Fees', () => {
  test('feeFields and takerFields take their multiplier as a named option', () => {
    expectTypeOf(Fees.feeFields).toBeCallableWith(1n, 1n)
    expectTypeOf(Fees.feeFields).toBeCallableWith(1n, 1n, {
      baseFeeMultiplier: undefined,
    })
    expectTypeOf(Fees.feeFields).toBeCallableWith(1n, 1n, {
      baseFeeMultiplier: 1.2,
    })
    expectTypeOf<Fees.feeFields.Options>().toEqualTypeOf<{
      baseFeeMultiplier?: number | undefined
    }>()
    expectTypeOf(Fees.feeFields).returns.toEqualTypeOf<{
      maxFeePerGas: bigint
      maxPriorityFeePerGas: bigint
    }>()
    expectTypeOf(Fees.takerFields).toBeCallableWith(1n, 1n, 1n)
    expectTypeOf(Fees.takerFields).toBeCallableWith(1n, 1n, 1n, {
      baseFeeMultiplier: 1.2,
    })
    expectTypeOf<Fees.takerFields.Options>().toEqualTypeOf<Fees.feeFields.Options>()
    expectTypeOf(Fees.takerFields).returns.toEqualTypeOf<{
      maxFeePerGas: bigint
      maxPriorityFeePerGas: bigint
    }>()
    expectTypeOf<typeof Fees.defaultBaseFeeMultiplier>().toEqualTypeOf<3>()
  })
})
