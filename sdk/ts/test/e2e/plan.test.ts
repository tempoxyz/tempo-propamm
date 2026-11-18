// Plan.simulate against anvil's 0x76 batches: a step is atomic as its batch is (a failed call undoes the step and runs
// none after it, and no later step sees it), typed calls decode, events come per call, and the fee fields reach the
// venue's cap. The reverted batch is sent for real too, to hold the simulation to the chain.
import {
  type Address,
  encodeFunctionData,
  type Hex,
  keccak256,
  toHex,
} from 'viem'
import { getBlock, readContract, sendTransactionSync } from 'viem/actions'
import { Abis as TempoAbis } from 'viem/tempo'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import {
  Abis,
  Actions,
  Fees,
  Plan,
  PostOutcome,
  Price,
  Sequencer,
  Venue,
} from '../../src/index.js'
import { type Fixture, type PairSetup, setupPair, start } from './fixture.js'

let f: Fixture
let p: PairSetup

beforeAll(async () => {
  f = await start()
  p = await setupPair(f)
})
afterAll(async () => f?.stop())

/** A typed call of a venue view, for a step to read state with: its result decodes. */
const view = (
  functionName: 'hotWord' | 'halted' | 'pairCount',
  args: readonly unknown[] = [],
): Plan.Call => ({
  to: f.venue,
  data: encodeFunctionData({ abi: Abis.venueAbi, functionName, args } as never),
  abi: Abis.venueAbi,
  functionName,
  args,
})

const hotWord = () =>
  readContract(f.client, {
    address: f.venue,
    abi: Abis.venueAbi,
    functionName: 'hotWord',
    args: [p.pairIndex],
  })

/** A taker's 0x76 swap of 1 BetaUSD for AlphaUSD through the Settler, as one step with `fees`. */
const swapStep = (fees: Partial<Plan.Step> = {}): Plan.Step => {
  const settler = f.core.settler
  const amountIn = 1_000_000n
  return {
    account: f.accounts.taker,
    calls: [
      {
        to: f.quote,
        data: encodeFunctionData({
          abi: TempoAbis.tip20,
          functionName: 'approve',
          args: [settler, amountIn],
        }),
      },
      {
        to: settler,
        data: encodeFunctionData({
          abi: Abis.settlerAbi,
          functionName: 'swapExactIn',
          args: [
            f.venue,
            p.pairIndex,
            f.quote,
            f.base,
            amountIn,
            1n,
            0n,
            2 ** 40 - 1,
            keccak256(toHex('plan swap')),
          ],
        }),
      },
    ],
    ...fees,
  }
}

/** A step's statuses and its failure, for an inline snapshot. */
const summary = (r: Plan.StepResult) => ({
  status: r.status,
  calls: r.calls.map((c) => c.status),
  ...(r.status === 'failure'
    ? { failedCall: r.failedCall, error: r.error?.errorName }
    : {}),
})

