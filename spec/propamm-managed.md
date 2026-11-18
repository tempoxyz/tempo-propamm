# Managed propAMM — focused spec

Status: audited by Sigma Prime ([audits](../audits/README.md)). Deployed code is immutable; owners manage pool configuration. Source revision: `0569025c72f3b569b2b981604245bfb8792adfe3`.

The three core contracts are [ManagedDirectPropAMM](../contracts/src/managed/ManagedDirectPropAMM.sol),
[Settler](../contracts/src/managed/Settler.sol) and
[PoolFactory](../contracts/src/managed/PoolFactory.sol), including their imported dependencies and
[interfaces](../contracts/src/managed/interfaces/). Their source is authoritative for exact behavior.
ManagedDirectPropAMM holds inventory and prices swaps; Settler executes caller-funded swaps;
PoolFactory creates pools. A taker is the account trading with the pool. Direct swaps pull input inside
the pool; prepaid fills instead run after Settler has already transferred and verified input.
Settler exposes only single-pool `swap(pool, params)`.
Exact input fixes gross input and bounds minimum output; exact output fixes output and bounds maximum
gross input. Net input means input after fees. A hook is an optional owner-selected callback contract.
A directional anchor is the last accepted oracle price for swaps in that direction.
The [managed guide](../contracts/src/managed/README.md) is the integration entry point.

## Design

The maker (pool owner) owns the inventory and selects an oracle for each pair. Oracle prices determine the
exchange rate; available inventory determines how much output the pool can pay. The owner and admitted sponsors (organizations with their own taker allowlists) control
access. Rounding credits carry fractional conversion value between trades, and optional hooks supply
fees and swap callbacks. One shared Settler per factory executes single-pool exact-input or exact-output swaps.

## 1. Architecture and lifecycle

A pool owns all its tokens. A pair stores its base, quote, oracle, decimal scale, freshness and deviation
limits, access mode, directional anchors and optional hook. Every pair using a token shares the pool's
actual balance of that token. A swap on one pair therefore changes the inventory available to other pairs.

The factory deploys one immutable pool implementation and one default Settler in its constructor.
Anyone can create an empty, paused clone for a named owner. The creator receives no authority merely
by deploying it. A pool's owner configures pairs, access, hooks and inventory, then unpauses it.
A standalone pool uses a zero factory and a valid owner in its constructor, and supports direct swaps.

Pair indexes start at 0 and increase monotonically. `addPair` creates a `Closed` (non-tradable) pair and caches token
and oracle decimals. Tokens must be distinct and nonzero; the oracle must be nonzero. The scale exponent `baseDecimals + oracleDecimals - quoteDecimals` must be between 0 and 77 inclusive. There can be 65,535 added indexes, including removed ones.

`removePair` is owner-only and needs neither closure nor a pool pause. It deletes the pair configuration,
anchors and hook and decrements token-use counts. Inventory and historical access and credit records remain associated with their original tokens and index.

The owner alone funds supported tokens and withdraws any nonzero token address, including stray or
removed-pair inventory, paused or not. Funding requires a token used by an existing, non-removed pair. Withdrawal rejects
zero, the pool itself and TIP-1022 virtual recipients (addresses that forward transfers to a registered master); it performs no
recipient lookup.
Ownership transfers in two steps: the current owner nominates, and the pending owner accepts.
Nomination alone grants no power.

Pool pause stops every direct swap and prepaid fill. Unpause enables trading; each swap checks its pair's active state and oracle. Pair closure independently stops that pair. Changing its
oracle, freshness/deviation limits or hook requires that pair to be `Closed`.
The owner's `resetPriceAnchor` also requires Closed: it replaces an anchor with the fresh oracle price
without comparing against the previous anchor. Entering `Open` (unrestricted access except denials)
requires a paused pool. Other access changes, including entering `Listed`, adding members,
enabling or admitting sponsors and lifting denials, take effect while unpaused. Leaving `Closed` checks
a fresh oracle and both directional anchors, initializing missing anchors and validating existing ones.

## 2. Roles and access

A sponsor is an organization whose admin maintains a taker list on admitted pairs.
Sponsor ID 0 is each pair's home list, edited only by the current pool owner.
Nonzero sponsors are registered by the owner, start enabled at membership-version counter (generation) 1, and initially have no pair
admissions. Only the owner enables/disables sponsors, admits/removes them on pairs, resets them,
changes pair modes, closes pairs, pauses, or edits the pool-wide deny list.

