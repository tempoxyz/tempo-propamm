// `Events` over real encoded logs: each built with viem's `encodeEventTopics` and `encodeAbiParameters` from the
// generated ABIs, as a node would return them.
import {
  type Abi,
  type Address,
  type ContractEventName,
  encodeAbiParameters,
  encodeEventTopics,
  type Hex,
  type Log,
} from 'viem'
import { Abis as TempoAbis } from 'viem/tempo'
import { describe, expect, test } from 'vitest'
import { Abis, Actions, Errors, Events, HotWord } from '../src/index.js'

const VENUE: Address = '0x1111111111111111111111111111111111111111'
const OTHER_VENUE: Address = '0x2222222222222222222222222222222222222222'
const TOKEN: Address = '0x20c0000000000000000000000000000000000001'
const A: Address = '0x00000000000000000000000000000000000000a1'
const B: Address = '0x00000000000000000000000000000000000000b2'

/** A log of `eventName` from `address`, as `eth_getLogs` returns one. */
function log<const abi extends Abi>(
  abi: abi,
  address: Address,
  eventName: ContractEventName<abi>,
  args: Record<string, unknown>,
  logIndex = 0,
): Log {
  const item = abi.find(
    (i) => i.type === 'event' && i.name === eventName,
  ) as Extract<Abi[number], { type: 'event' }>
  const data = item.inputs.filter((i) => !i.indexed)
  return {
    address,
    topics: encodeEventTopics({
      abi: [item],
      eventName,
      args,
    } as never) as [Hex, ...Hex[]],
    data: encodeAbiParameters(
      data,
      data.map((i) => args[i.name as string]),
    ),
    blockHash: `0x${'bb'.repeat(32)}`,
    blockNumber: 7n,
    logIndex,
    transactionHash: `0x${'cc'.repeat(32)}`,
    transactionIndex: 0,
    removed: false,
  }
}

const posted = log(Abis.venueAbi, VENUE, 'Posted', {
  pairIndex: 3,
  hotWord: HotWord.initial,
})
const halted = log(Abis.venueAbi, VENUE, 'HaltedSet', { halted: true }, 1)
const transfer = log(
  TempoAbis.tip20,
  TOKEN,
  'Transfer',
  { from: A, to: VENUE, amount: 5n },
  2,
)
const handover = log(
  Abis.venueAbi,
  OTHER_VENUE,
  'OwnershipTransferStarted',
  { owner: A, pendingOwner: B },
  3,
)
const logs = [posted, halted, transfer, handover]

const summary = (events: readonly Events.Event[]) =>
  events.map(({ address, eventName, args }) => ({ address, eventName, args }))

