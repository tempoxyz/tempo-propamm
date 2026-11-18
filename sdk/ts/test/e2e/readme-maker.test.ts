// Execute the README's maker flow, not a handwritten copy, against the local Tempo fixture.
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { createClient, http } from 'viem'
import { getLogs } from 'viem/actions'
import { afterAll, assert, beforeAll, expect, test } from 'vitest'
import {
  Actions,
  Events,
  HotWord,
  Info,
  PostOutcome,
  Price,
  Sequencer,
  Shape,
} from '../../src/index.js'
import { type Fixture, mined, start } from './fixture.js'

let f: Fixture
beforeAll(async () => {
  f = await start()
  mined(
    await Actions.venue.addPairSync(f.client, {
      venue: f.venue,
      base: f.base,
      quote: f.quote,
      sizeUnit: 1_000_000n,
      account: f.accounts.owner,
    }),
  )
})
afterAll(async () => f?.stop())

test('README maker requotes, switches shapes and cancels at the latest mid, refilling only once', async () => {
  const readme = readFileSync(
    new URL('../../README.md', import.meta.url),
    'utf8',
  )
  const example = /## Maker\n+```ts\n([\s\S]*?)\n```/.exec(readme)?.[1]
  assert(example, 'the README must have its executable maker example')
  // Supply the real SDK imports, local client and deployed venue instead of the example's placeholders.
  // Leave every statement of the maker flow unchanged, including its sequencing and one-shot refill.
  const body = example
    .replace(/^import .*\n/gm, '')
    .replace(/^const (?:client|venue) = .*\n/gm, '')
  const client = createClient({
    account: f.accounts.owner,
    chain: f.client.chain,
    transport: http(f.rpc),
    pollingInterval: 50,
  })
  await runInNewContext(`(async () => {\n${body}\n})()`, {
    Actions,
    PostOutcome,
    Price,
    Sequencer,
    Shape,
    client,
    venue: f.venue,
    console,
  })

  const logs = await getLogs(f.client, {
    address: f.venue,
    fromBlock: 0n,
    toBlock: 'latest',
  })
  const posts = Events.venue(logs, {
    venue: f.venue,
    eventName: 'Posted',
  }).map(({ args }) => HotWord.decode(args.hotWord))
  expect(posts.map((p) => p.sequence)).toStrictEqual([2, 3, 4, 5, 6])
  expect(posts.map((p) => Price.format(p.mid))).toStrictEqual([
    '1.085',
    '1.086',
    '1.086',
    '1.086',
    '1.086',
  ])
  expect(posts.slice(0, 3).map((p) => p.shapeId)).toStrictEqual([7, 7, 8])
  expect(posts.map((p) => p.sides)).toStrictEqual([
    'both',
    'both',
    'both',
    'neither',
    'neither',
  ])
  expect(
    Events.venue(logs, { venue: f.venue, eventName: 'Refilled' }).map(
      ({ args }) => args,
    ),
  ).toStrictEqual([{ pairIndex: 0, bids: false, asks: true }])
  expect((await Info.venueState(f.client, { venue: f.venue })).halted).toBe(
    true,
  )
})
