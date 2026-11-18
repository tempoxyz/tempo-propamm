// Plan's inputs, refused before any request, and its gas margin. The e2e plan suite holds the simulation to anvil.
import { type Address, createClient, custom, publicActions } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { mainnet, tempoLocalnet } from 'viem/chains'
import { tempoActions } from 'viem/tempo'
import { describe, expect, test } from 'vitest'
import { Actions, Errors, Plan } from '../src/index.js'

const venue: Address = '0x1111111111111111111111111111111111111111'
const sender: Address = '0x3333333333333333333333333333333333333333'
// Every check below runs before the first request, so this transport is never asked anything.
const transport = custom({
  request: async () => {
    throw new Error('no request expected')
  },
})
const tempo = createClient({ chain: tempoLocalnet, transport })
const other = createClient({ chain: mainnet, transport })
const halt = Actions.venue.setHalted.call({ venue, halted: true })

/** The error a call throws, by class and short message. */
async function refusal(run: () => Promise<unknown>): Promise<string> {
  try {
    await run()
  } catch (e) {
    return e instanceof Errors.BaseError
      ? `${e.name}: ${e.shortMessage}`
      : String(e)
  }
  return 'no error'
}

describe('Plan inputs', () => {
  test('refuses a step it could not send, before any request', async () => {
    const step = (over: Record<string, unknown>) =>
      ({ account: sender, calls: [halt], ...over }) as never
    const cases: Record<string, () => Promise<unknown>> = {
      'steps not an array': () =>
        Plan.simulate(tempo, { steps: step({}) as never }),
      'a step that is not an object': () =>
        Plan.simulate(tempo, { steps: [null as never] }),
      'a malformed sender': () =>
        Plan.simulate(tempo, { steps: [step({ account: '0x1234' })] }),
      'an account without an address': () =>
        Plan.simulate(tempo, { steps: [step({ account: {} })] }),
      'no calls': () => Plan.simulate(tempo, { steps: [step({ calls: [] })] }),
      'calls not an array': () =>
        Plan.simulate(tempo, { steps: [step({ calls: halt })] }),
      'a batch off a Tempo chain': () =>
        Plan.simulate(other, { steps: [step({ calls: [halt, halt] })] }),
      'a malformed target': () =>
        Plan.simulate(tempo, {
          steps: [step({ calls: [{ to: '0x12', data: '0x' }] })],
        }),
      'data that is not bytes': () =>
        Plan.simulate(tempo, {
          steps: [step({ calls: [{ to: venue, data: '0x123' }] })],
        }),
      'an abi that encodes other data': () =>
        Plan.simulate(tempo, {
          steps: [step({ calls: [{ ...halt, args: [false] }] })],
        }),
      'args without an abi': () =>
        Plan.simulate(tempo, {
          steps: [step({ calls: [{ to: venue, data: halt.data, args: [] }] })],
        }),
      'an abi that cannot encode its args': () =>
        Plan.simulate(tempo, {
          steps: [step({ calls: [{ ...halt, args: ['yes'] }] })],
        }),
      'a negative fee': () =>
        Plan.simulate(tempo, { steps: [step({ maxPriorityFeePerGas: -1n })] }),
      'a block number and a tag': () =>
        Plan.simulate(tempo, {
          steps: [step({})],
          blockNumber: 1n,
          blockTag: 'latest',
        }),
      'an unknown tag': () =>
        Plan.simulate(tempo, {
          steps: [step({})],
          blockTag: 'newest' as never,
        }),
      'estimateGas: no calls': () =>
        Plan.estimateGas(tempo, { account: sender, calls: [] }),
      'estimateGas: a batch off a Tempo chain': () =>
        Plan.estimateGas(other, { account: sender, calls: [halt, halt] }),
      'estimateGas: a negative block': () =>
        Plan.estimateGas(tempo, {
          account: sender,
          calls: [halt],
          blockNumber: -1n,
        }),
    }
    const refused: Record<string, string> = {}
    for (const [name, run] of Object.entries(cases))
      refused[name] = await refusal(run)
    expect(refused).toMatchInlineSnapshot(`
      {
        "a batch off a Tempo chain": "InvalidArgumentError: steps[0] has several calls, a Tempo calls batch: use a viem/tempo chain",
        "a block number and a tag": "InvalidArgumentError: pass blockNumber or blockTag, not both: they could name two blocks",
        "a malformed sender": "InvalidAddressError: steps[0].account is not an address: "0x1234"",
        "a malformed target": "InvalidAddressError: steps[0].calls[0].to is not an address: "0x12"",
        "a negative fee": "InvalidArgumentError: steps[0].maxPriorityFeePerGas must be a bigint in [0, 2^256 - 1], got -1n",
        "a step that is not an object": "InvalidArgumentError: steps[0] must be { account, calls }",
        "an abi that cannot encode its args": "InvalidArgumentError: steps[0].calls[0]'s abi, functionName and args do not encode a call",
        "an abi that encodes other data": "InvalidArgumentError: steps[0].calls[0]'s abi, functionName and args encode other data than its data",
        "an account without an address": "InvalidAddressError: steps[0].account.address is not an address: undefined",
        "an unknown tag": "InvalidArgumentError: blockTag must be one of earliest, finalized, latest, pending, safe, got "newest"",
        "args without an abi": "InvalidArgumentError: steps[0].calls[0] has args or a functionName without its abi: pass all three, or only { to, data }",
        "calls not an array": "InvalidArgumentError: steps[0].calls must be an array of calls",
        "data that is not bytes": "InvalidArgumentError: steps[0].calls[0].data must be bytes of hex",
        "estimateGas: a batch off a Tempo chain": "InvalidArgumentError: step has several calls, a Tempo calls batch: use a viem/tempo chain",
        "estimateGas: a negative block": "InvalidArgumentError: blockNumber must be a bigint in [0, 2^64 - 1], got -1n",
        "estimateGas: no calls": "EmptyBatchError: step needs at least one call",
        "no calls": "EmptyBatchError: steps[0] needs at least one call",
        "steps not an array": "InvalidArgumentError: steps must be an array of steps",
      }
    `)
  })

  test('simulates no steps without a request', async () => {
    expect(await Plan.simulate(tempo, { steps: [] })).toStrictEqual([])
  })
})