A registered sponsor admin alone edits its lists. Adding members requires an enabled sponsor,
admission and an existing, non-removed pair; delisting remains possible without those grants. An admin can nominate or cancel a successor; the successor must accept.
An owner reset selects a new admin, clears pending succession and increments the generation, invalidating
all prior memberships without iterating through them. Reset preserves enabled/admitted state.
Disabling or removing admission preserves memberships, so restoration restores current-generation grants.
Member and deny batches are atomic and capped at 100 entries.

Access modes are `None=0`, `Closed=1`, `Listed=2`, `Open=3`. Only missing/removed pairs read
`None`. The `takerAccess` view returns a `TakerAccess` enum result using this order:

1. Missing pair: `UnknownPair`.
2. Closed pair: `Closed`.
3. Pool-wide denial: `Denied`.
4. Open pair: `Allowed`, without inspecting the supplied sponsor.
5. Listed pair: for a nonzero sponsor, require registration, enabled state and pair admission;
   then require membership in the selected list at its current generation.

The home list is implicitly admitted and uses constant generation 1. Denials override both listing and
Open. `deniedCount` counts actual denied accounts, counting each denied account only once despite duplicate/idempotent batch entries;
the deny mapping is read during access only when that count is nonzero.

`takerAllowed` is exactly `takerAccess == Allowed`. These views report access eligibility; execution
also checks pause state, oracle pricing and inventory. `TakerAccess` starts with `None=0`, `Allowed=1`,
followed by `UnknownPair`, `Closed`, `Denied`, `UnknownSponsor`, `SponsorDisabled`,
`SponsorNotAdmitted` and `NotListed`. Pair indexes start at 0; sponsor ID 0 selects the home list.

## 3. Oracle pricing and rounding credit

Let `p` be the raw oracle price, quote per base in the oracle's decimal convention, and
`S = 10^(baseDecimals + oracleDecimals - quoteDecimals)`.
Define value multipliers `I,O` for raw token amounts:

- Base to quote: `I=p`, `O=S`.
- Quote to base: `I=S`, `O=p`.

The fresh observation must have nonzero price and timestamp, not be from the future, and be no older
than `maxOracleAge`. With `anchor` the stored anchor for the chosen direction, it must satisfy
`abs(p-anchor) <= floor(anchor * maxPriceDeviationBps / 10000)`.
Each successful swap moves only its own direction's anchor to the observed price.
The owner can reset a directional anchor from a fresh observation while Closed, or use
`refreshPriceAnchor` on any existing, non-removed pair with the same expected-price/tolerance formula described below.
Refresh intentionally bypasses the old-anchor deviation check.

Swap parameters also supply an expected price, tolerance, minimum observation timestamp and deadline.
Execution binds that observation:
`abs(p-expectedOraclePrice) <= floor(expectedOraclePrice * oraclePriceToleranceBps / 10000)`
and `updatedAt >= minimumOracleUpdatedAt`. Zero tolerance requires exact price equality;
tolerance above 10,000 bps is rejected. The deadline is inclusive: only `timestamp > deadline` fails.
These checks bind the raw oracle price.

Each swap also supplies customer and trade IDs; the latter labels transfer memos and events.
Credit carries rounding value across both directions for
`keccak256(abi.encode(pairIndex,taker,customerId))`.
The customer ID is a nonzero caller-selected accounting namespace. Each pair/taker/customer tuple has
its own credit balance, shared across its two swap directions.

For previous credit `C`, net input `n`, and desired output `y`, the mathematical rules are:

- Exact input: `y = floor((n*I+C)/O)`; `C' = n*I+C-y*O`.
- Exact output: `n = ceil(max(y*O-C,0)/I)`; `C' = C+n*I-y*O`.

Implementation uses full-precision division, remainders and carries instead of constructing overflowing
products/sums. Credit-only exact output may require zero new input and still passes access, oracle,
hook, limit and inventory checks.

Stateless quotes omit stored credit. `quoteExactInputFor` and `quoteExactOutputFor` use the specified
pair/taker/customer credit key (the rounding route) and return its next value.
Both forms price for the named taker and check oracle freshness and anchor deviation. Execution
additionally authenticates the caller and checks access, pause, observation bounds and payout inventory.

## 4. Optional hook fees and callbacks

The owner may select one hook and independently enable `QUOTE=1`, `BEFORE_SWAP=2` and
`AFTER_SWAP=4` on a Closed pair. Unsupported bits are rejected.
A nonzero hook must have code, be neither the pool nor virtual, and advertise every selected bit through
`supportedFlags`. Clearing the hook requires zero flags. A configured hook with zero flags receives no quote or swap callbacks; configuration still probes `supportedFlags`.

