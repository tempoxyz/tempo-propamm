use alloy::primitives::Address;

use crate::bindings::IVenue;

/// Modes an owner can set. The ABI's `None` sentinel is not a valid action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessMode {
    Closed,
    Listed,
    Open,
}

impl From<AccessMode> for IVenue::AccessMode {
    fn from(mode: AccessMode) -> Self {
        match mode {
            AccessMode::Closed => Self::Closed,
            AccessMode::Listed => Self::Listed,
            AccessMode::Open => Self::Open,
        }
    }
}

/// Venue-wide permissions and emergency-stop state at the requested block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VenueState {
    pub owner: Address,
    pub pending_owner: Address,
    pub halted: bool,
    pub denied_count: u32,
}

/// A sponsor's current admin and membership generation. An unregistered id
/// (including home-list id 0) returns zero fields; the home list belongs to the
/// venue's current owner, not to a registered sponsor admin.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SponsorState {
    pub admin: Address,
    pub pending_admin: Address,
    pub enabled: bool,
    pub generation: u32,
}
