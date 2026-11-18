// Every write's call, in wevm style: an inline snapshot of what each prepares (its target, function, arguments, signer
// and post entries); its calldata against an independent encoding of the contract signature (viem's
// `encodeFunctionData` over the human-readable signature, not the generated ABI) with hand-written arguments and
// selector; its ABI, its own function and the errors it can revert with; its refusals, as inline snapshots of the
// errors; and its event, extracted from a real encoded log. The e2e suites send every one.
import {
  type Abi,
  type AbiFunction,
  type Address,
  type ContractEventName,
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionData,
  getAddress,
  type Hex,
  type Log,
  parseAbiItem,
  toFunctionSelector,
} from 'viem'
import { describe, expect, test } from 'vitest'
import {
  Abis,
  Actions,
  Errors,
  HotWord,
  Post,
  type PreparedCall,
  Price,
  Shape,
  type SignerRole,
  Venue,
} from '../src/index.js'

const VENUE: Address = '0x1111111111111111111111111111111111111111'
const A: Address = '0x00000000000000000000000000000000000000a1'
const B: Address = '0x00000000000000000000000000000000000000b2'
const C: Address = '0x00000000000000000000000000000000000000c3'
const OTHER: Address = '0x2222222222222222222222222222222222222222'
const SALT: Hex = `0x${'5a'.repeat(32)}`
const MEMO: Hex = `0x${'4d'.repeat(32)}`
const SHAPE = Shape.from({
  bids: [{ size: 50_000, spread: 20 }],
  asks: [
    { size: 50_000, spread: 20 },
    { size: 9, spread: 21 },
  ],
})
const ORDER = {
  pairIndex: 3,
  mid: Price.parse('1.085'),
  shapeId: 7,
  sequence: 9,
  validUntil: 1_800_000_060,
  refill: 'asks' as const,
}
const ORDER_WORD = Post.order(ORDER).word
const CANCEL_WORD = Post.cancel({
  pairIndex: 4,
  sequence: 10,
  mid: Price.one,
}).word

const owner: SignerRole = { role: 'owner' }
const either: SignerRole = { role: 'ownerOrAgent' }

type Case = {
  name: string
  call: PreparedCall
  signature: string
  selector: Hex
  args: readonly unknown[]
  signer: SignerRole
}

