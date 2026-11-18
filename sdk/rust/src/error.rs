use thiserror::Error;

use crate::SkippedPair;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid {0}")]
    Invalid(&'static str),
    #[error("duplicate pair index {0} in batch")]
    DuplicatePair(u16),
    #[error("pair {0} has exhausted its sequence numbers")]
    SequenceExhausted(u16),
    #[error("pair {0} was not seeded in the sequencer")]
    UnseededPair(u16),
    #[error("unknown or removed pair {0}")]
    UnknownPair(u16),
    /// `cancel_all` had no pair to cancel: every live pair is in `skipped`, with its reason (empty
    /// when [`Actions::cancel_all`](crate::Actions::cancel_all) was given no cancels). Nothing was
    /// sent. The TypeScript SDK's `EmptyBatchError` from `cancelAll`.
    #[error("nothing to cancel: no live pair has a quote cancel_all can cancel ({} skipped)", skipped.len())]
    NothingToCancel { skipped: Vec<SkippedPair> },
    #[error("wrong chain: expected {expected}, got {actual}")]
    ChainMismatch { expected: u64, actual: u64 },
    #[error("call targets a different venue or chain")]
    CallMismatch,
    #[error("venue is not recognized by the configured factory")]
    UnknownVenue,
    #[error(transparent)]
    Contract(#[from] alloy::contract::Error),
    #[error(transparent)]
    Transport(#[from] alloy::transports::TransportError),
}
