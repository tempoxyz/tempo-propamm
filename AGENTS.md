# Agent context

propAMM is a monorepo for its Solidity contracts and its Rust and TypeScript SDKs. Solidity sources, tests and
scripts live in `contracts/`; the Cargo workspace contains `sdk/rust`; `sdk/ts` is a self-contained npm project. Run
Foundry and Cargo from the repository root, and npm from `sdk/ts`. Keep the repository focused on contracts, SDKs,
tests, deployment/configuration scripts and their documentation. Do not add a UI, hosted worker or customer-specific
application layer.

## Read first

- `README.md`: landing page: the two designs, which guide each role reads, and the SDKs.
- `contracts/README.md`: v1 guide: `DirectPropAMM`, `ManagedDirectPropAMM`, the rebalance controller and their gas
  tables.
- `docs/veda-integration.md`: Earn, Veda, BoringVault, Teller, Accountant, and buffer-helper flow.
- `docs/deployment.md`: deployment and operational checks.
- `spec/propamm-v2.md`: propAMM v2 design and the reasons behind it.
- `contracts/src/v2/README.md`: propAMM v2 guide for makers, sponsors and takers, with its gas tables.
- `docs/v2-deployment.md`: propAMM v2 core deployment, Moderato demo venue and trust model.
- `.github/workflows/verify.yml`: canonical pull-request validation commands.
- `sdk/rust/README.md`: Rust SDK guide: maker API, units, sequence and cancellation semantics.
- `sdk/ts/README.md`: TypeScript SDK guide (also its npm page): units, roles, the fee cap.

The READMEs are external integration guides. Build, test, CI, release and contributor material belongs in this file,
and deployment operations in `docs/`.

For changes involving Earn or Veda behavior, consult the canonical
[`tempoxyz/contracts`](https://github.com/tempoxyz/contracts/) repository and its root
[`AGENTS.md`](https://github.com/tempoxyz/contracts/blob/main/AGENTS.md) from the current default branch.
Earn is not vendored in this repository. Use the current Earn guidance for its accounting and engine
invariants, but keep propAMM-specific implementation and documentation in this repository.

## Contract and integration invariants

Managed access terms: a sponsor is a business administering a per-pair taker allowlist; the owner's
home list has sponsor ID 0, and registered sponsors use nonzero IDs. The owner admits a sponsor's list
on a pair before its members can trade there. Each pair has an access mode: `Closed` refuses all trades,
`Listed` requires membership on the selected list, and `Open` admits any caller; pool-wide denials override
either grant. The Settler is the separate contract callers approve to transfer input and execute prepaid
pool fills; a router calls it as the taker rather than forwarding an underlying user's identity.


- The pool is permissioned inventory, not a constant-product AMM or LP vault.
- A fresh guarded oracle observation determines execution price; pool inventory determines capacity.
- Only allowed takers and resolved recipients may settle swaps. `ManagedDirectPropAMM` direct swaps pay
  their caller and names the pair (`pairIndex`, from 0, never reused) and the list it trades under (`sponsorId`: 0 for
  the pair's home list, which only the current owner edits, or a sponsor the owner registered, switched on and
  admitted on the pair, whose lists only its admin edits). At zero fees each pair prices exactly like one
  `DirectPropAMM`, with its own oracle, freshness, deviation limit, directional anchors and `(pairIndex, taker, customerId)` credit routes, and
  `DirectPropAMM`'s errors byte for byte; inventory is the pool's balance of each token, shared by every pair that uses
  it, with no per-pair reservation. Access re-implements v2 `Venue`'s sponsor, admission, member,
  generation and deny-list semantics in the pool's storage (v2 is audit-locked, so nothing is shared,
  and nothing calls TIP-403). Managed access has no guardian or taker priority-fee cap: emergency
  controls (pause, `closePair`, deny, switch a sponsor off, remove an admission) are owner-only.
  `AccessMode` values match v2; managed `TakerAccess` omits `PriorityFeeTooHigh`, so compare refusal
  meanings rather than raw enum ordinals. The remaining access check order, events and errors follow v2.
  `Open` is entered only while the pool is paused; a pair's oracle and risk settings and `resetPriceAnchor` change only while it is `Closed` (the owner's
  `refreshPriceAnchor` moves an anchor on a live pair, only to a fresh price within its own expected-price bound), and leaving
  `Closed` runs `DirectPropAMM.unpause`'s oracle and anchor checks for that pair; the pool-wide `pause` stops every swap
  and only the owner unpauses, with no oracle check. All mutable pool entry points, including role and access
  administration, share the reentrancy lock so callbacks cannot mutate them. Every owner power is checked
  against the current owner when it is used. `deniedCount` always equals the number of denied accounts, and a swap reads the deny list only while it is nonzero. Keep `DirectPropAMM` unchanged, and keep
  both differentials passing: zero-fee v1 pricing pair by pair (`contracts/test/managed/ManagedDirectPropAMMDifferential.t.sol`) and v2
  access op by op (`contracts/test/managed/ManagedVenueAccessDifferential.t.sol`).
- Managed pairs support one optional hook, selected only by the owner with
  `setPairHook(uint16 pairIndex, address hook, uint8 flags)` while the pair is `Closed`; read it with
  `pairHook(pairIndex)`. No hook means zero fees and no external hook calls. `QUOTE` is a static/view callback
  returning `feeBps`, capped by the pool at `MAX_HOOK_FEE_BPS = 1000` (10%). `BEFORE_SWAP` and `AFTER_SWAP`
  are state callbacks requiring their selector acknowledgments. View calls are capped at 200,000 gas; each state callback at 5,000,000.
  `QuoteContext` contains `pairIndex`, named `taker`, `baseToQuote`, `exactInput`, and requested `amount`;
  quotes accept any named taker without authentication or access proof; only execution authenticates it.
  `SwapContext` also identifies sponsor, customer, trade, actual funding/payout caller, tokens and gross amounts.
  Custom mappings, defaults and policy administration belong entirely to hooks, not pool fee tables.
  Hooks have no token custody or `hookTake`, cannot decrease either pair-token balance, and cannot bypass
  core access, oracle, exact-transfer, rounding or slippage checks. Fees stay in shared inventory. Exact input
  charges `ceil(grossInput * feeBps / 10000)`; exact output grosses up required net input as
  `ceil(netInput * 10000 / (10000 - feeBps))`. Credit-only output requires no new input fee.
  Caller identity is not forwarded: hooks receive the direct caller or the Settler's immediate caller as taker,
  which funds and receives tokens. For routed swaps this is the router, not its underlying user. Preserve no-hook
  `DirectPropAMM` pricing/error differentials and the v2 access differential. `DirectPropAMM` and v2 are unchanged.
  This rework is the core Sigma Prime audited at `0569025` and needs a new immutable deployment; historical demos do
  not implement it. Any change to the audited managed sources needs a new review.
