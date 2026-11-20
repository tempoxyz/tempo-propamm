// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAggregatorV3 } from "../../../src/interfaces/IAggregatorV3.sol";
import { IOndoUSDYOracleWrapper } from "../../../src/interfaces/IOndoUSDYOracle.sol";

/// @dev A Chainlink AggregatorV3 feed with a settable latest round, for `DeployManagedOracleAdapters`' tests and its
/// Forge-script run.
contract ScriptFeed is IAggregatorV3 {
    uint8 public override decimals;
    string public override description;
    int256 public answer;
    uint256 public startedAt;

    constructor(uint8 decimals_, string memory description_, int256 answer_, uint256 startedAt_) {
        decimals = decimals_;
        description = description_;
        answer = answer_;
        startedAt = startedAt_;
    }

    function setRound(int256 answer_, uint256 startedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (7, answer, startedAt, startedAt, 7);
    }
}

/// @dev Ondo's USDY oracle wrapper, observed now. Its price is a constant, so its code works etched at the canonical
/// wrapper address, where no storage comes with it.
contract ScriptUsdyWrapper is IOndoUSDYOracleWrapper {
    uint256 public constant PRICE = 1.137e18;

    function getPriceData() external view returns (uint256, uint256) {
        return (PRICE, block.timestamp);
    }
}
