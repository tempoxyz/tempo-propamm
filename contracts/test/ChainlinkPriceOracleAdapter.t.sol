// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { ChainlinkPriceOracleAdapter } from "../src/ChainlinkPriceOracleAdapter.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

contract MockAggregatorV3 is IAggregatorV3 {
    uint8 public override decimals;
    string public override description;

    uint80 internal roundId;
    int256 internal answer;
    uint256 internal startedAt;
    uint256 internal updatedAt;
    uint80 internal answeredInRound;

    constructor(uint8 decimals_) {
        decimals = decimals_;
        description = "mock";
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract ChainlinkPriceOracleAdapterTest is Test {
    MockAggregatorV3 internal feed;
    ChainlinkPriceOracleAdapter internal adapter;

    function setUp() external {
        feed = new MockAggregatorV3(8);
        adapter = new ChainlinkPriceOracleAdapter(feed);
    }

    function test_returnsValidRound() external {
        feed.setRound(12, 105_000_000, 998_988, 999_000, 12);

        (uint256 price, uint256 effectiveTimestamp) = adapter.latestPrice();

        assertEq(price, 105_000_000);
        assertEq(effectiveTimestamp, 998_988);
        assertEq(adapter.decimals(), 8);
        assertEq(address(adapter.feed()), address(feed));
    }

    function test_nonPositiveAnswerReturnsZeroPrice() external {
        feed.setRound(12, -1, 998_988, 999_000, 12);

        (uint256 price, uint256 effectiveTimestamp) = adapter.latestPrice();

        assertEq(price, 0);
        assertEq(effectiveTimestamp, 998_988);
    }

    function test_incompleteRoundReturnsZeroPrice() external {
        feed.setRound(12, 105_000_000, 998_988, 999_000, 11);

        (uint256 price, uint256 effectiveTimestamp) = adapter.latestPrice();

        assertEq(price, 0);
        assertEq(effectiveTimestamp, 998_988);
    }

    function test_zeroStartedAtReverts() external {
        feed.setRound(12, 105_000_000, 0, 999_000, 12);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracleAdapter.InvalidFeedTimestamps.selector, 0, 999_000));
        adapter.latestPrice();
    }

    function test_zeroUpdatedAtReverts() external {
        feed.setRound(12, 105_000_000, 998_988, 0, 12);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracleAdapter.InvalidFeedTimestamps.selector, 998_988, 0));
        adapter.latestPrice();
    }

    function test_startedAtAfterUpdatedAtReverts() external {
        feed.setRound(12, 105_000_000, 999_001, 999_000, 12);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceOracleAdapter.InvalidFeedTimestamps.selector, uint256(999_001), uint256(999_000)
            )
        );
        adapter.latestPrice();
    }

    function test_poolRejectsDelayedObservationRecordedRecently() external {
        DirectPropAMM pool = _deployPausedPool();
        uint256 staleObservation = block.timestamp - 1 days - 1;
        feed.setRound(13, 105_000_000, staleObservation, block.timestamp, 13);

        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.StaleOraclePrice.selector, staleObservation, uint256(1 days))
        );
        pool.unpause();
    }

    function test_poolQuoteBindsToObservationTimestamp() external {
        DirectPropAMM pool = _deployPausedPool();
        pool.unpause();
        uint256 observationTimestamp = block.timestamp - 12;
        feed.setRound(13, 105_000_000, observationTimestamp, block.timestamp, 13);

        (,, uint256 effectiveTimestamp) = pool.quoteExactInput(true, 1e6);

        assertEq(effectiveTimestamp, observationTimestamp);
    }

    function test_feedDecimalChangeReverts() external {
        feed.setRound(12, 105_000_000, 999_000, 999_000, 12);
        feed.setDecimals(18);

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracleAdapter.FeedDecimalsChanged.selector, uint8(8), uint8(18))
        );
        adapter.latestPrice();
    }

    function test_feedDecimalChangeRevertsBeforeFirstUnpause() external {
        DirectPropAMM pool = _deployPausedPool();
        feed.setDecimals(18);

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracleAdapter.FeedDecimalsChanged.selector, uint8(8), uint8(18))
        );
        pool.unpause();
    }

    function test_feedDecimalChangeRevertsActivePoolQuote() external {
        DirectPropAMM pool = _deployPausedPool();
        pool.unpause();
        feed.setDecimals(18);

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracleAdapter.FeedDecimalsChanged.selector, uint8(8), uint8(18))
        );
        pool.quoteExactInput(true, 1e6);
    }

    function test_zeroFeedReverts() external {
        vm.expectRevert(ChainlinkPriceOracleAdapter.InvalidFeed.selector);
        new ChainlinkPriceOracleAdapter(IAggregatorV3(address(0)));
    }

    function _deployPausedPool() internal returns (DirectPropAMM pool) {
        vm.warp(1_000_000);
        feed.setRound(12, 105_000_000, block.timestamp, block.timestamp, 12);

        MockAddressRegistry registry = new MockAddressRegistry();
        MockTIP20 base = new MockTIP20("BASE", 6);
        MockTIP20 quote = new MockTIP20("QUOTE", 6);
        address guardian = address(0xBEEF);
        pool = new DirectPropAMM(base, quote, adapter, registry, address(this), guardian, 1 days, 50);
    }
}
