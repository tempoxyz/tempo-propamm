// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { IOndoUSDYOracleWrapper } from "./interfaces/IOndoUSDYOracle.sol";

/// @notice Read-only adapter from Ondo's USDY oracle wrapper to the pool oracle interface.
/// @dev The adapter reads only the wrapper's `getPriceData()` price, the one interface Ondo keeps stable when it
///      replaces the oracle behind the wrapper (`rwaOracle()`). It never reads that oracle's internals: the
///      October 2026 migration from `RWADynamicOracle` (daily steps inside `ranges(i)`) to a continuously accruing
///      rate oracle removed `ranges`, which reverted every read of the earlier range-walking adapter.
///
///      Ondo's price is a schedule computed on read, not a reported observation, so it is always current: the
///      adapter returns `block.timestamp` as `updatedAt`, as the wrapper itself does. The pool's
///      `maxOracleAge` therefore never trips for USDY; its directional price-deviation limit, and the
///      quote's price binding, are what bound a wrong or overridden Ondo price. The price can change every second, so
///      a quote executes at zero price tolerance only within the block it was read in (the buffer helper quotes and
///      swaps in one transaction).
contract OndoUSDYPriceOracleAdapter is IPriceOracle {
    uint8 public constant override decimals = 18;

    error InvalidWrapper();
    error InvalidPrice();

    IOndoUSDYOracleWrapper public immutable wrapper;

    constructor(IOndoUSDYOracleWrapper wrapper_) {
        if (address(wrapper_).code.length == 0) revert InvalidWrapper();
        wrapper = wrapper_;
        // The wrapper's timestamp is block.timestamp; only its price is used.
        // forge-lint: disable-next-line(unused-return)
        (uint256 price,) = wrapper_.getPriceData();
        if (price == 0) revert InvalidPrice();
    }

    function latestPrice() external view override returns (uint256 price, uint256 updatedAt) {
        // forge-lint: disable-next-line(unused-return)
        (price,) = wrapper.getPriceData();
        if (price == 0) revert InvalidPrice();
        updatedAt = block.timestamp;
    }
}
