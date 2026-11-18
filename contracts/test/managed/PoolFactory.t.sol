// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { Test } from "forge-std/Test.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { IPoolFactory } from "../../src/managed/interfaces/IPoolFactory.sol";
import { IManagedDirectPropAMM as IM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";

// Even a constructor at the bound factory address cannot initialize a clone.
contract ConstructorFactoryProbe {
    bool public initialized;
    address public clone;

    constructor() {
        ManagedDirectPropAMM impl = new ManagedDirectPropAMM(address(0), address(this));
        clone = Clones.clone(address(impl));
        (initialized,) = clone.call(abi.encodeCall(IM.initialize, (address(this), address(this))));
    }
}

contract ManagedPoolFactoryTest is Test {
    PoolFactory internal factory;
    address internal owner = makeAddr("owner");

    function setUp() public {
        factory = new PoolFactory();
    }

    function test_factoryPredictionAndIsolation() public {
        bytes32 salt = bytes32("pool");
        address predicted = factory.predictPool(address(this), owner, salt);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IPoolFactory.PoolCreated(predicted, address(this), owner, salt);
        address created = factory.createPool(owner, salt);
        assertEq(created, predicted);
        assertTrue(factory.isPool(created));
        IM clone = IM(created);
        assertEq(clone.owner(), owner);
        assertEq(clone.factory(), address(factory));
        assertEq(clone.settler(), factory.defaultSettler());
        assertTrue(clone.paused());
        assertEq(clone.pairCount(), 0);
        assertEq(created.code.length, 77);
        vm.prank(owner);
        assertNotEq(factory.createPool(owner, salt), created);
        vm.expectRevert();
        factory.createPool(owner, salt);
    }

    function test_initializationLocked() public {
        IM clone = IM(factory.createPool(owner, bytes32(0)));
        address settler = factory.defaultSettler();
        address implementation = factory.implementation();
        vm.expectRevert(IM.AlreadyInitialized.selector);
        clone.initialize(owner, settler);
        vm.expectRevert(IM.AlreadyInitialized.selector);
        IM(implementation).initialize(owner, settler);
        assertFalse(factory.isPool(factory.implementation()));
        vm.expectRevert(IM.InvalidAddress.selector);
        factory.createPool(address(0), bytes32("bad"));
    }

    function test_constructorCannotSeedInitializedClone() public {
        ConstructorFactoryProbe probe = new ConstructorFactoryProbe();
        assertFalse(probe.initialized());
        assertEq(IM(probe.clone()).owner(), address(0));
    }

    function testFuzz_unknownAddressesNeverPassProof(address candidate) public view {
        assertFalse(factory.isPool(candidate));
    }

    function test_wrongFactoryAndZeroSaltRejected() public {
        address clone = factory.createPool(owner, bytes32("salt"));
        PoolFactory other = new PoolFactory();
        assertFalse(other.isPool(clone));
        address forged = makeAddr("zero salt");
        bytes memory code = clone.code;
        for (uint256 i = 45; i < 77; ++i) {
            code[i] = 0;
        }
        vm.etch(forged, code);
        assertFalse(factory.isPool(forged));
    }
}
