use std::marker::PhantomData;

use alloy::{
    consensus::BlockHeader,
    network::{BlockResponse, Ethereum, Network, primitives::HeaderResponse},
    primitives::{Address, B256, U256},
    providers::Provider,
    rpc::types::{BlockId, BlockNumberOrTag, Filter, Log},
    sol_types::SolEvent,
};

use crate::{
    Actions, Balances, CancelRequest, Error, HotWord, Price, QuoteState, Result, Sequencer, Shape,
    SponsorState, VenueState,
    bindings::{ITIP20, IVenue, IVenueFactory},
};

#[derive(Clone, Debug)]
pub struct Market {
    pub pair_index: u16,
    pub base: Address,
    pub quote: Address,
    pub size_unit: u64,
    pub access: IVenue::AccessMode,
    pub hook: Address,
    pub hook_flags: u8,
}

/// Snapshot at an explicit block, not a guarantee a taker can currently fill.
/// Inspect access, halted state, expiry, depth, inventory, and token policies.
#[derive(Clone, Debug)]
pub struct OrderState {
    pub market: Market,
    pub hot: HotWord,
    pub shape: Shape,
    pub halted: bool,
    /// Base taken from each side by fills since the maker last refilled it.
    pub consumed: Consumed,
}

/// Base taken from each side since its last refill (`OrderRequest::refill`). The next
/// fill on a side starts this deep into its ladder.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Consumed {
    /// Base that takers sold into the bids.
    pub bids: u128,
    /// Base that takers bought from the asks.
    pub asks: u128,
}

/// Why [`Info::cancel_all_requests`] gives a live pair no cancel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SkipReason {
    /// Its word is still the one `addPair` stored (mid 0), and the sequencer holds no later
    /// sequence for it: it has no quote.
    NeverPosted,
    /// Its stored word is at `u32::MAX`: no post can replace it, so only `close_pair` or
    /// `set_halted` stops it.
    SequenceExhausted,
}

/// A live pair [`Info::cancel_all_requests`] gives no cancel, and why.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SkippedPair {
    pub pair_index: u16,
    pub reason: SkipReason,
}

/// What [`Info::cancel_all_requests`] reads, each in pair order: a cancel per live pair it can
/// cancel, for [`Actions::cancel_all`], and every other live pair. A removed pair isn't live and is
/// in neither.
#[derive(Clone, Debug, Default)]
pub struct CancelAllRequests {
    pub cancels: Vec<CancelRequest>,
    pub skipped: Vec<SkippedPair>,
}

/// One pair as `cancel_all` reads it: its stored word (zero for a removed pair) and mid band.
pub(crate) struct PairRead {
    pair_index: u16,
    word: B256,
    min_mid: u128,
    max_mid: u128,
}

/// A decoded fill plus its original log for block/transaction identity, ordering,
/// deduplication, and the `removed` flag when processing reorgs.
#[derive(Clone, Debug)]
pub struct Fill {
    pub fill: IVenue::Fill,
    pub log: Log,
}

/// Read-only venue information through a caller-owned provider.
/// Generic over the network, including Tempo-specific providers/signers.
#[derive(Clone, Debug)]
pub struct Info<P, N = Ethereum> {
    provider: P,
    actions: Actions,
    network: PhantomData<N>,
}

impl<P: Provider<N>, N: Network> Info<P, N> {
    /// Validate chain and venue membership against a caller-supplied trusted
    /// factory. No hardcoded or historical deployment addresses are assumed.
    pub async fn connect(
        provider: P,
        venue: Address,
        chain_id: u64,
        factory: Address,
    ) -> Result<Self> {
        let client = Self {
            provider,
            actions: Actions::new(venue, chain_id)?,
            network: PhantomData,
        };
        client.check_chain().await?;
        if factory.is_zero()
            || !IVenueFactory::new(factory, &client.provider)
                .isVenue(venue)
                .call()
                .await?
        {
            return Err(Error::UnknownVenue);
        }
        Ok(client)
    }

    pub const fn venue(&self) -> Address {
        self.actions.venue()
    }
    pub const fn chain_id(&self) -> u64 {
        self.actions.chain_id()
    }
    pub(crate) const fn actions(&self) -> &Actions {
        &self.actions
    }
    pub const fn provider(&self) -> &P {
        &self.provider
    }