const cases: Case[] = [
  {
    name: 'resetHotWord',
    call: Actions.venue.resetHotWord.call({ venue: VENUE, pairIndex: 5 }),
    signature: 'resetHotWord(uint16)',
    selector: '0xd8df23cc',
    args: [5],
    signer: owner,
  },
  {
    name: 'addPair',
    call: Actions.venue.addPair.call({
      venue: VENUE,
      base: A,
      quote: B,
      sizeUnit: 1_000_000n,
    }),
    signature: 'addPair(address,address,uint64)',
    selector: '0x3c502500',
    args: [A, B, 1_000_000n],
    signer: owner,
  },
  {
    name: 'removePair',
    call: Actions.venue.removePair.call({ venue: VENUE, pairIndex: 5 }),
    signature: 'removePair(uint16)',
    selector: '0x389275b7',
    args: [5],
    signer: owner,
  },
  {
    name: 'setPairAccess',
    call: Actions.venue.setPairAccess.call({
      venue: VENUE,
      pairIndex: 2,
      mode: 'open',
    }),
    signature: 'setPairAccess(uint16,uint8)',
    selector: '0x17aa2ce6',
    args: [2, 3],
    signer: owner,
  },
  {
    name: 'closePair',
    call: Actions.venue.closePair.call({ venue: VENUE, pairIndex: 2 }),
    signature: 'closePair(uint16)',
    selector: '0x456e8f99',
    args: [2],
    signer: either,
  },
  {
    name: 'addSponsor',
    call: Actions.venue.addSponsor.call({
      venue: VENUE,
      sponsorId: 42n,
      admin: A,
    }),
    signature: 'addSponsor(uint64,address)',
    selector: '0x69bd536a',
    args: [42n, A],
    signer: owner,
  },
  {
    name: 'setSponsorEnabled on',
    call: Actions.venue.setSponsorEnabled.call({
      venue: VENUE,
      sponsorId: 42n,
      enabled: true,
    }),
    signature: 'setSponsorEnabled(uint64,bool)',
    selector: '0xaececd15',
    args: [42n, true],
    signer: owner,
  },
  {
    name: 'setSponsorEnabled off',
    call: Actions.venue.setSponsorEnabled.call({
      venue: VENUE,
      sponsorId: 42n,
      enabled: false,
    }),
    signature: 'setSponsorEnabled(uint64,bool)',
    selector: '0xaececd15',
    args: [42n, false],
    signer: either,
  },
  {
    name: 'setPairSponsor admit',
    call: Actions.venue.setPairSponsor.call({
      venue: VENUE,
      pairIndex: 1,
      sponsorId: 42n,
      admitted: true,
    }),
    signature: 'setPairSponsor(uint16,uint64,bool)',
    selector: '0x876cd1e0',
    args: [1, 42n, true],
    signer: owner,
  },
  {
    name: 'setPairSponsor remove',
    call: Actions.venue.setPairSponsor.call({
      venue: VENUE,
      pairIndex: 1,
      sponsorId: 42n,
      admitted: false,
    }),
    signature: 'setPairSponsor(uint16,uint64,bool)',
    selector: '0x876cd1e0',
    args: [1, 42n, false],
    signer: either,
  },
  {
    name: 'setMembers home',
    call: Actions.venue.setMembers.call({
      venue: VENUE,
      pairIndex: 1,
      sponsorId: 0n,
      accounts: [A, B],
      allowed: true,
    }),
    signature: 'setMembers(uint16,uint64,address[],bool)',
    selector: '0x3c5c7afa',
    args: [1, 0n, [A, B], true],
    signer: owner,
  },
  {
    name: 'setMembers sponsor',
    call: Actions.venue.setMembers.call({
      venue: VENUE,
      pairIndex: 1,
      sponsorId: 42n,
      accounts: [C],
      allowed: false,
    }),
    signature: 'setMembers(uint16,uint64,address[],bool)',
    selector: '0x3c5c7afa',
    args: [1, 42n, [C], false],
    signer: { role: 'sponsorAdmin', sponsorId: 42n },
  },
  {
    name: 'transferSponsorAdmin',
    call: Actions.venue.transferSponsorAdmin.call({
      venue: VENUE,
      sponsorId: 42n,
      newAdmin: B,
    }),
    signature: 'transferSponsorAdmin(uint64,address)',
    selector: '0xb2d90fd4',
    args: [42n, B],
    signer: { role: 'sponsorAdmin', sponsorId: 42n },
  },
  {
    name: 'cancelSponsorAdminTransfer',
    call: Actions.venue.cancelSponsorAdminTransfer.call({
      venue: VENUE,
      sponsorId: 42n,
    }),
    signature: 'cancelSponsorAdminTransfer(uint64)',
    selector: '0x3b0642c0',
    args: [42n],
    signer: { role: 'sponsorAdmin', sponsorId: 42n },
  },
  {
    name: 'acceptSponsorAdmin',
    call: Actions.venue.acceptSponsorAdmin.call({
      venue: VENUE,
      sponsorId: 42n,
    }),
    signature: 'acceptSponsorAdmin(uint64)',
    selector: '0xf7fb45ee',
    args: [42n],
    signer: { role: 'pendingSponsorAdmin', sponsorId: 42n },
  },
  {
    name: 'resetSponsor',
    call: Actions.venue.resetSponsor.call({
      venue: VENUE,
      sponsorId: 42n,
      newAdmin: C,
    }),
    signature: 'resetSponsor(uint64,address)',
    selector: '0x27585352',
    args: [42n, C],
    signer: owner,
  },
  {
    name: 'setDenied deny',
    call: Actions.venue.setDenied.call({
      venue: VENUE,
      accounts: [A],
      deny: true,
    }),
    signature: 'setDenied(address[],bool)',
    selector: '0x1bc05463',
    args: [[A], true],
    signer: either,
  },
  {
    name: 'setDenied lift',
    call: Actions.venue.setDenied.call({
      venue: VENUE,
      accounts: [A],
      deny: false,
    }),
    signature: 'setDenied(address[],bool)',
    selector: '0x1bc05463',
    args: [[A], false],
    signer: owner,
  },
  {
    name: 'setPairHook',
    call: Actions.venue.setPairHook.call({
      venue: VENUE,
      pairIndex: 1,
      hook: C,
      flags: 7,
    }),
    signature: 'setPairHook(uint16,address,uint8)',
    selector: '0x1cf43536',
    args: [1, C, 7],
    signer: owner,
  },
  {
    name: 'approveAgent',
    call: Actions.venue.approveAgent.call({ venue: VENUE, agent: A }),
    signature: 'setUpdater(address,bool)',
    selector: '0x1a153391',
    args: [A, true],
    signer: owner,
  },
  {
    name: 'revokeAgent',
    call: Actions.venue.revokeAgent.call({ venue: VENUE, agent: A }),
    signature: 'setUpdater(address,bool)',
    selector: '0x1a153391',
    args: [A, false],
    signer: owner,
  },
  {
    name: 'setSettler',
    call: Actions.venue.setSettler.call({ venue: VENUE, settler: B }),
    signature: 'setSettler(address)',
    selector: '0x07f19eba',
    args: [B],
    signer: owner,
  },
  {
    name: 'setHalted halt',
    call: Actions.venue.setHalted.call({ venue: VENUE, halted: true }),
    signature: 'setHalted(bool)',
    selector: '0xdcc279c8',
    args: [true],
    signer: either,
  },
  {
    name: 'setHalted resume',
    call: Actions.venue.setHalted.call({ venue: VENUE, halted: false }),
    signature: 'setHalted(bool)',
    selector: '0xdcc279c8',
    args: [false],
    signer: owner,
  },
  {
    name: 'withdraw',
    call: Actions.venue.withdraw.call({
      venue: VENUE,
      token: A,
      to: B,
      amount: 123n,
      memo: MEMO,
    }),
    signature: 'withdraw(address,address,uint256,bytes32)',
    selector: '0xf4b23e03',
    args: [A, B, 123n, MEMO],
    signer: owner,
  },
  {
    name: 'transferOwnership',
    call: Actions.venue.transferOwnership.call({ venue: VENUE, newOwner: C }),
    signature: 'transferOwnership(address)',
    selector: '0xf2fde38b',
    args: [C],
    signer: owner,
  },
  {
    name: 'cancelOwnershipTransfer',
    call: Actions.venue.cancelOwnershipTransfer.call({ venue: VENUE }),
    signature: 'cancelOwnershipTransfer()',
    selector: '0x23452b9c',
    args: [],
    signer: owner,
  },
  {
    name: 'acceptOwnership',
    call: Actions.venue.acceptOwnership.call({ venue: VENUE }),
    signature: 'acceptOwnership()',
    selector: '0x79ba5097',
    args: [],
    signer: { role: 'pendingOwner' },
  },
  {
    name: 'post',
    call: Actions.venue.post.call({
      venue: VENUE,
      entries: [Post.order(ORDER), { pairIndex: 4, word: CANCEL_WORD }],
    }),
    signature: 'post(bytes)',
    selector: '0xbaf9b369',
    args: [`0x0003${ORDER_WORD.slice(2)}0004${CANCEL_WORD.slice(2)}`],
    signer: either,
  },
  {
    name: 'setShape',
    call: Actions.venue.setShape.call({
      venue: VENUE,
      pairIndex: 1,
      shapeId: 7,
      shape: SHAPE,
    }),
    signature: 'setShape(uint16,uint8,uint256[4])',
    selector: '0x1e7c92eb',
    args: [
      1,
      7,
      [
        50_000n | (20n << 32n),
        0n,
        50_000n | (20n << 32n) | ((9n | (21n << 32n)) << 48n),
        0n,
      ],
    ],
    signer: either,
  },
  {
    name: 'setMaxTakerPriorityFee',
    call: Actions.venue.setMaxTakerPriorityFee.call({
      venue: VENUE,
      cap: Venue.noPriorityFeeCap,
    }),
    signature: 'setMaxTakerPriorityFee(uint64)',
    selector: '0xdfd3607a',
    args: [18446744073709551615n],
    signer: either,
  },
  {
    name: 'enableTakerPriorityFeeCap',
    call: Actions.venue.enableTakerPriorityFeeCap.call({ venue: VENUE }),
    signature: 'enableTakerPriorityFeeCap()',
    selector: '0x83ab45c9',
    args: [],
    signer: either,
  },
  {
    name: 'setMidBand',
    call: Actions.venue.setMidBand.call({
      venue: VENUE,
      pairIndex: 1,
      minMid: Price.one,
      maxMid: Price.parse('2'),
    }),
    signature: 'setMidBand(uint16,uint96,uint96)',
    selector: '0x2dd043e9',
    args: [1, 10n ** 18n, 2n * 10n ** 18n],
    signer: owner,
  },
  {
    name: 'maker.order',
    call: Actions.maker.order.call({ venue: VENUE, order: ORDER }),
    signature: 'post(bytes)',
    selector: '0xbaf9b369',
    args: [`0x0003${ORDER_WORD.slice(2)}`],
    signer: either,
  },
  {
    name: 'maker.cancel',
    call: Actions.maker.cancel.call({
      venue: VENUE,
      cancel: { pairIndex: 4, sequence: 10, mid: Price.one },
    }),
    signature: 'post(bytes)',
    selector: '0xbaf9b369',
    args: [`0x0004${CANCEL_WORD.slice(2)}`],
    signer: either,
  },
  {
    name: 'maker.cancelAll',
    call: Actions.maker.cancelAll.call({
      venue: VENUE,
      cancels: [{ pairIndex: 4, sequence: 10, mid: Price.one }],
    }),
    signature: 'post(bytes)',
    selector: '0xbaf9b369',
    args: [`0x0004${CANCEL_WORD.slice(2)}`],
    signer: either,
  },
  {
    name: 'factory.createVenue',
    call: Actions.factory.createVenue.call({
      factory: VENUE,
      owner: A,
      salt: SALT,
    }),
    signature: 'createVenue(address,bytes32)',
    selector: '0x8a890517',
    args: [A, SALT],
    signer: { role: 'anyone' },
  },
]

