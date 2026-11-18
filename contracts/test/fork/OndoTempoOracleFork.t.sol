// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { OndoUSDYPriceOracleAdapter } from "../../src/OndoUSDYPriceOracleAdapter.sol";
import { TempoMainnet } from "../../src/TempoMainnet.sol";
import { IOndoUSDYOracleWrapper } from "../../src/interfaces/IOndoUSDYOracle.sol";

/// @notice Checks the adapter against Ondo's USDY wrapper on Tempo mainnet, through its October 2026 oracle migration.
/// @dev At `MIGRATION_BLOCK` the wrapper's `rwaOracle()` is a migration oracle that serves the old
///      `RWADynamicOracle` until `CUTOVER` and a rate-accruing oracle after it; it has no `ranges(i)`, which the
///      earlier range-walking adapter required. Needs an archive Tempo RPC in `TEMPO_RPC_URL`; skipped without one.
contract OndoTempoOracleForkTest is Test {
    uint256 internal constant MIGRATION_BLOCK = 46_607_363;
    uint256 internal constant CUTOVER = 1_793_491_200; // 2026-11-01 00:00 UTC

    IOndoUSDYOracleWrapper internal wrapper = IOndoUSDYOracleWrapper(TempoMainnet.USDY_ORACLE_WRAPPER);

    function test_pricesThroughOndoMigration() external {
        string memory rpc = vm.envOr("TEMPO_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, MIGRATION_BLOCK);
        OndoUSDYPriceOracleAdapter adapter = new OndoUSDYPriceOracleAdapter(wrapper);

        uint256 previous;
        uint256[4] memory times = [vm.getBlockTimestamp(), CUTOVER - 1, CUTOVER + 1 minutes, CUTOVER + 1 days];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            (uint256 wrapperPrice,) = wrapper.getPriceData();
            (uint256 price, uint256 updatedAt) = adapter.latestPrice();
            assertEq(price, wrapperPrice);
            assertEq(updatedAt, times[i]);
            assertGe(price, previous);
            // USDY sits near 1.15 USD; a decimals or source mistake would be orders of magnitude off.
            assertGt(price, 1.1e18);
            assertLt(price, 1.2e18);
            previous = price;
        }
    }
}
