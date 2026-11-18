// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Chainlink18To8PriceOracleAdapter } from "../src/Chainlink18To8PriceOracleAdapter.sol";
import { ChainlinkPriceOracleAdapter } from "../src/ChainlinkPriceOracleAdapter.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { MockAggregatorV3 } from "./ChainlinkPriceOracleAdapter.t.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

contract Chainlink18To8PriceOracleAdapterTest is Test {
    uint256 internal constant PRICE = 105_000_000;
    uint256 internal constant OBSERVED = 999_988;
    uint256 internal constant RECORDED = 1_000_000;
    int256 internal constant ANSWER = 1_050_000_000_000_000_000;

    MockAggregatorV3 internal feed;
    Chainlink18To8PriceOracleAdapter internal adapter;
    MockTIP20 internal base;
    MockTIP20 internal quote;

    function setUp() external {
        vm.warp(RECORDED);
        feed = new MockAggregatorV3(18);
        feed.setRound(12, ANSWER, OBSERVED, RECORDED, 12);
        adapter = new Chainlink18To8PriceOracleAdapter(feed);
    }

    function test_normalizesAndReturnsObservationTime() external view {
        _assertPrice(PRICE, OBSERVED);
        assertEq(adapter.decimals(), 8);
        assertEq(address(adapter.feed()), address(feed));
    }

    function test_zeroFeedReverts() external {
        vm.expectRevert(Chainlink18To8PriceOracleAdapter.InvalidFeed.selector);
        new Chainlink18To8PriceOracleAdapter(IAggregatorV3(address(0)));
    }

    function testFuzz_constructorRejectsOtherDecimals(uint8 decimals) external {
        vm.assume(decimals != 18);
        feed.setDecimals(decimals);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink18To8PriceOracleAdapter.FeedDecimalsChanged.selector, uint8(18), decimals)
        );
        new Chainlink18To8PriceOracleAdapter(feed);
    }

    function testFuzz_positiveAnswerRoundsDown(uint256 raw) external {
        raw = bound(raw, 1, uint256(type(int256).max));
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.setRound(12, int256(raw), OBSERVED, RECORDED, 12);
        (uint256 price, uint256 timestamp) = adapter.latestPrice();
        assertEq(price, raw / 1e10);
        assertLe(price * 1e10, raw);
        assertLt(raw - price * 1e10, 1e10);
        assertEq(timestamp, OBSERVED);
    }

    function test_maxIntAnswerDoesNotOverflow() external {
        feed.setRound(12, type(int256).max, OBSERVED, RECORDED, 12);
        _assertPrice(uint256(type(int256).max) / 1e10, OBSERVED);
    }

    function test_precisionBoundary() external {
        feed.setRound(12, 1e10 - 1, OBSERVED, RECORDED, 12);
        _assertPrice(0, OBSERVED);
        feed.setRound(12, 1e10, OBSERVED, RECORDED, 12);
        _assertPrice(1, OBSERVED);
        feed.setRound(12, 2e10 - 1, OBSERVED, RECORDED, 12);
        _assertPrice(1, OBSERVED);
    }

    function test_nonPositiveAnswersReturnZero() external {
        feed.setRound(12, 0, OBSERVED, RECORDED, 12);
        _assertPrice(0, OBSERVED);
        feed.setRound(12, -1, OBSERVED, RECORDED, 12);
        _assertPrice(0, OBSERVED);
        feed.setRound(12, type(int256).min, OBSERVED, RECORDED, 12);
        _assertPrice(0, OBSERVED);
    }

    function test_incompleteRoundReturnsZero() external {
        feed.setRound(12, ANSWER, OBSERVED, RECORDED, 11);
        _assertPrice(0, OBSERVED);
    }

    function test_laterAnsweredRoundAccepted() external {
        feed.setRound(12, ANSWER, OBSERVED, RECORDED, 13);
        _assertPrice(PRICE, OBSERVED);
    }

    function test_zeroRoundIdMatchesExistingAdapter() external {
        feed.setRound(0, ANSWER, OBSERVED, RECORDED, 0);
        _assertPrice(PRICE, OBSERVED);
    }

    function test_zeroStartedAtReverts() external {
        _assertInvalidTimestamps(0, RECORDED);
    }

    function test_zeroUpdatedAtReverts() external {
        _assertInvalidTimestamps(OBSERVED, 0);
    }

    function test_bothZeroTimestampsRevert() external {
        _assertInvalidTimestamps(0, 0);
    }

    function test_startedAfterUpdatedReverts() external {
        _assertInvalidTimestamps(RECORDED + 1, RECORDED);
    }

    function test_equalTimestampsAccepted() external {
        feed.setRound(12, ANSWER, OBSERVED, OBSERVED, 12);
        _assertPrice(PRICE, OBSERVED);
    }

    function test_invalidTimestampsPrecedeInvalidAnswerAndRound() external {
        feed.setRound(12, -1, 0, RECORDED, 11);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink18To8PriceOracleAdapter.InvalidFeedTimestamps.selector, 0, RECORDED)
        );
        adapter.latestPrice();
    }

    function testFuzz_decimalDriftReverts(uint8 decimals) external {
        vm.assume(decimals != 18);
        feed.setDecimals(decimals);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink18To8PriceOracleAdapter.FeedDecimalsChanged.selector, uint8(18), decimals)
        );
        adapter.latestPrice();
        assertEq(adapter.decimals(), 8);
    }

    function test_sourceRoundRevertPropagates() external {
        bytes memory reason = abi.encodeWithSignature("SourceUnavailable()");
        vm.mockCallRevert(address(feed), abi.encodeCall(IAggregatorV3.latestRoundData, ()), reason);
        vm.expectRevert(reason);
        adapter.latestPrice();
    }

    function test_sourceDecimalsRevertPropagates() external {
        bytes memory reason = abi.encodeWithSignature("SourceUnavailable()");
        vm.mockCallRevert(address(feed), abi.encodeCall(IAggregatorV3.decimals, ()), reason);
        vm.expectRevert(reason);
        adapter.latestPrice();
        vm.expectRevert(reason);
        new Chainlink18To8PriceOracleAdapter(feed);
    }

    function test_migratesExistingEightDecimalPoolAndSwapsBothDirections() external {
        DirectPropAMM pool = _existingPool();
        (uint256 beforeOut, uint256 beforePrice, uint256 beforeTime) = pool.quoteExactInput(true, 10e6);
        vm.expectRevert(DirectPropAMM.NotPaused.selector);
        pool.setOracle(adapter);
        pool.pause();
        // An ordinary adapter exposes 18 decimals and cannot replace the pool's immutable 8-decimal scale.
        ChainlinkPriceOracleAdapter unscaled = new ChainlinkPriceOracleAdapter(feed);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.OracleDecimalsChanged.selector, uint8(8), uint8(18)));
        pool.setOracle(unscaled);
        pool.setOracle(adapter);
        pool.unpause();
        assertEq(address(pool.oracle()), address(adapter));
        assertEq(pool.oracleDecimals(), 8);
        assertEq(pool.priceScale(), 1e8);
        (uint256 afterOut, uint256 afterPrice, uint256 afterTime) = pool.quoteExactInput(true, 10e6);
        assertEq(afterOut, beforeOut);
        assertEq(afterPrice, beforePrice);
        assertEq(afterTime, beforeTime);
        assertEq(_swap(pool, true, 10e6, 10_500_000), 10_500_000);
        assertEq(base.balanceOf(address(pool)), 1_010e6);
        assertEq(quote.balanceOf(address(pool)), 989_500_000);
        assertEq(base.balanceOf(address(this)), 90e6);
        assertEq(quote.balanceOf(address(this)), 110_500_000);
        assertEq(_swap(pool, false, 10_500_000, 10e6), 10e6);
        assertEq(base.balanceOf(address(pool)), 1_000e6);
        assertEq(quote.balanceOf(address(pool)), 1_000e6);
        assertEq(base.balanceOf(address(this)), 100e6);
        assertEq(quote.balanceOf(address(this)), 100e6);
    }

    function test_migratedPoolRejectsStaleObservationRecordedRecently() external {
        DirectPropAMM pool = _migratedPool();
        uint256 stale = RECORDED - 1 days - 1;
        feed.setRound(13, ANSWER, stale, RECORDED, 13);
        bytes memory reason = abi.encodeWithSelector(DirectPropAMM.StaleOraclePrice.selector, stale, uint256(1 days));
        vm.expectRevert(reason);
        pool.quoteExactInput(true, 1e6);
        vm.expectRevert(reason);
        _swap(pool, false, 1_050_000, 1e6);
        pool.pause();
        vm.expectRevert(reason);
        pool.unpause();
    }

    function test_migratedPoolRejectsFutureObservation() external {
        DirectPropAMM pool = _migratedPool();
        feed.setRound(13, ANSWER, RECORDED + 1, RECORDED + 1, 13);
        bytes memory reason =
            abi.encodeWithSelector(DirectPropAMM.FutureOracleTimestamp.selector, RECORDED + 1, RECORDED);
        vm.expectRevert(reason);
        pool.quoteExactInput(false, 1e6);
        vm.expectRevert(reason);
        _swap(pool, true, 1e6, 1_050_000);
        pool.pause();
        vm.expectRevert(reason);
        pool.unpause();
    }

    function test_migratedPoolRejectsSubprecisionPrice() external {
        DirectPropAMM pool = _migratedPool();
        feed.setRound(13, 1e10 - 1, OBSERVED, RECORDED, 13);
        vm.expectRevert(DirectPropAMM.InvalidPrice.selector);
        pool.quoteExactInput(true, 1e6);
    }

    function test_migratedPoolRejectsDecimalDrift() external {
        DirectPropAMM pool = _migratedPool();
        feed.setDecimals(8);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink18To8PriceOracleAdapter.FeedDecimalsChanged.selector, uint8(18), uint8(8))
        );
        pool.quoteExactInput(true, 1e6);
    }

    function _assertPrice(uint256 expectedPrice, uint256 expectedTimestamp) internal view {
        (uint256 price, uint256 timestamp) = adapter.latestPrice();
        assertEq(price, expectedPrice);
        assertEq(timestamp, expectedTimestamp);
    }

    function _assertInvalidTimestamps(uint256 startedAt, uint256 updatedAt) internal {
        feed.setRound(12, ANSWER, startedAt, updatedAt, 12);
        vm.expectRevert(
            abi.encodeWithSelector(
                Chainlink18To8PriceOracleAdapter.InvalidFeedTimestamps.selector, startedAt, updatedAt
            )
        );
        adapter.latestPrice();
    }

    function _existingPool() internal returns (DirectPropAMM pool) {
        MockAggregatorV3 oldFeed = new MockAggregatorV3(8);
        oldFeed.setRound(12, 105_000_000, OBSERVED, RECORDED, 12);
        ChainlinkPriceOracleAdapter oldAdapter = new ChainlinkPriceOracleAdapter(oldFeed);
        base = new MockTIP20("BASE", 6);
        quote = new MockTIP20("QUOTE", 6);
        pool = new DirectPropAMM(
            base, quote, oldAdapter, new MockAddressRegistry(), address(this), address(0xBEEF), 1 days, 50
        );
        pool.setTakerAllowed(address(this), true);
        pool.setRecipientAllowed(address(this), true);
        base.mint(address(pool), 1_000e6);
        quote.mint(address(pool), 1_000e6);
        base.mint(address(this), 100e6);
        quote.mint(address(this), 100e6);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        pool.unpause();
    }

    function _migratedPool() internal returns (DirectPropAMM pool) {
        pool = _existingPool();
        pool.pause();
        pool.setOracle(adapter);
        pool.unpause();
    }

    function _swap(DirectPropAMM pool, bool baseToQuote, uint256 amountIn, uint256 minimumOut)
        internal
        returns (uint256)
    {
        return pool.swapExactInput(
            baseToQuote,
            amountIn,
            minimumOut,
            address(this),
            bytes32("customer"),
            bytes32("trade"),
            RECORDED,
            PRICE,
            0,
            OBSERVED
        );
    }
}
