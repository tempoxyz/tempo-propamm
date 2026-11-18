// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../../src/v2/libraries/ShapeWord.sol";

/// @dev Exposes the internal curve libraries so their reverts surface as external call failures.
contract LadderMathHarness {
    /// @dev A fill on a fresh side: nothing consumed.
    function fill(bytes32 hot, uint64 sizeUnit, bool baseIn, uint256 w0, uint256 w1, bool exactIn, uint256 amount)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return LadderMath.fill(LadderMath.curve(hot, sizeUnit, baseIn), w0, w1, exactIn, amount, 0);
    }

    /// @dev The walk from `consumed` base down the ladder.
    function fillFrom(
        bytes32 hot,
        uint64 sizeUnit,
        bool baseIn,
        uint256 w0,
        uint256 w1,
        bool exactIn,
        uint256 amount,
        uint256 consumed
    ) external pure returns (uint256, uint256, uint256) {
        return LadderMath.fill(LadderMath.curve(hot, sizeUnit, baseIn), w0, w1, exactIn, amount, consumed);
    }

    function check(uint256[4] memory words) external pure returns (uint8) {
        return ShapeWord.check(words);
    }

    function isWellFormed(bytes32 hot) external pure returns (bool) {
        return HotWord.isWellFormed(hot);
    }
}
