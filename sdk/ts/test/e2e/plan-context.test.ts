// Real RPC execution: local signers must estimate in the same context as addresses.
import { createClient, http } from 'viem'
import { afterAll, beforeAll, expect, test } from 'vitest'
import { Actions, Plan } from '../../src/index.js'
import { type Fixture, start } from './fixture.js'

let f: Fixture
beforeAll(async () => {
  f = await start()
})
afterAll(async () => f?.stop())

test('local accounts preserve state overrides, with and without a pinned block', async () => {
  const client = createClient({ transport: http(f.rpc) })
  const calls = [{ to: f.accounts.stranger.address, data: '0x' as const }]
  for (const context of [
    {},
    { blockNumber: 0n },
    { blockTag: 'earliest' as const },
  ]) {
    for (const account of [f.accounts.owner.address, f.accounts.owner]) {
      // The actual target has no code; only the requested override makes it revert.
      await expect(
        Plan.estimateGas(client, { account, calls, ...context }),
      ).resolves.toBeGreaterThan(0n)
      await expect(
        Plan.estimateGas(client, {
          account,
          calls,
          ...context,
          stateOverride: [
            { address: f.accounts.stranger.address, code: '0x5f5ffd' },
          ],
        }),
      ).rejects.toThrow()
    }
  }
})

test('local accounts preserve a historical block independently of state overrides', async () => {
  const client = createClient({ transport: http(f.rpc) })
  const calls = [Actions.venue.setHalted.call({ venue: f.venue, halted: true })]
  for (const context of [
    { blockNumber: 0n },
    { blockTag: 'earliest' as const },
  ]) {
    const expected = await Plan.estimateGas(client, {
      account: f.accounts.owner.address,
      calls,
      ...context,
    })
    const latest = await Plan.estimateGas(client, {
      account: f.accounts.owner.address,
      calls,
    })
    expect(latest).not.toBe(expected)
    await expect(
      Plan.estimateGas(client, {
        account: f.accounts.owner,
        calls,
        ...context,
      }),
    ).resolves.toBe(expected)
  }
})

test('Tempo estimates retain explicit fees and overrides for single calls and batches', async () => {
  for (const account of [f.accounts.owner.address, f.accounts.owner]) {
    for (const callCount of [1, 2]) {
      const step = {
        account,
        calls: Array.from({ length: callCount }, () =>
          Actions.venue.setHalted.call({ venue: f.venue, halted: true }),
        ),
        maxFeePerGas: 30_000_000_000n,
        maxPriorityFeePerGas: 1_000_000_000n,
      }
      await expect(Plan.estimateGas(f.client, step)).resolves.toBeGreaterThan(
        0n,
      )
      await expect(
        Plan.estimateGas(f.client, {
          ...step,
          stateOverride: [{ address: f.venue, code: '0x5f5ffd' }],
        }),
      ).rejects.toThrow()
    }
  }
})
