# Tempo mainnet deployment runbook

Operational procedures for the v1 pools; what each contract does is in the [v1 guide](../contracts/README.md). For
**propAMM v2** (Venue implementation, Settler, VenueFactory) and the Moderato demo venue, use [Deploy propAMM v2](v2-deployment.md).

| To deploy | Script | Procedure |
| --- | --- | --- |
| PRIME/USDC.e and USDY/USDC.e pools, final roles at deployment, vaults attached later | `DeployUsdcePools.s.sol` | [USDC.e pools](#usdce-pools) |
| A USDY/pathUSD pool | `DeployUsdyPool.s.sol` | [USDY pool variant](#usdy-pool-variant) |
| A par pool behind a `DirectPropAMMRebalanceController` | `DeployParPool.s.sol` | [Par pool with a rebalance controller](#par-pool-with-a-rebalance-controller) |
| A `ManagedDirectPropAMM` (many pairs over one inventory, with sponsor access) | `DeployManagedPool.s.sol`, `ManagedPoolAccess.s.sol` | [Managed pools](#managed-pools) |
| The price adapters a managed pool's pairs read | `DeployManagedOracleAdapters.s.sol` | [Deploy the pairs' price adapters](#deploy-the-pairs-price-adapters) |
| The Veda buffer helpers that connect BoringVaults to a managed pool | `DeployManagedBufferHelpers.s.sol` | [Deploy the vaults' buffer helpers](#deploy-the-vaults-buffer-helpers) |

Every `DirectPropAMM` then goes live through [Bring a pool live](#bring-a-pool-live).

## Replace an 8-decimal pool's feed

This procedure replaces the current price adapter of a single-pair `DirectPropAMM` pool.
Its two directional anchors are the last accepted prices for base-to-quote and quote-to-base trades;
the deviation guard limits how far a new price can move from each.

`Chainlink18To8PriceOracleAdapter` lets an existing `DirectPropAMM` with `oracleDecimals() == 8` read an
18-decimal Chainlink AggregatorV3 feed without redeploying the pool. Deploy it with the feed address as its
single constructor argument. It returns `answer / 10^10`, rounded down, and preserves the report's `startedAt`
observation timestamp. Invalid rounds return zero or revert; the pool still enforces freshness and price guards.

This is precision normalization only, not a currency conversion. The proposed PRIME fundamental feed at
`0x0ae20Ebc56e1944eBaa7E40E65C8b7A61d6fF490` describes itself as `HASTRAPRIME / WYLDS Exchange Rate`.
Before using it for PRIME/USDC.e, confirm its economic denomination with the feed provider and the market maker
operating the pool.
Do not infer that WYLDS equals USD from a similar numerical price. If conversion is required, this adapter alone
is insufficient. No production switch is implied by this implementation.

1. Re-read the target pool's tokens, owner, oracle, fixed decimals, freshness limit and both directional anchors.
   Verify the feed address, 18 decimals, denomination and observation cadence independently.
2. Deploy the replacement adapter separately and verify its `feed()`, `decimals()` and `latestPrice()`.
   Existing PRIME pool deployment scripts still select the market feed; they are not migration scripts.
3. Simulate the complete change on a current mainnet fork, including quotes in both directions and the guards.
4. The pool owner pauses the pool, calls `setOracle(replacementAdapter)`, checks the new price against both anchors,
   then unpauses. Reset anchors only after explicitly approving a legitimate price change; do not widen guards
   merely to make a failing migration pass. Keep the freshness limit suited to the feed's actual cadence.
5. After the transaction is mined, verify the pool's `oracle()` points to the replacement and check quotes.
   If validation fails, leave the pool paused; the owner can restore the previous adapter while paused, then validate
   it before unpausing.

## Roles

- **Deployer:** pays deployment gas only; receives no pool authority.
- **Owner:** controls inventory, allowlists, oracle and price-deviation configuration, unpause, and two-step ownership transfer.
- **`ManagedDirectPropAMM` only** (see the [v1 guide](../contracts/README.md#manageddirectpropamm)):
  - The pool holds any number of pairs (`addPair`, owner), each `Closed` until the owner opens it, and starts paused
    with none. The constructor takes owner and factory; use `address(0)` as the factory for a standalone pool.
    There is no TIP-1022 address registry or TIP-403 registry.
  - Swaps take a `pairIndex` and a `sponsorId` instead of a recipient and always pay the caller: sponsor 0 is the pair's
    home list, which only the owner edits (`setMembers(pairIndex, 0, ...)`), and any other id a sponsor the owner
    registered (`addSponsor`), switched on and admitted on the pair (`setPairSponsor`). Only the sponsor's admin lists its
    users. At most 100 accounts per `setMembers` or `setDenied` call; send 50 from a Forge script.
  - Only the owner sets a pair's mode with `setPairAccess`: `Listed`, `Open` (anyone not denied may trade; entered only
    while the pool is paused) or `Closed` (nobody). Only the owner can `closePair` at any time. A pair's oracle,
    freshness and deviation limit and `resetPriceAnchor` change only while that pair is `Closed`, and reopening it
    re-checks its oracle and anchors, as `DirectPropAMM.unpause` does. To recover an untraded direction without
    closing, `refreshPriceAnchor` takes the fresh price on a live pair only within the owner's expected-price bound.
  - Only the owner selects a pair's optional hook with `setPairHook(pairIndex, hook, flags)`, while the pair
    is `Closed`. No hook means zero fees and no callbacks; fee mappings and defaults belong to the hook.
  - `setDenied(accounts, true)` stops a taker from trading on every pair, whatever the lists or `Open` say. Only the owner denies
    or lifts a denial. Direct swaps check their caller; managed Settler calls check the Settler
    caller (the router when routed). Underlying-user denials require separate router-side enforcement.
  - Inventory is shared per token by every pair that uses it. The owner can `withdraw` any token while the pool is
    active, not only while paused: a withdrawal lowers capacity from the next swap but changes no price. It pays no
    TIP-1022 virtual address, as v2 `Venue`: a withdrawal to one reverts `VirtualRecipient`, registered or not, and
    the recipient itself must get the exact credit. To pay a Bridge liquidation address, withdraw to an account and
    send it from there. For the same reason a `DirectPropAMMRebalanceController` on a managed pool takes only
    liquidation addresses that are accounts: its constructor refuses a virtual one (`VirtualLiquidationAddress`).
- **Guardian (`DirectPropAMM` only):** can pause immediately and cannot unpause or withdraw. Managed pools have
  no guardian role; only their owner pauses, closes pairs, denies accounts, disables or removes sponsors.
- **Sponsor admin (`ManagedDirectPropAMM`):** lists and delists its own users on the pairs its sponsor is admitted to,
  and hands its lists to a new key, which must accept. The owner can't edit its lists, only `resetSponsor`, which gives
  the sponsor a new admin and voids every earlier listing.
- **Taker:** the only initial address allowed to execute swaps.
- **Recipient:** the resolved Tempo address allowed to receive swap output. A virtual recipient resolves to its master account before this check. Managed direct swaps pay their caller. Through `Settler`, output goes to its caller (the router when routed). Managed `swap(pool, params)` uses that immediate caller for access, fees and credits. There is no forwarded identity or recipient argument.

Use separate encrypted keystores. The owner should be moved to an operational multisig or other agreed governance account before meaningful inventory is added.

## Preflight

1. Run `forge fmt --check` and the unit tests.
2. Run the fork suite with Foundry `v1.8.1`, the release CI pins.
3. Confirm the operator accepts the pool's explicit pricing assumption that the quote token is worth 1 USD, and who
   pauses the pool if it departs materially from USD.
4. Confirm the owner address independently with the operators, and the guardian for `DirectPropAMM` only.
5. Choose the maximum price deviation for the largest move from the last accepted trade price, and document who may
   approve a paused re-anchor after legitimate drift.
6. Simulate the deployment without `--broadcast` and inspect every constructor argument.

## USDC.e pools

Status: reviewable deployment procedure, not a production deployment record. Nothing in this procedure requires a
vault to exist yet: `contracts/script/DeployUsdcePools.s.sol` deploys PRIME/USDC.e and USDY/USDC.e with their final
roles, and the vaults attach later.

### What gets deployed

Four contracts, in this order:

1. `ChainlinkPriceOracleAdapter` reading the official same-chain PRIME/USD feed.
2. `DirectPropAMM` with PRIME as base and USDC.e as quote.
3. `OndoUSDYPriceOracleAdapter` reading the official same-chain USDY wrapper.
4. `DirectPropAMM` with USDY as base and USDC.e as quote.

Both pools receive the **final owner and guardian directly in their constructors**. No ownership acceptance
or temporary owner is needed. Both start paused, empty, with uninitialized price anchors and no allowed
takers or recipients. The deployer must differ from both administrative accounts and gets no pool role.
The same final owner and guardian apply to both pools; the guardian may be the owner if deliberately chosen.

No vault, Teller, buffer helper, reporter, approvals, allowlisting, inventory transfer, or unpause is included.
The pool, helper, Teller, and Earn layer are separately deployed and administered contracts.

### Fixed mainnet bindings

The script pins these in `contracts/src/TempoMainnet.sol` and rejects any chain other than Tempo mainnet (`4217`).
Reconfirm them with the issuers and live chain before approving deployment.

| Binding | Address |
| --- | --- |
| PRIME | `0x20C00000000000000000000058d0B8b2CFDb358c` |
| USDY | `0x20c000000000000000000000D479B9f6eC0ceFf9` |
| USDC.e (quote for both) | `0x20C000000000000000000000b9537d11c60E8b50` |
| PRIME/USD AggregatorV3 | `0xEd288826d3c2Dbb962534f4085073931aD7eeC93` |
| Ondo USDY wrapper | `0xb25b3266467a755328cfb8F1b349319C2B94419C` |
| Tempo address registry | `0xfDC0000000000000000000000000000000000000` |

All three tokens use six decimals. PRIME's feed has eight price decimals; the Ondo adapter has eighteen.
The adapters supply USD prices, so both pools explicitly assume **1 USDC.e = 1 USD**. Neither adapter checks
USDC.e's peg. Agree on depeg monitoring and pausing responsibility before adding inventory.

### Required review inputs

Copy `contracts/script/config/usdce-pools.env.example` to ignored `.env.usdce-pools` and fill every blank. There are
no role or risk defaults, and no private keys belong in this file.

| Input | Meaning |
| --- | --- |
| `DEPLOYER_ADDRESS` | Account paying for all four deployments, distinct from owner and guardian |
| `OWNER_ADDRESS` | Final administrator and inventory owner for both pools |
| `GUARDIAN_ADDRESS` | Pause authority for both pools; no independent unpause or withdrawal authority |
| `PRIME_MAX_ORACLE_AGE` | Positive maximum age in seconds, measured from PRIME's observation `startedAt` |
| `USDY_MAX_ORACLE_AGE` | Maximum age in seconds, at least `86400`; the USDY adapter always reports the current time |
| `PRIME_MAX_PRICE_DEVIATION_BPS` | Maximum move from the last accepted directional PRIME price, `0..10000` |
| `USDY_MAX_PRICE_DEVIATION_BPS` | Equivalent directional limit for USDY, `0..10000` |
| `TEMPO_RPC_URL` | Tempo mainnet RPC, for example `https://rpc.tempo.xyz` |

Age limits must fit `uint80`. Choose PRIME freshness against the actual reporting schedule; neither value is an order deadline. The
USDY adapter reports the current block time, so its age limit never trips; the scripts still require a day.

Deviation is a circuit breaker, **not a spread or fee**. Zero allows no price movement after initialization;
`50` permits a +/-0.5% step from a direction's anchor. Large values weaken the guard. Review the legitimate
daily accrual and long gaps between trades, plus who may independently validate a paused re-anchor.

Confirm final administrative addresses out of band. Virtual payment aliases are rejected for owner and
guardian: those roles require the actual calling account. A successful simulation does not prove the operator
controls those accounts or that their multisig can execute the required calls.

### Review and simulation only

Use a Tempo-capable Foundry build with `--network tempo` support. After filling and reviewing the config:

```bash
set -a
source .env.usdce-pools
set +a

forge test --match-contract DeployUsdcePoolsTest -vv
forge script contracts/script/DeployUsdcePools.s.sol:DeployUsdcePools \
  --rpc-url "$TEMPO_RPC_URL" --network tempo \
  --sender "$DEPLOYER_ADDRESS" --tempo.fee-token PathUSD -vvvv
```

**There is intentionally no `--broadcast` or signing material in this command.** It sends no transactions.
Before `startBroadcast`, the script checks token metadata, real administrative addresses, risk bounds, PRIME
feed identity, and both adapters' positive/fresh observations. Two local probe adapters validate source
compatibility; they are not included in the four deployment transactions. Simulation postconditions check
each pool's exact pair, adapter, registry, decimals, risk limits, roles, paused state and zero anchors,
and default-deny permissions for the deployment/admin accounts. Both predicted pool addresses may already hold
unsolicited token donations: each pool's base and quote balances must match its pre-deployment snapshot, not zero.
Deployment moves no inventory; record any pre-existing balance rather than treating it as operator funding.

Review the console output and ignored `broadcast/DeployUsdcePools.s.sol/4217/dry-run/run-latest.json`.
Require exactly four `CREATE` transactions, all from the agreed deployer, with the intended constructor
arguments and zero native value. Record the reviewed commit, Foundry version, nonces, estimated fee/gas per
transaction, role addresses, and chosen risk parameters. These are simulated addresses, not deployed contracts.
Check that the deployer has enough of the selected Tempo fee token before a future broadcast.

### After approval, in a separate execution step

Rerun preflight immediately before deploying. Only then may an authorized operator add their encrypted
keystore/password-file flags and `--broadcast` to the reviewed command. Keep signing material outside the
repository. Do not use `--skip-simulation`. Do not add owner/guardian signers: deployment needs only the deployer.

The four transactions are **sequential, not atomic or idempotent**. A source may change between simulation
and inclusion. For example, an Ondo wrapper failure can leave the PRIME adapter and pool deployed while the USDY
deployment fails. Already deployed pools remain paused, with any pre-existing donations; deployment adds no
inventory. A postcondition failure also does not undo
transactions that have already been mined.

If execution is interrupted, preserve the broadcast artifacts, inspect every receipt and the deployer's current
nonce, and reconcile successful addresses before doing anything else. Do not blindly rerun the deployment:
that can create duplicate pools. Resume only after reviewing which transactions remain and revalidating their
arguments and current source state; `--resume` is not a substitute for a fresh simulation/reconciliation.

After completion, independently read the mined contracts over RPC and compare every binding, role, risk limit,
paused state, anchor and balance against the review. Re-read the official sources; preflight checks are not
onchain freshness guarantees between transactions. Save real addresses, transaction hashes, source/commit and
configuration in a new deployment record, and verify the contract sources. Do not claim a production release before
these checks pass.

### Attach vaults later

Keep the pools paused until the chosen trading routes are ready. Each vault can be attached independently:

1. Deploy/identify the intended BoringVault and a Teller with buffer-hook support. Confirm the vault, Accountant,
   Teller assets and any Earn engine all use the intended **USDC.e** accounting boundary; the pathUSD example in
   [veda-integration.md](veda-integration.md) is not a drop-in USDC.e configuration.
2. Deploy one `DirectPropAMMBufferHelper(pool, vault, customerId, slippageBps)` for each route, using the correct
   PRIME or USDY pool, final BoringVault, nonzero customer ID and reviewed slippage limit. Its pool/vault/route
   bindings are immutable; do not deploy it with placeholder vault addresses.
3. The pool owner allows the **BoringVault itself** as taker and resolved recipient, not the helper, Teller,
   Earn engine or deployment wallet. Independently verify both tokens' transfer-policy admission.
4. The Veda administrator grants the required BoringVault management permissions, allows the helper, and
   selects it for both USDC.e deposit and withdrawal hooks. Use the current upstream Veda/Earn tooling and
   [integration requirements](veda-integration.md#external-integration-requirements), not this pool script.
5. The pool owner approves and funds the intended inventory. Funding only RWA inventory initially is possible:
   USDC.e deposits can buy it, but reverse swaps require sufficient USDC.e already in the pool.
6. Recheck live oracle validity, risk values and Accountant valuation; simulate full deposits/redemptions and
   adverse cases on a fork. Then the owner unpauses (initializing both anchors from the guarded live price),
   and operators execute explicitly approved tiny live tests before increasing inventory.

Deployment simulation and script unit tests are not a funded-swap or Veda end-to-end test. Oracle pricing does
not update Accountant NAV, and pool ownership does not grant issuer token-transfer permissions.

## Bring a pool live

After any `DirectPropAMM` deployment. For a `ManagedDirectPropAMM`, follow [Managed pools](#managed-pools) instead:
`DeployManagedPool.s.sol` checks the roles, the pause and every pair, and `ManagedPoolAccess.s.sol` prepares its access.

1. Record every contract address and transaction hash, and verify the source code in the Tempo explorer.
2. Confirm the pool is paused and its base, quote, oracle, registry, owner, guardian, freshness, decimals and maximum
   price deviation match the review.
3. With the owner signer, run `ConfigurePool.s.sol` (`POOL_ADDRESS`, `TAKER_ADDRESS`, `TAKER_ALLOWED`,
   `RECIPIENT_ADDRESS`, `RECIPIENT_ALLOWED`) for the initial taker and resolved recipient. Each role needs its
   address and an explicit lowercase `true` or `false` flag; missing or malformed flags abort before broadcasting.
   To change only one role, omit both inputs for the other. At least one role must be requested. Simulate first;
   submitting requires Forge's `--broadcast` and the owner signer. After successful mined receipts, read
   `takerAllowed(TAKER_ADDRESS)` and `recipientAllowed(resolveRecipient(RECIPIENT_ADDRESS))` for each requested role
   and compare with its flag; see the [configuration commands](veda-integration.md#adding-propamm-after-launch).
4. Transfer ownership to the production governance account and have it accept, if the bootstrap owner is temporary.
5. Move a deliberately small amount of the reviewed tokens to the owner, then follow
   [Funding an immutable pool](#funding-an-immutable-pool). Do not approve a candidate pool before verifying its identity.
6. Rehearse both exact-input and exact-output directions on a fork made from the deployed state.
7. Check stale, future, zero, insufficient-inventory, unauthorized-taker, unauthorized-recipient, quoted-price
   tolerance, minimum quoted-timestamp, deadline, pause, and virtual-recipient failure modes. Confirm zero tolerance is
   exact and the configured nonzero test tolerance is inclusive. `DirectPropAMM` itself has no fee or curve slippage.
8. Unpause only after the above checks pass, then verify that `priceAnchor(true)` and `priceAnchor(false)` equal the
   fresh oracle price used by that first unpause.
9. Execute tiny mainnet swaps in both directions, reconcile all balances and events, verify that each successful
   trade updates only its directional anchor, then decide whether to add inventory.

For an external Earn/Veda integration, the taker and recipient in step 3 are the BoringVault itself. On a
`ManagedDirectPropAMM` admit only the BoringVault, on the pair's home list or a sponsor's list on that pair, and pass
the pair index and that sponsor id (0 for the home list) to the buffer helper. This repository does not ship scripts
for deploying or configuring Veda or Earn. Use the upstream projects' tooling and follow
[veda-integration.md](veda-integration.md); do not authorize an outer Earn router. No offchain oracle automation is
shipped or deployed from this repository.

### Funding an immutable pool

`contracts/script/FundPool.s.sol` requires exported `POOL_ADDRESS`, `EXPECTED_CHAIN_ID`, `EXPECTED_OWNER`,
`EXPECTED_BASE`, `EXPECTED_QUOTE`, and `EXPECTED_POOL_CODEHASH`. Obtain these independently from the reviewed
immutable `DirectPropAMM` deployment and ownership-handoff records: confirm the chain, address, successful creation
receipt, exact historical source, compiler, settings and constructor arguments. `EXPECTED_POOL_CODEHASH` is the
verified deployed-runtime hash, including its immutable values. Do not copy getters or a code hash from an arbitrary
candidate and declare them trusted inputs. A proxy's runtime hash does not attest its implementation; this procedure
is for reviewed immutable pools.

The script checks the chain and runtime hash before calling the pool's owner and token getters, and checks all
expected values before starting any broadcast. `BASE_AMOUNT` and `QUOTE_AMOUNT` are optional raw-unit integers;
absent or zero amounts skip that token and leave any existing allowance for it unchanged. It selects
`EXPECTED_OWNER` as the sender and, for each funded token, approves exactly the requested amount, funds, then
clears the allowance. Do not preapprove an unlimited amount.

With those reviewed inputs exported, simulate first, inspect the target, tokens and amounts, then submit with the
matching owner signer:

```bash
forge script contracts/script/FundPool.s.sol:FundPool \
  --network tempo --rpc-url "$TEMPO_RPC_URL" --sender "$EXPECTED_OWNER"

# Only after reviewing the simulation; pool-owner is the matching local signer account.
forge script contracts/script/FundPool.s.sol:FundPool \
  --network tempo --rpc-url "$TEMPO_RPC_URL" --sender "$EXPECTED_OWNER" --broadcast --account pool-owner
```

Approvals, funding and allowance cleanup are separate transactions, not an atomic batch. After successful mined
receipts, reconcile the owner/pool balances and confirm each funded token's owner-to-pool allowance is zero. If a
send is interrupted or fails, inspect every receipt and outstanding allowance, and revoke any remaining allowance
before retrying. A contract owner must execute approved actions through its own governance mechanism, not an EOA
posing as that owner.

## USDY pool variant

`DeployUsdyPool.s.sol` deploys the same `DirectPropAMM` with USDY as base, pathUSD as quote, and an
`OndoUSDYPriceOracleAdapter`. USDY and Ondo's USDY oracle wrapper are both on Tempo, pinned in
`contracts/src/TempoMainnet.sol` (`USDY`, `USDY_ORACLE_WRAPPER`); the script takes both addresses as inputs, so check
them against those pins. Do not substitute the Ethereum wrapper: contracts cannot read state across chains, and this
repository does not include a bridge, reporter, or push adapter for USDY.

Before deployment:

1. Verify the USDY token and wrapper addresses against current Ondo documentation and deployed bytecode on
   Tempo.
2. Call `wrapper.getPriceData()` and check the price against Ondo's published USDY price. The adapter reads only
   that price; it does not depend on the source behind `wrapper.rwaOracle()`.
3. Choose `MAX_PRICE_DEVIATION_BPS` against Ondo's accrual rate and the longest expected gap between trades in each
   direction.
4. Keep `MAX_ORACLE_AGE` at 86,400 seconds or more, as the script requires; the adapter reports the current time.
5. Confirm the operator accepts both the official USDY source-governance model and the explicit
   `1 pathUSD = 1 USD` assumption.

Required deployment inputs are `USDY_ADDRESS`, `USDY_ORACLE_WRAPPER_ADDRESS`, `OWNER_ADDRESS`, and
`GUARDIAN_ADDRESS`. Both roles must be nonzero accounts that resolve to themselves through TIP-1022; virtual
payment aliases cannot administer the pool and are rejected before deployment. `MAX_ORACLE_AGE` defaults to 90,000
seconds and `MAX_PRICE_DEVIATION_BPS` to 50 only when absent. A supplied empty or malformed numeric value aborts;
it never substitutes a default.

```bash
forge script contracts/script/DeployUsdyPool.s.sol:DeployUsdyPool \
  --rpc-url "$TEMPO_RPC_URL" \
  --keystore /absolute/path/to/deployer.keystore \
  --password-file /absolute/path/to/deployer.password \
  --broadcast
```

The immutable wrapper is the integration trust anchor. Ondo can replace the source behind it (`rwaOracle()`) at any
time; the adapter follows the wrapper's price and needs no change unless the wrapper itself changes. Monitor wrapper
source changes and revalidate the price. The pool's caller-selected quoted-price tolerance, minimum quoted
timestamp, caller limits and directional deviation checks continue to apply; if the new price is outside the
deviation limit, follow the independently validated paused re-anchor procedure.

### Move a live USDY pool to a new adapter

A `DirectPropAMM` changes its oracle only while paused. The pool owner, with the guardian free to pause first:

```bash
forge create contracts/src/OndoUSDYPriceOracleAdapter.sol:OndoUSDYPriceOracleAdapter \
  --rpc-url "$TEMPO_RPC_URL" --broadcast <signer flags> --constructor-args "$USDY_ORACLE_WRAPPER_ADDRESS"
cast call "$ADAPTER" 'latestPrice()(uint256,uint256)' --rpc-url "$TEMPO_RPC_URL"   # matches wrapper.getPriceData()
cast send "$POOL" 'pause()' --rpc-url "$TEMPO_RPC_URL" <signer flags>
cast send "$POOL" 'setOracle(address)' "$ADAPTER" --rpc-url "$TEMPO_RPC_URL" <signer flags>
cast send "$POOL" 'unpause()' --rpc-url "$TEMPO_RPC_URL" <signer flags>   # reverts PriceDeviationExceeded if the price left the anchors' band
cast call "$POOL" 'quoteExactInput(bool,uint256)(uint256,uint256,uint256)' false 1000000 --rpc-url "$TEMPO_RPC_URL"
```

If `unpause` reverts `PriceDeviationExceeded`, validate the new price independently, call
`resetPriceAnchor(true)` and `resetPriceAnchor(false)`, then unpause. Point every consumer of the old adapter, such as
a Veda NAV engine, at the new one.

## Managed pools

The hook-based managed rework requires a new immutable deployment. Historical pair-wide and per-taker-fee
pools cannot be upgraded and are not evidence for this ABI. No hook-based redeployment is recorded here;
the core was audited by Sigma Prime at `0569025`, but the audit does not authorize production deployment.

A `ManagedDirectPropAMM` is deployed paused, with its pairs `Closed`, and the deployment moves no inventory.
Tokens donated to its predicted address before deployment may already be present. It is then opened in this order: sponsors and
lists, intended inventory, each pair's mode, then `unpause()`. Both scripts run each call as its sender in Forge's simulation,
check the result, and print the target, value 0 and calldata for that sender's Safe or wallet. They read no key and
send nothing unless Forge gets `--broadcast` and the sender's own signer (`--ledger` or `--account`).
`ManagedPoolAccess` additionally requires `BROADCAST=true`; without it, even `--broadcast` only simulates the
access change and prints “Not sent.” `DeployManagedPool` does not use this environment switch.

### Deploy the pairs' price adapters

Each managed pair reads one `IPriceOracle`, and the pool refuses an oracle address a second pair already uses, so
every pair needs an adapter of its own, deployed before `addPair`.
`contracts/script/managed/DeployManagedOracleAdapters.s.sol` deploys them on Tempo mainnet (4217) or Moderato (42431)
and nothing else: no pool, no role, no token. The adapters are immutable and ownerless, so the deployer keeps no
power over them. One entry per adapter:

| Variable | Notes |
| --- | --- |
| `DEPLOYER_ADDRESS` | Sends one CREATE per adapter, in order |
| `ORACLE_KINDS` | `CHAINLINK` (the feed's own decimals), `CHAINLINK_18_TO_8` (an 18-decimal feed read at 8, rounded down) or `ONDO_USDY` (Ondo's wrapper, 18 decimals) |
| `ORACLE_SOURCES` | The AggregatorV3 feed, or Ondo's wrapper (on mainnet only the canonical one) |
| `ORACLE_SOURCE_DESCRIPTIONS` | Separated by `\|`: the feed's exact `description()`, or `-` for `ONDO_USDY`. Single-quote it in the env file |
| `ORACLE_DECIMALS` | What the adapter must answer: the pair's price precision for good |
| `ORACLE_MAX_AGES` | The pair's planned `maxOracleAge`, 1 second to 365 days: the source must be that fresh now |
| `ORACLE_REFERENCES` | An existing `IPriceOracle` the adapter must agree with now, or the zero address |

A managed pair fixes its oracle's decimals when it is added: `setOracle` later refuses an adapter with other decimals
(`OracleDecimalsChanged`). Choosing `CHAINLINK` or `CHAINLINK_18_TO_8` over an 18-decimal feed is therefore a
choice for the life of the pair, not of the adapter; a pair that needs the other precision is a new pair. Decimals are
precision only, never a currency conversion: the reviewed description is what says the feed prices the pair's base in
its quote, and the cautions in [Replace an 8-decimal pool's feed](#replace-an-8-decimal-pools-feed) apply unchanged.

The preflight deploys a local probe of every adapter, outside the broadcast, and stops unless its source answers the
reviewed description and decimals and holds a positive observation no older than the pair's planned age. For a pair
that replaces a live pool, set its `ORACLE_REFERENCES` entry to that pool's current `oracle()`: the new adapter must
report the same observation time and the same price at the coarser of the two precisions, so the pair opens on the
price the old pool trades at. The postconditions require each adapter at the deployer's next CREATE address with the
reviewed source, decimals and the probe's observation. Every check gates the broadcast.

Copy `contracts/script/managed/config/managed-oracle-adapters.env.example` to an ignored
`.env.managed-oracle-adapters` and fill it. Then:

```bash
set -a
source .env.managed-oracle-adapters
set +a

forge test --match-contract DeployManagedOracleAdaptersTest -vv
forge script contracts/script/managed/DeployManagedOracleAdapters.s.sol:DeployManagedOracleAdapters \
  --rpc-url "$TEMPO_RPC_URL" --network tempo \
  --sender "$DEPLOYER_ADDRESS" --tempo.fee-token PathUSD -vvvv
```

After reviewing the simulated transactions, an authorized operator adds the deployer's keystore and password-file
flags and `--broadcast`. After inclusion, read each adapter's `feed()` or `wrapper()`, `decimals()` and
`latestPrice()` from the chain, then pass the printed `PAIR_ORACLES` line to `DeployManagedPool` in the same pair
order. A passing run proves the adapter matches its source, not that the source is the right one for the pair:
confirm the feed with its operator and the market maker before the owner sends `addPair`.

### Deploy a managed pool

`contracts/script/managed/DeployManagedPool.s.sol` deploys `ManagedDirectPropAMM(OWNER_ADDRESS, address(0))` on Tempo
mainnet (4217) or Moderato (42431), then adds the pairs. The constructor takes no pairs: Tempo prices code at about
1,030 gas a byte. The local Solar-built deployment measures 14,213,358 gas; `addPair` costs 1,308,772 with two new
tokens or 814,172 with known tokens. The deployment's conservative Forge gas limit is 20,048,821, below Tempo's 30M cap
(`contracts/test/fork/managed/ManagedDirectPropAMMGas.t.sol`). When `OWNER_ADDRESS`
is the deployer, as for a test pool on Moderato, the broadcast also sends each `addPair`. Otherwise the script runs
each `addPair` as the owner in the simulation and prints it, in order, as Safe calldata for the owner to send; the
deployer never holds the owner's power, and on mainnet it may hold no pool role at all.

| Variable | Notes |
| --- | --- |
| `DEPLOYER_ADDRESS` | Sends the deployment, and the `addPair`s when it is the owner |
| `OWNER_ADDRESS` | Real account, not zero or virtual; distinct from the deployer on mainnet |
| `PAIR_BASES`, `PAIR_QUOTES`, `PAIR_ORACLES` | One comma-separated entry per pair, in pair order, 1 to 16 pairs |
| `PAIR_MAX_ORACLE_AGES`, `PAIR_MAX_PRICE_DEVIATION_BPS` | Per pair: 1 to 365 days of seconds; 0 to 100 bps |

The preflight refuses a run without `--network tempo`, where Forge runs no TIP-20 precompile and pathUSD answers no
`decimals()`. Token and oracle probes (`decimals()`, `latestPrice()`) are capped at 200,000 gas and copy only exact
32-byte or 64-byte answers. Malformed, oversized or gas-burning answers get a named `InvalidConfig` refusal. It also
refuses an oracle an earlier pair already uses (one oracle prices one base in one quote: the same tokens the other way
round would trade at the inverse price), and limits beyond the script's; a stale oracle only warns, since only opening
the pair needs a fresh price.

For each distinct pair token, preflight reads its transfer policy through the canonical TIP-403 registry. The predicted
pool must be authorized to send and receive; `OWNER_ADDRESS`, the pool's funding caller and source, must be authorized
to send. A denied direction aborts before deployment with `TokenPolicyDenied(token, account, sending)`. A separate
deployer needs no token permission for funding, and this check does not require the owner to receive. These checks are
point-in-time: recheck the actual deployed pool and intended funding source after nonce or policy changes, before
funding or opening. They do not protect against a later policy-admin change.

The pool runs its own checks (`UnsupportedDecimals` and the rest) when the simulation adds
each pair. The postconditions check the owner, the pause, every pair's fields, `Closed` mode and zero
anchors, `tokenPairCount`, no denial and unchanged configured pair-token balances at the predicted
pool address. Pre-existing donations are allowed; a passing simulation does not prove the pool is empty.
These postconditions gate the broadcast.

Copy `contracts/script/managed/config/managed-pool.env.example` to an ignored `.env.managed-pool` and fill it. Then:

```bash
set -a
source .env.managed-pool
set +a

forge test --match-contract DeployManagedPoolTest -vv
forge script contracts/script/managed/DeployManagedPool.s.sol:DeployManagedPool \
  --rpc-url "$TEMPO_RPC_URL" --network tempo \
  --sender "$DEPLOYER_ADDRESS" --tempo.fee-token PathUSD -vvvv
```

After reviewing the simulated transactions, an authorized operator adds the deployer's keystore and password-file
flags and `--broadcast`. Record the pool address and its deployment block, which the
[access script's `MODE=CHECK`](#managed-pool-access) replays from.

Pair-list positions are provisional, not reserved indexes: mined `addPair` order assigns each index.
After inclusion, read `PairAdded` events and verify each live pair's base/quote/oracle addresses before configuring it.
All pair-targeted access modes require `EXPECTED_BASE=<reviewed base>`, `EXPECTED_QUOTE=<reviewed quote>` and
`EXPECTED_ORACLE=<reviewed oracle>` in addition to `PAIR_INDEX`; a missing identity or address mismatch aborts before any call. Token addresses
are immutable and pair indexes are never reused. Same-token pairs can have different oracles; review the oracle too.
Do not derive expectations from an unreviewed index. The script rejects a tuple shared by another live pair.
For an ambiguous tuple, review the intended index and submit explicitly reviewed calldata outside this script.
The oracle can change while a pair is Closed: these are simulation-time checks, not an atomic guard on a separately
queued Safe call. Re-simulate and review live state before executing queued calldata.

Before sending the owner's `addPair` calls, confirm every pair with the token issuers and oracle operators. Pairs share
inventory per token, so a wrong or compromised oracle on one pair can sell a token another pair needs: keep tokens that
back independent risk in separate pools.

### Configure and verify managed pair hooks

1. Keep the pair `Closed`. Prefer no hook unless the deployment needs custom fee or callback policy.
   Only the owner calls `setPairHook(uint16 pairIndex, address hook, uint8 flags)`; read back `pairHook(pairIndex)`.
   No hook means zero fees and no callbacks. There is no native fee table or fee-configuration API.
2. Review hook code, policy administration and upgrade authority. `QUOTE` is a gas-bounded static/view call
   returning `feeBps`, capped by the pool at `MAX_HOOK_FEE_BPS = 1000` (10%). `BEFORE_SWAP` and `AFTER_SWAP`
   are state callbacks requiring selector acknowledgments. View calls are capped at 200,000 gas and each state
   callback at 5,000,000 gas.
   Hooks cannot take custody, call `hookTake`, decrease either pair-token balance or bypass core checks.
3. Quote and simulate both directions and order types for the authenticated taker, including gross approvals,
   fee-inclusive limits, exact token deltas and route credit. `QuoteContext` identifies pair, taker, direction,
   order type and requested amount. Quotes accept any named taker without authentication or access proof;
   only execution authenticates it. Swap callbacks also identify sponsor, customer, trade, actual caller,
   tokens and gross input/output amounts. Defaults and custom fee mappings are entirely hook policy.
4. Direct swaps use their caller as taker; Settler swaps use the Settler's immediate caller. Quote for the
   router when routed: hooks see the router, not the underlying user. The router must independently check its
   authenticated user's pool access for the swap; core execution only checks the router. Customer IDs partition
   router-owned credits but do not authenticate users.
5. Before reopening, verify hook address/flags and policy, then rehearse small swaps. Monitor hook selection
   and any hook-specific policy changes; closing the pair to replace a hook does not freeze policy inside it.

For an Earn buffer, require no hook or independently verify zero fees for the BoringVault in both directions
and reconcile Accountant NAV ([Veda guide](veda-integration.md#hook-fees-and-vault-accounting)). The helper
quotes for the vault but enforces no independent fee cap; neither pool nor hook updates Accountant NAV.
A nonzero fee consumes vault backing and requires separately reviewed accounting and liquidity policy.

### Migrate managed Settler callers

The managed Settler exposes only `swap(pool, params)`, using its immediate
caller as taker. Removing the explicit-taker draft APIs is an ABI break: regenerate caller ABIs and calldata.
Router-trust configuration and forwarded-fill APIs are absent. Direct pool swap APIs are unchanged.

A router trades as itself, supplies and receives all tokens, and needs ordinary list membership on every
`Listed` pair. `Open` admits any caller without listing, still subject to the pool's deny list. Review the
router's authenticated user handling, input collection, output delivery and upgrade authority. Require it to
check each underlying user's `takerAllowed`/`takerAccess` separately for each swap; neither pool nor Settler
implements or enforces that policy for routed swaps. Denying an underlying user does not alone block an
admitted router. External Tempo router implementation is outside this change and was outside the core audit.

Quote for the router and the exact customer ID to be used. Hooks see the router rather than the underlying
user, and credits are keyed by `(pairIndex, router, customerId)`. Review the router's customer-ID partitioning
and authorization so different users cannot spend each other's routed credits. Simulate fee-inclusive limits,
deadlines, oracle bounds, exact token deltas and route-credit isolation against the final caller ABI.

These contracts need new immutable deployments, not an upgrade to existing addresses; no production
rollout is authorized by this runbook. Rebuild and validate the reviewed caller against those deployments
before funding. propAMM v2 is unaffected.

### Managed pool access

`contracts/script/managed/ManagedPoolAccess.s.sol` prepares one access change on a `ManagedDirectPropAMM`, or checks its access
state. `CALLER` names the sender; it defaults to the owner, to the sponsor's admin for a sponsor's `LIST`, `DELIST` and
handover, and to the pending admin for `ACCEPT_SPONSOR_ADMIN`. Administrative restriction modes require the owner.

It refuses, before anything runs:

- an input that doesn't apply to the mode;
- a zero or duplicate account, or the pool in a change;
- more than 50 accounts in any mode; remeasure worst-case batches against Tempo's 30M cap at Forge's 130% gas limit
  before sending;
- a TIP-1022 virtual address in `LIST` or `DENY`. It never calls the pool, so listing it admits nobody and denying it
  blocks nobody but makes every swap read the deny list; list or deny its master. `DELIST` and `UNDENY` take one, to
  clean up;
- a zero, pool or virtual `SPONSOR_ADMIN`;
- `ACCESS=open` while the pool is active, which `setPairAccess` would refuse;
- a change that would change nothing, except a sponsor's post-reset `DELIST` or verified removed-pair cleanup:
  these may clear retained records even when effective membership or admission is already false;
- a pool that doesn't answer as a `ManagedDirectPropAMM` (bounded raw probes of its managed interface):
  a `DirectPropAMM` or a v2 `Venue` is refused.

Every pair-targeted mode requires `EXPECTED_BASE`, `EXPECTED_QUOTE` and `EXPECTED_ORACLE` alongside
`PAIR_INDEX`. Use the reviewed identities and the mined `PairAdded` index, not an unreviewed index's current values.
Live pairs retain the current identity and uniqueness checks. Only `DELIST` and `UNADMIT` may target a removed
pair, with `FROM_BLOCK` at or before its mined `PairAdded` event (the pool's deployment block is safe).
`LOG_BLOCK_RANGE` optionally bounds each query, defaulting to 100,000 blocks; it requires `FROM_BLOCK`.
Do not pass these history inputs for a live-pair change or another mode.

Removed-pair cleanup requires the selected index to have existed and its current pair record to be empty.
Through the simulation block, the script requires exactly one matching `PairAdded`, a complete `OracleUpdated`
chain beginning at zero, and one later `PairRemoved`. `EXPECTED_ORACLE` is the **last oracle before removal**, not
necessarily the initial oracle. Missing, malformed, duplicate, reordered, reorg-removed or wrong-pool logs fail
closed, as do an incomplete oracle chain, wrong reviewed identity and RPC failures. Block hashes must match
canonical RPC headers for the selected pair's identity-event blocks; unrelated activity needs no header requests.
The history is replayed once per run. Its proof stays in memory only for that call: after the simulated cleanup,
the script rechecks the empty removed-pair record and unchanged simulation block and canonical head hash.
Every new run replays history afresh. Cleanup issues three exact-topic queries per bounded block range:
`PairAdded`, `OracleUpdated` and `PairRemoved`, each also filtered to the selected pair index. Filtering happens
before response decoding, so unrelated swaps, access events and other pairs do not consume cleanup's decoding
budget. The three streams are merged by block number and log index without sorting within a stream; every returned
log must match its query and pass the metadata, strict-order, identity and canonical-hash checks. CHECK still reads
all pool events and reconstructs full access state independently.
Cleanup and CHECK reclaim temporary log and RPC-answer memory after each chunk; cleanup retains only its fixed-size
proof state, while CHECK accumulates replay state in script storage. Both scans check their gas reserve before each
query, including empty responses; `ReplayNeedsMoreGas` reports the cumulative processed-event count (identity events
only for cleanup). Smaller `LOG_BLOCK_RANGE` values bound blocks per response, not same-block event density or total
replay cost. A single dense matching response must still fit decoding and memory; the reserve cannot preempt RPC
response decoding. Raise `FOUNDRY_GAS_LIMIT` and rerun the complete scan when needed.
A different live pair with the same identity is not touched.

Use a **fresh simulation against a trusted, complete canonical RPC**; the selected simulation block must still be
canonical. Header comparisons detect inconsistencies during replay, but do not independently authenticate an
already-loaded fork after a prior reorg, omitted events, pool code or deployment provenance. These are identity
checks on a known pool implementation, not a cryptographic proof of historical state. Re-simulate before signing
or executing queued Safe calldata, especially after a reorg.

For example, set the reviewed expectations and run `MODE=DELIST PAIR_INDEX=<removed index> ACCOUNTS=0x...
FROM_BLOCK=<creation block>` (with `SPONSOR_ID` for a sponsor list), or `MODE=UNADMIT PAIR_INDEX=<removed index>
SPONSOR_ID=<id> FROM_BLOCK=<creation block>` without `ACCOUNTS`. The current owner edits the home list; the current
sponsor admin edits its list, including after a reset or handover; only the current owner unadmits.
The simulation still calls the pool's real authorization checks. These calls never grant access. Public views hide
retained records once a pair is removed, so previews say **clear retained record if any, effective access unchanged**,
not that a stored record definitely changed. Repeating the explicit cleanup is permitted; other no-op checks remain.

The script calls no precompile, so it needs no `--network tempo`:

```bash
POOL_ADDRESS=0x... MODE=... forge script contracts/script/managed/ManagedPoolAccess.s.sol:ManagedPoolAccess \
  --rpc-url "$TEMPO_RPC_URL"
```

1. **Register a fintech as a sponsor:** `MODE=ADD_SPONSOR SPONSOR_ID=<id> SPONSOR_ADMIN=<its key>`, then
   `MODE=ADMIT PAIR_INDEX=<pair> SPONSOR_ID=<id>` for each pair its customers trade. Choose the id (reuse the
   business's v2 sponsor id where it has one), confirm the admin with the fintech, and record both. Tell the fintech
   to swap with that `sponsorId`, and to have its customers approve the pool per swap, exactly, in the swap's batch:
   Tempo access-key limits don't bound a standing allowance ([v1 guide](../contracts/README.md#taker-approvals-and-tempo-access-keys)).
2. **A sponsor lists its users:** its admin runs `MODE=LIST PAIR_INDEX=<pair> SPONSOR_ID=<id> ACCOUNTS=0x...,0x...`
   (at most 50) and sends the printed call. Listing needs the sponsor switched on and admitted on the pair; delisting
   (`MODE=DELIST`) needs neither enabled status nor admission. After a sponsor reset, it may also clear a retained
   old-generation listing whose effective membership is already false; the preview identifies that idempotent
   cleanup rather than claiming an access change. Removed-pair cleanup additionally needs the verified history
   described above; ordinary changes still require a live pair with reviewed identity.
3. **The home list:** the owner runs `MODE=LIST PAIR_INDEX=<pair> ACCOUNTS=...` (`SPONSOR_ID` unset, 0). Lists are per
   pair: a taker on several pairs is listed on each. An empty `SPONSOR_ID` also selects the home list; a malformed
   or out-of-range id aborts rather than falling back to it. Set `SPONSOR_ID=0` explicitly when reviewing a home-list edit.
4. **Open a pair:** `MODE=PAIR_ACCESS PAIR_INDEX=<pair> ACCESS=listed`, which re-checks the pair's oracle and anchors
   after `fund(token, amount, memo)` for its tokens, then `unpause()`. Zero directional anchors are initialized
   from the execution-time oracle price without a deviation or expected-price bound; only nonzero anchors are
   deviation-checked. The script prints both anchors and the oracle observation before and after its simulated call
   and warns before sending when an anchor is zero. Neither Safe calldata nor broadcast simulation binds the mined
   initialization price: after inclusion run `MODE=CHECK` and compare both anchors (or the transaction's
   `PriceAnchorUpdated` events) with the reviewed observation before allowing swaps. `ACCESS=open` admits everyone
   not denied and needs the pool paused.
5. **Offboard:** `MODE=DELIST` with the list's inputs. Another sponsor's list or the home list may still admit the
   account, and an `Open` pair admits it anyway: the script warns about the home list and `Open`. If it must not trade
   at all, deny it (`MODE=DENY ACCOUNTS=...`), which overrides every list and `Open` on every pair.
6. **Emergency:** set `CALLER=<owner>` for each narrowing mode: deny with `MODE=DENY ACCOUNTS=<accounts>`,
   switch a sponsor off with `MODE=DISABLE_SPONSOR SPONSOR_ID=<id>`, remove it from a pair with
   `MODE=UNADMIT SPONSOR_ID=<id> PAIR_INDEX=<pair>`, or close a pair with `MODE=CLOSE_PAIR PAIR_INDEX=<pair>`.
   Pair-targeted calls also need the reviewed `EXPECTED_BASE`, `EXPECTED_QUOTE` and `EXPECTED_ORACLE` for that live
   pair. Sending requires **all three**: `BROADCAST=true`, Forge's `--broadcast`, and the owner's signer.
   For example, with the reviewed pool, owner and account addresses set:

   ```bash
   POOL_ADDRESS="$POOL_ADDRESS" MODE=DENY CALLER="$OWNER_ADDRESS" ACCOUNTS="$DENIED_ACCOUNT" BROADCAST=true \
     forge script contracts/script/managed/ManagedPoolAccess.s.sol:ManagedPoolAccess \
       --rpc-url "$TEMPO_RPC_URL" --broadcast --account owner
   ```

   Wait for the successful mined receipt, then confirm the restriction through `denied(account)`,
   `sponsor(sponsorId)`, `pairSponsor(pairIndex,sponsorId)` or `pair(pairIndex).access`, as applicable. Neither the
   simulated applied-state check nor printed calldata proves the restriction is live. Pause the whole pool with
   `pause()` if needed. Only the owner reverses these, with `UNDENY`, `ENABLE_SPONSOR`, `ADMIT` or `PAIR_ACCESS`.
   Re-enabling restores retained current-generation listings across admitted pairs; readmission restores them on
   that pair, subject to the other access gates. The script warns before either change. Before submitting, run
   `MODE=CHECK` with `FROM_BLOCK` set to the deployment block to enumerate the retained listings, then review which
   members should regain access. Lift stale denials: while any account is denied, every swap reads the deny list.
7. **A sponsor changes keys:** its admin proposes the new key (`MODE=TRANSFER_SPONSOR_ADMIN SPONSOR_ID=<id>
   SPONSOR_ADMIN=<new key>`; `CANCEL_SPONSOR_ADMIN_TRANSFER` withdraws it), and the new key accepts
   (`MODE=ACCEPT_SPONSOR_ADMIN SPONSOR_ID=<id>`). A sponsor that lost its key gets a new admin from the owner
   (`MODE=RESET_SPONSOR SPONSOR_ID=<id> SPONSOR_ADMIN=<new key>`), which voids every listing it made: its new admin
   re-lists. Update the record either way.
8. **Monitor:** run `MODE=CHECK` with `EXPECTED_SPONSOR_IDS` and `EXPECTED_SPONSOR_ADMINS` (the recorded ids and
   admins, one per id) and `FROM_BLOCK` (the pool's deployment block; `LOG_BLOCK_RANGE` only with it). It reports the
   owner, pause, every pair's mode, oracle freshness and anchors, and each sponsor's admin.
   Safe-shaped getters and `owner()` answers are labeled self-reported and unverified: they do not prove the account's
   implementation, custody or upgrade authority. CHECK exits non-zero
   on any finding: an expected sponsor not registered, with another admin, a pending handover or switched off; a
   registered sponsor not recorded; or replayed events (sponsors, admissions, lists at each sponsor's current
   generation, denials and pairs) that disagree with the chain. Add `ACCOUNTS` to see each account's `takerAccess`
   reason on every live pair, under the home list and every sponsor. The replay runs in one simulation, about 120,000
   gas per listing event (about 800,000 with `--network tempo`, which CHECK doesn't need), so past about 8,000 listing
   events (1,300) it stops with `ReplayNeedsMoreGas` rather than check part of the history. Pair, sponsor and nested
   reporting/reconciliation loops and block-range queries (including empty ranges) also reserve gas and use that
   named refusal; expensive getters can reach the limit
   with fewer events. Run again with `FOUNDRY_GAS_LIMIT=18446744073709551615`, never treat a partial report as clean.
   Between checks, watch `MemberUpdated`,
   `SponsorAdded`, `SponsorEnabledSet`, `SponsorReset`, `SponsorAdminTransferred`, `PairSponsorSet`,
   `PairAccessUpdated`, `DenyUpdated` and `SettlerSet` on the pool. A sponsor re-enable
   restores its retained current-generation listings on every admitted pair, subject to the other access gates;
   review it even when no new `MemberUpdated` event appears. Review settler changes as custody
   and identity-authority changes, not merely routing updates.

### Deploy the vaults' buffer helpers

A Veda BoringVault trades on a managed pair through one `DirectPropAMMBufferHelper` bound to the pool, the vault, the
pair, the list that admits the vault and its route. `contracts/script/managed/DeployManagedBufferHelpers.s.sol`
deploys one helper per vault and pair, and nothing else. A helper holds no tokens and has no authority over the vault
or the pool: the pool's owner still admits each BoringVault ([Managed pool access](#managed-pool-access)), and the
Veda authority still allows the helper and selects it on the Teller. Run it after the pairs exist (it reads each
live pair), on chain 4217 or 42431. `POOL_ADDRESS` is the managed pool; one entry per helper:

| Variable | Notes |
| --- | --- |
| `DEPLOYER_ADDRESS` | Sends one CREATE per helper, in order |
| `HELPER_VAULTS` | The BoringVault itself, the account that swaps: never a Teller, an Earn engine or a wallet |
| `HELPER_PAIR_INDEXES` | The pair whose base the vault holds and whose quote is its asset |
| `HELPER_EXPECTED_BASES`, `HELPER_EXPECTED_QUOTES` | The reviewed tokens of that pair, which the live pair must hold |
| `HELPER_SPONSOR_IDS` | The list that admits the vault on the pair, 0 for its home list |
| `HELPER_CUSTOMER_IDS` | The nonzero 32-byte route id the vault's rounding credit accrues under |
| `HELPER_SLIPPAGE_BPS` | The helper's quote tolerance, at most 1,000. Not a fee cap |
| `HELPER_REFERENCES` | The helper the vault's Teller uses today, or the zero address |

Mined `addPair` order assigns pair indexes, so the script refuses an index whose live pair does not hold exactly the
expected tokens, as well as an unknown or removed pair, a pool that does not answer as a managed pool, a vault without
code, and two helpers for one vault and pair. A named `HELPER_REFERENCES` helper must serve the same vault and the
same two tokens, so a replacement cannot be bound to another vault or pair by mistake; a different customer id or
slippage only warns. Route credit is keyed by `(pairIndex, taker, customerId)` in the new pool and starts at zero
there whatever the id, so credit a vault accrued in the pool it leaves does not move.

The run warns, without stopping, about what a helper may be deployed ahead of: a vault the pair does not admit yet
(its swaps revert until it is listed and the pair leaves `Closed`), and a pair hook. A helper has no fee cap of its
own: before a Teller switches, verify the hook charges the BoringVault zero in both directions and review who can
change that, as [the Veda integration guide](veda-integration.md#on-a-manageddirectpropamm) requires.

Copy `contracts/script/managed/config/managed-buffer-helpers.env.example` to an ignored
`.env.managed-buffer-helpers` and fill it. Then:

```bash
set -a
source .env.managed-buffer-helpers
set +a

forge test --match-contract DeployManagedBufferHelpersTest -vv
forge script contracts/script/managed/DeployManagedBufferHelpers.s.sol:DeployManagedBufferHelpers \
  --rpc-url "$TEMPO_RPC_URL" --network tempo \
  --sender "$DEPLOYER_ADDRESS" --tempo.fee-token PathUSD -vvvv
```

After reviewing the simulated transactions and every warning, an authorized operator adds the deployer's keystore and
password-file flags and `--broadcast`. After inclusion, read each helper's `pool()`, `vault()`, `pairIndex()`,
`sponsorId()`, `baseToken()`, `quoteToken()`, `customerId()` and `slippageBps()` from the chain before the Veda
authority selects it. Deployment simulation and the script's unit tests are not a funded-swap or Veda end-to-end
test: simulate full deposits and redemptions through the Teller on a fork first.

### Auditing and replacing the managed settler

The managed access script's `CHECK` prints the immutable factory and owner-chosen settler. Set `FROM_BLOCK`
at or before deployment to replay `SettlerSet` and compare the last settler with chain state. Missing or malformed
views and mismatched or missing history are findings. For a factory clone, set `EXPECTED_FACTORY` to the
`PoolFactory` takers trust: the clone is a finding unless its `factory()` is that factory, the factory's `isPool`
proves it, and its `settler()` is the factory's `defaultSettler()` (or `EXPECTED_SETTLER`, a replacement you
reviewed). Without `EXPECTED_FACTORY` a clone's settler is unauthenticated, also a finding. A standalone pool (factory 0) always has an incomplete-provenance finding: matching runtime and events cannot
prove its constructor did not seed unlogged access state. CHECK fails closed even without a settler; standalone
configuration modes remain supported. A standalone pool given a settler or checked against `EXPECTED_FACTORY`
additionally has an unauthenticated-settlement finding. A matching history is not a security audit of the settler:
review the current contract and its upgrade authority, since a malicious settler can release unpaid inventory.

To replace a settler, use `MODE=SET_SETTLER` and exactly one nonzero address in `ACCOUNTS`. Only the owner can
apply this change; `CALLER` does not grant authority to another account. The script simulates the change, verifies the result
and prints Safe calldata by default. It refuses unrelated inputs and a replacement already selected.


## Rebalance controller

What the controller and its keeper can do is in the [v1 guide](../contracts/README.md#directpropammrebalancecontroller).

### Bridge liquidation addresses

Each address is a Bridge [liquidation address](https://apidocs.bridge.xyz/platform/orchestration/liquidation_address/liquidation_address):
a permanent deposit address that Bridge uses to convert incoming tokens and send the result to a configured
destination. Configure each address to convert into the pool token it should replenish and pay the pool directly.
The returned tokens become inventory as soon as they reach the pool; they never pass through the controller or keeper.
On a `DirectPropAMM`, a liquidation address that is a TIP-1022 virtual address is paid through its master, which the
pool checks; a managed pool's controller refuses one.

Use liquidation addresses, not static templates (called "payment routes" in the Bridge dashboard). Static templates
route deposits by memo, but the controller always sends a zero memo.

The contract fixes the liquidation addresses at deployment. Bridge controls their payout and refund destinations
outside the contract. Before funding, verify for each address:

- The source token and chain, and the destination token and chain.
- Both payout and refund destinations: each must return funds to the pool on its chain.
- Supported amounts and fees.

Bridge configures [crypto returns separately](https://apidocs.bridge.xyz/platform/orchestration/more/returns#returning-crypto-deposits).
Do not assume a failed conversion returns funds to the sender by default. Keep credentials that can change payout
or refund destinations off the keeper machine. A fixed onchain address offers no protection if the keeper can
change its destination through Bridge. An incorrect or compromised route can lose any inventory sent to it.

### Set up a controller

1. Deploy the pool, then deploy the controller with the pool, its tokens and their liquidation addresses.
2. Have the current pool owner call `transferOwnership(controller)`.
3. Have the controller owner call `execute` with the encoded pool call `acceptOwnership()`.
4. Configure and unpause the pool through `execute` (on a managed pool, open each pair with `setPairAccess` too).

To change a liquidation address, deploy a new controller. Through the old controller, call `execute` with the
encoded pool call `transferOwnership(newController)`. Then, through the new controller, call `execute` with the
encoded pool call `acceptOwnership()`.

## Par pool with a rebalance controller

Status: reviewed script for a small live test, not a production deployment record.

`contracts/script/DeployParPool.s.sol` deploys a par-priced `DirectPropAMM` for two TIP-20s of equal decimals,
`BASE_TOKEN` and `QUOTE_TOKEN`, and hands it to a `DirectPropAMMRebalanceController`. The controller fixes its Bridge
liquidation addresses at construction, but Bridge needs the pool address as each liquidation address's
`destination_address`. The deployment therefore runs in two stages, selected by the required `STAGE` variable. Each
stage is one broadcast from `DEPLOYER_ADDRESS`.

1. **`STAGE=pool`.** Deploys a `PushPriceOracle` (8 decimals, price `1e8`, timestamped at the current block) and
   `DirectPropAMM(BASE_TOKEN, QUOTE_TOKEN, oracle, ADDRESS_REGISTRY, deployer, guardian, maxOracleAge,
   maxPriceDeviationBps)`. It optionally approves and `fund`s each side from the deployer, then unpauses, which sets
   both anchors to par. The deployer is the oracle's sole initial owner and reporter until that unpause transaction;
   only the trusted deployer can change the seed before anchor capture, even if a configured role is the deployer.
   Afterwards the script grants
   `ORACLE_REPORTER_ADDRESS` and starts a two-step transfer to `ORACLE_OWNER_ADDRESS` (unless that role is the
   deployer). The configured owner must call `acceptOwnership()` on the oracle using the printed target/calldata;
   until acceptance the deployer retains oracle ownership and can change the reporter. These role transactions
   leave the pool CREATE address unchanged.
   Oracle ownership must be accepted before the controller stage. There is no controller: the deployer owns the pool.
   The script prints `POOL_ADDRESS` and
   `ORACLE_ADDRESS`.
2. **Create both Bridge liquidation addresses** with the pool as destination: base token in, quote token out; and
   quote token in, base token out. Verify their payout and refund destinations
   ([Bridge liquidation addresses](#bridge-liquidation-addresses)).
3. **`STAGE=controller`.** Requires `POOL_ADDRESS`, `POOL_DEPLOYMENT_BLOCK` and `POOL_CREATION_TX` from the pool's
   mined creation receipt (not the oracle or unpause transaction). Before broadcasting, it checks that the existing pool:
   - holds `BASE_TOKEN` as base and `QUOTE_TOKEN` as quote, with the expected registry and decimals;
   - has risk limits within the script's bounds;
   - is owned by the deployer and unpaused, with both anchors at par;
   - reads an oracle that is at par and fresh, and that matches `ORACLE_ADDRESS` when that is set;
   - has exactly the required `ORACLE_OWNER_ADDRESS` as accepted oracle owner, no pending oracle owner, and
     `ORACLE_REPORTER_ADDRESS` as reporter; these roles are checked again after handoff;
   - was created by the deployer with the exact canonical `DirectPropAMM` creation input, including compiler metadata
     and every constructor argument, in a successful transaction at `POOL_DEPLOYMENT_BLOCK`;
   - has no current taker or recipient permission for any account found in its permission-event history.

   The active RPC supplies the creation transaction and receipt; the receipt must name this pool and deployer.
   Creation must precede the simulation block. Its block hash is bound to the inspected fork's EIP-2935 history state,
   not just another numbered RPC response. Older creation blocks require hash-authenticated raw headers from
   `debug_getRawHeader`, with one sequential RPC call per ancestor link beyond the latest 8,191 blocks and at most
   1,000,000 such links. Run the controller stage no later than 1,008,191 blocks after creation; this is a block-age
   limit, not a fixed wall-clock window. Older pools cannot pass this stage. Even below the limit, old pools can
   require hundreds of thousands of sequential RPC calls. Missing history state or headers, an unsupported header
   format, a divergent history or a longer walk aborts before broadcasting; use an archive endpoint that supports
   this method. Trust the selected RPC to return genuine transactions, receipts, state and complete logs; this
   check rejects inconsistent histories, not a malicious endpoint fabricating all of that evidence. Tempo headers
   put three scalar fields before the inner Ethereum header, with optional trailing consensus context
   ([pinned node encoding](https://github.com/tempoxyz/tempo/blob/2d12f29a99ba8388de4eaa0ae2c1ad2e20cb55be/crates/primitives/src/header.rs#L26-L63)).
   Runtime code and events alone are insufficient:
   noncanonical initcode can silently grant permissions and return genuine runtime. Use the same source, dependencies,
   compiler and settings as stage 1, and leave its guardian, oracle and risk settings unchanged between stages. Deploy
   with the protocol nonce, without `--batch`, `--tempo.nonce-key`, `--tempo.lane` or `--tempo.expires`; verification
   accepts a single CREATE in a Tempo transaction or a legacy/EIP-2930/EIP-1559 transaction, not factory deployments.

   If stage 1 used solc, do not finish it with this checkout's default Solar compiler: the creation-input check
   will correctly reject the different bytecode. Use a separate checkout of stage 1's recorded source revision
   (for example, `git worktree add ../propamm-stage1 <stage1-commit>`), restore that revision's pinned dependencies
   and toolchain, and run `STAGE=controller` there with the original configuration and mined receipt fields.
   Keep its build outputs separate; do not disable the creation-input check or substitute a merely similar revision.

   The history query runs from `POOL_DEPLOYMENT_BLOCK` through the simulation block in ranges of at most 100,000
   blocks. It requires the pool's constructor ownership event, so a later start block cannot hide older grants.
   Previously granted accounts are acceptable only after both permissions are revoked. Missing deployment history
   or a failed RPC query aborts before any transaction; use an RPC that returns complete logs.

   It then deploys the controller and calls `transferOwnership(controller)`. If `CONTROLLER_OWNER_ADDRESS` is the
   deployer, the controller accepts through `execute(acceptOwnership())` in the same run. Otherwise the script prints
   that call, and the deployer remains the pool owner, with withdrawal authority, until the controller owner sends it.
   Stage 2 never unpauses: if the guardian paused the pool between stages, it reverts and leaves that decision to the
   operator.

`STAGE=all` runs both stages in one broadcast, for liquidation addresses that already exist, only when
`ORACLE_OWNER_ADDRESS` explicitly equals `DEPLOYER_ADDRESS`. An external oracle owner needs a separate acceptance:
use `pool`, accept oracle ownership, then `controller`. Otherwise `all` aborts before any broadcast.

No stage admits a taker or recipient, and the controller stage refuses surviving permissions from earlier owners.
After a successful handover, nothing can trade until the controller owner calls
`execute(setTakerAllowed(router, true))` and `execute(setRecipientAllowed(router, true))`. Set `EARN_ROUTER_ADDRESS`
to print the exact calldata. A supplied router must resolve to itself and be authorized to send and receive both
pair tokens under their current TIP-403 policies; a policy refusal aborts before broadcasting or printing admission
calldata. These checks are point-in-time, not proof of router identity. Independently review the address, chain,
implementation and upgrade authority, and repeat the checks immediately before signing. A code-less address warns
rather than rejects; if the router input is omitted, no router is checked, so perform that review and both tokens'
sender/recipient checks before preparing admission calls yourself. The deployment script never submits either
admission call.

Earn's `SingleZoneEarnRouter` swaps only at exactly `10 ** oracle.decimals()` with zero price tolerance and no
timestamp floor, and requires equal token decimals. The script fixes the par price. Every stage reads both tokens and
the symbol each must report (`BASE_TOKEN_SYMBOL`, `QUOTE_TOKEN_SYMBOL`), and refuses a zero token, the same token
twice, a symbol mismatch and unequal decimals; any equal decimals work, and the pool's price scale is then `1e8`. It
rejects zero or virtual role addresses, and zero, equal or transfer-policy-blocked liquidation addresses. It reads each
token's own TIP-403 transfer policy, whatever its id, and checks that the deployer may send what it funds and that the
pool can send and receive both tokens.

The postconditions check:

- the oracle and every pool and controller binding, including both tokens and their decimals;
- the unpaused state, par anchors and inventory;
- cleared allowances;
- the stage's ownership state;
- no permissions on the deployment roles; for an existing pool, the preflight also checks every account discovered
  in its permission-event history.

These checks run in Forge's simulation, so a failure prevents the broadcast. Read the mined state again afterwards.
The deployer can still change permissions until ownership is accepted: recheck the full permission history before a
separate controller-owner acceptance, and do not treat an earlier simulation as a guarantee of the later state.

Risk choices:

- `MAX_ORACLE_AGE` (default 30 days, at most 365 days). The par feed asserts a policy, not an observation, so
  freshness adds no price protection. It is a liveness heartbeat: once it lapses, swaps, keeper rebalances and stage 2
  revert until the reporter calls `pushPrice(100000000, now)` with a strictly later timestamp. Stage 2 must run within
  this window after the last push. Respond to a depeg with the guardian's `pause()`, not the oracle.
- `MAX_PRICE_DEVIATION_BPS` (default 0, at most 100). The anchors start at par, so 0 makes any off-par push halt swaps
  and rebalances instead of moving the price. It also prevents anchor ratcheting and limits a compromised reporter to
  a denial of service. A nonzero value gives the Earn router nothing, since it requires exact par.
- Initial inventory is capped at 1,000 whole tokens per side, in the tokens' decimals; add more later by direct
  transfer to the pool.
- Stage 1 leaves the pool active and deployer-owned with no taker. The deployer must keep it unpermissioned between
  stages; stage 2 rejects any surviving grants.

| Variable | `pool` | `controller` | Notes |
| --- | --- | --- | --- |
| `STAGE` | required | required | `pool`, `controller` or `all` |
| `DEPLOYER_ADDRESS` | required | required | Sends every transaction; must own the pool in stage 2 |
| `BASE_TOKEN`, `QUOTE_TOKEN` | required | required | Distinct TIP-20s of equal decimals; stage 2 requires the pool's own, in order |
| `BASE_TOKEN_SYMBOL`, `QUOTE_TOKEN_SYMBOL` | required | required | The symbol each token must report |
| `GUARDIAN_ADDRESS` | required | not read | Stage 2 keeps the pool's guardian |
| `ORACLE_OWNER_ADDRESS`, `ORACLE_REPORTER_ADDRESS` | required | required | Granted after anchor capture; controller requires accepted owner, no pending nomination and matching reporter |
| `MAX_ORACLE_AGE`, `MAX_PRICE_DEVIATION_BPS` | optional | not read | Default 30 days and 0 bps |
| `INITIAL_BASE_AMOUNT`, `INITIAL_QUOTE_AMOUNT` | optional | not read | Raw units of the tokens' decimals, default 0, at most 1,000 tokens |
| `POOL_ADDRESS` | must be unset | required | Printed by stage 1 |
| `POOL_DEPLOYMENT_BLOCK` | not read | required | Exact pool creation block from the mined stage-1 receipt; history must include its constructor event |
| `POOL_CREATION_TX` | not read | required | Pool creation transaction hash; the active RPC must return its canonical input and successful receipt |
| `ORACLE_ADDRESS` | not read | optional | Checked against the pool's oracle |
| `CONTROLLER_OWNER_ADDRESS`, `KEEPER_ADDRESS` | not read | required | |
| `BASE_LIQUIDATION_ADDRESS`, `QUOTE_LIQUIDATION_ADDRESS` | not read | required | Bridge addresses for the base and quote tokens |
| `EARN_ROUTER_ADDRESS` | not read | optional | Only prints the admission calldata |

`STAGE=all` uses every variable except `POOL_ADDRESS` (which must be unset), `POOL_DEPLOYMENT_BLOCK`,
`POOL_CREATION_TX` and `ORACLE_ADDRESS`. It constructs the pool itself, so it needs no prior creation evidence. Blank optional entries take their defaults.

Copy `contracts/script/config/par-pool.env.example` to ignored `.env.par-pool` and fill it. Then test and simulate each
stage:

```bash
set -a
source .env.par-pool
set +a

forge test --match-contract DeployParPoolTest -vv

# Stage 1: STAGE=pool in the env file.
forge script contracts/script/DeployParPool.s.sol:DeployParPool \
  --rpc-url "$TEMPO_RPC_URL" --network tempo \
  --sender "$DEPLOYER_ADDRESS" --tempo.fee-token PathUSD -vvvv

# Stage 2: after Bridge creates the liquidation addresses, set STAGE=controller, POOL_ADDRESS,
# POOL_DEPLOYMENT_BLOCK, POOL_CREATION_TX, ORACLE_ADDRESS and both liquidation addresses, source the file again,
# and run the same command.
```

After reviewing a stage's simulated transactions, an authorized operator adds the deployer's keystore and
password-file flags and `--broadcast` to the same command. A stage's transactions are sequential, not atomic. If one
fails, reconcile the mined state before rerunning, since a rerun of stage 1 deploys a new pool and a rerun of stage 2 a
new controller.

## Emergency procedure

1. On `DirectPropAMM`, guardian or owner calls `pause()`. On a `ManagedDirectPropAMM`, only the owner can pause,
   close one pair (`closePair`), deny accounts, or switch off or remove a sponsor ([Managed pools](#managed-pools)); only the owner reopens, lifts a denial
   or restores a sponsor.
2. Confirm swaps revert while paused.
3. Diagnose oracle freshness, inventory, policy, and recipient resolution before making any change.
4. Oracle, freshness, or price-anchor changes can only be made while paused (on a `ManagedDirectPropAMM`, while that
   pair is `Closed`; reopening it re-checks the oracle and anchors). Call
   `resetPriceAnchor(direction)` only after independently validating a legitimate move; repeated
   in-band trades can otherwise ratchet that direction's anchor. On a live `ManagedDirectPropAMM` pair use
   `refreshPriceAnchor(pairIndex, direction, expectedPrice, toleranceBps)` with the validated price, so a different
   price at execution reverts instead of becoming the anchor.
5. If inventory must be removed, the owner calls `withdraw()` while paused and verifies the exact resolved-recipient delta.
   A `ManagedDirectPropAMM` owner can withdraw any token without pausing, to an account only: it refuses a TIP-1022
   virtual address (`VirtualRecipient`) and checks the exact credit on the recipient itself, so to move inventory to a
   Bridge liquidation address, withdraw to an account and send it from there. The pool's inventory of a token backs
   every pair that uses it.
6. Only the owner can call `unpause()`, which requires a currently valid observation within the
   configured price gap unless the owner deliberately reset the anchor while paused. A `ManagedDirectPropAMM`'s
   `unpause()` checks no oracle; reopening each closed pair with `setPairAccess` does.
