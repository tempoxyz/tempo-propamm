# propAMM v2

propAMM v2 gives a market maker an on-chain order book on Tempo. The maker posts a price ladder for each token pair,
and the takers it allows swap against that ladder through one shared `Settler`. The maker keeps custody of its own
inventory, sets every price, and decides who can trade. There is no oracle, no pooled liquidity and no routing.

The contracts and their NatSpec define exact behaviour;
[`spec/propamm-v2.md`](../../../spec/propamm-v2.md) gives the design and the reasons behind it.

## Deployments

### Tempo mainnet (chain ID 4217)

Deployed on 2026-10-26. The three core contracts have verified source and match the contract code at `d74f248`.

| Contract | Address |
|---|---|
| Venue implementation | [0xEc207E702C5eEC03b79fb687e82049ed60BF64F3](https://explore.tempo.xyz/address/0xEc207E702C5eEC03b79fb687e82049ed60BF64F3) |
| Settler | [0xDD683c32d7379a8353b5b23E9a8159A2831F65b6](https://explore.tempo.xyz/address/0xDD683c32d7379a8353b5b23E9a8159A2831F65b6) |
| VenueFactory | [0x7b71Cd1F47EB6b98fD5aF5167872ce378fc7136b](https://explore.tempo.xyz/address/0x7b71Cd1F47EB6b98fD5aF5167872ce378fc7136b) |

The deployer retains no admin role in this core. No curated Registry was deployed on mainnet; its source has been removed.
The replacement `Registry` is separate and not deployed. See the signed
[mainnet manifest](../../../deployments/tempo-mainnet/propamm-v2.json) and
[deployment and verification record](../../../docs/v2-deployment.md#mainnet-deployment).

### Moderato testnet (chain ID 42431)

The live demo uses this deployment from 2026-10-18, built from audit-lock commit `675e826`.
It predates the subsequent audit fixes and does not match the mainnet contract version above.
Removing the curated Registry source does not remove a historical testnet Registry or migrate its consumers.
Historical records remain valid for their pinned deployment version; use that version’s tooling to verify them.

| Contract | Address |
|---|---|
| Venue implementation | [0x10ec0e47ED23B530d062B0A6B4c596eef845d53a](https://explore.moderato.tempo.xyz/address/0x10ec0e47ED23B530d062B0A6B4c596eef845d53a) |
| Settler | [0x57D79C27DBE4ae5FDc4475d1F8E63a1D9f431D68](https://explore.moderato.tempo.xyz/address/0x57D79C27DBE4ae5FDc4475d1F8E63a1D9f431D68) |
| VenueFactory | [0x8a928226A135bAb97956FAB313a2fa407bE6a7A3](https://explore.moderato.tempo.xyz/address/0x8a928226A135bAb97956FAB313a2fa407bE6a7A3) |

On either network, create a maker's venue through its `VenueFactory` and fund that venue. The Venue implementation
is the shared template; it does not hold a maker's inventory. Takers approve the network's `Settler`.

## Contracts

| Contract | How many | What it does |
|---|---|---|
| `Venue` | One per maker | Holds the maker's inventory, ladders and access lists for all of its pairs. Fills swaps. |
| `VenueFactory` | One per chain | Creates venues as minimal clones of one immutable implementation. Anyone can create one, for any owner. |
| `Settler` | One shared default per chain | The only address takers approve. Moves the taker's input into one venue, calls its `fill`, and enforces the taker's deadline and slippage bound. Holds no funds and has no admin. |
| `Registry` | Optional, per factory; not deployed | Permissionless, append-only venue catalog. Registration proves origin, not approval or trading access. |
| Pair hook | Optional, per pair | A maker's contract called around fills, for example to keep idle inventory in a vault. |

Nothing is upgradeable. The `Settler` only fills venues the factory created; any other address reverts `UnknownVenue`.
A venue owner can select a different settler; this guide’s swaps require the shared Settler to remain selected.
Check a venue with `VenueFactory.isVenue` before funding it or trusting its `owner()`. Directory registration is for
discovery only: the `Settler` fills any factory venue whose access admits the taker, registered or not.

`libraries/` holds the encoding and pricing code (`HotWord`, `ShapeWord`, `LadderMath`), and `interfaces/` the ABI.

## Optional venue registry (not deployed)

[`Registry`](Registry.sol) is a new, unaudited discovery contract for an existing v2 factory. It replaces the removed
curated Registry and records only venue addresses, not tokens, pairs or sponsor IDs. Registration proves factory
origin; it does **not** mean Tempo approves the venue or that anyone can trade there.

Anyone can call `register(venue)` to backfill an existing venue. `createAndRegister(owner, salt)` creates through the
original factory and registers in the same transaction; if that venue already exists, it registers it instead. This
preserves the factory's predicted address, owner and default Settler. Calls directly to the old factory do not update
the directory automatically: someone must submit those venues afterward.

Read `venueCount()`, `venueAt(index)` or `venues(offset, limit)` (at most 100 entries per page). Registration is
idempotent and entries remain in insertion order, even if a venue halts or removes every pair. Routers must read each
venue's current pairs, access, Settler, prices and liquidity, and apply their own approval policy before routing.
Permissionless creation means the directory can include unwanted venues; discovery is not an endorsement.

This extension changes no existing contract, token allowance or venue ownership. Clients migrating from the removed
pair-keyed Registry must page venues and read their live pairs instead.
Deployment and backfill are described in [the deployment guide](../../../docs/v2-deployment.md#optional-venue-registry).

## How a quote works

The owner or an authorized updater calls `post(packed)` with packed pair indexes and hot words to update quotes.
A refill resets a side’s consumed depth to zero, offering its ladder again; an ordinary update does not refill.

A pair's price comes from two pieces: a **shape**, which changes rarely, and a **hot word**, which changes on every
update. A pair's two tokens use the same decimals.

**Shape.** A shape is a ladder of up to 10 levels per side. Each level has a size and a spread from the mid. Spreads
can't get tighter deeper in the ladder, so the price only gets worse as size grows. A pair can store up to 256 shapes
(normal, wide, weekend, one-sided, and so on), set with `setShape`.

A shape is four words: bid levels 1-5, bid levels 6-10, ask levels 1-5, ask levels 6-10. Level `j` (0-4) of a word
sits at bits `48j` to `48j+47`: a `uint32` size in the pair's `sizeUnit`, then a `uint16` spread in 0.1 bp. `setShape`
accepts one encoding per ladder: a side ends at its first zero-size level and every deeper level is zero, spreads never
decrease, and bits 240-255 are zero. All-zero words delete a shape. A shape that was never set fills nothing.

**Hot word.** One storage slot per pair. It picks the active shape and moves or stretches it:

| Field | Bits | Meaning |
|---|---|---|
| `mid` | 0-95 | Quote tokens per 1 base token, 18 decimals. `post` rejects 0 |
| `bidWiden`, `askWiden` | 96-111, 112-127 | Extra spread added to every level on one side, in 0.1 bp |
| `widthScale` | 128-143 | Multiplier on every spread (1000 = 1x) |
| `depthScale` | 144-159 | Multiplier on every size (1000 = 1x, 0 = no size) |
| `shapeId` | 160-167 | Which stored shape is active |
| `validUntil` | 168-207 | The pair fills while `block.timestamp <= validUntil` |
| `seq` | 208-239 | Must go up with every post; owner reset restores 1 |
| `flags` | 240-255 | Bit 0 bids off, bit 1 asks off, bit 2 refill bids, bit 3 refill asks. Bits 4-15 must be 0 |

The price at an ask level is `mid × (1 + (spread × widthScale / 1000 + askWiden) / 100,000)`, and its size is
`floor(size × sizeUnit × depthScale / 1000)` base units. Bids mirror this below the mid; a bid level priced at or
below 0 ends the bid side. Moving the mid, widening, pulling size or switching shape is a single slot write.

**Fills use up the ladder.** Each fill walks its side from where the previous fills stopped, like orders coming off a
book. A taker buying base walks the asks; a taker selling base walks the bids. Depth only comes back when the maker
posts with that side's refill flag. So splitting an order into many swaps never gets a better price than one swap of
the total. `consumed(pairIndex)` shows how much base each side has used.

**Rounding.** Every fill rounds once, in the maker's favour, by less than one unit of the rounded token:

| Taker | Rounded result |
|---|---|
| Sells base, exact in | Quote out, floored |
| Buys base, exact out | Quote in, ceiled |
| Pays quote, exact in | Base out, floored. A remainder that can't buy one more base unit stays with the maker |
| Wants quote, exact out | Base in, ceiled |

A fill is all or nothing. It reverts `InsufficientDepth` when the ladder left past its side's consumed depth can't
cover it, and `ZeroFill` when either side rounds to 0. A level whose size floors to 0 is skipped. A quote or fill also
reverts `QuoteExpired` after `validUntil`, `SideDisabled` when `depthScale` is 0 or the side is off, and
`InsufficientInventory` when the venue can't pay the output, counting what a `BEFORE_FILL` hook can add.

## Who can do what

A pair hook is maker-selected code called around a fill. Its `afterFill` callback may use `hookTake` to collect
that fill’s input only when the owner enabled the `TAKE_INPUT` flag; see [hooks](#pair-hooks) for the full rules.

A sponsor is a business whose admin lists its own users. The venue owner registers that sponsor under a nonzero ID
and admits it to selected pairs. Sponsor 0 is the home list, edited only by the venue owner.

| Role | Can |
|---|---|
| Owner | Everything: add and remove pairs, set shapes and bands, manage access, set updaters and hooks, repoint the venue's settler (`setSettler`), halt and resume, withdraw at any time, transfer ownership (two steps). |
| Updater | Quote: `post` (refills included), `setShape`, the taker priority-fee cap. Narrow access only: close a pair, switch a sponsor off or remove it from a pair, deny accounts, halt. Can't reopen anything, lift a denial, withdraw or change roles. |
| Sponsor admin | Add its own users on the pairs its sponsor is admitted to, while the sponsor is switched on, and remove them on any pair. Hand its list to a new admin (two steps). |
| Taker | Swap for itself, through the `Settler`, on pairs it's allowed on. |
| Settler | Call `fill`. |
| Pair hook | Call `hookTake`, only inside its own pair's `afterFill` with `TAKE_INPUT`. |

Only the owner can change the venue's settler, so Tempo can't redirect a venue's custody. The directory has no admin
or delisting function; closing or removing a pair changes its live tradability, not directory membership.

Transferring ownership moves no other role: the old owner's updaters keep quoting, and their hot words stay live.
Updaters aren't enumerable on chain (replay `UpdaterSet`). A new owner follows the
[venue ownership handover](../../../docs/v2-deployment.md#venue-ownership-handover).

Use a Safe or a root-key account as the owner, and a separate account as the updater for day-to-day quoting. An
access key on the owner account carries the owner's full authority, including `withdraw`.

## Access

Each pair has a mode:

- **Closed:** nobody trades. Every new pair starts here.
- **Listed:** only listed takers trade.
- **Open:** anyone trades. The owner can only switch a pair to Open while the venue is halted.

A taker on a Listed pair needs a listing on one of these:

- **The home list,** sponsor id 0. The owner adds and removes its members.
- **A sponsor's list.** A sponsor is a business, such as a fintech, that vouches for its own users. The owner
  registers it (`addSponsor`) and admits it to each pair (`setPairSponsor`). The sponsor's admin then manages its
  users per pair (`setMembers`). If a sponsor's admin key is lost, the owner calls `resetSponsor`, which hands the id to
  a new admin and drops every earlier listing at once. The owner chooses each id, so a business can carry the same id
  on every venue, but the venue doesn't enforce that: a router that relies on it checks `sponsor(id)`.

The **deny list** is venue-wide and overrides everything, Open pairs included. A fill checks the `Settler`'s caller, so
deny the account that calls. A TIP-1022 virtual address never calls: deny its master.

`setMembers` and `setDenied` take at most `MAX_BATCH` (100) accounts per call, and a bad entry reverts the whole call.

Every swap names the sponsor id it trades under, and pays only the taker. `Fill.sponsorId` is checked on a Listed pair
and is the taker's unchecked claim on an Open one. To see why a taker can't trade, call
`takerAccess(pairIndex, taker, sponsorId)`. It returns `Allowed` or the first refusal, in the order `fill` checks:

| # | `TakerAccess` | When | `fill` reverts |
|---|---|---|---|
| 0 | `None` | Never returned. A zero word (an unset slot, a failed call) decodes to it: treat it as a refusal | — |
| 1 | `Allowed` | The check admits the taker | (fills) |
| 2 | `UnknownPair` | No live pair at the index: never added, or removed | `UnknownPair` |
| 3 | `PriorityFeeTooHigh` | The transaction's priority fee is above the venue's cap, whoever the taker | `TakerPriorityFeeTooHigh` (`quote` too) |
| 4 | `Closed` | The pair is Closed | `TakerNotAllowed` |
| 5 | `Denied` | The taker is denied, on a Listed or Open pair | `TakerDenied` |
| 6 | `UnknownSponsor` | Listed, and the id is neither 0 nor registered | `UnknownSponsor` |
| 7 | `SponsorDisabled` | Listed, and the sponsor is switched off | `SponsorDisabled` |
| 8 | `SponsorNotAdmitted` | Listed, and the sponsor isn't admitted on the pair | `SponsorNotAdmitted` |
| 9 | `NotListed` | Listed, and the list the swap names doesn't hold the taker on the pair | `TakerNotAllowed` |

`takerAllowed` is exactly `takerAccess(...) == Allowed`. Both read the calling transaction's own priority fee, so call
them with the swap's fee fields ([taker priority-fee cap](#taker-priority-fee-cap)). Neither covers `halted`, the hot
word, inventory, the venue's settler, a token's own transfer policy or TIP-1028 receive policies, so simulate the swap
too. `sponsor(id)`, `pairSponsor(pairIndex, id)`, `isMember(pairIndex, id, account)` and `denied(account)` read the
parts.

## Setting up a venue (maker)

1. Call `VenueFactory.createVenue(owner, salt)`. `predictVenue(owner, salt)` gives the address in advance. The venue
   starts with the factory's default settler, no sponsor and nobody listed.
2. As the owner, `addPair(base, quote, sizeUnit)` for each pair. Both tokens must be initialized TIP-20s accepted by
   the canonical factory at `0x20Fc000000000000000000000000000000000000`, have code and the same decimals.
   An ERC-20 lookalike or an uninitialized address in the TIP-20 namespace reverts `InvalidPairTokens`.
   `sizeUnit` (base units per size step) must be nonzero. Indexes count up from 0 and are never reused. The pair
   starts Closed.
3. `setShape(pairIndex, shapeId, words)` for each ladder you want to use.
4. `setUpdater(quotingAccount, true)`. Optionally `setMidBand(pairIndex, minMid, maxMid)` to cap the mids your updater
   can post.
5. Fund the venue with plain token transfers to its address.
6. Post the first quote. A new pair starts at `seq` 1, so the first post must use `seq` 2 or higher. A post with an
   old `seq` is skipped without an error.
7. Add takers: `setMembers(pairIndex, 0, accounts, true)` for the home list, and `addSponsor` plus `setPairSponsor` for
   each sponsor.
8. `setPairAccess(pairIndex, Listed)`. For Open, send `setHalted(true)`, `setPairAccess(pairIndex, Open)` and
   `setHalted(false)` in one batch.
9. Optionally cap takers' priority fee with `enableTakerPriorityFeeCap()` (10 gwei) or
   `setMaxTakerPriorityFee(cap)`. A take that tips above the cap reverts.
10. If a verified `Registry` is available, anyone can register the venue with `register(venue)`.
    Registration grants no approval or trading permission; until one is deployed, consumers can index factory events.

## Quoting (updater)

- `post(packed)` updates any number of pairs in one call. Each entry is a 2-byte pair index followed by the 32-byte
  hot word.
- Raise `seq` on every entry. Entries with a stale `seq` are skipped with no write and no event, so read `hotWord`
  after posting to confirm. A malformed entry (unknown pair, zero mid, reserved flag bits) reverts the whole batch.
- Keep `validUntil` short, so a quote you can't update in time stops filling on its own.
- Pull liquidity with `depthScale` 0 or the side-off flags. Switch regimes by changing `shapeId`.
- Depth a fill uses stays used, even across new quotes, until you post with that side's refill flag. Set it when you
  want to offer the full ladder again, for example after rebalancing that side. Leave it off for routine re-quotes.
  The flag isn't stored, so re-posting the same word later doesn't refill again. Consumed depth is in base units, so
  after a post without a refill it comes off the top of whichever ladder that post selects.
- An updater's entry with a mid outside the pair's band reverts the batch (`MidOutOfBand`); the owner's entries aren't
  band-checked. `setMidBand` doesn't re-check the live word, so halt or post after setting or tightening a band.
- If you use the fee cap, send every `post` with a priority fee above it, and anything else meant to beat takers: a
  `setShape` on a shape a live word uses, `setHalted(true)`, `closePair` or a cap cut. A builder that orders by priority
  fee then puts it ahead of any take pending at the same time. Send nothing at or below the cap on the posting key's
  nonce sequence just before a post: the post can't land before that transaction, which waits behind every take that
  tips more. A separate nonce key or an expiring nonce for posts avoids this. The cap narrows the race with takers but
  doesn't close it ([limits and risks](#limits-and-risks)).
- Keep each post's gas limit at or below the gas of the cheapest take on the venue (measure it on the venue's own
  tokens), and send a repricing of more pairs than fit under it as several posts. Posts and takes share Tempo's 30M
  general gas limit per block, and a builder that can't fit a transaction goes on to smaller ones, so a post that
  doesn't fit waits while a stale take lands.
- In an emergency, `setHalted(true)` stops all fills and `closePair` stops one pair. Only the owner reopens.

## Onboarding users (sponsor)

1. The maker registers you: `addSponsor(id, admin)`, then `setPairSponsor(pairIndex, id, true)` for each pair. Your
   admin can be an account or a contract, but not a TIP-1022 virtual address.
2. Your admin lists users: `setMembers(pairIndex, id, accounts, true)`, up to 100 per call, on pairs that admit you
   while you are switched on. Removing them uses the same call with `false`, and works on any pair, admitted or not.
3. Tell your users to swap with your sponsor id.
4. To change admin keys, call `transferSponsorAdmin(id, newAdmin)`. The new admin then calls `acceptSponsorAdmin(id)`.

If the maker switches you off or removes you from a pair, your lists are kept, so restoring you restores every member.
If your admin key is lost, the maker's `resetSponsor(id, newAdmin)` keeps your id but voids every earlier listing; the
new key lists your users again.

## Swapping (taker or router)

1. Discover candidates from a verified `Registry`: page `venues(offset, limit)` (limit at most 100),
   read each venue's `pairCount()` and `pair(index)`, skip removed pairs, and match the requested tokens in either
   order. Until a directory is deployed, index the factory's `VenueCreated` events. Check `venue.settler()` against the intended Settler
   and apply your own venue policy: several venues can offer the same pair, and registration is not approval.
2. Read the venue at one block. One multicall of `hotWord`, `consumed`, `pair`, `halted`, `maxTakerPriorityFee`, the
   output token's `balanceOf(venue)`, `hookLiquidity(pairIndex, tokenOut)` and `takerAccess(pairIndex, taker, id)`
   (the taker's sponsor id first, then 0), then `shape(pairIndex, shapeId)` for the shape that word selects, pinned to
   the same block number. Price from the walked side's consumed depth: `bids` when the taker sells base, `asks` when
   it buys. Or call `venue.quote(pairIndex, tokenIn, tokenOut, amount, exactIn)`, which returns what `fill` would.
3. Simulate the swap with the fee fields you will send ([taker priority-fee cap](#taker-priority-fee-cap)).
4. Send one 0x76 batch ([approvals](#approvals-and-access-keys)):
   - Exact input: `approve(Settler, amountIn)`, then
     `Settler.swapExactIn(venue, pairIndex, tokenIn, tokenOut, amountIn, minAmountOut, sponsorId, deadline, ref)`.
   - Exact output: `approve(Settler, maxAmountIn)`, then
     `Settler.swapExactOut(venue, pairIndex, tokenIn, tokenOut, amountOut, maxAmountIn, sponsorId, deadline, ref)`,
     then `approve(Settler, 0)`.
5. Set the slippage bound for fills that may land first. Each fill uses up depth, so a quote is only good until the
   next fill on that side.

The output always goes to the account that calls the `Settler`; there is no recipient. `ref` is echoed into `Fill`.
The `Settler` also requires:

- `deadline` not passed (inclusive), two different nonzero tokens and a nonzero amount.
- The pull to raise the venue's input balance by exactly the amount (`VenueDeltaMismatch`), so a token that charges a
  transfer fee can't be swapped.
- Exact input: the fill to use exactly `amountIn` and pay at least `minAmountOut` (`InsufficientOutput`).
- Exact output: the quoted input to be at most `maxAmountIn` before anything is pulled (`ExcessiveInput`), and the fill
  to match the quote (`FillMismatch`).
- The caller's output balance to rise by at least the output (`TakerDeltaMismatch`). The venue's payout must credit the
  taker exactly, so the taker's TIP-1028 receive policy must accept the venue.

For a hooked pair, include the gas its callbacks need. `hookLiquidity` gives the hook at most `HOOK_VIEW_GAS`
(1,500,000) and reads 0 on any failure, so a multicall should allow it that much. An exact-output quote with
insufficient venue inventory can also spend up to `HOOK_VIEW_GAS` reading the hook.

### Taker priority-fee cap

A venue can cap the priority fee per gas, `tx.gasprice - block.basefee`, of every transaction that fills on it, so a
take can't outbid the maker's re-quote. Above the cap, `quote` and `fill` revert
`TakerPriorityFeeTooHigh(priorityFee, cap)` and no tokens move; the taker still pays for gas. A new venue has no cap:
`maxTakerPriorityFee()` reads `NO_PRIORITY_FEE_CAP` (`type(uint64).max`).

- Read `maxTakerPriorityFee()` and set fee fields explicitly.
- An EIP-1559 or Tempo transaction keeps `maxPriorityFeePerGas` at or below the cap.
- A legacy or EIP-2930 transaction pays all of its `gasPrice` above the base fee as priority fee, wallet padding
  included, so it keeps `gasPrice` at or below the base fee plus the cap.
- Simulate and estimate with the fee fields set. A call without them has a gas price of 0 and sees no priority fee,
  so an over-cap swap passes there and reverts on chain. The same holds for `takerAccess` and `takerAllowed`.
- A cap below a wallet's default tip rejects every transaction that wallet prices by default.

## Approvals and access keys

Approve the `Settler` for each swap exactly, in the same batch as the swap. Exact input approves `amountIn`, which the
swap spends to zero. Exact output approves `maxAmountIn` and ends the batch with `approve(Settler, 0)`. Never leave a
standing allowance on an account that has Tempo access keys.

- **Access keys.** Tempo charges an access key's spending limit when the key approves, not when a contract pulls the
  tokens. A standing `Settler` allowance therefore lets any of the account's keys that may call the `Settler` swap past
  its limit, including into a venue the key's holder created, at a price it posted. This is Tempo behaviour for every
  allowance-based contract. Exact approvals, or keeping the `Settler` out of an access key's call scope, prevent it.
  The `Settler` pulls only from `msg.sender`, so no third party can spend a leftover allowance.
- **Gas.** An approval from zero creates the allowance slot, which Tempo charges about 250,000 gas up front. Clearing it
  in the same transaction earns the storage credit that refunds most of that (TIP-1060), so the slot nets a few
  thousand gas. The transaction still needs about 250,000 gas of headroom for it, and the fee payer's balance must
  cover that while it is reserved. Exact output's final `approve(Settler, 0)` is what clears the slot.

## Pair hooks

The owner can attach an optional hook to a pair with `setPairHook(pairIndex, hook, flags)`. Hooks can't change a
price: amounts are final before any hook runs.

- `beforeFill` (`BEFORE_FILL`, 1) runs before the output is paid, and can only add inventory, for example by pulling it
  from a vault just in time. Afterwards the venue must hold at least as much of both fill tokens as before.
- `afterFill` (`AFTER_FILL`, 2) runs after the output is paid.
- With `TAKE_INPUT` (4, which needs `AFTER_FILL`), the hook can call `hookTake(tokenIn, amount)` during `afterFill`,
  for up to the fill's input in total, for example to move it into a vault. Afterwards the venue must hold its earlier
  `tokenIn` less what was taken, and all of its `tokenOut`.
- Each callback must return its own selector. `setPairHook` rejects a hook without code and flags the hook doesn't
  list in `supportedFlags()`.
- Hooks can't re-enter the venue, except through `hookTake`, or the `Settler`. `quote` and the views take no lock, so a
  hook can read them mid-fill, and sees the depth after the current fill.

When the pair's hook has `BEFORE_FILL`, `hookLiquidity(pairIndex, token)` returns its `availableLiquidity(token)`, and
`quote` counts the same figure toward inventory; otherwise it returns 0. The call is a `staticcall` capped at
`HOOK_VIEW_GAS`; it reads 0 on any failure or malformed return, and never reverts for a known pair. A 0 doesn't prove
the hook is empty: a view that needs more gas reads 0, as can one within the cap when the caller leaves the venue less
than the cap plus 1/64, while `fill` still pulls from the hook. A hook over a vault with expensive views needs a
bounded source of its own.

`availableLiquidity` must report a conservative amount that `beforeFill` can deliver from the hook's own
withdrawable holdings. For exact output, the Settler quotes before crediting the venue's input; `fill` then advances
the side's consumed depth before calling `beforeFill`. The reported amount must remain deliverable after both
changes. Exclude liquidity that shrinks with either change, such as a top-up target minus the venue's input balance
or a limit derived from its remaining depth. A truthful point-in-time figure is not enough. This is a hook-author
obligation, not a reservation enforced by the venue: quotes reserve nothing and do not guarantee a later fill
against intervening external changes, such as vault withdrawals or a pause.

A hook is trusted code the maker chooses. It runs on every fill of its pair, and a failing hook blocks only that pair.
No hook ships with this repository: write and audit one against `IVenueHook`. The venue checks balances around each
callback, not what a hook does elsewhere. A hook that moves input into another contract, such as an ERC-4626 vault,
must check the contract received it: under TIP-1028 a transfer the receiver's policy rejects still succeeds and parks
in the ReceivePolicyGuard, and a stock ERC-4626 mints shares for it anyway. `hookTake` checks the hook's own credit,
so a TIP-1028 block on the hook reverts the fill. A no-op hook adds about 11,400 gas per fill in the local Solar build
([gas](#gas)).

## Retiring a pair or a venue

1. `closePair(pairIndex)` or `setHalted(true)`.
2. `withdraw(token, to, amount, memo)` for each token. It works halted or not, pays `to` as given and checks its exact
   credit, so a withdrawal to a TIP-1022 virtual address reverts: withdraw to an account.
3. Consumers must exclude the closed or removed pair using its live state. Directory entries are never delisted.

`closePair` keeps the pair's last hot word, so reopening it with `setPairAccess` revives that quote. Post a fresh one
first: `post` works on a closed pair and while halted.

`removePair` clears the pair's configuration, hot word, hook, mid band and consumed depth, and its index is never
reused. It leaves the pair's shapes behind: delete them with all-zero `setShape` calls, which work on a removed pair,
to recover their storage.

## Events to index

- `Posted`, `HotWordReset`, `Refilled` and `ShapeSet`: every quote update, reset, refill and shape, which together
  rebuild any curve at any block. `HotWordReset` restores the initial, unfillable word at seq 1 without changing
  consumed depth. With `Fill`, these events rebuild each side's consumed depth.
- `Fill`: every swap, with taker, sponsor id, amounts, the mid in force and its `seq`. `sponsorId` isn't indexed.
- `PairAccessUpdated`, `MemberUpdated`, `SponsorAdded`, `SponsorEnabledSet`, `PairSponsorSet`, `SponsorReset`,
  `SponsorAdminTransferStarted`, `SponsorAdminTransferred` and `DenyUpdated`: every access change. A sponsor's admin
  changes its list without the owner, so watch `MemberUpdated` for every admitted sponsor.
- `PairAdded` and `PairRemoved` (pairs), `PairHookSet` (hooks), `MidBandSet` (mid bands), `UpdaterSet` (updaters),
  `SettlerSet` (the settler), and `OwnershipTransferStarted` and `OwnershipTransferred` (the owner).
- `MaxTakerPriorityFeeSet`, `HaltedSet` and `Withdrawn`.
- `VenueFactory.VenueCreated(venue, owner, salt)`: a new venue. The venue emits nothing on creation; its settler is the
  factory's `defaultSettler()`.
- `Registry.Registered(venue, index)`: a venue added to the directory, not a pair approval.

## Limits and risks

Sigma Prime audited `contracts/src/v2` at commit `459ccf7`, and retested the fixes for all six findings (low and
informational): see the [audits page](../../../audits/README.md).

- **A mid band bounds price, not loss.** An updater that can also take (a contract updater, a batch transaction, or an
  accomplice the pair admits) can post at `minMid`, buy, post at `maxMid` and sell, losing up to
  `(maxMid - minMid) / maxMid` of the traded notional per round trip, repeatable within one transaction because the
  updater also sets depth. Keep bands narrow and pairs Listed, and monitor `Posted` and `Fill`.
- **`seq` at 2^32 - 1 blocks further posts.** Ordinary posts only raise `seq`, for the owner too. To recover, stop
  every writer, revoke compromised updater keys, discard queued posts and halt the venue. The owner calls
  `resetHotWord(pairIndex)` in its own transaction: it restores the initial, unfillable word at seq 1, preserving
  the pair index, shapes, band, hook, access, directory membership and consumed depth. Replace the SDK sequencer with
  one freshly seeded from chain (`observe` never lowers its counter), check the selected shapes, post a fresh quote
  from seq 2 and only then unhalt. Refilling remains explicit. Old queued posts from a still-authorized key can
  become newer again after a reset.
- **The fee cap doesn't close the race with takers.** It orders only transactions the builder has pending together: a
  take that reaches the builder before the re-quote, or lands in a block the re-quote misses, still fills the old
  quote. Across blocks, a short `validUntil` is the bound.
- **Simulate with fee fields.** A call or gas estimate without them never sees the cap, so an over-cap take simulates
  cleanly and reverts on chain.
- **Quotes go stale on every fill.** A quote holds only until the next fill on its side, and a venue's inventory is
  shared by all of its pairs.
- **The updater prices everything the venue can pay out**, including what a hook can pull from its vault, though it
  can't withdraw.
- **The venue trusts its settler.** `fill` doesn't re-check that the input arrived, so a settler that doesn't move it
  in can drain the venue at its own curve. A venue pointed at another settler still answers its views, but its fills
  through this `Settler` revert `NotSettler`.
- **Hooks are trusted code.** A hook can block its pair, and a 0 from `hookLiquidity` doesn't prove it empty.
- **Transfers must land exactly.** Payouts, `withdraw` and `hookTake` check the exact debit and credit, so a fee, a
  TIP-1022 forward or a TIP-1028 park reverts instead of landing elsewhere. Nothing in v2 resolves an address. A
  token's own controls (its transfer policy, pause) apply to every venue transfer.

## Gas

These tables measure fresh local builds with Foundry v1.8.1 and Solar `d83529b` (the revision in `solar.lock`),
not the deployed solc-built mainnet core. The compiler migration does not upgrade immutable contracts or their clones;
these savings require a new Solar-built deployment. Estimate gas against the actual target deployment before sending.
The pre-migration tables
record the earlier solc test measurements, not live transaction estimates.

### On Tempo

Gas per transaction under Tempo's gas schedule, with TIP-1000 storage pricing and the 21,000 base, on mock tokens.
A swap is one 100 EUR fill through the `Settler` on a pair that has traded before.

| Call | Gas |
| --- | --- |
| `swapExactIn` / `swapExactOut`, `Open` | 104,108 / 109,514 |
| `swapExactIn` / `swapExactOut`, `Open`, under a taker priority-fee cap | 104,171 / 109,640 |
| `swapExactIn` / `swapExactOut`, `Listed`, home list | 106,442 / 111,848 |
| `swapExactIn` / `swapExactOut`, `Listed`, home list, an account denied | 108,625 / 114,031 |
| `swapExactIn` / `swapExactOut`, `Listed`, sponsor list | 111,096 / 116,502 |
| `swapExactIn` / `swapExactOut`, `Listed`, sponsor list, an account denied | 113,279 / 118,685 |
| `post`, 1 pair (updater): no refill / refilling both sides / one side | 36,385 / 43,207 / 43,238 |
| `addPair` | 1,053,561 |
| `createVenue` | 1,114,312 |
| `setMembers`, 1 new: home list / sponsor list | 286,881 / 289,374 |
| `setDenied`, 1 new (updater) | 291,239 |
| `setMembers`, 50 new / 100 new (`MAX_BATCH`) | 12,784,889 / 25,540,485 |
| `addSponsor` (new slot) / `resetSponsor` | 283,581 / 37,095 |
| `setPairSponsor`: admit (new slot) / remove (updater) / re-admit | 288,095 / 38,764 / 38,795 |
| `setSponsorEnabled`: off (updater) / on | 36,215 / 34,032 |
| `closePair` (updater) / `setPairAccess(Listed)` | 35,985 / 34,097 |
| `setMaxTakerPriorityFee` / `enableTakerPriorityFeeCap` (updater) | 35,510 / 35,335 |
| Core deployment: `Venue` implementation / `VenueFactory` | 12,967,040 / 978,110 |

- Each fill rewrites its pair's consumed-depth slot, about 5,600 gas (6,000 exact out, whose `quote` reads it first).
  A refill adds about 6,800 to a `post`; a post without one never touches the slot.
- Each new member, denial, sponsor or admission creates a storage slot, about 250,000 gas. Switching a sponsor off and
  removing it from a pair keep their slots, so restoring either is a rewrite. Delisting clears the member's slot, so
  listing that account again creates it anew.
- A sponsor's list costs about 4,700 more per swap than the home list, the home list about 2,300 more than `Open`, and
  any denial on the venue about 2,200 more. The cap reads no extra slot: 63 more exact in and 126 exact out.
- `addPair` creates four slots. `createVenue` writes the 77-byte clone and two slots.
- 100 new accounts in one `setMembers` or `setDenied` come close to Tempo's 30M transaction cap. If your client sets
  the gas limit above its estimate (Forge uses 130%), send 50 at a time.

### Standard EVM pricing

The same calls without Tempo's TIP-1000 storage surcharge, so a row that creates storage reads far below its Tempo
cost. Pairs are `Open` unless the row names a list; the four access-path rows share one pair.

| Call | Gas |
| --- | --- |
| `post`, 1 pair / 6 pairs | 36,385 / 72,490 |
| `post`, 1 pair, with a mid band on another of the venue's pairs | 38,595 |
| `post`, 1 pair, refilling both sides / one side, after fills on both | 43,207 / 43,238 |
| `setShape`, redefining a ten-level shape in place | 63,230 |
| `addPair` | 130,761 |
| `createVenue` (the clone and `initialize`: no sponsor, no list) | 122,288 |
| `setMembers`, 1 new: home list / sponsor list | 54,681 / 57,174 |
| `addSponsor` / `setPairSponsor`, admit (new slots) | 51,381 / 55,895 |
| `setMaxTakerPriorityFee` / `enableTakerPriorityFeeCap` (updater) | 35,510 / 35,335 |
| `swapExactIn` | 106,474 |
| `swapExactOut` | 111,880 |
| `swapExactIn` / `swapExactOut`, priority fee at the venue's cap | 106,537 / 112,006 |
| `swapExactIn` by access path: `Open` / home list / sponsor list / home list, one account denied | 108,632 / 110,966 / 115,620 / 113,149 |
| `swapExactIn`, no-op hook | 117,826 |
