import {
  createClient,
  custom,
  encodeAbiParameters,
  type Hex,
  zeroAddress,
} from 'viem'
import { mainnet } from 'viem/chains'
import { expect, test } from 'vitest'
import {
  Actions,
  Errors,
  Info,
  Post,
  Price,
  Sequencer,
  Snapshot,
} from '../src/index.js'
import * as VenueReads from '../src/internal/venue.js'

const venue = '0x1111111111111111111111111111111111111111'
const parameters = { venue, blockNumber: 20_000_000n } as const
const stateValues = [
  zeroAddress,
  zeroAddress,
  zeroAddress,
  zeroAddress,
  false,
  0,
  0n,
]

function state(count: unknown) {
  return VenueReads.stateFrom(
    venue,
    VenueReads.state(venue).map((read, i) => ({
      read,
      status: 'success',
      result: [...stateValues, count][i],
    })),
  )
}

test.each([0, 1, 65_535])(
  'venue state preserves valid pairCount %s without fanout',
  (count) => {
    expect(state(count).pairCount).toBe(count)
  },
)

test.each([
  65_536,
  Number.MAX_SAFE_INTEGER + 1,
  -1,
  0.5,
  NaN,
  Infinity,
  0n,
  '0',
  null,
  undefined,
])('venue state rejects malformed decoded pairCount %s', (count) => {
  expect(() => state(count)).toThrow(Errors.UnexpectedResponseError)
  expect(() => state(count)).toThrow('pairCount')
})

const readers = {
  meta: Info.meta,
  venueState: Info.venueState,
  snapshot: Snapshot.get,
  snapshotExplicit: (
    client: Parameters<typeof Snapshot.get>[0],
    at: typeof parameters,
  ) => Snapshot.get(client, { ...at, pairs: [] }),
  cancelAll: Actions.maker.cancelAll.requests,
}

// Adversarial wire responses go through viem's real ABI decoder, which accepts safe integers outside uint16.
function node(count: bigint, reader: keyof typeof readers) {
  let calls = 0
  const word = encodeAbiParameters([{ type: 'uint256' }], [count])
  const uint = (value: bigint) =>
    encodeAbiParameters([{ type: 'uint256' }], [value])
  const values: Hex[] =
    reader === 'cancelAll'
      ? [word]
      : [
          uint(0n),
          uint(0n),
          uint(0n),
          uint(0n),
          uint(0n),
          uint(0n),
          uint(0n),
          word,
        ]
  const batch = encodeAbiParameters(
    [
      {
        type: 'tuple[]',
        components: [
          { name: 'success', type: 'bool' },
          { name: 'returnData', type: 'bytes' },
        ],
      },
    ],
    [values.map((returnData) => ({ success: true, returnData }))],
  )
  const client = createClient({
    chain: mainnet,
    transport: custom(
      {
        request: async ({ method }) => {
          if (method === 'eth_getBlockByNumber')
            return {
              number: '0x1312d00',
              hash: `0x${'11'.repeat(32)}`,
              timestamp: '0x1',
              baseFeePerGas: '0x0',
            }
          if (method === 'eth_call') {
            calls++
            if (calls > 1) throw new Error('unexpected pair-read fanout')
            return reader === 'meta' ? word : batch
          }
          throw new Error(`unexpected request: ${method}`)
        },
      },
      { retryCount: 0 },
    ),
  })
  return { client, calls: () => calls }
}

for (const reader of Object.keys(readers) as (keyof typeof readers)[]) {
  test.each([65_536n, 1n << 32n, (1n << 53n) - 1n])(
    `${reader} rejects out-of-domain RPC pairCount %s before pair-read fanout`,
    async (count) => {
      const rpc = node(count, reader)
      await expect(
        readers[reader](rpc.client, parameters),
      ).rejects.toMatchObject({
        name: 'UnexpectedResponseError',
        value: Number(count),
      })
      expect(rpc.calls()).toBe(1)
    },
  )
  test(`${reader} accepts zero pairs without pair-read fanout`, async () => {
    const rpc = node(0n, reader)
    const result = await readers[reader](rpc.client, parameters)
    if (reader === 'meta') expect(result).toEqual([])
    else if (reader === 'cancelAll')
      expect(result).toEqual({ cancels: [], skipped: [] })
    else if (reader === 'venueState')
      expect(result).toMatchObject({ pairCount: 0 })
    else expect(result).toMatchObject({ state: { pairCount: 0 }, pairs: [] })
    expect(rpc.calls()).toBe(1)
  })
}

// Exercise the wire-format boundary without generating 65,535 genuine pair reads.
test('venueState accepts the maximum uint16 RPC pairCount', async () => {
  const rpc = node(65_535n, 'venueState')
  await expect(Info.venueState(rpc.client, parameters)).resolves.toMatchObject({
    pairCount: 65_535,
  })
  expect(rpc.calls()).toBe(1)
})

