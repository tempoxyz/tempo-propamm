// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { IRegistry } from "../../src/v2/interfaces/IRegistry.sol";
import { IVenueFactory } from "../../src/v2/interfaces/IVenueFactory.sol";
import { Registry } from "../../src/v2/Registry.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { CoreDeploy } from "./utils/CoreDeploy.sol";
import { RegistryBaseline } from "./utils/RegistryBaseline.sol";

// Foundry v1.8.1 exposes this cheatcode; the pinned forge-std predates its declaration.
interface RegistryGasVm {
    function lastFrameGas() external view returns (Vm.Gas memory gas);
}

/// @dev Run with the repository's isolate=true, on both standard EVM and --network tempo.
/// Measurements are the immediately preceding directory call frame, not gasleft deltas around the harness.
/// Snapshots replay identical calldata against the same canonical factory, venue, owner and salt state.
contract RegistryGasTest is Test {
    RegistryGasVm private constant GAS_VM = RegistryGasVm(address(vm));
    address private constant OWNER = address(0xBEEF);
    VenueFactory private factory;
    IRegistry private baseline;
    IRegistry private optimized;

    function setUp() public {
        (, factory) = CoreDeploy.core();
        baseline = new RegistryBaseline(IVenueFactory(address(factory)));
        optimized = new Registry(IVenueFactory(address(factory)));
    }

    function test_gasRegisterFirst() public {
        address venue = factory.createVenue(OWNER, "first");
        _compareCall("register first", abi.encodeCall(IRegistry.register, (venue)), false);
    }

    function test_gasRegisterLater() public {
        _seed(1);
        address venue = factory.createVenue(OWNER, "later");
        _compareCall("register later", abi.encodeCall(IRegistry.register, (venue)), false);
    }

    function test_gasRegisterDuplicate() public {
        _seed(1);
        address venue = factory.predictVenue(OWNER, bytes32(0));
        _compareCall("register duplicate", abi.encodeCall(IRegistry.register, (venue)), false);
    }

    function test_gasCreateFresh() public {
        _compareCall("create fresh", abi.encodeCall(IRegistry.createAndRegister, (OWNER, bytes32("fresh"))), false);
    }

    function test_gasCreateExisting() public {
        factory.createVenue(OWNER, "existing");
        _compareCall("create existing", abi.encodeCall(IRegistry.createAndRegister, (OWNER, bytes32("existing"))), true);
    }

    function test_gasCreateDuplicate() public {
        _seed(1);
        _compareCall("create duplicate", abi.encodeCall(IRegistry.createAndRegister, (OWNER, bytes32(0))), false);
    }

    function test_gasPage1() public {
        _seed(101);
        _comparePage("page 1", 1, 1, false);
    }

    function test_gasPage10() public {
        _seed(101);
        _comparePage("page 10", 1, 10, true);
    }

    function test_gasPage100() public {
        _seed(101);
        _comparePage("page 100", 1, 100, true);
    }

    function test_gasCreateExistingReverseOrder() public {
        factory.createVenue(OWNER, "reverse-existing");
        // Sanity-check isolation: the optimized call must also win when measured first.
        (baseline, optimized) = (optimized, baseline);
        (uint256 optimizedGas, uint256 baselineGas) = _compareCall(
            "reverse existing (optimized first)",
            abi.encodeCall(IRegistry.createAndRegister, (OWNER, bytes32("reverse-existing"))),
            false
        );
        assertLt(optimizedGas, baselineGas);
    }

    function test_paginationBoundaryDifferential() public {
        _seed(101);
        _comparePage("page zero", 0, 0, false);
        _comparePage("page tail", 100, 100, false);
        _comparePage("page end", 101, 100, false);
        _comparePage("page max offset", type(uint256).max, 100, false);
        _compareCall("oversized limit", abi.encodeCall(IRegistry.venues, (0, 101)), false);
        _compareCall(
            "oversized empty page", abi.encodeCall(IRegistry.venues, (type(uint256).max, type(uint256).max)), false
        );
    }

    function _seed(uint256 count) private {
        for (uint256 i; i < count; ++i) {
            address venue = factory.createVenue(OWNER, bytes32(i));
            baseline.register(venue);
            optimized.register(venue);
        }
    }

    function _compareCall(string memory label, bytes memory data, bool mustSave)
        private
        returns (uint256 beforeGas, uint256 afterGas)
    {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        (bool beforeSuccess, bytes memory beforeResult) = address(baseline).call(data);
        beforeGas = GAS_VM.lastFrameGas().gasTotalUsed;
        Vm.Log[] memory beforeLogs = vm.getRecordedLogs();
        bytes32 beforeState = _state(baseline);
        assertTrue(vm.revertToState(snapshot));
        vm.recordLogs();
        (bool afterSuccess, bytes memory afterResult) = address(optimized).call(data);
        afterGas = GAS_VM.lastFrameGas().gasTotalUsed;
        Vm.Log[] memory afterLogs = vm.getRecordedLogs();
        assertEq(afterSuccess, beforeSuccess, "success/revert parity");
        assertEq(afterResult, beforeResult, "return/revert bytes parity");
        assertEq(_state(optimized), beforeState, "directory state parity");
        assertEq(afterLogs.length, beforeLogs.length, "event count parity");
        for (uint256 i; i < beforeLogs.length; ++i) {
            address expectedEmitter =
                beforeLogs[i].emitter == address(baseline) ? address(optimized) : beforeLogs[i].emitter;
            assertEq(afterLogs[i].emitter, expectedEmitter, "event emitter parity");
            assertEq(afterLogs[i].topics, beforeLogs[i].topics, "event topics parity");
            assertEq(afterLogs[i].data, beforeLogs[i].data, "event data parity");
        }
        _logGas(label, beforeGas, afterGas, mustSave);
    }

    function _comparePage(string memory label, uint256 offset, uint256 limit, bool mustSave) private {
        uint256 snapshot = vm.snapshotState();
        address[] memory beforePage = baseline.venues(offset, limit);
        uint256 beforeGas = GAS_VM.lastFrameGas().gasTotalUsed;
        assertTrue(vm.revertToState(snapshot));
        address[] memory afterPage = optimized.venues(offset, limit);
        uint256 afterGas = GAS_VM.lastFrameGas().gasTotalUsed;
        assertEq(afterPage, beforePage, "page parity");
        _logGas(label, beforeGas, afterGas, mustSave);
    }

    function _state(IRegistry directory) private view returns (bytes32) {
        uint256 count = directory.venueCount();
        address[] memory entries = new address[](count);
        for (uint256 i; i < count; ++i) {
            entries[i] = directory.venueAt(i);
            assertTrue(directory.isRegistered(entries[i]));
        }
        return keccak256(abi.encode(count, entries));
    }

    function _logGas(string memory label, uint256 beforeGas, uint256 afterGas, bool mustSave) private {
        emit log_named_uint(string.concat(label, " before"), beforeGas);
        emit log_named_uint(string.concat(label, " after"), afterGas);
        assertGt(beforeGas, 0, "baseline frame measured");
        assertGt(afterGas, 0, "optimized frame measured");
        if (mustSave) assertLt(afterGas, beforeGas, "targeted path saves gas");
    }
}
