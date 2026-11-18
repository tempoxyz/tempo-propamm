// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { OndoUSDYPriceOracleAdapter } from "../../src/OndoUSDYPriceOracleAdapter.sol";
import { IOndoUSDYOracleWrapper } from "../../src/interfaces/IOndoUSDYOracle.sol";

/// @notice Compatibility checks against Ondo's official Ethereum USDY wrapper.
/// @dev Tempo is checked by `OndoTempoOracleFork.t.sol` because Ondo may publish different contracts there.
contract OndoEthereumOracleForkTest is Test {
    address internal constant USDY_ORACLE_WRAPPER = 0x87b126e5518b6a1Bb8465779b4607C45C643DF90;

    IOndoUSDYOracleWrapper internal wrapper;
    OndoUSDYPriceOracleAdapter internal adapter;

    function setUp() external {
        vm.createSelectFork(vm.envOr("ETHEREUM_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        wrapper = IOndoUSDYOracleWrapper(USDY_ORACLE_WRAPPER);
        adapter = new OndoUSDYPriceOracleAdapter(wrapper);
    }

    function test_liveWrapperMatchesAdapter() external view {
        (uint256 wrapperPrice,) = wrapper.getPriceData();
        (uint256 adapterPrice, uint256 adapterUpdatedAt) = adapter.latestPrice();

        assertEq(address(adapter.wrapper()), USDY_ORACLE_WRAPPER);
        assertEq(adapterPrice, wrapperPrice);
        assertEq(adapterUpdatedAt, block.timestamp);
    }

    function test_livePriceDoesNotFallOverADay() external {
        (uint256 firstPrice,) = adapter.latestPrice();
        vm.warp(block.timestamp + 1 days);

        (uint256 wrapperPrice,) = wrapper.getPriceData();
        (uint256 nextPrice,) = adapter.latestPrice();

        assertEq(nextPrice, wrapperPrice);
        assertGe(nextPrice, firstPrice);
    }
}
