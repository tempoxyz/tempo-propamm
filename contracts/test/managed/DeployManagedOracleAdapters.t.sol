// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DeployManagedOracleAdapters } from "../../script/managed/DeployManagedOracleAdapters.s.sol";
import { Chainlink18To8PriceOracleAdapter } from "../../src/Chainlink18To8PriceOracleAdapter.sol";
import { ChainlinkPriceOracleAdapter } from "../../src/ChainlinkPriceOracleAdapter.sol";
import { OndoUSDYPriceOracleAdapter } from "../../src/OndoUSDYPriceOracleAdapter.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";
import { MockAggregatorV3 } from "../ChainlinkPriceOracleAdapter.t.sol";
import { MockOndoUSDYOracleWrapper } from "../OndoUSDYPriceOracleAdapter.t.sol";

contract DeployManagedOracleAdaptersTest is Test {
    int256 internal constant PRIME_18 = 1_052_345_678_912_345_678;

    DeployManagedOracleAdapters internal script;
    MockAggregatorV3 internal feed;
    MockOndoUSDYOracleWrapper internal wrapper;

    function setUp() external {
        vm.warp(1_000_000);
        vm.chainId(42431);
        script = new DeployManagedOracleAdapters();
        feed = new MockAggregatorV3(18);
        feed.setRound(1, PRIME_18, block.timestamp - 600, block.timestamp - 600, 1);
        wrapper = new MockOndoUSDYOracleWrapper(1.137e18);
    }

    function test_deploysOneAdapterOfEachKind() external {
        address[] memory adapters = script.deploy(_kinds(), _sources());

        assertEq(adapters.length, 3);
        assertEq(address(ChainlinkPriceOracleAdapter(adapters[0]).feed()), address(feed));
        assertEq(address(Chainlink18To8PriceOracleAdapter(adapters[1]).feed()), address(feed));
        assertEq(address(OndoUSDYPriceOracleAdapter(adapters[2]).wrapper()), address(wrapper));
        _assertPrice(adapters[0], 18, uint256(PRIME_18), block.timestamp - 600);
        _assertPrice(adapters[1], 8, 105_234_567, block.timestamp - 600);
        _assertPrice(adapters[2], 18, 1.137e18, block.timestamp);
    }

    function test_runReadsTheEnvironment() external {
        vm.setEnv("ORACLE_KINDS", "CHAINLINK_18_TO_8,ONDO_USDY");
        vm.setEnv("ORACLE_SOURCES", string.concat(vm.toString(address(feed)), ",", vm.toString(address(wrapper))));

        address[] memory adapters = script.run();

        assertEq(adapters.length, 2);
        _assertPrice(adapters[0], 8, 105_234_567, block.timestamp - 600);
        _assertPrice(adapters[1], 18, 1.137e18, block.timestamp);
    }

    function test_rejectsOtherChain() external {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployManagedOracleAdapters.UnexpectedChain.selector, 1));
        script.deploy(_kinds(), _sources());
    }

    function test_rejectsListsOfDifferentLengths() external {
        bytes memory err = abi.encodeWithSelector(
            DeployManagedOracleAdapters.InvalidConfig.selector, "ORACLE_KINDS and ORACLE_SOURCES"
        );
        vm.expectRevert(err);
        script.deploy(_kinds(), new address[](2));
        vm.expectRevert(err);
        script.deploy(new string[](0), new address[](0));
    }

    function test_rejectsUnknownKind() external {
        string[] memory kinds = _kinds();
        kinds[1] = "PUSH";
        vm.expectRevert(abi.encodeWithSelector(DeployManagedOracleAdapters.InvalidConfig.selector, "ORACLE_KINDS"));
        script.deploy(kinds, _sources());
    }

    function _kinds() internal pure returns (string[] memory kinds) {
        kinds = new string[](3);
        (kinds[0], kinds[1], kinds[2]) = ("CHAINLINK", "CHAINLINK_18_TO_8", "ONDO_USDY");
    }

    function _sources() internal view returns (address[] memory sources) {
        sources = new address[](3);
        (sources[0], sources[1], sources[2]) = (address(feed), address(feed), address(wrapper));
    }

    function _assertPrice(address adapter, uint8 decimals, uint256 price, uint256 observedAt) internal view {
        assertEq(IPriceOracle(adapter).decimals(), decimals);
        (uint256 actualPrice, uint256 actualObservedAt) = IPriceOracle(adapter).latestPrice();
        assertEq(actualPrice, price);
        assertEq(actualObservedAt, observedAt);
    }
}