    pub(crate) async fn check_chain(&self) -> Result<()> {
        let actual = self.provider.get_chain_id().await?;
        let expected = self.actions.chain_id();
        if actual != expected {
            return Err(Error::ChainMismatch { expected, actual });
        }
        Ok(())
    }

    /// Use a fixed block hash/number to keep these related permission reads coherent.
    pub async fn venue_state(&self, block: BlockId) -> Result<VenueState> {
        let venue = IVenue::new(self.venue(), &self.provider);
        Ok(VenueState {
            owner: venue.owner().block(block).call().await?,
            pending_owner: venue.pendingOwner().block(block).call().await?,
            halted: venue.halted().block(block).call().await?,
            denied_count: venue.deniedCount().block(block).call().await?,
        })
    }

    /// Whether the address is an updater. Owner authority is separate.
    pub async fn is_agent(&self, agent: Address, block: BlockId) -> Result<bool> {
        Ok(IVenue::new(self.venue(), &self.provider)
            .isUpdater(agent)
            .block(block)
            .call()
            .await?)
    }

    pub async fn sponsor_state(&self, sponsor_id: u64, block: BlockId) -> Result<SponsorState> {
        let venue = IVenue::new(self.venue(), &self.provider);
        let state = venue.sponsor(sponsor_id).block(block).call().await?;
        Ok(SponsorState {
            admin: state.admin,
            pending_admin: venue
                .pendingSponsorAdmin(sponsor_id)
                .block(block)
                .call()
                .await?,
            enabled: state.enabled,
            generation: state.generation,
        })
    }

    /// Pair admission alone; does not imply the sponsor is enabled or a user listed.
    pub async fn pair_sponsor(
        &self,
        pair_index: u16,
        sponsor_id: u64,
        block: BlockId,
    ) -> Result<bool> {
        Ok(IVenue::new(self.venue(), &self.provider)
            .pairSponsor(pair_index, sponsor_id)
            .block(block)
            .call()
            .await?)
    }

    /// Current-generation membership only. Use `taker_allowed` for effective access.
    pub async fn is_member(
        &self,
        pair_index: u16,
        sponsor_id: u64,
        account: Address,
        block: BlockId,
    ) -> Result<bool> {
        Ok(IVenue::new(self.venue(), &self.provider)
            .isMember(pair_index, sponsor_id, account)
            .block(block)
            .call()
            .await?)
    }

    pub async fn is_denied(&self, account: Address, block: BlockId) -> Result<bool> {
        Ok(IVenue::new(self.venue(), &self.provider)
            .denied(account)
            .block(block)
            .call()
            .await?)
    }

    /// The contract's own effective access check, including modes, denials,
    /// sponsor admission/enabled state and membership. It does not check halt,
    /// expiry, inventory, hooks or token policies, so true is not a fill guarantee.
    pub async fn taker_allowed(
        &self,
        pair_index: u16,
        account: Address,
        sponsor_id: u64,
        block: BlockId,
    ) -> Result<bool> {
        Ok(IVenue::new(self.venue(), &self.provider)
            .takerAllowed(pair_index, account, sponsor_id)
            .block(block)
            .call()
            .await?)
    }

    /// Reads one pair at a caller-selected block. Use a block hash to bind a set of
    /// related reads across a reorg; `latest` reads can span different blocks.
    pub async fn market(&self, pair_index: u16, block: BlockId) -> Result<Market> {
        let pair = IVenue::new(self.actions.venue(), &self.provider)
            .pair(pair_index)
            .block(block)
            .call()
            .await?;
        if pair.base.is_zero() {
            return Err(Error::UnknownPair(pair_index));
        }
        Ok(Market {
            pair_index,
            base: pair.base,
            quote: pair.quote,
            size_unit: pair.sizeUnit,
            access: pair.access,
            hook: pair.hook,
            hook_flags: pair.hookFlags,
        })
    }

    /// Discover all live pairs. Removed indices are never reused and are skipped.
    pub async fn meta(&self, block: BlockId) -> Result<Vec<Market>> {
        let count = IVenue::new(self.actions.venue(), &self.provider)
            .pairCount()
            .block(block)
            .call()
            .await?;
        let mut markets = Vec::new();
        for pair_index in 0..count {
            match self.market(pair_index, block).await {
                Ok(market) => markets.push(market),
                Err(Error::UnknownPair(_)) => (),
                Err(error) => return Err(error),
            }
        }
        Ok(markets)
    }

