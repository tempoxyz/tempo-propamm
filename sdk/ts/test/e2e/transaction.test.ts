// A write's transaction fields, on anvil --network tempo: every viem/tempo field the SDK takes reaches the transaction
// the node mines (read back with `eth_getTransactionByHash`), a post's fee fields, gas, nonce and nonce key included;
// the sender defaults to the client's account, viem checks the chain, a revert is viem's error naming the contract's,
// and a Sync twin whose transaction reverts throws, or returns its status and receipt alone.
import { type Address, bytesToHex, createClient, type Hex, http } from 'viem'
import { mnemonicToAccount } from 'viem/accounts'
import {
  estimateContractGas,
  getBlock,
  getTransaction,
  getTransactionCount,
  getTransactionReceipt,
  simulateContract,
} from 'viem/actions'
import { tempoModerato } from 'viem/chains'
import { Account } from 'viem/tempo'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import {
  Actions,
  Errors,
  Fees,
  Price,
  Sequencer,
  Venue,
} from '../../src/index.js'
import {
  BETA_USD,
  type Fixture,
  mined,
  type PairSetup,
  setupPair,
  start,
} from './fixture.js'

let f: Fixture
let p: PairSetup

beforeAll(async () => {
  f = await start()
  p = await setupPair(f)
})
afterAll(async () => f?.stop())