describe('Plan.simulate', () => {
  test("simulates a step as one atomic batch: the second of three calls reverts, and a later step never sees the first's effect", async () => {
    const { agent, stranger } = f.accounts
    const before = await hotWord()
    const order = Actions.maker.order.call({
      venue: f.venue,
      order: {
        pairIndex: p.pairIndex,
        mid: Price.parse('1.2'),
        shapeId: 7,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        validUntil: p.validUntil,
      },
    })
    // The agent may post and halt, but only the owner adds a pair.
    const batch = [
      order,
      Actions.venue.addPair.call({
        venue: f.venue,
        base: f.base,
        quote: f.quote,
        sizeUnit: 1n,
      }),
      Actions.venue.setHalted.call({ venue: f.venue, halted: true }),
    ]
    const [step, later] = await Plan.simulate(f.client, {
      steps: [
        { account: agent, calls: batch },
        {
          account: stranger.address,
          calls: [view('hotWord', [p.pairIndex]), view('halted')],
        },
      ],
    })
    assert(step && later)
    expect([summary(step), summary(later)]).toMatchInlineSnapshot(`
      [
        {
          "calls": [
            "rolledBack",
            "failure",
            "notRun",
          ],
          "error": "NotOwner",
          "failedCall": 1,
          "status": "failure",
        },
        {
          "calls": [
            "success",
            "success",
          ],
          "status": "success",
        },
      ]
    `)
    const [first] = step.calls
    assert(first?.status === 'rolledBack')
    expect(first.gasUsed > 0n, 'the first call ran').toBeTruthy()
    assert(later.status === 'success')
    expect(
      later.calls.map((c) => (c.status === 'success' ? c.result : c.status)),
      'the later step sees the hot word before the batch, and no halt',
    ).toStrictEqual([before, false])

    // The chain agrees: the same batch, sent, reverts as a whole.
    const receipt = await sendTransactionSync(f.client, {
      account: agent,
      calls: batch.map(({ to, data }) => ({ to, data })),
      // A batch that reverts can't be estimated: give it gas.
      gas: 5_000_000n,
      chain: f.client.chain,
    } as never)
    expect(receipt.status).toBe('reverted')
    expect(await hotWord()).toBe(before)
    expect(
      await readContract(f.client, {
        address: f.venue,
        abi: Abis.venueAbi,
        functionName: 'halted',
      }),
    ).toBe(false)
    expect(PostOutcome.fromBatchReceipt([order], receipt)).toStrictEqual({
      status: 'reverted',
    })
  })

  test('decodes typed results and per-call events, and carries state from step to step', async () => {
    const { owner, stranger } = f.accounts
    const count = await readContract(f.client, {
      address: f.venue,
      abi: Abis.venueAbi,
      functionName: 'pairCount',
    })
    const [add, read] = await Plan.simulate(f.client, {
      steps: [
        {
          account: owner,
          calls: [
            Actions.venue.addPair.call({
              venue: f.venue,
              base: f.quote,
              quote: f.base,
              sizeUnit: 1n,
            }),
            Actions.venue.setPairAccess.call({
              venue: f.venue,
              pairIndex: count,
              mode: 'listed',
            }),
          ],
        },
        { account: stranger.address, calls: [view('pairCount')] },
      ],
    })
    assert(add?.status === 'success' && read?.status === 'success')
    const [added, access] = add.calls
    assert(added?.status === 'success' && access?.status === 'success')
    expect(added.result, "addPair's own return value").toBe(count)
    expect(added.events.map((e) => e.eventName)).toStrictEqual(['PairAdded'])
    expect(access.events.map((e) => e.eventName)).toStrictEqual([
      'PairAccessUpdated',
    ])
    const [counted] = read.calls
    assert(counted?.status === 'success')
    expect(counted.result).toBe(count + 1)
    expect(add.gasUsed).toBe(added.gasUsed + access.gasUsed)
    // Nothing was sent.
    expect(
      await readContract(f.client, {
        address: f.venue,
        abi: Abis.venueAbi,
        functionName: 'pairCount',
      }),
    ).toBe(count)
  })

  test("requires a taker's submitted fee fields to make a capped simulation match the venue", async () => {
    const { agent } = f.accounts
    await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
      venue: f.venue,
      cap: Fees.gwei,
      account: agent,
    })
    const { baseFeePerGas } = await getBlock(f.client)
    assert(baseFeePerGas !== null)
    const allowed = Fees.takerFields(baseFeePerGas, Fees.gwei, Fees.gwei)
    const results = await Plan.simulate(f.client, {
      steps: [
        swapStep(),
        swapStep(allowed),
        swapStep(Fees.feeFields(baseFeePerGas, 2n * Fees.gwei)),
      ],
    })
    expect(results.map(summary)).toMatchInlineSnapshot(`
      [
        {
          "calls": [
            "success",
            "success",
          ],
          "status": "success",
        },
        {
          "calls": [
            "success",
            "success",
          ],
          "status": "success",
        },
        {
          "calls": [
            "rolledBack",
            "failure",
          ],
          "error": "TakerPriorityFeeTooHigh",
          "failedCall": 1,
          "status": "failure",
        },
      ]
    `)
    const over = results[2]
    assert(over?.status === 'failure')
    expect(over.error?.args).toStrictEqual([2n * Fees.gwei, Fees.gwei])
    // The allowed fields work on the submitted batch too.
    const accepted = swapStep(allowed)
    const acceptedReceipt = await sendTransactionSync(f.client, {
      account: f.accounts.taker,
      calls: accepted.calls.map(({ to, data }) => ({ to, data })),
      maxFeePerGas: accepted.maxFeePerGas,
      maxPriorityFeePerGas: accepted.maxPriorityFeePerGas,
      chain: f.client.chain,
    } as never)
    expect(acceptedReceipt.status).toBe('success')
    // The same explicit fields that expose the cap in simulation also reject the submitted batch.
    const submitted = swapStep(Fees.feeFields(baseFeePerGas, 2n * Fees.gwei))
    const receipt = await sendTransactionSync(f.client, {
      account: f.accounts.taker,
      calls: submitted.calls.map(({ to, data }) => ({ to, data })),
      maxFeePerGas: submitted.maxFeePerGas,
      maxPriorityFeePerGas: submitted.maxPriorityFeePerGas,
      // A batch that reverts cannot be estimated.
      gas: 5_000_000n,
      chain: f.client.chain,
    } as never)
    expect(receipt.status).toBe('reverted')
    await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
      venue: f.venue,
      cap: Venue.noPriorityFeeCap,
      account: agent,
    })
  })

  test('simulates at a pinned block, with a state override before the first step', async () => {
    const { stranger } = f.accounts
    const blockNumber = await f.client.request({ method: 'eth_blockNumber' })
    const [read] = await Plan.simulate(f.client, {
      steps: [{ account: stranger.address, calls: [view('halted')] }],
      blockNumber: BigInt(blockNumber),
    })
    assert(read?.status === 'success')
    expect(read.calls[0]?.status === 'success' && read.calls[0].result).toBe(
      false,
    )
    // Overriding the venue's code with a bare REVERT fails the read: the override applies.
    const [overridden] = await Plan.simulate(f.client, {
      steps: [{ account: stranger.address, calls: [view('halted')] }],
      stateOverride: [{ address: f.venue, code: '0x5f5ffd' as Hex }],
    })
    expect(overridden && summary(overridden)).toMatchInlineSnapshot(`
      {
        "calls": [
          "failure",
        ],
        "error": null,
        "failedCall": 0,
        "status": "failure",
      }
    `)
  })
})