    /// One cancel per live pair, for [`Actions::cancel_all`], and every live pair it gives none,
    /// read at `block` resolved to one hash (`pending` is refused). Each cancel is at the pair's
    /// stored mid, moved inside its mid band if it has one (an updater's cancel must satisfy the
    /// band), and its next sequence: one above the stored sequence, or above `sequencer`'s counter
    /// for a pair it tracks if that is higher (`max(last, stored) + 1`). A pair still on the word
    /// `addPair` stored (mid 0) is skipped as [`SkipReason::NeverPosted`], unless `sequencer` holds a
    /// later sequence for it, whose post may still be unmined: then it is cancelled at its band's
    /// `min_mid`, or at a price of 1 without a band. A pair whose stored word is at `u32::MAX` is
    /// skipped as [`SkipReason::SequenceExhausted`]: no post can replace it, and it never blocks the
    /// other pairs' cancels. If only `sequencer`'s counter is at the maximum, the cancel falls back
    /// to the stored sequence plus one. Malformed hot words or mid bands are refused before
    /// any cancellation sequence is reserved. It never changes `sequencer`:
    /// [`Exchange::cancel_all`](crate::Exchange::cancel_all) records every cancel it sends, a pair
    /// `sequencer` doesn't track included.
    pub async fn cancel_all_requests(
        &self,
        sequencer: Option<&Sequencer>,
        block: BlockId,
    ) -> Result<CancelAllRequests> {
        plan(&self.cancel_all_pairs(block).await?, sequencer, false)
    }

    /// Every pair's stored word and mid band, all read at `block` resolved to one hash.
    pub(crate) async fn cancel_all_pairs(&self, block: BlockId) -> Result<Vec<PairRead>> {
        let block = self.pin(block).await?;
        let venue = IVenue::new(self.actions.venue(), &self.provider);
        let count = venue.pairCount().block(block).call().await?;
        let mut pairs = Vec::with_capacity(count.into());
        for pair_index in 0..count {
            let word = venue.hotWord(pair_index).block(block).call().await?;
            // Zero is a removed pair, whose band is gone too.
            let (min_mid, max_mid) = if word.is_zero() {
                (0, 0)
            } else {
                let band = venue.midBand(pair_index).block(block).call().await?;
                (band.minMid.to::<u128>(), band.maxMid.to::<u128>())
            };
            pairs.push(PairRead {
                pair_index,
                word,
                min_mid,
                max_mid,
            });
        }
        Ok(pairs)
    }

    /// `block` resolved to its hash, so a set of reads sees one block even while blocks arrive.
    /// `pending` is refused: it has no fixed state to read.
    async fn pin(&self, block: BlockId) -> Result<BlockId> {
        if matches!(block, BlockId::Number(BlockNumberOrTag::Pending)) {
            return Err(Error::Invalid("block: pending has no fixed state to read"));
        }
        if matches!(block, BlockId::Hash(_)) {
            return Ok(block);
        }
        let header = self
            .provider
            .get_block(block)
            .await?
            .ok_or(Error::Invalid("block: not found"))?
            .header()
            .clone();
        Ok(BlockId::hash(header.hash()))
    }

    /// Venue-owned balance; excludes hook liquidity, which is read separately.
    pub async fn inventory(&self, token: Address, block: BlockId) -> Result<U256> {
        Ok(ITIP20::new(token, &self.provider)
            .balanceOf(self.actions.venue())
            .block(block)
            .call()
            .await?)
    }

    /// One result per requested pair, in request order. `block` should be a fixed
    /// number/hash for a coherent snapshot. Removed pairs return `UnknownPair`.
    pub async fn orders(&self, pairs: &[u16], block: BlockId) -> Result<Vec<OrderState>> {
        let venue = IVenue::new(self.actions.venue(), &self.provider);
        let halted = venue.halted().block(block).call().await?;
        let mut quotes = Vec::with_capacity(pairs.len());
        for &pair_index in pairs {
            let market = self.market(pair_index, block).await?;
            let hot = HotWord::decode(venue.hotWord(pair_index).block(block).call().await?)?;
            let shape = Shape::from_words(
                venue
                    .shape(pair_index, hot.shape_id)
                    .block(block)
                    .call()
                    .await?,
            )?;
            let consumed = self.consumed(pair_index, block).await?;
            quotes.push(OrderState {
                market,
                hot,
                shape,
                halted,
                consumed,
            });
        }
        Ok(quotes)
    }

