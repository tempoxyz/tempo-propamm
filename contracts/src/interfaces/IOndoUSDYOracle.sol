// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal interface for Ondo's USDY oracle wrapper: the price surface Ondo keeps across oracle migrations.
interface IOndoUSDYOracleWrapper {
    function getPriceData() external view returns (uint256 price, uint256 timestamp);
}
