// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAggregatorV3 } from "./interfaces/IAggregatorV3.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

/// @notice Immutable 18-to-8 decimal adapter for Chainlink AggregatorV3 feeds.
/// @dev Uses the report's `startedAt` observation time for freshness and quote binding. `updatedAt`
///      only proves when that observation was recorded onchain and cannot make a delayed report fresh.
/// @dev Scaling rounds down by less than 1e-8 quote units per base token. A subprecision answer returns zero,
///      which the pool rejects. This changes precision only: it does not convert WYLDS, USD or USDC denominations.
contract Chainlink18To8PriceOracleAdapter is IPriceOracle {
    error FeedDecimalsChanged(uint8 expectedDecimals, uint8 actualDecimals);
    error InvalidFeed();
    error InvalidFeedTimestamps(uint256 startedAt, uint256 updatedAt);

    uint8 private constant FEED_DECIMALS = 18;
    uint256 private constant SCALE_DOWN = 1e10;

    IAggregatorV3 public immutable feed;
    uint8 public constant override decimals = 8;

    constructor(IAggregatorV3 feed_) {
        if (address(feed_) == address(0)) revert InvalidFeed();
        feed = feed_;
        uint8 feedDecimals = feed_.decimals();
        if (feedDecimals != FEED_DECIMALS) revert FeedDecimalsChanged(FEED_DECIMALS, feedDecimals);
    }

    function latestPrice() external view override returns (uint256 price, uint256 updatedAt) {
        uint8 currentDecimals = feed.decimals();
        if (currentDecimals != FEED_DECIMALS) revert FeedDecimalsChanged(FEED_DECIMALS, currentDecimals);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 feedUpdatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (startedAt == 0 || feedUpdatedAt == 0 || startedAt > feedUpdatedAt) {
            revert InvalidFeedTimestamps(startedAt, feedUpdatedAt);
        }
        if (answer <= 0 || answeredInRound < roundId) return (0, startedAt);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer) / SCALE_DOWN, startedAt);
    }
}