    /// Everything `Venue.quote` reads for one pair at `block`, for `QuoteState::quote` to
    /// price locally: the pair's order state, the block's timestamp, the taker priority-fee
    /// cap, the venue's inventory and, when the hook has `BEFORE_FILL`, its liquidity. A tag
    /// such as `latest` is resolved once, and every read is made at that block's hash, so the
    /// state is one block's even while blocks arrive; `pending` is refused. A pair that doesn't
    /// exist still gets a state, with a zero base, so `QuoteState::quote` gives the venue's own
    /// revert (`VenueHalted` on a halted venue, else `UnknownPair`).
    pub async fn quote_state(&self, pair_index: u16, block: BlockId) -> Result<QuoteState> {
        if matches!(block, BlockId::Number(BlockNumberOrTag::Pending)) {
            return Err(Error::Invalid(
                "block: pending has no fixed state to quote from",
            ));
        }
        let header = self
            .provider
            .get_block(block)
            .await?
            .ok_or(Error::Invalid("block: not found"))?
            .header()
            .clone();
        let timestamp = header.timestamp();
        // Hash selectors also carry EIP-1898's canonicality requirement. Header lookup
        // does not enforce it, so retain it for every subsequent state read.
        let block = match block {
            BlockId::Hash(_) => block,
            BlockId::Number(_) => BlockId::hash(header.hash()),
        };
        let venue = IVenue::new(self.actions.venue(), &self.provider);
        let max_taker_priority_fee = venue.maxTakerPriorityFee().block(block).call().await?;
        let pair = venue.pair(pair_index).block(block).call().await?;
        if pair.base.is_zero() {
            return Ok(QuoteState {
                order: OrderState {
                    market: Market {
                        pair_index,
                        base: pair.base,
                        quote: pair.quote,
                        size_unit: pair.sizeUnit,
                        access: pair.access,
                        hook: pair.hook,
                        hook_flags: pair.hookFlags,
                    },
                    hot: HotWord::decode(B256::ZERO)?,
                    shape: Shape::empty(),
                    halted: venue.halted().block(block).call().await?,
                    consumed: Consumed::default(),
                },
                timestamp,
                max_taker_priority_fee,
                inventory: Balances::default(),
                hook_liquidity: Balances::default(),
            });
        }
        let order = self
            .orders(&[pair_index], block)
            .await?
            .pop()
            .ok_or(Error::UnknownPair(pair_index))?;
        let (base, quote) = (order.market.base, order.market.quote);
        let inventory = Balances {
            base: self.inventory(base, block).await?,
            quote: self.inventory(quote, block).await?,
        };
        let hook_liquidity = if order.market.hook_flags & 1 != 0 {
            Balances {
                base: self.hook_liquidity(pair_index, base, block).await?,
                quote: self.hook_liquidity(pair_index, quote, block).await?,
            }
        } else {
            Balances::default()
        };
        Ok(QuoteState {
            order,
            timestamp,
            max_taker_priority_fee,
            inventory,
            hook_liquidity,
        })
    }

    /// The contract's authoritative quote, including inventory/hook liquidity.
    /// Does not check taker access or token transfer policies.
    pub async fn quote(
        &self,
        pair_index: u16,
        token_in: Address,
        token_out: Address,
        amount: u128,
        exact_in: bool,
        block: BlockId,
    ) -> Result<(u128, u128)> {
        let quote = IVenue::new(self.actions.venue(), &self.provider)
            .quote(pair_index, token_in, token_out, amount, exact_in)
            .block(block)
            .call()
            .await?;
        Ok((quote.amountIn, quote.amountOut))
    }

    /// Depth fills have taken from each side since its last refill.
    pub async fn consumed(&self, pair_index: u16, block: BlockId) -> Result<Consumed> {
        let consumed = IVenue::new(self.actions.venue(), &self.provider)
            .consumed(pair_index)
            .block(block)
            .call()
            .await?;
        Ok(Consumed {
            bids: consumed.bids,
            asks: consumed.asks,
        })
    }

