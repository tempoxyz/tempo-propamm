use alloy::{
    network::{Ethereum, Network},
    primitives::{Address, B256, Bytes, U256},
    providers::{PendingTransactionBuilder, Provider},
    rpc::types::BlockId,
};

use crate::{
    AccessMode, Actions, CancelRequest, Error, Info, OrderRequest, PreparedCall, Result, Sequencer,
    Shape, SkippedPair, info::plan,
};

/// What [`Exchange::cancel_all`] sent: the pending transaction, its call (to reconcile the
/// receipt with [`PostOutcome::from_logs`](crate::PostOutcome::from_logs)), and every live pair it
/// sent no cancel, in pair order. A successful receipt whose cancels were all accepted still
/// leaves each skipped pair as it was: one at the last sequence still quotes.
#[derive(Debug)]
pub struct CancelAllSent<N: Network> {
    pub pending: PendingTransactionBuilder<N>,
    pub call: PreparedCall,
    pub skipped: Vec<SkippedPair>,
}

/// Signed action API, paired with read-only [`Info`]. The provider supplies the
/// signer, fees, gas and nonce policy. Every action broadcasts once and returns
/// a pending transaction; callers await and check the receipt themselves.
/// Permissions are enforced by the venue at execution, never inferred locally.
#[derive(Clone, Debug)]
pub struct Exchange<P, N = Ethereum> {
    info: Info<P, N>,
    sender: Address,
}

impl<P: Provider<N>, N: Network> Exchange<P, N> {
    /// Bind a validated Info connection to the address used for every action and
    /// simulation. The provider must be able to sign for this address (or use an
    /// unlocked account on a local node).
    pub const fn new(info: Info<P, N>, sender: Address) -> Self {
        Self { info, sender }
    }

    pub const fn info(&self) -> &Info<P, N> {
        &self.info
    }
    pub const fn sender(&self) -> Address {
        self.sender
    }
    pub const fn actions(&self) -> &Actions {
        self.info.actions()
    }

    async fn check_call(&self, call: &PreparedCall) -> Result<()> {
        if call.venue() != self.info.venue() || call.chain_id() != self.info.chain_id() {
            return Err(Error::CallMismatch);
        }
        self.info.check_chain().await
    }

    /// Simulate as this exchange's sender without broadcasting or reserving state.
    pub async fn simulate(&self, call: &PreparedCall) -> Result<Bytes> {
        self.check_call(call).await?;
        Ok(self
            .info
            .provider()
            .call(call.transaction::<N>(self.sender))
            .await?)
    }

    /// Submit a prepared call once, after checking chain and target. No implicit
    /// simulation or retry. A successful receipt may still contain skipped stale
    /// posts; reconcile its Posted events with [`PostOutcome`](crate::PostOutcome).
    pub async fn send(&self, call: &PreparedCall) -> Result<PendingTransactionBuilder<N>> {
        self.check_call(call).await?;
        Ok(self
            .info
            .provider()
            .send_transaction(call.transaction::<N>(self.sender))
            .await?)
    }

