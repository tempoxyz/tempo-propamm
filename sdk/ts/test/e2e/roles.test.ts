// Holds every write builder's declared signer to the contract's own gates: each call is simulated as every role
// holder and a stranger, and the senders it succeeds for must be exactly the ones its `signer` names (and the ones
// `Roles.check` admits). Every refusal must be a role error, so no other precondition hides a gate.
import { type Address, keccak256, toHex } from 'viem'
import { afterAll, beforeAll, describe, expect, test } from 'vitest'
import {
  Actions,
  Errors,
  Fees,
  type PreparedCall,
  Price,
  Roles,
  Shape,
  type SignerRole,
} from '../../src/index.js'
import {
  type Fixture,
  type PairSetup,
  setupPair,
  start,
  THETA_USD,
} from './fixture.js'

let f: Fixture
let p: PairSetup

const ROLE_ERRORS = new Set([
  'NotOwner',
  'NotOwnerOrUpdater',
  'NotPendingOwner',
  'NotSponsorAdmin',
  'NotPendingSponsorAdmin',
])

beforeAll(async () => {
  f = await start()
  p = await setupPair(f)
  const { owner, sponsorAdmin, newOwner, newAdmin } = f.accounts
  await Actions.venue.addSponsorSync(f.client, {
    venue: f.venue,
    sponsorId: 42n,
    admin: sponsorAdmin.address,
    account: owner,
  })
  await Actions.venue.setPairSponsorSync(f.client, {
    venue: f.venue,
    pairIndex: p.pairIndex,
    sponsorId: 42n,
    admitted: true,
    account: owner,
  })
  // Pending handovers, so the accept calls have a holder.
  await Actions.venue.transferOwnershipSync(f.client, {
    venue: f.venue,
    newOwner: newOwner.address,
    account: owner,
  })
  await Actions.venue.transferSponsorAdminSync(f.client, {
    venue: f.venue,
    sponsorId: 42n,
    newAdmin: newAdmin.address,
    account: sponsorAdmin,
  })
})
afterAll(async () => f?.stop())