- The buffer helper quotes managed pools for the BoringVault, the actual swap caller. Earn production requires
  no hook or a verified zero vault fee in both directions, plus Accountant NAV reconciliation. The helper has
  no independent fee cap, and neither hook nor pool updates Accountant NAV. Review hook policy and upgrade
  authority, not just its current quote, before relying on zero fees.
- Token movement must match exact pool and recipient balance deltas.
- Only the owner funds or withdraws inventory, and funding works paused or not. `DirectPropAMM` withdraws only while
  paused; `ManagedDirectPropAMM` withdraws any token paused or not, because a withdrawal changes no swap's price, only
  its capacity, and funds only a token some live pair uses. Both keep the reentrancy lock the swaps share.
  `DirectPropAMM` resolves the recipient through the TIP-1022 address registry: it pays the address as given, requires
  the exact debit on the pool and the exact credit on its resolution, and rejects zero, a zero resolution and a
  resolution to the pool, so a registered virtual address (a Bridge liquidation address) pays its master.
  `ManagedDirectPropAMM` supports no TIP-1022 virtual address, as v2 `Venue`: it holds no address registry and resolves
  nothing, its `withdraw` refuses zero and the pool (`InvalidAddress`) and any virtual address, registered or not
  (`VirtualRecipient`), and requires the exact debit on the pool and the recipient's own exact credit; to pay a
  virtual address, withdraw to an account and send it from there. Its direct swaps pay `msg.sender`; the current settler pays its caller (the router when routed). `DirectPropAMM` changes
  its oracle and risk settings or resets an anchor only while paused; `ManagedDirectPropAMM` only while that pair is
  `Closed`.
- `DirectPropAMMRebalanceController` owns one pool of either kind and calls only `paused`, `pause`, `withdraw` and
  `unpause` on it, after one `pairCount()` probe at construction that tells a `ManagedDirectPropAMM` (which answers it)
  from a `DirectPropAMM`. Its keeper sends a token only to that token's liquidation address, fixed at construction, and
  never undoes a pause. For a `DirectPropAMM` a liquidation address may be a TIP-1022 virtual address, which the pool
  pays the master of; for a `ManagedDirectPropAMM` the constructor refuses one (`VirtualLiquidationAddress`), since
  every rebalance of that token would revert.
- Deposit and withdrawal helper calls execute atomically from the BoringVault through Teller.
- The withdrawal helper must source only the quote-token shortfall after considering quote inventory
  already held by the BoringVault. If existing inventory covers the redemption, it must return an
  empty management batch.
- Preserve quote limits, deadlines, oracle-observation binding, route-credit isolation, and cleared
  token allowances when changing buffer behavior.
- The propAMM oracle does not update Veda Accountant NAV. Any integrated deployment must reconcile
  PRIME and quote inventory against the Accountant valuation boundary.
- Treat Earn and Veda as external integration context. Do not modify private or test-only
  dependencies unless the task explicitly includes the owning repository.

## Managed routing invariants

- Factory clones initialize atomically, only from their immutable factory's deployed code. Standalone pools and the
  implementation cannot initialize again. Clone provenance uses v2's 77-byte runtime and embedded CREATE2 salt,
  verified against the immutable implementation and factory without calls to candidate code or per-pool storage.
- Settler pulls only from its caller, directly into the pool, with the direct path's `SWAP_IN` memo, verifies exact pool credit before fill, and never
  escrows input or approves a pool. Exact-output fills equal quotes; ambient balances never fund swaps.
- Managed Settler exposes only single-pool `swap(pool, params)` for exact input or exact output, without
  explicit taker arguments. Each factory deploys one shared default Settler for its clones. It passes its
  immediate caller as taker to `fill`; direct swaps use their caller. There are no
  identity-forwarding or router-trust APIs. Routers trade only as themselves under normal access rules:
  listing on `Listed`, any caller on `Open`, with denials in either mode. Routers must separately check
  authenticated underlying users through pool `takerAllowed`/`takerAccess`; core execution does not enforce
  that policy, and denying a user does not alone block an admitted router. External Tempo router implementation
  is out of scope. Hooks see the router, and routed credits use `(pairIndex, router, customerId)`; routers must
  partition and authorize customer IDs consistently rather than treating them as authenticated identities.
- Removing forwarded identity is an ABI break from the explicit-taker draft, requiring rebuilt callers and
  new immutable deployments. Direct pool swap APIs and v2 remain unchanged. The audit does not authorize
  production deployment.
- Owner-only `setSettler` rejects zero, takes the swap lock and works without pausing, as in v2. The pool trusts the
  selected settler to authenticate takers and prepay input; a malicious replacement can drain inventory.
- Preserve direct pool swaps and v2 source behavior. Managed standalone constructors use factory zero; factory-bound
  implementations use zero owner and a nonzero immutable factory.

## v2 invariants

propAMM v2 (`contracts/src/v2`; mainnet core deployment recorded in `docs/v2-deployment.md`) is a separate
system priced by maker-posted ladders, not an oracle; the invariants above cover v1 only. `contracts/src/v2/interfaces` is the v2
ABI. The deployed implementation and its venue clones are immutable; changed contract behavior requires a new deployment.
The `contracts/test/v2` suites,
including the stateful campaign in `contracts/test/v2/invariant`, enforce:

- A fill equals `LadderMath` over the posted hot word and active shape, walked from its side's consumed depth: the
  base that side's fills took since the maker last refilled it (`consumed`, one nonzero slot per pair that `addPair`
  creates, so no fill or refill creates a slot). Each fill adds its base to its own side; an opposite trade consumes
  the other side and never gives any back; a side consumed to its depth reverts `InsufficientDepth`, as an over-depth
  fill does. Only an accepted `post` entry with a refill bit (`HotWord` bit 2 bids, bit 3 asks; stored and emitted
  cleared, then `Refilled`) lowers a side's consumption, to 0; a post without one keeps it, in base units of whatever
  ladder is then active. So a split order never beats one fill of its total. Each fill rounds once, toward the
  maker, by less than one unit of the rounded token. Inventory and hook liquidity bound payouts.
- `ShapeWord.check` accepts exactly one canonical encoding per ladder; `setShape` rejects anything else.
- `quote` predicts `fill`: the same amounts from the same posted ladder and consumed depth, or the same revert. It reverts
  `InsufficientInventory` exactly when the venue's balance plus the hook's liquidity (with `BEFORE_FILL` only) can't
  cover the output.
- No `fill` or `quote` succeeds in a transaction whose priority fee per gas (`tx.gasprice - block.basefee`, 0 when the
  gas price is below the base fee) is above `maxTakerPriorityFee` (`TakerPriorityFeeTooHigh`). It is the first step of
  the fill's access check, after pricing (so `UnknownPair` comes first) and before every check on the taker, because
  `quote`, which has no taker and runs before `fill` in a `Settler` exact-out swap, checks it at the same point:
  `TakerAccess.PriorityFeeTooHigh`, between `UnknownPair` and `Closed`. `takerAccess` and `takerAllowed` read the
  calling transaction's own priority fee, so an `eth_call` without fee fields never sees the cap. A new venue's cap is
  `NO_PRIORITY_FEE_CAP` (none), stored bit-inverted in the settler's slot so a fill reads no other slot for it.
  `enableTakerPriorityFeeCap` sets `DEFAULT_TAKER_PRIORITY_FEE_CAP` (10 gwei per gas, about 0.1 cent on a 100k-gas
  swap) exactly as `setMaxTakerPriorityFee` would, from the same roles, with the same event.
