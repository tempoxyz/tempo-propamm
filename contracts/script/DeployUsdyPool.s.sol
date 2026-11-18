// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { OndoUSDYPriceOracleAdapter } from "../src/OndoUSDYPriceOracleAdapter.sol";
import { TempoMainnet } from "../src/TempoMainnet.sol";
import { IAddressRegistry } from "../src/interfaces/IAddressRegistry.sol";
import { IOndoUSDYOracleWrapper } from "../src/interfaces/IOndoUSDYOracle.sol";
import { ITIP20 } from "../src/interfaces/ITIP20.sol";

contract DeployUsdyPool is Script {
    error InvalidMaxOracleAge(uint256 maxOracleAge);
    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);

    struct Config {
        address usdy;
        address wrapper;
        address owner;
        address guardian;
        uint256 maxOracleAge;
        uint256 maxPriceDeviationBps;
    }

    function run() external returns (OndoUSDYPriceOracleAdapter adapter, DirectPropAMM pool) {
        if (block.chainid != TempoMainnet.CHAIN_ID) revert UnexpectedChain(block.chainid);

        Config memory config = _readConfig();
        if (config.maxOracleAge < 1 days) revert InvalidMaxOracleAge(config.maxOracleAge);
        if (config.owner == address(0)) revert InvalidConfig("OWNER_ADDRESS");
        if (config.guardian == address(0)) revert InvalidConfig("GUARDIAN_ADDRESS");
        IAddressRegistry registry = IAddressRegistry(TempoMainnet.ADDRESS_REGISTRY);
        // Administrative callers must be actual accounts, not TIP-1022 virtual payment aliases.
        if (registry.resolveRecipient(config.owner) != config.owner) revert InvalidConfig("OWNER_ADDRESS");
        if (registry.resolveRecipient(config.guardian) != config.guardian) revert InvalidConfig("GUARDIAN_ADDRESS");

        vm.startBroadcast();
        adapter = new OndoUSDYPriceOracleAdapter(IOndoUSDYOracleWrapper(config.wrapper));
        pool = new DirectPropAMM(
            ITIP20(config.usdy),
            ITIP20(TempoMainnet.PATH_USD),
            adapter,
            IAddressRegistry(TempoMainnet.ADDRESS_REGISTRY),
            config.owner,
            config.guardian,
            config.maxOracleAge,
            config.maxPriceDeviationBps
        );
        vm.stopBroadcast();

        console2.log("Ondo USDY oracle adapter", address(adapter));
        console2.log("USDY/pathUSD DirectPropAMM", address(pool));
        console2.log("USDY oracle wrapper", address(adapter.wrapper()));
        console2.log("Pool starts paused", pool.paused());
        console2.log("Max price deviation bps", pool.maxPriceDeviationBps());
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory) {
        return Config({
            usdy: vm.envAddress("USDY_ADDRESS"),
            wrapper: vm.envAddress("USDY_ORACLE_WRAPPER_ADDRESS"),
            owner: vm.envAddress("OWNER_ADDRESS"),
            guardian: vm.envAddress("GUARDIAN_ADDRESS"),
            maxOracleAge: _optionalUint("MAX_ORACLE_AGE", 90_000),
            maxPriceDeviationBps: _optionalUint("MAX_PRICE_DEVIATION_BPS", 50)
        });
    }

    function _optionalUint(string memory field, uint256 defaultValue) internal view returns (uint256) {
        // Only an absent input gets a default; an empty or malformed supplied value must abort deployment.
        return vm.envExists(field) ? vm.envUint(field) : defaultValue;
    }
}