describe('signer roles against the contract', () => {
  test('match the contract for every write builder', async () => {
    const { owner, agent, sponsorAdmin, newOwner, newAdmin, stranger } =
      f.accounts
    const venue = f.venue
    const pairIndex = p.pairIndex
    const x: Address = '0x000000000000000000000000000000000000dEaD'
    const order = {
      pairIndex,
      mid: Price.one,
      shapeId: 7,
      sequence: 1_000,
      validUntil: p.validUntil,
    }
    const shape = Shape.from({ bids: [{ size: 1, spread: 1 }], asks: [] })
    const calls: [string, PreparedCall, SignerRole['role'][]][] = [
      [
        'addPair',
        Actions.venue.addPair.call({
          venue,
          base: THETA_USD,
          quote: f.quote,
          sizeUnit: 1n,
        }),
        ['owner'],
      ],
      [
        'removePair',
        Actions.venue.removePair.call({ venue, pairIndex }),
        ['owner'],
      ],
      [
        'setPairAccess',
        Actions.venue.setPairAccess.call({ venue, pairIndex, mode: 'closed' }),
        ['owner'],
      ],
      [
        'closePair',
        Actions.venue.closePair.call({ venue, pairIndex }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'addSponsor',
        Actions.venue.addSponsor.call({ venue, sponsorId: 77n, admin: x }),
        ['owner'],
      ],
      [
        'setSponsorEnabled on',
        Actions.venue.setSponsorEnabled.call({
          venue,
          sponsorId: 42n,
          enabled: true,
        }),
        ['owner'],
      ],
      [
        'setSponsorEnabled off',
        Actions.venue.setSponsorEnabled.call({
          venue,
          sponsorId: 42n,
          enabled: false,
        }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'setPairSponsor admit',
        Actions.venue.setPairSponsor.call({
          venue,
          pairIndex,
          sponsorId: 42n,
          admitted: true,
        }),
        ['owner'],
      ],
      [
        'setPairSponsor remove',
        Actions.venue.setPairSponsor.call({
          venue,
          pairIndex,
          sponsorId: 42n,
          admitted: false,
        }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'setMembers home',
        Actions.venue.setMembers.call({
          venue,
          pairIndex,
          sponsorId: 0n,
          accounts: [x],
          allowed: true,
        }),
        ['owner'],
      ],
      [
        'setMembers sponsor',
        Actions.venue.setMembers.call({
          venue,
          pairIndex,
          sponsorId: 42n,
          accounts: [x],
          allowed: true,
        }),
        ['sponsorAdmin'],
      ],
      [
        'transferSponsorAdmin',
        Actions.venue.transferSponsorAdmin.call({
          venue,
          sponsorId: 42n,
          newAdmin: x,
        }),
        ['sponsorAdmin'],
      ],
      [
        'cancelSponsorAdminTransfer',
        Actions.venue.cancelSponsorAdminTransfer.call({
          venue,
          sponsorId: 42n,
        }),
        ['sponsorAdmin'],
      ],
      [
        'acceptSponsorAdmin',
        Actions.venue.acceptSponsorAdmin.call({ venue, sponsorId: 42n }),
        ['pendingSponsorAdmin'],
      ],
      [
        'resetSponsor',
        Actions.venue.resetSponsor.call({ venue, sponsorId: 42n, newAdmin: x }),
        ['owner'],
      ],
      [
        'setDenied deny',
        Actions.venue.setDenied.call({ venue, accounts: [x], deny: true }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'setDenied lift',
        Actions.venue.setDenied.call({ venue, accounts: [x], deny: false }),
        ['owner'],
      ],
      [
        'setPairHook',
        Actions.venue.setPairHook.call({
          venue,
          pairIndex,
          hook: '0x0000000000000000000000000000000000000000',
          flags: 0,
        }),
        ['owner'],
      ],
      [
        'approveAgent',
        Actions.venue.approveAgent.call({ venue, agent: x }),
        ['owner'],
      ],
      [
        'revokeAgent',
        Actions.venue.revokeAgent.call({ venue, agent: x }),
        ['owner'],
      ],
      [
        'setSettler',
        Actions.venue.setSettler.call({ venue, settler: x }),
        ['owner'],
      ],
      [
        'setHalted halt',
        Actions.venue.setHalted.call({ venue, halted: true }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'setHalted resume',
        Actions.venue.setHalted.call({ venue, halted: false }),
        ['owner'],
      ],
      [
        'withdraw',
        Actions.venue.withdraw.call({
          venue,
          token: f.base,
          to: x,
          amount: 1n,
        }),
        ['owner'],
      ],
      [
        'transferOwnership',
        Actions.venue.transferOwnership.call({ venue, newOwner: x }),
        ['owner'],
      ],
      [
        'cancelOwnershipTransfer',
        Actions.venue.cancelOwnershipTransfer.call({ venue }),
        ['owner'],
      ],
      [
        'acceptOwnership',
        Actions.venue.acceptOwnership.call({ venue }),
        ['pendingOwner'],
      ],
      [
        'post',
        Actions.maker.order.call({ venue, order }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'setShape',
        Actions.venue.setShape.call({ venue, pairIndex, shapeId: 9, shape }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'setMaxTakerPriorityFee',
        Actions.venue.setMaxTakerPriorityFee.call({ venue, cap: Fees.gwei }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'enableTakerPriorityFeeCap',
        Actions.venue.enableTakerPriorityFeeCap.call({ venue }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'setMidBand',
        Actions.venue.setMidBand.call({
          venue,
          pairIndex,
          minMid: 1n,
          maxMid: 2n,
        }),
        ['owner'],
      ],
      [
        'cancelAll',
        Actions.maker.cancelAll.call({
          venue,
          cancels: (await Actions.maker.cancelAll.requests(f.client, { venue }))
            .cancels,
        }),
        ['owner', 'ownerOrAgent'],
      ],
      [
        'createVenue',
        Actions.factory.createVenue.call({
          factory: f.core.factory,
          owner: x,
          salt: keccak256(toHex('roles')),
        }),
        ['anyone'],
      ],
    ]
    // Who holds which role in the fixture.
    const holders: Record<string, Address> = {
      owner: owner.address,
      ownerOrAgent: agent.address,
      sponsorAdmin: sponsorAdmin.address,
      pendingSponsorAdmin: newAdmin.address,
      pendingOwner: newOwner.address,
      stranger: stranger.address,
    }
    const senders = Object.entries(holders)
    for (const [name, call, allowed] of calls) {
      const succeeded: string[] = []
      for (const [label, account] of senders) {
        const result = await simulate(call, account)
        const check = await Roles.check(f.client, { call, account })
        if (result === 'ok') succeeded.push(label)
        else
          expect(
            ROLE_ERRORS.has(result),
            `${name} as ${label}: refused with ${result}, not a role error`,
          ).toBeTruthy()
        expect(
          check.ok,
          `${name} as ${label}: Roles.check says ${check.ok}, the contract ${result}`,
        ).toBe(result === 'ok')
      }
      const expected = allowed.includes('anyone')
        ? senders.map(([l]) => l)
        : allowed.filter((r) => r !== 'anyone')
      expect(succeeded.sort(), `${name}: who succeeds`).toStrictEqual(
        [...expected].sort(),
      )
      expect(
        signerAllows(call.signer, allowed),
        `${name}: declared signer ${call.signer.role}`,
      ).toBeTruthy()
    }
  })
})

/** Whether the declared signer names exactly the roles the table expects. */
function signerAllows(
  signer: SignerRole,
  allowed: SignerRole['role'][],
): boolean {
  const covers: Record<SignerRole['role'], string[]> = {
    owner: ['owner'],
    ownerOrAgent: ['owner', 'ownerOrAgent'],
    pendingOwner: ['pendingOwner'],
    sponsorAdmin: ['sponsorAdmin'],
    pendingSponsorAdmin: ['pendingSponsorAdmin'],
    anyone: ['anyone'],
  }
  return (
    JSON.stringify([...covers[signer.role]].sort()) ===
    JSON.stringify([...allowed].sort())
  )
}

async function simulate(call: PreparedCall, account: Address): Promise<string> {
  try {
    await f.client.request({
      method: 'eth_call',
      params: [{ from: account, to: call.to, data: call.data }, 'latest'],
    })
    return 'ok'
  } catch (e) {
    return (
      Errors.decode(e)?.errorName ??
      `undecoded: ${(e as Error).message.split('\n')[0]}`
    )
  }
}