// A number is not a block identity: replacing height 20,000,000 can add a live pair
// after pairCount has already sized the dependent reads.
test.each(['requests', 'cancelAll', 'cancelAllSync'] as const)(
  '%s refuses a reorg between cancellation read rounds before sending or allocating sequences',
  async (action) => {
    const hash = `0x${'11'.repeat(32)}`
    let rounds = 0
    let sends = 0
    const aggregate = (values: Hex[]) =>
      encodeAbiParameters(
        [
          {
            type: 'tuple[]',
            components: [
              { name: 'success', type: 'bool' },
              { name: 'returnData', type: 'bytes' },
            ],
          },
        ],
        [values.map((returnData) => ({ success: true, returnData }))],
      )
    const client = createClient({
      chain: mainnet,
      transport: custom(
        {
          request: async ({ method, params }) => {
            if (method === 'eth_getBlockByNumber')
              return { number: '0x1312d00', hash, timestamp: '0x1' }
            if (method === 'eth_call') {
              const at = (params as unknown[])[1]
              if (rounds > 0 && typeof at === 'object') {
                expect(at).toEqual({ blockHash: hash, requireCanonical: true })
                throw new Error('snapshot block is no longer canonical')
              }
              rounds++
              return rounds === 1
                ? aggregate([encodeAbiParameters([{ type: 'uint16' }], [1])])
                : aggregate([
                    encodeAbiParameters([{ type: 'bytes32' }], [liveWord]),
                    encodeAbiParameters(
                      [{ type: 'uint96' }, { type: 'uint96' }],
                      [0n, 0n],
                    ),
                  ])
            }
            sends++
            throw new Error('must not send a partial cancellation')
          },
        },
        { retryCount: 0 },
      ),
    })
    const sequencer = Sequencer.from([[0, 2]])
    const before = Array.from(sequencer.last)
    const args = { venue, sequencer, account: venue } as const
    const result =
      action === 'requests'
        ? Actions.maker.cancelAll.requests(client, args)
        : Actions.maker[action](client, args)
    await expect(result).rejects.toThrow(
      'snapshot block is no longer canonical',
    )
    expect(Array.from(sequencer.last)).toEqual(before)
    expect(sends).toBe(0)
  },
)

const liveWord = Post.order({
  pairIndex: 0,
  sequence: 2,
  mid: Price.one,
  shapeId: 0,
  validUntil: 1_800_000_000,
}).word

test.each(['latest', 'safe', 'number'] as const)(
  'cancelAll pins %s reads by canonical hash, retaining overrides across multicall chunks',
  async (selector) => {
    const hash = `0x${'11'.repeat(32)}`
    const calls: unknown[][] = []
    const client = createClient({
      chain: mainnet,
      batch: { multicall: { batchSize: 1 } },
      transport: custom(
        {
          request: async ({ method, params }) => {
            if (method === 'eth_getBlockByNumber') {
              expect((params as unknown[])[0]).toBe(
                selector === 'number' ? '0x1312d00' : selector,
              )
              return { number: '0x1312d00', hash, timestamp: '0x1' }
            }
            if (method === 'eth_call') {
              calls.push(params as unknown[])
              const returns = [
                encodeAbiParameters([{ type: 'uint16' }], [1]),
                encodeAbiParameters([{ type: 'bytes32' }], [liveWord]),
                encodeAbiParameters(
                  [{ type: 'uint96' }, { type: 'uint96' }],
                  [0n, 0n],
                ),
              ]
              return encodeAbiParameters(
                [
                  {
                    type: 'tuple[]',
                    components: [
                      { name: 'success', type: 'bool' },
                      { name: 'returnData', type: 'bytes' },
                    ],
                  },
                ],
                [
                  [
                    {
                      success: true,
                      returnData: returns[calls.length - 1] as Hex,
                    },
                  ],
                ],
              )
            }
            throw new Error(`unexpected request: ${method}`)
          },
        },
        { retryCount: 0 },
      ),
    })
    const result = await Actions.maker.cancelAll.requests(client, {
      venue,
      ...(selector === 'number'
        ? { blockNumber: parameters.blockNumber }
        : { blockTag: selector }),
      blockOverrides: { time: 100n },
      stateOverride: [],
    })
    expect(result).toEqual({
      cancels: [{ pairIndex: 0, sequence: 3, mid: Price.one }],
      skipped: [],
    })
    expect(calls).toHaveLength(3)
    for (const params of calls) {
      expect(params[1]).toEqual({ blockHash: hash, requireCanonical: true })
      expect(params[2]).toEqual({})
      expect(params[3]).toMatchObject({ time: '0x64' })
    }
  },
)

test.each(['missingHash', 'unsupportedSelector'] as const)(
  'cancelAll fails closed on %s',
  async (failure) => {
    let calls = 0
    const client = createClient({
      chain: mainnet,
      transport: custom(
        {
          request: async ({ method }) => {
            if (method === 'eth_getBlockByNumber')
              return {
                number: '0x1312d00',
                hash: failure === 'missingHash' ? null : `0x${'11'.repeat(32)}`,
                timestamp: '0x1',
              }
            calls++
            throw new Error('EIP-1898 unsupported')
          },
        },
        { retryCount: 0 },
      ),
    })
    const result = Actions.maker.cancelAll.requests(client, parameters)
    await expect(result).rejects.toThrow(
      failure === 'missingHash'
        ? 'without a number or hash'
        : 'EIP-1898 unsupported',
    )
    expect(calls).toBe(failure === 'missingHash' ? 0 : 1)
  },
)