describe('Plan.estimateGas fees', () => {
  test.each([
    { maxFeePerGas: 30_000_000_000n, maxPriorityFeePerGas: 11_000_000_000n },
    { maxFeePerGas: 30_000_000_000n },
    { maxPriorityFeePerGas: 11_000_000_000n },
    { maxFeePerGas: 0n, maxPriorityFeePerGas: 0n },
    {},
  ])('preserves explicit fees on the wire: %#', async (fees) => {
    for (const chain of [tempoLocalnet, mainnet]) {
      for (const calls of chain === tempoLocalnet
        ? [[halt], [halt, halt]]
        : [[halt]]) {
        const requests: { method: string; params?: unknown }[] = []
        const client = createClient({
          chain,
          transport: custom({
            request: async (request) => {
              requests.push(request)
              if (request.method === 'eth_estimateGas') return '0x186a0'
              throw new Error(`unexpected request: ${request.method}`)
            },
          }),
        })
        const stateOverride = [{ address: venue, balance: 1n }]
        expect(
          await Plan.estimateGas(client, {
            account: sender,
            calls,
            ...fees,
            blockNumber: 42n,
            stateOverride,
          }),
        ).toBe(100_000n)
        expect(requests).toHaveLength(1)
        const request = requests[0] as (typeof requests)[number]
        expect(request.method).toBe('eth_estimateGas')
        const [transaction, block, overrides] = request.params as [
          Record<string, unknown>,
          string,
          unknown,
        ]
        expect(transaction.from).toBe(sender)
        for (const field of ['maxFeePerGas', 'maxPriorityFeePerGas'] as const)
          expect(transaction[field]).toBe(
            fees[field] === undefined
              ? undefined
              : `0x${fees[field].toString(16)}`,
          )
        if (calls.length > 1) {
          expect(transaction.type).toBe('0x76')
          expect(transaction.calls).toMatchObject(
            calls.map(({ to, data }) => ({ to, data })),
          )
          expect(transaction.to).toBeUndefined()
          expect(transaction.data).toBeUndefined()
        } else {
          expect(transaction.to).toBe(venue)
          expect(transaction.data).toBe(halt.data)
        }
        expect(block).toBe('0x2a')
        expect(overrides).toEqual({ [venue]: { balance: '0x1' } })
        expect(client.chain).toBe(chain)
      }
    }
  })
})

const customizedTempoChains = [
  { name: 'canonical', chain: tempoLocalnet },
  {
    name: 'copied formatter',
    chain: {
      ...tempoLocalnet,
      formatters: {
        ...tempoLocalnet.formatters,
        transactionRequest: { ...tempoLocalnet.formatters.transactionRequest },
      },
    },
  },
  {
    name: 'wrapped serializer',
    chain: {
      ...tempoLocalnet,
      serializers: {
        ...tempoLocalnet.serializers,
        transaction: (
          ...args: Parameters<typeof tempoLocalnet.serializers.transaction>
        ) => tempoLocalnet.serializers.transaction(...args),
      },
    },
  },
]

