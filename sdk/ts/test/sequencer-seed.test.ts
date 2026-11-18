import { createClient, custom, encodeAbiParameters, maxUint32 } from 'viem'
import { mainnet } from 'viem/chains'
import { expect, test } from 'vitest'
import { Errors, HotWord, Sequencer } from '../src/index.js'

const venue = '0x1111111111111111111111111111111111111111'

// A node with a fixed stored sequence: allocated posts have not landed yet.
function node(sequence: number) {
  const word = HotWord.fromFields({
    mid: 10n ** 18n,
    bidWiden: 0,
    askWiden: 0,
    widthScale: 1000,
    depthScale: 1000,
    shapeId: 0,
    validUntil: 1_800_000_000,
    sequence,
    flags: 0,
  })
  const result = encodeAbiParameters(
    [
      {
        type: 'tuple[]',
        components: [
          { name: 'success', type: 'bool' },
          { name: 'returnData', type: 'bytes' },
        ],
      },
    ],
    [[{ success: true, returnData: word }]],
  )
  return createClient({
    chain: mainnet,
    transport: custom({
      request: async ({ method }) => {
        if (method === 'eth_blockNumber') return '0xdbba01'
        if (method === 'eth_call') return result
        throw new Error(`unexpected request: ${method}`)
      },
    }),
  })
}

test('repeated restarts allocate above durable checkpoints even while stored sequence is unchanged', async () => {
  const client = node(2)
  let current = await Sequencer.seed(client, { venue, pairs: [0], gap: 16 })
  expect(Sequencer.next(current, 0)).toBe(19)
  // A fresh process without a checkpoint cannot discover the unmined sequence.
  const unsafe = await Sequencer.seed(client, { venue, pairs: [0], gap: 16 })
  expect(Sequencer.next(unsafe, 0)).toBe(19)
  for (const expected of [20, 21, 22]) {
    // JSON-compatible persistence, captured after allocation and before broadcast.
    const checkpoint = Object.fromEntries(current.last)
    current = await Sequencer.seed(client, {
      venue,
      pairs: [0],
      gap: 16,
      last: checkpoint,
    })
    expect(Sequencer.next(current, 0)).toBe(expected)
    Sequencer.observe(current, 0, 2)
    expect(Sequencer.last(current, 0)).toBe(expected)
  }
})

test('seed takes the higher of the chain plus gap and the checkpoint, without mutating it', async () => {
  const checkpoint = new Map([
    [0, 19],
    [5, 100],
  ])
  const resumed = await Sequencer.seed(node(30), {
    venue,
    pairs: [0],
    gap: 16,
    last: checkpoint,
  })
  expect(Sequencer.next(resumed, 0)).toBe(47)
  expect(Sequencer.last(resumed, 5)).toBe(100)
  Sequencer.observe(resumed, 5, 2)
  expect(Sequencer.next(resumed, 5)).toBe(101)
  const again = await Sequencer.seed(node(30), {
    venue,
    pairs: [0],
    last: Object.fromEntries(resumed.last),
  })
  expect(Sequencer.next(again, 5)).toBe(102)
  expect([...checkpoint]).toEqual([
    [0, 19],
    [5, 100],
  ])
  const newlyAdded = await Sequencer.seed(node(2), {
    venue,
    pairs: [0],
    last: { 5: 100 },
  })
  expect(Sequencer.next(newlyAdded, 0)).toBe(3)
})

test('a restored exhausted counter never wraps and overflowed seeds still fail', async () => {
  const resumed = await Sequencer.seed(node(2), {
    venue,
    pairs: [0],
    gap: 16,
    last: { 0: Number(maxUint32) },
  })
  expect(() => Sequencer.next(resumed, 0)).toThrow(
    Errors.SequenceExhaustedError,
  )
  expect(Sequencer.last(resumed, 0)).toBe(Number(maxUint32))
  const almostExhausted = await Sequencer.seed(node(2), {
    venue,
    pairs: [0],
    last: { 0: Number(maxUint32) - 1 },
  })
  expect(Sequencer.next(almostExhausted, 0)).toBe(Number(maxUint32))
  expect(() => Sequencer.next(almostExhausted, 0)).toThrow(
    Errors.SequenceExhaustedError,
  )
  await expect(
    Sequencer.seed(node(Number(maxUint32)), {
      venue,
      pairs: [0],
      gap: 1,
      last: { 0: 19 },
    }),
  ).rejects.toThrow(Errors.SequenceExhaustedError)
  await expect(
    Sequencer.seed(node(2), {
      venue,
      pairs: [0],
      last: { 0: Number(maxUint32) + 1 },
    }),
  ).rejects.toThrow(Errors.InvalidArgumentError)
})

test('unrequested exhausted checkpoint floors survive reseeding', async () => {
  const resumed = await Sequencer.seed(node(2), {
    venue,
    pairs: [0],
    last: { 5: Number(maxUint32) },
  })
  Sequencer.observe(resumed, 5, 2)
  expect(() => Sequencer.next(resumed, 5)).toThrow(
    Errors.SequenceExhaustedError,
  )
  expect(Sequencer.last(resumed, 5)).toBe(Number(maxUint32))
})