Only an enabled QUOTE callback selects fees; otherwise fees are zero. Its context contains pair index,
named taker, direction, exact-input/output mode and requested amount: gross input for exact input,
desired output for exact output.
A hook may reject a quote/trade. A returned fee `f` must not exceed 1,000 bps.

With `B=10000`, fees are input-token units:

- Exact input with gross amount `g`: `fee=ceil(g*f/B)`, then `n=g-fee` enters credit math.
- Exact output: compute required `n` with credit first, then
  `g=ceil(n*B/(B-f))` and `fee=g-n`.

Fees remain in the maker's shared inventory; credit math uses net input.
Credit-only output pays no new input fee. Slippage uses actual output and gross input.
Execution rejects zero requested amounts and zero resulting exact-input output.
A nonzero fee emits `HookFeeCharged`; `TradeExecuted.amountIn` includes it.

The selected hook/stages are snapshotted before pricing. After credit and anchor updates and input
settlement, BEFORE_SWAP runs with final gross amounts, then output is paid, then AFTER_SWAP runs.
Their context adds sponsor/customer/trade IDs, the actual taker as `caller`, tokens and final amounts.

Static hook calls receive at most 200,000 gas; each state callback receives at most 5,000,000.
Every response must be exactly one canonical ABI word; state callbacks must return their selector.
Failure, malformed response or excessive fee reverts.
Each callback separately snapshots both pair-token pool balances and forbids either from decreasing.

Direct quotes/swaps invoke QUOTE before input arrives; prepaid fills invoke it after input arrives.
Balance-dependent policies can therefore produce different fees.
Settler exact output first quotes required gross input, transfers it, then calls fill and requires that
same gross input result. A mismatch reverts.
Policies needing path-independent quotes must not infer fees from raw pool balances.

## 5. Direct and prepaid settlement

Direct swaps use `msg.sender` as taker, pull nonzero gross input from it and pay it output.
Input transfer requires a true return and exact pool credit. Output requires sufficient inventory and exact pool debit
and recipient credit. Transfer behavior that redirects, parks or taxes output fails these checks.
Transfer memos label swaps for reconciliation. Input/output memos hash `abi.encode("SWAP_IN"/"SWAP_OUT",customerId,tradeId)`.

Only the currently selected nonzero Settler can call pool `fill`. This prepaid path skips the input pull:
the pool trusts the Settler to authenticate taker and verify payment. The shipped Settler proves pool
origin before payment (section 7), pulls only from its immediate caller directly into the pool, and checks exact caller
debit and pool credit before fill. Swap tokens move directly between caller and pool.

Exact output first obtains the `quoteExactOutputFor` input quote and checks the maximum input, prepays that amount,
then requires fill to return exactly it (`FillMismatch` otherwise). Both swap modes verify the caller's
exact input debit and output credit after fill. Any later failure rolls back earlier token transfers,
credits, anchors, allowances consumed by transfers and hook state.

The owner can replace Settler with any nonzero address while trading is active. The selected Settler
is custody-trusted: the pool relies on it to authenticate the taker and verify prepayment. Takers should
approve a Settler they trust and check that the pool selects it.

## 6. Caller identity

The immediate caller is the taker for the swap's access, hook fee and credit key.
A router therefore trades as itself: it needs normal access and receives the tokens.
For a routed trade, the router authenticates its users, checks their eligibility, partitions customer
IDs by user and authorizes their use. Pool access and credit accounting apply to the router's address;
the core accepts caller-selected IDs without authenticating the underlying user. Allowing one user to
reuse another's ID lets that user spend the other's rounding credit.

## 7. Clone provenance and reentrancy

Factory deployment salt is `keccak256(abi.encode(creator,owner,salt))`, binding creator and owner.
CREATE2 clones embed that salt as their sole immutable argument in a 77-byte runtime: 45 bytes of
minimal-proxy code plus the 32-byte salt.
Factory `isPool` and Settler independently require that length, read immutable clone arguments from code without executing it, reject a
zero embedded salt, and recompute the expected address using the immutable implementation and factory.
This proves that a pool was deployed by that factory.

Creation initializes the clone in the same transaction. Initialization requires the immutable factory
as caller with deployed code, a nonzero Settler and an unset owner. The factory supplies its default Settler. The implementation itself,
constructor-initialized standalone pools and initialized clones cannot initialize again. The deployed-code check prevents factory
constructor-time initialization.

All mutable pool entry points share its transient reentrancy lock, including owner and sponsor
administration; callbacks cannot exploit administrative roles to mutate the pool mid-swap.
Settler's `swap` entry point uses a separate transient reentrancy lock.