- A pair's `seq` only rises through `post`; the owner may `resetHotWord` while halted, restoring the unfillable initial
  word at seq 1 without changing consumed depth or configuration. Reset emits `HotWordReset`.
  A stale `post` entry writes, emits and refills nothing, and a malformed entry reverts the
  batch. A new pair can't fill until its first post. An updater's accepted entry with a mid outside the pair's band
  reverts the batch; the owner's entries aren't band-checked, and a venue without bands reads no band in `post`.
- Access is venue-held, `[pairIndex][sponsorId][account] -> listed`, and calls nothing: v2 doesn't use TIP-403. No
  taker the venue's access rejects ever fills, and a swap pays its caller (there is no recipient). Each swap names a
  `sponsorId`: 0 for the pair's home list, which only the current owner edits and every pair admits, or a sponsor the
  owner registered under an id it chose (`addSponsor`), that is switched on (`setSponsorEnabled`) and admitted on the
  pair (`setPairSponsor`). The owner registers, switches on, admits and resets (`resetSponsor`); an updater only
  switches off and removes. A sponsor's lists are edited only by its admin (`setMembers`), never by the owner, an
  updater or another sponsor; it lists only where it is enabled and admitted and can always delist; only it hands its
  lists to a new key, which must accept. Switching off and removal keep the lists, so restoring restores every member;
  a reset gives the id a new admin and voids every earlier listing (each member stores the sponsor's `generation`).
  Each pair is `Closed`, `Listed` or `Open`; `addPair` starts it `Closed`, only the owner sets the mode
  (`setPairAccess`), entering `Open` only while halted, and the owner or an updater can `closePair`. The check order is
  the taker priority-fee cap (above), `Closed`, the deny list (`setDenied`: the owner denies and lifts, an updater only
  denies; it overrides every list and `Open`), `Open` (no list read), then the named list: registered
  (`UnknownSponsor`), on (`SponsorDisabled`), admitted (`SponsorNotAdmitted`), then the member. `deniedCount` always
  equals the number of denied accounts, and a fill reads the deny list only while it is nonzero. Denials are
  venue-wide; lists and admissions are per pair. `takerAllowed` and `takerAccess` run the fill's own check, and `Fill`
  carries the swap's `sponsorId`.
- Every venue payout, `withdraw` and `hookTake` checks the exact debit on the venue and the exact credit on the taker,
  the `withdraw` recipient as given or the hook, so a fee, a redirect, a TIP-1022 forward or a TIP-1028 park reverts.
  Nothing in v2 resolves an address. A swap changes a venue's balance by exactly its fills' input less their output,
  less the hook's take, plus the hook's pull; other tokens don't move. Tokens are conserved across all holders.
- Fill amounts are final before any hook runs. `beforeFill` can only add inventory. After `afterFill` the venue holds
  its prior `tokenIn` less what `hookTake` took, and all its `tokenOut`. `hookTake` works only for the pair's hook,
  in `tokenIn`, within `amountIn`, inside `afterFill` with `TAKE_INPUT`. Hooks can't re-enter the venue (except
  `hookTake`) or the Settler, and a failing hook blocks only its own pair.
- The Settler holds no balance after any call, pulls only from `msg.sender`, requires each pull to credit the venue
  exactly before it calls `fill`, fills only venues the factory created, passes its caller as the taker and the swap's
  `sponsorId` to the venue, requires exact-out fills to match their quotes, and requires the caller to gain at least the
  swap's output. A venue is proved by its address, never by its code or storage, which a constructor can forge: each
  venue's code carries its CREATE2 salt, and the swap's venue must sit at the factory's CREATE2 address for that salt
  (OpenZeppelin `Clones`: `fetchCloneArgs` behind a 77-byte code-length check, then
  `predictDeterministicAddressWithImmutableArgs`; no call, never a revert). Only the factory deploys there, and it
  initializes each venue in the same call; `initialize` refuses a factory without code, so a factory's constructor
  can't leave an initialized venue behind. `factory.isVenue` makes the same check; directory registration uses that factory proof.
- The views a router reads agree with the venue's state: `takerAccess` returns exactly the outcome of the fill's own
  access check (`Allowed`, or the first refusal in its order, which `fill` reverts with its error), `takerAllowed` is
  exactly `takerAccess == Allowed`, and `hookLiquidity` never reverts for a known pair, gives the hook at most
  `HOOK_VIEW_GAS`, and reads 0 on any failure. There is no Lens: routers read each candidate venue's views directly.
- Role gates hold: custody, hooks, settler, the home lists, registering, switching on, admitting and resetting
  sponsors, lifting denials, pair modes, mid bands, pairs and unhalting are owner-only; updaters can only quote (post,
  set shapes, and set the taker priority-fee cap to any value or the default, as the owner can) and narrow access:
  close pairs, halt, deny, switch sponsors off and remove them from pairs; a sponsor's lists are its admin's alone.
- `Registry` is an optional, undeployed, unaudited sidecar for one existing factory. Anyone can register a
  factory-created venue; registration is provenance, not approval. It is append-only with pages capped at 100.
  Consumers read live pairs, access, settlement and liquidity; the registry has no admin or delisting.
  This permissionless Registry has a different ABI from the removed curated Registry; do not restore legacy SDK APIs.
- `DeployV2` deploys only the `Venue` implementation, `Settler` and `VenueFactory`, as three consecutive CREATEs.
  The implementation uses the predicted factory address. Executable code (excluding CBOR metadata) must match a
  fresh build, and verification requires the deployer's signed provenance and consecutive CREATE addresses from
  `deployerNonce`. Preserve the version-2 digest and its fourth, zero legacy Registry address field; manifest
  `contracts.registry`, `roles.registryAdmin` and `registryCreationTx` stay zero. Nonzero legacy Registry manifests
  are rejected: verify historical four-contract deployments with their original pinned source, dependencies and
  compiler. Never rewrite signed historical manifests to fit current tooling. Deploy a directory separately, not
  through `DeployV2`, and record it separately. Keep every deployment transaction under Tempo's 30M cap at Forge's
  130% gas limit (`contracts/test/fork/VenueAccessGas.t.sol`). The core registers no sponsor and calls the TIP-20
  factory precompile only while admitting a pair. `run` and `verify` must also pass as real `forge script` simulations
  on Moderato and mainnet (`contracts/test/v2/script/DeployV2RunVerify.s.sol`).

`foundry.toml` sets `isolate = true`, which clears transient storage between top-level test calls. A test of a
same-transaction sequence (the `hookTake` window, the locks, an exact-out quote and its fill) must run the whole
sequence inside one external call from a helper contract, or it passes vacuously. In via_ir tests, don't keep
`block.timestamp` in a local across a `vm.warp`: it may be re-read after the warp.

