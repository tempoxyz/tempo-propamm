// Revert decoding over every error the SDK's contracts and the TIP-20 precompile declare, and the errors the SDK throws.
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import {
  type AbiParameter,
  type Address,
  BaseError,
  ContractFunctionRevertedError,
  createClient,
  custom,
  encodeErrorResult,
  getAddress,
  type Hex,
  http,
  RawContractError,
  toFunctionSelector,
  zeroAddress,
} from 'viem'
import { describe, expect, test } from 'vitest'
import { venueAbi } from '../src/generated/abis.js'
import {
  Abis,
  Actions,
  Book,
  Errors,
  Fees,
  HotWord,
  Info,
  Ladder,
  Plan,
  Post,
  Price,
  Quote,
  Roles,
  Sequencer,
  Shape,
  Snapshot,
  takerAccessNames,
} from '../src/index.js'
import { readOf, readValue } from '../src/internal/read.js'
import { version } from '../src/version.js'

/** This package's package.json: its name and version. */
const pkg = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf8'),
) as { name: string; version: string }

function sample(param: AbiParameter): unknown {
  if (param.type === 'address')
    return getAddress('0x00000000000000000000000000000000000000aa')
  if (param.type === 'bool') return true
  if (param.type.startsWith('bytes'))
    return `0x${'11'.repeat(Number(param.type.slice(5)) || 4)}`
  if (param.type === 'string') return 'x'
  const bits = Number(param.type.replace(/^u?int/, '') || 256)
  return bits <= 48 ? 7 : 7n
}