    pub async fn hook_liquidity(
        &self,
        pair_index: u16,
        token: Address,
        block: BlockId,
    ) -> Result<U256> {
        Ok(IVenue::new(self.actions.venue(), &self.provider)
            .hookLiquidity(pair_index, token)
            .block(block)
            .call()
            .await?)
    }

    /// Bounded log query. Callers own pagination, confirmation policy and reorg
    /// handling. RPC errors are returned without silently dropping any fills.
    /// Noncanonical ABI words, unexpected emitters and pairs outside the requested
    /// filter return [`Error::Invalid`]. ABI validation permits trailing event data.
    pub async fn fills(&self, pair: Option<u16>, from: u64, to: u64) -> Result<Vec<Fill>> {
        if from > to {
            return Err(Error::Invalid("block range"));
        }
        let mut filter = Filter::new()
            .address(self.actions.venue())
            .event_signature(IVenue::Fill::SIGNATURE_HASH)
            .from_block(from)
            .to_block(to);
        if let Some(pair) = pair {
            filter = filter.topic1(U256::from(pair));
        }
        let logs = self.provider.get_logs(&filter).await?;
        logs.into_iter()
            .map(|log| {
                if log.address() != self.actions.venue() {
                    return Err(Error::Invalid("Fill event"));
                }
                let fill = log
                    .log_decode_validate::<IVenue::Fill>()
                    .map_err(|_| Error::Invalid("Fill event"))?
                    .inner
                    .data;
                if pair.is_some_and(|pair| pair != fill.pairIndex) {
                    return Err(Error::Invalid("Fill event"));
                }
                Ok(Fill { fill, log })
            })
            .collect()
    }
}

/// 1.0 as a mid: the price an untracked pair's cancel carries when it has no band to sit in.
const ONE: u128 = 1_000_000_000_000_000_000;

/// [`Info::cancel_all_requests`] from the pairs read. With `commit`, each pair's sequence is
/// allocated from `sequencer` atomically (`max(last, stored) + 1`; a pair it doesn't track joins
/// it at that sequence), so no concurrent `next` can return it and no later post of the pair can
/// reuse it while the cancel is in flight.
pub(crate) fn plan(
    pairs: &[PairRead],
    sequencer: Option<&Sequencer>,
    commit: bool,
) -> Result<CancelAllRequests> {
    let mut requests = CancelAllRequests::default();
    let mut floors = Vec::new();
    for pair in pairs {
        let pair_index = pair.pair_index;
        // Zero is a removed pair: it isn't live, so there is nothing to cancel or report.
        if pair.word.is_zero() {
            continue;
        }
        // Validate even a never-posted or exhausted pair before deciding to skip it.
        if (pair.max_mid == 0 && pair.min_mid != 0)
            || (pair.max_mid != 0 && (pair.min_mid == 0 || pair.min_mid > pair.max_mid))
            || pair.max_mid >= (1u128 << 96)
        {
            return Err(Error::Invalid(
                "mid band: expected (0, 0) or 0 < min <= max < 2^96",
            ));
        }
        let stored = HotWord::decode(pair.word)?;
        if stored.sequence == 0 {
            return Err(Error::Invalid("hot word: sequence must be nonzero"));
        }
        // No post can replace a word at the last sequence.
        if stored.sequence == u32::MAX {
            requests.skipped.push(SkippedPair {
                pair_index,
                reason: SkipReason::SequenceExhausted,
            });
            continue;
        }
        let tracked = sequencer.and_then(|s| s.last(pair_index));
        // A zero mid is the word `addPair` stored, which no taker can fill: nothing to cancel,
        // unless the sequencer has handed out a later sequence, whose post may still be unmined.
        if stored.mid == 0 && tracked.is_none_or(|last| last <= stored.sequence) {
            requests.skipped.push(SkippedPair {
                pair_index,
                reason: SkipReason::NeverPosted,
            });
            continue;
        }
        // A sequencer counter at u32::MAX (the stored word below it) falls back to the stored
        // sequence plus one, as an untracked pair does.
        let sequence = tracked
            .and_then(|last| last.max(stored.sequence).checked_add(1))
            .unwrap_or(stored.sequence + 1);
        // An updater's entries must sit inside the pair's band (`max_mid` 0 for none).
        let mid = match (stored.mid, pair.max_mid) {
            (0, 0) => ONE,
            (0, _) => pair.min_mid,
            (mid, 0) => mid,
            (mid, max_mid) => mid.max(pair.min_mid).min(max_mid),
        };
        floors.push(stored.sequence);
        requests.cancels.push(CancelRequest {
            pair_index,
            sequence,
            mid: Price::from_scaled(mid)?,
        });
    }
    // Nothing fallible remains: only now reserve from the shared allocator. Do not
    // observe previewed sequences: concurrent posts may have raised any pair's floor.
    if commit && let Some(sequencer) = sequencer {
        for (cancel, floor) in requests.cancels.iter_mut().zip(floors) {
            cancel.sequence = sequencer
                .next_above(cancel.pair_index, floor)
                .unwrap_or(floor + 1);
        }
    }
    Ok(requests)
}