describe('Events.parse', () => {
  test('decodes every SDK event, typed by name, with its emitter checksummed and its log', () => {
    const events = Events.parse(logs)
    expect(summary(events)).toMatchInlineSnapshot(`
      [
        {
          "address": "0x1111111111111111111111111111111111111111",
          "args": {
            "hotWord": "0x0000000000010000000000000000000000000000000000000000000000000000",
            "pairIndex": 3,
          },
          "eventName": "Posted",
        },
        {
          "address": "0x1111111111111111111111111111111111111111",
          "args": {
            "halted": true,
          },
          "eventName": "HaltedSet",
        },
        {
          "address": "0x20C0000000000000000000000000000000000001",
          "args": {
            "amount": 5n,
            "from": "0x00000000000000000000000000000000000000A1",
            "to": "0x1111111111111111111111111111111111111111",
          },
          "eventName": "Transfer",
        },
        {
          "address": "0x2222222222222222222222222222222222222222",
          "args": {
            "owner": "0x00000000000000000000000000000000000000A1",
            "pendingOwner": "0x00000000000000000000000000000000000000b2",
          },
          "eventName": "OwnershipTransferStarted",
        },
      ]
    `)
    expect(events[2]?.log.logIndex).toBe(2)
    const [first] = events
    if (first?.eventName === 'Posted') expect(first.args.pairIndex).toBe(3)
    else expect.unreachable('the first log is a Posted')
  })

  test('keeps only the emitter and the names asked for', () => {
    expect(
      Events.parse(logs, { address: TOKEN }).map((e) => e.eventName),
    ).toStrictEqual(['Transfer'])
    expect(
      Events.parse(logs, { eventName: ['HaltedSet', 'Transfer'] }).map(
        (e) => e.eventName,
      ),
    ).toStrictEqual(['HaltedSet', 'Transfer'])
    expect(
      Events.parse(logs, { address: VENUE, eventName: 'Transfer' }),
    ).toStrictEqual([])
  })

  test('skips logs no SDK contract emits', () => {
    const unknown = { ...posted, topics: [`0x${'ee'.repeat(32)}`] } as Log
    expect(Events.parse([unknown, halted]).map((e) => e.eventName)).toEqual([
      'HaltedSet',
    ])
  })

  test('refuses what is not logs, an unknown event name or a bad address', () => {
    expect(() =>
      Events.parse('0x' as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: logs must be an array of logs

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Events.parse([null] as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: logs[0] is not a log

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Events.parse(logs, { eventName: 'Posed' as never }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: no SDK event is named "Posed"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Events.parse(logs, { address: '0xnope' }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: address is not an address: "0xnope"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Events.parse([{ ...posted, address: '0x12' as Address }]),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: logs[0].address is not an address: "0x12"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})

describe('Events.venue', () => {
  test("decodes only the venue's own events", () => {
    expect(
      summary(Events.venue(logs, { venue: VENUE, eventName: 'HaltedSet' })),
    ).toMatchInlineSnapshot(`
      [
        {
          "address": "0x1111111111111111111111111111111111111111",
          "args": {
            "halted": true,
          },
          "eventName": "HaltedSet",
        },
      ]
    `)
    expect(
      Events.venue(logs, { venue: VENUE }).map((e) => e.eventName),
    ).toStrictEqual(['Posted', 'HaltedSet'])
    expect(() =>
      Events.venue(logs, { venue: VENUE, eventName: 'Transfer' as never }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: no venue event is named "Transfer"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})

describe("an action's extractEvent and extractEvents", () => {
  const OTHER: Address = '0x3333333333333333333333333333333333333333'
  const word = (n: number) => `0x${n.toString(16).padStart(64, '0')}` as Hex
  // A two-venue batch: each venue's Posted, in log order.
  const batch = [
    log(Abis.venueAbi, OTHER, 'Posted', { pairIndex: 0, hotWord: word(1) }, 0),
    log(Abis.venueAbi, VENUE, 'Posted', { pairIndex: 0, hotWord: word(2) }, 1),
    log(Abis.venueAbi, OTHER, 'Posted', { pairIndex: 1, hotWord: word(3) }, 2),
  ]
  // A token whose transfer emits a log that decodes as the venue's `Withdrawn`, before the venue's own.
  const withdrawn = (address: Address, amount: bigint, logIndex: number) =>
    log(
      Abis.venueAbi,
      address,
      'Withdrawn',
      { token: TOKEN, to: A, amount, memo: `0x${'00'.repeat(32)}` },
      logIndex,
    )
  const withdrawal = [withdrawn(TOKEN, 1_000_000n, 0), withdrawn(VENUE, 5n, 1)]

  test("keep only the given address's logs, and every match without one", () => {
    const words = (events: { args: { hotWord: Hex } }[]) =>
      events.map((e) => e.args.hotWord)
    expect(
      words(Actions.maker.bulkOrders.extractEvents(batch, { address: VENUE })),
    ).toStrictEqual([word(2)])
    expect(
      words(Actions.venue.post.extractEvents(batch, { address: OTHER })),
    ).toStrictEqual([word(1), word(3)])
    expect(words(Actions.maker.order.extractEvents(batch))).toStrictEqual([
      word(1),
      word(2),
      word(3),
    ])
    // A checksummed or lowercase address matches either way.
    expect(
      Actions.maker.cancel.extractEvents(batch, {
        address: VENUE.toUpperCase().replace('0X', '0x') as Address,
      }),
    ).toHaveLength(1)
  })

  test("skip a token's look-alike event for the venue's own", () => {
    expect(
      Actions.venue.withdraw.extractEvent(withdrawal, { address: VENUE }).args
        .amount,
    ).toBe(5n)
    // Without an address, the first match: the token's.
    expect(Actions.venue.withdraw.extractEvent(withdrawal).args.amount).toBe(
      1_000_000n,
    )
    expect(() =>
      Actions.venue.withdraw.extractEvent(withdrawal, { address: OTHER }),
    ).toThrowErrorMatchingInlineSnapshot(
      `
      [InvalidArgumentError: the logs hold no \`Withdrawn\` event from 0x3333333333333333333333333333333333333333

      Version: @tempoxyz/propamm-sdk@<version>]
    `,
    )
    expect(() =>
      Actions.venue.withdraw.extractEvent(withdrawal, { address: '0x1234' }),
    ).toThrow(Errors.InvalidAddressError)
  })
})