describe('Errors.decode', () => {
  test('decodes every declared error and names the contracts that declare it', () => {
    expect(
      Errors.allErrorsAbi.length,
      `${Errors.allErrorsAbi.length} errors`,
    ).toBeGreaterThan(80)
    for (const item of Errors.allErrorsAbi) {
      const args = item.inputs.map(sample)
      const data = encodeErrorResult({
        abi: [item],
        errorName: item.name,
        args,
      } as never)
      const d = Errors.decode(data)
      expect(d, item.name).toBeTruthy()
      expect(d?.errorName).toBe(item.name)
      expect(d?.args, item.name).toStrictEqual(args)
      expect(d?.selector).toBe(data.slice(0, 10))
      expect(
        d?.contracts.length,
        `${item.name} has a declaring contract`,
      ).toBeGreaterThan(0)
      expect(Errors.errorOf(d?.selector as `0x${string}`)?.name).toBe(item.name)
    }
  })

  test('lists every contract that shares a signature', () => {
    const d = Errors.decode(toFunctionSelector('ZeroAddress()'))
    expect([...(d?.contracts ?? [])].sort()).toStrictEqual([
      'Settler',
      'Venue',
      'VenueFactory',
    ])
    expect(
      Errors.decode(
        toFunctionSelector('UnknownVenue(address)') + '0'.repeat(64),
      )?.contracts,
    ).toStrictEqual(['Settler'])
    expect(
      Errors.decode(toFunctionSelector('InsufficientDepth()'))?.contracts,
    ).toStrictEqual(['Venue'])
    expect(
      Errors.decode(toFunctionSelector('PolicyForbids()'))?.contracts,
    ).toStrictEqual(['TIP20'])
  })

  test('finds the revert in viem error chains and in raw data', () => {
    const data = encodeErrorResult({
      abi: Abis.venueAbi,
      errorName: 'QuoteExpired',
      args: [12],
    })
    const raw = new RawContractError({ data })
    const wrapped = new BaseError('outer', { cause: raw })
    expect(Errors.decode(wrapped)?.errorName).toBe('QuoteExpired')
    expect(Errors.decode(wrapped)?.args).toStrictEqual([12])
    const reverted = new ContractFunctionRevertedError({
      abi: Abis.venueAbi,
      data,
      functionName: 'quote',
    })
    expect(
      Errors.decode(new BaseError('x', { cause: reverted }))?.errorName,
    ).toBe('QuoteExpired')
    const plain = Object.assign(new Error('rpc'), { cause: { data } })
    expect(Errors.decode(plain)?.errorName).toBe('QuoteExpired')
    expect(Errors.decode(new Error('network down'))).toBe(null)
    expect(Errors.decode(undefined)).toBe(null)
    // The error itself, with no cause; a node's `{ data: { data } }`; and a cause chain that loops.
    expect(Errors.decode(reverted)?.args).toStrictEqual([12])
    expect(
      Errors.decode(
        new BaseError('x', { cause: new RawContractError({ data: { data } }) }),
      )?.errorName,
    ).toBe('QuoteExpired')
    const loop: { cause?: unknown } = {}
    loop.cause = loop
    expect(
      Errors.decode(Object.assign(new Error('loop'), { cause: loop })),
    ).toBe(null)
    expect(
      Errors.decode(new BaseError('x', { cause: new RawContractError({}) })),
    ).toBe(null)
  })

  test('bounds deep and cyclic causes beneath viem errors', () => {
    let deep: unknown = {}
    for (let i = 0; i < 30_000; i++) deep = { cause: deep }
    const wrapped = Object.assign(new BaseError('rpc'), { cause: deep })
    expect(Errors.decode(wrapped)).toBeNull()
    expect(Errors.decode(deep)).toBeNull()
    const cyclic = new BaseError('rpc')
    cyclic.cause = { cause: cyclic }
    expect(Errors.decode(cyclic)).toBeNull()
  })

  test('uses the first revert data and bounds both kinds of wrapper at 16 objects', () => {
    const data = toFunctionSelector('ZeroFill()')
    for (const outer of [new BaseError('rpc'), new Error('rpc')]) {
      let cause: object = { data }
      for (let i = 0; i < 14; i++) cause = { cause }
      outer.cause = cause
      expect(Errors.decode(outer)?.errorName).toBe('ZeroFill')
      outer.cause = { cause }
      expect(Errors.decode(outer)).toBeNull()
      Object.assign(outer, { data: toFunctionSelector('InsufficientDepth()') })
      expect(Errors.decode(outer)?.errorName).toBe('InsufficientDepth')
    }
  })

  test('decodes a deep JSON-RPC failure from Info.meta without overflowing', async () => {
    const depth = 30_000
    const nested = `${'{"cause":'.repeat(depth)}{}${'}'.repeat(depth)}`
    const server = createServer((request, response) => {
      let body = ''
      request.on('data', (chunk) => {
        body += chunk
      })
      request.on('end', () => {
        const { id } = JSON.parse(body)
        response.setHeader('content-type', 'application/json')
        response.end(
          `{"jsonrpc":"2.0","id":${JSON.stringify(id)},"error":{"code":-32602,"message":"invalid params","cause":${nested}}}`,
        )
      })
    })
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    try {
      const address = server.address()
      if (!address || typeof address === 'string')
        throw new Error('no server address')
      const client = createClient({
        transport: http(`http://127.0.0.1:${address.port}`),
      })
      const error: unknown = await Info.meta(client, {
        venue: '0x1111111111111111111111111111111111111111',
      }).then(
        () => {
          throw new Error('expected RPC failure')
        },
        (error: unknown) => error,
      )
      expect(error).toBeInstanceOf(BaseError)
      expect((error as BaseError).name).toBe('InvalidParamsRpcError')
      expect(Errors.decode(error)).toBeNull()
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      )
    }
  })

  test('finds an error by its selector, in either case, from a table built once', () => {
    const selector = toFunctionSelector('QuoteExpired(uint40)')
    expect(Errors.errorOf(selector)?.name).toBe('QuoteExpired')
    expect(
      Errors.errorOf(selector.toUpperCase().replace('0X', '0x') as Hex),
    ).toBe(Errors.errorOf(selector))
    expect(Errors.errorOf('0xdeadbeef')).toBe(undefined)
    expect(Errors.errorOf(`${selector}${'00'.repeat(32)}`)).toBe(undefined)
    const zeroFill = toFunctionSelector('ZeroFill()')
    expect(
      Errors.decode(zeroFill.toUpperCase().replace('0X', '0x')),
    ).toMatchObject({
      errorName: 'ZeroFill',
      contracts: ['Venue'],
    })
  })

  test('reports unknown selectors, empty reverts and the builtins', () => {
    expect(Errors.decode('0xdeadbeef')).toMatchInlineSnapshot(`
      {
        "args": [],
        "contracts": [],
        "data": "0xdeadbeef",
        "errorName": null,
        "selector": "0xdeadbeef",
      }
    `)
    expect(Errors.decode('0x')).toMatchInlineSnapshot(`
      {
        "args": [],
        "contracts": [],
        "data": "0x",
        "errorName": null,
        "selector": null,
      }
    `)
    const panic = Errors.decode(`0x4e487b71${'0'.repeat(62)}11`)
    expect(panic?.errorName).toBe('Panic')
    expect(panic?.contracts).toStrictEqual([])
    expect(
      Errors.describe({ errorName: null, args: [], selector: '0xdeadbeef' }),
    ).toBe('unknown revert 0xdeadbeef')
  })
})