## Zero and one conventions

Storage starts zeroed, a missing record reads as zeros, and a failed or ignored low-level call can decode as zero, so
zero must never grant anything. Every contract in `contracts/src/` except `DirectPropAMM` (v1, unchanged) follows these rules;
apply them to anything new, and check `spec/propamm-v2.md` and the `IVenue` NatSpec, which state them too.

1. Enums and result codes: 0 is `None`, unset. Never store it for a live record or return it as an answer, and never
   make it a success or a grant. Real values start at 1: `AccessMode` (v2 and `ManagedDirectPropAMM`) is `None`,
   `Closed`, `Listed`, `Open`; `TakerAccess` in both interfaces starts with `None`,
   `Allowed`, then the refusals in the swap's order. Managed access omits v2's `PriorityFeeTooHigh`;
   the remaining refusal ordinals are not identical across the interfaces.
2. Ids: 0 is the contract's own default entity, its home list: `sponsorId` 0 is a pair's home list, in v2 and in
   `ManagedDirectPropAMM` alike. Registered sponsor ids are nonzero.
3. Storage markers and version counters: 0 means never written, and live values start at 1 (`HOME_GENERATION` 1,
   sponsor generations from 1, hot-word `seq` from 1, directory positions 1-based). A removed state gets its own
   nonzero marker so the slot stays nonzero and a rewrite never pays TIP-1000's slot creation (`ADMITTED` 1,
   `REMOVED` 2, in v2 and `ManagedDirectPropAMM`).
4. Sentinels written to storage are nonzero, so writing one never creates a slot (`FRESH_CONSUMPTION`,
   `HotWord.INITIAL`).
5. Bit flags: 0 is no flags, and each flag is a power of two (`HotWord` flags, `VenueHookFlags`).
6. Indexes use 0 as a real value, the first entry: `pairIndex` (v2 and `ManagedDirectPropAMM`) and `shapeId` from 0.
   This is allowed because they never grant access. Don't renumber them.
7. Error and reason codes: 0 is no error or no reason (`ShapeWord.check` returns 0 for a valid shape, and its
   `InvalidShape` reasons start at 1).

Deliberate, so don't "fix" them:

- Quantities (amounts, balances, `deniedCount`, `pairCount`, `tokenPairCount`, `_bandedPairs`, tolerances) are
  numbers, not markers: 0 means none. The counters share slots that are already nonzero, so they never create one
  (`tokenPairCount` is its token's own slot, created whenever a pair uses a token no live pair uses).
- Restrictions read 0 when absent (`denied` false, `halted` or `paused` false, no mid band, no taker priority-fee
  cap). That grants nothing on its own: every grant also needs a nonzero mode, listing, admission or role. The v2 venue
  stores its cap bit-inverted (`_invertedFeeCap`), so the 0 a new venue starts with reads as
  `NO_PRIORITY_FEE_CAP`, no cap, without `initialize` writing it. Managed pools have no priority-fee cap.
- Per-account entries (v2 and `ManagedDirectPropAMM` members and denials, updaters) clear to 0
  rather than a marker: 0 reads as not listed or not denied, and adding one back creates its slot again.
  Managed fee-policy storage belongs to hooks; an absent pair hook charges no fee and grants no access.
- `ITIP403Registry.PolicyType` is the precompile's ABI, so `WHITELIST` is 0. Only the v1 deploy scripts' transfer-policy
  preflights and the mock's tests use it; no contract in `contracts/src` calls TIP-403.

`test_zeroIsNeverAllowed` (`contracts/test/v2/VenueAccessReasons.t.sol`, and its port in
`contracts/test/managed/ManagedDirectPropAMMAccess.t.sol`) pins rule 1 for `TakerAccess`.

## Validation

For Rust changes, run `cargo fmt --all -- --check`,
`cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked` and
`RUSTDOCFLAGS='-D warnings' cargo doc --workspace --no-deps --locked`.
For SDK or v2 ABI changes, also run `forge build` then
`cargo test -p propamm-sdk --test onchain --locked -- --ignored` with Anvil available (`ANVIL_BIN` if it isn't on
`PATH`; the test starts its own node and never reads `RPC_URL`). `sdk/rust/README.md` is the crate's rustdoc front
page (`lib.rs` includes it), so its `rust` blocks are doctests. Keep the bindings sourced from the canonical Solidity
interfaces; do not maintain a second handwritten ABI. That is also why the crate isn't published to crates.io
(`publish = false`): its bindings read `contracts/src` from the checkout.

For TypeScript SDK changes, or any v2 ABI, constant or `LadderMath` change, run from `sdk/ts` (the `ts-sdk` job in
`verify.yml`; Node 24 and Foundry v1.8.1):

```bash
npm ci --ignore-scripts
npm run typecheck
npm run check
npm run examples:check
npm run contracts:build
npm run gen:check
npm test
node ../../contracts/test/vectors/fuzz.mjs --seed 0x0123456789abcdef --scale 2 --out ../../contracts/test/vectors/fuzz/ci.json
PROPAMM_VECTORS=contracts/test/vectors/fuzz/ci.json npm run test:vectors
npm run check:package
npm run test:e2e
PROPAMM_VECTORS=contracts/test/vectors/fuzz/ci.json npm run test:e2e:vectors
```

CI seeds the vector replays with `0x` and the commit's first 16 hex digits; any seed reproduces a failure.

`npm run examples:check` typechecks every ```ts block in `src/` JSDoc and in `sdk/ts/README.md` against the package's
build, so README examples must compile. To try an unreleased commit, `npm pack` in `sdk/ts` (it builds `dist/` first)
and install the tarball; inside this monorepo a `file:` dependency on `sdk/ts` works too, but a git dependency doesn't
(npm can't install a repository subdirectory). Run the compiled package, not `src/`: the source uses TypeScript value
namespaces and `.js` specifiers that Node's type stripping doesn't run. `examples/quote.ts` (prints unsigned calldata)
and `examples/inspect.ts` (reads only) import the built package: `npm run build` first.

The SDK follows viem/tempo's conventions (actions with `call`, `extractEvent` and a `Sync` twin, simulated and
estimated through viem's `simulateContract` and `estimateContractGas` or `Plan`; one error class per refusal;
`foo?: T | undefined` optional properties; ox-style pure modules), tests with vitest and no mocks, and formats with
Biome (`npx biome check --write .` fixes formatting, lint and import order; `npm run format` only formats). A change
to its public behaviour adds a changeset in `sdk/ts/.changeset/`: one past-tense sentence, with a `diff` fence for a
breaking change. That is a convention, not a gate: no CI job checks for a changeset (`npx changeset status` needs the
base branch's history, which the shallow checkout doesn't fetch). `npm run changeset:version` releases them, writing
package.json, the CHANGELOG and `src/version.ts`; test snapshots name the version `<version>`, so a release changes
none. On `main`, `.github/workflows/main.yml` does that in a `chore(sdk-ts): version packages` pull request and, once
it is merged, publishes the version to npm through trusted publishing (`npm run changeset:publish`); never publish by
hand except the one-time first publish that [Releasing](#releasing-the-typescript-sdk) describes.

`propAmmActions()`'s entries (`sdk/ts/src/actions/decorator.ts`) restate each action's description and `@returns` word
for word; only their `@example` and `@param` differ. After changing an action's doc, run `npm run docs:decorator`, which
copies it into the entry. `test/decorator-docs.test.ts` fails a drifted entry, and an action the decorator doesn't bind.
Contract reads go through `internal/read.ts`: make each with `VenueReads.read` or `readOf`, whose view name and
arguments the ABI types, and decode it with `VenueReads.view`, `readValue` or `readValues`. Each returns the view's ABI
type after matching the same ABI object, view name, target and ABI-encoded arguments to an independently
constructed expected read; this checks read identity, not the truth of the RPC response.

`sdk/ts/src/generated/` is generated from the Forge build of `contracts/src/v2` by `sdk/ts/scripts/gen.mjs`: never edit
it by hand. After a v2 interface or constant change, run `npm run contracts:build && npm run gen` and commit the result;
CI fails a stale copy. `npm run contracts:build` builds into `sdk/ts/.forge`, never the root `out/` and `cache/`.
`Ladder.fill` and `Quote.local` copy `LadderMath.fill` and `Venue.quote` bit for bit: change them with the contracts, and
keep `test/vectors.test.ts`, the reference fuzz and the e2e differential fuzz passing. Pin npm dependencies exactly, to
versions at least about 20 days old (the org's npm proxy blocks newer ones).

Start with the smallest relevant test, then run the repository gates before pushing contract or test
changes:

```bash
forge fmt --check
node contracts/test/vectors/ladder-reference.mjs --check
forge lint
forge build
forge build --sizes
FOUNDRY_PROFILE=ci forge test --force -vvv --no-match-path 'contracts/test/fork/*'
FOUNDRY_PROFILE=ci forge snapshot --force --check --no-match-test '^(invariant_|testFuzz)' --no-match-path 'contracts/test/fork/*'
```

The Coverage job runs `forge coverage` under the `coverage` profile (`foundry.toml`), which equals `ci`: repeat any
inline `ci.` config of a test as `coverage.`. Only the managed v1 and v2 differentials and the managed invariant
campaign run fewer sequences there, so the job stays inside its 30 minutes on a CI runner:

```bash
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report summary --exclude-tests \
  --no-match-coverage '^contracts/script/' --no-match-path 'contracts/test/fork/*'
```

When a code or test change affects gas, regenerate and review `.gas-snapshot` before committing:

```bash
FOUNDRY_PROFILE=ci forge snapshot --force --no-match-test '^(invariant_|testFuzz)' --no-match-path 'contracts/test/fork/*'
git diff -- .gas-snapshot
```

Do not omit `.gas-snapshot` changes merely because tests pass; CI checks the committed snapshot.
Only accept entries caused by the intended change. Use `--force` when generating or checking snapshots so
filtered builds cannot leave different via-IR test artifacts in the cache.

`contracts/test/vectors/propamm-v2-ladder.json` is the one set of vectors the Solidity contracts and both SDKs are held to,
generated by the independent BigInt reference `contracts/test/vectors/ladder-reference.mjs`: ladder fills, splits and shape
checks, hot words, prices, shapes, post batches, venue quote sequences and post outcomes (one transaction's post calls, the
`Posted` events the venue emits for them and which entries it stored). `contracts/test/v2/LadderMathVectors.t.sol`
(`LadderMath`, `HotWord`, `ShapeWord`) and `contracts/test/v2/integration/VenueVectors.t.sol` (the venue's `post`, `quote` and `fill`)
replay it, as do the Rust SDK's `sdk/rust/tests/vectors.rs` and the TypeScript SDK's `sdk/ts/test/vectors.test.ts`
(every section of each) and
`sdk/ts/test/e2e/vectors.test.ts` (the venue sections and post outcomes against the deployed core on Anvil). Both SDKs'
`PostOutcome` match an entry to a `Posted` event by pair and stored word and claim each event once, so an entry that
repeats an earlier one's pair and sequence in the same transaction reads skipped. After changing the reference, regenerate the JSON with
`node contracts/test/vectors/ladder-reference.mjs` and commit both; CI fails a stale JSON. `contracts/test/vectors/fuzz.mjs`
writes a seeded random set in the same format (under `contracts/test/vectors/fuzz/`, git-ignored, where Forge may read);
with `PROPAMM_VECTORS` naming it, each of those suites replays it instead. CI does that in the Test, Rust SDK and TypeScript
SDK jobs with one seed per commit (`0x` and the commit's first 16 hex digits, printed in each job's log), and
`bin/equivalence [seed] [scale]` runs all four replays locally on one seed, so a CI failure reruns anywhere.

The Solar differential workflow (`.github/workflows/solar.yml`, manual-only, not a required status) runs the v2 and
`ManagedDirectPropAMM` suites, their `--network tempo` runs and the seeded vector replays on contracts and tests
compiled by [solar](https://github.com/paradigmxyz/solar) instead of solc, with the ci profile and Foundry v1.8.1. Solc
is the oracle: every test must pass as it does in `verify.yml`. `contracts/test/solar/compare.mjs` writes the job
summary: the divergences, and each test's gas against the committed solc `.gas-snapshot` (harness included, since
solar compiles the tests too). The fork gas suites stay out, because they pin solc's exact figures. The workflow builds
solar at `SOLAR_REF`; a manual run takes another `solar-ref`. Run it when evaluating a compiler revision or a
compiler switch, not automatically on PRs, pushes or a schedule. Run it locally with
`SOLAR=/path/to/solar bin/solar-diff [seed]`, which builds under `cache/solar`. A failure there that solc doesn't
share is a solar bug to report upstream with a reduced case, not a reason to change a contract or a test.

The managed suites hold the pool to its two references and its own invariants:

- **v1 pricing, pair by pair** (`contracts/test/managed/ManagedDirectPropAMMDifferential.t.sol`): one managed pool with three
  pairs at zero fees runs the same fuzzed swaps as three `DirectPropAMM` pools; every swap must return or revert
  with the same bytes,
  move balances alike and leave the same anchors and route credits, with the taker's access fuzzed and `DirectPropAMM`
  listing the caller exactly when `takerAccess` admits it. `withdraw` to a TIP-1022 virtual recipient is the one
  intended divergence in that zero-fee comparison: v1 pays its master, the managed pool refuses it. Nonzero managed
  fees intentionally differ and need independent fee and rounding checks.
- **v2 access, call by call** (`contracts/test/managed/ManagedVenueAccessDifferential.t.sol`): a v2 `Venue` and a managed pool run
  the shared access-call sequences from the same callers and must succeed or revert alike, emit the same access
  events and admit or refuse swaps alike. Compare `takerAccess` by meaning, not raw enum ordinal; exclude
  v2-only updater/priority-fee-cap behavior and use owner-only managed emergency controls.
- **Invariants** (`contracts/test/managed/invariant/ManagedDirectPropAMMInvariant.t.sol`): up to five pairs over three shared
  tokens, access calls from every role, oracle moves, clock jumps, pair changes, `fund`, `withdraw` and swaps,
  each outcome predicted from ghost state: access state, deny precedence, resets, `Open` only while paused, owner-only
  emergency controls, per-token inventory conservation, no virtual address paid, fills paying only their caller, and
  pair indexes never reused.

- **Router-as-taker invariants** (`contracts/test/managed/invariant/RouterAsTakerInvariant.t.sol`): an independent
  ledger models caller-owned credits, access, hook fees and custody across direct, Settler and router trades,
  routes, listing/denial changes and ownership transitions. Router trades consume router/customer-ID credit
  partitions, never an underlying user's direct-trading credits.

The `ManagedDirectPropAMM` suites and its scripts' suites (`contracts/test/managed/DeployManagedPool.t.sol`,
`contracts/test/managed/ManagedPoolAccess.t.sol`) run on mocks, whose tokens forward a transfer to a virtual address registered
in `MockVirtualAddressRegistry` to its master, as Tempo's TIP-20 does, and CI also runs them under `--network tempo`.
There the deploy script's suite probes pathUSD itself, and `contracts/test/managed/ManagedDirectPropAMMTempo.t.sol` and
`contracts/test/managed/ManagedDirectPropAMMRegression.t.sol` use the TIP-1022 address registry itself and TIP-20 factory
tokens: a withdrawal to a registered virtual address must revert `VirtualRecipient` with nothing moved, and a
controller must refuse one as a managed pool's liquidation address and pay its master for a `DirectPropAMM`.
`contracts/test/v2/MockFidelity.t.sol` holds the TIP-403 and TIP-1022 mocks to the precompiles. v2's
`contracts/test/v2/VenueAccess.t.sol` calls no registry; CI also runs it under `--network tempo`. The swap and
access-call gas bounds in `contracts/test/fork/managed/ManagedDirectPropAMMGas.t.sol` and `contracts/test/fork/VenueAccessGas.t.sol` run only
under `--network tempo` (the first two commands below include them; `-vv` on the last two prints the measured
figures) and must match the gas tables in `contracts/README.md` (managed) and `contracts/src/v2/README.md` (v2, "On Tempo"). The v2 guide's
standard-EVM table comes from `contracts/test/v2/integration/GasIntegration.t.sol`, whose limits sit about 15% above
the figures, so re-measure it when a fill path changes; re-measure the Tempo tables after a Tempo hardfork:

```bash
forge test --network tempo --match-path 'contracts/test/{managed/**,fork/managed/**}'
forge test --network tempo --match-path 'contracts/test/*VenueAccess*'
forge test --network tempo --match-path 'contracts/test/v2/MockFidelity.t.sol'
forge test --network tempo --match-path 'contracts/test/fork/managed/ManagedDirectPropAMMGas.t.sol' -vv
forge test --network tempo --match-path 'contracts/test/fork/VenueAccessGas.t.sol' -vv
```

After any change to `contracts/script/v2/DeployV2.s.sol` or the contracts it deploys, also run it as a Forge script, as CI does
(the addresses are placeholders that hold no keys), on Moderato (`--chain 42431`) and on mainnet (`--chain 4217`):

```bash
forge script contracts/test/v2/script/DeployV2RunVerify.s.sol:DeployV2RunVerify --sig 'runAndVerify()' \
  --network tempo --chain 42431 --sender 0x7e57d2a1000000000000000000000000000c0de1
```

After any change to `contracts/script/managed/DeployManagedPool.s.sol`, `contracts/script/managed/ManagedPoolAccess.s.sol` or
`ManagedDirectPropAMM`, run them as Forge scripts too, as CI does (`contracts/test/managed/script/ManagedPoolScriptsRun.s.sol`
makes the tokens, oracles and pool in the simulation), the deploy on both chains:

```bash
forge script contracts/test/managed/script/ManagedPoolScriptsRun.s.sol:DeployManagedPoolRun --sig 'runWithPairs()' \
  --network tempo --chain 4217 --sender 0x7e57d2a1000000000000000000000000000c0de1
forge script contracts/test/managed/script/ManagedPoolScriptsRun.s.sol:ManagedPoolAccessRun --sig 'runModes()' \
  --network tempo --chain 42431 --sender 0x7e57d2a1000000000000000000000000000c0de1
```

The live fork suites `contracts/test/fork/OndoEthereumOracleFork.t.sol` (an Ethereum RPC) and
`contracts/test/fork/OndoTempoOracleFork.t.sol` (an archive Tempo RPC, `TEMPO_RPC_URL`; it pins the block of Ondo's
October 2026 oracle migration) check the USDY adapter against Ondo's wrappers; the other fork files are the Tempo gas suites above, which skip
without `--network tempo`:

```bash
ETHEREUM_RPC_URL=https://ethereum-rpc.publicnode.com \
forge test -vvv --match-path 'contracts/test/fork/*'
```

Report upstream source or interface failures separately from local unit or invariant failures. Earn is external integration context, not a propAMM build dependency; CI initializes only the public build
submodules required for compilation.

## Rust and TypeScript SDK names

The TypeScript SDK uses the Rust SDK's names, in TypeScript casing, wherever both SDKs have the concept. Keep this
table in step when either SDK adds or renames one; `sdk/ts/README.md` ("Coming from the Rust SDK") lists only the
rows whose behaviour differs.

| Rust (`propamm_sdk`) | TypeScript (`@tempoxyz/propamm-sdk`) |
| --- | --- |
| `Info::connect(provider, venue, chain_id, factory)` | `Info.isVenue(client, { factory, venue })` and viem's `getChainId(client)`: no connection object |
| `Info::venue_state`, `sponsor_state` | `Info.venueState`, `sponsorState` |
| `Info::is_agent`, `is_member`, `is_denied`, `pair_sponsor` | `Info.isAgent`, `isMember`, `isDenied`, `pairSponsor` |
| `Info::taker_allowed` | `Info.takerAllowed` |
| `Info::meta`, `market` | `Info.meta`, `market` |
| `Info::orders`, `consumed`, `quote` | `Info.orders` (with the block it read), `consumed`, `quote` |
| `Info::inventory`, `hook_liquidity` | viem/tempo's `Actions.token.getBalance(client, { token, account: venue })` (every pair token at one block: `Snapshot.get`'s `PairState.inventory`), `Info.hookLiquidity` |
| `Info::quote_state`, `QuoteState::quote` | `Snapshot.get`, `Quote.local` |
| `Curve`, `Curve::new`, `factor`, `effective_size`, `fill` | `Ladder.Curve`, `Ladder.curve`, `factor`, `effectiveSize`, `fill` |
| `LadderFill`, `LadderError` | `Ladder.FillResult` (`ok: true`, or its `error`) |
| `QuoteRequest`, `LocalQuote`, `QuoteError` | `Quote.Request`, `Quote.Result` (`ok: true`, or its `error`, a `Quote.Revert`) |
| `NO_PRIORITY_FEE_CAP` | `Venue.noPriorityFeeCap` |
| `Info::fills` | `Info.fills` |
| `Exchange::order`, `bulk_orders` (and `Actions::order`, `bulk_orders`) | `Actions.maker.order`, `bulkOrders` |
| `cancel`, `bulk_cancel`, `cancel_all` | `Actions.maker.cancel`, `bulkCancel`, `cancelAll` |
| `Info::cancel_all_requests`, `Actions::cancel_all(&requests.cancels)` | `Actions.maker.cancelAll.requests`, `cancelAll.call({ venue, cancels })` |
| `CancelAllRequests` (`cancels`, `skipped`), `SkippedPair`, `SkipReason::NeverPosted`, `SequenceExhausted` | `cancelAll.requests.ReturnValue` (`cancels`, `skipped`), `cancelAll.SkippedPair`, `cancelAll.SkipReason`: `'neverPosted'`, `'sequenceExhausted'` |
| `CancelAllSent` (`pending`, `call`, `skipped`) | `cancelAll`'s hash; `cancelAllSync`'s `receipt`, `outcome` and `skipped` |
| `approve_agent`, `revoke_agent` | `Actions.venue.approveAgent`, `revokeAgent` |
| `set_halted`, `set_shape`, `close_pair`, `set_pair_access` | `Actions.venue.setHalted`, `setShape`, `closePair`, `setPairAccess` |
| `add_sponsor`, `set_sponsor_enabled`, `set_pair_sponsor`, `set_members` | `Actions.venue.addSponsor`, `setSponsorEnabled`, `setPairSponsor`, `setMembers` |
| `transfer_sponsor_admin`, `accept_sponsor_admin`, `reset_sponsor` | `Actions.venue.transferSponsorAdmin`, `acceptSponsorAdmin`, `resetSponsor` |
| `set_denied`, `transfer_ownership`, `accept_ownership`, `withdraw` | `Actions.venue.setDenied`, `transferOwnership`, `acceptOwnership`, `withdraw` |
| `Actions::prepare(call)` for any other venue write | `Actions.venue.addPair`, `removePair`, `post`, `setPairHook`, `setSettler`, `setMidBand`, `setMaxTakerPriorityFee`, `enableTakerPriorityFeeCap` |
| `Exchange::simulate`, `send` | viem's `simulateContract(client, { ...call, account })` (`Plan.simulate` for a batch), the action itself (`<fn>Sync` also waits for the receipt and returns its event) |
| `PreparedCall`, `posts()` | `PreparedCall`, `.posts` |
| `PostOutcome::from_logs`, `from_batch`, `all_accepted()` | `PostOutcome.fromLogs`, `fromBatch`, `.allAccepted`; `fromReceipt` and `fromBatchReceipt` also read the receipt's status |
| `Sequencer::new`, `seed`, `next`, `observe`, `last`, `checkpoint` | `Sequencer.from`, `Sequencer.seed`, `Sequencer.next(sequencer, pairIndex)`, `observe`, `last`, `sequencer.last` (the whole checkpoint) |
| `OrderRequest` (`OrderRequest::new`'s defaults), `CancelRequest` | `Post.OrderRequest` (the same defaults; it also takes a word's raw `flags`, which Rust's has no field for), `Post.CancelRequest` |
| `OrderRequest::encode` | `Post.order` |
| `Sides::Both`, `Bids`, `Asks`, `Neither` | `HotWord.Sides`: `'both'`, `'bids'`, `'asks'`, `'neither'` |
| `HotWord::decode` | `HotWord.decode` |
| `AccessMode::Closed`, `Listed`, `Open` (`Market::access` reads `IVenue::AccessMode`) | `AccessModeName`: `'closed'`, `'listed'`, `'open'`, as `setPairAccess` takes it and `Info.Market`'s `access` reads it |
| `IVenue::TakerAccess` (the bindings' enum; `Info` reads only `taker_allowed`) | `TakerAccessName`: `'allowed'`, `'notListed'`, ... (`Info.takerAccess`) |
| `Balances` (`QuoteState::inventory`, `hook_liquidity`) | `Snapshot.PairState`'s `inventory` and `hookLiquidity` |
| `Price` from a string, `Display`, `from_scaled` | `Price.parse` (or `Price.from`), `Price.format`, `Price.from` |
| `Level`, `Shape::new`, `Shape::empty`, `Shape::from_words` | `Shape.Level`, `Shape.from`, `Shape.empty`, `Shape.fromWords` |
| `Market`, `OrderState`, `Fill`, `VenueState`, `SponsorState`, `Consumed` | `Info.Market`, `Info.OrderState`, `Info.Fill`, `Info.VenueState`, `Info.SponsorState`, `Ladder.Consumed` |
| `Error::DuplicatePair`, `SequenceExhausted`, `UnseededPair`, `UnknownPair` | `Errors.DuplicatePairError`, `SequenceExhaustedError`, `UnseededPairError`, `UnknownPairError` |
| `Error::NothingToCancel { skipped }` (`Exchange::cancel_all` with no pair to cancel; `Actions::cancel_all(&[])`) | `Errors.EmptyBatchError`, naming the skipped pairs in its `metaMessages` |
| `Error::ChainMismatch`, `Error::CallMismatch` | None: the SDK keeps no chain of its own, and a call names only its contract. viem signs for the client's `chain`, and throws its own `ChainMismatchError` for a JSON-RPC account whose node is on another chain |
| `Error::UnknownVenue` (`Info::connect`: the factory didn't create it) | `Info.isVenue(...)` answering `false`; `Errors.UnknownVenueError` is `Snapshot.get`'s for an address that doesn't answer the venue views |


## Releasing the TypeScript SDK

A release goes through two jobs in `.github/workflows/main.yml`, on every push to `main`, after the Verify suite, the
way tempoxyz/accounts releases:
1. **Version.** With changesets pending, changesets/action opens or updates the `chore(sdk-ts): version packages` pull
   request: `npm run changeset:version` bumps package.json, writes CHANGELOG.md and rewrites `src/version.ts`, the
   version every error names. It commits through a short-lived token from the org's GitHub STS
   (`.github/sts/changesets.sts.yaml`), not the built-in GITHUB_TOKEN. The job checks out full history: to write
   CHANGELOG.md, `changeset version` finds the commit that added each changeset, and on a shallow clone it would fetch
   more history, which has no credentials there.
2. **Publish.** Once that pull request is merged and no changeset is left, `npm run changeset:publish` runs in the
   `npm` environment. It builds `dist/`, then `scripts/publish.mjs`:
   - requires a clean git checkout (including untracked files) and `HEAD == GITHUB_SHA` in CI;
   - publishes with `changeset publish` through npm OIDC only if npm reports the version absent;
   - checks npm's `gitHead` against HEAD and downloads the public registry tarball, verifying its SHA-512
     `dist.integrity` before comparing its file paths, bytes and executable bits with `npm pack`. Compression, archive
     order and incidental tar metadata may differ across machines; package contents may not. After publishing, it
     retries absent or incomplete registry identity and a not-yet-visible tarball for a bounded interval, never
     republishing or accepting a conflicting identity, before requesting the `@tempoxyz/propamm-sdk@<version>` tag and GitHub release.

   npm, tag and release are checked independently. Retry the original workflow run from its clean source commit
   and identical packaged file contents to recover a missing tag or just a missing release, without republishing npm.
   Existing tags (including annotated tags) must resolve to npm's `gitHead`. The pinned action tolerates an existing
   tag and still creates the missing release from a `git-tag` event. Once all three exist, later main commits are
   a no-op: only the tag must match npm's source, not the current checkout or artifact.

   Recovery fails closed on absent identity, mismatched commit (even with identical bytes), artifact or tag, and
   registry/API errors. Resolve the discrepancy; there is no override. `0.0.0` is refused. Lifecycle scripts stay
   off (`NPM_CONFIG_IGNORE_SCRIPTS`); `check-npm.mjs` requires npm 11.5.1+ for OIDC. Provenance is not requested
   (npm refuses it from private repositories); trusted publishing adds it automatically from this public repository.

One-time setup around the first release (step 1 needs a repository admin; steps 2 and 3 a maintainer of the
`@tempoxyz` npm organization):
1. GitHub: create the `npm` environment in this repository, with `main` as its only deployment branch: the trusted
   publisher is bound to it, so no other branch can publish. Check that the org's STS GitHub App can write contents and
   pull requests here, so the `changesets` policy can mint its token.
2. Merge the version pull request. npm adds a trusted publisher only to a package that exists, so its Publish job
   fails, with nothing published or tagged. A maintainer of the `@tempoxyz` npm organization then publishes that version
   by hand from a fresh, clean git checkout of that exact merge commit: in `sdk/ts`,
   `npm ci --ignore-scripts && npm run changeset:publish`. Outside the workflow it verifies the published source
   commit and artifact, then names the tag it would ask for; it creates no GitHub metadata. Re-run that original
   failed Publish job: it rebuilds the same artifact, verifies npm's identity, and creates the missing tag and release.
3. npm: give `@tempoxyz/propamm-sdk` a trusted publisher: GitHub Actions, `tempoxyz/tempo-propamm`, workflow `main.yml`,
   environment `npm`, allowing `npm publish` (a configuration made since September 2026 allows only `npm stage publish`
   unless that is ticked, and `changeset publish` runs `npm publish`). Set the package to require two-factor
   authentication and disallow tokens. A configuration expires unless a publish uses it within 2 days, and step 2's
   re-run publishes nothing, so add it when the next version pull request is ready, then merge that.

## Toolchain and CI access

Solar is the default compiler, source-pinned by `solar.lock`. Run `bin/install-solar` before Forge commands.
The installer uses Rust 1.99.1 only for Solar (minimum 1.98); the SDK keeps its own Rust toolchain pin.
`bin/solar-solc` invokes the pinned executable with Solidity 0.8.30 compatibility reporting, never a PATH
compiler or a solc fallback. The compiler cache is `cache/solar`; force rebuild after changing the compiler pin.
Every CI job that compiles Solidity installs Solar. The installer and SDK parser require no runtime SDK changes.

SDK generation reads ABIs from compiler artifacts and uses `@solidity-parser/parser` for source enums,
constants and NatSpec. Artifact metadata hashes must match those sources; stale sources fail generation.
The evaluator rejects unsupported syntax, unresolved/ambiguous references, cycles and overflowing values.
`npm test` includes generator tests, and `npm run gen:check` still checks every generated file. Do not edit
bindings by hand or restore a solc AST dependency.

Historical deployments still need their original source, compiler and settings for bytecode verification.
This switch does not redeploy them. New Solar source verification must identify the full compiler version
(`0.8.30+commit.d83529b.solar.0.2.0`, from `bin/solar-solc --version`) and pass
`--compilation-profile default` to `forge verify-contract`. The Tempo verifier source supports this identity;
public explorer verification of a new propAMM deployment has not been tested here.

CI pins Foundry **v1.8.1** for contracts, coverage and fork tests; use the same release locally (`forge --version`).
When upgrading Foundry, review formatting and gas changes together and update every CI version pin rather than using a
floating `stable` release. The gas snapshot runs with `isolate = true`, so it is not comparable to a mainnet
transaction fee estimate.

Besides `changesets` (the SDK release's own, above), `.github/sts/` holds two read-only policies for consumers that
fetch this repository while it is private: `earn-ci-read` (tempoxyz/contracts' verify workflow, which rebuilds its
DirectPropAMM fixture) and `policy-engine-ci-read` (tempoxyz/policy-engine's lint, test and image workflows, which
fetch `propamm-sdk`). Each is pinned to one repository's ID and named workflows. Remove both once the repository is
public and those consumers have dropped their token steps.

## Repository layout

```text
contracts/src/     contracts and narrow external interfaces
contracts/test/    unit, fuzz, invariant, live-fork, and Tempo-precompile gas tests
contracts/script/  deployment, funding, configuration and access operations, and their env examples
sdk/rust/          Rust SDK, examples and contract integration tests
sdk/ts/            TypeScript SDK, its ABI generator, examples, and unit and Anvil tests
docs/              integration and deployment documentation
bin/               equivalence: the Solidity, Rust and TypeScript vector replays on one seed
lib/               public Foundry dependencies (submodules)
```

## Documentation and safety

- Update the owning contract or integration documentation when behavior changes.
- Clearly distinguish current implementation, test-value deployment, proposed work, and production
  requirements.
- Never commit private keys, seed phrases, keystores, password files, RPC credentials, or customer
  secrets.
- Verify live addresses and deployment state rather than trusting historical documentation.
- Use explicit, fail-closed deployment/configuration inputs for authorization changes. `contracts/script/managed/ManagedPoolAccess.s.sol`
  does this for `ManagedDirectPropAMM` access: it refuses inputs that don't apply to its mode, more than 50 accounts,
  a TIP-1022 virtual address it would list or deny (it never calls, so the entry admits or blocks nobody), and a pool
  that doesn't answer its raw probes as a managed pool (a v1 pool or a v2 `Venue`); it runs each call as its sender
  before printing it and checks the result, and `CHECK` compares every sponsor with the recorded one and, from the
  pool's deployment block, replays every access event against the chain, describing admin contracts with raw probes,
  bounded in gas and answer size, so an odd or gas-burning one never aborts it. It never reads a key or sends unless `BROADCAST` is set. `contracts/script/managed/DeployManagedPool.s.sol`
  never gives the deployer the owner's power: another owner's `addPair` calls come out as Safe calldata.