#[cfg(test)]
mod cancellation_tests {
    use super::*;

    fn pair(pair_index: u16, mid: u128, min_mid: u128, max_mid: u128) -> PairRead {
        PairRead {
            pair_index,
            word: B256::from((U256::from(2) << 208) | U256::from(mid)),
            min_mid,
            max_mid,
        }
    }

    #[test]
    fn late_bad_hot_word_leaves_checkpoint_untouched() {
        let sequencer = Sequencer::new([(0, 9), (7, 42)]);
        let before = sequencer.checkpoint();
        let mut bad = pair(1, 10, 0, 0);
        bad.word = B256::from(U256::from(4) << 240);
        assert!(plan(&[pair(0, 10, 0, 0), bad], Some(&sequencer), true).is_err());
        assert_eq!(sequencer.checkpoint(), before);
    }

    #[test]
    fn invalid_bands_are_rejected_even_on_skipped_pairs() {
        for (min, max) in [(0, 1), (1, 0), (2, 1), (1, 1u128 << 96)] {
            let mut bad = pair(1, 0, min, max);
            bad.word = B256::from(U256::from(1) << 208);
            assert!(plan(&[bad], None, false).is_err(), "({min},{max})");
        }
    }

    #[test]
    fn unmined_first_orders_use_band_minimum_or_one() {
        let sequencer = Sequencer::new([(0, 9), (1, 9)]);
        let mut pairs = [pair(0, 0, 20, 30), pair(1, 0, 0, 0)];
        for pair in &mut pairs {
            pair.word = B256::from(U256::from(1) << 208);
        }
        let before = sequencer.checkpoint();
        let preview = plan(&pairs, Some(&sequencer), false).unwrap();
        assert_eq!(sequencer.checkpoint(), before);
        let committed = plan(&pairs, Some(&sequencer), true).unwrap();
        for requests in [preview, committed] {
            assert_eq!(
                requests
                    .cancels
                    .iter()
                    .map(|c| (c.mid.scaled(), c.sequence))
                    .collect::<Vec<_>>(),
                [(20, 10), (ONE, 10)]
            );
        }
    }

    #[test]
    fn cancellation_reservations_and_concurrent_posts_are_unique() {
        let sequencer = Sequencer::new([(0, 2)]);
        let mut allocated = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..8)
                .map(|_| {
                    let sequencer = &sequencer;
                    scope.spawn(move || {
                        let cancel = plan(&[pair(0, 10, 0, 0)], Some(sequencer), true).unwrap();
                        [cancel.cancels[0].sequence, sequencer.next(0).unwrap()]
                    })
                })
                .collect();
            handles
                .into_iter()
                .flat_map(|h| h.join().unwrap())
                .collect::<Vec<_>>()
        });
        allocated.sort_unstable();
        assert_eq!(allocated, (3..=18).collect::<Vec<_>>());
    }

    #[test]
    fn valid_bands_clamp_and_max_counter_falls_back() {
        let sequencer = Sequencer::new([(0, u32::MAX), (1, 9), (2, 9)]);
        let pairs = [pair(0, 10, 20, 30), pair(1, 40, 20, 30), pair(2, 10, 0, 0)];
        let requests = plan(&pairs, Some(&sequencer), true).unwrap();
        assert_eq!(
            requests
                .cancels
                .iter()
                .map(|c| (c.mid.scaled(), c.sequence))
                .collect::<Vec<_>>(),
            [(20, 3), (30, 10), (10, 10)]
        );
        assert_eq!(sequencer.last(0), Some(u32::MAX));
    }
}