describe('access and revert descriptions', () => {
  test('put every TakerAccess value in words', () => {
    for (const n of takerAccessNames)
      expect(Errors.describeAccess(n).length).toBeGreaterThan(0)
    expect(Errors.describeAccess(8)).toBe(
      Errors.describeAccess('sponsorNotAdmitted'),
    )
    for (const [i] of takerAccessNames.entries()) {
      expect(Errors.assertAccess(i)).toBe(undefined)
      expect(Errors.validateAccess(i)).toBe(true)
    }
    for (const bad of [takerAccessNames.length, -1, 1.5, '1', 1n, null]) {
      expect(() => Errors.assertAccess(bad), String(bad)).toThrow(
        Errors.InvalidArgumentError,
      )
      expect(Errors.validateAccess(bad), String(bad)).toBe(false)
    }
    expect(
      (thrown(() => Errors.assertAccess(10n)) as Errors.InvalidArgumentError)
        .shortMessage,
    ).toMatchInlineSnapshot(`"not a TakerAccess value: 10n"`)
  })

  test('describe the ladder, access and fee-cap reverts in words', () => {
    expect(
      Errors.describe({
        errorName: 'InsufficientDepth',
        args: [],
        selector: null,
      }),
    ).toMatch(/consumed depth/)
    expect(
      Errors.describe({
        errorName: 'TakerPriorityFeeTooHigh',
        args: [2n, 1n],
        selector: null,
      }),
    ).toMatch(/above the venue's taker cap of 1/)
    expect(
      Errors.describe({
        errorName: 'TakerDenied',
        args: [zeroAddress],
        selector: null,
      }),
    ).toMatch(/denied/)
    expect(
      Errors.describe({
        errorName: 'MalformedPost',
        args: [3n],
        selector: null,
      }),
    ).toBe('MalformedPost(3)')
  })
})

/** What `fn` throws. */
function thrown(fn: () => unknown): unknown {
  try {
    fn()
  } catch (error) {
    return error
  }
  throw new Error('expected a throw')
}

const classes = Object.entries(Errors).filter(
  (entry): entry is [string, typeof Errors.BaseError] =>
    typeof entry[1] === 'function' &&
    entry[1].prototype instanceof Errors.BaseError,
)

describe('the errors the SDK throws', () => {
  test("extend viem's BaseError and name the SDK's version, not viem's", () => {
    const error = thrown(() => Price.parse('1.5e3'))
    expect(error).toBeInstanceOf(Errors.InvalidPriceError)
    expect(error).toBeInstanceOf(Errors.BaseError)
    expect(error).toBeInstanceOf(BaseError)
    const e = error as Errors.InvalidPriceError
    expect(e.name).toBe('InvalidPriceError')
    expect(e.value).toBe('1.5e3')
    expect(e.shortMessage).toBe(
      'price must be an unsigned decimal with at most 18 places, got "1.5e3"',
    )
    expect(e.version).toBe(`${pkg.name}@${pkg.version}`)
    expect(e.message).toMatchInlineSnapshot(`
      "price must be an unsigned decimal with at most 18 places, got "1.5e3"

      Version: @tempoxyz/propamm-sdk@<version>"
    `)
    expect(e.message).not.toMatch(/viem/)
  })

  test('carry their cause, details, meta messages and docs path', () => {
    const cause = new Error('execution reverted')
    const wrapped = new Errors.UnknownVenueError('no venue views', {
      venue: '0x1111111111111111111111111111111111111111',
      cause,
      metaMessages: ['venue: 0x1111111111111111111111111111111111111111'],
      docsPath: '#errors',
    })
    expect(wrapped.cause).toBe(cause)
    expect(wrapped.details).toBe('execution reverted')
    expect(wrapped.walk()).toBe(cause)
    expect(wrapped.message).toMatchInlineSnapshot(`
      "no venue views

      venue: 0x1111111111111111111111111111111111111111

      Docs: https://github.com/tempoxyz/propAMM/tree/main/sdk/ts#errors
      Details: execution reverted
      Version: @tempoxyz/propamm-sdk@<version>"
    `)
    // A cause from the SDK lends its details and docs path; one from viem lends its details only.
    const outer = new Errors.SnapshotIncompleteError('outer', {
      cause: wrapped,
    })
    expect(outer.details).toBe('execution reverted')
    expect(outer.docsPath).toBe('#errors')
    expect(outer.walk((e) => e instanceof Errors.UnknownVenueError)).toBe(
      wrapped,
    )
    const fromViem = new Errors.SnapshotIncompleteError('outer', {
      cause: new BaseError('viem says no', { docsPath: '/docs/x' }),
    })
    expect(fromViem.docsPath).toBe(undefined)
    expect(fromViem.message).not.toMatch(/viem\.sh|Version: viem/)
  })

  test('are one class per refusal, each named for itself', () => {
    expect(classes.map(([name]) => name)).toMatchInlineSnapshot(`
      [
        "AmountOutOfRangeError",
        "BatchTooLargeError",
        "DuplicatePairError",
        "EmptyBatchError",
        "InvalidAddressError",
        "InvalidArgumentError",
        "InvalidHotWordError",
        "InvalidOrderError",
        "InvalidPriceError",
        "InvalidShapeError",
        "MissingAccountError",
        "SequenceExhaustedError",
        "SnapshotIncompleteError",
        "SnapshotReorgedError",
        "UnexpectedResponseError",
        "UnknownPairError",
        "UnknownVenueError",
        "UnseededPairError",
      ]
    `)
    for (const [name, Class] of classes) {
      const error = new Class('x', {
        parameter: 'p',
        value: 1,
        address: '0x',
        pairIndex: 0,
        size: 1,
        maxSize: 0,
        chainId: 1,
        expectedChainId: 2,
        venue: '0x',
        blockNumber: 1n,
        hash: '0x',
        newHash: null,
      } as never)
      expect(error.name, name).toBe(name)
      expect(error).toBeInstanceOf(Errors.BaseError)
      expect(error.version).toBe(`${pkg.name}@${pkg.version}`)
    }
  })

  test('carry the values they refused as fields', () => {
    const shape = thrown(() =>
      Shape.fromWords([
        0n,
        0n,
        5n | (3n << 32n) | ((5n | (2n << 32n)) << 48n),
        0n,
      ]),
    )
    expect(shape).toBeInstanceOf(Errors.InvalidShapeError)
    expect((shape as Errors.InvalidShapeError).reason).toBe(3)
    const batch = thrown(() =>
      Actions.venue.setDenied.call({
        venue: '0x1111111111111111111111111111111111111111',
        accounts: Array.from(
          { length: 101 },
          (_, i) => `0x${(i + 1).toString(16).padStart(40, '0')}` as const,
        ),
        deny: true,
      }),
    ) as Errors.BatchTooLargeError
    expect([batch.name, batch.size, batch.maxSize]).toStrictEqual([
      'BatchTooLargeError',
      101,
      100,
    ])
    const address = thrown(() =>
      Actions.venue.closePair.call({ venue: '0x1234', pairIndex: 0 }),
    ) as Errors.InvalidAddressError
    expect([address.name, address.parameter, address.address]).toStrictEqual([
      'InvalidAddressError',
      'venue',
      '0x1234',
    ])
  })

  test('name the package.json version, which src/version.ts holds', () => {
    // `npm run changeset:version` bumps package.json and rewrites src/version.ts from it; snapshots name `<version>`.
    expect(version).toBe(pkg.version)
    expect(new Errors.BaseError('x').version).toBe(`${pkg.name}@${pkg.version}`)
    expect(new Errors.BaseError('x').message).toMatchInlineSnapshot(`
      "x

      Version: @tempoxyz/propamm-sdk@<version>"
    `)
  })
})

describe('one class per kind of mistake', () => {
  const venue: Address = '0x1111111111111111111111111111111111111111'
  const hot = {
    mid: Price.one,
    bidWiden: 0,
    askWiden: 0,
    widthScale: 1000,
    depthScale: 1000,
  }
  const curve = Ladder.curve(hot, 1n, true)
  const word = Post.order({
    pairIndex: 0,
    mid: Price.one,
    shapeId: 0,
    sequence: 2,
    validUntil: 1,
  }).word
  /** Each refusal's class and parameter. */
  const kinds = (runs: (() => unknown)[]) =>
    runs.map((run) => {
      try {
        run()
      } catch (e) {
        const error = e as Errors.BaseError & { parameter?: string }
        return `${error.name} ${error.parameter}`
      }
      return 'no error'
    })

  test('a sides value or a side is an InvalidArgumentError, naming its parameter', () => {
    const pair = {
      hot: HotWord.decode(word),
      sizeUnit: 1n,
      shapeWords: Shape.empty.words,
      consumed: { bids: 0n, asks: 0n },
    }
    expect(
      kinds([
        () => HotWord.sidesFlags('up' as never),
        () => HotWord.refillFlags('up' as never),
        () => Ladder.applyRefill({ bids: 0n, asks: 0n }, 'up' as never),
        () => Shape.side(Shape.empty.words, 'up' as never),
        () => Book.ladder(pair, 'up' as never),
        () => Book.side(pair, 'up' as never, { at: 0n, halted: false }),
      ]),
    ).toStrictEqual([
      'InvalidArgumentError sides',
      'InvalidArgumentError refill',
      'InvalidArgumentError refill',
      'InvalidArgumentError which',
      'InvalidArgumentError which',
      'InvalidArgumentError which',
    ])
  })

  test('a mid above uint96 is an InvalidPriceError; a hot-word widening above uint16 an InvalidHotWordError', () => {
    const over = 1n << 96n
    expect(
      kinds([
        () => Ladder.curve({ ...hot, mid: over }, 1n, true),
        () => Ladder.factor({ ...curve, mid: over }, 0),
        () => HotWord.fromFields({ ...HotWord.toFields(word), mid: over }),
        () =>
          Actions.venue.setMidBand.call({
            venue,
            pairIndex: 0,
            minMid: 1n,
            maxMid: over,
          }),
        () => Ladder.curve({ ...hot, bidWiden: 1 << 16 }, 1n, true),
        () => Ladder.factor({ ...curve, widen: 1 << 16 }, 0),
        () =>
          HotWord.fromFields({ ...HotWord.toFields(word), bidWiden: 1 << 16 }),
      ]),
    ).toStrictEqual([
      'InvalidPriceError mid',
      'InvalidPriceError curve.mid',
      'InvalidPriceError mid',
      'InvalidPriceError maxMid',
      'InvalidHotWordError bidWiden',
      'InvalidHotWordError curve.widen',
      'InvalidHotWordError bidWiden',
    ])
  })

  test("a pairIndex above uint16 is an InvalidArgumentError, an order's the InvalidOrderError that extends it", () => {
    const errors = [
      () =>
        Post.order({
          pairIndex: 1 << 16,
          mid: Price.one,
          shapeId: 0,
          sequence: 2,
          validUntil: 1,
        }),
      () => Post.pack([{ pairIndex: 1 << 16, word }]),
      () => Actions.venue.removePair.call({ venue, pairIndex: 1 << 16 }),
    ].map((run) => {
      try {
        run()
      } catch (e) {
        return e as Errors.InvalidArgumentError
      }
      throw new Error('expected a throw')
    })
    for (const error of errors) {
      expect(error).toBeInstanceOf(Errors.InvalidArgumentError)
      expect([error.parameter, error.shortMessage]).toStrictEqual([
        'pairIndex',
        'pairIndex must be an integer in [0, 65535], got 65536',
      ])
    }
    expect(errors.map((e) => e.name)).toStrictEqual([
      'InvalidOrderError',
      'InvalidArgumentError',
      'InvalidArgumentError',
    ])
  })
})

describe('no other error escapes', () => {
  const venue: Address = '0x1111111111111111111111111111111111111111'
  const base: Address = '0x20c0000000000000000000000000000000000001'
  const quote: Address = '0x20c0000000000000000000000000000000000002'
  // Every check below runs before the first request, so this transport is never asked anything.
  const client = createClient({
    transport: custom({
      request: async () => {
        throw new Error('no request expected')
      },
    }),
  })

  test('a multicall result that never came back', () => {
    expect(() =>
      readValue(undefined, readOf(venue, venueAbi, 'owner')),
    ).toThrow(Errors.SnapshotIncompleteError)
  })

  test('a result decoded as a view other than the one its read called (an SDK bug), refused', () => {
    const venue = '0x1111111111111111111111111111111111111111'
    const result = {
      status: 'success' as const,
      result: `0x${'00'.repeat(32)}` as const,
      read: readOf(venue, venueAbi, 'hotWord', [0]),
    }
    expect(readValue(result, readOf(venue, venueAbi, 'hotWord', [0]))).toBe(
      result.result,
    )
    expect(() =>
      readValue(result, readOf(venue, venueAbi, 'owner'), 'owner'),
    ).toThrow(
      'owner: decoded from a different hotWord read (an SDK bug: please report it)',
    )
  })

  test('a quote for tokens that are not addresses', () => {
    const shape = Shape.from({ bids: [{ size: 1, spread: 0 }], asks: [] })
    const hotWord = HotWord.withoutRefill(
      Post.order({
        pairIndex: 0,
        mid: Price.one,
        shapeId: 0,
        sequence: 2,
        validUntil: 2,
      }).word,
    )
    const source = {
      block: { timestamp: 1n },
      state: { halted: false, maxTakerPriorityFee: 0n },
      pairs: [
        {
          ok: true as const,
          pairIndex: 0,
          base,
          quote,
          sizeUnit: 1n,
          access: 'listed' as const,
          hook: '0x0000000000000000000000000000000000000000' as const,
          hookFlags: 0,
          hotWord,
          hot: HotWord.decode(hotWord),
          consumed: { bids: 0n, asks: 0n },
          midBand: { minMid: 0n, maxMid: 0n },
          shapeWords: shape.words,
          shape,
          inventory: { base: 0n, quote: 0n },
          hookLiquidity: { base: 0n, quote: 0n },
        },
      ],
    }
    const request = { pairIndex: 0, amount: 1n, exactIn: true, priorityFee: 0n }
    expect(() =>
      Quote.local(source, { ...request, tokenIn: '0x1234', tokenOut: quote }),
    ).toThrow(Errors.InvalidAddressError)
    expect(() =>
      Quote.local(source, {
        ...request,
        tokenIn: base,
        tokenOut: `0x${'zz'.repeat(20)}`,
      }),
    ).toThrow(Errors.InvalidAddressError)
  })

  test('a shape that is not an object, and a mode from the prototype', () => {
    for (const shape of [5, null, undefined, 'words']) {
      expect(() =>
        Actions.venue.setShape.call({
          venue,
          pairIndex: 0,
          shapeId: 0,
          shape: shape as never,
        }),
      ).toThrow(Errors.InvalidShapeError)
    }
    for (const mode of [
      'toString',
      'constructor',
      '__proto__',
      'hasOwnProperty',
    ]) {
      expect(() =>
        Actions.venue.setPairAccess.call({
          venue,
          pairIndex: 0,
          mode: mode as never,
        }),
      ).toThrow(Errors.InvalidArgumentError)
    }
  })

  test('a fill at a zero mid, and curves and levels that are not integers', () => {
    const [w0, w1] = Shape.encodeSide([{ size: 10, spread: 0 }])
    const hot = {
      mid: 0n,
      bidWiden: 0,
      askWiden: 0,
      widthScale: 1000,
      depthScale: 1000,
    }
    for (const baseIn of [true, false]) {
      for (const exactIn of [true, false]) {
        expect(() =>
          Ladder.fill(Ladder.curve(hot, 1n, baseIn), w0, w1, exactIn, 3n, 0n),
        ).toThrow(Errors.InvalidPriceError)
      }
    }
    expect(() => Ladder.curve({ ...hot, widthScale: 1.5 }, 1n, true)).toThrow(
      Errors.InvalidHotWordError,
    )
    expect(() => Shape.rawLevel(w0, w1, 1.5)).toThrow(
      Errors.InvalidArgumentError,
    )
    expect(() => HotWord.decode(1.5 as never)).toThrow(
      Errors.InvalidHotWordError,
    )
  })

  test('post bytes that are not hex, and fee inputs that are not bigints', () => {
    expect(() => Post.unpack(`0x${'zz'.repeat(34)}`)).toThrow(
      Errors.InvalidArgumentError,
    )
    expect(() => Fees.makerTip(10 as never)).toThrow(
      Errors.InvalidArgumentError,
    )
    expect(() => Fees.feeFields(1n, 1 as never)).toThrow(
      Errors.InvalidArgumentError,
    )
  })

  test('read inputs viem would refuse, before any request', async () => {
    await expect(
      Info.quote(client, {
        venue,
        pairIndex: 0,
        tokenIn: base,
        tokenOut: quote,
        amount: 1n << 128n,
        exactIn: true,
      }),
    ).rejects.toThrow(Errors.AmountOutOfRangeError)
    await expect(
      Info.isDenied(client, { venue, account: '0x1234' }),
    ).rejects.toThrow(Errors.InvalidAddressError)
    await expect(
      Info.consumed(client, { venue, pairIndex: 0, blockNumber: -1n }),
    ).rejects.toThrow(Errors.InvalidArgumentError)
    await expect(
      Snapshot.get(client, { venue, sponsorIds: [-1n] }),
    ).rejects.toThrow(Errors.InvalidArgumentError)
    await expect(
      Snapshot.get(client, { venue, multicallAddress: '0x1234' }),
    ).rejects.toThrow(Errors.InvalidAddressError)
  })

  test('role checks reject a zero sender before reading vacant role slots', async () => {
    const roles = [
      { role: 'anyone' },
      { role: 'owner' },
      { role: 'ownerOrAgent' },
      { role: 'pendingOwner' },
      { role: 'sponsorAdmin', sponsorId: 999n },
      { role: 'pendingSponsorAdmin', sponsorId: 999n },
    ] as const
    for (const signer of roles) {
      const call = { address: venue, signer }
      for (const account of [
        zeroAddress,
        { address: zeroAddress, type: 'json-rpc' },
      ] as const) {
        await expect(Roles.check(client, { call, account })).rejects.toThrow(
          Errors.InvalidAddressError,
        )
      }
      const zeroClient = createClient({
        account: zeroAddress,
        transport: custom({
          request: async () => {
            throw new Error('zero sender must fail before any RPC request')
          },
        }),
      })
      await expect(Roles.check(zeroClient, { call })).rejects.toThrow(
        Errors.InvalidAddressError,
      )
    }
  })

  test("'pending' for a read that pins one block, before any request", async () => {
    const pending = { venue, blockTag: 'pending' } as const
    const reads: Record<string, () => Promise<unknown>> = {
      'Info.venueState': () => Info.venueState(client, pending),
      'Info.sponsorState': () =>
        Info.sponsorState(client, { ...pending, sponsorId: 1n }),
      'Info.meta': () => Info.meta(client, pending),
      'Info.orders': () => Info.orders(client, { ...pending, pairs: [0] }),
      'Sequencer.seed': () =>
        Sequencer.seed(client, { ...pending, pairs: [0] }),
      'Roles.check': () =>
        Roles.check(client, {
          call: Actions.venue.setHalted.call({ venue, halted: true }),
          account: venue,
          blockTag: 'pending',
        }),
      'Snapshot.get': () => Snapshot.get(client, pending),
      'cancelAll.requests': () =>
        Actions.maker.cancelAll.requests(client, pending),
      'Plan.simulate': () =>
        Plan.simulate(client, {
          steps: [
            {
              account: venue,
              calls: [Actions.venue.setHalted.call({ venue, halted: true })],
            },
          ],
          blockTag: 'pending',
        }),
    }
    for (const [name, read] of Object.entries(reads)) {
      const error = await read().catch((e: unknown) => e)
      expect(error, name).toBeInstanceOf(Errors.InvalidArgumentError)
      expect(
        [
          (error as Errors.InvalidArgumentError).parameter,
          (error as Errors.BaseError).shortMessage,
        ],
        name,
      ).toStrictEqual([
        'blockTag',
        "blockTag 'pending' names no fixed block for this read to pin: pass 'latest' or a blockNumber",
      ])
    }
  })
})
