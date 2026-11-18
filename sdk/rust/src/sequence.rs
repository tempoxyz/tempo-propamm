use std::{
    collections::HashMap,
    sync::{
        PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard,
        atomic::{AtomicU32, Ordering},
    },
};

use alloy::{network::Network, providers::Provider, rpc::types::BlockId};

use crate::{Error, HotWord, Info, Result, bindings::IVenue};

/// In-process sequence allocator for one venue, for a single writer process.
///
/// Seed it once, then take every order's and cancel's sequence from [`next`](Self::next).
/// It never rereads the chain, so it cannot hand out a number that an unmined post of
/// its own already uses; "read the stored sequence and add one" can. The venue accepts
/// any sequence above the stored one, so gaps are harmless.
///
/// Every writer to a pair must share one allocator. Separate processes, keys or nonce
/// lanes need a shared counter (for example, a database row per pair) instead. A pair it
/// wasn't made with (one the venue added later, or a market moved to another index) joins it
/// through [`observe`](Self::observe), at the pair's stored sequence.
///
/// For a deliberate reset, follow the README's recovery protocol: halt, fence old allocators,
/// durable writes and executable posts (halt does not block posts), then confirm a separate owner
/// `resetHotWord`. Atomically transition only that pair's durable application generation and floor
/// to the confirmed reset state, bound idempotently to the receipt: retries must not clear later
/// allocations. Reject old-generation writes atomically and preserve other pairs. Restore only
/// current-generation floors into a fresh allocator, never the pre-reset checkpoint; `observe`
/// cannot lower it. Neither SDK nor contract carries a reset epoch or fences old posts.
#[derive(Debug, Default)]
pub struct Sequencer {
    /// Each pair's counter. Allocating takes the read lock and bumps the pair's atomic, so
    /// concurrent callers never wait on each other; only a pair's first `observe` takes the
    /// write lock, to add it.
    last: RwLock<HashMap<u16, AtomicU32>>,
}

impl Sequencer {
    /// Start from known last-used sequences, such as a durable checkpoint persisted before
    /// broadcasting each allocation. On restart, stop the old writer and [`observe`](Self::observe)
    /// each pair's current stored sequence as well, so neither floor is lost.
    pub fn new(last: impl IntoIterator<Item = (u16, u32)>) -> Self {
        Self {
            last: RwLock::new(
                last.into_iter()
                    .map(|(pair_index, sequence)| (pair_index, AtomicU32::new(sequence)))
                    .collect(),
            ),
        }
    }

    /// Start from each pair's stored sequence plus `gap`.
    ///
    /// A fresh process cannot discover unmined allocations from the chain. For a restart,
    /// stop the old writer and restore a durable [`checkpoint`](Self::checkpoint) with
    /// [`new`](Self::new), then [`observe`](Self::observe) each pair's current stored sequence:
    /// the counter must be at least `max(stored_sequence, last_allocated)`. Persist every
    /// allocation before broadcasting its post. Without a checkpoint, wait until all earlier
    /// posts have landed or can no longer execute, then read the settled chain. A gap is safe
    /// only if `stored_sequence + gap` covers the highest potentially executable sequence,
    /// not the pending-post count. Reusing the same gap on restart can reuse an unmined sequence.
    pub async fn seed<P: Provider<N>, N: Network>(
        info: &Info<P, N>,
        pairs: &[u16],
        gap: u32,
        block: BlockId,
    ) -> Result<Self> {
        let venue = IVenue::new(info.venue(), info.provider());
        let mut last = HashMap::with_capacity(pairs.len());
        for &pair_index in pairs {
            let word = venue.hotWord(pair_index).block(block).call().await?;
            if word.is_zero() {
                return Err(Error::UnknownPair(pair_index));
            }
            let sequence = HotWord::decode(word)?
                .sequence
                .checked_add(gap)
                .ok_or(Error::SequenceExhausted(pair_index))?;
            last.insert(pair_index, sequence);
        }
        Ok(Self::new(last))
    }

