use std::collections::HashSet;

use alloy::{
    network::{Network, TransactionBuilder},
    primitives::{Address, B256, Bytes, U256},
    sol_types::SolCall,
};

use crate::{AccessMode, Error, OrderRequest, Price, Result, Shape, Sides, bindings::IVenue};

/// An unsigned zero-value call. Fields are private so a client can enforce its
/// configured venue and chain before simulation or submission.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreparedCall {
    venue: Address,
    chain_id: u64,
    data: Bytes,
    posts: Vec<(u16, u32)>,
}

impl PreparedCall {
    pub const fn venue(&self) -> Address {
        self.venue
    }
    pub const fn chain_id(&self) -> u64 {
        self.chain_id
    }
    pub fn data(&self) -> &Bytes {
        &self.data
    }
    /// The `(pair_index, sequence)` entries of an order or cancel batch, in request
    /// order; empty for every other call. [`PostOutcome`](crate::PostOutcome) matches
    /// these against the receipt's `Posted` events.
    pub fn posts(&self) -> &[(u16, u32)] {
        &self.posts
    }

    /// Works with Ethereum or a caller-supplied Tempo Alloy network. The provider
    /// supplies fees, nonce, gas, and signing; the SDK never reads a private key.
    pub fn transaction<N: Network>(&self, sender: Address) -> N::TransactionRequest {
        N::TransactionRequest::default()
            .with_to(self.venue)
            .with_from(sender)
            .with_chain_id(self.chain_id)
            .with_input(self.data.clone())
            .with_value(U256::ZERO)
    }
}

/// Cancels both sides by posting a newer disabled word. Cancellation is subject
/// to the same sequence ordering as any other post. Use `close_pair` or
/// `set_halted(true)` for a stop that later quote posts cannot undo.
#[derive(Clone, Copy, Debug)]
pub struct CancelRequest {
    pub pair_index: u16,
    pub sequence: u32,
    /// Keep the current mid (or another mid inside the updater's band).
    pub mid: Price,
}

/// Offline market-maker command builder, scoped to one venue and chain.
#[derive(Clone, Copy, Debug)]
pub struct Actions {
    venue: Address,
    chain_id: u64,
}

// Venue.MAX_BATCH. Keep the offline limit aligned with the canonical v2 contract.
const MAX_BATCH: usize = 100;

/// TIP-1022 identifies virtual addresses by layout, without a registry lookup.
fn is_virtual(account: Address) -> bool {
    account.as_slice()[4..14].iter().all(|byte| *byte == 0xfd)
}

fn require_callable(account: Address) -> Result<()> {
    if account.is_zero() || is_virtual(account) {
        return Err(Error::Invalid("zero or virtual account"));
    }
    Ok(())
}

impl Actions {
    pub fn new(venue: Address, chain_id: u64) -> Result<Self> {
        if venue.is_zero() {
            return Err(Error::Invalid("venue address"));
        }
        if chain_id == 0 {
            return Err(Error::Invalid("chain id"));
        }
        Ok(Self { venue, chain_id })
    }

    pub const fn venue(&self) -> Address {
        self.venue
    }
    pub const fn chain_id(&self) -> u64 {
        self.chain_id
    }

    /// Advanced escape hatch for pair setup, bands, hooks and other venue calls. All calls
    /// stay bound to this venue. Role checks remain the contract's responsibility.
    pub fn prepare<C: SolCall>(&self, call: C) -> PreparedCall {
        PreparedCall {
            venue: self.venue,
            chain_id: self.chain_id,
            data: call.abi_encode().into(),
            posts: Vec::new(),
        }
    }

    /// Atomically replace hot words for distinct pairs; shapes must already exist.
    /// Returns calldata, not an acceptance acknowledgement. Stale entries emit no
    /// `Posted` event even when the transaction succeeds.
    pub fn bulk_orders(&self, quotes: &[OrderRequest]) -> Result<PreparedCall> {
        if quotes.is_empty() {
            return Err(Error::Invalid("empty quote batch"));
        }
        let mut seen = HashSet::new();
        let mut packed = Vec::with_capacity(quotes.len() * 34);
        let mut posts = Vec::with_capacity(quotes.len());
        for quote in quotes {
            if !seen.insert(quote.pair_index) {
                return Err(Error::DuplicatePair(quote.pair_index));
            }
            packed.extend_from_slice(&quote.pair_index.to_be_bytes());
            packed.extend_from_slice(quote.encode()?.as_slice());
            posts.push((quote.pair_index, quote.sequence));
        }
        let mut call = self.prepare(IVenue::postCall {
            packed: packed.into(),
        });
        call.posts = posts;
        Ok(call)
    }

