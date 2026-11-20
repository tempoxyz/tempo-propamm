// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script, console2 } from "forge-std/Script.sol";

import { Chainlink18To8PriceOracleAdapter } from "../../src/Chainlink18To8PriceOracleAdapter.sol";
import { ChainlinkPriceOracleAdapter } from "../../src/ChainlinkPriceOracleAdapter.sol";
import { OndoUSDYPriceOracleAdapter } from "../../src/OndoUSDYPriceOracleAdapter.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IOndoUSDYOracleWrapper } from "../../src/interfaces/IOndoUSDYOracle.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";

/// @notice Deploys the price adapters a `ManagedDirectPropAMM`'s pairs read, one per entry. Each is immutable and
/// ownerless. Logs every adapter's price for review, and the `PAIR_ORACLES` line `DeployManagedPool` takes.
/// @dev Inputs, comma-separated with one entry per adapter: `ORACLE_KINDS` (`CHAINLINK`: the feed's own decimals;
/// `CHAINLINK_18_TO_8`: an 18-decimal feed read at 8 decimals; `ONDO_USDY`: Ondo's USDY oracle wrapper) and
/// `ORACLE_SOURCES` (the AggregatorV3 feed, or the wrapper). Forge sends only with `--broadcast`.
contract DeployManagedOracleAdapters is Script {
    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);

    function run() external returns (address[] memory) {
        return deploy(vm.envString("ORACLE_KINDS", ","), vm.envAddress("ORACLE_SOURCES", ","));
    }

    /// @dev `run`'s body with its inputs passed in, so tests need no process-global environment.
    function deploy(string[] memory kinds, address[] memory sources) public returns (address[] memory adapters) {
        if (block.chainid != 4217 && block.chainid != 42431) revert UnexpectedChain(block.chainid);
        uint256 count = kinds.length;
        if (count == 0 || sources.length != count) revert InvalidConfig("ORACLE_KINDS and ORACLE_SOURCES");

        adapters = new address[](count);
        vm.startBroadcast();
        for (uint256 i; i < count; ++i) {
            adapters[i] = address(_deploy(kinds[i], sources[i]));
        }
        vm.stopBroadcast();

        string memory list;
        for (uint256 i; i < count; ++i) {
            IPriceOracle adapter = IPriceOracle(adapters[i]);
            (uint256 price, uint256 observedAt) = adapter.latestPrice();
            console2.log(kinds[i], adapters[i]);
            console2.log("  decimals / price / observed at", adapter.decimals(), price, observedAt);
            list = string.concat(list, i == 0 ? "" : ",", Strings.toChecksumHexString(adapters[i]));
        }
        console2.log(string.concat("PAIR_ORACLES=", list));
    }

    function _deploy(string memory kind, address source) internal returns (IPriceOracle) {
        bytes32 hash = keccak256(bytes(kind));
        if (hash == keccak256("CHAINLINK")) return new ChainlinkPriceOracleAdapter(IAggregatorV3(source));
        if (hash == keccak256("CHAINLINK_18_TO_8")) return new Chainlink18To8PriceOracleAdapter(IAggregatorV3(source));
        if (hash == keccak256("ONDO_USDY")) return new OndoUSDYPriceOracleAdapter(IOndoUSDYOracleWrapper(source));
        revert InvalidConfig("ORACLE_KINDS");
    }
}
