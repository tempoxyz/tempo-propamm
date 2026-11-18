// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "../../managed/utils/TestFeeHook.sol";
using TestFeeHookLib for ManagedDirectPropAMM;
import { Test, Vm } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { PoolFactory } from "../../../src/managed/PoolFactory.sol";
import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { Settler } from "../../../src/managed/Settler.sol";
import { IManagedDirectPropAMM as IM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";
import { TestRouter } from "../../managed/utils/TestRouter.sol";

interface IManagedFrameGas {
    function lastFrameGas() external view returns (Vm.Gas memory gas);
}

contract ManagedRoutingGasTest is Test {
    function test_coreAndCloneDeployUnderTempoCap() public {
        if (!_tempo()) return;
        PoolFactory factory = new PoolFactory();
        uint256 coreGas = _gas();
        console.log("Managed core deployment", coreGas);
        _check(coreGas, 17_243_216);
        // Conservative 1.21M estimation gap plus Forge's 130% gas multiplier, as in the existing pool suite.
        assertLe((coreGas + 1_208_812) * 130 / 100, 30_000_000);
        factory.createPool(address(this), bytes32("test"));
        uint256 cloneGas = _gas();
        console.log("Managed clone deployment", cloneGas);
        _check(cloneGas, 1_119_106);
        assertLe(cloneGas * 130 / 100, 30_000_000);
    }

    function test_routedAndSettledSwapGas() public {
        if (!_tempo()) return;
        vm.warp(1_000_000);
        MockTIP20 base = new MockTIP20("BASE", 6);
        MockTIP20 quote = new MockTIP20("QUOTE", 6);
        MockOracle oracle = new MockOracle(8, 105_000_000, block.timestamp);
        PoolFactory factory = new PoolFactory();
        Settler settler = Settler(factory.defaultSettler());
        ManagedDirectPropAMM pool = ManagedDirectPropAMM(factory.createPool(address(this), "test"));
        pool.addPair(address(base), address(quote), oracle, 90000, 50);
        address taker = address(0x1235);
        pool.configureFees(0, taker, 100, 200);
        address[] memory users = new address[](1);
        users[0] = taker;
        pool.setMembers(0, 0, users, true);
        TestRouter router = new TestRouter(settler);
        users[0] = address(router);
        pool.setMembers(0, 0, users, true);
        pool.configureFees(0, address(router), 100, 200);
        pool.setPairAccess(0, IM.AccessMode.Listed);
        pool.unpause();
        base.mint(taker, 1000e6);
        quote.mint(address(pool), 1000e6);
        vm.startPrank(taker);
        base.approve(address(settler), type(uint256).max);
        base.approve(address(router), type(uint256).max);
        IM.SwapParams memory s = IM.SwapParams(
            0, true, true, 10e6, 0, 0, "customer", "trade", block.timestamp, 105_000_000, 0, block.timestamp
        );
        for (uint256 i; i < 2; ++i) {
            settler.swap(address(pool), s);
        }
        uint256 settledGas = _gas();
        console.log("Managed settler exact input", settledGas);
        _check(settledGas, 126_295);
        for (uint256 i; i < 2; ++i) {
            router.swap(address(pool), s);
        }
        uint256 routedGas = _gas();
        console.log("Managed router exact input including user transfers", routedGas);
        _check(routedGas, 154_737);
        vm.stopPrank();
    }

    /// @dev Match the pool gas suite's 2% bidirectional baseline guard; cheaper paths must be re-recorded too.
    function _check(uint256 used, uint256 recorded) internal pure {
        assertGe(used, recorded * 98 / 100, "cheaper than recorded");
        assertLe(used, recorded * 102 / 100, "dearer than recorded");
    }

    function _gas() internal returns (uint256) {
        return IManagedFrameGas(address(vm)).lastFrameGas().gasTotalUsed;
    }

    function _tempo() internal returns (bool) {
        if (address(0xfDC0000000000000000000000000000000000000).code.length != 0) return true;
        vm.skip(true, "needs --network tempo");
        return false;
    }
}
