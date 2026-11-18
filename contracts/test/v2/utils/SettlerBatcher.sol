// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapParams } from "./SwapParams.sol";

import { ISettler } from "../../../src/v2/interfaces/ISettler.sol";
import { Settler } from "../../../src/v2/Settler.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";

/// @dev Runs several swaps inside one external call, so they share one transaction's transient storage even with
/// `isolate = true`. A successful exact-in and a successful exact-out are each followed by another swap, which would
/// revert with `Reentrancy` if either function left the lock set. The swap caught in between reverts on purpose: it
/// shows a caught failure doesn't leave the lock set either, but that is guaranteed by transient storage rolling back
/// with the reverting frame, not by the Settler's own unlock. The batcher is the taker of every swap, so it receives
/// every output.
contract SettlerBatcher {
    error ExpectedRevert();
    error WrongRevert(bytes reason);

    Settler internal immutable SETTLER;

    constructor(Settler settler_) {
        SETTLER = settler_;
    }

    function approve(MockTIP20V2 token) external {
        token.approve(address(SETTLER), type(uint256).max);
    }

    function run(address tokenIn, address tokenOut, SwapParams calldata fills, uint40 deadline)
        external
        returns (uint256 firstOut, uint256 exactOutIn, uint256 lastOut)
    {
        firstOut = SETTLER.swapExactIn(
            fills.venue, fills.pairIndex, tokenIn, tokenOut, fills.amount, 0, fills.sponsorId, deadline, "first"
        );
        try SETTLER.swapExactIn(
            fills.venue,
            fills.pairIndex,
            tokenIn,
            tokenOut,
            fills.amount,
            type(uint256).max,
            fills.sponsorId,
            deadline,
            "reverts"
        ) {
            revert ExpectedRevert();
        } catch (bytes memory reason) {
            if (bytes4(reason) != ISettler.InsufficientOutput.selector) revert WrongRevert(reason);
        }
        exactOutIn = SETTLER.swapExactOut(
            fills.venue,
            fills.pairIndex,
            tokenIn,
            tokenOut,
            fills.amount,
            type(uint256).max,
            fills.sponsorId,
            deadline,
            "second"
        );
        lastOut = SETTLER.swapExactIn(
            fills.venue, fills.pairIndex, tokenIn, tokenOut, fills.amount, 0, fills.sponsorId, deadline, "third"
        );
    }
}