    pub fn order(&self, quote: OrderRequest) -> Result<PreparedCall> {
        self.bulk_orders(&[quote])
    }

    pub fn cancel(&self, request: CancelRequest) -> Result<PreparedCall> {
        self.bulk_cancel(&[request])
    }

    pub fn bulk_cancel(&self, quotes: &[CancelRequest]) -> Result<PreparedCall> {
        let quotes: Vec<_> = quotes
            .iter()
            .map(|q| {
                let mut quote = OrderRequest::new(q.pair_index, q.mid, 0, q.sequence, 0);
                quote.sides = Sides::Neither;
                quote.depth_scale = 0;
                quote
            })
            .collect();
        self.bulk_orders(&quotes)
    }

    /// Cancels every live pair's quotes in one atomic post, from the cancels
    /// [`Info::cancel_all_requests`](crate::Info::cancel_all_requests) read (its `cancels`): a
    /// [`bulk_cancel`](Self::bulk_cancel) of them. It never halts the venue. An empty list is
    /// refused with [`Error::NothingToCancel`]: no pair has a quote to cancel.
    pub fn cancel_all(&self, requests: &[CancelRequest]) -> Result<PreparedCall> {
        if requests.is_empty() {
            return Err(Error::NothingToCancel {
                skipped: Vec::new(),
            });
        }
        self.bulk_cancel(requests)
    }

    /// Owner-only recovery while halted: restores the initial, unfillable hot word without
    /// refilling consumed depth. Stop writers, revoke compromised updaters and discard queued
    /// posts first; recreate the sequencer, post a fresh quote, then resume.
    pub fn reset_hot_word(&self, pair_index: u16) -> PreparedCall {
        self.prepare(IVenue::resetHotWordCall {
            pairIndex: pair_index,
        })
    }

    /// Venue-wide stop: owner or updater halts fills without reading any sequences;
    /// only the owner resumes. Resume re-arms any unexpired words, so refresh them
    /// before resuming. To pull quotes without halting, use `cancel_all`.
    pub fn set_halted(&self, halted: bool) -> PreparedCall {
        self.prepare(IVenue::setHaltedCall { halted })
    }
    pub fn close_pair(&self, pair_index: u16) -> PreparedCall {
        self.prepare(IVenue::closePairCall {
            pairIndex: pair_index,
        })
    }

    /// Owner only. Entering Open requires a halted venue. Reopening re-arms the
    /// existing hot word; refresh it first. Denials override every mode.
    pub fn set_pair_access(&self, pair_index: u16, mode: AccessMode) -> PreparedCall {
        self.prepare(IVenue::setPairAccessCall {
            pairIndex: pair_index,
            mode: mode.into(),
        })
    }

    /// Owner only: authorize a venue updater. Unlike a Hyperliquid API wallet,
    /// this grants onchain post/shape and access-narrowing powers, not custody.
    pub fn approve_agent(&self, agent: Address) -> Result<PreparedCall> {
        require_callable(agent)?;
        Ok(self.prepare(IVenue::setUpdaterCall {
            updater: agent,
            allowed: true,
        }))
    }

    /// Owner only: revoke an updater's permissions. Existing quotes stay live.
    pub fn revoke_agent(&self, agent: Address) -> PreparedCall {
        self.prepare(IVenue::setUpdaterCall {
            updater: agent,
            allowed: false,
        })
    }

    /// Owner only: register a nonzero sponsor id, initially enabled but admitted
    /// on no pair. The contract validates the admin address.
    pub fn add_sponsor(&self, sponsor_id: u64, admin: Address) -> PreparedCall {
        self.prepare(IVenue::addSponsorCall {
            sponsorId: sponsor_id,
            admin,
        })
    }

    /// Owner enables/disables; updaters can only disable. Existing lists survive.
    pub fn set_sponsor_enabled(&self, sponsor_id: u64, enabled: bool) -> PreparedCall {
        self.prepare(IVenue::setSponsorEnabledCall {
            sponsorId: sponsor_id,
            enabled,
        })
    }

    /// Owner admits/removes; updaters can only remove. Existing lists survive.
    pub fn set_pair_sponsor(
        &self,
        pair_index: u16,
        sponsor_id: u64,
        admitted: bool,
    ) -> PreparedCall {
        self.prepare(IVenue::setPairSponsorCall {
            pairIndex: pair_index,
            sponsorId: sponsor_id,
            admitted,
        })
    }

