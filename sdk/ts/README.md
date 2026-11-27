# propAMM TypeScript SDK

`@tempoxyz/propamm-sdk` is the TypeScript SDK for **propAMM v2**, Tempo's maker-posted ladder venue. It is for makers
and the owners and sponsors who run their venues: encoding, a bit-exact copy of the ladder math, reads at one block,
typed actions with the role each needs, simulation and gas, and revert decoding. Takers and routers can use its reads
and local quotes. It builds no Settler swap or token approval: see the contracts guide's
[Swapping](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/src/v2/README.md#swapping-taker-or-router).

`ManagedDirectPropAMM`, v1's multi-pair oracle-priced pool, has optional pair hooks (callbacks for fee
policy and swap notifications). They are a separate API; this v2 SDK's `VenueHookFlags` and
`Actions.venue.setPairHook` do not configure them. Managed v1 has no built-in taker-fee table; see the
[v1 hook guide](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/README.md#pair-hooks-and-fees).
The v2 hook API and SDK behavior are unchanged.

It is built on [viem](https://viem.sh) and follows `viem/tempo`'s action conventions. It reads no keys or environment
variables and sends nothing on its own: viem accounts sign.

> **Audited.** propAMM v2's contracts were audited by Sigma Prime
> ([audits](https://github.com/tempoxyz/tempo-propamm/tree/main/audits)); this SDK was not in scope.
> The SDK ships no deployment addresses: supply a factory you verified,
> and check every venue against it with `Info.isVenue` before you trust it.

The old curated Registry SDK APIs have been removed. The new permissionless `Registry` has a different ABI,
is not deployed, and has no replacement SDK actions. See the
[registry guide](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/src/v2/README.md#optional-venue-registry-not-deployed).

## Install

```sh
npm install @tempoxyz/propamm-sdk viem
```

`viem` is a peer dependency (`^2.56.9`). The package is ESM only, with TypeScript declarations, and needs Node 20 or
later.

## Quick start

```ts
import { Info, Price, propAmmActions, Quote, Sequencer, Snapshot } from '@tempoxyz/propamm-sdk'
import { createClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/chains'

const client = createClient({ account: privateKeyToAccount('0x...'), chain: tempoModerato, transport: http() })
  .extend(propAmmActions())
const factory = '0x...' // a VenueFactory you verified
const venue = '0x...'

// Trust the venue only if the factory created it; read it at one block; price a swap locally.
if (!(await Info.isVenue(client, { factory, venue }))) throw new Error('not a venue')
const snapshot = await Snapshot.get(client, { venue, pairs: [0] })
const pair = Snapshot.pair(snapshot, 0)
const quote = Quote.local(snapshot, {
  pairIndex: 0, tokenIn: pair.quote, tokenOut: pair.base, amount: 1_000_000n, exactIn: true,
  priorityFee: 0n, // the priority fee per gas of the swap's transaction
})
console.log(quote.ok ? quote.amountOut : quote.error.errorName)

// As the owner or an agent: requote pair 0 on shape 7, which setShape defined.
const sequencer = await Sequencer.seed(client, { venue, pairs: [0] })
const validUntil = Math.floor(Date.now() / 1000) + 60
const order = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: Sequencer.next(sequencer, 0), validUntil }
const posted = await client.maker.orderSync({ venue, order })
if (posted.status === 'success') console.log(posted.outcome.allAccepted)
```

## Modules at a glance

| Module | What it does |
| --- | --- |
| `Actions`, `propAmmActions()` | Every write, by contract: `Actions.venue`, `maker`, `factory`. `propAmmActions()` binds them to a client. |
| `Info` | Reads of one view each: venue, pair, sponsor and member state, access, `quote`, fills, `isVenue`, `predictVenue`. |
| `Snapshot` | A venue's state at one block: pairs, sponsors, accounts and taker access. |
| `Quote` | `Quote.local`: `Venue.quote` from a snapshot, with no request. |
| `Book` | A side's depth as rows. |
| `Price` | 18-decimal mids: `parse`, `format`, `from`. |
| `Shape`, `HotWord`, `Post` | Encode shapes, hot words and `post` batches. |
| `Ladder` | `LadderMath`, bit for bit. |
| `Sequencer` | Sequence allocation for one writer process. |
| `PostOutcome` | Which entries of a post the venue stored. |
| `Fees` | The taker priority-fee cap: what a take may tip, and what a post should. |
| `Plan` | Simulates steps in order and estimates their gas. |
| `Roles` | A pre-flight check: does an account hold a call's role? |
| `Events` | Decodes the contracts' and TIP-20's logs. |
| `Errors` | The SDK's error classes, and helpers that decode and describe reverts. |
| `Abis`, `Venue`, `VenueHookFlags`, `AccessMode`, `TakerAccess` | The contracts' ABIs, public constants and enums. |

The pure modules follow ox's conventions: `assert` throws, `validate` returns a boolean, `from` parses and checks,
conversions come in pairs (`HotWord.fromFields` and `toFields`, `Post.pack` and `unpack`), and every function declares
what it throws as `<fn>.ErrorType` (`Post.order.ErrorType`).

## Units and constants

- Amounts are token atoms, as `bigint`. Values from `uint8` to `uint40` (pair indexes, shape ids, sequences, expiries,
  scales, widenings, a level's size and spread) are `number`s, as viem types them. `uint64` and wider (sponsor ids,
  size units, mids, caps) are `bigint`s.
- `mid` is quote per 1 base with 18 decimals: `Price.parse('1.085')` is exactly `1_085_000_000_000_000_000n`. No price
  is ever a float. A post carries a nonzero `uint96` mid. A pair that has never been posted stores 0, which
  `Price.format` prints as `'0'` and `Price.parse` refuses.
- A level's `size` is in the pair's `sizeUnit` (base atoms per size step). Spreads and widenings are in 0.1 bp. Width
  and depth scales are per mille (1000 = 1x); depth 0 offers nothing.
- Bids are where takers sell base; asks are where they buy it.
- An enum reads and writes as its camelCase name: `AccessModeName` (`'closed'`, `'listed'`, `'open'`, and `'none'` for
  a removed pair) and `TakerAccessName` (`'allowed'`, `'notListed'`, ...). `AccessMode` and `TakerAccess` hold the raw
  values that events and raw reads carry, and `accessModeNames` and `takerAccessNames` name them.
- Addresses go in all lowercase, all uppercase or EIP-55 checksummed, and come out checksummed. A mixed-case address
  with a wrong checksum is refused (`InvalidAddressError`), not re-checksummed.
- Constants are camelCase. A contract's public constants sit in its group (`Venue.maxBatch`, `Venue.noPriorityFeeCap`,
  `Venue.defaultTakerPriorityFeeCap`, `VenueHookFlags.beforeFill`). A library's sit in
  the module that ports it (`HotWord.initial` and the flag bits, `Shape.maxLevels` and the `Shape.reason*` values,
  `Ladder.factorOne`, `scaleOne`, `denominator` and `spreadOne`). The SDK's own sit in theirs (`Price.one`,
  `Fees.gwei`).

## Encoding

The pure modules encode what the contracts store and price what they would fill. They need no client.

```ts
import { HotWord, Ladder, Post, Price, Shape } from '@tempoxyz/propamm-sdk'

// An exact decimal, scaled by 1e18.
const mid = Price.parse('1.085')

// Up to ten levels a side: sizes in the pair's size steps, spreads in 0.1 bp that never decrease.
const shape = Shape.from({
  bids: [{ size: 50_000, spread: 20 }, { size: 100_000, spread: 40 }],
  asks: [{ size: 50_000, spread: 20 }, { size: 100_000, spread: 40 }],
})

// An order is the pair's whole hot word; `post` takes the packed entries.
const entry = Post.order({ pairIndex: 0, mid, shapeId: 7, sequence: 2, validUntil: 1_800_000_060, refill: 'asks' })
const { packed, posts } = Post.pack([entry])
const hot = HotWord.decodeEntry(entry.word) // { mid, ..., sides: 'both', refill: 'asks' }

// LadderMath.fill, bit for bit: sell 1,000 base atoms into the bids of a pair whose sizeUnit is 1e6.
const [w0, w1] = Shape.side(shape.words, 'bids')
const fill = Ladder.fill(Ladder.curve(hot, 1_000_000n, true), w0, w1, true, 1_000n, 0n)
if (fill.ok) console.log(packed, posts, fill.amountOut)
```

- A hot word is exactly 32 bytes of hex. `HotWord` and `Post.pack` refuse a short one rather than pad it.
- `Post.order` and `Post.cancel` refuse each bad field with `InvalidOrderError`: `parameter` names the field, `value`
  holds what was given and `pairIndex` the order's pair. A batch refuses a pair it already holds
  (`DuplicatePairError`).
- An order's optional fields default to no widening, both scales 1000, both sides on and no refill. It also takes a
  word's raw `HotWord.Fields` as they are, `Post.order({ pairIndex, ...fields })`, with `flags` (0 to 15) in place of
  `sides` and `refill`, never alongside them. A reserved flag bit (4-15) is refused.
- `Shape` accepts exactly one encoding per ladder, as the contract does. A refusal names the level and field
  (`bids[2].spread`) or carries the contract's `reason`.
- `Ladder` takes every input at the width the venue stores it, so it never prices a fill the chain couldn't.

## Actions

Every write is a viem/tempo-style action, grouped by the contract it calls: `Actions.venue`, `Actions.maker`,
`Actions.factory`. `Actions.<group>.<name>(client, parameters)` sends one transaction and
returns its hash. Each action's namespace also holds:

- `<name>Sync`, which waits for the receipt and returns its event's arguments beside it.
- `call(args)`, the validated call: `{ abi, address, functionName, args, data, to }`, plus `signer` (who may send it)
  and, for a post, `posts`. Use it in a Tempo `calls` batch, `Plan.simulate`, or viem's `writeContract`,
  `simulateContract` and `multicall`. Its `abi` holds just its function and the errors it can revert with.
- `extractEvent(logs, { address })`, or `extractEvents` for `setMembers`, `setDenied` and posts: the typed event, from
  `address` only when it is given. Events keep the contract's field names (`Posted`'s `hotWord`, `Fill`'s `seq`).
- The types `Args`, `Parameters`, `ReturnValue` and `ErrorType`.

```ts
import { Actions, propAmmActions } from '@tempoxyz/propamm-sdk'
import { createClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sendTransactionSync } from 'viem/actions'
import { tempoModerato } from 'viem/chains'
import { tempoActions } from 'viem/tempo'

const client = createClient({
  account: privateKeyToAccount('0x...'),
  chain: tempoModerato,
  transport: http(),
})
  .extend(tempoActions())
  .extend(propAmmActions())
const venue = '0x...'

// Send and wait: the event's arguments beside a successful receipt. A pending or reverted one carries no event.
const added = await client.venue.addPairSync({
  venue,
  base: '0x20C0000000000000000000000000000000000001',
  quote: '0x20c0000000000000000000000000000000000002',
  sizeUnit: 1_000_000n,
})
if (added.status !== 'success') throw new Error(`addPair is ${added.status}`)
const { pairIndex } = added

// Several calls, one Tempo transaction: list a taker, then open the pair to the list.
const calls = [
  Actions.venue.setMembers.call({ venue, pairIndex, sponsorId: 0n, accounts: ['0x...'], allowed: true }),
  Actions.venue.setPairAccess.call({ venue, pairIndex, mode: 'listed' }),
]
const receipt = await sendTransactionSync(client, { calls })
console.log(Actions.venue.setPairAccess.extractEvent(receipt.logs).args.newMode)

// Some successful calls emit no event when the requested state is already set.
const halted = await client.venue.setHaltedSync({ venue, halted: true })
if (halted.status === 'success' && halted.changed === true) {
  console.log(halted.halted) // The HaltedSet event's field exists only in this branch.
} else if (halted.status === 'success') {
  console.log('already halted') // changed: false; no event fields.
}
```

- **Parameters** are viem/tempo's write parameters: `account` (the client's by default), `chain`, gas, fees and
  `nonce`, and Tempo's `feePayer`, `feeToken`, `keyAuthorization`, `nonceKey`, `owner`, `validAfter` and `validBefore`.
  `createVenue`'s `owner` is the new venue's owner, so it takes no multisig `owner`.
- **Sync results** are a union keyed on `status`, which is always `receipt.status` (`SyncReturnValue`). `throwOnReceiptRevert`
  defaults to `true`. A `'pending'` receipt (Tempo's, before inclusion) or a `'reverted'` one (with
  `throwOnReceiptRevert: false`) comes back as `{ status, receipt }` alone, so check `status` first. A success carries
  the posts' `{ posted, outcome }` or `setMembers`' and `setDenied`'s `{ updates }`. `approveAgentSync`,
  `revokeAgentSync` and `setHaltedSync` can succeed without a change: `{ status: 'success', receipt, changed: false }`
  has no event fields. Check both `status === 'success'` and `changed === true` before reading their event fields.
  Other writes return their event arguments on success. `cancelAllSync` adds `skipped` in every case. Each reads only
  the logs its own contract emitted.
- **`propAmmActions()`** binds every action to a client, as `tempoActions()` does: `client.venue.*`, `client.maker.*`,
  `client.factory.*`, typed for the client's chain and account. `call`, `extractEvent` and
  `cancelAll.requests` are bound too.
- A revert is viem's `ContractFunctionExecutionError`, which names the contract's error. `Errors.decode(error)` reads
  it too.

## Roles

| Role (`call.signer.role`) | Calls |
| --- | --- |
| `owner` | `addPair`, `removePair`, `resetHotWord` (while halted), `setPairAccess`, `addSponsor`, `resetSponsor`, `setPairHook`, `approveAgent`, `revokeAgent`, `setSettler`, `setMidBand`, `withdraw`, `transferOwnership`; `setMembers` for the home list (sponsor id 0); the widening half of the split calls |
| `ownerOrAgent` | `post` (orders, cancels, `cancelAll`), `setShape`, `setMaxTakerPriorityFee`, `enableTakerPriorityFeeCap`, `closePair`; the narrowing half: `setHalted(true)`, `setDenied(_, true)`, `setSponsorEnabled(_, false)`, `setPairSponsor(_, _, false)` |
| `sponsorAdmin` | `setMembers` for its id, `transferSponsorAdmin` |
| `pendingOwner`, `pendingSponsorAdmin` | `acceptOwnership`, `acceptSponsorAdmin` |
| `anyone` | `Actions.factory.createVenue` |

- `Roles.check(client, { call, account })` reads the role `call.signer` names, at one block, and returns `{ ok: true }`
  or the role missing and why. `account` defaults to the client's. It is a pre-flight only: the contract stays the
  authority.
- An agent is one of the venue's updaters (the contract's `setUpdater`). It posts, sets shapes and the fee cap, and
  narrows access, but never has custody.

## Maker

```ts
import { Actions, PostOutcome, Price, Sequencer, Shape } from '@tempoxyz/propamm-sdk'
import { createClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/chains'

const client = createClient({ account: privateKeyToAccount('0x...'), chain: tempoModerato, transport: http() })
const venue = '0x...'
const validUntil = Math.floor(Date.now() / 1000) + 3_600

// Define a shape and confirm it before an order names it.
const shape = Shape.from({ bids: [{ size: 50_000, spread: 20 }], asks: [{ size: 50_000, spread: 20 }] })
await Actions.venue.setShapeSync(client, { venue, pairIndex: 0, shapeId: 7, shape })

// Seed once at startup; every later post takes its sequence from memory.
const sequencer = await Sequencer.seed(client, { venue, pairs: [0] })
let currentOrder = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 7, sequence: Sequencer.next(sequencer, 0), validUntil }
const call = Actions.maker.order.call({ venue, order: currentOrder })
const posted = await Actions.maker.orderSync(client, { venue, order: currentOrder })
// A stale entry is skipped without an event: `outcome` says what the venue stored, once the receipt is a success.
// PostOutcome.fromReceipt(call, receipt) reads any receipt, a pending or reverted one included.
if (posted.status === 'success' && !posted.outcome.allAccepted) console.log('stale:', posted.outcome.skipped)
console.log(PostOutcome.fromReceipt(call, posted.receipt).status)

// Requote and give the asks their whole ladder back after fills consumed it.
currentOrder = { ...currentOrder, sequence: Sequencer.next(sequencer, 0), mid: Price.parse('1.086') }
// Refill is a one-shot request, not part of the current order state reused below.
await Actions.maker.orderSync(client, { venue, order: { ...currentOrder, refill: 'asks' } })

// Switch shapes safely: define id 8, confirm it, then point the next order at it.
const wider = Shape.from({ bids: [{ size: 50_000, spread: 40 }], asks: [{ size: 50_000, spread: 40 }] })
await Actions.venue.setShapeSync(client, { venue, pairIndex: 0, shapeId: 8, shape: wider })
currentOrder = { ...currentOrder, sequence: Sequencer.next(sequencer, 0), shapeId: 8 }
await Actions.maker.orderSync(client, { venue, order: currentOrder })

// Stops: a cancel is a newer word with no sides (a newer in-flight post supersedes it); cancelAll cancels every live
// pair in one post and leaves the venue running. Halting is its own call, and only the owner resumes.
await Actions.maker.cancelSync(client, { venue, cancel: { pairIndex: 0, sequence: Sequencer.next(sequencer, 0), mid: currentOrder.mid } })
const cancelled = await Actions.maker.cancelAllSync(client, { venue, sequencer })
if (cancelled.status === 'success' && !cancelled.outcome.allAccepted)
  console.log('superseded by a newer post:', cancelled.outcome.skipped)
// Live pairs no cancel went to: one never posted, or one at the last sequence, which still quotes.
if (cancelled.skipped.length > 0) console.log('not cancelled:', cancelled.skipped)
await Actions.venue.setHaltedSync(client, { venue, halted: true })
```

- **Orders.** Each order replaces the pair's whole hot word and names a shape already set. There are no order ids or
  queue priority. `validUntil` is inclusive Unix seconds below 2^40. There is no implicit clock, refresh or
  cancel-on-disconnect.
- **Sequencing.** Ordinary posts only raise a pair's sequence, and the venue skips a stale entry without reverting. A new pair stores
  sequence 1, so `Post.order` refuses `sequence <= 1`. `Sequencer` serves one writer process per venue: `seed` reads
  each pair's stored sequence once (plus an optional `gap`), then `next` allocates from memory, so it never reuses a
  number an unmined post of its own holds. Keep one per venue: `next` and `observe` update it in place and never lower
  a counter. `observe` raises a pair's floor after a post made elsewhere, and starts a pair the state doesn't know
  (`next` refuses one until then). Persistence is the caller's responsibility: atomically max-merge each pair's allocated sequence
  from `sequencer.last` into durable storage, never lowering a floor (the last allocated sequence) or deleting other pairs during ordinary operation. The deliberate-reset exception is covered below. Await durable commit before broadcasting its post.
  Concurrent snapshot writes can finish out of order: a snapshot at 8 can overwrite one at 9 after post 9 was
  broadcast, letting a restart reuse 9. Serialize checkpoint capture and commit through one writer, or use transactional per-pair
  maxima; ordinary last-writer-wins replacement is unsafe. Stop or fence the old process against allocation and
  broadcast before loading the latest committed checkpoint. Storage maxima alone do not coordinate allocators.
  On restart, pass the committed checkpoint as `Sequencer.seed(client, { venue, pairs, last: checkpoint })`:
  each counter starts at `max(storedSequence + gap, lastAllocated)`. Alternatively, `Sequencer.from(checkpoint)`
  restores it, then `observe` each pair's current stored sequence. Without a checkpoint, wait until all earlier posts
  have landed or can no longer execute, then read the settled chain. A gap must cover the distance to the highest
  potentially executable sequence, not the count of pending posts; reusing a gap on restart is not safe by itself.
  Several processes, keys or nonce lanes need a shared counter instead.
  The owner can call `Actions.venue.resetHotWord` while halted to restore the initial, unfillable word at seq 1
  without changing consumed depth or pair configuration.
  Deliberate reset is the only exception to a durable floor's monotonicity, and needs an **application-owned
  per-pair generation** (a checkpoint namespace, not the venue's sponsor generation). The contract and SDK carry
  no reset epoch: halting stops fills, not posts. A halted venue still accepts authorized posts, including old signed transactions.
  Use this recovery protocol:
  1. Halt and confirm it. Fence all old allocators, broadcasts and durable writes; drain pending/signed posts or
     make them permanently unable to execute (for example, revoke their updater authority and do not reauthorize
     it while those posts remain executable). Discarding a local queue alone is insufficient; include owner posts.
     Durably mark the pair as recovering so a crash cannot start an ordinary writer against its old checkpoint.
  2. Send `resetHotWord` separately and confirm its successful receipt under your finality policy. Persist its
     identity (chain, venue, pair, transaction hash and log/block identity) for recovery. After checking the reset
     state, atomically compare-and-swap the old generation to a fresh, never-reused generation and replace only
     this pair's floor with the freshly read reset sequence, 1. Preserve every unrelated pair's generation and floor.
     Bind the transition to that confirmed reset identity: retries return the already committed generation without
     resetting its floor again. If a crash leaves the reset or transition uncertain, keep writers stopped and reconcile
     the receipt and durable record; do not send another reset or clear a checkpoint blindly.
  3. Load only the current generation's floor and seed a new allocator from the confirmed chain state and that floor.
     Each durable max-merge must atomically compare its supplied generation with the current record and reject a
     mismatch; never relabel an old snapshot with a new generation. Await commit before broadcast. Resume only
     current-generation writers, check shapes and post a fresh quote before unhalting; refill explicitly if intended.
     Ordinary restarts retain maxima within this generation, so a crash after allocation cannot reuse that sequence.
     Keep old transaction authority fenced: storage generations do not make the contract reject an old post.
  For example, the application's storage adapter below must implement the atomic max-merge and durable-commit
  contract above, scoped to this chain and venue. It rejects stale generations atomically. It is not an SDK function or an in-memory `Map.set`:

  ```ts
  import { Sequencer } from '@tempoxyz/propamm-sdk'

  declare const sequencer: Sequencer.Sequencer // Restored from current-generation floors before tasks start.
  declare const generations: ReadonlyMap<number, string> // Loaded with those floors; immutable for this writer.
  declare const storage: {
    // Atomically require the current generation, then keep max(stored, sequence).
    // Reject a stale generation and preserve all other pairs.
    // Resolve only after durable commit; reject on failure.
    maxMerge(pairIndex: number, generation: string, sequence: number): Promise<void>
  }
  declare function broadcast(pairIndex: number, sequence: number): Promise<void>

  async function allocateAndBroadcast(pairIndex: number) {
    const generation = generations.get(pairIndex)
    if (generation === undefined) throw new Error('Pair generation not loaded')
    const sequence = Sequencer.next(sequencer, pairIndex)
    await storage.maxMerge(pairIndex, generation, sequence) // Failure means no broadcast; burn the allocation.
    await broadcast(pairIndex, sequence)
  }
  await allocateAndBroadcast(0)
  ```

- **Refill.** Fills take depth off each side, from where the last fill on that side stopped. Only a post with `refill`
  gives a side its depth back; a post without one keeps the consumption, which then comes off the top of the new
  ladder. The venue applies a refill once.
- **`cancelAll`** reads every pair at one block and posts each live one a cancel at its next sequence, above the stored
  one and `sequencer`'s counter, recording each cancel in `sequencer` before it sends. It skips a pair never posted to
  (`neverPosted`, unless `sequencer` has handed out a later sequence for it) and one at the last sequence
  (`sequenceExhausted`): stop it with `closePair` or `setHalted`, then recover with an owner reset while halted.
  `cancelAllSync` returns those as `skipped` beside `outcome`, so `outcome.allAccepted` alone doesn't mean every pair
  is cancelled. With nothing to cancel it sends nothing and throws `EmptyBatchError`. `cancelAll.requests` returns
  `{ cancels, skipped }` and reserves each returned sequence in the supplied `sequencer` before resolving, so a
  concurrent `Sequencer.next` cannot reuse it. Malformed mid-band responses fail with `UnexpectedResponseError`;
  discovery validates every cancel before reserving any sequence. Reservations require latest state without `blockNumber`,
  `stateOverride` or `blockOverrides`; `blockTag` must be omitted or `latest`. For historical or hypothetical
  discovery, omit the sequencer. Without a sequencer it only reads: serialize manual writers or use a
  shared allocator. For manual sending (`cancelAll.call({ venue, cancels })`), durably max-merge the reserved
  checkpoint before broadcasting. Do not roll reservations back after an abandoned or failed send; later calls
  allocate above them. Read `PostOutcome` because a newer post can still supersede a cancellation.
- **`PostOutcome`** matches each entry to a `Posted` event by pair and stored word. `fromReceipt` and
  `fromBatchReceipt` (for a Tempo batch of several post calls, in call order) read the receipt's status first: a
  pending receipt is `{ status: 'pending' }` and a reverted one `{ status: 'reverted' }`, never every entry skipped.
  `fromLogs` and `fromBatch` take the logs of a mined, successful transaction. In one transaction, a later entry at a
  pair and sequence already used reads skipped. A receipt containing `HotWordReset` for a venue/pair being
  attributed is rejected as ambiguous: identical posts before and after the reset cannot be distinguished by logs.
  Resets of unrelated pairs do not prevent attribution.
- Send every `post` with a tip above the venue's taker cap: `Fees.makerTip(cap)` ([the fee cap](#the-taker-priority-fee-cap)).

## Owner and sponsors

```ts
import { Actions } from '@tempoxyz/propamm-sdk'
import { createClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/chains'
import { Actions as TempoActions } from 'viem/tempo'

const owner = createClient({ account: privateKeyToAccount('0x...'), chain: tempoModerato, transport: http() })
const sponsorAdmin = createClient({ account: privateKeyToAccount('0x...'), chain: tempoModerato, transport: http() })
const venue = '0x...'
const base = '0x20C0000000000000000000000000000000000001'

const added = await Actions.venue.addPairSync(owner, { venue, base, quote: '0x20c0000000000000000000000000000000000002', sizeUnit: 1_000_000n })
if (added.status !== 'success') throw new Error(`addPair is ${added.status}`)
const { pairIndex } = added
await Actions.venue.approveAgentSync(owner, { venue, agent: '0x...' })
// Funding is a TIP-20 transfer: viem/tempo's own action (`memo` optional).
await TempoActions.token.transferSync(owner, { token: base, to: venue, amount: 1_000_000_000_000n })

// Sponsors: the owner registers an id and admits it on the pair; only its admin lists its users.
await Actions.venue.addSponsorSync(owner, { venue, sponsorId: 42n, admin: sponsorAdmin.account.address })
await Actions.venue.setPairSponsorSync(owner, { venue, pairIndex, sponsorId: 42n, admitted: true })
const listed = await Actions.venue.setMembersSync(sponsorAdmin, { venue, pairIndex, sponsorId: 42n, accounts: ['0x...'], allowed: true })
await Actions.venue.setPairAccessSync(owner, { venue, pairIndex, mode: 'listed' })

// The taker priority-fee cap: the contract's 10 gwei default, or any value.
const capped = await Actions.venue.enableTakerPriorityFeeCapSync(owner, { venue })
if (listed.status === 'success' && capped.status === 'success') console.log(listed.updates.length, capped.cap)
```

- **Access rules** (pair modes, the home list, sponsor lists, the deny list) are the contracts':
  see the contracts guide's [Access](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/src/v2/README.md#access).
- **Batch limits.** `setMembers` and `setDenied` take 1 to `Venue.maxBatch` (100) accounts, and the SDK never splits
  them: split a longer list yourself. Each new account is a fresh storage slot, about 255k gas: 50 new accounts take
  12.8M gas and 100 take 25.6M. At `Plan.gasLimit`'s 130%, a batch of about 90 new accounts still fits Tempo's 30M
  transaction cap, a full batch of 100 doesn't (33.2M), and 50 (16.6M) leaves room.
- **Validation.** Builders validate every input and fail closed with one of [`Errors`' classes](#errors): zero
  addresses, sponsor id 0 for `addSponsor`, `'none'` access, a bad mid band, incoherent hook flags, non-canonical
  shapes, and empty or oversized batches.
- **Virtual addresses.** A TIP-1022 virtual address never sends a transaction, accepts a role or takes a fill, so the
  builders refuse one where it can only be a mistake: `createVenue`'s `owner`, `transferOwnership`'s `newOwner` (the
  venue's), `approveAgent`'s `agent`, a sponsor's `admin` or `newAdmin`, the accounts `setMembers`
  lists and `setDenied` denies, and `withdraw`'s `to`. Removing one (`setMembers` with `allowed: false`, `setDenied`
  with `deny: false`, `revokeAgent`) is still accepted, for cleanup.

## Takers: reads and quotes

```ts
import { Book, Info, Quote, Snapshot } from '@tempoxyz/propamm-sdk'
import { createClient, http } from 'viem'
import { tempoModerato } from 'viem/chains'

const client = createClient({ chain: tempoModerato, transport: http() })
const factory = '0x...' // a VenueFactory you verified
const venue = '0x...'
const taker = '0x...'
const tip = 1n // the priority fee per gas the taker's swap transaction will pay

// Trust `venue` only if the verified factory created it.
if (!(await Info.isVenue(client, { factory, venue }))) throw new Error('not a venue')
const snapshot = await Snapshot.get(client, { venue, pairs: [0], access: [{ taker, sponsorIds: [0n] }] })
const pair = Snapshot.pair(snapshot, 0)
// What a taker can take now; Book.ladder(pair, 'asks') is the posted ladder whatever its switches.
const asks = Book.side(pair, 'asks', { at: snapshot.block.timestamp, halted: snapshot.state.halted })
// The taker's swap, at the priority fee its transaction will pay, with its access folded in.
const q = Quote.local(snapshot, {
  pairIndex: 0, tokenIn: pair.quote, tokenOut: pair.base, amount: 1_000_000n, exactIn: false,
  priorityFee: tip,
  takerAccess: Snapshot.access(snapshot, { pairIndex: 0, taker, sponsorId: 0n }),
})
console.log(asks.length, q.ok ? q.amountIn : q.error.errorName)
```

- **Read options.** Every state read takes viem/tempo's read parameters (`account`, `blockNumber`, `blockTag`,
  `blockOverrides`, `stateOverride`). A read that makes several calls (`Info.venueState`, `sponsorState`, `meta`,
  `orders`, and `Snapshot.get`, `Sequencer.seed`, `Roles.check`, `cancelAll.requests`, `Plan.simulate`) makes them all
  at one block: `blockNumber`, else the block `blockTag` names, else the latest. So it refuses `blockTag: 'pending'`
  (`InvalidArgumentError`). `Info.fills` reads logs, not state: it takes an inclusive `fromBlock` and `toBlock`.
- **`Snapshot.get`** reads the venue, the pairs (`'all'` by default), and the sponsors, accounts and taker access you
  ask for, at one block, in two or three multicalls. If the address doesn't answer the venue views it throws
  `UnknownVenueError`; if the node fails that read it throws viem's error. Any other failed read fails only its own
  entry, which reads `{ ok: false, error }`. `Snapshot.pair` and `Snapshot.access` return an entry that was read, or
  throw `SnapshotIncompleteError`. `verifyHash: true` re-reads the block hash and throws `SnapshotReorgedError` if it
  changed.
- **`Quote.local(snapshot, request)`** is `Venue.quote` from that state: the same amounts, or the same revert with the
  same arguments, checked in the venue's order. It prices only. `priorityFee` is required, since the taker's wallet
  sets it and a silent 0 would pass every cap.
- **`takerAccess`.** Like `Venue.quote`, `Quote.local` checks no access unless you pass `takerAccess` (from
  `Snapshot.access` or `Info.takerAccess`). Then a refusal is `fill`'s revert for it, after the fee cap and before
  inventory. `Info.takerAccess` returns the fill's own access check by name (`'allowed'`, or the first refusal), and
  `Info.takerAllowed` whether that is `'allowed'`.
- **`Book.side(pair, side, { at, halted })`** and `Book.remaining` show what a taker can take at `at` (Unix seconds),
  after the side's consumption: nothing when the venue is halted, the quote has expired, or the side is off or at depth
  scale 0. `Book.ladder(pair, side)` is the posted ladder. Neither checks inventory or access.

## The taker priority-fee cap

A venue can cap the priority fee per gas (`tx.gasprice - block.basefee`, 0 below the base fee) of any transaction that
fills or quotes it. No `fill` or `quote` succeeds above the venue's `maxTakerPriorityFee`: both revert
`TakerPriorityFeeTooHigh`. A new venue has no cap (`Venue.noPriorityFeeCap`). `enableTakerPriorityFeeCap` sets
`Venue.defaultTakerPriorityFeeCap` (10 gwei per gas), and `setMaxTakerPriorityFee` sets any value. With a cap, a maker
that posts with a higher tip gets ahead of every pending take in a builder that orders by priority fee. A builder that
orders by arrival, such as Tempo's, still fills a take that reached it first at the old quote.

```ts
import { Fees, Venue } from '@tempoxyz/propamm-sdk'

const cap = Venue.defaultTakerPriorityFeeCap
const tip = Fees.makerTip(cap) // 11 gwei: above anything a take may tip
Fees.allows(cap, tip) // false: no take tips as much
const fees = Fees.feeFields(10n * Fees.gwei, tip) // maxFeePerGas 41 gwei, maxPriorityFeePerGas 11 gwei
const viemsHeadroom = Fees.feeFields(10n * Fees.gwei, tip, { baseFeeMultiplier: 1.2 })
const takerFees = Fees.takerFields(10n * Fees.gwei, cap, Fees.gwei)
// Reuse takerFees for simulation, gas estimation and the submitted swap.
console.log(fees, viemsHeadroom, takerFees)
```

- `Fees.allows(cap, priorityFee)` is the venue's rule: any priority fee when there is no cap, else `priorityFee <= cap`.
  `Fees.priorityFee(gasPrice, baseFee)` is the fee the venue judges. `Fees.isNoCap(cap)` is true for
  `Venue.noPriorityFeeCap` (`type(uint64).max`). Caps are `uint64`s in wei per gas.
- `Fees.makerTip(cap, margin?)` is the tip a post (and `setShape`) should pay: `margin` above the cap, 1 gwei by
  default (`Fees.defaultMakerMargin`), or `margin` alone when there is no cap.
- `Fees.feeFields(baseFee, priorityFee)` is viem's `estimateFeesPerGas` formula (`baseFee x baseFeeMultiplier +
  priorityFee`) with the tip fixed rather than estimated. Its `baseFeeMultiplier` defaults to 3
  (`Fees.defaultBaseFeeMultiplier`; viem's is 1.2): the whole tip is paid while the base fee at inclusion stays within
  that multiple.
- `Fees.takerFields(baseFee, cap, priorityFee)` builds the same EIP-1559 fields, but rejects a tip above the
  supplied cap. Read the venue's current cap when preparing each transaction.
- Takers: reuse `Fees.takerFields`' result for reads, `Plan.simulate`, gas estimation and submission; omitted
  fee fields simulate a zero priority fee and may hide a rejection at execution. `Quote.local` judges its `priorityFee` against the snapshot's cap. `Info.takerAccess` and `takerAllowed` read
  the calling transaction's own fee, so a read without fee fields never sees the cap. `Plan.simulate` passes each
  step's fee fields through.

## Simulation and gas

One call goes to viem's own `simulateContract` and `estimateContractGas` as it is. A Tempo batch, or several steps in
order, goes to `Plan`.

```ts
import { Actions, Plan, Price, Shape } from '@tempoxyz/propamm-sdk'
import { createClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { estimateContractGas, simulateContract, writeContract } from 'viem/actions'
import { tempoModerato } from 'viem/chains'

const account = privateKeyToAccount('0x...') // an agent the venue's owner approved
const client = createClient({ account, chain: tempoModerato, transport: http() })
const venue = '0x...'

// One call: simulate as the sender (a revert throws viem's error, named), then send the request it returns.
const halt = Actions.venue.setHalted.call({ venue, halted: true })
const { request } = await simulateContract(client, { ...halt, account })
const gas = await estimateContractGas(client, { ...halt, account })
const hash = await writeContract(client, { ...request, gas })

// One step is one transaction: here a Tempo batch (0x76) of a shape and the order that names it.
const shape = Shape.from({ bids: [{ size: 50_000, spread: 40 }], asks: [{ size: 50_000, spread: 40 }] })
const order = { pairIndex: 0, mid: Price.parse('1.085'), shapeId: 8, sequence: 43, validUntil: Math.floor(Date.now() / 1000) + 60 }
const calls = [Actions.venue.setShape.call({ venue, pairIndex: 0, shapeId: 8, shape }), Actions.maker.order.call({ venue, order })]
const [step] = await Plan.simulate(client, { steps: [{ account, calls }] })
if (step?.status === 'failure') console.log(`call ${step.failedCall} reverts ${step.error?.errorName}`)
const limit = Plan.gasLimit(await Plan.estimateGas(client, { account, calls }))
console.log(hash, limit)
```

- `Plan.simulate(client, { steps })` runs steps (each one transaction from one sender) in order with `eth_simulateV1`,
  one block per step with state carried. It returns each call's status, gas, decoded result or decoded revert, and its
  events. It needs no fee balance or nonce.
- The steps follow one base block (`blockNumber`, else the block `blockTag` names, else the latest; `'pending'` is
  refused). Each step's block carries the base block's base fee, so the venue judges a step's priority fee as it would
  onchain, and a timestamp one second after the block before it, so a live quote doesn't expire. `blockOverrides`
  apply to every step's block on top of those.
- A step is atomic, like the Tempo batch it stands for. If a call reverts, the step fails as a whole: its earlier
  calls read `rolledBack`, its later ones `notRun`, and later steps don't see its effects.
- A step of several calls needs a viem/tempo chain, as sending it would.
- `Plan.estimateGas(client, step)` is `eth_estimateGas`, with `calls` for a batch. It includes Tempo's state-creation
  cost, which the simulation's per-call gas mostly omits, so use it for a gas limit. `Plan.gasLimit(estimate)` is 130%
  of it, rounded up (`Plan.gasEstimateMultiplier`, Forge's default). For account batches, see
  [Batch limits](#owner-and-sponsors).

## Errors

`Errors` holds both halves: the classes of the errors the SDK throws, and helpers for the reverts the contracts throw
(`decode`, `describe`, `describeAccess`, `errorOf`, `allErrorsAbi`).

```ts
import { Errors, Post, Price } from '@tempoxyz/propamm-sdk'

try {
  Price.parse('1.5e3')
} catch (error) {
  if (error instanceof Errors.InvalidPriceError) error.value // '1.5e3'
  if (error instanceof Errors.BaseError) error.shortMessage // anything the SDK refused
}

// Each function's ErrorType narrows on `name`.
function explain(error: Post.order.ErrorType) {
  if (error.name === 'InvalidOrderError') return `${error.parameter}: ${String(error.value)}`
  return error.message
}

// A revert, from any viem error or raw data.
const decoded = Errors.decode('0x69495f5e') // { errorName: 'ZeroFill', contracts: ['Venue'], ... }
if (decoded) console.log(Errors.describe(decoded), explain)
```

- **Refusals.** The SDK checks every input before it encodes, reads or sends anything, and fails closed: a value it
  can't represent exactly is an error, never a rounding or a clamp. Each kind of mistake has a class:
  `AmountOutOfRangeError`, `BatchTooLargeError`, `DuplicatePairError`, `EmptyBatchError`, `InvalidAddressError`,
  `InvalidArgumentError`, `InvalidHotWordError`, `InvalidOrderError`, `InvalidPriceError`, `InvalidShapeError`,
  `MissingAccountError`, `SequenceExhaustedError`, `SnapshotIncompleteError`, `SnapshotReorgedError`,
  `UnknownPairError`, `UnknownVenueError` and `UnseededPairError`, each with an `<Name>ErrorType` for narrowing.
- **One class per kind of value**, wherever it comes in: an address is `InvalidAddressError`; a mid
  `InvalidPriceError`; a hot word or one of its widenings or scales `InvalidHotWordError`; a shape, its words, or a
  level's size or spread `InvalidShapeError`; an amount a call moves `AmountOutOfRangeError`; anything else
  `InvalidArgumentError`. A field of an order or cancel is `InvalidOrderError`, which extends `InvalidArgumentError`
  and adds the order's `pairIndex`.
- **Not refusals.** A node answer the SDK can't use (a block without a number, a simulation missing a result) is
  `UnexpectedResponseError`. A contract revert or an RPC failure stays viem's own error: decode it with
  `Errors.decode`, which inspects the outer error and at most 15 causes, stopping at cycles, and names every contract
  that declares the decoded error (venue, Settler, factory, TIP-20). It returns `null` when no revert data is found
  within that limit, even if a deeper cause carries data. Raw revert data can be passed directly. `Errors.describe`
  puts the ladder, access and fee-cap errors in words.
- **Fields.** Each class carries what it refused (`parameter` and `value`, `address`, `pairIndex`, `reason`, `size`
  and `maxSize`, ...). A short message names the value as given, so `got 1` (a number) and `got 1n` (a bigint) differ.
  The full message ends with `Version: @tempoxyz/propamm-sdk@<version>`.
- **Types.** Every function declares what it throws as `<fn>.ErrorType` (`Price.parse.ErrorType`), including
  `Errors.GlobalErrorType` for anything else. `Errors.BaseError` extends viem's `BaseError`, so `shortMessage`,
  `details`, `cause` and `walk()` work as they do for viem's errors.

## Coming from the Rust SDK

Names follow the Rust SDK's, in TypeScript casing (`Info::venue_state` is `Info.venueState`,
`Exchange::bulk_orders` is `Actions.maker.bulkOrders`). These behave differently:

| Rust (`propamm_sdk`) | TypeScript (`@tempoxyz/propamm-sdk`) |
| --- | --- |
| `Info::connect(provider, venue, chain_id, factory)` | No connection object. `Info.isVenue(client, { factory, venue })` returns `false` where Rust returns `Error::UnknownVenue`, and the chain is the viem client's. |
| `Error::UnknownVenue` | `Info.isVenue` answering `false`. `Errors.UnknownVenueError` is a different case: `Snapshot.get`'s for an address that doesn't answer the venue views. |
| `Error::ChainMismatch`, `Error::CallMismatch` | The SDK keeps no chain of its own, and a call names only its contract. viem signs for the client's `chain`, and throws its own `ChainMismatchError` for a JSON-RPC account whose node is on another chain. |
| `Error::NothingToCancel { skipped }` | `Errors.EmptyBatchError`, from `cancelAll` with no pair to cancel or `cancelAll.call` with no cancels. |
| `Exchange::simulate` | viem's `simulateContract(client, { ...call, account })`, or `Plan.simulate` for a batch or several steps. |
| `Exchange::send` | The action itself returns the hash. `<name>Sync` also waits for the receipt and returns its event. |
| `CancelAllSent` (`pending`, `call`, `skipped`) | `cancelAll` returns the hash; `cancelAllSync` returns `receipt`, `outcome` and `skipped`. |
| `PostOutcome::from_logs`, `from_batch` | The same as `PostOutcome.fromLogs` and `fromBatch`. `fromReceipt` and `fromBatchReceipt` also read the receipt's status. |
| `Sequencer::new`, `checkpoint`, methods on `&self` | `Sequencer.from`, `sequencer.last`, and functions over a state value: `Sequencer.next(sequencer, pairIndex)`. |
| `Info::inventory` | viem/tempo's `Actions.token.getBalance(client, { token, account: venue })`, or a snapshot pair's `inventory`. |
| `Info::quote_state`, `QuoteState::quote` | `Snapshot.get` for the whole venue, then `Quote.local`. |
| `OrderRequest` | `Post.OrderRequest`, with the same defaults. It also takes a word's raw `flags`. |

## Links

- [propAMM v2 contracts guide](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/src/v2/README.md): roles,
  access, quoting and swapping.
- [propAMM v2 specification](https://github.com/tempoxyz/tempo-propamm/blob/main/spec/propamm-v2.md).
- [Rust SDK](https://github.com/tempoxyz/tempo-propamm/blob/main/sdk/rust/README.md).
