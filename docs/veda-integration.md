# Earn → Veda → BoringVault integration

## Required topology

This guide connects Earn, which issues EarnShare, to Veda's BoringVault, which holds the investment assets.
The VedaEngine is Earn's adapter to that vault; the Teller handles deposits and withdrawals, and the Accountant
values vault shares. PRIME is the investment token (base); pathUSD is the deposit and payout token (quote).
`DirectPropAMM` is the single-pair oracle-priced pool; `ManagedDirectPropAMM` holds multiple pairs.
The [v1 guide](../contracts/README.md) defines their pricing and access controls.

The EarnVault asset, Veda Accountant base, Teller deposit/withdraw asset, and user payout asset are
all pathUSD. PRIME is a managed asset held only inside the BoringVault. The helper, `DirectPropAMMBufferHelper`, builds the vault's swap calls. A Teller buffer hook is a
callback during a deposit or withdrawal: it asks this helper for token approvals and a swap, then
executes those calls from the BoringVault.

```text
Deposit
user pathUSD
  -> EarnVault
  -> VedaEngine.deposit(pathUSD)
  -> TellerWithYieldStreaming.bulkDeposit(pathUSD)
  -> BoringVault receives pathUSD and mints raw shares to VedaEngine
  -> Teller deposit buffer hook
  -> BoringVault.manage(pathUSD approvals + DirectPropAMM exact-input swap)
  -> BoringVault holds PRIME
  -> EarnVault mints EarnShare to user

Immediate redemption
EarnVault pulls and burns the user's EarnShare
  -> VedaEngine.redeem(raw BoringVault shares)
  -> TellerWithYieldStreaming.bulkWithdraw(pathUSD)
  -> Teller withdrawal buffer hook
  -> BoringVault.manage(PRIME approvals + DirectPropAMM exact-output shortfall swap, if needed)
  -> BoringVault holds the exact required pathUSD
  -> BoringVault.exit burns raw shares and sends pathUSD to the user
```

All steps in either flow are one transaction. A failed oracle read, pool permission, inventory
check, swap, or final transfer reverts the entire flow, including share minting or burning.

## Closed-loop admission

Two independent default-deny layers are active:

- DirectPropAMM allows only the BoringVault as taker and resolved recipient. Users, EarnVault,
  VedaEngine, Teller, helpers, and deployment wallets cannot call the swap path unless the pool owner
  explicitly changes the mapping.
- EarnShare uses TIP-403, Tempo's token-transfer access control, with a whitelist policy. A user must be a sender,
  recipient, and mint recipient under this policy to receive shares and redeem them.

Policy administration is intentionally external to this repository. Keep EarnVault, EarnFees, and
the configured fee recipient admitted, use a policy-admin key from an external secret store, and
verify all three authorization modes after every change. Admission controls access to EarnShare and
its yield claim. A third party can still donate pathUSD by calling `deposit` for an admitted
receiver, but it cannot receive shares or access yield unless it is itself admitted.

## Why the helper is in this repository

`DirectPropAMMBufferHelper` implements only the public ABI of Veda's `IBufferHelper`; it does not
copy or import Veda source. Earn and Veda are separately versioned external integration dependencies;
this repository compiles and tests the helper against the local interface and a mock BoringVault. The
helper is stateless and returns four BoringVault management calls when a swap is required. A withdrawal
returns no calls when the BoringVault's existing pathUSD balance already covers the redemption:

| Hook | Calls executed by BoringVault |
| --- | --- |
| Deposit | clear pathUSD allowance; approve input; exact-input pathUSD→PRIME; clear allowance |
| Withdraw | subtract existing pathUSD; if a shortfall remains, clear PRIME allowance; approve maximum input; exact-output PRIME→pathUSD for the shortfall; clear allowance |

