import {
  type Address,
  createClient,
  custom,
  defineChain,
  encodeAbiParameters,
  encodeEventTopics,
  type Hex,
  toFunctionSelector,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { expect, test } from 'vitest'
import { Abis, Actions, Errors } from '../src/index.js'

const venue = '0x1111111111111111111111111111111111111111' as const
const factory = '0x2222222222222222222222222222222222222222' as const
const account = privateKeyToAccount(`0x${'01'.repeat(32)}`)
const hash = `0x${'11'.repeat(32)}` as const
const chain = defineChain({
  id: 31337,
  name: 'Receipt transport',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['http://localhost'] } },
  contracts: {
    multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' },
  },
})
function haltLog(data: Hex, address: Address = venue) {
  return {
    address,
    topics: encodeEventTopics({ abi: Abis.venueAbi, eventName: 'HaltedSet' }),
    data,
    blockNumber: '0x10',
    blockHash: hash,
    logIndex: '0x0',
    transactionHash: hash,
    transactionIndex: '0x0',
    removed: false,
  }
}
const encodedTrue = encodeAbiParameters([{ type: 'bool' }], [true])
function fixture(logs: ReturnType<typeof haltLog>[]) {
  const probes: unknown[] = []
  const client = createClient({
    account,
    chain,
    transport: custom({
      async request({ method, params }) {
        if (method === 'eth_chainId') return '0x7a69'
        if (method === 'eth_sendRawTransactionSync')
          return {
            transactionHash: hash,
            transactionIndex: '0x0',
            blockHash: hash,
            blockNumber: '0x10',
            from: account.address,
            to: venue,
            cumulativeGasUsed: '0x5208',
            gasUsed: '0x5208',
            contractAddress: null,
            logs,
            logsBloom: `0x${'00'.repeat(256)}`,
            status: '0x1',
            effectiveGasPrice: '0x3b9aca00',
            type: '0x2',
          }
        if (method === 'eth_call') {
          probes.push(params)
          const [{ data }] = params as [{ data: string }]
          const returnData = data.includes(
            toFunctionSelector('factory()').slice(2),
          )
            ? encodeAbiParameters([{ type: 'address' }], [factory])
            : encodeAbiParameters([{ type: 'bool' }], [true])
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
            [[{ success: true, returnData }]],
          )
        }
        throw new Error(`Unexpected RPC ${method}`)
      },
    }),
  })
  return {
    probes,
    send: () =>
      Actions.venue.setHaltedSync(client, {
        venue,
        halted: true,
        gas: 200_000n,
        nonce: 0,
        maxFeePerGas: 2_000_000_000n,
        maxPriorityFeePerGas: 1_000_000_000n,
      }),
  }
}
for (const data of ['0x', '0x01'] as const) {
  for (const withValid of [false, true]) {
    test(`rejects undecodable halt data ${data}, valid companion=${withValid}`, async () => {
      const f = fixture([
        ...(withValid ? [haltLog(encodedTrue)] : []),
        haltLog(data),
      ])
      await expect(f.send()).rejects.toBeInstanceOf(
        Errors.UnexpectedResponseError,
      )
      expect(f.probes).toHaveLength(0)
    })
  }
}
test('a decoded halt event reports a change without factory probes', async () => {
  const f = fixture([haltLog(encodedTrue)])
  expect(await f.send()).toMatchObject({
    status: 'success',
    changed: true,
    halted: true,
  })
  expect(f.probes).toHaveLength(0)
})
for (const logs of [[], [haltLog('0x', factory)]]) {
  test(`genuine eventless receipts ignore other emitters (${logs.length} logs)`, async () => {
    const f = fixture(logs)
    expect(await f.send()).toMatchObject({ status: 'success', changed: false })
    expect(f.probes).toHaveLength(2)
  })
}

for (const casing of ['upper', 'mixed'] as const) {
  test(`a valid ${casing}-case halt selector reports a change`, async () => {
    const log = haltLog(encodedTrue)
    const topic = log.topics[0]
    if (!topic) throw new Error('Missing HaltedSet selector')
    log.topics[0] = `0x${Array.from(topic.slice(2), (c, i) =>
      casing === 'upper' || i % 2 === 0 ? c.toUpperCase() : c,
    ).join('')}`
    const f = fixture([log])
    expect(await f.send()).toMatchObject({
      status: 'success',
      changed: true,
      halted: true,
    })
    expect(f.probes).toHaveLength(0)
  })
}

for (const withValid of [false, true]) {
  test(`ignores an unrelated malformed-address log, valid companion=${withValid}`, async () => {
    const unrelated = haltLog('0x', '0xnot-an-address' as Address)
    unrelated.topics[0] = `0x${'00'.repeat(32)}`
    const f = fixture([...(withValid ? [haltLog(encodedTrue)] : []), unrelated])
    expect(await f.send()).toMatchObject({
      status: 'success',
      changed: withValid,
    })
    expect(f.probes).toHaveLength(withValid ? 0 : 2)
  })
}
