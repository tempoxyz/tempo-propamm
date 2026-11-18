// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LadderMath } from "../../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../../src/v2/libraries/ShapeWord.sol";

/// @dev Exposes `LadderMath.fill` externally so tests can catch its reverts.
contract LadderMathOracle {
    /// @dev From `consumed` base down the side, as the venue walks it after its earlier fills.
    function fill(
        bytes32 hot,
        uint64 sizeUnit,
        bool baseIn,
        uint256[4] memory words,
        bool exactIn,
        uint256 amount,
        uint256 consumed
    ) external pure returns (uint256 amountIn, uint256 amountOut, uint256 baseFilled) {
        uint256 w0 = baseIn ? words[0] : words[2];
        uint256 w1 = baseIn ? words[1] : words[3];
        if (!ShapeWord.continues(w0)) w1 = 0;
        return LadderMath.fill(LadderMath.curve(hot, sizeUnit, baseIn), w0, w1, exactIn, amount, consumed);
    }
}
