// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { Settler } from "../../src/managed/Settler.sol";

/// @notice Deploy the immutable factory, implementation and settler. No pools, trading permissions or inventory.
/// @dev Simulation by default. BROADCAST=true plus Forge --broadcast is required to send. Never reads a private key.
/// Every run checks the deployed wiring (factory, implementation and settler point at each other; the implementation
/// has no owner).
contract DeployManagedCore is Script {
    uint256 internal constant TEMPO_MAINNET_CHAIN_ID = 4217;
    uint256 internal constant TEMPO_MODERATO_CHAIN_ID = 42431;

    function run() external returns (PoolFactory factory) {
        return deploy(vm.envAddress("DEPLOYER_ADDRESS"), vm.envOr("BROADCAST", false));
    }

    /// @dev `run`'s body with its inputs passed in, so tests need no process-global environment.
    function deploy(address deployer, bool broadcast) public returns (PoolFactory factory) {
        require(
            block.chainid == TEMPO_MAINNET_CHAIN_ID || block.chainid == TEMPO_MODERATO_CHAIN_ID, "Unsupported chain"
        );
        require(deployer != address(0), "Missing deployer");
        if (broadcast) vm.startBroadcast(deployer);
        else vm.startPrank(deployer);
        factory = new PoolFactory();
        if (broadcast) vm.stopBroadcast();
        else vm.stopPrank();
        _checkWiring(factory);
        console2.log("Managed factory", address(factory));
        console2.log("Managed implementation", factory.implementation());
        console2.log("Managed settler", factory.defaultSettler());
    }

    function _checkWiring(PoolFactory factory) internal view {
        ManagedDirectPropAMM implementation = ManagedDirectPropAMM(factory.implementation());
        Settler settler = Settler(factory.defaultSettler());
        require(implementation.factory() == address(factory), "Implementation factory mismatch");
        require(implementation.owner() == address(0), "Implementation has an owner");
        require(settler.factory() == address(factory), "Settler factory mismatch");
        require(settler.implementation() == address(implementation), "Settler implementation mismatch");
    }
}