test.each(
  customizedTempoChains.flatMap(({ name, chain }) =>
    (['public', 'local'] as const).map((accountType) => ({
      name,
      chain,
      accountType,
    })),
  ),
)(
  'preserves single-call fees with $name Tempo configuration and $accountType account',
  async ({ chain, accountType }) => {
    const account =
      accountType === 'public'
        ? sender
        : privateKeyToAccount(`0x${'01'.repeat(32)}`)
    const requests: { method: string; params?: unknown }[] = []
    const configuredChain = { ...chain, feeToken: venue }
    const client = createClient({
      chain: configuredChain,
      transport: custom({
        request: async (request) => {
          requests.push(request)
          if (request.method === 'eth_estimateGas') return '0x186a0'
          if (request.method === 'eth_fillTransaction')
            throw { code: -32601, message: 'Method not found' }
          if (request.method === 'eth_getTransactionCount') return '0x0'
          if (request.method === 'eth_chainId') return '0x539'
          throw new Error(`unexpected request: ${request.method}`)
        },
      }),
    }).extend(publicActions)
    const originalEstimateGas = client.estimateGas
    const formatter = configuredChain.formatters.transactionRequest
    const originalFormat = formatter.format
    expect(
      await Plan.estimateGas(client, {
        account,
        calls: [halt],
        maxFeePerGas: 30_000_000_000n,
        maxPriorityFeePerGas: 11_000_000_000n,
        blockNumber: 42n,
        stateOverride: [{ address: venue, balance: 1n }],
      }),
    ).toBe(100_000n)
    const estimates = requests.filter(
      ({ method }) => method === 'eth_estimateGas',
    )
    expect(estimates).toHaveLength(1)
    expect(estimates[0]?.params).toEqual([
      expect.objectContaining({
        from: typeof account === 'string' ? account : account.address,
        type: '0x76',
        calls: [expect.objectContaining({ to: venue, data: halt.data })],
        feeToken: venue,
        maxFeePerGas: '0x6fc23ac00',
        maxPriorityFeePerGas: '0x28fa6ae00',
      }),
      '0x2a',
      { [venue]: { balance: '0x1' } },
    ])
    expect(client.chain).toBe(configuredChain)
    expect(client.estimateGas).toBe(originalEstimateGas)
    expect(configuredChain.formatters.transactionRequest).toBe(formatter)
    expect(formatter.format).toBe(originalFormat)
  },
)

test.each(
  (['bare', 'public', 'tempo'] as const).flatMap((actions) =>
    [1, 2].flatMap((callCount) =>
      ([undefined, 'pending'] as const).map((blockTag) => ({
        actions,
        callCount,
        blockTag,
      })),
    ),
  ),
)(
  'preserves explicit fees with $actions actions and $callCount calls with block context $blockTag',
  async ({ actions, callCount, blockTag }) => {
    const account = privateKeyToAccount(`0x${'01'.repeat(32)}`)
    const transactions: Record<string, unknown>[] = []
    const methods: string[] = []
    const baseClient = createClient({
      chain: tempoLocalnet,
      account,
      transport: custom({
        request: async ({ method, params }) => {
          methods.push(method)
          if (method === 'eth_estimateGas') {
            transactions.push((params as [Record<string, unknown>])[0])
            return '0x186a0'
          }
          if (method === 'eth_fillTransaction')
            throw { code: -32601, message: 'Method not found' }
          if (method === 'eth_getTransactionCount') return '0x0'
          if (method === 'eth_chainId') return '0x539'
          throw new Error(`unexpected request: ${method}`)
        },
      }),
    })
    const client =
      actions === 'bare'
        ? baseClient
        : actions === 'public'
          ? baseClient.extend(publicActions)
          : baseClient.extend(publicActions).extend(tempoActions())
    const originalEstimateGas =
      'estimateGas' in client ? client.estimateGas : undefined
    expect(
      await Plan.estimateGas(client, {
        account,
        calls: Array.from({ length: callCount }, () => halt),
        maxFeePerGas: 30_000_000_000n,
        maxPriorityFeePerGas: 11_000_000_000n,
        blockTag,
      }),
    ).toBe(100_000n)
    expect(client.chain).toBe(tempoLocalnet)
    expect('estimateGas' in client ? client.estimateGas : undefined).toBe(
      originalEstimateGas,
    )
    if (blockTag === undefined) {
      expect(methods).toContain('eth_fillTransaction')
      expect(methods).toContain('eth_getTransactionCount')
    } else {
      expect(methods).not.toContain('eth_fillTransaction')
      expect(methods).not.toContain('eth_getTransactionCount')
    }
    expect(transactions).toHaveLength(1)
    expect(transactions[0]).toMatchObject({
      from: account.address,
      ...(callCount > 1 ? { type: '0x76' } : {}),
      maxFeePerGas: '0x6fc23ac00',
      maxPriorityFeePerGas: '0x28fa6ae00',
      ...(callCount > 1
        ? {
            calls: Array.from({ length: callCount }, () => ({
              to: venue,
              data: halt.data,
            })),
          }
        : { to: venue, data: halt.data }),
    })
  },
)

describe('Plan.gasLimit', () => {
  test('adds 130%, rounded up, and refuses an estimate that is no gas amount', () => {
    expect(Plan.gasEstimateMultiplier).toBe(130n)
    expect(
      [0n, 1n, 100_000n, 1_000_001n].map((gas) => Plan.gasLimit(gas)),
    ).toStrictEqual([0n, 2n, 130_000n, 1_300_002n])
    expect(() => Plan.gasLimit(-1n)).toThrow(Errors.InvalidArgumentError)
    expect(() => Plan.gasLimit(1n << 64n)).toThrow(Errors.InvalidArgumentError)
  })
})
