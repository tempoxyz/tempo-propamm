import {
  createClient,
  custom,
  type Hex,
  maxUint256,
  numberToHex,
  walletActions,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/chains'
import { Transaction } from 'viem/tempo'
import { expect, test } from 'vitest'
import { Actions, Errors, Sequencer } from '../src/index.js'

const venue = '0x1111111111111111111111111111111111111111' as const
const hash = `0x${'11'.repeat(32)}` as Hex
const invalid = [
  '1800000000',
  1_800_000_000n,
  null,
  true,
  {},
  [],
  Object(1_800_000_000),
  -1,
  1.5,
  Number.NaN,
  Number.POSITIVE_INFINITY,
  Number.NEGATIVE_INFINITY,
  Number.MAX_SAFE_INTEGER + 1,
]

function fixture(rpcAccount = false) {
  const requests: string[] = []
  const signed: object[] = []
  const sent: Hex[] = []
  const key = privateKeyToAccount(numberToHex(1, { size: 32 }))
  const account: typeof key = {
    ...key,
    async signTransaction(tx, options) {
      signed.push(tx)
      return key.signTransaction(tx, options)
    },
  }
  const client = createClient({
    account: rpcAccount ? account.address : account,
    chain: tempoModerato,
    transport: custom({
      async request({ method, params }) {
        requests.push(method)
        if (method === 'eth_fillTransaction') {
          const [request] = params as [
            { to: Hex; data?: Hex; input?: Hex; nonceKey?: Hex },
          ]
          return {
            raw: '0x',
            tx: {
              type: '0x76',
              chainId: '0xa5bf',
              nonceKey: request.nonceKey ?? '0x7',
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
        if (method === 'eth_chainId') return '0xa5bf'
        throw new Error(`Unexpected RPC ${method}`)
      },
    }),
  }).extend(walletActions)
  return { client, requests, signed, sent }
}

for (const rpcAccount of [false, true]) {
  for (const action of ['setHalted', 'setHaltedSync'] as const) {
    for (const parameter of ['validAfter', 'validBefore'] as const) {
      test.each(invalid)(
        `${action} rejects malformed ${parameter} before any RPC or signing (rpcAccount=${rpcAccount}): %#`,
        async (value) => {
          const f = fixture(rpcAccount)
          await expect(
            Actions.venue[action](f.client, {
              venue,
              halted: true,
              [parameter]: value,
            } as never),
          ).rejects.toMatchObject({
            name: 'InvalidArgumentError',
            parameter,
            value,
          })
          expect(f.requests).toEqual([])
          expect(f.signed).toEqual([])
          expect(f.sent).toEqual([])
        },
      )
    }
  }
}

for (const rpcAccount of [false, true]) {
  for (const action of ['setHalted', 'setHaltedSync'] as const) {
    test.each([
      { validAfter: 1, validBefore: 1 },
      { validAfter: 2, validBefore: 1 },
    ])(
      `${action} rejects an empty validity window (rpcAccount=${rpcAccount}): %j`,
      async (bounds) => {
        const f = fixture(rpcAccount)
        await expect(
          Actions.venue[action](f.client, { venue, halted: true, ...bounds }),
        ).rejects.toMatchObject({
          name: 'InvalidArgumentError',
          parameter: 'validBefore',
        })
        expect(f.requests).toEqual([])
        expect(f.signed).toEqual([])
      },
    )
  }
}

for (const action of ['cancelAll', 'cancelAllSync'] as const) {
  test.each([
    { validAfter: '1800000000' },
    { validBefore: 1_800_000_000n },
    { validAfter: null },
    { validAfter: 2, validBefore: 1 },
  ])(
    `${action} validates before reading or reserving sequences: %#`,
    async (bounds) => {
      const f = fixture()
      const sequencer = Sequencer.from({ 0: 7 })
      await expect(
        Actions.maker[action](f.client, {
          venue,
          sequencer,
          ...bounds,
        } as never),
      ).rejects.toBeInstanceOf(Errors.InvalidArgumentError)
      expect(sequencer.last).toEqual(new Map([[0, 7]]))
      expect(f.requests).toEqual([])
      expect(f.signed).toEqual([])
    },
  )
}

test.each([
  {},
  { validAfter: undefined, validBefore: undefined },
  { validAfter: 1 },
  { validBefore: 1 },
  { validAfter: 1_800_000_000 },
  { validBefore: Number.MAX_SAFE_INTEGER },
  { validAfter: Number.MAX_SAFE_INTEGER },
  {
    validAfter: Number.MAX_SAFE_INTEGER - 1,
    validBefore: Number.MAX_SAFE_INTEGER,
  },
  { validAfter: 1, validBefore: 1_800_000_000 },
  { validAfter: 1_800_000_000, validBefore: 1_800_000_001 },
])(
  'valid numeric bounds are preserved on the signed wire: %j',
  async (bounds) => {
    const f = fixture()
    await Actions.venue.setHalted(f.client, {
      venue,
      halted: true,
      nonceKey: 7n,
      ...bounds,
    })
    expect(f.signed).toHaveLength(1)
    const [serialized] = f.sent
    if (!serialized?.startsWith('0x76'))
      throw new Error('No Tempo transaction sent')
    const tx = Transaction.deserialize(serialized as `0x76${string}`)
    expect(tx.validAfter).toBe(
      'validAfter' in bounds ? bounds.validAfter : undefined,
    )
    expect(tx.validBefore).toBe(
      'validBefore' in bounds ? bounds.validBefore : undefined,
    )
  },
)

// An omitted nonceKey can become expiring during viem's concurrency detection.
const partialExpiringWindows = [
  { nonceKey: 'expiring', validBefore: 1 },
  { nonceKey: maxUint256, validBefore: 1 },
  { nonceKey: 'expiring', validAfter: Number.MAX_SAFE_INTEGER },
  { nonceKey: maxUint256, validAfter: Number.MAX_SAFE_INTEGER },
  { nonceKey: 'expiring', validBefore: 1_800_000_000 },
  { nonceKey: maxUint256, validAfter: 1 },
  { validBefore: 1 },
  { validAfter: Number.MAX_SAFE_INTEGER },
  { feePayer: true, validBefore: 1 },
] as const

for (const rpcAccount of [false, true]) {
  for (const action of [
    'setHalted',
    'setHaltedSync',
    'cancelAll',
    'cancelAllSync',
  ] as const) {
    test.each(partialExpiringWindows)(
      `${action} rejects a partial potentially expiring window before side effects (rpcAccount=${rpcAccount}): %#`,
      async (bounds) => {
        const f = fixture(rpcAccount)
        const sequencer = Sequencer.from({ 0: 7 })
        await expect(
          action === 'setHalted' || action === 'setHaltedSync'
            ? Actions.venue[action](f.client, {
                venue,
                halted: true,
                ...bounds,
              } as never)
            : Actions.maker[action](f.client, {
                venue,
                sequencer,
                ...bounds,
              } as never),
        ).rejects.toMatchObject({
          name: 'InvalidArgumentError',
          parameter: 'validAfter' in bounds ? 'validBefore' : 'validAfter',
          shortMessage: expect.stringContaining(
            'explicit non-expiring nonceKey',
          ),
        })
        expect(sequencer.last).toEqual(new Map([[0, 7]]))
        expect(f.requests).toEqual([])
        expect(f.signed).toEqual([])
        expect(f.sent).toEqual([])
      },
    )
  }
}

for (const nonceKey of ['expiring', maxUint256] as const) {
  test.each([{}, { validAfter: 1, validBefore: Number.MAX_SAFE_INTEGER }])(
    'expiring defaults and complete windows still sign (nonceKey=%s): %j',
    async (bounds) => {
      const f = fixture()
      await Actions.venue.setHalted(f.client, {
        venue,
        halted: true,
        nonceKey,
        ...bounds,
      })
      expect(f.signed).toHaveLength(1)
      const [serialized] = f.sent
      if (!serialized?.startsWith('0x76'))
        throw new Error('No Tempo transaction sent')
      const tx = Transaction.deserialize(serialized as `0x76${string}`)
      expect(tx.nonceKey).toBe(maxUint256)
      expect(tx.validAfter).toEqual(expect.any(Number))
      expect(tx.validBefore).toEqual(expect.any(Number))
      expect(tx.validBefore).toBeGreaterThan(tx.validAfter ?? 0)
      if ('validAfter' in bounds) {
        expect(tx.validAfter).toBe(bounds.validAfter)
        expect(tx.validBefore).toBe(bounds.validBefore)
      }
    },
  )
}

for (const rpcAccount of [false, true]) {
  for (const action of [
    'setHalted',
    'setHaltedSync',
    'cancelAll',
    'cancelAllSync',
  ] as const) {
    for (const parameter of ['validAfter', 'validBefore'] as const) {
      test.each([0, -0])(
        `${action} rejects zero ${parameter} even in a non-expiring lane (rpcAccount=${rpcAccount}): %#`,
        async (value) => {
          const f = fixture(rpcAccount)
          const sequencer = Sequencer.from({ 0: 7 })
          const bounds = { nonceKey: 7n, [parameter]: value }
          await expect(
            action === 'setHalted' || action === 'setHaltedSync'
              ? Actions.venue[action](f.client, {
                  venue,
                  halted: true,
                  ...bounds,
                })
              : Actions.maker[action](f.client, {
                  venue,
                  sequencer,
                  ...bounds,
                }),
          ).rejects.toMatchObject({
            name: 'InvalidArgumentError',
            parameter,
            value,
            shortMessage: expect.stringContaining('positive safe-integer'),
          })
          expect(sequencer.last).toEqual(new Map([[0, 7]]))
          expect(f.requests).toEqual([])
          expect(f.signed).toEqual([])
          expect(f.sent).toEqual([])
        },
      )
    }
  }
}

// Runtime callers can bypass TypeScript; only viem's actual nonce lanes are valid.
for (const rpcAccount of [false, true]) {
  for (const action of [
    'setHalted',
    'setHaltedSync',
    'cancelAll',
    'cancelAllSync',
  ] as const) {
    test.each([
      null,
      7,
      '7',
      'parallel',
      {},
      [],
      true,
      Object(7n),
      -1n,
      maxUint256 + 1n,
    ])(
      `${action} rejects malformed nonceKey before side effects (rpcAccount=${rpcAccount}): %#`,
      async (nonceKey) => {
        for (const bounds of [
          {},
          { validAfter: 1 },
          { validBefore: 1_800_000_000 },
          { validAfter: 1, validBefore: 1_800_000_000 },
        ]) {
          const f = fixture(rpcAccount)
          const sequencer = Sequencer.from({ 0: 7 })
          const parameters = { venue, nonceKey, ...bounds }
          await expect(
            action === 'setHalted' || action === 'setHaltedSync'
              ? Actions.venue[action](f.client, {
                  ...parameters,
                  halted: true,
                } as never)
              : Actions.maker[action](f.client, {
                  ...parameters,
                  sequencer,
                } as never),
          ).rejects.toMatchObject({
            name: 'InvalidArgumentError',
            parameter: 'nonceKey',
            value: nonceKey,
          })
          expect(sequencer.last).toEqual(new Map([[0, 7]]))
          expect(f.requests).toEqual([])
          expect(f.signed).toEqual([])
          expect(f.sent).toEqual([])
        }
      },
    )
  }
}

for (const nonceKey of [0n, 1n, maxUint256 - 1n]) {
  test.each([{}, { validAfter: 1 }, { validBefore: 1_800_000_000 }])(
    `explicit non-expiring lane ${nonceKey} preserves partial bounds: %j`,
    async (bounds) => {
      const f = fixture()
      await Actions.venue.setHalted(f.client, {
        venue,
        halted: true,
        nonceKey,
        ...bounds,
      })
      expect(f.signed).toHaveLength(1)
      const [serialized] = f.sent
      if (!serialized?.startsWith('0x76'))
        throw new Error('No Tempo transaction sent')
      const tx = Transaction.deserialize(serialized as `0x76${string}`)
      expect(tx.nonceKey).toBe(nonceKey)
      expect(tx.validAfter).toBe(
        'validAfter' in bounds ? bounds.validAfter : undefined,
      )
      expect(tx.validBefore).toBe(
        'validBefore' in bounds ? bounds.validBefore : undefined,
      )
    },
  )
}
