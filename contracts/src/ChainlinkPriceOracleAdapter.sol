// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAggregatorV3 } from "./interfaces/IAggregatorV3.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

/// @notice Minimal immutable adapter from Chainlink AggregatorV3 to the pool oracle interface.
/// @dev Uses the report's `startedAt` observation time for freshness and quote binding. `updatedAt`
///      only proves when that observation was recorded onchain and cannot make a delayed report fresh.
contract ChainlinkPriceOracleAdapter is IPriceOracle {
    error FeedDecimalsChanged(uint8 expectedDecimals, uint8 actualDecimals);
    error InvalidFeed();
    error InvalidFeedTimestamps(uint256 startedAt, uint256 updatedAt);

    IAggregatorV3 public immutable feed;
    uint8 public immutable override decimals;

    constructor(IAggregatorV3 feed_) {
        if (address(feed_) == address(0)) revert InvalidFeed();
        feed = feed_;
        decimals = feed_.decimals();
    }

    function latestPrice() external view override returns (uint256 price, uint256 updatedAt) {
        uint8 currentDecimals = feed.decimals();
        if (currentDecimals != decimals) revert FeedDecimalsChanged(decimals, currentDecimals);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 feedUpdatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (startedAt == 0 || feedUpdatedAt == 0 || startedAt > feedUpdatedAt) {
            revert InvalidFeedTimestamps(startedAt, feedUpdatedAt);
        }
        if (answer <= 0 || answeredInRound < roundId) return (0, startedAt);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer), startedAt);
    }
}
