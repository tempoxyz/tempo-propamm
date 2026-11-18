// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Chainlink18To8PriceOracleAdapter } from "../../src/Chainlink18To8PriceOracleAdapter.sol";
import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Mechanical compatibility only; does not certify the feed's economic denomination.
contract Chainlink18To8PriceOracleForkTest is Test {
    function test_liveFeedAndExistingPoolMigration() external {
        string memory rpc = vm.envOr("TEMPO_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        IAggregatorV3 feed = IAggregatorV3(0x0ae20Ebc56e1944eBaa7E40E65C8b7A61d6fF490);
        Chainlink18To8PriceOracleAdapter adapter = new Chainlink18To8PriceOracleAdapter(feed);
        (, int256 answer, uint256 startedAt,,) = feed.latestRoundData();
        assertGt(answer, 0);
        (uint256 price, uint256 timestamp) = adapter.latestPrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(price, uint256(answer) / 1e10);
        assertEq(timestamp, startedAt);
        DirectPropAMM pool = DirectPropAMM(0x2C22026217d2275F1883FEbF161863dC0b0A43B2);
        assertEq(pool.oracleDecimals(), 8);
        vm.startPrank(pool.owner());
        if (!pool.paused()) pool.pause();
        pool.setOracle(adapter);
        pool.unpause();
        vm.stopPrank();
        assertEq(address(pool.oracle()), address(adapter));
        (uint256 quoteOut, uint256 bidPrice, uint256 bidTime) = pool.quoteExactInput(true, 1e6);
        (uint256 baseOut, uint256 askPrice, uint256 askTime) = pool.quoteExactInput(false, 1e6);
        assertGt(quoteOut, 0);
        assertGt(baseOut, 0);
        assertEq(bidPrice, price);
        assertEq(askPrice, price);
        assertEq(bidTime, startedAt);
        assertEq(askTime, startedAt);
    }
}
