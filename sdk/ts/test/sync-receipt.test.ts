import { createClient, custom } from 'viem'
import { tempoModerato } from 'viem/chains'
import { expect, test } from 'vitest'
import { sendSync } from '../src/actions/internal/define.js'
import { Actions } from '../src/index.js'

const venue = '0x1111111111111111111111111111111111111111' as const
const hash = `0x${'11'.repeat(32)}` as const
const order = {
  pairIndex: 0,
  mid: 10n ** 18n,
  shapeId: 0,
  sequence: 2,
  validUntil: 1_800_000_060,
}

// Exercise viem's real write, receipt retrieval and RPC formatting, not mocked actions.
function fixture(overrides: object = {}, omitted: string[] = []) {
  const methods: string[] = []
  const rpcReceipt = {
    transactionHash: hash,
    transactionIndex: '0x0',
    blockHash: hash,
    blockNumber: '0x1',
    from: venue,
    to: venue,
    contractAddress: null,
    cumulativeGasUsed: '0x5208',
    gasUsed: '0x5208',
    effectiveGasPrice: '0x1',
    logs: [],
    logsBloom: `0x${'00'.repeat(256)}`,
    status: '0x1',
    type: '0x2',
    ...overrides,
  }
  for (const field of omitted) Reflect.deleteProperty(rpcReceipt, field)
  const client = createClient({
    chain: tempoModerato,
    account: venue,
    transport: custom({
      async request({ method }) {
        methods.push(method)
        if (method === 'eth_chainId') return '0xa5bf'
        if (method === 'eth_sendTransaction') return hash
        if (method === 'eth_getTransactionReceipt') return rpcReceipt
        throw new Error(`Unexpected RPC ${method}`)
      },
    }),
  })
  return { client, methods }
}

for (const overrides of [
  { blockNumber: null },
  { blockHash: null },
  { blockNumber: null, blockHash: null },
  { status: 'pending' },
  { status: '0x0', blockNumber: null },
  { status: '0x0', blockHash: null },
]) {
  test(`unincluded receipt stays pending: ${JSON.stringify(overrides)}`, async () => {
    const { client, methods } = fixture(overrides)
    let reads = 0
    const result = await sendSync(
      client,
      { throwOnReceiptRevert: false },
      Actions.maker.order.call({ venue, order }),
      () => {
        reads++
        return { outcome: 'must not be read' }
      },
    )
    expect(result.status).toBe('pending')
    expect(result).not.toHaveProperty('outcome')
    expect(result.receipt.transactionHash).toBe(hash)
    expect(reads).toBe(0)
    expect(methods).toEqual([
      'eth_chainId',
      'eth_sendTransaction',
      'eth_getTransactionReceipt',
    ])
  })
}
for (const field of ['blockNumber', 'blockHash'] as const) {
  test(`maker orderSync does not report skipped entries without ${field}`, async () => {
    const { client } = fixture({ [field]: null })
    const result = await Actions.maker.orderSync(client, { venue, order })
    expect(result.status).toBe('pending')
    expect(result.receipt[field]).toBeNull()
    expect(result.receipt.status).toBe('success')
    expect(result).not.toHaveProperty('outcome')
    expect(result).not.toHaveProperty('posted')
  })
}
for (const field of ['blockNumber', 'blockHash'] as const) {
  test(`omitted ${field} never reaches the outcome reader`, async () => {
    const { client } = fixture({}, [field])
    let reads = 0
    const result = await sendSync(
      client,
      {},
      Actions.maker.order.call({ venue, order }),
      () => {
        reads++
        return { outcome: 'must not be read' }
      },
    )
    expect(result.status).toBe('pending')
    expect(result).not.toHaveProperty('outcome')
    expect(reads).toBe(0)
  })
  test(`maker orderSync does not report outcomes with omitted ${field}`, async () => {
    const { client } = fixture({}, [field])
    const result = await Actions.maker.orderSync(client, { venue, order })
    expect(result.status).toBe('pending')
    expect(result.receipt.status).toBe('success')
    expect(result).not.toHaveProperty('outcome')
    expect(result).not.toHaveProperty('posted')
  })
}
test('included success still reads the post outcome', async () => {
  const { client } = fixture()
  const result = await Actions.maker.orderSync(client, { venue, order })
  expect(result.status).toBe('success')
  if (result.status !== 'success') throw new Error('Expected inclusion')
  expect(result.receipt.blockNumber).toBe(1n)
  expect(result.posted).toEqual([])
  expect(result.outcome.skipped).toHaveLength(1)
})
test('included revert returns only the receipt when requested', async () => {
  const { client } = fixture({ status: '0x0' })
  const result = await Actions.maker.orderSync(client, {
    venue,
    order,
    throwOnReceiptRevert: false,
  })
  expect(result.status).toBe('reverted')
  expect(result.receipt.status).toBe('reverted')
  expect(result).not.toHaveProperty('outcome')
})
test('included revert still throws by default', async () => {
  const { client } = fixture({ status: '0x0' })
  await expect(
    Actions.maker.orderSync(client, { venue, order }),
  ).rejects.toThrow()
})