    /// Edit one list atomically (at most the contract's MAX_BATCH accounts).
    /// Id 0 is owner-only; other ids are sponsor-admin-only, even for the owner.
    /// Listing requires an enabled, admitted sponsor; delisting always works.
    /// Screens 1..=100 nonzero, non-venue accounts offline; virtual entries may only be removed.
    pub fn set_members(
        &self,
        pair_index: u16,
        sponsor_id: u64,
        accounts: &[Address],
        allowed: bool,
    ) -> Result<PreparedCall> {
        self.validate_accounts(accounts, allowed)?;
        Ok(self.prepare(IVenue::setMembersCall {
            pairIndex: pair_index,
            sponsorId: sponsor_id,
            accounts: accounts.to_vec(),
            allowed,
        }))
    }

    /// Sponsor admin only: propose a nonzero successor.
    pub fn transfer_sponsor_admin(&self, sponsor_id: u64, new_admin: Address) -> PreparedCall {
        self.prepare(IVenue::transferSponsorAdminCall {
            sponsorId: sponsor_id,
            newAdmin: new_admin,
        })
    }

    /// Sponsor admin only: clear a pending successor. This is idempotent.
    pub fn cancel_sponsor_admin_transfer(&self, sponsor_id: u64) -> PreparedCall {
        self.prepare(IVenue::cancelSponsorAdminTransferCall {
            sponsorId: sponsor_id,
        })
    }

    /// Pending sponsor admin only: accept control of the existing lists.
    pub fn accept_sponsor_admin(&self, sponsor_id: u64) -> PreparedCall {
        self.prepare(IVenue::acceptSponsorAdminCall {
            sponsorId: sponsor_id,
        })
    }

    /// Owner only: assign a new admin and permanently invalidate ALL previous
    /// memberships for this id. Enabled state and pair admissions are retained.
    pub fn reset_sponsor(&self, sponsor_id: u64, new_admin: Address) -> PreparedCall {
        self.prepare(IVenue::resetSponsorCall {
            sponsorId: sponsor_id,
            newAdmin: new_admin,
        })
    }

    /// Owner denies/lifts; updaters only deny. Denials apply venue-wide, including
    /// Open pairs. Screens batch size and accounts offline; virtual entries may only be removed.
    pub fn set_denied(&self, accounts: &[Address], deny: bool) -> Result<PreparedCall> {
        self.validate_accounts(accounts, deny)?;
        Ok(self.prepare(IVenue::setDeniedCall {
            accounts: accounts.to_vec(),
            deny,
        }))
    }

    /// Owner only: propose a nonzero successor; permissions change on acceptance.
    pub fn transfer_ownership(&self, new_owner: Address) -> Result<PreparedCall> {
        require_callable(new_owner)?;
        Ok(self.prepare(IVenue::transferOwnershipCall {
            newOwner: new_owner,
        }))
    }

    /// Owner only: clear a pending successor. This is idempotent.
    pub fn cancel_ownership_transfer(&self) -> PreparedCall {
        self.prepare(IVenue::cancelOwnershipTransferCall {})
    }

    /// Pending owner only: accept custody and administration of the venue.
    pub fn accept_ownership(&self) -> PreparedCall {
        self.prepare(IVenue::acceptOwnershipCall {})
    }
    /// Changing an active shape reprices immediately, even before another post.
    /// Define an inactive shape, confirm it, then switch its id in `bulk_orders`.
    pub fn set_shape(&self, pair_index: u16, shape_id: u8, shape: &Shape) -> PreparedCall {
        self.prepare(IVenue::setShapeCall {
            pairIndex: pair_index,
            shapeId: shape_id,
            words: shape.words(),
        })
    }
    /// Owner-only inventory withdrawal, with exact debit and credit checks onchain.
    pub fn withdraw(
        &self,
        token: Address,
        to: Address,
        amount: U256,
        memo: B256,
    ) -> Result<PreparedCall> {
        if token.is_zero() || to.is_zero() || to == self.venue || amount.is_zero() {
            return Err(Error::Invalid("withdrawal"));
        }
        require_callable(to)?;
        Ok(self.prepare(IVenue::withdrawCall {
            token,
            to,
            amount,
            memo,
        }))
    }

    fn validate_accounts(&self, accounts: &[Address], adding: bool) -> Result<()> {
        if accounts.is_empty() || accounts.len() > MAX_BATCH {
            return Err(Error::Invalid("account batch size (expected 1..=100)"));
        }
        for &account in accounts {
            if account.is_zero() || account == self.venue {
                return Err(Error::Invalid("zero or venue account"));
            }
            if adding {
                require_callable(account)?;
            }
        }
        Ok(())
    }
}