describe("Plan.simulate's blocks", () => {
  test("runs each step one second after the block before, at the base block's base fee, under any overrides given", async () => {
    const { agent } = f.accounts
    const base = await getBlock(f.client)
    // A quote live for ten more seconds: eth_simulateV1's default 12 seconds a block would expire it.
    const validUntil = Number(base.timestamp) + 10
    await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        pairIndex: p.pairIndex,
        mid: Price.parse('1.085'),
        shapeId: 7,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        validUntil,
      },
      account: agent,
    })
    const [live, again] = await Plan.simulate(f.client, {
      steps: [swapStep(), swapStep()],
    })
    expect([live?.status, again?.status]).toStrictEqual(['success', 'success'])
    // Given a time past the quote, the swap fails as it would then.
    const [expired] = await Plan.simulate(f.client, {
      steps: [swapStep()],
      blockOverrides: { time: BigInt(validUntil) + 1n },
    })
    assert(expired?.status === 'failure')
    expect([expired.error?.errorName, expired.error?.args]).toStrictEqual([
      'QuoteExpired',
      [validUntil],
    ])

    // The base fee: a transaction whose maxFeePerGas leaves it 1 gwei of its 2 gwei tip pays 1 gwei above the base
    // fee, so it passes a 1 gwei cap; at base fee 0 it would pay its whole 2 gwei tip and fail.
    await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
      venue: f.venue,
      cap: Fees.gwei,
      account: agent,
    })
    // Anvil moves the base fee from block to block: pin the base block, and pay against its base fee.
    const at = await getBlock(f.client)
    const baseFee = at.baseFeePerGas
    assert(baseFee !== null && baseFee > Fees.gwei)
    const [capped, over] = await Plan.simulate(f.client, {
      blockNumber: at.number,
      steps: [
        swapStep({
          maxFeePerGas: baseFee + Fees.gwei,
          maxPriorityFeePerGas: 2n * Fees.gwei,
        }),
        swapStep({
          maxFeePerGas: baseFee + 2n * Fees.gwei,
          maxPriorityFeePerGas: 2n * Fees.gwei,
        }),
      ],
    })
    expect(capped?.status).toBe('success')
    assert(over?.status === 'failure')
    expect([over.error?.errorName, over.error?.args]).toStrictEqual([
      'TakerPriorityFeeTooHigh',
      [2n * Fees.gwei, Fees.gwei],
    ])
    await Actions.venue.setMaxTakerPriorityFeeSync(f.client, {
      venue: f.venue,
      cap: Venue.noPriorityFeeCap,
      account: agent,
    })
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
    })
  })

  test('keeps a state change from before a failed step, and survives two failed steps', async () => {
    const { owner, agent, stranger } = f.accounts
    const count = await readContract(f.client, {
      address: f.venue,
      abi: Abis.venueAbi,
      functionName: 'pairCount',
    })
    const addPair = Actions.venue.addPair.call({
      venue: f.venue,
      base: f.quote,
      quote: f.base,
      sizeUnit: 1n,
    })
    const read = { account: stranger.address, calls: [view('pairCount')] }
    const results = await Plan.simulate(f.client, {
      steps: [
        { account: owner, calls: [addPair] },
        {
          account: stranger,
          calls: [
            Actions.venue.setHalted.call({ venue: f.venue, halted: true }),
          ],
        },
        read,
        { account: agent, calls: [addPair] },
        read,
      ],
    })
    expect(results.map(summary)).toMatchInlineSnapshot(`
      [
        {
          "calls": [
            "success",
          ],
          "status": "success",
        },
        {
          "calls": [
            "failure",
          ],
          "error": "NotOwnerOrUpdater",
          "failedCall": 0,
          "status": "failure",
        },
        {
          "calls": [
            "success",
          ],
          "status": "success",
        },
        {
          "calls": [
            "failure",
          ],
          "error": "NotOwner",
          "failedCall": 0,
          "status": "failure",
        },
        {
          "calls": [
            "success",
          ],
          "status": "success",
        },
      ]
    `)
    // Both reads see the owner's pair, and neither failed step's effect.
    expect(
      [results[2], results[4]].map((r) =>
        r?.status === 'success' && r.calls[0]?.status === 'success'
          ? r.calls[0].result
          : r?.status,
      ),
    ).toStrictEqual([count + 1, count + 1])
  })
})

describe('Plan.estimateGas', () => {
  test('estimates a batch as one transaction, and its limit is 130% of it', async () => {
    const { owner } = f.accounts
    const halt = (halted: boolean) =>
      Actions.venue.setHalted.call({ venue: f.venue, halted })
    const one = await Plan.estimateGas(f.client, {
      account: owner,
      calls: [halt(true)],
    })
    const two = await Plan.estimateGas(f.client, {
      account: owner.address as Address,
      calls: [halt(true), halt(false)],
    })
    // Halting writes a zero slot (Tempo's state creation, about 250k); halting and unhalting in one batch nets none.
    expect(one > 250_000n && two > 21_000n && two < one).toBeTruthy()
    expect(Plan.gasLimit(two)).toBe((two * 130n + 99n) / 100n)
  })
})
