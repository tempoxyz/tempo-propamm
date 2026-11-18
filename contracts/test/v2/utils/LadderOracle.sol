// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LadderMath } from "../../../src/v2/libraries/LadderMath.sol";

contract LadderOracle {
    /// @dev From `consumed` base down the side.
    function fill(LadderMath.Curve memory curve, uint256 w0, uint256 w1, bool exactIn, uint256 amount, uint256 consumed)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return LadderMath.fill(curve, w0, w1, exactIn, amount, consumed);
    }
}