    /// Post one whole pair ladder; the shape must already exist.
    pub async fn order(&self, request: OrderRequest) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().order(request)?).await
    }

    /// Post distinct pairs atomically. Stale entries are skipped without events.
    pub async fn bulk_orders(
        &self,
        requests: &[OrderRequest],
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().bulk_orders(requests)?).await
    }

    /// Disable both sides using a newer sequence; later posts can re-enable them.
    pub async fn cancel(&self, request: CancelRequest) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().cancel(request)?).await
    }

    /// Cancel distinct pairs in one post, subject to normal sequence ordering.
    pub async fn bulk_cancel(
        &self,
        requests: &[CancelRequest],
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().bulk_cancel(requests)?).await
    }

    /// Cancel every live pair's quotes in one atomic post, without halting the venue: reads
    /// them as [`Info::cancel_all_requests`] does, every read at the latest block's hash, and
    /// sends [`Actions::cancel_all`]. Pass the sequencer your posts draw from, so each cancel
    /// outranks this process's own unmined posts: before it sends, each pair's cancel is allocated
    /// from it (`max(last, stored) + 1`; a pair it doesn't track joins it at that sequence), so its
    /// next post outranks the cancel. All hot words, bands and cancel prices are validated
    /// before any shared sequence is reserved; malformed reads send nothing. A newer
    /// post can still supersede a cancel: reconcile the receipt with the returned `call`. The
    /// returned `skipped` lists the live pairs it sent no cancel. When no pair gets a cancel it
    /// sends nothing and returns [`Error::NothingToCancel`], carrying every skipped pair with its
    /// reason, as read at the same block.
    pub async fn cancel_all(&self, sequencer: Option<&Sequencer>) -> Result<CancelAllSent<N>> {
        // Reject a switched provider before discovering pairs or reserving sequences.
        self.info.check_chain().await?;
        let pairs = self.info.cancel_all_pairs(BlockId::latest()).await?;
        let requests = plan(&pairs, sequencer, true)?;
        if requests.cancels.is_empty() {
            return Err(Error::NothingToCancel {
                skipped: requests.skipped,
            });
        }
        let call = self.actions().cancel_all(&requests.cancels)?;
        let pending = self.send(&call).await?;
        Ok(CancelAllSent {
            pending,
            call,
            skipped: requests.skipped,
        })
    }

    /// Owner-only hot-word recovery while halted. Preserves consumed depth and configuration.
    /// Stop writers, revoke compromised updaters, discard queued posts and reseed before resuming.
    pub async fn reset_hot_word(&self, pair_index: u16) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().reset_hot_word(pair_index)).await
    }

    /// Owner resumes; owner or updater halts. Resume re-arms unexpired words.
    pub async fn set_halted(&self, halted: bool) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().set_halted(halted)).await
    }

    /// Owner/updater defines a shape. Editing an active shape reprices immediately.
    pub async fn set_shape(
        &self,
        pair_index: u16,
        shape_id: u8,
        shape: &Shape,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().set_shape(pair_index, shape_id, shape))
            .await
    }

    /// Owner/updater closes access independently of sequence; only owner reopens.
    pub async fn close_pair(&self, pair_index: u16) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().close_pair(pair_index)).await
    }

    /// Owner sets access mode. Entering Open requires the venue to be halted.
    pub async fn set_pair_access(
        &self,
        pair_index: u16,
        mode: AccessMode,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().set_pair_access(pair_index, mode))
            .await
    }

    /// Owner grants updater powers: posting, shapes and narrowing access; no custody.
    pub async fn approve_agent(&self, agent: Address) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().approve_agent(agent)?).await
    }

    /// Owner revokes updater permissions. Existing quotes remain live.
    pub async fn revoke_agent(&self, agent: Address) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().revoke_agent(agent)).await
    }

    /// Owner registers a nonzero id, enabled but not yet admitted on any pair.
    pub async fn add_sponsor(
        &self,
        sponsor_id: u64,
        admin: Address,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().add_sponsor(sponsor_id, admin))
            .await
    }

    /// Owner enables/disables; updater only disables. Membership is retained.
    pub async fn set_sponsor_enabled(
        &self,
        sponsor_id: u64,
        enabled: bool,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().set_sponsor_enabled(sponsor_id, enabled))
            .await
    }

    /// Owner admits/removes; updater only removes. Membership is retained.
    pub async fn set_pair_sponsor(
        &self,
        pair_index: u16,
        sponsor_id: u64,
        admitted: bool,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(
            &self
                .actions()
                .set_pair_sponsor(pair_index, sponsor_id, admitted),
        )
        .await
    }

    /// Owner edits home list 0; sponsor admins alone edit their own lists. Atomic batch.
    pub async fn set_members(
        &self,
        pair_index: u16,
        sponsor_id: u64,
        accounts: &[Address],
        allowed: bool,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(
            &self
                .actions()
                .set_members(pair_index, sponsor_id, accounts, allowed)?,
        )
        .await
    }

    /// Sponsor admin proposes a nonzero successor.
    pub async fn transfer_sponsor_admin(
        &self,
        sponsor_id: u64,
        new_admin: Address,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().transfer_sponsor_admin(sponsor_id, new_admin))
            .await
    }

    /// Sponsor admin clears a pending successor. This is idempotent.
    pub async fn cancel_sponsor_admin_transfer(
        &self,
        sponsor_id: u64,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().cancel_sponsor_admin_transfer(sponsor_id))
            .await
    }

    /// Pending admin accepts control of the sponsor lists.
    pub async fn accept_sponsor_admin(
        &self,
        sponsor_id: u64,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().accept_sponsor_admin(sponsor_id))
            .await
    }

    /// Owner replaces admin and permanently invalidates every prior membership.
    pub async fn reset_sponsor(
        &self,
        sponsor_id: u64,
        new_admin: Address,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().reset_sponsor(sponsor_id, new_admin))
            .await
    }

    /// Owner denies/lifts; updater only denies. Applies to every pair and mode.
    pub async fn set_denied(
        &self,
        accounts: &[Address],
        deny: bool,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().set_denied(accounts, deny)?).await
    }

    /// Owner proposes a nonzero successor. The current owner retains powers until acceptance.
    pub async fn transfer_ownership(
        &self,
        new_owner: Address,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().transfer_ownership(new_owner)?)
            .await
    }

    /// Owner clears a pending successor. This is idempotent.
    pub async fn cancel_ownership_transfer(&self) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().cancel_ownership_transfer()).await
    }

    /// Pending owner accepts custody and administration of the venue.
    pub async fn accept_ownership(&self) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().accept_ownership()).await
    }

    /// Owner withdraws inventory with exact balance-delta checks.
    pub async fn withdraw(
        &self,
        token: Address,
        to: Address,
        amount: U256,
        memo: B256,
    ) -> Result<PendingTransactionBuilder<N>> {
        self.send(&self.actions().withdraw(token, to, amount, memo)?)
            .await
    }
}