The helper reads the pool quote in the same transaction. `DirectPropAMM` has no swap fee or curve
slippage. The helper also supports the multi-pair `ManagedDirectPropAMM`, whose optional pair hook quotes
the input-token fee. The helper passes the BoringVault address, the account that will
call the swap—not the helper, Teller, EarnVault or end user. This guide's Earn setup requires zero fees
for that vault on that pair, but the helper does not enforce that requirement
([Hook fees and vault accounting](#hook-fees-and-vault-accounting)). Its immutable `slippageBps`
constructor parameter permits additional deviation from the quote in basis points (100 bps = 1%), not a
maximum fee. If hook policy charges a nonzero vault fee, the vault pays it even at zero quote tolerance.
The stateless exact-input quote is a safe minimum and the stateless exact-output quote is a safe maximum. Route credit (fractional rounding value the pool records for the vault's accounting route) can only improve
the actual execution relative to those bounds. The generated swap passes zero oracle-price tolerance,
treats the quoted effective timestamp as a minimum, and uses the current transaction timestamp as its
deadline. Consequently, the Teller must construct and execute the management calls atomically. A newer
observation at the same price remains valid, but any price change requires a new helper quote. The
helper cannot move funds itself. Replacing a pool, BoringVault, customer ID, or quote-tolerance policy
requires a new helper and an explicit Teller configuration change.

## Atomic rounding credit

Token amounts are integers, while the oracle conversion usually is not. Pools deployed from the
current source retain the discarded fractional value in a ledger keyed by the allowed taker,
resolved recipient, and customer ID (on a `ManagedDirectPropAMM`, by pair, taker and customer ID,
`roundingRouteKey(pairIndex, taker, customerId)`: it pays the taker, and credits never mix pairs). For example, if an
exact-input deposit mathematically buys
`47,550.620...` base atoms, the vault receives `47,550` and its route retains the remainder. An
inverse exact-output redemption uses that remainder before rounding its required base input, so a
full round trip at the same oracle price consumes exactly the base atoms the deposit produced only
when both of the vault's directional swap fees are zero throughout. Managed-pool fees are not rounding credit and
are never recovered by the inverse trade; a nonzero fee breaks this exact round-trip guarantee.

`quoteExactInputFor` and `quoteExactOutputFor` include the current route credit and return the credit
that would remain after execution. The stateless `quoteExactInput` and `quoteExactOutput` deliberately
ignore credit so integrations that do not identify a route still receive conservative limits. On a managed
pool their signatures are `(uint16 pairIndex, address taker, bool baseToQuote, uint256 amount)`; the helper
passes the BoringVault as `taker` for both. The managed route-aware signatures still take
`(pairIndex, taker, customerId, baseToQuote, amount)`; only the stateless signatures gained the taker argument.
Credit cannot cross takers, resolved recipients, or customer IDs. Oracle replacement is restricted
to the deployed oracle decimal precision because changing that precision would change the credit's
unit. A new oracle with the same decimals may still be installed while the pool is paused.

This ledger is part of newly deployed pool bytecode. It cannot retrofit an already deployed,
immutable DirectPropAMM.

## USDY pool variant

The helper is pair-generic: a dedicated pool may use USDY as its base token and pathUSD as its quote token
without changing the helper or Teller ABI. Deposits then convert pathUSD to USDY, and withdrawals sell only the
USDY needed to cover the BoringVault's pathUSD shortfall. Deploy a separate pool and helper for each immutable
pair; do not share inventory through a helper.

For USDY, use `OndoUSDYPriceOracleAdapter` only with an official same-chain Ondo wrapper. It returns the wrapper's
price and the current block time, and reads nothing behind the wrapper, so Ondo source replacements need no adapter
change as long as the wrapper keeps `getPriceData()`. Helper execution is bound to the price quoted in the same
transaction. The adapter fails closed only on a zero price or a wrapper that stops answering. This does not replace
Accountant reporting: the BoringVault's USDY position must still be valued and reconciled at the Veda accounting
boundary, including the `1 pathUSD = 1 USD` assumption. A NAV engine reading the adapter must move to a replacement
adapter with the pool.

## External integration requirements

This repository does not ship Veda or Earn deployment/configuration scripts. Integrators must use
the upstream projects' tooling and independently verify these bindings. For Earn behavior and
integration guidance, consult the Earn project's current documentation; Earn is not vendored here.

| Binding | Required value |
| --- | --- |
| `EarnVault.asset()` | pathUSD `0x20C0000000000000000000000000000000000000` |
| `VedaEngine.baseAsset()` | pathUSD |
| `VedaEngine.vault()` | intended BoringVault |
| `VedaEngine.teller()` | intended `TellerWithYieldStreaming` |
| `Teller.vault()` | same BoringVault |
| `Accountant.base()` | pathUSD |
| DirectProp pool base | PRIME `0x20C00000000000000000000058d0B8b2CFDb358c` |
| DirectProp pool quote | pathUSD |

### Adding propAMM after launch

An active vault can add propAMM without redeploying the vault when its deployed Teller inherits
`TellerWithBuffer` and the authority still permits the required configuration calls. A Teller that
was deployed without buffer support cannot gain these hooks through configuration alone.

For a live integration:

1. Pause deposits and withdrawals for the affected asset.
2. Deploy and fully configure the propAMM pool, with the BoringVault as both its allowed taker and
   resolved recipient.
3. Deploy a new `DirectPropAMMBufferHelper` bound to that pool and the existing BoringVault.
4. Verify that the Teller is authorized to call the BoringVault batch
   `manage(address[],bytes[],uint256[])` function.
5. From an authorized Veda administration account, call `allowBufferHelper(pathUSD, helper)`, then
   set the helper with both `setDepositBufferHelper(pathUSD, helper)` and
   `setWithdrawBufferHelper(pathUSD, helper)`.
6. Simulate a small deposit and withdrawal, verify balances and allowances, then unpause.

The helper address can be changed later through the same allow-and-set sequence. Treat permission
to allow a helper as vault-manager authority: the Teller executes every call returned by the
selected helper from the BoringVault, so a malicious helper can spend vault assets. Disallowing a
helper does not unset an already selected helper; first set both hooks to zero or a replacement,
then disallow the old helper.

Deploy `DirectPropAMMBufferHelper` with the final pool, BoringVault, customer ID, and quote-tolerance
values, plus `pairIndex` and `sponsorId` (both 0 for a `DirectPropAMM`), using external tooling.
The Veda authority must allow and select it for both Teller buffer
hooks, permit Teller to call the BoringVault batch `manage(address[],bytes[],uint256[])` function,
and grant VedaEngine permission for Teller `bulkDeposit` and `bulkWithdraw`. Simulate and verify all
constructor values, permissions, and deployed bytecode before use.

With the DirectProp pool owner, configure the BoringVault—not the helper, Teller, VedaEngine, or
EarnVault—as both pool taker and recipient. First simulate without sending:

```bash
export POOL_ADDRESS=0x...        # the DirectPropAMM pool
export POOL_OWNER_ADDRESS=0x...  # its current owner, whose signer will send
export TAKER_ADDRESS=0x...       # the BoringVault
export TAKER_ALLOWED=true
export RECIPIENT_ADDRESS=0x...   # the same BoringVault
export RECIPIENT_ALLOWED=true

forge script contracts/script/ConfigurePool.s.sol:ConfigurePool \
  --network tempo --rpc-url "$TEMPO_RPC_URL" --sender "$POOL_OWNER_ADDRESS"
```

This is simulation only. After reviewing both requested permissions, send them with the owner's signer and
Forge's `--broadcast` flag:

```bash
forge script contracts/script/ConfigurePool.s.sol:ConfigurePool \
  --network tempo --rpc-url "$TEMPO_RPC_URL" --sender "$POOL_OWNER_ADDRESS" --broadcast \
  --keystore /absolute/path/to/pool-owner.keystore \
  --password-file /absolute/path/to/pool-owner.password
```

Wait for successful mined receipts for both changes, then read the permissions from the chain. A successful
simulation is not inclusion; these calls are separate transactions, so inspect both if sending is interrupted.
The recipient permission belongs to the address the pool resolves, not an unresolved payment alias:

```bash
set -e
actual_taker=$(cast call "$POOL_ADDRESS" 'takerAllowed(address)(bool)' "$TAKER_ADDRESS" --rpc-url "$TEMPO_RPC_URL")
resolved_recipient=$(cast call "$POOL_ADDRESS" 'resolveRecipient(address)(address)' "$RECIPIENT_ADDRESS" --rpc-url "$TEMPO_RPC_URL")
actual_recipient=$(cast call "$POOL_ADDRESS" 'recipientAllowed(address)(bool)' "$resolved_recipient" --rpc-url "$TEMPO_RPC_URL")
test "$actual_taker" = "$TAKER_ALLOWED"
test "$actual_recipient" = "$RECIPIENT_ALLOWED"
```

Do not enable the buffer until these reads match the reviewed values. If the pool is owned by a contract rather
than the signing account, submit the two calls through that owner's execution mechanism instead, then perform
the same readback.

### On a `ManagedDirectPropAMM`

A managed pool holds many pairs. Its swaps name the pair and the list that admits the caller (`pairIndex`,
`sponsorId`) and pay the caller, the BoringVault. The helper detects a managed pool at construction (it answers
`pair(pairIndex)`) and encodes those swaps instead; one helper serves one pair, whose base the vault holds and whose
quote is its asset.

#### Hook fees and vault accounting

For production Earn use, prefer no pair hook, which means zero fees and no callbacks. Otherwise verify the
hook charges the BoringVault zero in both directions and review its policy administration and upgrade authority.
The helper quotes for the BoringVault, not the depositor, helper or Teller. Per-taker mappings and defaults
belong entirely to the hook; the pool has no native fee table. All depositors share this vault identity.

Only the pool owner selects a hook with `setPairHook(pairIndex, hook, flags)` while the pair is `Closed`;
read its address and callback-selection flags with `pairHook(pairIndex)`
([callback flags](../contracts/README.md#pair-hooks-and-fees)). A hook's quote fee is capped at 1,000 bps (10%), but zero at activation
is not a permanent guarantee. Monitor hook selection and hook-specific policy changes. Hooks cannot bypass
pool access or oracle checks, take pool-token custody or decrease either pair-token balance.

Zero vault fees remain an operational requirement, not a helper check: its limits use fee-inclusive quotes
and its `slippageBps` is not a fee cap. Reconcile PRIME and quote inventory with Accountant NAV even without
a hook; neither pool, helper nor hook updates that valuation boundary automatically.

If fees are enabled for the vault, the BoringVault pays them from its own assets: deposits pay the quote-to-base
fee in pathUSD and receive less PRIME; redemption shortfall swaps pay the base-to-quote fee in
PRIME and consume more PRIME. Fees stay in the pool, outside the vault's backing. A redemption
already covered by the vault's pathUSD inventory makes no swap and pays no pool fee. Fees apply only
to fresh input, not to value supplied by existing route credit.

For example, at 1 PRIME = 1 pathUSD with six decimals and no route credit, a 100 pathUSD deposit
with a 1% quote-to-base fee for the vault leaves 99 PRIME. With a 1% base-to-quote fee, only 99% of fresh PRIME
input buys pathUSD. Redeeming the original 100 pathUSD therefore needs `ceil(100 × 1,000,000 / 0.99) / 1,000,000 = 101.010102` PRIME. A vault holding only
that deposit's 99 PRIME cannot fund the redemption. Other vault inventory may cover the gap, but doing so consumes backing rather than
restoring an exact round trip.

Do not enable nonzero fees for the BoringVault on this pair without a separately reviewed accounting and
withdrawal-liquidity policy that allocates those costs. The propAMM oracle and helper do not update
the Veda Accountant's share price. A fee-aware integration must reconcile deposit costs and
realizable exit value with that accounting boundary; quote tolerance alone does not protect
remaining holders from paying another user's costs.

#### Managed-pool setup

1. Admit the BoringVault on the vault's pair: on the pair's home list (`MODE=LIST PAIR_INDEX=<pair> ACCOUNTS=<BoringVault>`
   with `ManagedPoolAccess.s.sol`, sponsor 0), or on a sponsor's list there, which its admin sends
   (`MODE=LIST PAIR_INDEX=<pair> SPONSOR_ID=<id> ACCOUNTS=<BoringVault>`), the sponsor switched on and admitted on the
   pair.
2. Deploy `DirectPropAMMBufferHelper(pool, BoringVault, customerId, slippageBps, pairIndex, sponsorId)` with that pair
   and sponsor id (0 for the home list). An unknown or removed pair reverts `InvalidPair`. For a `DirectPropAMM` pass
   0 for both; anything else reverts `PairIndexUnsupported` or `SponsorIdUnsupported`.
3. Verify `helper.managed()`, `helper.pairIndex()` and `helper.sponsorId()`, the helper's base and quote against
   `pool.pair(pairIndex)`, and that `pool.takerAccess(pairIndex, BoringVault, sponsorId)` reads `Allowed` (1). Any
   other value names the refusal a swap would revert with.
4. The helper's quotes check no access or pause, so a refusal surfaces at the swap, with the pool's
   own error, and the Earn deposit or redemption reverts in full: a closed pair (`TakerNotAllowed`), a denial
   (`TakerDenied`), a sponsor switched off (`SponsorDisabled`) or removed from the pair (`SponsorNotAdmitted`), a
   sponsor reset (`TakerNotAllowed` until its new admin re-lists the vault). Managed pools have no taker priority-fee cap.

## NAV and yield reporting

The DirectProp oracle prices swaps; it does not update the BoringVault share price. Veda's
YieldStreaming Accountant must remain pathUSD-denominated, and its authorized strategist/reporting
process must mark the vault's PRIME position to pathUSD and post gains or losses. `VedaEngine`
rejects new deposits when the latest strategist report exceeds its configured `maxRateAge`.

This separation is important: holding PRIME produces Earn yield only when PRIME's pathUSD value or
its economic backing increases and that change is correctly reported to the Accountant. Do not
mark PRIME at cost indefinitely, and do not treat the pool's Chainlink quote as a complete NAV
service. The reporting process must reconcile at least BoringVault PRIME and pathUSD balances,
current PRIME/pathUSD value, realizable exit value after the vault's configured swap fees, pool inventory,
and any active vest or loss. See the canonical
[Veda engine accounting guide](https://github.com/tempoxyz/contracts/blob/3f62b97521ea11e71f893ac0efe3b98d3018f258/docs/earn/modules/veda.md)
for the engine's Accountant-rate and measured-payout checks; they do not remove pool swap costs.

## Liquidity and failure behavior

- Deposits consume PRIME from the DirectProp pool and add pathUSD to it.
- Redemptions consume pathUSD from the pool and return PRIME to it.
- The pool is permissioned inventory, not an LP vault; it must be sized for the largest supported
  atomic deposit and redemption shortfall after available BoringVault pathUSD is considered.
- Pausing the pool or exhausting either output inventory intentionally makes the corresponding
  synchronous Earn action revert.
- A `ManagedDirectPropAMM` owner can withdraw inventory while the pool is active, with effect from
  the next swap. Keep what is left above the largest supported deposit and redemption shortfall; an
  Earn action that needs more reverts in full.
- A `ManagedDirectPropAMM`'s inventory is shared per token by every pair that uses it, with no per-pair reservation:
  swaps on another pair can use up the quote token the vault's redemptions need, and a wrong oracle on another pair
  can sell it. Size each token for every flow it must cover, and keep a vault's tokens in a pool whose other pairs
  carry acceptable oracle risk.
- A queued Veda redemption is not automatically compatible with this synchronous buffer design;
  do not enable it until the solver path is tested with the same required PRIME→pathUSD unwind.
- A pool that reads a `PushPriceOracle` depends on its reporter: each pushed timestamp must be the source report's
  observation `startedAt`, not its later onchain recording `updatedAt`. The pricing model assumes pathUSD remains
  worth one US dollar.

## Activation checklist

Keep the live pool paused during preparation; unpause only the fork for rehearsal, then the live pool in step 9:

1. Verify the intended Veda release, license, deployed bytecode, RolesAuthority, Teller, Accountant,
   BoringVault, and optional Queue as a single reviewed deployment.
2. Verify every address and base-asset binding in the table above.
3. Verify the helper's immutable pool, vault, token pair, customer ID, zero quote tolerance, and for a managed pool
   `managed`, `pairIndex` and `sponsorId`. Require no pair hook or verify zero hook fees for the vault in both
   directions, including policy/upgrade authority. Monitor hook selection and policy changes; the helper does
   not enforce zero fees. Reconcile the vault's PRIME and quote balances against Accountant NAV.
4. Verify both Teller buffer-helper selections and the Teller's BoringVault batch-manage authority.
5. Verify VedaEngine has only the required Teller bulk capabilities and is bound to the EarnVault.
6. Verify the BoringVault is the pool's allowed taker and resolved recipient (on a managed pool:
   `takerAccess(pairIndex, BoringVault, sponsorId) == Allowed`, and the pair is `Listed`).
7. Verify a fresh Accountant report includes the PRIME position and satisfies `maxRateAge`.
8. Fund deliberately small two-sided pool inventory and rehearse deposit and redemption on a mainnet fork.
9. Unpause, execute a tiny mainnet pathUSD deposit and full round-trip redemption, and reconcile
   EarnShare supply, BoringVault shares, PRIME/pathUSD balances, pool events, oracle price, and NAV.
   The exact round-trip check assumes unchanged oracle price and zero fees for the vault in both directions.
10. Re-pause before increasing inventory or caps; complete independent security review before a
    production launch.
