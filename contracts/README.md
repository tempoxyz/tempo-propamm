# propAMM v1

propAMM v1 is a permissioned, oracle-priced venue on Tempo where a market maker trades its own inventory with
the takers it approves. Swaps use one oracle mid-price against inventory the owner funds and owns: there are no
liquidity shares, bonding curve or public deposits. `DirectPropAMM` holds one pair, with no spread or swap fee.
`ManagedDirectPropAMM` holds any number of pairs over one shared inventory, with one optional policy hook per pair
and taker lists that sponsors manage for their own users. Inventory decides whether a trade settles,
never its price.

> **Status:** the managed pool core was audited by Sigma Prime at `0569025` ([audits](../audits/README.md));
> hook implementations, routers and `DirectPropAMM` were not. There is no supported v1 deployment. Pools are immutable:
> the hook-based `ManagedDirectPropAMM` and caller-only managed Settler require new deployments, not upgrades.
> The managed Settler ABI now requires `swap(pool, params)`; see [swap guide](src/managed/README.md#execute-a-swap).
> The earlier managed-pool demo on the Moderato testnet uses pair-wide fees, not this version. No redeployment is recorded here.
> `DirectPropAMM` and propAMM v2 are unchanged.

The managed Settler is the separate settlement contract takers approve and call; it transfers input directly
into a pool before requesting its prepaid fill. Routers use the same entry point and trade as themselves.

> **Successor:** propAMM v2, in which makers post their own price ladders. See the [v2 guide](src/v2/README.md).

Deployment and operations are in [`docs/deployment.md`](../docs/deployment.md).

## At a glance

| Property | Design |
| --- | --- |
| Market model | Owner-funded bilateral inventory |
| Pricing | One oracle mid-price; no curve price impact |
| Spread and fees | No oracle spread. `DirectPropAMM`: no fee. `ManagedDirectPropAMM`: optional hook-quoted input fee, no hook means zero, at most 10% |
| Trade directions | Base to quote and quote to base |
| Order types | Exact input and exact output |
| Access | `DirectPropAMM`: taker and resolved-recipient allowlists. `ManagedDirectPropAMM`: per-pair modes, home and sponsor lists, and a deny list |
| Inventory limit | Available pool balance only |
| Oracle controls | Positive price, effective-timestamp freshness, future-time rejection, and a directional deviation guard |
| Quote binding | Caller deadline, per-swap oracle-price tolerance (`0` is exact), and minimum effective timestamp |
| Emergency control | `DirectPropAMM`: guardian or owner pauses. Managed pool: owner alone pauses and closes pairs. Only the owner unpauses |
| Upgradeability | None; each pool is a standalone deployment |

## How pricing works

The oracle returns `P`, the number of quote tokens per base token, with `oracleDecimals` decimals. Each pool (each
pair, on `ManagedDirectPropAMM`) derives:

```text
priceScale = 10 ** (baseDecimals + oracleDecimals - quoteDecimals)
```

A negative exponent or one above 77 is rejected (`UnsupportedDecimals`). For exact-input trades, using input
after any managed-pool fee ([Pair hooks and fees](#pair-hooks-and-fees)):

```text
base -> quote: quoteOut = floor(baseIn * P / priceScale)
quote -> base: baseOut  = floor(quoteIn * priceScale / P)
```

Exact-output trades apply the inverse formula and round the required input up. The caller's `minAmountOut` or
`maxAmountIn` is the taker's slippage bound, not a maker spread. On a managed pool, these bounds include the
fee: `minAmountOut` bounds output after fees, and `maxAmountIn` caps gross input including the fee.

A swap also takes `expectedOraclePrice` and `oraclePriceToleranceBps`. It executes at the live oracle price, but only
if that price is within the caller's symmetric tolerance of `expectedOraclePrice`; a tolerance of `0` requires
equality. The amount limit stays the final bound on what the taker pays or receives.

### Rounding credit

Sub-atomic value lost to integer rounding is carried as a credit on the swap's route, keyed by:

| Pool | Route |
| --- | --- |
| `DirectPropAMM` | `(taker, resolved recipient, customerId)` |
| `ManagedDirectPropAMM` | `(pairIndex, taker, customerId)` |

`customerId` is a nonzero `bytes32` label supplied by the caller, for example for a customer or subaccount.
It is not an onchain customer record, identity proof, secret or authorization. Reusing a label for the same
pair and taker shares that credit route; a different label keeps its credit separate.

The route's next trade consumes the credit before rounding again, so repeated or round-trip conversions at a
constant price conserve value apart from any managed-pool fees, and routes never share credit. Fees never become
rounding credit. `quoteExactInputFor` and `quoteExactOutputFor` return the exact result including the route's
credit; `quoteExactInput` and `quoteExactOutput` ignore credit and are conservative bounds.

### What pricing does not do

There is no inventory skew, size tier or curve slippage. `DirectPropAMM` has no bid/ask spread or swap fee;
managed pairs apply the hook-quoted input fee before oracle conversion. `maxPriceDeviationBps` is a circuit
breaker, not a spread.

## How inventory works

- Inventory is the pool's token balance. The owner adds to it with `fund(token, amount, memo)`, paused or not.
- `DirectPropAMM`'s owner withdraws only while the pool is paused. `ManagedDirectPropAMM`'s owner withdraws at any
  time ([Withdrawals](#withdrawals)).
- A trade that needs more output than the pool holds reverts in full (`InsufficientInventory`); there are no partial
  fills.
- Every transfer must move exactly the requested amount, so fee-on-transfer and redirected-output behaviour is rejected
  (`ExactBalanceDeltaFailed`).
- Inventory doesn't affect price. The only size limit is the pool's balance.

With no spread or per-trade limit, oracle quality and inventory sizing are the maker's main economic risk controls.

## Swap lifecycle

`DirectPropAMM`'s swaps:

```text
swapExactInput(baseToQuote, amountIn, minAmountOut, recipient, customerId, tradeId, deadline,
               expectedOraclePrice, oraclePriceToleranceBps, minimumOracleUpdatedAt)
swapExactOutput(baseToQuote, amountOut, maxAmountIn, recipient, customerId, tradeId, deadline,
                expectedOraclePrice, oraclePriceToleranceBps, minimumOracleUpdatedAt)
```

Quote first with `quoteExactInputFor(taker, recipient, customerId, baseToQuote, amountIn)` or `quoteExactOutputFor`,
and pass its `price` and `updatedAt` as `expectedOraclePrice` and `minimumOracleUpdatedAt`. Quotes check neither access
nor the pause. A swap then:

1. Requires the pool to be active (else `Paused`) and `deadline` not to have passed (else `DeadlineExpired`).
2. Requires `msg.sender` to be an allowed taker and `customerId` to be nonzero, resolves `recipient` through Tempo's
   TIP-1022 address registry, and requires the resolved address to be allowed and not the pool.
3. Requires a nonzero amount.
4. Reads a positive, non-future oracle price no older than `maxOracleAge` and within `maxPriceDeviationBps` of that
   direction's anchor.
5. Requires the price to be within `oraclePriceToleranceBps` of `expectedOraclePrice`, and its effective timestamp to be
   at least `minimumOracleUpdatedAt`.
6. Calculates the exact input or output with the route's credit and enforces `minAmountOut` or `maxAmountIn`.
7. Stores the route's new credit and moves only that direction's anchor to the price.
8. Pulls the input from `msg.sender`, pays the output, and checks the exact balance deltas on the pool and the resolved
   recipient.
9. Emits `RoundingCreditUpdated` and `TradeExecuted`.

The input transfer carries the memo `keccak256(abi.encode("SWAP_IN", customerId, tradeId))` and the output
transfer `keccak256(abi.encode("SWAP_OUT", customerId, tradeId))`. Swaps, `fund` and `withdraw` share one
transient reentrancy lock. `ManagedDirectPropAMM` uses its own access check in step 2, fee-inclusive math and
limits in step 6, and an additional event when a nonzero fee is charged ([Swaps and quotes](#swaps-and-quotes)).

## Taker approvals and Tempo access keys

Approve the pool for each swap exactly, in the same 0x76 batch as the swap:

1. Exact input: `approve(pool, amountIn)`, then `swapExactInput`, which consumes the allowance fully.
2. Exact output: `approve(pool, maxAmountIn)`, then `swapExactOutput`, then `approve(pool, 0)` to clear what the swap
   didn't spend.

Never leave a standing pool allowance on an account that has access keys. Tempo charges an access key's spending limit
when the key approves, not when the pool pulls with `transferFromWithMemo`. A key that approves only what its swap
spends stays within its limit, but a standing allowance, such as one the root key granted earlier, lets any of the
account's keys swap past it: on `DirectPropAMM` to any allowlisted recipient, on `ManagedDirectPropAMM` to the account,
from where the key can move the output under that token's own limit. Tempo accepts this for every allowance-based
contract, so the pools don't check the signing key.

## Oracle model

A pool accepts any `IPriceOracle`: `decimals()`, and `latestPrice()` returning a price and its effective timestamp. The
decimals are fixed for the pool's life, and a replacement oracle must match them (`OracleDecimalsChanged`). This
repository includes:

| Oracle | Behaviour |
| --- | --- |
| `ChainlinkPriceOracleAdapter` | Immutable adapter for an AggregatorV3 feed. Uses the report's observation `startedAt` as its effective timestamp, rejects invalid `startedAt`/`updatedAt` relationships, reports a non-positive or carried-over answer (`answeredInRound < roundId`) as price 0, which the pool rejects, and fails closed if the feed's decimals differ from those captured at deployment |
| `Chainlink18To8PriceOracleAdapter` | Accepts only an 18-decimal AggregatorV3 feed and returns 8-decimal prices, rounding down. Preserves the same observation-time and round checks as the unscaled adapter. Changes precision, not denomination; see the [replacement procedure](../docs/deployment.md#replace-an-8-decimal-pools-feed) |
| `OndoUSDYPriceOracleAdapter` | Read-only adapter for Ondo's USDY oracle wrapper price ([USDY pricing](#usdy-pricing)) |
| `PushPriceOracle` | Single-reporter oracle with nonzero prices, strictly increasing non-future source timestamps, and two-step ownership. The repository ships no reporter service or key |

Every swap binds to a caller-selected range around the price its quote returned and treats the quoted effective
timestamp as a lower bound. `oraclePriceToleranceBps = 0` binds the exact price; a nonzero value lets a non-atomic taker
accept a small live-oracle move. A price outside that range needs a fresh quote. The pool's own freshness, future-time,
deviation and amount checks still apply, and the deadline stops an old transaction from executing later.

Each direction has its own rolling price anchor. A successful trade advances only its direction's anchor, and a price
outside `maxPriceDeviationBps` of it reverts (`PriceDeviationExceeded`). Anchors start at zero and are set from the
oracle when the pool first unpauses (`DirectPropAMM`) or the pair first leaves `Closed` (`ManagedDirectPropAMM`). The
owner changes the oracle, freshness limit or deviation limit, and can deliberately reset an anchor, only while the pool
is paused (`DirectPropAMM`) or the pair is `Closed` (`ManagedDirectPropAMM`).

The deviation guard is a jump and operator-error circuit breaker, not an independent price oracle. A compromised
reporter and a party able to cause trades can move an anchor through repeated in-band steps. Production operation
therefore needs independent source validation, reporter monitoring, a short freshness limit suited to the source, and a
pool owner ready to pause (or its guardian on `DirectPropAMM`).

An oracle that prices in USD assumes the quote token is worth 1 USD. No pool checks that peg, so monitor it.

### USDY pricing

Ondo's [USDY oracle](https://docs.ondo.finance/developer-guides/usdy-instant-manager-integration#usdy-price-oracle)
wrapper's `getPriceData()` returns an 18-decimal USD price that Ondo computes on read from its rate schedule, and the
current block timestamp. `OndoUSDYPriceOracleAdapter` reads only that price and returns `block.timestamp` as
`updatedAt`. It never reads the oracle behind the wrapper (`rwaOracle()`), whose interface Ondo changes when it
replaces the source: the October 2026 move from `RWADynamicOracle`'s daily `ranges(i)` to a rate oracle that
accrues every second removed `ranges`, and the earlier range-walking adapter reverted `RangeNotFound(0)` on every
read.

Because the price is always current, a USDY pool's `maxOracleAge` never trips; the directional deviation limit and the
swap's quoted-price binding bound a wrong or overridden Ondo price. The price can move every second, so a quote at
zero price tolerance executes only in the block it was read in. The buffer helper quotes and swaps in one transaction;
an outside taker quoting off chain needs a tolerance of at least 1 bp. The deviation anchor moves with each trade, so a
direction left untraded for longer than its limit allows (about 50 days at 50 bps and Ondo's current rate) needs a
paused `resetPriceAnchor`.

The adapter must read a wrapper on its own chain: a Tempo contract can't read Ondo's Ethereum wrapper.
[`TempoMainnet.sol`](src/TempoMainnet.sol) pins Tempo mainnet's USDY token and USDY oracle wrapper; verify both against
Ondo's documentation before deploying.

## Roles and permissions

| Role | `DirectPropAMM` | `ManagedDirectPropAMM` |
| --- | --- | --- |
| Owner | Fund; withdraw while paused; taker and recipient allowlists; guardian; oracle and risk settings and anchor resets while paused; pause and unpause; ownership transfer | Fund; withdraw at any time; add and remove pairs; set pair modes; home lists; register, reset, switch on or off, and admit or remove sponsors; deny and lift denials; a pair's hook, oracle and risk settings and anchor resets while it is `Closed`; bounded anchor refreshes on a live pair; close pairs; pause and unpause; ownership transfer |
| Guardian | Pause | No guardian role |
| Sponsor admin | None | List its users on the pairs its sponsor is enabled and admitted on; delist on any pair; hand its lists to a new key |
| Oracle reporter | Publish newer observations to `PushPriceOracle` | Same |
| Taker | Swap while allowed | Swap for itself under the list its swap's `sponsorId` names |
| Recipient | Receive swap output, after TIP-1022 resolution, while allowed | None: a swap pays its caller |

- Ownership transfers take two steps: `transferOwnership`, then `acceptOwnership` from the new owner. Keep owner and reporter on separate keys, and put the owner behind a multisig.
  `DirectPropAMM` also has a separate guardian; managed pools do not.
- On `DirectPropAMM`, every authorized `pause()` or `unpause()` emits `PausedStateChanged`, even when the state doesn't
  change. `ManagedDirectPropAMM` emits it only when `paused` changes; no-op calls emit nothing. On
  `DirectPropAMM`, a real paused-to-active transition reads the oracle and sets or checks both anchors, so it reverts on
  a stale or deviated price. `ManagedDirectPropAMM`'s `unpause` checks no oracle.
- `DirectPropAMM`'s taker and recipient permissions are independent sets: every allowed taker can pay every allowed
  recipient. Recipient permission is stored for the resolved address. For tenant isolation, use separate pools.

## ManagedDirectPropAMM

`ManagedDirectPropAMM` serves several businesses, and several pairs, from one maker's inventory. Each pair
prices like one `DirectPropAMM` at zero fees; nonzero fees reduce the input entering its oracle and credit math.
Taker access follows v2's model ([v2 access](src/v2/README.md#access)): each business is a sponsor that lists
its own customers, the maker keeps a home list per pair, and a pool-wide deny list overrides both. A taker swaps
only for itself.

| | `DirectPropAMM` | `ManagedDirectPropAMM` |
| --- | --- | --- |
| Constructor | Tokens, oracle, address registry, owner, guardian, limits | `(owner, factory)`; factory zero for standalone; starts paused, with no pairs |
| Pairs | One, fixed at deployment | Any number, added and removed by the owner |
| Swap output | An allowed recipient, resolved through TIP-1022 | The caller |
| Withdrawals | Owner, while paused, pair tokens only | Owner, at any time, any token, never to a TIP-1022 virtual address |
| Oracle and risk changes | While the pool is paused | While the pair is `Closed` |
| Swap fees | None | Hook-quoted; owner selects the hook only while the pair is `Closed` |
| `unpause` | Reads the oracle and checks anchors | Checks nothing |

### Pairs

`addPair(base, quote, oracle, maxOracleAge, maxPriceDeviationBps)` (owner) returns the next `pairIndex`,
counting from 0; an index is never reused. Each pair has its own oracle, decimals and price scale, freshness and
deviation limits, directional anchors and rounding-credit routes, checked as `DirectPropAMM`'s constructor
checks them. The same tokens may form several pairs, either way round. A new pair starts `Closed`, with zero
anchors and no hook.

`removePair(pairIndex)` (owner, any mode) clears a pair's configuration and anchors. Its lists, admissions and credits
stay in storage, unreachable, and its tokens stay in inventory.

| View | Returns |
| --- | --- |
| `pair(pairIndex)` | The configuration; all zero, with `access == None`, for a removed or unknown pair |
| `pairHook(pairIndex)` | Hook and flags; rejects unknown or removed pairs |
| `pairCount()` | The next index; removed pairs still count |
| `tokenPairCount(token)` | How many live pairs use the token |

### Pair hooks and fees

The owner selects one optional hook with `setPairHook(uint16 pairIndex, address hook, uint8 flags)`,
only while the pair is `Closed`. `pairHook(pairIndex)` reads its address and flags. No hook means zero
fees and no hook calls. Clear with `setPairHook(pairIndex, address(0), 0)`. There is no native per-taker
fee table, setter or configuration event; hook selection emits `PairHookUpdated`.

A hook may implement `QUOTE`, `BEFORE_SWAP` and `AFTER_SWAP`. `QUOTE` runs as a static/view call and returns
`feeBps`; without `QUOTE` the fee is zero. The pool rejects rates above `MAX_HOOK_FEE_BPS = 1000` (10%). The state callbacks must acknowledge
their own selectors. `supportedFlags()` declares supported stages: `QUOTE = 1`, `BEFORE_SWAP = 2`,
`AFTER_SWAP = 4`. Unsupported bits are rejected. View calls have a 200,000-gas cap; state callbacks
have a 5,000,000-gas cap. Each response must be exactly one canonical ABI word.
`QuoteContext` contains `pairIndex`, `taker`, `baseToQuote`, `exactInput` and requested `amount`
(gross input for exact input; output for exact output, before route-credit adjustment).
`SwapContext` additionally carries sponsor, customer and trade identifiers, actual funding/payout caller,
input/output tokens and gross input/output amounts. Quote calls accept any named taker; they do not
authenticate that identity or grant access. Only execution authenticates the taker. Custom rates, defaults and administration
are hook policy, not pool storage. A hook can reject a trade but cannot grant core access or bypass oracle guards.

For the same trade, direct swaps and quote views run the quote hook before input arrives, whereas Settler fills
run it after input is prepaid. Policies based on raw pool token balances can therefore charge different fees
across paths; the quote context does not include the prepayment amount. Use trade context or independent hook
policy state for consistent fees. A changed fee may alter exact-input output within its slippage limit, or
revert a Settler exact-output swap with `FillMismatch` if its required input no longer matches the prepaid quote.

Direct swaps authenticate their caller. Managed Settler `swap(pool, params)`
use the Settler's immediate caller as taker for pool access, hook fees and credits. A router trades as itself,
not as its underlying user. Hook quotes see that router identity. On `Listed` pairs the router needs ordinary
list membership; `Open` admits any caller, subject to denial. The router must separately check its authenticated
user through pool access views; the core does not enforce underlying-user access or denial on routed swaps.

Hooks receive no pool-token custody or approval, expose no `hookTake` path and cannot decrease either
pool balance of either pair token during a callback. Each check compares the balances immediately before and
after that callback; the normal swap payout between callbacks is still permitted. The pool retains control of
exact transfers, fee rounding, route credits and fee-inclusive slippage. `beforeSwap` runs after input settlement and final pricing, before payout;
`afterSwap` runs after payout. The earlier `QUOTE` stage can select a fee that changes the finalized amounts;
neither state callback can reprice those amounts or reenter pool mutations. A reverting, malformed or
unacknowledged callback rolls back the swap. Hook authors must authenticate the calling pool.

The fee is always in the **input token**, retained in the pool's shared inventory. It has no separate claim
balance or claim function: the owner can withdraw it through ordinary `withdraw`.

- **Exact input:** the taker supplies gross input. The fee is `ceil(grossInput * feeBps / 10000)`; the remainder
  enters the existing oracle conversion and route-credit math. A tiny positive input can round entirely to a
  fee, leaving no fresh conversion value. Fees round up to a whole input-token atomic unit. Existing route credit
  then contributes to the output without another fee; if total output is zero, the swap reverts without charging.
- **Exact output:** the existing oracle and route-credit math first finds the required net input. Gross input is
  `ceil(netInput * 10000 / (10000 - feeBps))`, and the fee is `grossInput - netInput`. An output funded entirely
  by existing route credit needs no fresh input and pays no new fee.

For example, with a 1:1 oracle price, equal token decimals, no route credit and a 100-bps (1%) fee: an exact
input of 10,000 atomic units pays 100 units in fees and buys 9,900 units. An exact output of 9,900 units
requires 10,000 gross input units, including the same 100-unit fee. Integer rounding is upward in the input
token, not a second output fee.

Quotes use these same fee calculations. `amountIn`, approvals and `maxAmountIn` are gross, fee-inclusive
amounts; `minAmountOut` bounds the output after the fee. Raw oracle-price binding and directional anchors are
unchanged: the fee never adjusts the oracle observation. Zero fees retain `DirectPropAMM` pricing parity, and
fees change no access rule.

### Swaps and quotes

```text
swapExactInput(pairIndex, baseToQuote, amountIn, minAmountOut, sponsorId, customerId, tradeId, deadline,
               expectedOraclePrice, oraclePriceToleranceBps, minimumOracleUpdatedAt)
swapExactOutput(pairIndex, baseToQuote, amountOut, maxAmountIn, sponsorId, customerId, tradeId, deadline,
                expectedOraclePrice, oraclePriceToleranceBps, minimumOracleUpdatedAt)
```

- Both pay `msg.sender`; there is no recipient.
- `sponsorId` names the list the caller trades under: 0 for the pair's home list, or a sponsor's. It is checked on a
  `Listed` pair and is the caller's unchecked claim on an `Open` one.
- Checks run in `DirectPropAMM`'s order: `Paused`, the deadline, access, `customerId`, the amount, the oracle,
  the fee and credit math and the limit. At zero fees, pricing errors are `DirectPropAMM`'s, byte for byte; none
  names the pair.
- `TradeExecuted(pairIndex, taker, customerId, sponsorId, tradeId, tokenIn, tokenOut, amountIn, amountOut,
  oraclePrice, oracleUpdatedAt)` indexes the pair, the taker and the customer. Its `amountIn` is gross input. A
  nonzero fee also emits `HookFeeCharged(pairIndex, taker, token, amount)`; zero fees emit no fee event.
- Stateless quotes explicitly name the taker whose fees to use:
  `quoteExactInput(uint16 pairIndex, address taker, bool baseToQuote, uint256 amountIn)` and
  `quoteExactOutput(uint16 pairIndex, address taker, bool baseToQuote, uint256 amountOut)`. They ignore route
  credit, so they give conservative limits for that taker. These signatures replace the older managed-pool
  quotes without a taker argument; `DirectPropAMM`'s quote signatures are unchanged.
- Route-aware quotes keep their signatures:
  `quoteExactInputFor(pairIndex, taker, customerId, baseToQuote, amountIn)` and
  `quoteExactOutputFor(pairIndex, taker, customerId, baseToQuote, amountOut)`. They use that taker's fees and
  the credit at `roundingRouteKey(pairIndex, taker, customerId)`.
- All four quotes check no access or pause. They are pricing calculations, not executable
  guarantees: they neither reserve inventory nor prove access, sufficient inventory or successful token transfers.
  Quote for the effective taker (the direct caller, or the immediate caller of the Settler); for the [Veda buffer](../docs/veda-integration.md),
  that is the BoringVault, not its helper or an end user.
- Before swapping, call `takerAccess(pairIndex, taker, sponsorId)` ([Access](#access)) and simulate the complete swap.

### Shared inventory

Inventory is the pool's balance of each token, shared by every pair that uses it; there is no per-pair reservation.
`fund(token, amount, memo)` takes only a token some live pair uses (`UnsupportedToken`). One pair's flow can use up a
token another pair needs, and a wrong or compromised oracle on one pair can sell a token that backs another. Keep tokens
that back independent risk in separate pools, size each token for every flow it must cover, vault redemptions included,
and `closePair` or `pause` to stop a pair.

### Access

Access lives in the pool's own storage and calls nothing; there is no TIP-403 check. `Closed` blocks swaps,
`Listed` requires membership on the named list, and `Open` admits anyone not denied. Each direction's price anchor
is its last accepted swap price; a new price must remain within the pair's configured deviation limit.

- **Modes.** Each pair is `Closed`, `Listed` or `Open`. Only the owner sets the mode (`setPairAccess`), and enters
  `Open` only while the pool is paused (`NotPaused`). Only the owner can `closePair` at any time.
- **Home list.** Sponsor id 0 on each pair is the owner's: `setMembers(pairIndex, 0, accounts, allowed)`.
- **Sponsors.** The owner registers a sponsor under an id it picks (`addSponsor(sponsorId, admin)`: nonzero, registered
  for good; reuse a business's v2 sponsor id where it has one). A sponsor starts enabled and admitted on no pair. The
  owner alone switches it on or off (`setSponsorEnabled`) and admits or removes it per pair (`setPairSponsor`).
  Switching off and removal keep its lists, so restoring brings every member back.
- **Sponsor lists.** Only a sponsor's admin edits its lists: `setMembers(pairIndex, sponsorId, accounts, allowed)`
  lists only where the sponsor is enabled and admitted, and delists always. Only the admin hands its lists to a new key
  (`transferSponsorAdmin(sponsorId, newAdmin)`, then `acceptSponsorAdmin`). The nominee must be nonzero. To cancel a
  pending handover, the current admin calls `cancelSponsorAdminTransfer(sponsorId)` and checks that
  `pendingSponsorAdmin(sponsorId)` is zero after inclusion; transferring to `address(0)` reverts and cancels nothing.
  For a sponsor that lost its key,
  `resetSponsor(sponsorId, newAdmin)` (owner) gives it a new admin and voids every earlier listing, keeping its id,
  enabled state and admissions.
- **Deny list.** `setDenied(accounts, deny)` (owner only) overrides every list and
  `Open`. A TIP-1022 virtual address never calls, so deny its master instead.
- **Checking a taker.** `takerAccess(pairIndex, taker, sponsorId)` returns `Allowed` or the first refusal a swap would
  hit, in order: `UnknownPair`, `Closed`, `Denied`, `UnknownSponsor`, `SponsorDisabled`,
  `SponsorNotAdmitted`, `NotListed`. `takerAllowed` is `takerAccess == Allowed`. Neither covers the pool-wide pause, the
  oracle, inventory, or the tokens' own transfer policies.
- **Batches.** `setMembers` and `setDenied` take at most `MAX_BATCH` (100) accounts, and each batch is atomic. Send 50
  at a time from scripts, and remeasure worst-case batches before sending ([Gas](#gas)).

`Open` exposes oracle-priced inventory to any taker not denied, which increases oracle-latency adverse selection.

Pool-wide administration belongs to the current owner, is checked when used, and moves at `acceptOwnership`.
A sponsor's admin also widens access by listing users: watch `MemberUpdated`, and respond with a denial, a switch-off, a removal or
`closePair`.

Unlike a v2 venue, a managed pool has no updater role or taker priority-fee cap: only the owner pauses, closes pairs,
denies accounts, disables sponsors or removes admissions. Entering `Open` requires the pool-wide pause (v2: the halt); leaving
`Closed` re-checks the pair's oracle and anchors ([Closing and pausing](#closing-and-pausing)).

### Closing and pausing

`Closed` is a pair's own pause. A pair's `setPairHook`, `setOracle`, `setMaxOracleAge`,
`setMaxPriceDeviationBps` and `resetPriceAnchor` work only while it is `Closed` (`PairNotClosed`). A swap moves only
its own direction's anchor, so a direction nobody trades can drift past the deviation limit while the other trades on:
the owner's `refreshPriceAnchor(pairIndex, direction, expectedPrice, toleranceBps)` recovers it on a live pair, taking
the fresh price only within that bound, which holds at execution since the pair keeps trading. Leaving
`Closed` checks that pair: one fresh oracle read, then each zero anchor set
to the price, or each set anchor required within the deviation limit.

The pool-wide `pause()` (owner only) stops every swap on every pair and gates `Open`. `unpause()` (owner) checks
no oracle, so one pair's stale feed stops only that pair.

### Withdrawals

`withdraw(token, recipient, amount, memo)` (owner) works at any time, paused or not, for any token, so a removed pair's
inventory can leave. A withdrawal changes no swap's price, only whether it fits.

- It refuses zero and the pool (`InvalidAddress`) and any TIP-1022 virtual address, registered or not
  (`VirtualRecipient`: bytes 4 to 13 all `0xFD`). The pool holds no address registry and resolves nothing.
- It requires the pool's exact debit and the recipient's own exact credit, so a transfer the token takes a fee from,
  redirects or parks (a TIP-1028 receive policy) reverts.
- To pay a virtual address, such as a Bridge liquidation address, withdraw to an account and send it from there.
- It shares the swaps' reentrancy lock.

### Gas

Gas per isolated transaction under Tempo's gas schedule, from
`contracts/test/fork/managed/ManagedDirectPropAMMGas.t.sol` (Foundry 1.8.1, pinned Solar, `--network tempo`,
mock tokens and oracle, 21,000 base included). Swap measurements use a previously traded route, selling or buying
10 base tokens. Unless labeled otherwise, swaps have no hook. Custom callback costs depend on the hook.
Remeasure after a compiler or Tempo gas-schedule change; these are not production fee estimates.

Each new member, denial, sponsor, admission or pending admin creates a storage slot. Removing a sponsor from a pair
or switching it off keeps its slots; delisting or lifting a denial clears that account's slot.
A batch of 100 new members exceeds Tempo's 30M cap at Forge's 130% gas limit; use script batches of 50.
The standalone deployment's conservative gas limit, including the 1,208,812-gas estimate gap and Forge's 130%
multiplier, is 19,207,511.

| Swap | Exact input / exact output |
| --- | --- |
| `DirectPropAMM`, mapping allowlists, for comparison | 99,447 / 99,874 |
| `Open` | 99,847 / 100,281 |
| `Listed`, home list | 102,163 / 102,597 |
| `Listed`, home list, test quote hook at 100 bps | 109,994 / 110,475 |
| `Listed`, home list, an account denied | 104,346 / 104,780 |
| `Listed`, sponsor list | 106,807 / 107,241 |
| `Listed`, sponsor list, an account denied | 108,990 / 109,424 |

| Call | Gas |
| --- | --- |
| Deployment (no pairs) | 13,566,197 |
| `setPairHook`: first / replacement / remove / restore | 286,457 / 37,145 / 38,733 / 41,457 |
| `addPair`: two new tokens / known tokens | 1,308,761 / 814,161 |
| `setPairAccess(Listed)` from `Closed`: first / again | 552,244 / 46,444 |
| `closePair` | 31,280 |
| `removePair` | 68,538 |
| `setMembers`, 1 new: home list / sponsor list | 284,287 / 286,785 |
| `setMembers`: 1 delisted / 50 new / 100 new (`MAX_BATCH`) | 37,644 / 12,781,959 / 25,534,711 |
| `setDenied`: 1 new / 1 lifted | 284,423 / 40,005 |
| `addSponsor` / `resetSponsor` | 280,731 / 34,211 |
| `setPairSponsor`: admit / remove / re-admit | 285,488 / 33,962 / 36,188 |
| `setSponsorEnabled`: off / on | 31,144 / 31,156 |
| `transferSponsorAdmin` / `acceptSponsorAdmin` | 280,723 / 39,023 |
| `pause` / `unpause` | 27,761 / 27,834 |
| `fund` / `withdraw` | 56,593 / 46,922 |

The test hook's own two-direction fee configuration costs 282,098 gas on first configuration, 32,810 on update,
37,674 on clearing and 37,098 on restoration. These are external test-hook policy operations, not pool fee-table APIs.

## DirectPropAMMRebalanceController

`DirectPropAMMRebalanceController` is an optional owner for one `DirectPropAMM` or `ManagedDirectPropAMM`. It splits the
pool owner's authority between an offline owner key and a hot keeper key. The keeper can only send a token's inventory
to that token's liquidation address, fixed at construction: typically a Bridge liquidation address that converts the
token and pays another pool token back to the pool. A pool has one owner, so one controller serves every token it
rebalances. The controller takes ownership through the pool's two-step transfer, accepting with `execute`.

| Role | Authority |
| --- | --- |
| Owner (offline key) | Every pool owner call, through `execute(data)`, which calls only the pool. Set or clear the keeper with `setKeeper`. Transfer controller ownership through OpenZeppelin `Ownable2Step`; `renounceOwnership()` always reverts (`Disabled`) |
| Keeper (hot key) | `rebalance(token, amount)` only |

### Rebalancing

`rebalance(token, amount)` sends `amount` of `token` from the pool to `liquidationAddress(token)`. It pauses the pool,
withdraws and unpauses in one transaction, and reverts `PoolPaused` if the pool is already paused, so it never undoes a
pause by the pool's authorized pauser (the owner on managed pools; owner or guardian on `DirectPropAMM`). The keeper can't choose a recipient, unpause the pool separately, or make any other owner call.

- **`DirectPropAMM`** withdraws only while paused, and its `unpause` re-checks the oracle and anchors, so a stale or
  deviated price reverts the whole rebalance.
- **`ManagedDirectPropAMM`** withdraws paused or not and its `unpause` checks no oracle, so the keeper rebalances even
  while a pair's feed is stale.

The pool stays active between transactions; the converted inventory is available only once the liquidation address
pays it back. Each rebalance emits the pool's `PausedStateChanged(true)` and `PausedStateChanged(false)`: correlate them
with the controller's `Rebalanced` event in the same receipt rather than treating every pause event as an emergency
stop.

### Liquidation addresses

The constructor takes 1 to `MAX_TOKENS` (16) tokens, each once, with one liquidation address each: nonzero, and neither
the pool nor the controller. `tokens()` lists them, and any other token reverts `UnsupportedToken`. On a
`DirectPropAMM`, a liquidation address may be a TIP-1022 virtual address: the pool resolves it and requires the exact
credit on its master. A `ManagedDirectPropAMM` pays no virtual address, so for one the constructor refuses it
(`VirtualLiquidationAddress(token, liquidationAddress)`), registered or not; it tells the pool kinds apart by
`pairCount()`, which only a managed pool answers. To pay a virtual address from a managed pool, withdraw to an account
through `execute` and send it on.

Liquidation addresses are fixed. To change one, deploy a new controller and move pool ownership to it: through the old
controller, `execute` the pool's `transferOwnership(newController)`, then through the new one, `execute` the pool's
`acceptOwnership()`.

### Keeper risks and owner controls

- A compromised keeper can send the full balance of any of the controller's tokens to its liquidation address. It can
  empty one side of the pool while conversion is pending and incur conversion fees or spread on repeated round trips; on
  a managed pool, a token every pair shares empties for all of them.
- The liquidation address's provider controls its payout and refund destinations outside the contract. A wrong or
  compromised route loses whatever is sent to it, so keep credentials that can change those destinations off the
  keeper machine.
- The managed pool owner (or `DirectPropAMM` owner/guardian) stops further rebalancing with `pause()`. On `ManagedDirectPropAMM`, `closePair` stops a
  pair's swaps but not rebalancing.
- The owner disables the keeper with `setKeeper(address(0))` or replaces it.
- Fund the pool with direct token transfers: `fund` would need the controller to hold and approve tokens. Tokens sent to
  the controller by mistake can't be recovered.

## Optional Veda buffer

`DirectPropAMMBufferHelper` is a stateless, optional adapter that builds Veda BoringVault management calls for a
quote-token vault that holds the pool's base token as a buffer. It holds no funds and has no pool or vault authority;
the vault's Teller executes its calls from the BoringVault, which is the pool's allowed taker and recipient. On a
`ManagedDirectPropAMM`, which the helper detects at construction (`managed()`), it serves one pair and one list
(`pairIndex`, and `sponsorId`: 0 for the home list, or a sponsor that lists the vault). Generated calls bind to the
current timestamp with zero oracle-price tolerance. The pools don't depend on Veda. See
[Veda integration](../docs/veda-integration.md) for the permission and NAV model.

## Security controls and known limitations

Implemented controls:

- default-deny access: `DirectPropAMM`'s taker and resolved-recipient allowlists, and `ManagedDirectPropAMM`'s per-pair
  modes (new pairs start `Closed`), lists and deny list;
- owner-only managed pause, unpause and per-pair `closePair`; `DirectPropAMM` also permits guardian pause;
- owner-only withdrawal: on `DirectPropAMM` only while paused, on `ManagedDirectPropAMM` at any time, never to a
  TIP-1022 virtual address;
- stale, future, zero-price and directional-deviation rejection;
- quote deadlines, caller-selected oracle-price tolerance and minimum effective-timestamp binding;
- caller min/max execution bounds;
- exact input, pool-output and recipient-output balance checks;
- reentrancy protection;
- fixed oracle decimals across oracle replacement; and
- two-step ownership transfer.

Production blockers and design limits:

- no protection from oracle-latency adverse selection; `DirectPropAMM` has no spread or fee, and managed-pool
  fees do not guarantee protection;
- no per-fill, rolling-volume, inventory-exposure or customer notional caps;
- no independent reference oracle, confidence-band check or automatic source/push divergence check;
- no protocol default for freshness: `DeployUsdyPool` defaults `maxOracleAge` to 90,000 seconds,
  `DeployParPool` to 30 days, and `DeployUsdcePools` and `DeployManagedPool` require a value. Observation feeds should use a shorter source-appropriate limit, the USDY adapter always reports the current time, and the chosen policy should be documented before meaningful inventory is added;
- a rolling anchor that repeated in-band trades can ratchet;
- zero price tolerance forces a fresh quote after any oracle repricing, including USDY's per-second accrual, but price
  binding doesn't prove that the oracle source itself is correct;
- single-key owner and reporter roles (plus guardian on `DirectPropAMM`) unless operations put them behind stronger controls;
- `DirectPropAMM`'s independent taker and recipient allowlists rather than pairwise authorization;
- `ManagedDirectPropAMM`'s shared inventory: one pair's flow or oracle can use up a token another pair needs
  ([Shared inventory](#shared-inventory)); and
- Tempo access-key spending limits don't bound a pull from a standing allowance: takers approve each swap exactly, in
  its batch ([Taker approvals](#taker-approvals-and-tempo-access-keys)).

Report vulnerabilities to [security@tempo.xyz](mailto:security@tempo.xyz). See the
[deployment runbook](../docs/deployment.md) for preflight and emergency procedures.

## Contracts

| Contract | Purpose |
| --- | --- |
| [`DirectPropAMM`](src/DirectPropAMM.sol) | One pair's inventory, quoting, permissions, settlement, pause and price guard |
| [`ManagedDirectPropAMM`](src/managed/ManagedDirectPropAMM.sol) | Many oracle-priced pairs with optional hook-quoted input fees over one shared inventory, with per-pair modes and home lists, sponsor lists and a deny list; swaps pay the caller, and the owner withdraws without pausing |
| [`PushPriceOracle`](src/PushPriceOracle.sol) | Reporter-fed oracle with monotonic source timestamps |
| [`ChainlinkPriceOracleAdapter`](src/ChainlinkPriceOracleAdapter.sol) | AggregatorV3 adapter |
| [`OndoUSDYPriceOracleAdapter`](src/OndoUSDYPriceOracleAdapter.sol) | Read-only Ondo USDY wrapper-price adapter |
| [`DirectPropAMMBufferHelper`](src/DirectPropAMMBufferHelper.sol) | Optional Veda BoringVault management-call builder |
| [`DirectPropAMMRebalanceController`](src/DirectPropAMMRebalanceController.sol) | Optional owner of either pool kind, with an offline owner key and a hot keeper that sends each token's inventory only to its fixed liquidation address |
| [`TempoMainnet`](src/TempoMainnet.sol) | Library of the Tempo mainnet addresses the deploy scripts pin |

The interfaces are in [`src/interfaces`](src/interfaces); `IManagedDirectPropAMM`'s NatSpec documents every managed
call, error and event.

## Managed factory and settlement

Managed settlement uses factory clones, address-only provenance, one shared default Settler per factory
and owner-replaceable settlement. Its only execution entry point, `swap(pool, params)`, executes one
exact-input or exact-output trade. It does not provide split or multi-hop execution or route discovery.

The immediate caller supplies and receives every token and selects permissions, hook fees and credits.
A router therefore trades as itself under the ordinary pool access rules, not a special trust grant.
It must separately check underlying-user eligibility using pool access views; the core does not enforce
that router-side policy. Quote for the router. Its credits use `(pairIndex, router, customerId)`; the router
must partition and authorize customer IDs consistently if it serves multiple users. Customer IDs grant no access.
Neither pool nor Settler implements user-signature verification or identity forwarding.

This is an ABI break from the explicit-taker draft: rebuild callers for the two-argument Settler swap.
Router-trust and forwarded-fill APIs are removed. This version is the audited core; it needs new immutable deployments and
does not change existing deployed contracts, direct pool swap APIs or propAMM v2. See the
[managed guide](src/managed/README.md#for-routers) for the integration boundary.


On the local Tempo harness, `ManagedRoutingGas.t.sol` measures 17,243,216 gas for the factory,
implementation and shared Settler deployment, and 1,119,106 for a clone. The core fits Tempo’s 30M cap
with the conservative 1,208,812-gas estimate gap added before Forge’s 130% gas-limit multiplier.
A settled exact-input swap uses 126,295 gas; the test router including user transfers uses 154,737.
Swap figures are warm-state measurements, not first-use or production fee estimates.