/** The calldata of `signature` with `args`, encoded from the signature alone. */
function expectedCalldata(signature: string, args: readonly unknown[]): Hex {
  const item = parseAbiItem(`function ${signature}`) as AbiFunction
  return encodeFunctionData({
    abi: [item],
    functionName: item.name,
    args,
  } as never)
}

/** What a call prepares, less its ABI and calldata (checked on their own). */
const prepared = ({ to, functionName, args, signer, posts }: PreparedCall) => ({
  to,
  functionName,
  args,
  signer,
  ...(posts ? { posts } : {}),
})

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

describe('calls', () => {
  test('cover every nonpayable venue function except the settler and hook paths', () => {
    const writes = Abis.venueAbi
      .filter(
        (i) => i.type === 'function' && i.stateMutability === 'nonpayable',
      )
      .map((i) => (i as AbiFunction).name)
    const built = new Set(
      cases
        .filter((c) => c.call.contract === 'Venue')
        .map((c) => c.call.functionName),
    )
    expect(writes.filter((w) => !built.has(w)).sort()).toStrictEqual([
      'fill',
      'hookTake',
      'initialize',
    ])
  })

  for (const c of cases) {
    test(`${c.name}: calldata, selector, round trip and signer`, () => {
      expect(c.call.data, 'calldata').toBe(
        expectedCalldata(c.signature, c.args),
      )
      expect(toFunctionSelector(c.signature), 'selector').toBe(c.selector)
      expect(c.call.data.slice(0, 10)).toBe(c.selector)
      expect(c.call.to).toBe(c.call.address)
      const decoded = decodeFunctionData({ abi: c.call.abi, data: c.call.data })
      expect(decoded.functionName).toBe(c.call.functionName)
      expect(decoded.args ?? []).toStrictEqual(c.call.args)
      expect(c.call.signer).toStrictEqual(c.signer)
    })
  }

  test('prepare their target, function, arguments, signer and post entries', () => {
    expect(
      Object.fromEntries(cases.map((c) => [c.name, prepared(c.call)])),
    ).toMatchInlineSnapshot(`
      {
        "acceptOwnership": {
          "args": [],
          "functionName": "acceptOwnership",
          "signer": {
            "role": "pendingOwner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "acceptSponsorAdmin": {
          "args": [
            42n,
          ],
          "functionName": "acceptSponsorAdmin",
          "signer": {
            "role": "pendingSponsorAdmin",
            "sponsorId": 42n,
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "addPair": {
          "args": [
            "0x00000000000000000000000000000000000000A1",
            "0x00000000000000000000000000000000000000b2",
            1000000n,
          ],
          "functionName": "addPair",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "addSponsor": {
          "args": [
            42n,
            "0x00000000000000000000000000000000000000A1",
          ],
          "functionName": "addSponsor",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "approveAgent": {
          "args": [
            "0x00000000000000000000000000000000000000A1",
            true,
          ],
          "functionName": "setUpdater",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "cancelOwnershipTransfer": {
          "args": [],
          "functionName": "cancelOwnershipTransfer",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "cancelSponsorAdminTransfer": {
          "args": [
            42n,
          ],
          "functionName": "cancelSponsorAdminTransfer",
          "signer": {
            "role": "sponsorAdmin",
            "sponsorId": 42n,
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "closePair": {
          "args": [
            2,
          ],
          "functionName": "closePair",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "enableTakerPriorityFeeCap": {
          "args": [],
          "functionName": "enableTakerPriorityFeeCap",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "factory.createVenue": {
          "args": [
            "0x00000000000000000000000000000000000000A1",
            "0x5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a",
          ],
          "functionName": "createVenue",
          "signer": {
            "role": "anyone",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "maker.cancel": {
          "args": [
            "0x000400030000000a000000000000000003e800000000000000000de0b6b3a7640000",
          ],
          "functionName": "post",
          "posts": [
            {
              "pairIndex": 4,
              "sequence": 10,
              "word": "0x00030000000a000000000000000003e800000000000000000de0b6b3a7640000",
            },
          ],
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "maker.cancelAll": {
          "args": [
            "0x000400030000000a000000000000000003e800000000000000000de0b6b3a7640000",
          ],
          "functionName": "post",
          "posts": [
            {
              "pairIndex": 4,
              "sequence": 10,
              "word": "0x00030000000a000000000000000003e800000000000000000de0b6b3a7640000",
            },
          ],
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "maker.order": {
          "args": [
            "0x0003000800000009006b49d23c0703e803e800000000000000000f0eb1c05d4c8000",
          ],
          "functionName": "post",
          "posts": [
            {
              "pairIndex": 3,
              "sequence": 9,
              "word": "0x000000000009006b49d23c0703e803e800000000000000000f0eb1c05d4c8000",
            },
          ],
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "post": {
          "args": [
            "0x0003000800000009006b49d23c0703e803e800000000000000000f0eb1c05d4c8000000400030000000a000000000000000003e800000000000000000de0b6b3a7640000",
          ],
          "functionName": "post",
          "posts": [
            {
              "pairIndex": 3,
              "sequence": 9,
              "word": "0x000000000009006b49d23c0703e803e800000000000000000f0eb1c05d4c8000",
            },
            {
              "pairIndex": 4,
              "sequence": 10,
              "word": "0x00030000000a000000000000000003e800000000000000000de0b6b3a7640000",
            },
          ],
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "removePair": {
          "args": [
            5,
          ],
          "functionName": "removePair",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "resetHotWord": {
          "args": [
            5,
          ],
          "functionName": "resetHotWord",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "resetSponsor": {
          "args": [
            42n,
            "0x00000000000000000000000000000000000000C3",
          ],
          "functionName": "resetSponsor",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "revokeAgent": {
          "args": [
            "0x00000000000000000000000000000000000000A1",
            false,
          ],
          "functionName": "setUpdater",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setDenied deny": {
          "args": [
            [
              "0x00000000000000000000000000000000000000A1",
            ],
            true,
          ],
          "functionName": "setDenied",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setDenied lift": {
          "args": [
            [
              "0x00000000000000000000000000000000000000A1",
            ],
            false,
          ],
          "functionName": "setDenied",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setHalted halt": {
          "args": [
            true,
          ],
          "functionName": "setHalted",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setHalted resume": {
          "args": [
            false,
          ],
          "functionName": "setHalted",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setMaxTakerPriorityFee": {
          "args": [
            18446744073709551615n,
          ],
          "functionName": "setMaxTakerPriorityFee",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setMembers home": {
          "args": [
            1,
            0n,
            [
              "0x00000000000000000000000000000000000000A1",
              "0x00000000000000000000000000000000000000b2",
            ],
            true,
          ],
          "functionName": "setMembers",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setMembers sponsor": {
          "args": [
            1,
            42n,
            [
              "0x00000000000000000000000000000000000000C3",
            ],
            false,
          ],
          "functionName": "setMembers",
          "signer": {
            "role": "sponsorAdmin",
            "sponsorId": 42n,
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setMidBand": {
          "args": [
            1,
            1000000000000000000n,
            2000000000000000000n,
          ],
          "functionName": "setMidBand",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setPairAccess": {
          "args": [
            2,
            3,
          ],
          "functionName": "setPairAccess",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setPairHook": {
          "args": [
            1,
            "0x00000000000000000000000000000000000000C3",
            7,
          ],
          "functionName": "setPairHook",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setPairSponsor admit": {
          "args": [
            1,
            42n,
            true,
          ],
          "functionName": "setPairSponsor",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setPairSponsor remove": {
          "args": [
            1,
            42n,
            false,
          ],
          "functionName": "setPairSponsor",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setSettler": {
          "args": [
            "0x00000000000000000000000000000000000000b2",
          ],
          "functionName": "setSettler",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setShape": {
          "args": [
            1,
            7,
            [
              85899395920n,
              0n,
              25387442214440573358621520n,
              0n,
            ],
          ],
          "functionName": "setShape",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setSponsorEnabled off": {
          "args": [
            42n,
            false,
          ],
          "functionName": "setSponsorEnabled",
          "signer": {
            "role": "ownerOrAgent",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "setSponsorEnabled on": {
          "args": [
            42n,
            true,
          ],
          "functionName": "setSponsorEnabled",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "transferOwnership": {
          "args": [
            "0x00000000000000000000000000000000000000C3",
          ],
          "functionName": "transferOwnership",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "transferSponsorAdmin": {
          "args": [
            42n,
            "0x00000000000000000000000000000000000000b2",
          ],
          "functionName": "transferSponsorAdmin",
          "signer": {
            "role": "sponsorAdmin",
            "sponsorId": 42n,
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
        "withdraw": {
          "args": [
            "0x00000000000000000000000000000000000000A1",
            "0x00000000000000000000000000000000000000b2",
            123n,
            "0x4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d",
          ],
          "functionName": "withdraw",
          "signer": {
            "role": "owner",
          },
          "to": "0x1111111111111111111111111111111111111111",
        },
      }
    `)
  })

  test('carry only their own function and the errors they can revert with', () => {
    const shape = (call: PreparedCall) => {
      const [fn, ...rest] = call.abi
      return {
        function: fn?.type === 'function' ? fn.name : null,
        errors: rest.length,
        others: rest.filter((i) => i.type !== 'error').length,
      }
    }
    expect({
      setHalted: shape(
        Actions.venue.setHalted.call({ venue: VENUE, halted: true }),
      ),
      withdraw: shape(
        Actions.venue.withdraw.call({
          venue: VENUE,
          token: A,
          to: B,
          amount: 1n,
        }),
      ),
      createVenue: shape(
        Actions.factory.createVenue.call({
          factory: VENUE,
          owner: A,
          salt: SALT,
        }),
      ),
    }).toMatchInlineSnapshot(`
      {
        "createVenue": {
          "errors": 52,
          "function": "createVenue",
          "others": 0,
        },
        "setHalted": {
          "errors": 46,
          "function": "setHalted",
          "others": 0,
        },
        "withdraw": {
          "errors": 68,
          "function": "withdraw",
          "others": 0,
        },
      }
    `)
  })

  test('carry post refs for PostOutcome, each with the word the venue stores', () => {
    const call = Actions.venue.post.call({
      venue: VENUE,
      entries: [Post.order(ORDER), { pairIndex: 4, word: CANCEL_WORD }],
    })
    expect(call.posts).toStrictEqual([
      { pairIndex: 3, sequence: 9, word: HotWord.withoutRefill(ORDER_WORD) },
      { pairIndex: 4, sequence: 10, word: CANCEL_WORD },
    ])
    expect(
      HotWord.withoutRefill(ORDER_WORD),
      'the order refills its asks',
    ).not.toBe(ORDER_WORD)
    expect(HotWord.decodeEntry(ORDER_WORD).refill).toBe('asks')
  })

  test('cover the maker path only: no Settler swap or TIP-20 call (viem/tempo has those)', () => {
    expect(Object.keys(Actions).sort()).toStrictEqual([
      'factory',
      'maker',
      'venue',
    ])
    expect(
      cases.some(
        (c) => c.call.contract === 'Settler' || c.call.contract === 'TIP20',
      ),
    ).toBe(false)
  })
})

