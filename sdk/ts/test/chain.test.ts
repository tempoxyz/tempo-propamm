// Tempo chain detection: by viem/tempo's serializer and request formatter, never by a chain id or a schema field.
import { type Chain, defineChain } from 'viem'
import {
  anvil,
  mainnet,
  tempo,
  tempoDevnet,
  tempoLocalnet,
  tempoModerato,
} from 'viem/chains'
import { describe, expect, test } from 'vitest'
import { isTempoChain } from '../src/internal/chain.js'

describe('isTempoChain', () => {
  test("accepts viem/tempo's chains and chains built from them, and nothing else", () => {
    const cases: Record<string, Chain | undefined> = {
      tempo,
      tempoModerato,
      tempoDevnet,
      tempoLocalnet,
      'tempoLocalnet with its own RPC (as the e2e fixture builds it)': {
        ...tempoLocalnet,
        rpcUrls: { default: { http: ['http://127.0.0.1:8545'] } },
      },
      'tempo.extend({ feeToken })': tempo.extend({
        feeToken: '0x20c0000000000000000000000000000000000001',
      }),
      "viem/tempo's config under another id": defineChain({
        ...tempoLocalnet,
        id: 99_999,
      }),
      mainnet,
      anvil,
      'another chain at Tempo localnet id 1337': { ...mainnet, id: 1337 },
      'another chain with a schema field': {
        ...mainnet,
        extendSchema: {},
      } as Chain,
      'tempo with its serializer replaced': {
        ...tempo,
        serializers: { transaction: () => '0x' },
      },
      'no chain': undefined,
    }
    expect(
      Object.fromEntries(
        Object.entries(cases).map(([name, chain]) => [
          name,
          isTempoChain(chain),
        ]),
      ),
    ).toMatchInlineSnapshot(`
      {
        "another chain at Tempo localnet id 1337": false,
        "another chain with a schema field": false,
        "anvil": false,
        "mainnet": false,
        "no chain": false,
        "tempo": true,
        "tempo with its serializer replaced": false,
        "tempo.extend({ feeToken })": true,
        "tempoDevnet": true,
        "tempoLocalnet": true,
        "tempoLocalnet with its own RPC (as the e2e fixture builds it)": true,
        "tempoModerato": true,
        "viem/tempo's config under another id": true,
      }
    `)
  })
})
