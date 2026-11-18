//! Bindings generated at compile time from the authoritative v2 interfaces.
//! Includes the complete owner/access API, events, and custom errors.

// Generated function signatures follow Solidity, including long event/argument lists.
#![allow(clippy::too_many_arguments)]

use alloy::sol;

sol!(
    #[sol(rpc, all_derives)]
    "../../contracts/src/interfaces/ITIP20.sol"
);

sol!(
    #[sol(rpc, all_derives)]
    "../../contracts/src/v2/interfaces/IVenue.sol"
);
sol!(
    #[sol(rpc, all_derives)]
    "../../contracts/src/v2/interfaces/IVenueFactory.sol"
);
sol!(
    #[sol(rpc, all_derives)]
    "../../contracts/src/v2/interfaces/ISettler.sol"
);