const accounts = (n: number) =>
  Array.from(
    { length: n },
    (_, i) => `0x${(i + 1).toString(16).padStart(40, '0')}` as Address,
  )

describe('refusals', () => {
  test('batches: 1 to MAX_BATCH accounts, none zero or the venue, never split', () => {
    Actions.venue.setMembers.call({
      venue: VENUE,
      pairIndex: 0,
      sponsorId: 0n,
      accounts: accounts(Number(Venue.maxBatch)),
      allowed: true,
    })
    expect(() =>
      Actions.venue.setMembers.call({
        venue: VENUE,
        pairIndex: 0,
        sponsorId: 0n,
        accounts: accounts(101),
        allowed: true,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [BatchTooLargeError: 101 accounts is above the venue's MAX_BATCH of 100: split them

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setDenied.call({ venue: VENUE, accounts: [], deny: true }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [EmptyBatchError: an account batch needs at least one account

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setMembers.call({
        venue: VENUE,
        pairIndex: 0,
        sponsorId: 0n,
        accounts: ['0x0000000000000000000000000000000000000000'],
        allowed: true,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: accounts[0] must not be the zero address

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setDenied.call({
        venue: VENUE,
        accounts: [VENUE],
        deny: true,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: accounts[0] 0x1111111111111111111111111111111111111111 is the venue itself

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })

  test('virtual addresses: refused where one could only be a mistake, accepted where removing one cleans up', () => {
    // A TIP-1022 virtual address never sends a transaction, accepts a role or takes a fill.
    const virtual: Address = '0x00000000fdfdfdfdfdfdfdfdfdfdfdfd00000001'
    const refused = (
      [
        [
          'createVenue.owner',
          () =>
            Actions.factory.createVenue.call({
              factory: OTHER,
              owner: virtual,
              salt: `0x${'00'.repeat(32)}`,
            }),
        ],
        [
          'transferOwnership.newOwner',
          () =>
            Actions.venue.transferOwnership.call({
              venue: VENUE,
              newOwner: virtual,
            }),
        ],
        [
          'approveAgent.agent',
          () =>
            Actions.venue.approveAgent.call({ venue: VENUE, agent: virtual }),
        ],
        [
          'setSettler.settler',
          () =>
            Actions.venue.setSettler.call({ venue: VENUE, settler: virtual }),
        ],
        [
          'setMembers, listing',
          () =>
            Actions.venue.setMembers.call({
              venue: VENUE,
              pairIndex: 0,
              sponsorId: 0n,
              accounts: [A, virtual],
              allowed: true,
            }),
        ],
        [
          'setDenied, denying',
          () =>
            Actions.venue.setDenied.call({
              venue: VENUE,
              accounts: [virtual],
              deny: true,
            }),
        ],
        [
          'withdraw.to',
          () =>
            Actions.venue.withdraw.call({
              venue: VENUE,
              token: OTHER,
              to: virtual,
              amount: 1n,
            }),
        ],
      ] as const
    ).map(([name, run]) => {
      try {
        run()
      } catch (e) {
        const error = e as Errors.InvalidAddressError
        expect(error, name).toBeInstanceOf(Errors.InvalidAddressError)
        return `${name}: ${error.parameter}: ${error.shortMessage}`
      }
      return `${name}: accepted`
    })
    expect(refused).toMatchInlineSnapshot(`
      [
        "createVenue.owner: owner: owner 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which never sends a transaction, so it could never run the venue",
        "transferOwnership.newOwner: newOwner: newOwner 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which could never accept",
        "approveAgent.agent: agent: agent 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which never sends a transaction, so it could never post",
        "setSettler.settler: settler: settler 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which never sends a call, so it could never settle a fill",
        "setMembers, listing: accounts[1]: accounts[1] 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which never calls a fill: adding it admits or blocks nobody",
        "setDenied, denying: accounts[0]: accounts[0] 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which never calls a fill: adding it admits or blocks nobody",
        "withdraw.to: to: to 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which forwards to its master, so the venue's exact-credit check would revert",
      ]
    `)
    // Delisting, lifting a denial and revoking stay accepted, for cleanup.
    expect(
      Actions.venue.setMembers.call({
        venue: VENUE,
        pairIndex: 0,
        sponsorId: 0n,
        accounts: [virtual],
        allowed: false,
      }).args[2],
    ).toStrictEqual([getAddress(virtual)])
    expect(
      Actions.venue.setDenied.call({
        venue: VENUE,
        accounts: [virtual],
        deny: false,
      }).args[0],
    ).toStrictEqual([getAddress(virtual)])
    expect(
      Actions.venue.revokeAgent.call({ venue: VENUE, agent: virtual }).args[0],
    ).toBe(getAddress(virtual))
  })

  test('ownership proposals reject zero; named cancellation is the only clear path', () => {
    expect(() =>
      Actions.venue.transferOwnership.call({
        venue: VENUE,
        newOwner: '0x0000000000000000000000000000000000000000',
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: newOwner must not be the zero address

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.transferSponsorAdmin.call({
        venue: VENUE,
        sponsorId: 42n,
        newAdmin: '0x0000000000000000000000000000000000000000',
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: newAdmin must not be the zero address

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })

  test('sponsors: a nonzero id, and an admin that is neither the venue nor virtual', () => {
    expect(() =>
      Actions.venue.addSponsor.call({ venue: VENUE, sponsorId: 0n, admin: A }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: sponsor id 0 is the home list, never a registered sponsor

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.addSponsor.call({
        venue: VENUE,
        sponsorId: 1n << 64n,
        admin: A,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: sponsorId must be a bigint in [0, 2^64 - 1], got 18446744073709551616n

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.addSponsor.call({
        venue: VENUE,
        sponsorId: 1n,
        admin: VENUE,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: admin 0x1111111111111111111111111111111111111111 is the venue itself

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.addSponsor.call({
        venue: VENUE,
        sponsorId: 1n,
        admin: '0x00000000fdfdfdfdfdfdfdfdfdfdfdfd00000001',
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: admin 0x00000000FDfDFDfDFDfDFDfDFdFDFdfd00000001 is a TIP-1022 virtual address, which never sends a call

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.transferSponsorAdmin.call({
        venue: VENUE,
        sponsorId: 1n,
        newAdmin: VENUE,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: newAdmin 0x1111111111111111111111111111111111111111 is the venue itself

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.resetSponsor.call({
        venue: VENUE,
        sponsorId: 1n,
        newAdmin: VENUE,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: newAdmin 0x1111111111111111111111111111111111111111 is the venue itself

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })

  test('pairs, modes, hooks, bands, shapes and the fee cap: what the contract would revert', () => {
    expect(() =>
      Actions.venue.setPairAccess.call({
        venue: VENUE,
        pairIndex: 0,
        mode: 'none' as never,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: mode must be 'closed', 'listed' or 'open', got "none"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.addPair.call({
        venue: VENUE,
        base: A,
        quote: A,
        sizeUnit: 1n,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: a pair needs two different tokens

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.addPair.call({
        venue: VENUE,
        base: A,
        quote: B,
        sizeUnit: 0n,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: sizeUnit must be nonzero

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setMidBand.call({
        venue: VENUE,
        pairIndex: 0,
        minMid: 2n,
        maxMid: 1n,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: a mid band is (0, 0) or 0 < minMid <= maxMid (InvalidMidBand onchain)

      minMid: 2n
      maxMid: 1n

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    Actions.venue.setMidBand.call({
      venue: VENUE,
      pairIndex: 0,
      minMid: 0n,
      maxMid: 0n,
    })
    expect(
      () =>
        Actions.venue.setPairHook.call({
          venue: VENUE,
          pairIndex: 0,
          hook: C,
          flags: 4,
        }),
      'takeInput needs afterFill',
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: hook flags 4 don't fit hook 0x00000000000000000000000000000000000000C3 (InvalidHookFlags onchain)

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setPairHook.call({
        venue: VENUE,
        pairIndex: 0,
        hook: '0x0000000000000000000000000000000000000000',
        flags: 1,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: hook flags 1 don't fit hook 0x0000000000000000000000000000000000000000 (InvalidHookFlags onchain)

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    Actions.venue.setPairHook.call({
      venue: VENUE,
      pairIndex: 0,
      hook: '0x0000000000000000000000000000000000000000',
      flags: 0,
    })
    expect(() =>
      Actions.venue.setShape.call({
        venue: VENUE,
        pairIndex: 0,
        shapeId: 0,
        shape: [0n, 1n, 0n, 0n],
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidShapeError: shape words are not canonical: ShapeWord reason 2 (non-canonical)

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setMaxTakerPriorityFee.call({
        venue: VENUE,
        cap: 1n << 64n,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: cap must be a bigint in [0, 2^64 - 1], got 18446744073709551616n

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })

  test('custody: a withdrawal moves a nonzero amount out of the venue', () => {
    expect(() =>
      Actions.venue.withdraw.call({
        venue: VENUE,
        token: A,
        to: VENUE,
        amount: 1n,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: a withdrawal must leave the venue

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.withdraw.call({
        venue: VENUE,
        token: A,
        to: B,
        amount: 0n,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [AmountOutOfRangeError: a withdrawal moves a nonzero amount

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.withdraw.call({
        venue: VENUE,
        token: A,
        to: B,
        amount: 1n,
        memo: `0x${'zz'.repeat(32)}`,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: memo must be 32 bytes of hex, got "0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.approveAgent.call({
        venue: VENUE,
        agent: '0x0000000000000000000000000000000000000000',
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: agent must not be the zero address

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })

  test('factory and maker: a 32-byte salt, and a batch with something in it', () => {
    // `size` rounds 63 nibbles up to 32 bytes; a bytes32 is exactly 64.
    expect(() =>
      Actions.factory.createVenue.call({
        factory: VENUE,
        owner: A,
        salt: `0x${'5'.repeat(63)}`,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: salt must be 32 bytes of hex, got "0x555555555555555555555555555555555555555555555555555555555555555"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.maker.bulkOrders.call({ venue: VENUE, orders: [] }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [EmptyBatchError: an order batch needs at least one order

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.maker.bulkOrders.call({ venue: VENUE, orders: [ORDER, ORDER] }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [DuplicatePairError: pair 3 appears twice in one batch

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.maker.cancelAll.call({ venue: VENUE, cancels: [] }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [EmptyBatchError: no pair has a quote to cancel

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })

  test('addresses: a mixed-case one must carry its checksum, and an all-lowercase or all-uppercase one comes out checksummed', () => {
    // Multicall3's address, as EIP-55 checksums it, then with one letter's case flipped.
    const checksummed: Address = '0xcA11bde05977b3631167028862bE2a173976CA11'
    const typo: Address = '0xCA11bde05977b3631167028862bE2a173976CA11'
    const lowercase = checksummed.toLowerCase() as Address
    // EIP-55 reads a one-case address as carrying no checksum, all uppercase as all lowercase.
    const uppercase = `0x${checksummed.slice(2).toUpperCase()}` as Address
    for (const venue of [lowercase, uppercase])
      expect(Actions.venue.setHalted.call({ venue, halted: true }).to).toBe(
        checksummed,
      )
    expect(() =>
      Actions.venue.setHalted.call({ venue: typo, halted: true }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: venue 0xCA11bde05977b3631167028862bE2a173976CA11 is in mixed case but fails its EIP-55 checksum: check it for a typo

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setDenied.call({
        venue: VENUE,
        accounts: [A, typo],
        deny: true,
      }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: accounts[1] 0xCA11bde05977b3631167028862bE2a173976CA11 is in mixed case but fails its EIP-55 checksum: check it for a typo

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.removePair.call({ venue: 'nope' as Address, pairIndex: 0 }),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidAddressError: venue is not an address: "nope"

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(
      Actions.venue.setDenied.call({
        venue: VENUE,
        accounts: [lowercase],
        deny: true,
      }).args[0],
    ).toStrictEqual([checksummed])
  })
})

describe('events', () => {
  test('extractEvent returns the typed event of the call', () => {
    const logs = [
      log(Abis.venueAbi, VENUE, 'Posted', {
        pairIndex: 3,
        hotWord: ORDER_WORD,
      }),
      log(Abis.venueAbi, VENUE, 'HaltedSet', { halted: true }, 1),
    ]
    const { address, args, eventName, logIndex } =
      Actions.venue.setHalted.extractEvent(logs)
    expect({ address, args, eventName, logIndex }).toMatchInlineSnapshot(`
      {
        "address": "0x1111111111111111111111111111111111111111",
        "args": {
          "halted": true,
        },
        "eventName": "HaltedSet",
        "logIndex": 1,
      }
    `)
    expect(
      Actions.factory.createVenue.extractEvent([
        log(Abis.venueFactoryAbi, B, 'VenueCreated', {
          venue: VENUE,
          owner: A,
          salt: SALT,
        }),
      ]).args,
    ).toMatchInlineSnapshot(`
      {
        "owner": "0x00000000000000000000000000000000000000A1",
        "salt": "0x5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a",
        "venue": "0x1111111111111111111111111111111111111111",
      }
    `)
  })

  test('extractEvents returns one per account, or per stored post entry', () => {
    const members = [A, B].map((account, i) =>
      log(
        Abis.venueAbi,
        VENUE,
        'MemberUpdated',
        { pairIndex: 1, sponsorId: 42n, account, allowed: true },
        i,
      ),
    )
    expect(
      Actions.venue.setMembers.extractEvents(members).map((e) => e.args),
    ).toMatchInlineSnapshot(`
      [
        {
          "account": "0x00000000000000000000000000000000000000A1",
          "allowed": true,
          "pairIndex": 1,
          "sponsorId": 42n,
        },
        {
          "account": "0x00000000000000000000000000000000000000b2",
          "allowed": true,
          "pairIndex": 1,
          "sponsorId": 42n,
        },
      ]
    `)
    expect(
      Actions.maker.order.extractEvents(members),
      'a stale entry emits nothing: no Posted is no error',
    ).toStrictEqual([])
  })

  test('refuse logs without the event, or anything but logs', () => {
    expect(() =>
      Actions.venue.setHalted.extractEvent([]),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: the logs hold no \`HaltedSet\` event

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.setDenied.extractEvents([]),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: the logs hold no \`DenyUpdated\` event

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    expect(() =>
      Actions.venue.addPair.extractEvent('0x' as never),
    ).toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: logs must be an array of logs

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})
