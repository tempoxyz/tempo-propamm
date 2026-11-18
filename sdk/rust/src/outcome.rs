use alloy::{
    primitives::B256,
    rpc::types::Log,
    sol_types::{SolCall, SolEvent},
};

use crate::{Error, PreparedCall, Result, bindings::IVenue};

/// The refill flags (flag bits 2 and 3, in a word's second byte): the venue applies
/// them once, then stores and emits the word without them.
const REFILL_FLAGS: u8 = 0x0c;

/// Which entries of a mined order or cancel batch the venue stored.
///
/// The venue skips an entry whose sequence is not above the stored one, without
/// reverting or emitting an event, so a successful receipt alone does not mean a
/// quote is live. Build this from the receipt's logs after checking its status: a
/// reverted transaction has no logs and would report every entry as skipped.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PostOutcome {
    /// `(pair_index, sequence)` entries acknowledged by `Posted`, in request order.
    pub accepted: Vec<(u16, u32)>,
    /// Entries the venue ignored because its stored sequence was already at or
    /// above them, in request order.
    pub skipped: Vec<(u16, u32)>,
}

impl PostOutcome {
    /// Match `call`'s entries against the `Posted` events in a receipt's logs.
    /// Logs from other contracts and other events are ignored. If the transaction
    /// carried other posts to the venue, such as a Tempo batch of several calls,
    /// match them together with [`from_batch`](Self::from_batch). A reset of this
    /// call's pair makes the receipt ambiguous: send `resetHotWord` separately,
    /// then attribute fresh posts from a later receipt.
    pub fn from_logs(call: &PreparedCall, logs: &[Log]) -> Result<Self> {
        Ok(Self::from_batch(&[call], logs)?.remove(0))
    }

    /// Match the post calls of one transaction, in the order it sent them, against
    /// its logs. Each entry claims the first unclaimed `Posted` event at its venue
    /// for its pair and its word as the venue stores it, refill bits cleared. The
    /// venue applies or skips entries in that same order, so an entry that repeats
    /// an earlier one's pair and sequence reads skipped, even with an identical word.
    /// A `HotWordReset` for a venue and pair this function attributes is ambiguous,
    /// so this refuses the receipt; send that reset in a separate transaction.
    /// Recognized `Posted` and `HotWordReset` logs are decoded with Alloy ABI
    /// validation, rejecting noncanonical integer padding with [`Error::Invalid`].
    /// This does not reject trailing event data.
    pub fn from_batch(calls: &[&PreparedCall], logs: &[Log]) -> Result<Vec<Self>> {
        if calls.iter().any(|call| call.posts().is_empty()) {
            return Err(Error::Invalid("call: not an order or cancel batch"));
        }
        let mut posted = Vec::new();
        for log in logs {
            if !calls.iter().any(|call| call.venue() == log.address()) {
                continue;
            }
            if log.topic0() == Some(&IVenue::HotWordReset::SIGNATURE_HASH) {
                let event = log
                    .log_decode_validate::<IVenue::HotWordReset>()
                    .map_err(|_| Error::Invalid("HotWordReset event"))?
                    .inner
                    .data;
                if calls.iter().any(|call| {
                    call.venue() == log.address()
                        && call
                            .posts()
                            .iter()
                            .any(|&(pair_index, _)| pair_index == event.pairIndex)
                }) {
                    return Err(Error::Invalid(
                        "post outcome: HotWordReset makes attribution ambiguous",
                    ));
                }
                continue;
            }
            if log.topic0() != Some(&IVenue::Posted::SIGNATURE_HASH) {
                continue;
            }
            let event = log
                .log_decode_validate::<IVenue::Posted>()
                .map_err(|_| Error::Invalid("Posted event"))?
                .inner
                .data;
            posted.push(Some((log.address(), event.pairIndex, event.hotWord)));
        }
        calls
            .iter()
            .map(|call| {
                let packed = IVenue::postCall::abi_decode(call.data())
                    .map_err(|_| Error::Invalid("call: not an order or cancel batch"))?
                    .packed;
                let mut outcome = Self::default();
                for (&entry, bytes) in call.posts().iter().zip(packed.chunks_exact(34)) {
                    let mut word = B256::from_slice(&bytes[2..]);
                    word[1] &= !REFILL_FLAGS;
                    let event = Some((call.venue(), entry.0, word));
                    match posted.iter_mut().find(|posted| **posted == event) {
                        Some(claimed) => {
                            *claimed = None;
                            outcome.accepted.push(entry);
                        }
                        None => outcome.skipped.push(entry),
                    }
                }
                Ok(outcome)
            })
            .collect()
    }

    /// Whether every entry in the batch was stored.
    pub fn all_accepted(&self) -> bool {
        self.skipped.is_empty()
    }
}