describe('transaction fields', () => {
  test('feeToken, feePayer, nonceKey, validAfter and validBefore reach the mined transaction', async () => {
    const { owner, other } = f.accounts
    const { timestamp } = await getBlock(f.client)
    const validAfter = Number(timestamp) - 60
    const validBefore = Number(timestamp) + 3_600
    const result = mined(
      await Actions.venue.setHaltedSync(f.client, {
        venue: f.venue,
        halted: false,
        account: owner,
        feeToken: BETA_USD,
        feePayer: other,
        nonceKey: 7n,
        validAfter,
        validBefore,
      }),
    )
    expect(result.changed).toBe(false)
    const { receipt } = result
    const tx = await getTransaction(f.client, {
      hash: receipt.transactionHash,
    })
    expect({
      type: tx.type,
      from: tx.from.toLowerCase(),
      feeToken: tx.feeToken,
      nonceKey: tx.nonceKey,
      validAfter: tx.validAfter === validAfter,
      validBefore: tx.validBefore === validBefore,
      feePayerSigned: tx.feePayerSignature !== undefined,
      feePayer: receipt.feePayer,
    }).toStrictEqual({
      type: 'tempo',
      from: owner.address.toLowerCase(),
      feeToken: BETA_USD,
      nonceKey: 7n,
      validAfter: true,
      validBefore: true,
      feePayerSigned: true,
      feePayer: other.address.toLowerCase(),
    })
  })

  test('keyAuthorization authorizes an access key that sends in the same transaction', async () => {
    // Anvil's dev mnemonic: account 0 is the fixture's owner.
    const { privateKey } = mnemonicToAccount(
      'test test test test test test test test test test test junk',
    ).getHdKey()
    if (!privateKey) throw new Error('the owner has no private key')
    const root = Account.fromSecp256k1(bytesToHex(privateKey))
    const accessKey = Account.fromSecp256k1(`0x${'ab'.repeat(32)}`, {
      access: root,
    })
    const keyAuthorization = await root.signKeyAuthorization(accessKey, {
      chainId: BigInt(f.client.chain.id),
    })
    const { receipt } = await Actions.venue.setHaltedSync(f.client, {
      venue: f.venue,
      halted: false,
      account: accessKey,
      keyAuthorization,
    })
    const tx = await getTransaction(f.client, {
      hash: receipt.transactionHash,
    })
    expect(tx.from.toLowerCase()).toBe(root.address.toLowerCase())
    expect(tx.keyAuthorization?.address).toBe(accessKey.accessKeyAddress)
  })

  test('access Sync writes reject a codeless venue instead of claiming a no-op', async () => {
    const { owner, other, stranger } = f.accounts
    const common = { venue: stranger.address, account: owner, gas: 1_000_000n }
    for (const halted of [false, true])
      await expect(
        Actions.venue.setHaltedSync(f.client, { ...common, halted }),
      ).rejects.toThrow(/returned no data/)
    await expect(
      Actions.venue.approveAgentSync(f.client, {
        ...common,
        agent: other.address,
      }),
    ).rejects.toThrow(/returned no data/)
    await expect(
      Actions.venue.revokeAgentSync(f.client, {
        ...common,
        agent: other.address,
      }),
    ).rejects.toThrow(/returned no data/)
    for (const deny of [false, true])
      await expect(
        Actions.venue.setDeniedSync(f.client, {
          ...common,
          accounts: [other.address],
          deny,
        }),
      ).rejects.toThrow(/returned no data/)
  })

  test('eventless access writes accept uppercase venue, agent and account addresses', async () => {
    const { owner, agent, other } = f.accounts
    const upper = (address: Address): Address =>
      `0x${address.slice(2).toUpperCase()}`
    const common = { venue: upper(f.venue), account: owner }
    expect(
      mined(
        await Actions.venue.setHaltedSync(f.client, {
          ...common,
          halted: false,
        }),
      ).changed,
    ).toBe(false)
    expect(
      mined(
        await Actions.venue.approveAgentSync(f.client, {
          ...common,
          agent: upper(agent.address),
        }),
      ).changed,
    ).toBe(false)
    expect(
      mined(
        await Actions.venue.revokeAgentSync(f.client, {
          ...common,
          agent: upper(other.address),
        }),
      ).changed,
    ).toBe(false)
    expect(
      mined(
        await Actions.venue.setDeniedSync(f.client, {
          ...common,
          accounts: [upper(other.address)],
          deny: false,
        }),
      ).updates,
    ).toStrictEqual([])
  })

  test('eventless writes remain successful when a later transaction changes their state in the same block', async () => {
    const { owner, agent, other } = f.accounts
    const common = { venue: f.venue, account: owner, gas: 1_000_000n }
    const automine = (on: boolean) =>
      f.client.request({
        method: 'evm_setAutomine' as never,
        params: [on] as never,
      })
    async function together<
      T extends {
        receipt: { blockNumber: bigint | null; transactionIndex: number }
      },
    >(
      first: (nonce: number) => Promise<T>,
      later: (nonce: number) => Promise<Hex>,
    ): Promise<T> {
      const nonce = await getTransactionCount(f.client, {
        address: owner.address,
      })
      await automine(false)
      try {
        const pending = first(nonce)
        // The old implementation rejects once mined. Attach a handler immediately, but still assert its result below.
        const result = pending.then(
          (value) => ({ value }),
          (error) => ({ error }),
        )
        await expect
          .poll(() =>
            getTransactionCount(f.client, {
              address: owner.address,
              blockTag: 'pending',
            }),
          )
          .toBe(nonce + 1)
        const hash = await later(nonce + 1)
        await f.client.request({
          method: 'evm_mine' as never,
          params: [] as never,
        })
        const settled = await result
        if ('error' in settled) throw settled.error
        const next = await getTransactionReceipt(f.client, { hash })
        expect(next.status).toBe('success')
        expect(next.blockNumber).toBe(settled.value.receipt.blockNumber)
        expect(next.transactionIndex).toBeGreaterThan(
          settled.value.receipt.transactionIndex,
        )
        return settled.value
      } finally {
        await automine(true)
      }
    }
    const halted = mined(
      await together(
        (nonce) =>
          Actions.venue.setHaltedSync(f.client, {
            ...common,
            nonce,
            halted: false,
          }),
        (nonce) =>
          Actions.venue.setHalted(f.client, { ...common, nonce, halted: true }),
      ),
    )
    expect(halted.changed).toBe(false)
    await Actions.venue.setHaltedSync(f.client, { ...common, halted: false })
    const approved = mined(
      await together(
        (nonce) =>
          Actions.venue.approveAgentSync(f.client, {
            ...common,
            nonce,
            agent: agent.address,
          }),
        (nonce) =>
          Actions.venue.revokeAgent(f.client, {
            ...common,
            nonce,
            agent: agent.address,
          }),
      ),
    )
    expect(approved.changed).toBe(false)
    await Actions.venue.approveAgentSync(f.client, {
      ...common,
      agent: agent.address,
    })
    const revoked = mined(
      await together(
        (nonce) =>
          Actions.venue.revokeAgentSync(f.client, {
            ...common,
            nonce,
            agent: other.address,
          }),
        (nonce) =>
          Actions.venue.approveAgent(f.client, {
            ...common,
            nonce,
            agent: other.address,
          }),
      ),
    )
    expect(revoked.changed).toBe(false)
    await Actions.venue.revokeAgentSync(f.client, {
      ...common,
      agent: other.address,
    })
    await Actions.venue.setDeniedSync(f.client, {
      ...common,
      accounts: [other.address],
      deny: true,
    })
    const denied = mined(
      await together(
        (nonce) =>
          Actions.venue.setDeniedSync(f.client, {
            ...common,
            nonce,
            accounts: [other.address, agent.address],
            deny: true,
          }),
        (nonce) =>
          Actions.venue.setDenied(f.client, {
            ...common,
            nonce,
            accounts: [other.address, agent.address],
            deny: false,
          }),
      ),
    )
    expect(denied.updates).toStrictEqual([
      { account: agent.address, denied: true, by: owner.address },
    ])
  })

  test('idempotent access writes report no change without requiring an event', async () => {
    const { agent, other, owner } = f.accounts
    const halted = mined(
      await Actions.venue.setHaltedSync(f.client, {
        venue: f.venue,
        halted: false,
        account: owner,
      }),
    )
    expect(halted.changed).toBe(false)

    const approved = mined(
      await Actions.venue.approveAgentSync(f.client, {
        venue: f.venue,
        agent: agent.address,
        account: owner,
      }),
    )
    expect(approved.changed).toBe(false)

    const denied = mined(
      await Actions.venue.setDeniedSync(f.client, {
        venue: f.venue,
        accounts: [other.address],
        deny: true,
        account: owner,
      }),
    )
    expect(denied.updates).toStrictEqual([
      { account: other.address, denied: true, by: owner.address },
    ])
    const alreadyDenied = mined(
      await Actions.venue.setDeniedSync(f.client, {
        venue: f.venue,
        accounts: [other.address],
        deny: true,
        account: owner,
      }),
    )
    expect(alreadyDenied.updates).toStrictEqual([])
    const mixed = mined(
      await Actions.venue.setDeniedSync(f.client, {
        venue: f.venue,
        accounts: [other.address, agent.address],
        deny: true,
        account: owner,
      }),
    )
    expect(mixed.updates).toStrictEqual([
      { account: agent.address, denied: true, by: owner.address },
    ])
    await Actions.venue.setDeniedSync(f.client, {
      venue: f.venue,
      accounts: [other.address, agent.address],
      deny: false,
      account: owner,
    })

    const revoked = mined(
      await Actions.venue.revokeAgentSync(f.client, {
        venue: f.venue,
        agent: other.address,
        account: owner,
      }),
    )
    expect(revoked.changed).toBe(false)
  })
})

