# propAMM Rust SDK

Market-maker client for **propAMM v2**, the maker-posted ladder venue. v2's contracts were audited by
Sigma Prime ([audits](https://github.com/tempoxyz/tempo-propamm/blob/main/audits/README.md); this SDK was
not in scope). Its mainnet core is recorded in the contracts guide; supply your own verified venue,
factory and chain. The SDK does not cover v1's oracle-priced pools. The
[contracts guide](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/src/v2/README.md) explains
the venue, its roles and how a quote works.

`Exchange` submits actions, `Info` reads state, and `Actions` builds the same calls offline.
`order`, `bulk_orders`, `cancel` and `bulk_cancel` work on **whole pair ladders**: each order
replaces the pair's complete hot word, which refers to a shape installed earlier. There are no
individual order ids or queue priority. Fills take depth off each side of the ladder until the
maker refills it with a post (`OrderRequest::refill`); inventory and hooks still bound total
exposure.

## Install

The crate is not on crates.io. Depend on a reviewed commit:

```toml
[dependencies]
propamm-sdk = { git = "https://github.com/tempoxyz/tempo-propamm", rev = "<commit>" }
```

Inside a checkout of this repository, use a path dependency on `sdk/rust` instead:

```toml
[dependencies]
propamm-sdk = { path = "sdk/rust" }
```

It needs Rust 1.94.1 or later (edition 2024). The crate re-exports its Alloy 2.5 as
`propamm_sdk::alloy`, so provider and primitive types match without a separate dependency. For
Alloy features the SDK doesn't enable, such as a local signer, add `alloy` 2.5 with those features
yourself; Cargo unifies the two.

## Quick start

Supply an [Alloy provider](https://docs.rs/alloy/2.5.0/alloy/providers/index.html) configured with
your signer, gas/fee policy and nonce handling. `Info::connect` checks the RPC's chain id and that a
caller-supplied trusted factory created the venue. Verify that factory deployment separately; the
SDK never infers deployments from historical addresses or a venue's self-reported factory.
`Exchange::new(info, sender)` binds actions and simulations to one sender, which the provider must
sign for.

```rust,no_run
use propamm_sdk::{
    Exchange, Info, OrderRequest, PostOutcome, Price, Sequencer,
    alloy::{primitives::Address, providers::Provider, rpc::types::BlockId},
};

async fn post_order<P: Provider>(
    provider: P,
    venue: Address,
    chain_id: u64,
    factory: Address,
    updater: Address,
    mid: Price,
    valid_until: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    let info = Info::connect(provider, venue, chain_id, factory).await?;
    let block = BlockId::number(info.provider().get_block_number().await?);
    // Seed once at startup; every later post takes its sequence from memory.
    let sequencer = Sequencer::seed(&info, &[0], 0, block).await?;
    let exchange = Exchange::new(info, updater);

    // The order's shape must already be confirmed onchain.
    let order = OrderRequest::new(0, mid, 7, sequencer.next(0)?, valid_until);
    let call = exchange.actions().order(order)?;
    exchange.simulate(&call).await?;
    let receipt = exchange.send(&call).await?.get_receipt().await?;
    assert!(receipt.status());
    // A successful receipt can still skip a stale entry; check what was stored.
    let outcome = PostOutcome::from_logs(&call, receipt.inner.logs())?;
    assert!(outcome.all_accepted(), "skipped: {:?}", outcome.skipped);
    Ok(())
}
```

## Exchange and Info

Every `Exchange` action broadcasts once and returns an Alloy pending transaction: await its receipt
and check its status yourself. There are no implicit retries, and `send` doesn't simulate first.
`simulate` runs the call as the configured sender and reserves no state. Both check that the call
targets this venue and chain, and that the RPC is on that chain; RPC and revert errors are returned
as they come. `Info` only reads, and `exchange.info()` gives the same read API. `Info` and `Exchange`
are generic over the Alloy network, including Tempo's.

| API | Operation / result |
| --- | --- |
| `Exchange::order`, `bulk_orders` | Single or atomic batch of complete ladder hot-word replacements |
| `cancel`, `bulk_cancel` | Newer hot words disabling both sides, with a caller-selected mid |
| `set_shape` | Define up to ten levels per side; editing an active shape reprices immediately |
| `close_pair` | Close access independently of quote sequence; only owner reopens |
| `cancel_all` | Atomically cancel every live pair's quotes without halting (`Info::cancel_all_requests` reads them); returns the pending transaction, its call and the pairs it skipped |
| `set_halted` | Venue-wide halt; only owner resumes |
| `withdraw` | Owner-only exact-delta inventory withdrawal |
| `actions`, `simulate`, `send` | Prepare offline, simulate as the configured sender, submit explicitly |
| `Sequencer`, `PostOutcome` | Allocate post sequences in memory; report which entries a receipt stored |
| `Info::meta`, `market` | Discover all live pairs or inspect one pair |
| `orders` | Raw ladder snapshots with consumed depth, including disabled/expired/closed states |
| `consumed` | Base each side's fills have taken since its last refill |
| `inventory`, `hook_liquidity` | Venue balance and separate hook liquidity |
| `quote` | Authoritative onchain taker quote including inventory checks |
| `quote_state`, `QuoteState::quote` | Read one pair's quote inputs at a block, then price `Venue.quote` locally |
| `fills` | Venue's decoded `Fill` logs with transaction/block metadata |

Funding is a token transfer to the venue. Use `bindings::ITIP20` with your token's
`transferWithMemo`, or existing custody tooling, then verify the balance with `Info::inventory`.
The SDK reads no keys or environment variables, chooses no fee token and starts no background
tasks.

## Local pricing

`QuoteState::quote` is `Venue.quote` computed offline: the same checks in the same order, from the
same state, so it returns the venue's amounts or the venue's own revert. `Info::quote_state(pair,
block)` reads that state at one block: the pair's `OrderState`, the block's timestamp, the taker
priority-fee cap, the venue's inventory and, when the hook has `BEFORE_FILL`, its liquidity. It
resolves a tag such as `latest` once and makes every read at that block's hash, and refuses
`pending`. A pair that doesn't exist gets a state whose quote is the venue's `UnknownPair` (or
`VenueHalted`). A maker can then price any number of probes, and the consumption a fill would leave
(`LocalQuote::consumed_after`), without another call.

`Curve::fill` is `LadderMath.fill` alone: it prices one side's ladder from that side's consumed
depth, rounding once toward the maker, with none of the venue's other checks. Build the curve with
`Curve::new(&hot, size_unit, base_in)` and pass that side's two words from `Shape::words` (bids
first). Like `Venue.quote`, neither checks taker access or token transfer policies, and a quote is
a snapshot: it says nothing about the state a later fill sees.

```rust
use propamm_sdk::{
    Curve, Info, QuoteRequest,
    alloy::{primitives::U256, providers::Provider, rpc::types::BlockId},
};

async fn price<P: Provider>(info: &Info<P>, block: BlockId) -> Result<(), Box<dyn std::error::Error>> {
    let state = info.quote_state(0, block).await?;
    let market = &state.order.market;
    // Buy 1 base token (6 decimals) exact out, as an eth_call without fee fields would.
    let request = QuoteRequest {
        token_in: market.quote,
        token_out: market.base,
        amount: 1_000_000,
        exact_in: false,
        priority_fee: U256::ZERO,
    };
    match state.quote(&request) {
        Ok(quote) => println!("costs {} quote units", quote.amount_in),
        Err(revert) => println!("the venue would revert: {revert:?}"),
    }
    // The ask ladder alone, from the depth earlier fills took.
    let [_, _, ask0, ask1] = state.order.shape.words();
    let asks = Curve::new(&state.order.hot, market.size_unit, false);
    println!("{:?}", asks.fill(ask0, ask1, false, 1_000_000, state.order.consumed.asks));
    Ok(())
}
```

## Offline actions

`Actions` exposes the same write methods without a provider or key. It returns unsigned,
chain-bound `PreparedCall`s for external signing, or submission with `Exchange::send`.
`prepare` accepts canonical typed venue calls for pair setup, mid bands, hooks and the taker
priority-fee cap.

```rust
use propamm_sdk::{Actions, Level, OrderRequest, Shape, alloy::primitives::address};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Placeholder only. Choose the venue and chain for your deployment.
    let actions = Actions::new(address!("1111111111111111111111111111111111111111"), 42431)?;
    // At sizeUnit = 1e6 and 6 base decimals, this is 50,000 base tokens per side.
    // Spread 20 means 2 bp at width_scale = 1000.
    let shape = Shape::new(&[Level::new(50_000, 20)], &[Level::new(50_000, 20)])?;
    let define_shape = actions.set_shape(0, 7, &shape);
    // Sequence 2 is the first accepted post for a fresh pair (initial sequence 1).
    // Choose a fresh, short Unix-seconds deadline; this expiry is illustrative.
    let order = OrderRequest::new(0, "1.085".parse()?, 7, 2, 1_800_000_060);
    let update = actions.bulk_orders(&[order])?;
    println!("shape: {}", define_shape.data());
    println!("order: {}", update.data());
    Ok(())
}
```

Confirm `set_shape` before posting its id. To replace a live shape safely, define an inactive
id first, confirm it, then switch to it in the next order. Shape setup and order posting are
separate transactions; `bulk_orders` itself is one atomic `post(bytes)` transaction.

## Access control

Each venue holds per-pair lists of takers (the accounts that call swaps). **Home-list id 0
belongs to the current owner**. A sponsor is a separate list operator registered by the owner
under a nonzero id; only that sponsor's admin edits its per-pair lists. `approve_agent` grants the contract's updater
role: posting, shape changes, the taker priority-fee cap and access restrictions, with no custody
or authority to reopen access. The
[contracts guide](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/src/v2/README.md) sets out
the full role model.

Both `Exchange` and offline `Actions` expose these methods. TIP-1022 virtual addresses are
payment aliases that never send calls themselves; listing or denying an alias admits or blocks
nobody. Their layout is identified by address bytes 4 through 13 (zero-based), all `0xFD`,
without registry or network calls. The contract enforces roles and its `MAX_BATCH` limit
(currently 100 accounts per member or deny batch), but does not screen virtual entries.
The SDK refuses empty or oversized member/deny batches, zero or venue accounts, and virtual
addresses when listing or denying. Delisting and lifting virtual entries remain
available for cleanup. Updater grants, ownership proposals and withdrawal recipients also reject
zero and virtual-layout accounts offline; withdrawals additionally reject the venue recipient.
Batches are atomic and never silently split. Authorization uses state at execution, not cached SDK permissions.

`Actions::approve_agent`, `set_members`, `set_denied` and `transfer_ownership` return
`Result<PreparedCall>`: callers must propagate (`?`) or handle local validation errors before
simulation or submission. `Exchange` propagates these through its existing `Result` API.
`revoke_agent` remains infallible and accepts zero or virtual addresses to clear old entries;
use the explicit cancellation methods to clear pending ownership or sponsor-admin transfers.
`Actions::prepare` is an unchecked ABI escape hatch, not a validated builder.

| Methods | Authority and effect |
| --- | --- |
| `approve_agent`, `revoke_agent` | Owner grants/revokes updater powers; existing orders remain live |
| `set_pair_access` | Owner sets `AccessMode::{Closed, Listed, Open}`; entering Open requires halt |
| `close_pair`, `set_halted(true)` | Owner/updater stops fills; reopening/unhalting is owner-only |
| `add_sponsor` | Owner registers nonzero id; starts enabled, admitted on no pairs |
| `set_sponsor_enabled` | Owner enables/disables; updater only disables; lists are preserved |
| `set_pair_sponsor` | Owner admits/removes; updater only removes; lists are preserved |
| `set_members` | Owner edits id 0; sponsor admin alone edits its own id. Listing requires enabled/admitted; delisting always works |
| `set_denied` | Owner denies/lifts; updater only denies. Overrides every list and Open mode |
| `transfer_sponsor_admin`, `accept_sponsor_admin` | Admin proposes, successor accepts; zero cancels a pending proposal; lists survive |
| `reset_sponsor` | Owner assigns new admin and permanently invalidates every old membership for that id |
| `transfer_ownership`, `accept_ownership` | Current owner proposes, pending owner accepts custody and administration |

A typical setup registers a sponsor, admits it to a pair, then lets its admin list takers.
Confirm each transaction before depending on its result. The provider below must support both
owner and admin senders; separate providers can also be used for each role.

```rust,no_run
use propamm_sdk::{
    AccessMode, Exchange, Info,
    alloy::{
        network::Ethereum,
        primitives::Address,
        providers::{PendingTransactionBuilder, Provider},
    },
};

async fn confirm(pending: PendingTransactionBuilder<Ethereum>) -> Result<(), Box<dyn std::error::Error>> {
    if !pending.get_receipt().await?.status() {
        return Err("transaction reverted".into());
    }
    Ok(())
}

async fn admit_taker<P: Provider + Clone>(
    info: Info<P>,
    owner_address: Address,
    admin_address: Address,
    taker: Address,
) -> Result<(), Box<dyn std::error::Error>> {
    let owner = Exchange::new(info.clone(), owner_address);
    let admin = Exchange::new(info, admin_address);
    let sponsor_id = 42; // Chosen by the owner; 0 is reserved for the home list.
    confirm(owner.add_sponsor(sponsor_id, admin_address).await?).await?;
    confirm(owner.set_pair_sponsor(0, sponsor_id, true).await?).await?;
    confirm(admin.set_members(0, sponsor_id, &[taker], true).await?).await?;
    confirm(owner.set_pair_access(0, AccessMode::Listed).await?).await?;
    Ok(())
}
```

`Info::venue_state` returns owner, pending owner, halt state and denied count. `is_agent`,
`sponsor_state` (including pending admin and generation), `pair_sponsor`, `is_member` and
`is_denied` expose individual permissions at an explicit block. Use
`info.taker_allowed(pair_index, account, sponsor_id, block)` for **effective access**: it calls
the same check as a fill, including modes, denial, admission, enabled state and generation.
It does not check halt, quote expiry, liquidity or token policies. A membership read alone
never proves permission to trade. Disabling/removing a sponsor preserves its lists; resetting
it invalidates them. These operations deliberately have distinct methods.

## Units, ordering and risk controls

- `Price` accepts exact unsigned decimal strings with at most 18 places, bounded to nonzero
  `uint96`; it rejects signs, exponent notation, overflow and excess precision. Amounts are
  integer token atoms. No financial value is converted through a float.
- `Level::size` is in the pair's `sizeUnit`. Level spreads and bid/ask widenings are **0.1 bp**;
  width and depth scales are per mille (**1000 = 1x**). Zero depth disables liquidity.
  Empty sides are valid; trailing holes, decreasing spreads and reserved bits are rejected.
  `OrderRequest::new` sets no widening, both scales to 1000, `sides` to `Both` and `refill` to
  `Neither`; change its public fields for anything else.
- Bids are the maker buying base; asks are the maker selling base. `Sides` controls which
  sides are enabled. Every update replaces the complete hot word.
- A side's fills consume its depth until a post refills it (`OrderRequest::refill`). Read
  `Info::consumed` or `OrderState::consumed` for the depth used; the contracts guide has the rules.
- `valid_until` is inclusive Unix seconds and must fit `uint40`. There is no automatic
  refresh or cancel-on-disconnect. Expiry is the onchain fallback when an updater stops.
- Posts must exceed the pair's stored sequence; the venue skips stale entries without reverting.
  Take every order's and cancel's sequence from one allocator per venue/pair. Never derive
  the next sequence from a chain read: an unmined post of your own may already use it.
  `Sequencer::seed` starts from the stored hot words plus a gap, then `next` allocates from memory:
  concurrent tasks never receive the same number, and gaps are harmless. It covers one writer process;
  separate processes, keys or nonce lanes posting to the same pair need a shared counter. Persistence is the caller's responsibility: atomically max-merge each pair's allocated sequence
  from `checkpoint()` (the `(pair_index, last_allocated)` entries) into durable storage, never lowering a floor (the last allocated sequence) or deleting other pairs during ordinary operation. The deliberate-reset exception is covered below. Await durable commit before broadcasting its post.
  Concurrent snapshot writes can finish out of order: a snapshot at 8 can overwrite one at 9 after post 9 was
  broadcast, letting a restart reuse 9. Serialize checkpoint capture and commit through one writer, or use transactional per-pair
  maxima; ordinary last-writer-wins replacement is unsafe. Stop or fence the old process against allocation and
  broadcast before loading the latest committed checkpoint. Storage maxima alone do not coordinate allocators.
  On restart, restore with `Sequencer::new(checkpoint)`, then `observe` each pair's current stored sequence:
  the floor must be `max(stored_sequence, last_allocated)`. Without a checkpoint, wait until all earlier
  posts have landed or can no longer execute, then read the settled chain. A gap must cover the distance
  to the highest potentially executable sequence, not the count of pending posts; reusing a gap on restart
  is not safe by itself. `observe` raises a pair's
  floor after a higher sequence lands, such as an owner's manual post, and adds a pair the
  sequencer wasn't made with at its stored sequence; until then `next` refuses that pair
  (`Error::UnseededPair`).
- The owner can recover an exhausted sequence with `resetHotWord` while the venue is halted, restoring its unfillable hot word at sequence 1
  without changing consumed depth or configuration.
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
- A stale post is skipped without an event, so a successful receipt does not imply every quote
  was accepted. Check the receipt status first, since a reverted transaction has no logs, then
  call `PostOutcome::from_logs(&call, logs)`: it matches each entry to a `Posted` event by pair and
  stored word, claiming each event once. For a transaction carrying several post calls to the
  venue, such as a Tempo batch, `PostOutcome::from_batch(&calls, logs)` matches them in call order:
  a later entry that repeats an earlier one's pair and sequence reads skipped, even with the same
  word. A newer in-flight update can supersede a cancel; use `close_pair` or `set_halted(true)` for
  a stop no later post undoes.
- `cancel_all` cancels every live pair in one post and never halts the venue.
  `Exchange::cancel_all(Some(&sequencer))` reads every pair at the latest block, allocates each
  cancel's sequence from the sequencer, so your later posts outrank it, and sends. It returns a
  `CancelAllSent`: the pending transaction, the `call` (for `PostOutcome`) and `skipped`, each
  pair it sent no cancel with its `SkipReason`. A skipped pair is left as it was; a
  `SequenceExhausted` one stops only with `close_pair` or `set_halted`. With nothing to cancel it
  sends nothing and returns `Error::NothingToCancel { skipped }`. To send the cancels yourself,
  read them with `Info::cancel_all_requests(sequencer, block)` and pass its `cancels` to
  `Actions::cancel_all`. That read never changes the sequencer, so `observe` each cancel you send.
  Its rustdoc gives how each cancel's mid and sequence are chosen.
- An updater's posts, cancels included, must carry a mid inside the pair's mid band, or the batch
  reverts. Closing/halting needs no mid and cannot be undone by quote posts. Reopening/unhalting
  re-arms unexpired quotes: refresh first.
- Pass a fixed block number or hash to related reads. A block hash is strongest across a
  reorg; `latest` may change between calls. A raw quote state is not proof of executability:
  access, pause, expiry, depth, inventory, hooks and token policies still apply.
- Log readers own block-range pagination, deduplication, confirmations and reorg recovery.
  `Fill` preserves the original log, including `removed`. `Info::fills` reads historical logs over
  RPC; the SDK manages no WebSocket subscriptions.

## Taker priority-fee cap

`Info::quote_state` reads the venue's `maxTakerPriorityFee` into
`QuoteState::max_taker_priority_fee` (`NO_PRIORITY_FEE_CAP` is none), and `QuoteState::quote`
applies it to `QuoteRequest::priority_fee`. There is no setter method: pass
`bindings::IVenue::setMaxTakerPriorityFeeCall` or `enableTakerPriorityFeeCapCall` to
`Actions::prepare`. Reads sent as an `eth_call` without fee fields, such as `Info::quote` and
`Info::taker_allowed`, never see the cap. The
[contracts guide](https://github.com/tempoxyz/tempo-propamm/blob/main/contracts/src/v2/README.md) covers
when to set one.

## Errors

Every fallible SDK call outside local pricing returns `propamm_sdk::Error`:

| Variant | When |
| --- | --- |
| `Invalid(reason)` | A local check failed: a malformed price, shape, expiry or sequence (below 2), an empty or oversized account batch, invalid access or role accounts, a zero venue or chain id, zero, virtual or self-targeted withdrawal arguments, a reversed block range, a `pending` or missing block, a non-post call given to `PostOutcome`, or a hot word or event that doesn't decode |
| `DuplicatePair(pair)` | An order or cancel batch names a pair twice |
| `SequenceExhausted(pair)` | A sequence would pass `u32::MAX` |
| `UnseededPair(pair)` | `Sequencer::next` for a pair it doesn't track; `observe` it first |
| `UnknownPair(pair)` | `market`, `orders` or `Sequencer::seed` read a pair that doesn't exist or was removed |
| `NothingToCancel { skipped }` | `cancel_all` found no pair to cancel; nothing was sent |
| `ChainMismatch { expected, actual }` | The RPC reports a different chain id |
| `CallMismatch` | A `PreparedCall` targets another venue or chain than the `Exchange` |
| `UnknownVenue` | The factory passed to `Info::connect` didn't create the venue, or is zero |
| `Contract(error)` | A contract read failed or reverted, such as `Info::quote` |
| `Transport(error)` | Any other RPC failure, including a revert in `simulate` or in `send`'s gas estimate; a revert after mining shows only in the receipt status |

A venue revert decodes as `bindings::IVenue::IVenueErrors`:

```rust
use propamm_sdk::{Error, bindings::IVenue::IVenueErrors};

fn venue_revert(error: &Error) -> Option<IVenueErrors> {
    match error {
        Error::Contract(error) => error.as_decoded_interface_error(),
        Error::Transport(error) => error.as_error_resp()?.as_decoded_interface_error(),
        _ => None,
    }
}
```

Local pricing has its own errors. `QuoteState::quote` returns `QuoteError::Revert`, the
`IVenueErrors` value the venue would revert with, arguments included, or `QuoteError::OutOfRange`
for a hand-built state whose hot word no venue can store; state from `Info::quote_state` never has
one. `Curve::fill` returns a `LadderError`: `InsufficientDepth` when the side's remaining ladder
can't cover the fill (checked first), `ZeroFill` when either amount rounds to zero, and
`MidOutOfRange` for a mid no hot word holds.

## Examples

Two examples run from the root of a checkout of this repository, reading explicit, nonsecret
parameters from the environment. `quote` prints unsigned calldata and never connects; `inspect`
only reads:

```sh
VENUE=0x1111111111111111111111111111111111111111 CHAIN_ID=42431 \
  SEQUENCE=2 VALID_UNTIL=1800000060 cargo run -p propamm-sdk --example quote

# Supply your verified deployment's values; no v2 addresses are preconfigured.
RPC_URL=... VENUE=... FACTORY=... CHAIN_ID=42431 cargo run -p propamm-sdk --example inspect
```
