# Managed propAMM

Managed propAMM lets a maker trade several token pairs from one pool of maker-owned inventory on Tempo.
An oracle supplies each pair's price, checked for freshness and deviation from prior prices; the maker chooses who may trade. Every pair using a token draws
from the same token balance. Owners may attach hooks: callback contracts that supply fee policy and run
before or after swaps.

This guide covers integration with three core contracts: `ManagedDirectPropAMM`, `Settler` and
`PoolFactory`. Their source and [interfaces](interfaces/) define exact behavior; the
[managed specification](../../../spec/propamm-managed.md) explains the design and invariants.

**Status:** these three contracts and their interfaces were audited by Sigma Prime at commit `0569025`, with no
vulnerabilities found ([audits](../../../audits/README.md)).
Routers and hook implementations were out of scope. Deployed code is immutable; owners manage pool configuration.

## Deployments

### Tempo mainnet (chain ID 4217)

Deployed on 2026-11-20 from `bdeb16b`, whose managed sources match the audited commit `0569025`. The three core
contracts have verified source.

| Contract | Address |
|---|---|
| PoolFactory | [0x61e5C6b8B737930d07025eC88B34B307F61e162c](https://explore.tempo.xyz/address/0x61e5C6b8B737930d07025eC88B34B307F61e162c) |
| Pool implementation | [0xa12a02d2917c4EFb4d4BFAf2fCca17c7Ab55215b](https://explore.tempo.xyz/address/0xa12a02d2917c4EFb4d4BFAf2fCca17c7Ab55215b) |
| Settler (the factory's default) | [0xf8Ed0Ed4D960f1F400400dA717Aba69708049595](https://explore.tempo.xyz/address/0xf8Ed0Ed4D960f1F400400dA717Aba69708049595) |

The deployer holds no role in this core, and the deployment created no pool, pair or inventory: each maker creates
its own pool with `PoolFactory.createPool(owner, salt)`. See the
[mainnet manifest](../../../deployments/tempo-mainnet/managed-core.json) and the
[deployment record](../../../docs/deployment.md#mainnet-core).

## Why this is useful for Earn vaults

Earn vaults convert between yield-bearing assets and the stablecoin used for deposits and redemptions.
Oracle-priced liquidity makes those conversions predictable: the oracle sets the rate, and available
inventory sets the executable size. Hook fees and rounding determine the final amounts.

Using a consistent price reference for swaps and net asset value (NAV) calculations helps align
execution with the vault's valuation. For example, an Earn/Veda vault can convert pathUSD deposits
into PRIME and sell enough PRIME to cover a pathUSD redemption. Vault accounting reconciles both
PRIME and pathUSD holdings at that valuation boundary. See the
[Earn/Veda integration](../../../docs/veda-integration.md).

## Contracts

| Contract | Role |
|---|---|
| [ManagedDirectPropAMM](ManagedDirectPropAMM.sol) | One maker's inventory, oracle configuration, access lists, rounding credits and swaps across its pairs. |
| [PoolFactory](PoolFactory.sol) | Permissionless creation of immutable pool clones and proof of their factory origin. |
| [Settler](Settler.sol) | Shared approval and execution entry point for factory pools; transfers input directly from its caller to each pool and pays output to that caller. |

The factory constructor deploys the pool implementation and default Settler. The pool owner controls
inventory, configuration, access, optional hooks and the selected settler.

## For makers

A pair is an added, not removed token-pair configuration; “live” below includes a pair that is `Closed`.
Each pair has two price anchors: reference oracle prices for base-to-quote and quote-to-base swaps.
The deviation limit compares a new price with the relevant anchor. A successful swap updates that anchor.
`Closed` blocks trades, `Listed` requires an allowlist and `Open` needs no listing (denials still apply).
Entering `Open` requires a paused pool. Switching to `Listed`, updating lists, enabling or admitting
sponsors and lifting denials take effect immediately, including while the pool is unpaused.

### Create and fund a pool

Call `PoolFactory.createPool(owner, salt)`. Anyone can create for any owner; the creator gets no special
rights. Creation initializes the clone atomically with that owner and the factory's `defaultSettler()`.
A new pool starts paused, with no pairs. `predictPool(creator, owner, salt)` predicts its address;
creator and owner are bound into the deployment salt.

Use `isPool(address)` to check origin. It verifies the clone's CREATE2 address against its embedded salt
and immutable implementation, without calling candidate code. Discover pools through `PoolCreated`
events, then inspect their live state.

1. Add each pair with `addPair`: base and quote tokens, oracle, maximum oracle age and maximum price deviation.
   Pair indexes start at 0 and are never reused; new pairs start `Closed`.
2. Approve the pool and call `fund` for a token used by a live pair. Funding works paused or unpaused.
   Every pair using that token shares the inventory.
3. Configure access and any optional hook. Move the pair to `Listed`, or enter `Open` while the pool is paused.
   Leaving `Closed` validates a fresh oracle price and both directional price anchors, initializing missing anchors.
4. Call `unpause` to enable swaps across eligible pairs. Unpausing itself performs no oracle check;
   every swap still checks its pair's oracle and guards.

The owner can `pause` all swaps or `closePair` one pair.
Oracle, risk settings, hook configuration and `resetPriceAnchor` changes require that pair to be `Closed`,
even when the pool is paused. `refreshPriceAnchor` can update a live pair's directional anchor to a fresh
price within `priceToleranceBps` of the owner's supplied `expectedPrice`, bypassing the old anchor's deviation check.

Only the owner calls `fund` or `withdraw`. Withdrawals may take any token while paused or unpaused,
reducing available capacity without changing the oracle price. They require exact pool debit and
recipient credit, reject zero, the pool itself and TIP-1022 virtual recipients (addresses whose transfers forward to another account). The pool checks the
recipient as given.
Ownership transfers use `transferOwnership` and `acceptOwnership`; a pending owner has no owner powers.

### Choose who can trade

Each swap selects a `sponsorId`: 0 for the pair's home allowlist, or a nonzero ID for a sponsor,
a business administering its own per-pair taker lists.

| Pair mode | Eligibility |
|---|---|
| `Closed` | Nobody trades. |
| `Listed` | Caller must belong to the selected home list or an enabled, admitted sponsor's list. |
| `Open` | No listing needed; sponsor ID is not checked. |

Pool-wide denials override both listing and `Open`. The owner alone edits the home lists with `setMembers(..., sponsorId = 0, ...)`, registers
sponsors (`addSponsor`), enables them (`setSponsorEnabled`), admits their lists on pairs
(`setPairSponsor`) and changes denials (`setDenied`). Registering a sponsor does not admit it on a pair.

Use `takerAllowed(pairIndex, taker, sponsorId)` for boolean eligibility or `takerAccess` for the first
access refusal. These views do not prove the pool is unpaused, the oracle is usable or inventory is sufficient.
`TakerAccess.Allowed` is the successful result.

## For sponsors

After the owner registers and admits your sponsor ID, its admin calls
`setMembers(pairIndex, sponsorId, accounts, allowed)` to list or delist takers. A batch holds at most
100 accounts and is atomic. Only the sponsor admin edits that sponsor's lists, not the pool owner.
Listing requires an enabled sponsor admitted on that live pair; delisting remains available when disabled.

Disabling a sponsor or removing an admission preserves its lists; restoring access restores current
members. The owner can instead `resetSponsor` to a new admin and list-version counter (`generation`), invalidating every old
listing. Admin handover uses `transferSponsorAdmin` and `acceptSponsorAdmin`.

On `Open` pairs, a trade's sponsor ID is an unchecked label, not evidence of sponsor membership.

## For takers

### Quote and bind the trade

Quote for the address that will actually call the pool or Settler. Token amounts are integer base units;
oracle price precision and token-decimal conversion come from the pair configuration.
`direction` below is the boolean `baseToQuote`: true sells base for quote, false sells quote for base.

A rounding-credit route is `(pairIndex, taker, customerId)`. Integer conversion rounds output down or
required input up; residual value remains in that route for later trades in either direction.
Customer IDs are nonzero accounting keys chosen by the caller. Trade IDs label trades.

- `quoteExactInput(pairIndex, taker, direction, amountIn)` and `quoteExactOutput(..., amountOut)`
  ignore existing rounding credit.
- `quoteExactInputFor(pairIndex, taker, customerId, direction, amountIn)` and `quoteExactOutputFor`
  include that credit and return the projected credit afterward. Use these for execution estimates.
- All four return the raw oracle price and observation timestamp. Quotes check freshness and the directional
  anchor, but not access, pause or output inventory. A successful quote does not reserve liquidity.

Execution binds `expectedOraclePrice`, `oraclePriceToleranceBps` and `minimumOracleUpdatedAt`.
The oracle must return a nonzero price and timestamp, not be future-dated or older than the pair's
maximum age, and remain within the pair's deviation limit from that direction's anchor.
A successful swap moves only its direction's anchor to the observed price. Set the expected-price
tolerance and minimum timestamp from the observation you accepted; these bounds refer to the raw
oracle price, not a fee-adjusted execution rate.

### Execute a swap

Choose a trusted Settler independently of the pool owner, normally the factory's reviewed
`defaultSettler()`. Check that `pool.settler()` still equals it. Never approve arbitrary replacement
code merely because a pool owner selected it.

Approve the trusted Settler for input, then call `swap(pool, params)`, using
[IManagedDirectPropAMM.SwapParams](interfaces/IManagedDirectPropAMM.sol). Supply the pair, direction,
exact-input/output choice, amount, limit, sponsor, customer/trade IDs, deadline and oracle bounds.
The limit is minimum output for exact input or maximum gross input (including any hook fee) for exact output.
The return value is output for exact input or gross input for exact output.

The Settler accepts only clones of its factory's implementation. It pulls from its immediate caller
directly into the pool, verifies exact caller debit and pool credit, then calls the pool's settler-only
`fill`. Output goes to that same caller. It never escrows swap input or approves pools; existing
Settler donations cannot replace caller payment and are not swept. Exact-output input is quoted first,
and the fill must consume exactly that amount or revert `FillMismatch`.

Direct `swapExactInput` and `swapExactOutput` calls remain available: approve the pool instead, and it
pulls from and pays its caller. Standalone pools, constructed with factory zero, are not accepted by the
factory-scoped Settler even if their owner selects it.

### Optional hooks and fees

The owner may install one hook per pair, enabling independent stages with `setPairHook` while
the pair is `Closed`:

- `QUOTE`: static callback returning an input-token fee, capped at 1,000 basis points (10%).
  Fees default to zero. The hook supplies policy and any address-specific rates.
- `BEFORE_SWAP`: state callback after input settlement and final pricing, before payout.
- `AFTER_SWAP`: state callback after payout.

View calls (`supportedFlags` and `quote`) are capped at 200,000 gas; each state callback at 5,000,000.
Invalid responses, missing callback acknowledgments or failures revert the operation.
Callbacks receive final gross amounts and may add inventory. Each callback must preserve or increase
both pair-token balances; pool mutations are locked during execution.

Exact input charges `ceil(grossInput * feeBps / 10000)` and prices the remaining input.
Exact output grosses up credit-adjusted net input as `ceil(netInput * 10000 / (10000 - feeBps))`.
Output fully covered by accumulated credit needs no new input fee. Fees remain in the maker's shared inventory;
slippage limits include them.

**Hook state can change the quote.** View quotes and direct swaps call `QUOTE` before input arrives;
Settler fills call it after prepayment. The hook receives pair index, taker, direction, exact-input/output choice and requested amount.
A raw-balance-dependent hook can therefore return different fees across these paths even in one
transaction. For consistent policy, use its supplied context or independent policy state.
Bind slippage regardless; a changed required input makes a Settler exact-output swap revert.

## For routers

The Settler uses its immediate caller as the taker for access, hook fees, credits and payout.
A router trades under its own eligibility on each pair. It authenticates its users, checks their
eligibility through the pool's `takerAllowed` or `takerAccess`, and partitions customer IDs by user.
Routed credits are keyed by `(pairIndex, router, customerId)`. The router must authorize each user's use
of an ID so one user cannot spend another's rounding credit; the core treats IDs as caller-selected
accounting keys, not authenticated user identities.

The Settler executes only one pool swap per call, with exact input or exact output.
It does not provide split or multi-hop execution or route discovery.

## Trust and configuration

The owner can change the selected settler with `setSettler(nonzeroAddress)`; only the current address
may `fill`. The selected settler is custody-trusted: the pool relies on it to authenticate the taker
and verify prepayment. Approve a Settler you trust and check that the pool selects it.

The owner also chooses each pair's oracle and optional hook. Review their behavior and administration
alongside the pool configuration. [Operational guidance](../../../docs/deployment.md) covers deployment.
