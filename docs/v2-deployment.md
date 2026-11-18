# Deploy propAMM v2

This is the operator guide for Tempo’s maker-priced trading venues. `Venue` holds a maker’s inventory and quotes;
`VenueFactory` creates its clones; `Settler` transfers a taker’s input and executes the swap. Read the
[v2 integration guide](../contracts/src/v2/README.md) for pricing and access APIs. This guide assumes familiarity
with Forge, Solidity deployment, Tempo tokens and transaction fees. A pair hook is an owner-selected contract
called before or after a fill, for example to supply inventory from a vault; the
[hook interface and constraints](../contracts/src/v2/README.md#pair-hooks) are part of the integration guide.

A pair names base and quote tokens. Its shape is a price ladder; its hot word packs the current mid-price,
expiry and ladder adjustments. A mid band bounds the prices an updater may post. A sponsor is a business
whose admin lists its users; the home list is the venue owner’s list (sponsor 0). A `listed` (mode 2) pair admits only
users on an eligible list, `open` (3) admits anyone not denied, and `closed` (1) admits nobody.

Status: the three-contract core was deployed and verified on Tempo mainnet (`4217`) on 2026-10-26.
The former curated Registry was not deployed on mainnet and has been removed from current source.
The replacement `Registry` is a separate, undeployed discovery contract. The procedure below also supports Moderato (`42431`).

This retires the curated Registry source and supported API, not historical on-chain deployments. Legacy testnet
Registries and their signed records remain intact; existing consumers are not migrated by this change. Verify
those deployments using their original pinned source. No Registry is deleted or changed on chain.

## Mainnet deployment

The signed [deployment manifest](../deployments/tempo-mainnet/propamm-v2.json) has status `verified`.
Historical solc deployment source: `6519109301e855ca3b0910620caa43726720c5c2`; all executable contract sources and pinned dependencies
match `d74f248`. Only deployment tooling changed to allow omitting the old curated Registry.

| Contract | Address | Deployment transaction |
| --- | --- | --- |
| Venue implementation | `0xEc207E702C5eEC03b79fb687e82049ed60BF64F3` | [46026036](https://explore.tempo.xyz/tx/0xa5feb25ce72d72e21f5857b9553e5ad6faeb201c90799ad0a70600647879bca4) |
| Settler | `0xDD683c32d7379a8353b5b23E9a8159A2831F65b6` | [46026041](https://explore.tempo.xyz/tx/0x84579fa6e20d39e0c731bde7a2810d6a2ee4d25b5cd6aceca87a47d83f91cc41) |
| VenueFactory | `0x7b71Cd1F47EB6b98fD5aF5167872ce378fc7136b` | [46026046](https://explore.tempo.xyz/tx/0xb37cdf392726fefecb79e7a41aabc0019b220cdab04a4afc1bc671b82b108179) |

Deployer: `0xcC4957A13A225eA1BfC85346D48B7de2Cb2cE374`, protocol nonces 235–237, ending at 238. All three receipts
succeeded; total gas used was 24,855,180 and the wallet paid 0.014914 USDC.e in fees. The fee token was
`0x20C000000000000000000000b9537d11c60E8b50`. No maker venue, pair or inventory was created by this deployment.

At deployment time, the `DeployV2.s.sol` script’s `verify()` entry point confirmed the consecutive CREATE addresses, source-equivalent executable code including immutables,
factory/implementation/Settler wiring, the implementation's zero owner and settler, and the deployer's version-2
signature of a digest binding the chain, deployer, starting nonce and contract addresses. Both legacy Registry fields are zero. The deployer retains no role in this v2 core.

Tempo's source verifier returned `exact_match` for all three contracts:
[Venue](https://contracts.tempo.xyz/verify-ui/jobs/65bacde9-742f-4d31-a7c4-77d67a631ba7),
[Settler](https://contracts.tempo.xyz/verify-ui/jobs/f60e5484-4e11-4371-ad12-894d3d8881bf), and
[VenueFactory](https://contracts.tempo.xyz/verify-ui/jobs/da5a3f80-cf6e-430d-97ce-42b0daa8467d).

## Core: `contracts/script/v2/DeployV2.s.sol`

Inputs are documented in `contracts/script/config/v2-deploy.env.example`. The sender is `--sender`, or the only
signer, and pays deployment fees. The script requires chain `4217` or `42431` and a sender other than zero or Forge's
default sender. It creates no admin role, maker venue, pair, inventory or sponsor.

The sender sends exactly three transactions, in this order:

1. `Venue(predictedFactory)`, the implementation every venue clones. The factory address is predicted from the
   sender's nonce two transactions on.
2. `Settler(implementation)`, which fills only venues created by that implementation's factory.
3. `VenueFactory(implementation, settler)`, which must land at the prediction. Its constructor rejects an
   implementation that names another factory or has an owner.

The manifest retains zero `contracts.registry`, `roles.registryAdmin` and `registryCreationTx` fields for legacy
format compatibility. The unchanged version-2 provenance digest still binds all four address fields, including the
zero legacy Registry address. Current tooling rejects nonzero legacy Registry configuration or manifests rather
than silently ignoring them. Historical four-contract manifests must be verified with their original source,
compiler and dependencies; never strip their Registry fields or change their signatures to fit this script.

`Venue.addPair` calls the canonical TIP-20 factory precompile to require initialized TIP-20s. Each venue owns its
access lists and its owner registers sponsors. Settlement requires no discovery registration.

### Optional venue registry

`Registry` is the undeployed, unaudited replacement for curated Registry discovery. It records venue addresses
from one fixed v2 factory, not token pairs, and has no admin or delisting function. Registration proves factory
origin, not approval, maker quality or permission to trade.

Deploy `Registry(IVenueFactory(existingFactory))` separately after verifying the factory's chain, address,
implementation and default Settler against the existing core deployment record. The constructor rejects an address
without code, but cannot tell whether a supplied factory is canonical. Verify the new contract's source and its
`factory()` value; record its address and creation transaction separately. Do not edit the signed core manifest or
rerun `DeployV2` to add this sidecar.

To populate it:

1. Read `VenueCreated` logs emitted by that factory from its deployment block through a finalized checkpoint.
2. Submit each address to `register(venue)`. Anyone may submit; the directory requires the original factory's
   `isVenue` proof. Repeated submissions return false and emit nothing, so backfill is safe to retry.
3. Compare the registered addresses with the checkpoint's factory events. An empty directory is not a complete
   inventory. Continue indexing subsequent events, handling chain reorganizations before submitting.
4. For new venues, callers may use `createAndRegister(owner, salt)` to create through the original factory and
   register atomically. It also accepts a venue already created for that owner and salt. A direct factory call still
   requires a later registration; no hook was added to the deployed factory.

Discovery clients must explicitly select the new directory and page through `venues(offset, limit)` with a limit of
at most 100. Read `pairCount()` and `pair(index)` from each venue, skip removed pairs, match tokens in either order and filter by live access, settlement, liquidity and
routing policy. Directory membership persists after halting, ownership transfer or pair removal. It grants no trading
permission. Existing venues, approvals, balances and the Settler need no changes.

### Run and verify

Steps:

1. Copy `contracts/script/config/v2-deploy.env.example` to an ignored `.env.v2-deploy`. Do not configure a legacy
   Registry admin; this script deploys only the three core contracts.
2. Fund the deployer with fee tokens. A Moderato simulation from a fresh sender on 2026-10-16 estimated 29.0M gas in
   total for the historical four-contract version: Venue implementation 19.01M, Settler 3.69M, VenueFactory 2.30M,
   Registry 4.00M. These are historical solc measurements, not estimates for the current Solar build. Forge's default
   estimate multiplier (130%) puts the largest gas limit, the implementation's, at 24.7M (82% of Tempo's 30M
   transaction cap, TIP-1000), which leaves room for about 4.0 kB more venue code.
   `contracts/test/fork/VenueAccessGas.t.sol` holds every transaction under the cap.
3. Dry run. The script writes
   `deployments/<network>/propamm-v2.dry-run.json`, which git ignores:

   ```bash
   set -a; source .env.v2-deploy; set +a
   forge script contracts/script/v2/DeployV2.s.sol:DeployV2 --rpc-url https://rpc.moderato.tempo.xyz --sender <deployer>
   ```

4. Broadcast with the same command plus `--broadcast` and the deployer's keystore (`--account`). Use the protocol
   nonce only, with no `--tempo.nonce-key`, `--tempo.lane`, `--tempo.expires` or `--batch`, so the implementation, the
   Settler and the factory execute in order at the predicted addresses. Use `--slow` to confirm each transaction before
   sending the next. This writes `deployments/<network>/propamm-v2.json` with
   `status: broadcast`, and `run` signs the provenance digest with the same wallet into its `deployerSignature`, with
   `provenanceVersion: 2`. With a wallet that can't sign a raw digest, `run` logs the digest instead: sign it with
   `cast wallet sign --no-hash <digest> --account <deployer keystore>` and put the signature in the manifest.
5. Verify against the exact deployment build.

   **Historical solc deployments:** the current default compiler is Solar; it cannot reproduce their bytecode.
   Run verification in a separate checkout of the deployment's original reviewed source revision, with its pinned
   dependencies, Foundry version and compiler settings. For example, `git worktree add ../propamm-historical
   <original-deployment-commit>` creates that checkout; follow its dependency setup and run the command below there
   against the correct manifest and RPC. Use the actual deployment revision, not an arbitrary pre-migration commit.
   Keep its build outputs separate from this checkout. Do not bypass the bytecode checks or redeploy to make them pass.

   Verify with no signer and no `--broadcast`. `verify` rewrites the manifest from live
   state with `status: verified`. Its `startBlock` remains an unsigned indexing hint: neither the version-2
   provenance digest nor `status: verified` authenticates the creation block. Before indexing, compare it with the
   actual successful creation receipts, using a block at or before the first core creation so no events are skipped:

   ```bash
   forge script contracts/script/v2/DeployV2.s.sol:DeployV2 --sig 'verify()' --rpc-url https://rpc.moderato.tempo.xyz
   ```

   Historical provenance-version migrations belong to the deployment's original tooling. Preserve the existing
   signed records in this checkout; verification is not a reason to rewrite an old deployment as a new one.

6. Commit the verified manifest. `.gitignore` permits `deployments/tempo-mainnet/propamm-v2.json`; other mainnet JSON
   files and all dry-run manifests remain ignored.

`run` checks the wiring before it writes a manifest, and `verify` repeats the checks from live state:

- (`verify` only) the manifest's chain id is the chain's, `startBlock` is not beyond the inspected chain head,
  and every recorded contract, the Venue implementation included, has code. The future-block refusal runs before
  provenance verification or manifest rewriting; a past block is not proof of the creation block;
- (`verify` only) the implementation, the Settler and the factory are the deployer's consecutive
  CREATEs from the manifest's `deployerNonce`, the deployer's live nonce is past the last deployment's, and the
  manifest's `deployerSignature` is the deployer's signature of `provenanceDigest` version 2 (the version, the chain,
  the deployer, `deployerNonce`, implementation, Settler, factory and zero legacy Registry address), which the manifest records as `provenanceVersion`. Version 1
  left out the old curated Registry, so a manifest could name any contract that answers that Registry's views and keep its
  signature. Code shows what an address runs now, not what ran there before; an address that can be occupied twice
  could first hold code that initializes a venue with a settler of its choosing and self-destructs in the same
  transaction, and then the real factory. Neither code nor nonce proves an address can't be occupied twice: a contract
  deployer can be destroyed in its creation transaction and created again, nonce reset, by init code that bumps the
  nonce and leaves no code. A signature does, since only an externally owned account (with or without an EIP-7702
  delegation) signs, and its CREATE address can only ever hold one contract;
- `factory.implementation()` is the implementation and `factory.defaultSettler()` is the Settler;
- the implementation's `factory()` is the factory, and its `owner()` and `settler()` are zero;
- `settler.factory()` is the factory and `settler.implementation()` the implementation;
- the implementation, the Settler and the factory each run this source's code: each is rebuilt in the
  simulation, at its own address and from its constructor arguments, and its executable code, immutables included,
  must equal the deployed code. The factory alone deploys and initializes venues; these checks and explorer source
  verification pin the code that decides which venues exist and fill.
  The CBOR metadata trailer is left out of the comparison: it hashes every source file's text and the remappings, so
  comment-only changes can alter it without changing executable code. Core-only verification still requires identical
  executable bytes: matching Solidity source alone is insufficient when the compiler, settings or dependencies change.
  Use the historical checkout described above for solc-built deployments, not the current Solar default.
- legacy Registry address, admin and creation-transaction fields are zero. Nonzero fields abort verification;
  use the original pinned deployment tooling for a historical four-contract manifest.

CI runs `run` on Moderato, and `run` then `verify` (`contracts/test/v2/script/DeployV2RunVerify.s.sol`) on Moderato and on
mainnet, as local `forge script` simulations under `--network tempo`, with no RPC and nothing broadcast. The
run-and-verify script deploys from a key of its own, derived from a public string and holding nothing, so `run` can
sign and `verify` check the signature. Forge enforces some rules only in a script run, such as refusing `address(this)` in the script contract,
which `forge test` doesn't catch, and both chain IDs exercise the supported-chain checks:

```bash
forge script contracts/test/v2/script/DeployV2RunVerify.s.sol:DeployV2RunVerify --sig 'runAndVerify()' \
  --network tempo --chain 42431 --sender 0x7e57d2a1000000000000000000000000000c0de1
```

Pass `--chain 4217` for the mainnet simulation. Both chains exercise the three-contract deployment and verification.
These are local simulations, not new deployments on either network.

## Demo venue on Moderato: `contracts/script/v2/SetupDemoVenue.s.sol`

The script creates a venue for `OWNER`, adds the pairs with their mid bands, registers each sponsor in `SPONSOR_IDS`
and admits it on every `listed` pair, lists `HOME_ALLOWED` on the home list of every `listed` pair, sets one shape and
posts one hot word on `QUOTED_PAIR`, and opens each pair in its access mode last. Each sponsor lists its own users
afterwards. It installs no hook, moves no tokens and runs on Moderato only. `OWNER` sends every transaction, because
`addPair`, `setMidBand` and the access calls are owner-only.

Inputs, from `contracts/script/config/v2-demo-venue.env.example`:

| Input | Default | Meaning |
| --- | --- | --- |
| `VENUE_FACTORY` | Required | `contracts.venueFactory` from the verified manifest |
| `OWNER` | Required | Venue owner and sender |
| `VENUE_SALT` | `0` | CREATE2 salt; change it for a second venue with the same owner |
| `UPDATER` | None | Hot key allowed to quote: `post`, `setShape`, `setMaxTakerPriorityFee` and `enableTakerPriorityFeeCap` |
| `PAIR_BASES`, `PAIR_QUOTES` | Required | Comma-separated tokens, one entry per pair, added as indexes 0, 1, ... |
| `PAIR_SIZE_UNITS` | Required | Base-token units per shape size step, per pair |
| `PAIR_ACCESS` | Required | Per pair: `listed` (the home list and admitted sponsors' lists), `open` (anyone not denied) or `closed` |
| `HOME_ALLOWED` | None | Accounts for the home list (sponsor 0) of every `listed` pair, at most 100, sent 50 per `setMembers` |
| `SPONSOR_IDS` | None | Sponsors to register, each under the id it carries on every venue |
| `SPONSOR_ADMINS` | With `SPONSOR_IDS` | Per id, in the same order: the key that lists that sponsor's users |
| `PAIR_MID_MINS`, `PAIR_MID_MAXS` | None | Per pair, 18 dp: the band an updater's mids must stay in; `0`, `0` is none |
| `QUOTED_PAIR`, `SHAPE_ID` | `0`, `0` | The pair that gets the shape and the first hot word, and the shape id |
| `SHAPE_BID`, `SHAPE_ASK` | Required | `size:spread,...`, level 1 first, in size units and 0.1 bp; empty for no side |
| `MID` | Required | Quote per 1 base, 18 dp |
| `BID_WIDEN`, `ASK_WIDEN` | `0` | Extra spread, 0.1 bp |
| `WIDTH_SCALE`, `DEPTH_SCALE` | `1000` | Multipliers, 1/1000 |
| `VALID_FOR` | `3600` | Seconds from the simulation's timestamp until the hot word expires |

Optional quote scalars (`QUOTED_PAIR`, `SHAPE_ID`, `BID_WIDEN`, `ASK_WIDEN`, `WIDTH_SCALE`, `DEPTH_SCALE`,
`VALID_FOR`) and `VENUE_SALT` default only when unset or empty. A nonempty value that fails to parse aborts
before any transaction rather than silently changing the quote or venue address.

Before sending anything, the script requires the factory and its implementation to have code and no venue at
`predictVenue(OWNER, VENUE_SALT)`. Each pair needs two distinct initialized TIP-20s accepted by the canonical factory,
with code and equal decimals, a nonzero size unit, an access mode of exactly `closed`, `listed` or `open`, and a band of
`0`, `0` or `0 < min <= max`; the band lists are
both unset/empty or both one entry per pair. Nonempty band lists must parse as unsigned integers: a malformed
value, overflow or empty comma-separated entry aborts before venue creation rather than removing the bands.
`HOME_ALLOWED` holds at most 100 accounts, none zero, the predicted venue or a TIP-1022 virtual address.
A virtual address can never call: list its master instead. `UPDATER` also rejects virtual addresses, which could
never post; zero still means no updater.
Each sponsor id is nonzero and listed once, with one admin per id that is not zero, the predicted venue or a TIP-1022
virtual address, which could never list anyone. Each
side must parse into at most 10 levels with sizes in `1..2^32-1`, spreads up to 65,535 and non-decreasing, and at least
one side must be set. `QUOTED_PAIR` must be among the pairs, `MID` and `VALID_FOR` must be nonzero, and `MID` must
be inside `QUOTED_PAIR`'s band.

Transactions, all from `OWNER`: `createVenue`, one `addPair` per
pair, each followed by its `setMidBand`, then per sponsor `addSponsor(id, admin)` and one `setPairSponsor(pair, id,
true)` per `listed` pair, then per `listed` pair `setMembers(pair, 0, HOME_ALLOWED, true)` in calls of at most 50
accounts (100 in one call would top Tempo's 30M transaction cap at Forge's 130% gas limit), `setUpdater`, `setShape`,
`post` with `seq = 2`, and last one `setPairAccess` per pair that isn't `closed`, bracketed by `setHalted(true)` and
`setHalted(false)` when any pair is `open`. The band, sponsor, home-list and updater transactions are sent only when
their inputs are set. Every band is on before the updater exists, and every pair opens after its band and first word.

1. Copy `contracts/script/config/v2-demo-venue.env.example` to an ignored `.env.v2-demo-venue`. Set `VENUE_FACTORY` from the
   verified manifest. Set `SPONSOR_IDS` to the ids the sponsors you serve use, and `SPONSOR_ADMINS` to the keys each
   sponsor gave you, in the same order. With `UPDATER` set, also set `PAIR_MID_MINS` and `PAIR_MID_MAXS`, so the hot
   key never prices an unbanded pair.
2. Dry run with `forge script contracts/script/v2/SetupDemoVenue.s.sol:SetupDemoVenue --rpc-url https://rpc.moderato.tempo.xyz
   --sender "$OWNER"`, then broadcast with `--broadcast --account <owner keystore>`. After the transactions the
   script checks that the factory knows the venue and that its owner, settler (the factory default), updater, pairs
   and their access modes, bands, shape and hot word match the inputs, since `post` skips a stale `seq` silently, that
   the venue isn't halted, that every `listed` pair admits every sponsor and lists every `HOME_ALLOWED` account on its
   home list and every other pair neither, and that each sponsor is registered to its admin, on, and on its first
   list.
3. Fund the venue by transferring pair tokens to it.
4. If a verified directory is deployed for this factory, anyone can call `register(venue)`. Until then, consumers
   can discover the venue from factory events. Registration grants no approval or access.
5. On a `listed` pair, the owner lists takers on the home list with `setMembers(pairIndex, 0, [takers], true)`, and
   each sponsor's admin lists its customers with `setMembers(pairIndex, sponsorId, [customers], true)`. A taker trades
   for itself, under `sponsorId` 0 for the home list or its sponsor's id.
6. The hot word expires `VALID_FOR` seconds after the simulation. Keep quoting with `post`, from `seq = 3` up.
   Fills take depth off the ladder: each side keeps what its fills consumed (`consumed(pairIndex)`) until a `post`
   entry refills it with `HotWord` flag bit 2 (bids) or 3 (asks). Watch `Fill`, rebalance, and refill the side you
   want to offer again in the same post that re-prices it; routine re-quotes leave the bits off.

TIP-20 tokens on Moderato (checked 2026-09-30, all 6 decimals):

| Token | Address | Currency | Notes |
| --- | --- | --- | --- |
| pathUSD | `0x20C0000000000000000000000000000000000000` | USD | Genesis |
| AlphaUSD / BetaUSD / ThetaUSD | `0x20C0…0001` / `…0002` / `…0003` | USD | Genesis test tokens |
| USDC.e (Stargate) | `0x20C0000000000000000000009e8d7eB59B783726` | USDC | Bridged |
| EURC.e (Stargate) | `0x20c000000000000000000000D72572838BbEe59C` | EURO | Bridged; about 1.6 in supply |
| OUSD | `0x20c0000000000000000000006a37DA5C996874BE` | USD | |

EURC.e is the only non-USD TIP-20 on the token list. Its supply is too small for a trial, and only its bridge can
mint it. To create a mintable test euro with the TIP-20 factory precompile (`0x20FC…0000`):

```bash
RPC=https://rpc.moderato.tempo.xyz FACTORY=0x20FC000000000000000000000000000000000000
cast call $FACTORY 'getTokenAddress(address,bytes32)(address)' $ADMIN $SALT --rpc-url $RPC  # the address
cast send $FACTORY 'createToken(string,string,string,address,address,bytes32)(address)' \
  'Test Euro' tEUR EUR 0x20C0000000000000000000000000000000000000 $ADMIN $SALT --rpc-url $RPC --account admin
cast send $TOKEN 'grantRole(bytes32,address)' $(cast keccak ISSUER_ROLE) $ADMIN --rpc-url $RPC --account admin
cast send $TOKEN 'mint(address,uint256)' $TO 1000000000000 --rpc-url $RPC --account admin  # 1,000,000 tEUR
```

The address is `0x20C0…` followed by the first 8 bytes of `keccak256(abi.encode(sender, salt))`. The factory rejects
a salt that lands in the reserved range. Only a USD token must quote a USD token, so pathUSD works as the quote
token. The token starts with transfer policy 1 (allow all) and a `uint128` supply cap.

## Venue ownership handover

An ownership transfer moves no other role: the old owner's updater keys keep quoting, and the venue keeps its settler,
hooks, bands, taker priority-fee cap, access (home lists, sponsors and their admissions, denials, pair modes), shapes
and hot words. Control of
the home lists moves with `acceptOwnership`; each sponsor's lists stay with that sponsor's admin. `post` and `setShape` work while halted, and a band doesn't bind a word
posted before it, so an inherited key can leave a word at any price that outlives the key. Before acceptance, the current
owner can cancel a pending handover with `cancelOwnershipTransfer()`; this clears the nominee and leaves the current
owner in place. A sponsor admin uses `cancelSponsorAdminTransfer(sponsorId)` for the same behavior on its own handover.
Both transfer functions reject zero-address nominees; cancellation is explicit and may be repeated. The new owner:

1. Lists the live updaters. They aren't enumerable on chain: replay the venue's `UpdaterSet` logs and take each key
   whose last event set it to `true`.
2. Sends one batched Tempo transaction: `acceptOwnership()`, `setHalted(true)` and `setUpdater(key, false)` for each
   listed key. The old owner can add a key until the batch lands, so replay `UpdaterSet` up to its block again and
   revoke any new key.
3. Checks `settler()`, `maxTakerPriorityFee()`, each pair's hook and flags (`pair(i)`), the hook's own configuration
   and each pair's access mode, and sets each pair's band with `setMidBand`. Reviews access: each pair's home list (replay `MemberUpdated`
   for sponsor 0), the sponsors, their switches and admissions (replay `SponsorAdded`, `SponsorEnabledSet` and
   `PairSponsorSet`; switch off any it won't serve) and the denials (replay `DenyUpdated`).
4. Replaces every pair's hot word, closed pairs included: `closePair` leaves the word in place, and any later
   `setPairAccess` re-arms it. Read each `hotWord(i)`, and read it again after posting, since `post` skips a stale
   `seq` silently. In either branch, set (or check with `shape(i, id)`) every shape the new words will select;
   reset preserves inherited shapes, so do not trust them merely because the hot word was reset:
   - At `seq = 2^32 - 1` no ordinary post can follow. While halted, call `resetHotWord(i)` to restore
     `HotWord.INITIAL` (seq 1, expired). This preserves the pair index, shapes, bands, hook, access lists,
     directory membership and both sides' consumed depth. Stop the quoting process, revoke compromised updater keys,
     and discard queued posts first: a still-authorized key's old high-sequence post can become newer again.
     Recreate the SDK sequencer (the Rust or TypeScript SDK’s per-pair sequence-number tracker) from the reset
     on-chain state; its `observe` method only raises the remembered sequence number, never lowers it.
     Put the reset in its own transaction before sending fresh posts. `PostOutcome` refuses to attribute a receipt
     containing a reset for a pair it is attributing, because a stale post before the reset can equal a fresh post after it.
     Post a fresh quote from seq 2 before resuming. Refill only by explicitly setting the intended refill flags.
   - Otherwise `post` a word with a higher
     `seq`, a mid inside the band and a short `validUntil`. A pair
     you won't quote yet gets a word too, stopped with `depthScale = 0` or a past `validUntil`.
5. Unhalts with `setHalted(false)`.

## Venue access

Run each step as the venue owner unless noted; batch them in one Tempo transaction where they must land together.

1. List takers on a pair's home list: `setMembers(pairIndex, 0, accounts, allowed)`, at most 100 accounts per call
   (50 when each is new, to stay under Tempo's cap at Forge's gas limit). Use each taker's own account: a swap checks
   its caller.
2. For each sponsor you serve: agree its sponsor id (the same on every venue it uses) and its admin key, then
   `addSponsor(id, admin)` and, for each pair it may trade, `setPairSponsor(pairIndex, id, true)`. Check
   `sponsor(id)` reports that admin.
3. The sponsor's admin, not the owner, lists its customers on each venue and pair: `setMembers(pairIndex, id, accounts,
   true)`. It can list only on pairs it is admitted on and only while it is switched on; it can always delist.
4. Open each pair: `setPairAccess(pairIndex, 2)` (`Listed`). For `Open` (3): `setHalted(true)`,
   `setPairAccess(pairIndex, 3)`, `setHalted(false)` in one batch.
5. Tell each sponsor the venue and its pairs. Its takers swap for themselves and pass its id as the swap's `sponsorId`
   (`Settler.swapExactIn` and `swapExactOut`); home-list takers pass 0. Each swap approves the Settler in its own
   batch: exactly `amountIn` for exact in, and `maxAmountIn` with a final `approve(Settler, 0)` for exact
   out. Never leave a standing allowance on an account with access keys: Tempo charges a key's spending
   limit at approval, not on the Settler's pull (see the spec’s [access-key allowance behavior](../spec/propamm-v2.md#known-behaviour-access-keys)). Routers read
   the venue's `takerAllowed(pairIndex, taker, id)`, then with id 0, and pass the first id that admits;
   `takerAccess(pairIndex, taker, id)` says why an id doesn't (`TakerAccess`), for example a sponsor not yet admitted
   on the pair or a customer it hasn't listed there. Both read the call's own priority fee against the venue's cap
   (`maxTakerPriorityFee`), so routers call them with the fee fields the swap will carry.
6. Monitor `MemberUpdated` for every admitted sponsor (its admin lists users with no owner call), `SponsorReset`,
   `SponsorAdminTransferred`, and `Fill.sponsorId` for per-sponsor volume.
7. To stop one account, `setDenied([account], true)`. To stop one sponsor everywhere on the venue,
   `setSponsorEnabled(id, false)`; on one pair, `setPairSponsor(pairIndex, id, false)`. To stop a pair,
   `closePair(pairIndex)`. An updater can do each of these; only the owner lifts a denial, switches a sponsor back on,
   readmits it or reopens a pair, and each restores the lists as they were.
8. If a sponsor loses its key, `resetSponsor(id, newAdmin)`: the id keeps its switch and admissions, every listing made
   under the old key stops admitting at once, and the new key lists its users again.

## Trust model

Tempo has no lever over maker funds:

- The Settler and VenueFactory have no admin, the Venue implementation is immutable and clones cannot be upgraded.
  Core deployment creates no admin role for the deployer.
- The directory has no admin or delisting function. Registration changes no venue state and grants no access.
  Routers must inspect live pairs, access, settlement and liquidity and apply their own selection policy.
- Only the venue owner can withdraw, change the settler, install hooks, change pair access modes or unhalt. Sponsor admins can list users only on admitted pairs. `withdraw` works
  while halted and consults no access list or directory.
- The factory's default settler is fixed when the factory is deployed. A different settler reaches a venue only if
  its owner calls `setSettler`.
- The Settler accepts only venues the factory created, and proves it from the venue's address, without calling the
  factory or the venue. Code and storage can't prove it: a constructor can write any slot (an owner, a settler, a
  hidden pending owner or updater) and then return a real venue's exact code. So each venue's code carries its
  CREATE2 salt, and the venue must sit at the factory's CREATE2 address for that salt; only the factory deploys there,
  and it initializes each venue in the same call. `verify` checks the factory's runtime code, which can't show what its
  constructor did, so a venue accepts `initialize` only from the factory's deployed code: a clone a constructor planted
  at a venue address stays uninitialized, with no owner or settler. `verify` also requires the factory at its
  deployer's CREATE address and the deployer's signature, so no other code can ever have held that address. Any other contract, whatever its code and storage,
  reverts `UnknownVenue`, and `factory.isVenue` and directory registration reject it too. Check a venue with `factory.isVenue`
  before funding it or trusting its `owner()`.
- As for any holder, a token's own TIP-20 controls (the issuer's transfer policy, pause) and a recipient's TIP-1028
  receive policy apply to every venue transfer. Each sponsor's admin can list users on the pairs the maker admitted it
  on at any time; the maker's answers are the deny list, removing the sponsor from a pair and switching it off.

What the maker trusts:

- The owner key controls everything, custody included. Ownership moves in two steps and doesn't revoke updaters; see
  [Venue ownership handover](#venue-ownership-handover).
- An updater can't withdraw, but it prices everything the venue can pay out, including what a pair's hook can pull
  from its vault. The owner bounds that per pair with `setMidBand(pairIndex, minMid, maxMid)`: an updater can't post
  a mid outside the band, and since asks never sit below mid and bids never above it, the venue can't sell base below
  `minMid` or buy it above `maxMid`. The owner's own posts aren't checked. `setMidBand` doesn't re-check the live
  hot word, so a band doesn't bind a word posted before it: halt or post after setting or tightening a band. A band
  caps each trade's price, not the total loss. An updater key that can also take (a contract updater, a batch
  transaction, or an accomplice the pair's access admits) can post at `minMid`, buy, post at `maxMid` and sell, losing
  up to `(maxMid - minMid) / maxMid` of the traded notional per round trip, repeatable within one transaction because
  the updater also sets depth. Keep bands narrow, keep pairs `Listed`, and monitor `Posted` and `Fill`. An updater
  also sets the taker priority-fee cap to any value, raising or removing it as the owner can, or enables the 10 gwei
  default (`enableTakerPriorityFeeCap`, about 0.1 cent of priority fee on a 100k-gas swap): a quoting setting that
  pairs with its own posts' priority fee, and no more power than posting, since a higher cap only lets a take that
  outbids a post fill the quote that post replaces. Watch `MaxTakerPriorityFeeSet`. The owner or an updater
  can stop fills with `setHalted(true)`, `closePair`, a denial, or switching a sponsor off or removing it
  from a pair; the owner revokes a key
  with `setUpdater(key, false)`.
- Fills take depth off the ladder like orders off a book. Each pair stores per side the base its fills took since the
  maker last refilled it; each fill walks the ladder from there and adds what it took, and an opposite trade consumes
  the other side without giving any back. A side consumed to its depth fills nothing until refilled, so splitting an
  order never beats one swap of the total. Only a `post` entry with a refill bit gives depth back, and the updater
  can send one, as it can already raise `depthScale`. Inventory and hook liquidity still bound payouts.
- Clients select a candidate from discovered venues and price it from each side's consumed depth using the venue's views (`hotWord`, `consumed`,
  `pair`, `shape`, read at one block). Inventory remains shared across a venue's pairs and repeated swaps; a quote is
  good only until the next fill on its side, so simulation must run against the live state.

- The venue trusts its settler to move each fill's input in before `fill`; a settler that doesn't can drain the venue
  at the venue's own curve. The deployed Settler pulls each input from its caller with `transferFromWithMemo` and
  requires it to return true.
- A pair hook is owner-chosen trusted code: it runs on every fill of its pair and can block that pair. The balance
  checks around each callback stop it from taking more than `hookTake` allows.
