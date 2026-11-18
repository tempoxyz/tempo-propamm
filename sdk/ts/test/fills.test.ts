import {
  createClient,
  custom,
  DecodeLogDataMismatch,
  DecodeLogTopicsMismatch,
  encodeAbiParameters,
  encodeEventTopics,
  type Hex,
  IntegerOutOfRangeError,
  InvalidBytesBooleanError,
  type RpcLog,
} from 'viem'
import { expect, test } from 'vitest'
import { Abis, Errors, Info } from '../src/index.js'

const venue = '0x1111111111111111111111111111111111111111'
const taker = '0x2222222222222222222222222222222222222222'
const parameters = { venue, fromBlock: 1n, toBlock: 2n } as const
const topics = encodeEventTopics({
  abi: Abis.venueAbi,
  eventName: 'Fill',
  args: { pairIndex: 0, taker, ref: `0x${'00'.repeat(32)}` },
}) as [Hex, ...Hex[]]
const data = encodeAbiParameters(
  [
    { type: 'uint64' },
    { type: 'bool' },
    { type: 'uint128' },
    { type: 'uint128' },
    { type: 'uint96' },
    { type: 'uint32' },
  ],
  [0n, true, 10n, 20n, 30n, 1],
)
const valid: RpcLog = {
  address: venue,
  topics,
  data,
  blockNumber: '0x1',
  blockHash: `0x${'11'.repeat(32)}`,
  transactionHash: `0x${'22'.repeat(32)}`,
  transactionIndex: '0x0',
  logIndex: '0x0',
  removed: false,
}
function node(logs: RpcLog[], pairIndex: number | null = 0) {
  return createClient({
    transport: custom({
      async request({ method, params }) {
        expect(method).toBe('eth_getLogs')
        expect(params).toEqual([
          {
            address: venue,
            fromBlock: '0x1',
            toBlock: '0x2',
            topics:
              pairIndex === null
                ? [topics[0]]
                : [topics[0], `0x${word(BigInt(pairIndex))}`, null, null],
          },
        ])
        return logs
      },
    }),
  })
}

test('fills preserves valid logs and metadata in order with pair filtering', async () => {
  const fills = await Info.fills(
    node([valid, { ...valid, logIndex: '0x1', removed: true }]),
    {
      ...parameters,
      pairIndex: 0,
    },
  )
  expect(
    fills.map((fill) => [fill.sequence, fill.amountOut, fill.log.logIndex]),
  ).toEqual([
    [1, 20n, 0],
    [1, 20n, 1],
  ])
  expect(fills[0]?.log).toMatchObject({
    address: venue,
    data,
    topics,
    blockNumber: 1n,
    blockHash: valid.blockHash,
    transactionHash: valid.transactionHash,
    transactionIndex: 0,
    removed: false,
    eventName: 'Fill',
    args: { seq: 1, pairIndex: 0, taker },
  })
  expect(fills[1]?.log.removed).toBe(true)
})

test('fills returns an empty page without inventing a fill', async () => {
  expect(await Info.fills(node([], null), parameters)).toEqual([])
})

const word = (value: bigint) => value.toString(16).padStart(64, '0')
const replace = (index: number, value: bigint): Hex =>
  `0x${data.slice(2, 2 + index * 64)}${word(value)}${data.slice(2 + (index + 1) * 64)}`
test.each([
  ['empty data', { data: '0x' }],
  ['truncated data', { data: data.slice(0, -2) }],
  ['trailing data', { data: `${data}00` }],
  ['missing topic', { topics: topics.slice(0, -1) }],
  ['extra topic', { topics: [...topics, topics[0]] }],
  [
    'wide pair',
    { topics: [topics[0], `0x${word(65536n)}`, ...topics.slice(2)] },
  ],
  [
    'wide address',
    { topics: [topics[0], topics[1], `0x${'11'.repeat(32)}`, topics[3]] },
  ],
  ['wide sponsor', { data: replace(0, 1n << 64n) }],
  ['invalid bool', { data: replace(1, 2n) }],
  ['wide mid', { data: replace(4, 1n << 96n) }],
  ['wide input', { data: replace(2, 1n << 128n) }],
  ['wide output', { data: replace(3, 1n << 128n) }],
  ['wide sequence', { data: replace(5, 1n << 32n) }],
])('fills refuses a mixed page containing %s', async (kind, patch) => {
  const error =
    kind === 'empty data' || kind === 'truncated data'
      ? DecodeLogDataMismatch
      : kind === 'missing topic'
        ? DecodeLogTopicsMismatch
        : kind === 'invalid bool'
          ? InvalidBytesBooleanError
          : kind.startsWith('wide') && kind !== 'wide address'
            ? IntegerOutOfRangeError
            : Errors.UnexpectedResponseError
  await expect(
    Info.fills(node([valid, { ...valid, ...patch } as RpcLog]), {
      ...parameters,
      pairIndex: 0,
    }),
  ).rejects.toThrow(error)
})

test('fills skips unrelated emitters and signatures but checks recognized logs before pair filtering', async () => {
  expect(
    await Info.fills(
      node([
        { ...valid, address: taker, data: '0x' },
        { ...valid, topics: ['0x00'], data: '0x' },
        valid,
      ]),
      { ...parameters, pairIndex: 0 },
    ),
  ).toHaveLength(1)
  await expect(
    Info.fills(
      node([
        {
          ...valid,
          topics: [topics[0], `0x${word(1n)}`, ...topics.slice(2)],
          data: '0x',
        },
      ]),
      { ...parameters, pairIndex: 0 },
    ),
  ).rejects.toThrow(DecodeLogDataMismatch)
})

test.each([0n, (1n << 64n) - 1n])(
  'fills accepts canonical uint boundaries %s without a pair filter',
  async (value) => {
    const data = encodeAbiParameters(
      [
        { type: 'uint64' },
        { type: 'bool' },
        { type: 'uint128' },
        { type: 'uint128' },
        { type: 'uint96' },
        { type: 'uint32' },
      ],
      [
        value,
        false,
        (1n << 128n) - 1n,
        0n,
        value === 0n ? 0n : (1n << 96n) - 1n,
        value === 0n ? 0 : 0xffffffff,
      ],
    )
    const page: RpcLog[] = [
      {
        ...valid,
        data,
        topics: [
          topics[0].toUpperCase().replace('0X', '0x') as Hex,
          `0x${word(65535n)}`,
          ...topics.slice(2),
        ],
      },
    ]
    const fills = await Info.fills(node(page, null), parameters)
    expect(fills[0]).toMatchObject({
      pairIndex: 65535,
      sponsorId: value,
      baseIn: false,
      makerMid: value === 0n ? 0n : (1n << 96n) - 1n,
    })
  },
)
