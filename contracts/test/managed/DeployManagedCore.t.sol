// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { DeployManagedCore } from "../../script/managed/DeployManagedCore.s.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { Settler } from "../../src/managed/Settler.sol";

contract DeployManagedCoreTest is Test {
    address internal constant DEPLOYER = 0x1111111111111111111111111111111111111111;

    function test_simulateCore() external {
        vm.chainId(42431);
        vm.setEnv("DEPLOYER_ADDRESS", "0x1111111111111111111111111111111111111111");
        vm.setEnv("BROADCAST", "false");
        PoolFactory factory = (new DeployManagedCore()).run();
        assertGt(factory.implementation().code.length, 0);
        assertEq(Settler(factory.defaultSettler()).factory(), address(factory));
        assertFalse(factory.isPool(factory.implementation()));
    }

    function test_rejectOtherChain() external {
        vm.chainId(1);
        DeployManagedCore script = new DeployManagedCore();
        vm.expectRevert("Unsupported chain");
        script.deploy(DEPLOYER, false, false);
    }

    /// @dev Pre-audit contracts: a mainnet broadcast needs the explicit acknowledgement; a mainnet simulation doesn't.
    function test_mainnetBroadcastNeedsPreAuditAck() external {
        vm.chainId(4217);
        DeployManagedCore script = new DeployManagedCore();
        vm.expectRevert("Mainnet broadcast needs MANAGED_MAINNET_PRE_AUDIT_ACK=true");
        script.deploy(DEPLOYER, true, false);
        PoolFactory factory = script.deploy(DEPLOYER, false, false);
        assertEq(Settler(factory.defaultSettler()).implementation(), factory.implementation());
    }

    function test_moderatoBroadcastNeedsNoAck() external {
        vm.chainId(42431);
        PoolFactory factory = (new DeployManagedCore()).deploy(DEPLOYER, true, false);
        assertEq(Settler(factory.defaultSettler()).factory(), address(factory));
    }
}
