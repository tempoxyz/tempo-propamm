# propAMM v2 — focused spec

Status: implemented on the main branch and audited by Sigma Prime at commit `459ccf7` (all findings resolved; [audits](../audits/)). The new `Registry` discovery sidecar is unaudited and not deployed; it is not covered by that historical audit. The contracts in `contracts/src/v2` and their NatSpec are the reference for exact behaviour; this spec gives the design and the reasons for it, and git history has its amendments. `contracts/src/v2/README.md` is the guide for makers, sponsors and takers, and `contracts/README.md` covers the v1 pools.

## Goals and non-goals

This spec covers five things. The first four are in priority order. Fill hooks come last but ship in M1, because venue clones can't be upgraded (section 5).

1. **General price curves, cheap to update.** A maker can express any sensible price-vs-size shape, and the frequent part of an update (moving the mid, widening, shrinking size) is a single storage write.
2. **Easy integration with the Tempo API** (`api.tempo.xyz`). propAMM plugs into the existing `/v1/exchange/quotes` flow as an exchange provider, with no new wallet-side work.
3. **One venue per swap.** Discovery can expose multiple venues for a token pair; each swap specifies one venue, pair index and amount.
4. **Benchmarking.** Every fill and every quote update is logged so that realized prices can be compared with a separately published on-chain reference mid.
5. **Fill hooks.** A maker can attach a hook to a pair, in the spirit of Uniswap v4 hooks, for example to keep passive inventory in a lending vault and move it into the venue only when a fill needs it.

Explicit non-goals for v2: on-chain aggregation or split-finding, multi-hop paths, a shared custody hub. The chain enforces each maker's curve and the taker's limits. The API discovers candidate venues, reads their live pairs and chooses one per swap.

RFQ is out of scope for this release.

## Architecture

```
Wallet -> Tempo API -> Registry (paged venues) -> live pairs -> candidate venue views at one block
Wallet -> approve + Settler.swapExactIn / swapExactOut(venue, pairIndex, ...) -> Venue -> optional pair hook
```


Three core contracts, plus an optional discovery sidecar and pair hooks:

| Contract | One per | Job |
|---|---|---|
| `Venue` | maker | Holds that maker's inventory for all their pairs (except what a pair hook keeps in a vault), their curves. Makers never share custody. Deployed as a minimal clone. |
| `VenueFactory` | chain | Creates venues: `createVenue(owner, salt)` clones the one immutable `Venue` implementation with CREATE2 (salt `keccak256(abi.encode(owner, salt))`, which the clone's code carries) and, in the same call, `initialize`s it with `owner` and the factory's `defaultSettler`. `predictVenue(owner, salt)` gives the address in advance. Permissionless, with no admin and no per-venue storage: `isVenue(venue)` proves a venue from its address alone, and the Settler makes the same check; the directory calls `isVenue` before registering. The implementation is deployed first, against the factory's predicted address, and accepts `initialize` only from the factory's deployed code. |
| `Settler` | chain | The one address takers approve. Moves tokens from taker to one venue, calls its `fill`, enforces the taker's amount bound and deadline. Holds no funds. Does no routing. Fills only venues the factory created, proved from the venue's address with no call to the factory: each venue's code carries its CREATE2 salt, and the venue must sit at the factory's CREATE2 address for it, where only the factory deploys. |
| `Registry` | factory (optional, not deployed) | Permissionless, append-only venue addresses. Page `venues(offset, limit)` (at most 100), then read live pairs, access, settlement and liquidity. Registration proves factory origin, not approval. |
| Pair hook | pair (optional) | A maker-chosen contract called around fills of one pair (section 5), for example one that keeps inventory in an ERC-4626 vault and moves it just in time. None ships with the repository. |

Why one `Venue` per maker instead of one pool per pair (v1) or a shared hub (previous proposal): a maker updating six pairs does it in one call with one auth check, which is where the update savings come from. Custody stays per maker, which keeps the trust story identical to v1. Without on-chain aggregation there is no reason to pool inventory.

A sponsor is a business whose admin lists its own users on the pairs the venue owner admits it to.
Each registered sponsor has a nonzero `sponsorId`; 0 names the home list edited by the venue owner.
A ladder is a sequence of price/size levels around a mid-price (quote tokens per base token). Consumed depth is
the base quantity already traded from one side. A hot word packs the current mid-price and ladder adjustments;
`post` is the owner/updater call that writes it. Its refill bits reset the selected side’s consumed depth, making
that side’s ladder available again. Section 1 gives the full encoding.
A pair hook receives optional callbacks before and after a fill. The `afterFill` callback can take that fill’s
input through `hookTake` only when the owner enabled its `TAKE_INPUT` flag; section 5 defines the limits.

### Zero and one conventions

Storage starts zeroed, a missing record reads as zeros, and a failed or ignored call can decode as zero, so zero never grants anything. Every v2 contract follows these rules (`AGENTS.md` has the repository-wide list):

1. **Enums and result codes:** 0 is `None`, never stored for a live record and never returned as an answer; real values start at 1. `AccessMode`: `None` 0, `Closed` 1, `Listed` 2, `Open` 3. `TakerAccess`: `None` 0, `Allowed` 1, then the refusals in `fill`'s order: `UnknownPair` 2, `PriorityFeeTooHigh` 3, `Closed` 4, `Denied` 5, `UnknownSponsor` 6, `SponsorDisabled` 7, `SponsorNotAdmitted` 8, `NotListed` 9.
2. **Ids:** 0 is the venue's own default, the home list (`sponsorId` 0). Registered sponsor ids are nonzero.
3. **Markers and version counters:** 0 means never written, and live values start at 1: `seq`, each sponsor's `generation`, the home list's constant generation 1, a pair's sponsor admission (`ADMITTED` 1, `REMOVED` 2). A removed state has its own nonzero marker, so the slot stays nonzero (TIP-1000 charges about 250k gas to create one).
4. **Stored sentinels** are nonzero, so writing one never creates a slot: `HotWord.INITIAL` (`seq` 1), the fresh consumption slot (`live` bit set).
5. **Bit flags:** 0 is no flags, and each flag is a power of two (hot-word flags, hook flags).
6. **Indexes** use 0 as a real value, the first entry: `pairIndex` and `shapeId` from 0. They never grant access, so this is deliberate: don't renumber them.
7. **Error and reason codes:** 0 is no error (`ShapeWord.check` returns 0 for a valid shape, else an `InvalidShape` reason from 1).

Quantities (amounts, `deniedCount`, `pairCount`) are numbers, not markers: 0 means none. A restriction reads 0 when absent (not denied, not halted, no mid band, no taker priority-fee cap, which is stored bit-inverted so a new venue's zero reads as `NO_PRIORITY_FEE_CAP`), which grants nothing on its own, since every grant needs a nonzero mode, listing or role. Per-account entries (members, denials, updaters) clear to 0 on removal, which reads as not listed; adding one back creates its slot again.

## 1. Price curves

### Model

A curve is a **ladder of price levels per side**, like a small order book, plus a handful of **scalars that reshape the whole ladder at once**. The ladder changes rarely. The scalars change every tick.

- Price is always *quote token per 1 base token*, 18 decimals.
- A pair admits only two distinct initialized Tempo TIP-20s that the canonical TIP-20 factory accepts. The factory
  rejects an unused reserved-prefix address, and the venue never probes token movement while validating a pair.
- Each side (bid = maker buys base, ask = maker sells base) has up to 10 levels. Level *i* has a size (how much base is available at that level) and a spread from mid.
- Spreads must be non-decreasing level to level, so the price only gets worse as size grows. The contract rejects shapes that violate this.
- Filling walks levels in order. Within a level the price is constant. This makes exact-input and exact-output both closed-form, with no square roots, and the off-chain router can reproduce the result bit for bit.
- Fills take depth off the ladder like orders off a book. Each pair stores, per side, how much base its fills
  have taken since the maker last refilled that side (`consumed(pairIndex)`: the bids lose what takers sell, the
  asks what they buy). A fill walks its side from that offset, so a later fill starts deeper and pays the worse
  levels, and adds the base it took. An opposite trade consumes the other side; it never gives any back. A side
  consumed to its depth fills nothing (`InsufficientDepth`, as any fill larger than the book) until refilled.
- Only the maker gives depth back, with a refill bit on a hot-word update (below): `post` clears that side's
  consumption, so it offers its whole ladder again. A post without one changes the price, spreads or shape and
  keeps the consumption, in base units, which then comes off the top of whatever ladder is now active.
- So splitting an order into several swaps, in one block or many, never beats one swap of the total: the parts
  walk the same book the whole would, and each rounds toward the maker on its own. Inventory and hook liquidity
  still bound payouts.

Ten stepped levels plus the scalars below cover flat quotes, sloped quotes, deep-then-thin books, and asymmetric books. A pluggable `ICurve` hook is deferred to a later milestone. It is separate from the fill hooks in section 5, which run around a fill and can't change its price.

### Shapes

A **shape** is one saved ladder: the levels for both sides of a pair. It holds the structure of the curve, meaning how much size sits at each spread. Shapes change rarely.

Each shape takes four storage slots, two per side. Each slot holds five levels of `(size uint32, spread uint16)`, so a side can have up to 10 levels.

- `size` is in a per-pair `sizeUnit`. With a unit of 1 EUR, the maximum is about 4.29B per level.
- `spread` is the distance from mid in 0.1 bp units, before any scaling or widening from the hot word below.

A maker can store **up to 256 shapes per pair** (`shapeId` 0–255) and switch between them with one hot-word write. Examples are normal, wide, weekend, off-hours, event risk, or a ladder per inventory band. Shapes are stored only when the maker defines them, so a maker pays only for the shapes they use. A `shapeId` that has never been defined reads as empty. It has zero size and fills nothing, so selecting it fails safe and `post` doesn't need to check it.

Shape examples, all built from the same ladder format:

- **Flat:** one level, e.g. "up to 200k at ±3 bp."
- **Sloped:** spreads rising evenly across equal sizes, e.g. 2 / 4 / 6 / 8 / 10 bp.
- **Deep then thin:** tight and large near mid, then a sharply wider tail.
- **Asymmetric:** different bid and ask ladders, for a maker leaning one way.
- **One-sided:** zero size on one side.

### Hot word

The **hot word** is one slot per pair, rewritten on every update. It chooses the active shape and moves or stretches it without rewriting the ladder:

| Field | Bits | Meaning |
|---|---|---|
| `mid` | 96 | Maker's mid, 18 dp (max ≈ 7.9e10) |
| `bidWiden` | 16 | Extra spread added to every bid level, 0.1 bp units |
| `askWiden` | 16 | Extra spread added to every ask level, 0.1 bp units |
| `widthScale` | 16 | Multiplier on all ladder spreads, 1/1000 (1000 = 1×) |
| `depthScale` | 16 | Multiplier on all ladder sizes, 1/1000 (0 = pull all size) |
| `shapeId` | 8 | Which stored shape to use (0–255) |
| `validUntil` | 40 | Unix seconds. Past this, the pair does not fill |
| `seq` | 32 | Increases on accepted posts. Owner-only reset while halted starts a new sequence at 1 |
| `flags` | 16 | Bit 0: bids off. Bit 1: asks off. Bit 2: refill bids. Bit 3: refill asks. Other bits reserved |

The owner can recover sequence exhaustion with `resetHotWord(pairIndex)` while the venue is halted. It restores
`HotWord.INITIAL` and emits `HotWordReset(pairIndex, previousSeq)`, preserving the pair's consumed depth and all
configuration. A fresh post is required before filling again. Stop quoting, revoke compromised keys and discard
queued posts before the reset; a still-authorized key's old posts could otherwise become newer again. Recreate the
SDK sequencer from the reset state. Event replayers apply `HotWordReset` as the initial word, with no refill.
Send the reset in its own transaction before fresh posts: `PostOutcome` refuses to attribute a receipt that resets a
pair it is attributing, because an identical pre-reset stale post and post-reset accepted post cannot be distinguished.

The refill bits are actions, not state. When `post` accepts the word, each one clears its side's consumed depth
and `post` emits `Refilled(pairIndex, bids, asks)` after the entry's `Posted`. The word is stored and emitted without
them, so a refill acts once: a bot that copies the stored word forward with a higher `seq` refills nothing, and an
entry `post` skips as stale refills nothing either. One bit per side mirrors the side-off bits and lets a maker give
back the side it has rebalanced (bought back the base it sold, say) without handing out more depth on the side it
hasn't; both bits together are a fresh ladder. Refill only with a quote that prices the inventory the fills left
behind. The updater can refill, as it can already offer more depth by raising `depthScale`.

Moving the mid, widening, pulling size, and switching regime (by changing `shapeId`) all cost one hot write.

The updater key prices all of the venue's inventory, including what a pair hook can pull just in time. The owner can bound it per pair with a **mid band** (`setMidBand(pairIndex, minMid, maxMid)`). An updater's `post` that would set a mid outside the band reverts. Asks never sit below mid and bids never above it, so the venue can't sell below `minMid` or buy above `maxMid`. The owner key isn't band-checked. A venue with no bands pays nothing for the check.

**Taker priority-fee cap.** A re-quote and a take can race for one block, and where the builder orders transactions by priority fee a take that outbids the `post` fills at the old quote. The owner or an updater caps the priority fee per gas, `tx.gasprice - block.basefee`, of any transaction that fills on the venue (`setMaxTakerPriorityFee(cap)`): above it `fill` and `quote` revert `TakerPriorityFeeTooHigh`. The cap is a quoting setting, not an access one, so an updater raises, lowers and removes it as the owner does: it pairs with the priority fee the updater's own posts pay, and raising it only lets a take that outbids a post fill the quote that post replaces, while the updater can already post any quote within the pair's mid band. The maker sends every `post` above the cap, so a builder that orders by priority fee puts no take pending with the post ahead of it. This needs no node change, unlike a privileged top-of-block lane (TIP-1147), but it orders only transactions pending together. Tempo's builder keeps admitting arrivals for its whole build budget and holds back a late one that tips more than the lowest tip its sub-pool has already included, so a take that reaches the proposer first, or a post that arrives mid-build, still leaves the old quote fillable; closing that gap needs a builder that sorts a window of arrivals by priority fee before executing it, or a lane. The cap is per venue, because one `post` reprices many pairs at one fee, and shares the settler's slot, so a fill reads no extra slot. A new venue has none (`NO_PRIORITY_FEE_CAP`). `enableTakerPriorityFeeCap()` sets the default, `DEFAULT_TAKER_PRIORITY_FEE_CAP` = 10 gwei per gas, in one call from the same roles and with the same event: a Tempo fee in a 6-decimal stablecoin is `gas * gasPrice / 1e12` units, so a 100,000-gas swap tipping at the cap pays 1,000 units, 0.1 cent, of priority fee. The cap is the first step of the fill's access check, so `takerAccess` reports it (`PriorityFeeTooHigh`) and `takerAllowed` is false for it: after pricing, so a pair that isn't live is `UnknownPair` whatever the fee, and before every check on the taker, because `quote` checks it too, at the same point, and has no taker; a `Settler` exact-out swap calls `quote` before `fill`, so an over-cap swap reverts `TakerPriorityFeeTooHigh` exact in or exact out, whatever the taker's access. The views read the calling transaction's own priority fee: an `eth_call` without fee fields has a gas price of 0 and never sees the cap, so a router simulates with the fees the swap will send. The TypeScript SDK's `Fees.takerFields(baseFee, cap, priorityFee)` validates the intended take and returns the fields to reuse unchanged for its views, simulation, gas estimate and submission.

### Pricing

Effective ask price at level *i*: `mid × (1 + (spreadᵢ × widthScale/1000 + askWiden) / 1e5)`. Effective size: `floor(sizeᵢ × sizeUnit × depthScale / 1000)`, floored per level. Bids mirror this. The venue can deliver at most its own balance of the output token plus what the pair's hook can add just in time (section 5). A fill that needs more than that, or more than the ladder has left past its side's consumed depth, reverts. Fills are never clipped. Each fill rounds once, toward the maker, by less than one unit of the rounded token. Selling base exact-in floors the quote out, and buying base exact-out ceils the quote in. When paying quote exact-in, the maker keeps as dust less than one base unit's price in quote.

### Update cost

Two Tempo rules set storage costs:

- **TIP-1000:** writing a storage slot that is currently zero costs **250,000 gas**. Overwriting a nonzero slot costs about 2,900.
- **TIP-1060 (T7), storage credits:** clearing a slot to zero earns the account that owns it one credit. In the default mode, a later zero-to-nonzero write by the same account is charged the full amount upfront. At the end of the transaction, 245,000 gas of that is refunded per credit the account holds. The net cost of a creation backed by a credit is therefore about 5,000 gas. Credits belong to the storage-owning account and can't be transferred.

Implications for the venue:

- **Net-new storage costs the full 250k once.** Adding a pair allocates four slots: its two configuration slots, its hot word and its consumption slot (both sides' consumed depth). Defining a shape allocates four slots, about 1M gas: about a cent at a 10 gwei gas price (a Tempo fee is `gas × gasPrice / 1e12` units of a 6-decimal stablecoin).
- **Fills and refills never create a slot.** The consumption slot is created nonzero by `addPair` and kept nonzero by every fill and refill, so a fill pays one cold read and one overwrite of it (about 5k) and never the 250k. A post without a refill bit doesn't touch it.
- **Churn is cheap.** Deleting a shape, or removing a pair, earns the venue credits that pay for the next shape or pair it defines. A maker can keep a rotating working set of shapes. Redefining a shape in place only overwrites.
- **Routine updates still never clear a slot.** `seq` is never zero, so a hot word is never zero. "Off" means `validUntil` is in the past or `depthScale = 0`. Clearing and recreating would be credit-neutral, but an overwrite (about 2.9k) is still cheaper than a credited recreation (about 5k). An overwrite also avoids the 245k of upfront gas headroom that a recreation needs.

Maker entry points:

```solidity
/// Packed: repeated [uint16 pairIndex][bytes32 hotWord]. Caller: owner or updater key.
/// A word with a refill bit clears that side's consumed depth (section 1).
function post(bytes calldata packed) external;
function setShape(uint16 pairIndex, uint8 shapeId, uint256[4] calldata words) external;
/// Owner only. (0, 0) clears the band.
function setMidBand(uint16 pairIndex, uint96 minMid, uint96 maxMid) external;
```

Measured gas, from `contracts/test/v2/integration/GasIntegration.t.sol` (standard EVM pricing, 21k base included; the [v2 guide's gas tables](../contracts/src/v2/README.md#gas) have the rest, and `contracts/test/fork/VenueAccessGas.t.sol` the Tempo figures):

| Update | Gas | Per pair |
|---|---|---|
| v1 `pushPrice`, 1 pair (an earlier v1 measurement, not pinned by a test here) | 35.5k | 35.5k |
| v2 `post`, 1 pair | 37,441 | 37.4k |
| v2 `post`, 6 pairs | 73,566 | ~12.3k |
| v2 `setShape`, redefining a ten-level shape in place | 65,057 | occasional |

Most of the per-transaction cost is Tempo's 21k base fee, so batching pairs into one `post` is the main lever. A maker quoting six pairs once a second spends about a third of what six v1 pushes would.

## 2. Tempo API integration

### What the API does today

The API's exchange quote routes and its provider interface:

- `GET /v1/exchange/quotes` tries the native stablecoin DEX first. Only if the DEX can't route does it call registered exchange providers, **in order, returning the first success**. It does not compare prices.
- A provider implements `quote(input)` and returns one of `ready` (calls to execute), `approvalRequired` (approve first, then re-quote), or `signatureRequired` (wallet signs EIP-712, then `POST /v1/exchange/quotes/execute` calls `finalizeQuote`).
- Before returning `ready` calls, the API simulates them and checks the account's token movements against the quoted bounds (`validateExecution`). Providers need no special trust.
- Provider quotes require `account`. Responses carry `provider`, amounts, gas estimate, and optional `meta.valuation` (currently ECB daily rates).
- `/v1/exchange/swaps` indexes only native DEX fills.

### The `propamm` provider

A planned provider, not yet built, configured with a verified `Registry` address (once deployed), or factory-event discovery. The API's existing propAMM provider serves v1 `DirectPropAMM` pools only.

`quote(input)`:

1. Page directory venues, read `pairCount()` and `pair(index)` for each, skip removed pairs, match tokens in either order and require the intended Settler. Apply the router's venue policy; directory registration is not approval. For each eligible candidate, make two reads pinned to the same block number. First, one Multicall3 `aggregate3` call (failures allowed): `hotWord`, `consumed(pairIndex)` (each side's consumed depth, where the next fill on it starts), `pair` (access mode, size unit, hook), `halted`, the output token's `balanceOf(venue)`, `hookLiquidity(pairIndex, tokenOut)` (the output the pair's hook can add, section 5, gas-capped by the venue and never reverting for a known pair), and `takerAllowed(pairIndex, account, id)` for the sponsor the authenticated API customer is, then 0 for the venue's home list; the first id it admits is the swap's `sponsorId`. `takerAccess(pairIndex, account, id)` runs the same check and returns its outcome (`TakerAccess`: `Allowed`, or the refusal `fill` would revert with, the first in its order when several apply: an unknown pair, a priority fee over the venue's cap, `Closed`, a denied account, an unregistered, switched-off or unadmitted sponsor, or an account the named list doesn't hold), so the same batch can carry it instead when the API reports why it can't route the account. The batch also reads `maxTakerPriorityFee`, the swap is sent with a priority fee at or below it, and the batch's `eth_call` carries those fee fields: without them the views see no priority fee and can't report the cap. Then `shape(pairIndex, shapeId)` for the shape id that hot word selects: it depends on the first read's result, so it can't share that batch, and pinning both reads to one block keeps the word and its ladder consistent, since a maker's next `post` can select another shape. The access fields don't cover the account's own TIP-1028 receive policy or a token-level policy. Simulation catches those.
2. Reject a pool that is expired, doesn't admit the account, or has no size. Compute its quote (section 3).
3. Return `ready` with the calls batched in one transaction: `approve(Settler, exactAmount)`, then `Settler.swapExactIn(…)` or `Settler.swapExactOut(…)`. Exact-output swaps add a final `approve(Settler, 0)`. `minOut` / `maxIn` come from the request's `slippageBps`. See "Approvals" below for why exact approvals are the default.
4. Throw `RouteUnavailableError` when nothing can fill, so the API moves on.

This uses the existing `ready` status, so wallets see nothing new. The simulation and validation path works unchanged because tokens flow from the account to venues and back to the account.

### Changes needed in the API core

| Change | Needed for | Size |
|---|---|---|
| None | M1 on pairs the native DEX doesn't list (EUR, MXN and other FX). The existing fallback path already reaches providers. | — |
| "Competitive" providers: query in parallel with the native DEX and pick the best output net of gas, instead of fallback-then-first-success | Pairs listed on both (USDC/USDT-style) | Small, in the API's quote handler |
| Optional `meta.pool` (venue, pair index) and `meta.benchmark` (quoted price vs reference mid, bps) on the quote response | Transparency, benchmarking | Schema addition |
| Index `Venue` `Fill`, `Posted`, `ShapeSet` and `Refilled` events in tidx (section 4 rebuilds curves and consumed depth from them), with their block timestamps for benchmarking, and serve fills from `/v1/exchange/swaps` (or a sibling endpoint) with `provider: propamm` | Benchmarking, partner reporting | Indexer and route work |

### Contract surface the API relies on

```solidity
interface ISettler {
    // amountIn for exact-in, amountOut for exact-out; sponsorId: 0 for the venue's home list, or a sponsor it registered.
    // Every output goes to msg.sender: a taker only swaps for itself.
    function swapExactIn(address venue, uint16 pairIndex, address tokenIn, address tokenOut, uint128 amountIn,
        uint256 minAmountOut, uint64 sponsorId, uint40 deadline, bytes32 ref) external returns (uint256 amountOut);

    function swapExactOut(address venue, uint16 pairIndex, address tokenIn, address tokenOut, uint128 amountOut,
        uint256 maxAmountIn, uint64 sponsorId, uint40 deadline, bytes32 ref) external returns (uint256 amountIn);
}

interface IVenue {
    // Only callable by Settler; Settler has already moved amountIn from the taker to this venue.
    // tokenIn and tokenOut must be the pair's two tokens; the venue derives the side from them.
    // Pays taker; checks the taker's access under sponsorId.
    function fill(uint16 pairIndex, address tokenIn, address tokenOut, uint128 amount, bool exactIn,
        address taker, uint64 sponsorId, bytes32 ref) external returns (uint128 amountIn, uint128 amountOut);

    function quote(uint16 pairIndex, address tokenIn, address tokenOut, uint128 amount, bool exactIn)
        external view returns (uint128 amountIn, uint128 amountOut);

    // fill's access check, without reverting. TakerAccess: None (0, never returned), Allowed (1), then fill's refusals
    // in its order (2 to 9): UnknownPair, PriorityFeeTooHigh, Closed, Denied, UnknownSponsor, SponsorDisabled,
    // SponsorNotAdmitted, NotListed. PriorityFeeTooHigh reads the calling transaction's own priority fee.
    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool);
    function takerAccess(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (TakerAccess);

    // Only callable by the pair's hook during its afterFill, with TAKE_INPUT set; only tokenIn, at most amountIn in total (section 5).
    function hookTake(address token, uint256 amount) external;
}

```

**Settler order per fill.** For exact input, `Settler` pulls `amount` from the taker into the venue, calls `fill`, and requires `amountIn == amount`. For exact output, it calls the venue's `quote`, pulls exactly the quoted input, calls `fill`, and requires `fill` to return the quoted input and the requested output. Each pull must raise the venue's balance of `tokenIn` by exactly the pulled amount before `fill` runs, so a token that returns true without delivering the input reverts the swap instead of releasing output. `quote` and `fill` both price from the side's consumed depth (section 1), and nothing moves it between the Settler's `quote` and its `fill`, so they agree; each fill then moves it, so the next swap on that side quotes deeper unless the maker refills. Either way the input is in the venue before `fill` runs, which the hooks in section 5 rely on. `fill` reverts if `tokenIn` and `tokenOut` aren't the pair's two tokens, so a fill can never be paid in some other token the venue happens to hold.

`ref` is a caller-chosen `bytes32` that is echoed into every `Fill` event. The API sets it to the quote ID (with the integrator in the high bytes), so realized fills can be joined back to the quote and the partner.

### Taker access

Access is held in each venue's own storage, per pair, per sponsor, per user: `[pairIndex][sponsorId][account] -> listed`. The venue calls no registry. A sponsor (any business that brings its own users: a fintech, broker or wallet app) is registered by the maker under an id the maker chooses (`addSponsor(id, admin)`), so the same business can carry the same id on every venue; the maker admits it pair by pair (`setPairSponsor`) and can switch it off venue-wide (`setSponsorEnabled`). Only the sponsor's admin lists its users (`setMembers`): not the maker, an updater or another sponsor. It can list only on pairs it is admitted on, only while switched on, and can always delist; switching off and removal keep its lists, so restoring restores every member. Removing a pair does not sweep its lists or admissions, but `isMember` and `pairSponsor` first confirm that the pair is live and report false for an unknown or removed pair without reading those retained maps. Id 0 is each pair's home list, which only the current owner edits. A venue-wide deny list (`setDenied`) overrides every list. Each pair is `Closed` (where `addPair` starts it), `Listed` or `Open` (entered only while the venue is halted). A taker only swaps for itself: there is no recipient, so no recipient check. Each swap names the sponsor the taker trades under, and `fill` checks, in order: the venue's taker priority-fee cap (section 1), `Closed`, the deny list, `Open` (no list read), then on a `Listed` pair the named list: the home list (id 0), or a registered, enabled sponsor admitted on the pair that has listed the taker there. `Fill` carries the `sponsorId`, so volume is attributed per sponsor. An updater can only narrow access (close a pair, halt, deny, switch a sponsor off, remove it from a pair).

**Owner and sponsor keys.** The owner hands the venue to a new key in two steps (`transferOwnership`, `acceptOwnership`). Before acceptance, only the current owner can call `cancelOwnershipTransfer()` to cancel the pending handover without changing the owner. A sponsor's admin is an account or a contract (a multisig, an onboarding contract). It hands its lists to a new key in two steps (`transferSponsorAdmin`, `acceptSponsorAdmin`); only the current sponsor admin can cancel with `cancelSponsorAdminTransfer`, and the maker can't move or cancel that handover. Both transfer functions reject a zero-address nominee and allow replacing a pending nominee. Both cancellation functions clear the nominee, preserve the current holder and lists, and emit the corresponding transfer-started event with a zero nominee, including when no transfer is pending. A sponsor that loses its key is reset by the maker (`resetSponsor(id, newAdmin)`): the id keeps its switch and admissions, every earlier listing stops admitting at once (each member stores the sponsor's `generation`), and the new key lists its users again, so the maker never takes over a sponsor's list. The deployment registers no sponsor.

**No address resolution.** Nothing in v2 resolves a TIP-1022 virtual address. A fill pays its taker and `withdraw` pays the address it is given, each with an exact-credit check, so a transfer the token forwards to a virtual address's master reverts instead of landing elsewhere.

### Approvals

Resolved by TIP-1060, live on Tempo since T7. **Default: an exact-amount approval, batched in the same transaction as the swap, and always drawn back to zero.** This is the same approve-then-swap pattern the API already uses for the native DEX.

Why it's cheap: the allowance slot is owned by the TIP-20 token, so any credit is earned and spent by the token.

1. `approve(Settler, X)` takes the slot from zero to nonzero. That is a creation: about 250k is charged upfront and one refund is left pending.
2. The swap spends the allowance to zero. That clear earns the token one credit, plus the ordinary 4,900 refund for undoing a same-transaction write.
3. At the end of the transaction, the pending creation is matched against the credit the token just earned, and 245k is refunded.

The net cost for the allowance slot is only a few thousand gas. The token's credit balance ends where it started, so this works whether or not the token held any credits beforehand.

Rules this implies:

- **Exact-input swaps:** approve exactly `amountIn`. `Settler` pulls exactly that amount, so the allowance reaches zero on its own.
- **Exact-output swaps:** the approval is `maxAmountIn` but the actual spend is lower, so the allowance wouldn't reach zero. Without a clear there is no credit to match, and the creation would be refunded only if the token already held a spare credit. The provider therefore appends `approve(Settler, 0)` as the last call. That costs one overwrite, earns the credit, and leaves no lingering allowance.
- **Approve each swap exactly, in its own batch.** Put the approval in the same 0x76 batch as the swap. Exact input: approve `amountIn`, which the swap consumes fully. Exact output: approve `maxAmountIn` and end the batch with `approve(Settler, 0)`, so nothing is left even when the price improves before the swap lands. Never leave a standing Settler allowance on an account that has access keys: Tempo charges an access key's spending limit when it approves, not when the Settler pulls (see "Known behaviour: access keys" below).
- **`Settler` only ever pulls from `msg.sender`.** A leftover allowance can't be used by a third party, but any of the account's access keys that may call the Settler can spend it.
- **Gas limits must include upfront headroom.** In the default refund mode, the transaction needs about 250k of headroom per creation even though most of it comes back. The API's `estimateGas` sees the full upfront charge, so no special handling is needed, but the fee payer's balance must cover it for the moment it is reserved.
- **One case the design can't make cheap: a first-time holder.** A recipient receiving a token for the first time creates their balance slot in that token. The 245k is refunded only if the token holds a spare credit. Established stablecoins earn credits whenever anyone empties a balance or allowance, so they will usually have one. A new, thin token may not, and then the recipient pays about 250k, about $0.0025 at a 10 gwei gas price. This applies to any transfer on Tempo, not just to propAMM.

### Known behaviour: access keys

Tempo charges an access key's spending limit when the key approves, by the increase, not when a contract later spends the allowance with `transferFrom`. Every Settler pull is a `transferFromWithMemo`, so a standing Settler allowance lets any of the account's access keys that may call the Settler swap past its limit. Venues are permissionless, so that includes swapping into a venue the key's holder created, at a price it posted.

This is accepted Tempo platform behaviour, the same for every allowance-based contract on Tempo (Uniswap v4 pools included): Tempo counts the approval as the spend. [tempoxyz/tempo#2503](https://github.com/tempoxyz/tempo/pull/2503), which charged limits on `transferFrom`, was closed unmerged, and an audit follow-up resolved the issue as a docs clarification. The Settler doesn't check which key signed a swap (won't fix), so a wallet that signs with a site access key can approve and swap in one batch. The mitigation is the approval rule above, or not giving access keys call scope over the Settler.

## 3. Single-pool quoting

The permissionless directory permits multiple venues offering the same token pair, including reversed base/quote
orientations. It stores venue addresses, never pair indexes; a venue can hold multiple distinct pairs. Consumers
read current pairs, skip removed ones and filter access and liquidity. The Settler accepts factory-created venues
independently of directory registration. There is no delisting or directory admin.

The API reads each candidate pool through the venue's views, expands the active shape with the hot-word scalars and walks
it from the side's consumed depth. Capacity is bounded by what the ladder has left past that depth, and by venue
inventory plus the pair hook's liquidity, with an optional haircut on the hook component. Repeat swaps walk on down
the same side and share the actual output inventory; a quote is only good until the next fill on its side.

Each transaction fills one pool atomically at its live curve. The Settler enforces `minAmountOut` or `maxAmountIn`
and the deadline. Exact output checks its maximum before pulling funds and requires the fill to match its quote.
There is no split routing. Solidity and off-chain pricing use shared test vectors.

## 4. Benchmarking against the reference mid

The reference mid is published separately. This spec only assumes it provides, per pair:

- an on-chain readable `(mid, updatedAt)`, and
- a `MidUpdated(pair, mid, timestamp)` event per update, so history can be indexed.

### What venues emit

```solidity
event Posted(uint16 indexed pairIndex, bytes32 hotWord);          // every accepted hot update, as stored
event Refilled(uint16 indexed pairIndex, bool bids, bool asks);   // after the Posted of an entry with a refill bit
event ShapeSet(uint16 indexed pairIndex, uint8 shapeId, uint256[4] words);
event Fill(
    uint16 indexed pairIndex,
    address indexed taker,
    bytes32 indexed ref,
    uint64  sponsorId,      // the sponsor the taker traded under (0: the venue's home list); the taker's unchecked claim on Open pairs
    bool   baseIn,
    uint128 amountIn,
    uint128 amountOut,
    uint96  makerMid,       // maker's posted mid at fill
    uint32  seq             // hot-word seq in force
);
```

`sponsorId` is not indexed: `pairIndex`, `taker` and `ref` use all three topics, so per-sponsor volume is filtered off chain. Id 0 names a different home list on every venue, and each venue binds its other ids to admin keys itself, so attribute per venue and check `sponsor(id)`.

`Posted` and `ShapeSet` together let the indexer rebuild every maker's full curve at any block. That means makers can be benchmarked on quote quality even when fills are sparse. `Fill` and `Refilled` rebuild each side's consumed depth too: a side's consumption is the base of its fills (`amountIn` when `baseIn`, else `amountOut`) since its last refill, so depth-at-X metrics can count only the depth a taker could actually get.

### Join rule

For each fill, the reference mid is **the latest `MidUpdated` at or before the fill's block and log index**. If that mid is older than a per-pair staleness bound (for example 5 s for FX), the fill is flagged `ref_stale` and excluded from headline numbers.

### Metrics

Let `p = amountQuote / amountBase` for the fill, `M` = reference mid, `m` = maker's mid. Signs are chosen so that positive means the taker paid.

| Metric | Formula | Answers |
|---|---|---|
| Realized cost (bps) | taker buys base: `(p/M − 1)·1e4`; taker sells: `(1 − p/M)·1e4` | What did the taker pay versus fair? |
| Mid bias (bps) | same formula with `m` in place of `p` | How far was the maker's mid from the reference? |
| Spread charged (bps) | realized cost − mid bias | How much was curve spread at that size? |
| Quote slippage (bps) | realized vs amount returned by `/quotes`, joined on `ref` | How much did prices move between quote and fill? |
| Markout (bps) at +1 s, +10 s, +60 s | cost measured against the reference mid at those offsets | Adverse selection. Mostly for makers. |
| Quote uptime | share of time the hot word is valid with non-zero depth | Reliability |
| Depth at X bps | base size available within X bps of reference, over time, from rebuilt curves | Liquidity quality |

Reports cut by maker, pair, size bucket, integrator (from `ref`), and day. Volume-weighted and median. These live in the Tempo API (tidx SQL) and can back a `/v1/exchange/propamm/benchmarks` endpoint and the quote-response `meta.benchmark` field.

### Possible on-chain guard (M3, not implemented)

A later version could let a pair read the reference mid at fill time and revert if `|m − M| / M` exceeds a bound. This protects consumers from a maker's fat-finger mid and puts `refMid` directly in the event. It would cost a few thousand gas per fill and tie fills to the reference feed's liveness, so it would be off by default and set per pair. If built: turn it on for consumer-facing FX pairs, fail open when the reference is stale, and emit a flag when it does.

## 5. Fill hooks and just-in-time inventory

A maker can attach one hook contract to each pair, in the spirit of Uniswap v4 hooks. Only the venue's owner key can install one, with `setPairHook(pairIndex, hook, flags)`. The updater key can't. The hook is generic. The venue only sees the interface below, so vault type never matters to the venue. Any strategy can sit behind it, such as an ERC-4626 vault, a Veda or Earn vault, or monitoring. Access control stays with the venue's access check.

```solidity
interface IVenueHook {
    struct FillContext {
        uint16 pairIndex;
        address taker; // receives the output
        uint64 sponsorId; // the sponsor the taker traded under
        bytes32 ref;
        address tokenIn;
        address tokenOut;
        uint128 amountIn;
        uint128 amountOut;
        bool exactIn;
        uint96 makerMid;
        uint32 seq;
    }

    function supportedFlags() external view returns (uint8);
    // Conservative token amount deliverable by beforeFill after input credit and consumption advance.
    function availableLiquidity(address token) external view returns (uint256);
    function beforeFill(FillContext calldata fill) external returns (bytes4);
    function afterFill(FillContext calldata fill) external returns (bytes4);
}
```

The flags are `BEFORE_FILL`, `AFTER_FILL` and `TAKE_INPUT`, which requires `AFTER_FILL`. `setPairHook` rejects flags the hook doesn't list in `supportedFlags()`, a hook without code, a nonzero hook with no flags, and a zero hook with nonzero flags. Each callback must return its own selector.

Order inside `fill`:

1. Check the caller, the tokens and the hot word, price the fill from the side's consumed depth, then check the taker's access, and add the fill's base to the side's consumption. The amounts and the new depth are final before any hook runs, so a hook can never change a price, and a hook that quotes mid-fill sees the depth after this fill.
2. Call `beforeFill`, if set. It may only add inventory. When it returns, the venue must hold at least as much of each fill token as before the call.
3. Pay the taker and check the exact balance changes of the venue and of the taker. If the venue is still short, revert. A TIP-1028 receive-policy redirect leaves the taker's balance unchanged, so it also reverts the fill.
4. Call `afterFill`, if set. With `TAKE_INPUT`, the hook may call `hookTake(tokenIn, x)` during this call, for at most `amountIn` in total. The window is open only to the pair's hook, only in the fill's input token, and it closes before `fill` returns. When `afterFill` returns, the venue must hold at least its `tokenIn` balance from before the call, minus what the hook took, and at least as much `tokenOut` as before the call.
5. Emit `Fill`.

So no fill can leave the venue holding less of any token than before, beyond the trade itself and the input its hook took back. Apart from `hookTake` during `afterFill`, hooks can't re-enter the venue, and they can't re-enter the `Settler` at all. A hook is trusted code chosen by the maker: it runs on every fill of its pair, can block that pair's fills, and adds its own protocol risk (for example vault illiquidity). Through the hook interface it can't affect other pairs. Outside that interface it can use any role its owner separately grants it on other venues.

**How routers see hook inventory.** `Venue.hookLiquidity` reports `availableLiquidity(tokenOut)` on its own, next to the venue's balance, so the router can haircut it (section 3). `Venue.quote` counts it toward what the venue can deliver. Both count it only when the pair's hook has `BEFORE_FILL` set, since only `beforeFill` can add inventory. The call is a `staticcall` capped at 1.5M gas, enough for a lending vault that spans many markets. Any failure or malformed return counts as 0, so a broken hook can hide its own liquidity but can never make `hookLiquidity` or `quote` revert.

The hook must report a conservative amount deliverable from its own withdrawable holdings after the fill's input
has been credited to the venue and the side's consumed depth has advanced. For exact output, the Settler calls `Venue.quote`, which
samples `availableLiquidity` before either change, while `beforeFill` runs after both. Exclude liquidity that
shrinks with those venue-state changes, such as a top-up target minus the venue's input balance or a limit derived
from its remaining depth; a truthful point-in-time figure does not meet this obligation. Same-transaction
quote/fill agreement depends on the hook honoring it. The view reserves no liquidity and does not guarantee a
later fill against intervening external changes, such as vault withdrawals or a pause.

**No reference hook.** The repository ships the hook seam, not a hook. A maker who wants one, for example to keep a pair token (such as OUSD) in an ERC-4626 vault so it earns yield and move it to the venue just in time, writes and audits it. The venue enforces the rules above around every callback, but not what the hook does with tokens elsewhere. Such a hook must check that its vault really received each deposit: under TIP-1028 a transfer the vault's receive policy rejects still succeeds and parks in the ReceivePolicyGuard, and a stock ERC-4626 mints shares for it anyway. Liquidity it reports must come from views that reflect real liquidity, with a bounded source for vaults whose views are expensive or don't (Morpho Vault V2's `max*` views return 0).

**Cost.** A no-op hook adds about 11.4k gas per fill: `contracts/test/v2/integration/GasIntegration.t.sol` measures 117,826 for a hooked exact-input swap against 106,474 without a hook (standard EVM pricing, local Solar build; not the deployed solc-built core). What a real hook adds on top depends on its vault; no hook ships here to measure. Pairs without hooks pay one flag check.

**Why the seam ships in M1.** Venues are minimal clones and can't be upgraded. Adding a hook seam later would mean every maker re-cloning and moving inventory.

## Milestones

**M1 — resting quotes, one venue per swap**
`Venue` (clone), `VenueFactory`, `Settler`; a separate permissionless `Registry` (not deployed); stepped ladders; batched `post`; venue-held access (home lists, per-pair sponsor lists, deny list, per-pair modes); fill hooks; `Fill`/`Posted`/`ShapeSet`/`Refilled` events; a BigInt JavaScript reference (`contracts/test/vectors/ladder-reference.mjs`) with shared vectors; and, in the Tempo API (not yet built), a `propamm` provider behind a flag, running on the existing fallback path for FX pairs.

**M2 — benchmarking**
Competitive-provider mode in the API; tidx indexing and benchmark reports; `meta.benchmark` on quotes.

**M3 — extensions**
`ICurve` hook for exotic shapes; on-chain reference-mid guard.

## Open questions

1. **Reference mid interface.** Does it publish per-update events with timestamps, as the join rule assumes? What staleness bound per pair?
2. **Size units and precision.** Is 0.1 bp spread granularity fine for stablecoin pairs, or do we need 0.01 bp? What `sizeUnit` per pair?
3. **Maker fees and protocol fee.** Is there a Tempo fee switch on `Settler` from day one (off by default)?
4. **Venue selection policy.** Multiple venues per maker and token pair are allowed. Which off-chain criteria should the API use to select candidates?
5. **Hook liquidity haircut.** How much of a hook's reported `availableLiquidity` should the router count? Should it be one global haircut, or a per-hook setting in the router's off-chain policy?