describe("a post's fee fields", () => {
  test('maxFeePerGas and maxPriorityFeePerGas, gas, nonce and nonceKey reach the mined transaction', async () => {
    const { agent } = f.accounts
    const { baseFeePerGas } = await getBlock(f.client)
    assert(baseFeePerGas !== null)
    const fees = Fees.feeFields(
      baseFeePerGas,
      Fees.makerTip(Venue.defaultTakerPriorityFeeCap),
    )
    // The first transaction on a fresh nonce key: its nonce in that lane is 0.
    const { receipt, outcome } = mined(
      await Actions.maker.orderSync(f.client, {
        venue: f.venue,
        order: {
          pairIndex: p.pairIndex,
          mid: Price.parse('1.085'),
          shapeId: 7,
          sequence: Sequencer.next(p.sequencer, p.pairIndex),
          validUntil: p.validUntil,
        },
        account: agent,
        ...fees,
        gas: 600_000n,
        nonce: 0,
        nonceKey: 9n,
      }),
    )
    expect(outcome.allAccepted).toBe(true)
    const tx = await getTransaction(f.client, {
      hash: receipt.transactionHash,
    })
    expect({
      maxFeePerGas: tx.maxFeePerGas,
      maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
      gas: tx.gas,
      nonce: tx.nonce,
      nonceKey: tx.nonceKey,
    }).toStrictEqual({
      maxFeePerGas: fees.maxFeePerGas,
      maxPriorityFeePerGas: 11n * Fees.gwei,
      gas: 600_000n,
      nonce: 0,
      nonceKey: 9n,
    })
  })
})