    /// Allocate the pair's next sequence. Concurrent callers never receive the same one.
    /// `Error::UnseededPair` for a pair it doesn't track: [`observe`](Self::observe) its stored
    /// sequence first.
    pub fn next(&self, pair_index: u16) -> Result<u32> {
        self.read()
            .get(&pair_index)
            .ok_or(Error::UnseededPair(pair_index))?
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |last| {
                last.checked_add(1)
            })
            .map(|last| last + 1)
            .map_err(|_| Error::SequenceExhausted(pair_index))
    }

    /// Raise the pair's floor after learning of a higher stored sequence, for example
    /// one posted by the owner. Never lowers it. A pair it doesn't track yet starts at
    /// `sequence`: observe a new pair's stored sequence once (a pair the venue added, or a
    /// market that moved to another index) and [`next`](Self::next) allocates above it.
    pub fn observe(&self, pair_index: u16, sequence: u32) -> Result<()> {
        if let Some(counter) = self.read().get(&pair_index) {
            counter.fetch_max(sequence, Ordering::Relaxed);
            return Ok(());
        }
        // A concurrent first observe of the same pair may have added it: keep the higher.
        self.write()
            .entry(pair_index)
            .or_insert_with(|| AtomicU32::new(sequence))
            .fetch_max(sequence, Ordering::Relaxed);
        Ok(())
    }

    /// Allocates the pair's next sequence above `floor` as well: its counter becomes
    /// `max(last, floor) + 1`, which it returns. A pair it doesn't track yet joins it, as
    /// [`observe`](Self::observe) adds one, at `floor`. `None` when that would pass `u32::MAX`
    /// (the counter is left as it is).
    pub(crate) fn next_above(&self, pair_index: u16, floor: u32) -> Option<u32> {
        let bump = |counter: &AtomicU32| {
            counter
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |last| {
                    last.max(floor).checked_add(1)
                })
                .ok()
                .map(|last| last.max(floor) + 1)
        };
        if let Some(counter) = self.read().get(&pair_index) {
            return bump(counter);
        }
        bump(
            self.write()
                .entry(pair_index)
                .or_insert_with(|| AtomicU32::new(floor)),
        )
    }

    /// Every pair's most recently allocated (or seeded) sequence, in pair order: a snapshot
    /// to persist for [`new`](Self::new) to restart from, including the pairs
    /// [`observe`](Self::observe) and `Exchange::cancel_all` added. The TypeScript SDK's
    /// `sequencer.last`. This method performs no durable write and is not an atomic snapshot
    /// across pairs. Within each current application generation, atomically max-merge each entry
    /// into storage, never lowering a floor or
    /// deleting other pairs; await durable commit before broadcasting the corresponding allocation.
    /// Concurrent writes can finish out of order: whole-checkpoint replacement can overwrite a
    /// higher, already broadcast sequence with an older snapshot. Serialize checkpoint capture and
    /// commit through one writer, or use transactional per-pair maxima. Stop or fence the old process against
    /// allocation and broadcast before restoring the latest committed checkpoint. Storage maxima
    /// alone do not coordinate separate allocators. Deliberate reset transitions require the
    /// generation-fenced recovery protocol documented on [`Sequencer`].
    pub fn checkpoint(&self) -> Vec<(u16, u32)> {
        let mut out: Vec<(u16, u32)> = self
            .read()
            .iter()
            .map(|(pair_index, last)| (*pair_index, last.load(Ordering::Relaxed)))
            .collect();
        out.sort_unstable();
        out
    }

    /// The pair's most recently allocated (or seeded) sequence.
    pub fn last(&self, pair_index: u16) -> Option<u32> {
        self.read()
            .get(&pair_index)
            .map(|last| last.load(Ordering::Relaxed))
    }

    /// The counters, shared. A panic while the lock is held leaves every counter valid (each
    /// changes only through one atomic operation), so a poisoned lock is used as it is.
    fn read(&self) -> RwLockReadGuard<'_, HashMap<u16, AtomicU32>> {
        self.last.read().unwrap_or_else(PoisonError::into_inner)
    }

    fn write(&self) -> RwLockWriteGuard<'_, HashMap<u16, AtomicU32>> {
        self.last.write().unwrap_or_else(PoisonError::into_inner)
    }
}
