// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { stdError } from "forge-std/Test.sol";

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { IRegistry } from "../../src/v2/interfaces/IRegistry.sol";
import { IVenueFactory } from "../../src/v2/interfaces/IVenueFactory.sol";
import { Registry } from "../../src/v2/Registry.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { IntegrationFixture } from "./integration/utils/IntegrationFixture.sol";
import { CoreDeploy } from "./utils/CoreDeploy.sol";

/// @notice The directory discovers real factory clones without changing the deployed trading stack.
contract RegistryTest is IntegrationFixture {
    Registry internal directory;

    event Registered(address indexed venue, uint256 indexed index);

    function setUp() public override {
        super.setUp();
        // These three live venues predate the sidecar: none is automatically registered.
        directory = new Registry(IVenueFactory(address(factory)));
    }

    function test_constructorStartsEmptyAgainstExistingFactory() public view {
        assertEq(address(directory.factory()), address(factory));
        assertEq(directory.MAX_PAGE_SIZE(), 100);
        assertEq(directory.venueCount(), 0);
        assertFalse(directory.isRegistered(address(0)));
        assertFalse(directory.isRegistered(address(venueA)));
        assertEq(directory.venues(0, 100).length, 0);
    }

    function test_constructorRejectsZeroAndNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistry.InvalidFactory.selector, address(0)));
        new Registry(IVenueFactory(address(0)));
        vm.expectRevert(abi.encodeWithSelector(IRegistry.InvalidFactory.selector, stranger));
        new Registry(IVenueFactory(stranger));
    }

    function test_registerBackfillsPermissionlesslyInRegistrationOrder() public {
        vm.startPrank(stranger);
        vm.expectEmit(true, true, false, true, address(directory));
        emit Registered(address(venueC), 0);
        assertTrue(directory.register(address(venueC)));
        vm.expectEmit(true, true, false, true, address(directory));
        emit Registered(address(venueA), 1);
        assertTrue(directory.register(address(venueA)));
        vm.stopPrank();
        assertEq(directory.venueCount(), 2);
        assertEq(directory.venueAt(0), address(venueC));
        assertEq(directory.venueAt(1), address(venueA));
        assertTrue(directory.isRegistered(address(venueC)));
        assertTrue(directory.isRegistered(address(venueA)));
        assertFalse(directory.isRegistered(address(venueB)));
    }

    function test_registerDuplicateReturnsFalseWithoutEventOrReordering() public {
        directory.register(address(venueB));
        directory.register(address(venueA));
        vm.recordLogs();
        vm.prank(stranger);
        assertFalse(directory.register(address(venueB)));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(directory.venueCount(), 2);
        assertEq(directory.venueAt(0), address(venueB));
        assertEq(directory.venueAt(1), address(venueA));
    }

    function test_registerRejectsEOAZeroImplementationAndUndeployedPrediction() public {
        _assertUnknown(address(0));
        _assertUnknown(stranger);
        _assertUnknown(address(factory));
        _assertUnknown(factory.implementation());
        _assertUnknown(factory.predictVenue(makerA, "not-created"));
    }

    function test_registerRejectsOtherFactoryAndIdenticalCodeForgery() public {
        (, VenueFactory otherFactory) = CoreDeploy.core();
        address foreign = otherFactory.createVenue(makerA, "foreign");
        assertTrue(otherFactory.isVenue(foreign));
        _assertUnknown(foreign);

        bytes memory args = Clones.fetchCloneArgs(address(venueA));
        address forged = Clones.cloneWithImmutableArgs(factory.implementation(), args);
        assertEq(forged.code, address(venueA).code, "identical code is not factory provenance");
        _assertUnknown(forged);
        // Real ownership and live market state still work for the genuine clone.
        assertTrue(directory.register(address(venueA)));
    }

    function test_venueAtOutOfBoundsUsesArrayPanic() public {
        vm.expectRevert(stdError.indexOOBError);
        directory.venueAt(0);
        directory.register(address(venueA));
        vm.expectRevert(stdError.indexOOBError);
        directory.venueAt(1);
        vm.expectRevert(stdError.indexOOBError);
        directory.venueAt(type(uint256).max);
    }

    function test_paginationZeroLimitEndAndOverflowingOffset() public {
        directory.register(address(venueA));
        directory.register(address(venueB));
        assertEq(directory.venues(0, 0).length, 0);
        assertEq(directory.venues(1, 0).length, 0);
        assertEq(directory.venues(2, 100).length, 0);
        assertEq(directory.venues(type(uint256).max, 100).length, 0);
        assertEq(directory.venues(type(uint256).max, 0).length, 0);
        address[] memory tail = directory.venues(1, 100);
        assertEq(tail.length, 1);
        assertEq(tail[0], address(venueB));
    }

    function testFuzz_paginationRejectsOversizedLimitEvenForEmptyPage(uint256 limit, uint256 offset) public {
        limit = bound(limit, 101, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IRegistry.PageTooLarge.selector, limit, uint256(100)));
        directory.venues(offset, limit);
    }

    function test_paginationMaximumPageAndStableAppend() public {
        address[] memory expected = new address[](101);
        for (uint256 i; i < expected.length; ++i) {
            expected[i] = directory.createAndRegister(makerA, bytes32(i));
        }
        address[] memory first = directory.venues(0, 100);
        assertEq(first.length, 100);
        for (uint256 i; i < first.length; ++i) {
            assertEq(first[i], expected[i]);
            assertEq(directory.venueAt(i), expected[i]);
        }
        assertEq(directory.venues(100, 100)[0], expected[100]);
        directory.register(address(venueA));
        assertEq(directory.venues(0, 100), first);
        assertEq(directory.venueAt(101), address(venueA));
        assertEq(directory.venueCount(), 102);
    }

    function testFuzz_paginationMatchesAppendOnlyModel(uint8 count, uint256 offset, uint256 limit) public {
        uint256 length = bound(count, 0, 12);
        address[] memory expected = new address[](length);
        for (uint256 i; i < length; ++i) {
            expected[i] = directory.createAndRegister(makerA, bytes32(i));
            assertFalse(directory.register(expected[i]));
        }
        limit = bound(limit, 0, 100);
        _assertPage(expected, offset, limit);
        // Exercise interior pages even when the unconstrained offset is very large.
        _assertPage(expected, bound(offset, 0, length + 1), limit);
        assertEq(directory.venueCount(), length);
    }

    function test_createAndRegisterMatchesDirectFactoryAddressAndInitialization() public {
        bytes32 salt = "wrapped";
        address predicted = factory.predictVenue(makerA, salt);
        uint256 snapshot = vm.snapshotState();
        vm.prank(stranger);
        address direct = factory.createVenue(makerA, salt);
        bytes memory runtime = direct.code;
        assertTrue(vm.revertToState(snapshot));

        vm.expectEmit(true, true, false, true, address(directory));
        emit Registered(predicted, 0);
        vm.prank(stranger);
        address wrapped = directory.createAndRegister(makerA, salt);
        assertEq(wrapped, direct);
        assertEq(wrapped, predicted);
        assertEq(wrapped.code, runtime);
        assertTrue(factory.isVenue(wrapped));
        assertEq(IVenue(wrapped).owner(), makerA);
        assertEq(IVenue(wrapped).pendingOwner(), address(0));
        assertEq(IVenue(wrapped).settler(), address(settler));
        assertEq(IVenue(wrapped).factory(), address(factory));
        assertEq(IVenue(wrapped).pairCount(), 0);
        assertEq(directory.venueAt(0), wrapped);
        assertEq(directory.venueCount(), 1);
    }

    function test_createAndRegisterToleratesFrontRunAndRepeatedCalls() public {
        bytes32 salt = "front-run";
        vm.prank(stranger);
        address existing = factory.createVenue(makerA, salt);
        vm.expectEmit(true, true, false, true, address(directory));
        emit Registered(existing, 0);
        vm.prank(makerA);
        assertEq(directory.createAndRegister(makerA, salt), existing);
        vm.recordLogs();
        vm.prank(taker);
        assertEq(directory.createAndRegister(makerA, salt), existing);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(directory.venueCount(), 1);
        assertFalse(directory.register(existing));
    }

    function test_createAndRegisterDoesNotReinitializeTransferredVenue() public {
        vm.prank(makerA);
        venueA.transferOwnership(makerB);
        vm.prank(makerB);
        venueA.acceptOwnership();
        vm.prank(makerB);
        venueA.setSettler(stranger);
        assertEq(directory.createAndRegister(makerA, "A"), address(venueA));
        assertEq(venueA.owner(), makerB);
        assertEq(venueA.settler(), stranger);
        assertEq(venueA.pairCount(), 1);
    }

    function test_createAndRegisterRejectsZeroOwnerAtomically() public {
        vm.expectRevert(IVenueFactory.ZeroAddress.selector);
        directory.createAndRegister(address(0), "invalid");
        assertEq(directory.venueCount(), 0);
    }

    function test_createAndRegisterStillRejectsAnUnprovenFactoryReturn() public {
        bytes32 salt = "unproven-return";
        // A code-bearing factory is not necessarily canonical. Never trust only createVenue's return.
        vm.mockCall(address(factory), abi.encodeCall(IVenueFactory.createVenue, (makerA, salt)), abi.encode(stranger));
        vm.expectRevert(abi.encodeWithSelector(IRegistry.UnknownVenue.selector, stranger));
        directory.createAndRegister(makerA, salt);
        assertEq(directory.venueCount(), 0);
        assertFalse(directory.isRegistered(stranger));
    }

    function test_registrationPreservesLiveMarketCustodyAndTrading() public {
        uint256[12] memory balances = _balances();
        bytes32 beforeState = _marketState();
        vm.record();
        vm.prank(stranger);
        directory.register(address(venueA));
        (, bytes32[] memory venueWrites) = vm.accesses(address(venueA));
        (, bytes32[] memory factoryWrites) = vm.accesses(address(factory));
        assertEq(venueWrites.length, 0);
        assertEq(factoryWrites.length, 0);
        assertEq(_marketState(), beforeState);
        _assertUnchanged(balances);
        assertEq(eur.balanceOf(address(directory)), 0);
        assertEq(usd.balanceOf(address(directory)), 0);

        (, uint256 expectedOut,) = _expect(venueA, pairA, true, true, UNIT);
        uint256 output = _swapExactIn(taker, address(eur), address(usd), _request(venueA, pairA, UNIT), expectedOut);
        assertEq(output, expectedOut);
        assertEq(eur.balanceOf(taker), balances[0] - UNIT);
        assertEq(usd.balanceOf(taker), balances[1] + output);
        assertEq(eur.balanceOf(address(venueA)), balances[4] + UNIT);
        assertEq(usd.balanceOf(address(venueA)), balances[5] - output);
        assertEq(directory.venueAt(0), address(venueA));
    }

    function _marketState() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                venueA.owner(),
                venueA.pendingOwner(),
                venueA.settler(),
                venueA.pairCount(),
                venueA.pair(pairA),
                venueA.hotWord(pairA),
                venueA.shape(pairA, 0),
                venueA.halted(),
                venueA.isUpdater(updaterA),
                venueA.takerAccess(pairA, taker, HOME)
            )
        );
    }

    function _assertUnknown(address candidate) internal {
        vm.expectRevert(abi.encodeWithSelector(IRegistry.UnknownVenue.selector, candidate));
        directory.register(candidate);
        assertFalse(directory.isRegistered(candidate));
        assertEq(directory.venueCount(), 0);
    }

    function _assertPage(address[] memory expected, uint256 offset, uint256 limit) internal view {
        address[] memory page = directory.venues(offset, limit);
        uint256 length = offset >= expected.length ? 0 : expected.length - offset;
        if (length > limit) length = limit;
        assertEq(page.length, length);
        for (uint256 i; i < length; ++i) {
            assertEq(page[i], expected[offset + i]);
            assertTrue(directory.isRegistered(page[i]));
        }
    }
}
