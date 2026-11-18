import { createClient, custom, zeroAddress } from 'viem'
import { describe, expect, test } from 'vitest'
import { Info, Snapshot } from '../src/index.js'
import { readOptions } from '../src/internal/read.js'

const quantities = [
  'baseFeePerGas',
  'blobBaseFee',
  'gasLimit',
  'number',
  'prevRandao',
  'time',
] as const
const withdrawal = {
  address: zeroAddress,
  amount: 1n,
  index: 0,
  validatorIndex: 1,
}

describe('read block overrides', () => {
  test('rejects malformed overrides before any RPC, including block pinning', async () => {
    let calls = 0
    const client = createClient({
      transport: custom(
        {
          request: async () => {
            calls++
            throw new Error('unexpected RPC')
          },
        },
        { retryCount: 0 },
      ),
    })
    const invalid: unknown[] = [
      null,
      [],
      0,
      'override',
      { timestamp: 1n },
      { feeRecipient: '0x1234' },
      { withdrawals: null },
      { withdrawals: {} },
      { withdrawals: [null] },
      { withdrawals: Array(1) },
    ]
    for (const key of quantities)
      for (const value of [0, '0x1', null, true, -1n, 1n << 256n])
        invalid.push({ [key]: value })
    for (const key of ['address', 'amount', 'index', 'validatorIndex'])
      for (const value of [undefined, null, -1, -1n, '1'])
        invalid.push({ withdrawals: [{ ...withdrawal, [key]: value }] })
    invalid.push(
      { withdrawals: [{ ...withdrawal, index: Number.MAX_SAFE_INTEGER + 1 }] },
      { withdrawals: [{ ...withdrawal, extra: 1 }] },
    )
    for (const blockOverrides of invalid) {
      const parameters = {
        venue: '0x1111111111111111111111111111111111111111' as const,
        blockOverrides: blockOverrides as never,
      }
      for (const read of [Info.venueState, Snapshot.get])
        await expect(read(client, parameters)).rejects.toMatchObject({
          name: expect.stringMatching(/^Invalid(Argument|Address)Error$/),
        })
    }
    expect(calls).toBe(0)
  })

  test('preserves valid fields, zero and optional semantics', () => {
    expect(readOptions({})).toStrictEqual({})
    expect(readOptions({ blockOverrides: undefined })).toStrictEqual({})
    expect(readOptions({ blockOverrides: {} })).toStrictEqual({
      blockOverrides: {},
    })
    const blockOverrides = {
      ...Object.fromEntries(quantities.map((key) => [key, 0n])),
      feeRecipient: zeroAddress,
      withdrawals: [withdrawal],
    }
    expect(readOptions({ blockOverrides })).toStrictEqual({ blockOverrides })
    expect(
      readOptions({
        blockOverrides: { time: undefined, withdrawals: undefined },
      }),
    ).toStrictEqual({ blockOverrides: {} })
  })
})
