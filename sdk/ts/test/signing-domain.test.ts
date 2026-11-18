import {
  createClient,
  custom,
  type Hex,
  maxUint256,
  numberToHex,
  publicActions,
  walletActions,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/chains'
import { Transaction } from 'viem/tempo'
import { expect, test } from 'vitest'
import { Actions } from '../src/index.js'

const venue = '0x1111111111111111111111111111111111111111' as const
function deserialize(sent: Hex[]) {
  const [serialized] = sent
  if (!serialized) throw new Error('No transaction sent')
  if (!serialized.startsWith('0x76'))
    throw new Error('Expected a Tempo transaction')
  return Transaction.deserialize(serialized as `0x76${string}`)
}
const hash = `0x${'11'.repeat(32)}` as Hex
function fixture(chainId = 42431, nonceKey = 7n, type = '0x76') {
  const signed: object[] = []
  const sent: Hex[] = []
  const rpcSent: object[] = []
  const key = privateKeyToAccount(numberToHex(1, { size: 32 }))
  const account: typeof key = {
    ...key,
    async signTransaction(tx, options) {
      signed.push(tx)
      return key.signTransaction(tx, options)
    },
  }
  const transport = custom({
    async request({ method, params }) {
      if (method === 'eth_fillTransaction') {
        const [request] = params as [{ to: Hex; data?: Hex; input?: Hex }]
        return {
          raw: '0x',
          tx: {
            type,
            chainId: numberToHex(chainId),
            nonceKey: numberToHex(nonceKey),
            from: account.address,
            to: request.to,
            input: request.data ?? request.input,
            nonce: '0x0',
            gas: '0x30d40',
            maxFeePerGas: '0x3b9aca00',
            maxPriorityFeePerGas: '0x3b9aca00',
            feeToken: '0x20c0000000000000000000000000000000000000',
            blockHash: null,
            blockNumber: null,
            transactionIndex: null,
            hash,
          },
        }
      }
      if (method === 'eth_sendRawTransaction') {
        sent.push((params as [Hex])[0])
        return hash
      }
      if (method === 'eth_sendTransaction') {
        rpcSent.push((params as [object])[0])
        return hash
      }
      if (method === 'eth_chainId') return numberToHex(chainId)
      throw new Error(`Unexpected RPC ${method}`)
    },
  })
  return { account, transport, signed, sent, rpcSent }
}
for (const accountLocation of ['hoisted', 'parameter'] as const) {
  for (const decorated of [false, true]) {
    for (const attack of ['chainId', 'nonceKey'] as const) {
      test(`refuses forged ${attack}, ${accountLocation}, decorated=${decorated}`, async () => {
        const f = fixture(
          attack === 'chainId' ? 4217 : 42431,
          attack === 'nonceKey' ? 9n : 7n,
        )
        const base = createClient({
          chain: tempoModerato,
          transport: f.transport,
          ...(accountLocation === 'hoisted' ? { account: f.account } : {}),
        })
        const client = decorated
          ? base.extend(walletActions).extend(publicActions)
          : base
        await expect(
          Actions.venue.setHalted(client, {
            venue,
            halted: true,
            nonceKey: 7n,
            ...(accountLocation === 'parameter' ? { account: f.account } : {}),
          }),
        ).rejects.toThrow(attack)
        expect(f.signed).toHaveLength(0)
        expect(f.sent).toHaveLength(0)
      })
    }
  }
}
test('canonical domain reaches the original signer and serializer', async () => {
  const f = fixture()
  const client = createClient({
    chain: tempoModerato,
    account: f.account,
    transport: f.transport,
  })
  await expect(
    Actions.venue.setHalted(client, { venue, halted: true, nonceKey: 7n }),
  ).resolves.toBe(hash)
  expect(f.signed).toHaveLength(1)
  const tx = deserialize(f.sent)
  expect(tx.chainId).toBe(42431)
  expect(tx.nonceKey).toBe(7n)
})

test('explicit chain overrides the hoisted chain', async () => {
  const f = fixture(4217)
  const client = createClient({
    chain: tempoModerato,
    account: f.account,
    transport: f.transport,
  })
  await Actions.venue.setHalted(client, {
    venue,
    halted: true,
    nonceKey: 7n,
    chain: { ...tempoModerato, id: 4217 },
  })
  expect(deserialize(f.sent).chainId).toBe(4217)
})
test('an unspecified nonce lane may still be prepared by viem', async () => {
  const f = fixture(42431, 9n)
  const client = createClient({
    chain: tempoModerato,
    account: f.account,
    transport: f.transport,
  })
  await Actions.venue.setHalted(client, { venue, halted: true })
  expect(deserialize(f.sent).nonceKey).toBe(9n)
})
test('a chainless client can use an explicit chain', async () => {
  const f = fixture()
  const client = createClient({ account: f.account, transport: f.transport })
  await Actions.venue.setHalted(client, {
    venue,
    halted: true,
    nonceKey: 7n,
    chain: tempoModerato,
  })
  expect(deserialize(f.sent).chainId).toBe(42431)
})
test('synchronous writes refuse a forged chain before signing or requesting a receipt', async () => {
  const f = fixture(4217)
  const client = createClient({
    account: f.account,
    chain: tempoModerato,
    transport: f.transport,
  }).extend(walletActions)
  await expect(
    Actions.venue.setHaltedSync(client, { venue, halted: true, nonceKey: 7n }),
  ).rejects.toThrow('chainId')
  expect(f.signed).toHaveLength(0)
  expect(f.sent).toHaveLength(0)
})
test('null chain intentionally leaves chain selection to viem', async () => {
  const f = fixture(4217)
  const client = createClient({
    chain: tempoModerato,
    account: f.account,
    transport: f.transport,
  })
  await Actions.venue.setHalted(client, {
    venue,
    halted: true,
    nonceKey: 7n,
    chain: null,
  })
  expect(f.signed).toHaveLength(1)
  expect(f.sent).toHaveLength(1)
})

test('a chainless client without an override preserves viem chain discovery', async () => {
  const f = fixture(4217, 0n, '0x2')
  const client = createClient({ account: f.account, transport: f.transport })
  await Actions.venue.setHalted(client, {
    venue,
    halted: true,
    chain: undefined,
  })
  expect(f.signed).toHaveLength(1)
  const [serialized] = f.sent
  if (!serialized) throw new Error('No transaction sent')
  expect(Transaction.deserialize(serialized).chainId).toBe(4217)
})
test('JSON-RPC accounts continue using the wallet without a local signer', async () => {
  const f = fixture()
  const client = createClient({
    chain: tempoModerato,
    account: f.account.address,
    transport: f.transport,
  }).extend(walletActions)
  await expect(
    Actions.venue.setHalted(client, { venue, halted: true, nonceKey: 7n }),
  ).resolves.toBe(hash)
  expect(f.signed).toHaveLength(0)
  expect(f.sent).toHaveLength(0)
  expect(f.rpcSent).toHaveLength(1)
  expect(f.rpcSent[0]).toMatchObject({
    nonceKey: '0x7',
    calls: [{ to: venue }],
  })
})
test('JSON-RPC accounts retain viem chain-mismatch refusal', async () => {
  const f = fixture(4217)
  const client = createClient({
    chain: tempoModerato,
    account: f.account.address,
    transport: f.transport,
  })
  await expect(
    Actions.venue.setHalted(client, { venue, halted: true }),
  ).rejects.toThrow('does not match')
  expect(f.rpcSent).toHaveLength(0)
})

for (const attack of ['none', 'chainId', 'nonceKey'] as const) {
  test(`expiring nonce lane: ${attack}`, async () => {
    const f = fixture(
      attack === 'chainId' ? 4217 : 42431,
      attack === 'nonceKey' ? 7n : maxUint256,
    )
    const client = createClient({
      chain: tempoModerato,
      account: f.account,
      transport: f.transport,
    }).extend(walletActions)
    const result = Actions.venue.setHalted(client, {
      venue,
      halted: true,
      nonceKey: 'expiring',
    })
    if (attack !== 'none') {
      await expect(result).rejects.toThrow(attack)
      expect(f.signed).toHaveLength(0)
      expect(f.sent).toHaveLength(0)
      return
    }
    await expect(result).resolves.toBe(hash)
    expect(f.signed).toHaveLength(1)
    const tx = deserialize(f.sent)
    expect(tx.chainId).toBe(42431)
    expect(tx.nonceKey).toBe(maxUint256)
    expect(tx.nonce).toBe(0)
    expect(tx.validAfter).toBeTypeOf('number')
    expect(tx.validBefore).toBeTypeOf('number')
  })
}

test('custom local accounts retain inherited and nonenumerable properties without changing signer this', async () => {
  const f = fixture()
  let reads = 0
  const account: typeof f.account = Object.create(f.account, {
    nonceManager: {
      get() {
        reads++
        return undefined
      },
    },
    signTransaction: {
      value: async function (
        ...args: Parameters<typeof f.account.signTransaction>
      ) {
        expect(this).toBe(account)
        return f.account.signTransaction(...args)
      },
    },
  })
  const client = createClient({
    chain: tempoModerato,
    account,
    transport: f.transport,
  })
  await expect(
    Actions.venue.setHalted(client, { venue, halted: true, nonceKey: 7n }),
  ).resolves.toBe(hash)
  expect(reads).toBeGreaterThan(0)
  expect(f.signed).toHaveLength(1)
  expect(deserialize(f.sent).nonceKey).toBe(7n)
})

for (const decorated of [false, true]) {
  test(`null account opts out of the hoisted local signer, decorated=${decorated}`, async () => {
    const f = fixture()
    const base = createClient({
      chain: tempoModerato,
      account: f.account,
      transport: f.transport,
    })
    const client = decorated ? base.extend(walletActions) : base
    await expect(
      Actions.venue.setHalted(client, {
        venue,
        halted: true,
        account: null,
      }),
    ).resolves.toBe(hash)
    expect(f.signed).toHaveLength(0)
    expect(f.sent).toHaveLength(0)
    expect(f.rpcSent).toHaveLength(1)
    expect(f.rpcSent[0]).not.toHaveProperty('from')
  })
}

for (const receiver of ['address', 'nonceManager', 'methods'] as const) {
  for (const attack of ['none', 'chainId', 'nonceKey'] as const) {
    test(`frozen private-state account: ${receiver}, ${attack}`, async () => {
      const f = fixture(
        attack === 'chainId' ? 4217 : 42431,
        attack === 'nonceKey' ? 9n : 7n,
      )
      const reads: string[] = []
      class CustomAccount {
        #key = f.account
        readonly type = 'local' as const
        readonly source = 'custom'
        readonly publicKey = f.account.publicKey
        readonly signTypedData = f.account.signTypedData
        get address() {
          reads.push('address')
          return receiver === 'address' ? this.#key.address : f.account.address
        }
        get nonceManager() {
          reads.push('nonceManager')
          return receiver === 'nonceManager'
            ? this.#key.nonceManager
            : f.account.nonceManager
        }
        signMessage(...args: Parameters<typeof f.account.signMessage>) {
          expect(this).toBe(account)
          reads.push('signMessage')
          return this.#key.signMessage(...args)
        }
        signTransaction(...args: Parameters<typeof f.account.signTransaction>) {
          expect(this).toBe(account)
          return this.#key.signTransaction(...args)
        }
      }
      // Neither replacing this own signer nor proxying this frozen object can override it.
      const account = Object.freeze(
        Object.defineProperty(new CustomAccount(), 'signTransaction', {
          value: CustomAccount.prototype.signTransaction,
          writable: false,
          configurable: false,
        }),
      )
      const descriptors = Object.getOwnPropertyDescriptors(account)
      const chain: typeof tempoModerato = {
        ...tempoModerato,
        prepareTransactionRequest: [
          async (request, options) => {
            if (receiver === 'methods') {
              const wrapped = request.account
              if (
                !wrapped ||
                typeof wrapped === 'string' ||
                wrapped.type !== 'local'
              )
                throw new Error('Missing local account')
              expect(wrapped).toBeInstanceOf(CustomAccount)
              expect('publicKey' in wrapped).toBe(true)
              // A preparation hook can use other account methods before transaction signing.
              // These must still run on the original receiver, not the facade.
              await wrapped.signMessage({ message: 'prepare transaction' })
            }
            return tempoModerato.prepareTransactionRequest[0](request, options)
          },
          tempoModerato.prepareTransactionRequest[1],
        ],
      }
      const client = createClient({
        chain,
        ...(receiver === 'nonceManager' ? {} : { account }),
        transport: f.transport,
      }).extend(walletActions)
      const result = Actions.venue.setHalted(client, {
        venue,
        halted: true,
        nonceKey: 7n,
        ...(receiver === 'nonceManager' ? { account } : {}),
      })
      if (attack === 'none') {
        await expect(result).resolves.toBe(hash)
        expect(f.signed).toHaveLength(1)
        expect(deserialize(f.sent)).toMatchObject({
          chainId: 42431,
          nonceKey: 7n,
        })
      } else {
        await expect(result).rejects.toThrow(attack)
        expect(f.signed).toHaveLength(0)
        expect(f.sent).toHaveLength(0)
      }
      expect(reads).toContain(receiver === 'methods' ? 'signMessage' : receiver)
      expect(client.account).toBe(
        receiver === 'nonceManager' ? undefined : account,
      )
      expect(Object.getOwnPropertyDescriptors(account)).toEqual(descriptors)
      expect(Object.isFrozen(account)).toBe(true)
    })
  }
}
