// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev A single swap's venue, pair and amount for test helpers, and the sponsor the taker trades under on that venue
/// (0: the venue's home list).
struct SwapParams {
    address venue;
    uint16 pairIndex;
    uint128 amount;
    uint64 sponsorId;
}
