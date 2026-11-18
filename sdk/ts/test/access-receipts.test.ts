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
function accessLog(
  eventName: 'UpdaterSet' | 'DenyUpdated',
  data: Hex,
  address: Address = venue,
) {
  return {
    address,
    topics: encodeEventTopics({
      abi: Abis.venueAbi,
      eventName,
      args:
        eventName === 'UpdaterSet'
          ? { updater: account.address }
          : { account: account.address, by: account.address },
    }) as Hex[],
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
function fixture(
  action: 'approveAgentSync' | 'revokeAgentSync' | 'setDeniedSync',
  logs: ReturnType<typeof accessLog>[],
) {
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
    send: () => {
      const parameters = {
        venue,
        agent: account.address,
        accounts: [account.address],
        deny: true,
        gas: 200_000n,
        nonce: 0,
        maxFeePerGas: 2_000_000_000n,
        maxPriorityFeePerGas: 1_000_000_000n,
      }
      if (action === 'approveAgentSync')
        return Actions.venue.approveAgentSync(client, parameters)
      if (action === 'revokeAgentSync')
        return Actions.venue.revokeAgentSync(client, parameters)
      return Actions.venue.setDeniedSync(client, parameters)
    },
  }
}
for (const action of [
  'approveAgentSync',
  'revokeAgentSync',
  'setDeniedSync',
] as const) {
  const eventName = action === 'setDeniedSync' ? 'DenyUpdated' : 'UpdaterSet'
  const valid = () =>
    accessLog(
      eventName,
      action === 'revokeAgentSync'
        ? encodeAbiParameters([{ type: 'bool' }], [false])
        : encodedTrue,
    )
  for (const data of ['0x', '0x01'] as const) {
    for (const withValid of [false, true]) {
      test(`${action} rejects malformed data ${data}, valid companion=${withValid}`, async () => {
        const f = fixture(action, [
          ...(withValid ? [valid()] : []),
          accessLog(eventName, data),
        ])
        await expect(f.send()).rejects.toBeInstanceOf(
          Errors.UnexpectedResponseError,
        )
        expect(f.probes).toHaveLength(0)
      })
    }
  }
  test(`${action} rejects a missing indexed account`, async () => {
    const log = valid()
    log.topics = log.topics.slice(0, 1)
    const f = fixture(action, [log])
    await expect(f.send()).rejects.toBeInstanceOf(
      Errors.UnexpectedResponseError,
    )
    expect(f.probes).toHaveLength(0)
  })
  for (const casing of ['lower', 'upper', 'mixed'] as const) {
    test(`${action} decodes ${casing}-case topics`, async () => {
      const log = valid()
      log.topics = log.topics.map((topic) =>
        typeof topic === 'string'
          ? (`0x${Array.from(topic.slice(2), (c, i) => (casing === 'upper' || (casing === 'mixed' && i % 2 === 0) ? c.toUpperCase() : c)).join('')}` as Hex)
          : topic,
      )
      const f = fixture(action, [log])
      expect(await f.send()).toMatchObject(
        action === 'setDeniedSync'
          ? {
              status: 'success',
              updates: [{ account: account.address, denied: true }],
            }
          : {
              status: 'success',
              changed: true,
              updater: account.address,
              allowed: action !== 'revokeAgentSync',
            },
      )
      expect(f.probes).toHaveLength(0)
    })
  }
  for (const kind of [
    'empty',
    'otherEmitter',
    'unrelatedBadAddress',
  ] as const) {
    test(`${action} preserves genuine no-ops (${kind})`, async () => {
      const log = accessLog(
        eventName,
        '0x',
        kind === 'otherEmitter' ? factory : ('0xnot-an-address' as Address),
      )
      if (kind === 'unrelatedBadAddress') log.topics[0] = `0x${'00'.repeat(32)}`
      const f = fixture(action, kind === 'empty' ? [] : [log])
      expect(await f.send()).toMatchObject(
        action === 'setDeniedSync'
          ? { status: 'success', updates: [] }
          : { status: 'success', changed: false },
      )
      expect(f.probes).toHaveLength(2)
    })
  }
}