describe('a Sync twin whose transaction reverts', () => {
  // With a gas limit given, viem sends without estimating, so the transaction is mined and reverts.
  test('throws by default, and returns its status and receipt alone without throwOnReceiptRevert', async () => {
    const { stranger } = f.accounts
    const halt = {
      venue: f.venue,
      halted: true,
      account: stranger,
      gas: 1_000_000n,
    }
    await expect(Actions.venue.setHaltedSync(f.client, halt)).rejects.toThrow(
      /reverted/,
    )
    const result = await Actions.venue.setHaltedSync(f.client, {
      ...halt,
      throwOnReceiptRevert: false,
    })
    expect(Object.keys(result).sort()).toStrictEqual(['receipt', 'status'])
    expect([result.status, result.receipt.status]).toStrictEqual([
      'reverted',
      'reverted',
    ])
  })

  test('the same for a post, and cancelAllSync keeps its skipped pairs beside it', async () => {
    const { stranger } = f.accounts
    const order = {
      pairIndex: p.pairIndex,
      mid: Price.one,
      shapeId: 7,
      sequence: Sequencer.next(p.sequencer, p.pairIndex),
      validUntil: p.validUntil,
    }
    const post = {
      venue: f.venue,
      order,
      account: stranger,
      gas: 1_000_000n,
    }
    await expect(Actions.maker.orderSync(f.client, post)).rejects.toThrow(
      /reverted/,
    )
    const result = await Actions.maker.orderSync(f.client, {
      ...post,
      throwOnReceiptRevert: false,
    })
    expect(Object.keys(result).sort()).toStrictEqual(['receipt', 'status'])
    expect(result.status).toBe('reverted')
    const all = await Actions.maker.cancelAllSync(f.client, {
      venue: f.venue,
      account: stranger,
      gas: 1_000_000n,
      throwOnReceiptRevert: false,
    })
    expect(Object.keys(all).sort()).toStrictEqual([
      'receipt',
      'skipped',
      'status',
    ])
    expect([all.status, all.skipped]).toStrictEqual(['reverted', []])
  })
})

describe('the sender and the chain', () => {
  test("default to the client's", async () => {
    const client = createClient({
      account: f.accounts.owner,
      chain: f.client.chain,
      transport: http(f.rpc),
    })
    const { receipt } = await Actions.venue.setHaltedSync(client, {
      venue: f.venue,
      halted: false,
    })
    expect(receipt.from).toBe(f.accounts.owner.address.toLowerCase())
  })

  test("are viem's errors when missing or mismatched", async () => {
    await expect(
      Actions.venue.setHalted(f.client, {
        venue: f.venue,
        halted: true,
      } as never),
    ).rejects.toThrow(/Could not find an Account to execute with this Action/)
    // A JSON-RPC sender (anvil's unlocked owner) on a node of another chain.
    await expect(
      Actions.venue.setHalted(f.client, {
        venue: f.venue,
        halted: true,
        account: f.accounts.owner.address,
        chain: tempoModerato,
      }),
    ).rejects.toThrow(/does not match the target chain for the transaction/)
  })
})

describe('reverts', () => {
  test("are viem's errors, named from the call's ABI, and Errors.decode reads them", async () => {
    const send = Actions.venue.setHaltedSync(f.client, {
      venue: f.venue,
      halted: true,
      account: f.accounts.stranger,
    })
    await expect(send).rejects.toThrowErrorMatchingInlineSnapshot(`
      [ContractFunctionExecutionError: The contract function "setHalted" reverted.

      Error: NotOwnerOrUpdater()
       
      Contract Call:
        address:   0x6A4377951fE7145358fD9BEEbF14052D5908CfdE
        function:  setHalted(bool halted_)
        args:               (true)
        sender:    0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65

      Docs: https://viem.sh/docs/contract/writeContract
      Details: execution reverted: custom error 0x7d60c902
      Version: viem@2.56.9]
    `)
    const error = await send.catch((e: unknown) => e)
    expect((error as Error).name).toBe('ContractFunctionExecutionError')
    expect(Errors.decode(error)?.errorName).toBe('NotOwnerOrUpdater')
    await expect(
      simulateContract(f.client, {
        ...Actions.venue.setHalted.call({
          venue: f.venue,
          halted: true,
        }),
        account: f.accounts.stranger.address,
      }),
    ).rejects.toThrow(/NotOwnerOrUpdater\(\)/)
    await expect(
      estimateContractGas(f.client, {
        ...Actions.venue.setHalted.call({ venue: f.venue, halted: true }),
        account: f.accounts.stranger,
      }),
    ).rejects.toThrow(/NotOwnerOrUpdater\(\)/)
  })
})
