// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Test.sol";

import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { ManagedPoolFixture } from "./utils/ManagedPoolFixture.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

/// @notice `ManagedDirectPropAMM`'s access, v2 `Venue`'s model re-implemented: per-pair home lists (sponsor 0) that
/// only the owner edits, owner-registered sponsors with their own admins, switches, per-pair admissions and
/// generations, a pool-wide deny list and `Closed`/`Listed`/`Open` per pair. Pool administration is owner-only;
/// sponsor admins control only their own lists. Swaps pay their caller and name the list they trade under.
/// @dev Ports `contracts/test/v2/VenueAccess.t.sol` and `VenueAccessReasons.t.sol` with
/// swaps run directly on the pool. The pool calls nothing for access, so the suite runs the same under
/// `--network tempo`.
contract ManagedDirectPropAMMAccessTest is ManagedPoolFixture {
    // Storage slots, matching ManagedDirectPropAMM's declared layout.
    uint256 internal constant SLOT_DENIED = 6;
    uint256 internal constant SLOT_ADMITTED = 9;
    uint256 internal constant SLOT_MEMBERS = 10;
    /// @dev Never registered.
    uint64 internal constant UNREGISTERED = 4242;

    // ---------------------------------------------------------------- the home lists (sponsor 0)

    function test_ownerListsAndDelistsOnTheHomeList() external {
        assertFalse(pool.takerAllowed(PRIME_PAIR, taker, HOME));
        assertEq(uint8(_access(PRIME_PAIR, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.NotListed));
        _listHome(PRIME_PAIR, taker);
        assertTrue(pool.isMember(PRIME_PAIR, HOME, taker));
        assertTrue(pool.pairSponsor(PRIME_PAIR, HOME), "every live pair admits its home list");
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT);
        pool.setMembers(PRIME_PAIR, HOME, _one(taker), false);
        assertFalse(pool.isMember(PRIME_PAIR, HOME, taker));
        _expectSellRevert(_notAllowed(taker), PRIME_PAIR, taker, HOME);
    }

    /// @dev Home lists are per pair: listing on one admits nothing on the other.
    function test_homeListsArePerPair() external {
        _listHome(PRIME_PAIR, taker);
        assertTrue(pool.takerAllowed(PRIME_PAIR, taker, HOME));
        assertFalse(pool.takerAllowed(EUR_PAIR, taker, HOME));
        _expectSellRevert(_notAllowed(taker), EUR_PAIR, taker, HOME);
    }

    function test_onlyTheOwnerEditsTheHomeList() external {
        _addAlpha();
        address[3] memory others = [unauthorized, alpha, stranger];
        for (uint256 i; i < others.length; ++i) {
            for (uint256 k; k < 2; ++k) {
                vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
                vm.prank(others[i]);
                pool.setMembers(PRIME_PAIR, HOME, _one(taker), k == 0);
            }
        }
    }

    function test_homeListControlFollowsOwnership() external {
        address next = makeAddr("next");
        pool.transferOwnership(next);
        vm.prank(next);
        pool.acceptOwnership();
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setMembers(PRIME_PAIR, HOME, _one(taker), true);
        vm.prank(next);
        pool.setMembers(PRIME_PAIR, HOME, _one(taker), true);
        assertTrue(pool.takerAllowed(PRIME_PAIR, taker, HOME));
    }

    /// @dev None of the former secondary role's narrowing powers remain available to a non-owner.
    function test_narrowingControlsAreOwnerOnly() external {
        _addAlpha();
        bytes[] memory calls = _narrowingCalls();
        address[3] memory others = [unauthorized, alpha, stranger];
        for (uint256 i; i < others.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(others[i]);
                (bool ok, bytes memory reason) = address(pool).call(calls[j]);
                assertFalse(ok);
                assertEq(reason, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
            }
        }
        assertFalse(pool.paused());
        assertFalse(pool.denied(taker));
        assertTrue(pool.pairSponsor(PRIME_PAIR, ALPHA));
        (, bool enabled,) = pool.sponsor(ALPHA);
        assertTrue(enabled);
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Listed));
    }

    function test_narrowingControlFollowsOwnership() external {
        _addAlpha();
        pool.transferOwnership(unauthorized);
        vm.prank(unauthorized);
        pool.acceptOwnership();
        bytes[] memory calls = _narrowingCalls();
        for (uint256 i; i < calls.length; ++i) {
            (bool oldOwnerOk, bytes memory reason) = address(pool).call(calls[i]);
            assertFalse(oldOwnerOk);
            assertEq(reason, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
            vm.prank(unauthorized);
            (bool ownerOk, bytes memory result) = address(pool).call(calls[i]);
            assertTrue(ownerOk, vm.toString(result));
        }
        assertTrue(pool.paused());
        assertTrue(pool.denied(taker));
        assertFalse(pool.pairSponsor(PRIME_PAIR, ALPHA));
        (, bool enabled,) = pool.sponsor(ALPHA);
        assertFalse(enabled);
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Closed));
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.unpause();
        vm.prank(unauthorized);
        pool.unpause();
        assertFalse(pool.paused());
    }

    function _narrowingCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](5);
        calls[0] = abi.encodeCall(IManagedDirectPropAMM.pause, ());
        calls[1] = abi.encodeCall(IManagedDirectPropAMM.closePair, (PRIME_PAIR));
        calls[2] = abi.encodeCall(IManagedDirectPropAMM.setDenied, (_one(taker), true));
        calls[3] = abi.encodeCall(IManagedDirectPropAMM.setSponsorEnabled, (ALPHA, false));
        calls[4] = abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PRIME_PAIR, ALPHA, false));
    }

    // ---------------------------------------------------------------- sponsors

    function test_addSponsorRegistersItEnabledAndAdmittedNowhere() external {
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.SponsorAdded(ALPHA, alpha);
        pool.addSponsor(ALPHA, alpha);
        (address admin, bool enabled, uint32 generation) = pool.sponsor(ALPHA);
        assertEq(admin, alpha);
        assertTrue(enabled);
        assertEq(generation, 1);
        assertFalse(pool.pairSponsor(PRIME_PAIR, ALPHA));
        assertFalse(pool.pairSponsor(EUR_PAIR, ALPHA));
        assertEq(uint8(_access(PRIME_PAIR, member, ALPHA)), uint8(IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted));
        (admin, enabled, generation) = pool.sponsor(UNREGISTERED);
        assertEq(admin, address(0));
        assertFalse(enabled);
        assertEq(generation, 0);
    }

    function test_addSponsorValidation() external {
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.SponsorExists.selector, HOME));
        pool.addSponsor(HOME, alpha);
        pool.addSponsor(ALPHA, alpha);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.SponsorExists.selector, ALPHA));
        pool.addSponsor(ALPHA, beta);
        address[3] memory bad = [address(0), address(pool), VirtualAddress.make(0x12345678, 1)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
            pool.addSponsor(BETA, bad[i]);
        }
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.addSponsor(BETA, beta);
        // One admin may hold several ids.
        pool.addSponsor(BETA, alpha);
    }

    /// @dev Switching a sponsor off stops its swaps on every pair and its listings, keeps its lists and admissions,
    /// and switching it on restores them. Only the owner controls either direction.
    function test_switchingASponsorOffStopsItsSwapsAndOnRestoresThem() external {
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);
        _listAlpha(EUR_PAIR, member);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.SponsorEnabledSet(ALPHA, false, address(this));
        pool.setSponsorEnabled(ALPHA, false);
        bytes memory disabled = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, ALPHA);
        _expectSellRevert(disabled, PRIME_PAIR, member, ALPHA);
        _expectSellRevert(disabled, EUR_PAIR, member, ALPHA);
        vm.expectRevert(disabled);
        vm.prank(alpha);
        pool.setMembers(PRIME_PAIR, ALPHA, _one(stranger), true);
        // It can still delist.
        vm.prank(alpha);
        pool.setMembers(EUR_PAIR, ALPHA, _one(member), false);
        assertTrue(pool.isMember(PRIME_PAIR, ALPHA, member), "the list is kept");

        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.setSponsorEnabled(ALPHA, true);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(stranger);
        pool.setSponsorEnabled(ALPHA, false);
        pool.setSponsorEnabled(ALPHA, true);
        assertEq(_sell(PRIME_PAIR, member, ALPHA), PRIME_OUT);
        _expectSellRevert(_notAllowed(member), EUR_PAIR, member, ALPHA);
    }

    /// @dev Removing a sponsor from a pair stops it there only, keeps its list and the slot nonzero (`REMOVED`), and
    /// readmitting restores every member. Only the owner controls admissions; admission needs a live pair.
    function test_removingASponsorFromAPairStopsItThereAndReadmittingRestoresIt() external {
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);
        _listAlpha(EUR_PAIR, member);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PairSponsorSet(PRIME_PAIR, ALPHA, false, address(this));
        pool.setPairSponsor(PRIME_PAIR, ALPHA, false);
        assertFalse(pool.pairSponsor(PRIME_PAIR, ALPHA));
        assertEq(uint256(vm.load(address(pool), _admittedSlot(PRIME_PAIR, ALPHA))), 2, "REMOVED keeps the slot");
        _expectSellRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.SponsorNotAdmitted.selector, PRIME_PAIR, ALPHA),
            PRIME_PAIR,
            member,
            ALPHA
        );
        assertEq(_sell(EUR_PAIR, member, ALPHA), 10 * EUR_OUT, "the other pair still admits it");
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.SponsorNotAdmitted.selector, PRIME_PAIR, ALPHA));
        vm.prank(alpha);
        pool.setMembers(PRIME_PAIR, ALPHA, _one(stranger), true);

        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.setPairSponsor(PRIME_PAIR, ALPHA, true);
        pool.setPairSponsor(PRIME_PAIR, ALPHA, true);
        assertEq(uint256(vm.load(address(pool), _admittedSlot(PRIME_PAIR, ALPHA))), 1, "ADMITTED");
        assertEq(_sell(PRIME_PAIR, member, ALPHA), PRIME_OUT);

        // Removing a sponsor never admitted writes nothing; admitting needs a live pair.
        pool.addSponsor(BETA, beta);
        pool.setPairSponsor(PRIME_PAIR, BETA, false);
        assertEq(uint256(vm.load(address(pool), _admittedSlot(PRIME_PAIR, BETA))), 0);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, uint16(9)));
        pool.setPairSponsor(9, BETA, true);
        pool.setPairSponsor(9, BETA, false);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(stranger);
        pool.setPairSponsor(PRIME_PAIR, ALPHA, false);
    }

    function test_switchesNeedARegisteredSponsor() external {
        uint64[2] memory ids = [HOME, UNREGISTERED];
        for (uint256 i; i < ids.length; ++i) {
            bytes memory unknown = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, ids[i]);
            vm.expectRevert(unknown);
            pool.setSponsorEnabled(ids[i], true);
            vm.expectRevert(unknown);
            pool.setPairSponsor(PRIME_PAIR, ids[i], true);
            vm.expectRevert(unknown);
            pool.setPairSponsor(PRIME_PAIR, ids[i], false);
            vm.expectRevert(unknown);
            pool.resetSponsor(ids[i], alpha);
        }
    }

    /// @dev Every switch call emits, even when nothing changes.
    function test_switchesEmitEveryCall() external {
        _addAlpha();
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(address(pool));
            emit IManagedDirectPropAMM.SponsorEnabledSet(ALPHA, true, address(this));
            pool.setSponsorEnabled(ALPHA, true);
            vm.expectEmit(address(pool));
            emit IManagedDirectPropAMM.PairSponsorSet(PRIME_PAIR, ALPHA, true, address(this));
            pool.setPairSponsor(PRIME_PAIR, ALPHA, true);
        }
    }

    // ---------------------------------------------------------------- sponsor lists

    function test_onlyTheSponsorAdminEditsItsList() external {
        _addAlpha();
        pool.addSponsor(BETA, beta);
        pool.setPairSponsor(PRIME_PAIR, BETA, true);
        address[4] memory others = [address(this), unauthorized, beta, stranger];
        for (uint256 i; i < others.length; ++i) {
            for (uint256 k; k < 2; ++k) {
                vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, ALPHA));
                vm.prank(others[i]);
                pool.setMembers(PRIME_PAIR, ALPHA, _one(member), k == 0);
            }
        }
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, UNREGISTERED));
        vm.prank(alpha);
        pool.setMembers(PRIME_PAIR, UNREGISTERED, _one(member), true);
    }

    /// @dev A swap reads only the list it names: a member of `ALPHA`'s list is refused under the home list and under
    /// `BETA`, and a home member under `ALPHA`.
    function test_aSwapReadsOnlyTheNamedList() external {
        _addAlpha();
        pool.addSponsor(BETA, beta);
        pool.setPairSponsor(PRIME_PAIR, BETA, true);
        _listAlpha(PRIME_PAIR, member);
        _listHome(PRIME_PAIR, taker);
        assertEq(_sell(PRIME_PAIR, member, ALPHA), PRIME_OUT);
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT);
        _expectSellRevert(_notAllowed(member), PRIME_PAIR, member, HOME);
        _expectSellRevert(_notAllowed(member), PRIME_PAIR, member, BETA);
        _expectSellRevert(_notAllowed(taker), PRIME_PAIR, taker, ALPHA);
        _expectSellRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, UNREGISTERED),
            PRIME_PAIR,
            member,
            UNREGISTERED
        );
    }

    function test_setMembersValidation() external {
        _addAlpha();
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.BatchTooLarge.selector, MAX_BATCH + 1, MAX_BATCH));
        pool.setMembers(PRIME_PAIR, HOME, _accounts(MAX_BATCH + 1), true);
        pool.setMembers(PRIME_PAIR, HOME, _accounts(MAX_BATCH), true);
        address[2] memory bad = [address(0), address(pool)];
        for (uint256 i; i < bad.length; ++i) {
            address[] memory accounts = new address[](2);
            accounts[0] = stranger;
            accounts[1] = bad[i];
            vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
            pool.setMembers(PRIME_PAIR, HOME, accounts, true);
            vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
            vm.prank(alpha);
            pool.setMembers(PRIME_PAIR, ALPHA, accounts, false);
            assertFalse(pool.isMember(PRIME_PAIR, HOME, stranger), "atomic");
        }
        // A listing needs a live pair; a delisting doesn't. A virtual address is accepted, as in v2.
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, uint16(9)));
        pool.setMembers(9, HOME, _one(taker), true);
        pool.setMembers(9, HOME, _one(taker), false);
        address virtualAccount = VirtualAddress.make(0x12345678, 1);
        _listHome(PRIME_PAIR, virtualAccount);
        assertTrue(pool.isMember(PRIME_PAIR, HOME, virtualAccount));
    }

    /// @dev `MemberUpdated` for every entry, no-ops included, and only real changes write.
    function test_setMembersEmitsEveryEntry() external {
        _listHome(PRIME_PAIR, taker);
        address[] memory accounts = new address[](3);
        accounts[0] = taker;
        accounts[1] = stranger;
        accounts[2] = taker;
        vm.recordLogs();
        pool.setMembers(PRIME_PAIR, HOME, accounts, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].topics[0], IManagedDirectPropAMM.MemberUpdated.selector);
            assertEq(logs[i].topics[1], bytes32(uint256(PRIME_PAIR)));
            assertEq(logs[i].topics[2], bytes32(uint256(HOME)));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(accounts[i]))));
            assertEq(abi.decode(logs[i].data, (bool)), true);
        }
        assertEq(uint256(vm.load(address(pool), _memberSlot(PRIME_PAIR, HOME, stranger))), 1, "a home member stores 1");
    }

    // ---------------------------------------------------------------- handover and reset

    function test_sponsorAdminHandsItsListsOnInTwoSteps() external {
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.SponsorAdminTransferStarted(ALPHA, alpha, beta);
        vm.prank(alpha);
        pool.transferSponsorAdmin(ALPHA, beta);
        assertEq(pool.pendingSponsorAdmin(ALPHA), beta);
        // Until it accepts, the old admin keeps the list.
        vm.prank(alpha);
        pool.setMembers(PRIME_PAIR, ALPHA, _one(stranger), true);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotPendingSponsorAdmin.selector, ALPHA));
        vm.prank(stranger);
        pool.acceptSponsorAdmin(ALPHA);

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.SponsorAdminTransferred(ALPHA, alpha, beta);
        vm.prank(beta);
        pool.acceptSponsorAdmin(ALPHA);
        (address admin,, uint32 generation) = pool.sponsor(ALPHA);
        assertEq(admin, beta);
        assertEq(generation, 1, "a handover keeps the list");
        assertEq(pool.pendingSponsorAdmin(ALPHA), address(0));
        assertEq(_sell(PRIME_PAIR, member, ALPHA), PRIME_OUT);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, ALPHA));
        vm.prank(alpha);
        pool.setMembers(PRIME_PAIR, ALPHA, _one(stranger), false);
    }

    function test_handoverValidation() external {
        _addAlpha();
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, ALPHA));
        pool.transferSponsorAdmin(ALPHA, beta);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, UNREGISTERED));
        vm.prank(alpha);
        pool.transferSponsorAdmin(UNREGISTERED, beta);
        vm.startPrank(alpha);
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.transferSponsorAdmin(ALPHA, address(pool));
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.transferSponsorAdmin(ALPHA, VirtualAddress.make(0x12345678, 1));
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.transferSponsorAdmin(ALPHA, address(0));
        // Cancellation is a separate, idempotent current-admin action.
        pool.transferSponsorAdmin(ALPHA, beta);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.SponsorAdminTransferStarted(ALPHA, alpha, address(0));
        pool.cancelSponsorAdminTransfer(ALPHA);
        vm.stopPrank();
        assertEq(pool.pendingSponsorAdmin(ALPHA), address(0));
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotPendingSponsorAdmin.selector, ALPHA));
        vm.prank(beta);
        pool.acceptSponsorAdmin(ALPHA);

        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, ALPHA));
        pool.cancelSponsorAdminTransfer(ALPHA);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.SponsorAdminTransferStarted(ALPHA, alpha, address(0));
        vm.prank(alpha);
        pool.cancelSponsorAdminTransfer(ALPHA);
    }

    /// @dev A reset voids every earlier listing at once, keeps the id, its switch and its admissions, and cancels a
    /// pending handover; the new admin starts an empty list.
    function test_resetVoidsTheOldListAndKeepsTheIdSwitchAndAdmissions() external {
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);
        _listAlpha(EUR_PAIR, member);
        vm.prank(alpha);
        pool.transferSponsorAdmin(ALPHA, stranger);
        pool.setSponsorEnabled(ALPHA, false);

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.SponsorReset(ALPHA, alpha, beta, 2);
        pool.resetSponsor(ALPHA, beta);
        (address admin, bool enabled, uint32 generation) = pool.sponsor(ALPHA);
        assertEq(admin, beta);
        assertFalse(enabled, "the switch is kept");
        assertEq(generation, 2);
        assertEq(pool.pendingSponsorAdmin(ALPHA), address(0), "the handover is cancelled");
        assertTrue(pool.pairSponsor(PRIME_PAIR, ALPHA), "admissions are kept");
        assertFalse(pool.isMember(PRIME_PAIR, ALPHA, member), "the old list is void");
        assertFalse(pool.isMember(EUR_PAIR, ALPHA, member));

        pool.setSponsorEnabled(ALPHA, true);
        _expectSellRevert(_notAllowed(member), PRIME_PAIR, member, ALPHA);
        vm.prank(beta);
        pool.setMembers(PRIME_PAIR, ALPHA, _one(member), true);
        assertEq(uint256(vm.load(address(pool), _memberSlot(PRIME_PAIR, ALPHA, member))), 2, "stores the generation");
        assertEq(_sell(PRIME_PAIR, member, ALPHA), PRIME_OUT);
        _expectSellRevert(_notAllowed(member), EUR_PAIR, member, ALPHA);
    }

    function test_resetValidation() external {
        _addAlpha();
        address[3] memory bad = [address(0), address(pool), VirtualAddress.make(0x12345678, 1)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
            pool.resetSponsor(ALPHA, bad[i]);
        }
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.resetSponsor(ALPHA, beta);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(alpha);
        pool.resetSponsor(ALPHA, beta);
    }

    // ---------------------------------------------------------------- modes

    /// @dev `Open` admits everyone not denied, whatever `sponsorId`, and reads no list.
    function test_openIgnoresTheSponsorAndReadsNoList() external {
        _setAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        vm.record();
        assertEq(_sell(PRIME_PAIR, stranger, UNREGISTERED), PRIME_OUT);
        (bytes32[] memory reads,) = vm.accesses(address(pool));
        bytes32 slot = _memberSlot(PRIME_PAIR, UNREGISTERED, stranger);
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(reads[i] != slot, "read a list");
        }
        assertTrue(pool.takerAllowed(PRIME_PAIR, stranger, HOME));
        assertFalse(pool.takerAllowed(EUR_PAIR, stranger, HOME), "Open is per pair");
    }

    function test_closedRejectsEveryoneOnItsPairOnly() external {
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
        pool.closePair(PRIME_PAIR);
        _expectSellRevert(_notAllowed(taker), PRIME_PAIR, taker, HOME);
        assertEq(uint8(_access(PRIME_PAIR, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.Closed));
        assertEq(_sell(EUR_PAIR, taker, HOME), 10 * EUR_OUT);
    }

    // ---------------------------------------------------------------- the deny list

    /// @dev A denial overrides the home list, every sponsor list and `Open`, on every pair.
    function test_denyOverridesEveryListAndOpen() external {
        _addAlpha();
        _listHome(PRIME_PAIR, taker);
        _listAlpha(PRIME_PAIR, taker);
        _setAccess(EUR_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        pool.setDenied(_one(taker), true);
        bytes memory deniedErr = abi.encodeWithSelector(IManagedDirectPropAMM.TakerDenied.selector, taker);
        _expectSellRevert(deniedErr, PRIME_PAIR, taker, HOME);
        _expectSellRevert(deniedErr, PRIME_PAIR, taker, ALPHA);
        _expectSellRevert(deniedErr, EUR_PAIR, taker, HOME);
        pool.setDenied(_one(taker), false);
        assertEq(_sell(EUR_PAIR, taker, HOME), 10 * EUR_OUT);
    }

    function test_onlyTheOwnerDeniesAndLifts() external {
        address[3] memory others = [unauthorized, alpha, stranger];
        for (uint256 i; i < others.length; ++i) {
            for (uint256 k; k < 2; ++k) {
                vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
                vm.prank(others[i]);
                pool.setDenied(_one(taker), k == 0);
            }
        }
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.DenyUpdated(taker, true, address(this));
        pool.setDenied(_one(taker), true);
        assertTrue(pool.denied(taker));
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.DenyUpdated(taker, false, address(this));
        pool.setDenied(_one(taker), false);
        assertFalse(pool.denied(taker));
    }

    function test_setDeniedValidation() external {
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.BatchTooLarge.selector, MAX_BATCH + 1, MAX_BATCH));
        pool.setDenied(_accounts(MAX_BATCH + 1), true);
        address[2] memory bad = [address(0), address(pool)];
        for (uint256 i; i < bad.length; ++i) {
            address[] memory accounts = new address[](2);
            accounts[0] = stranger;
            accounts[1] = bad[i];
            vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
            pool.setDenied(accounts, true);
        }
        assertEq(pool.deniedCount(), 0, "atomic");
        // A virtual address is accepted, as in v2 (the access script refuses it: it blocks nobody).
        pool.setDenied(_one(VirtualAddress.make(0x12345678, 1)), true);
        assertEq(pool.deniedCount(), 1);
    }

    function test_setDeniedCountsExactlyAndEmitsChangedEntries() external {
        address[] memory accounts = _accounts(4);
        accounts[3] = accounts[0];
        vm.recordLogs();
        pool.setDenied(accounts, true);
        assertEq(vm.getRecordedLogs().length, 3, "every state transition");
        assertEq(pool.deniedCount(), 3, "duplicates count once");
        vm.recordLogs();
        pool.setDenied(accounts, true);
        assertEq(vm.getRecordedLogs().length, 0, "re-denying emits nothing");
        assertEq(pool.deniedCount(), 3, "re-denying counts nothing");
        address[] memory two = new address[](2);
        two[0] = accounts[1];
        two[1] = stranger;
        vm.recordLogs();
        pool.setDenied(two, false);
        assertEq(vm.getRecordedLogs().length, 1, "only the lifted account emits");
        assertEq(pool.deniedCount(), 2, "lifting an undenied account counts nothing");
        pool.setDenied(accounts, false);
        assertEq(pool.deniedCount(), 0);
    }

    /// @dev While nobody is denied a swap reads no deny slot; once anyone is, it reads its taker's.
    function test_emptyDenyListReadsNoDenySlot() external {
        _listHome(PRIME_PAIR, taker);
        assertFalse(_denySlotReadBySwap(taker));
        pool.setDenied(_one(stranger), true);
        assertTrue(_denySlotReadBySwap(taker));
    }

    /// @dev A refusal before the list (`Closed`, a denial) reads neither the member's slot nor the sponsor's.
    function test_refusalsBeforeTheListReadNoList() external {
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);
        bytes32[2] memory slots = [_memberSlot(PRIME_PAIR, ALPHA, member), _admittedSlot(PRIME_PAIR, ALPHA)];
        pool.setDenied(_one(member), true);
        _assertSwapReadsNone(member, slots, abi.encodeWithSelector(IManagedDirectPropAMM.TakerDenied.selector, member));
        pool.setDenied(_one(member), false);
        pool.closePair(PRIME_PAIR);
        _assertSwapReadsNone(member, slots, _notAllowed(member));
    }

    /// @dev Sponsors have no limit: each of 40 admits its own member, under its own id only, and one account a
    /// neighbour also lists trades under either.
    function test_manySponsorsEachAdmitOnlyTheirOwnMembers() external {
        uint256 count = 40;
        address[] memory members = new address[](count);
        for (uint256 i; i < count; ++i) {
            members[i] = makeAddr(string.concat("member", vm.toString(i)));
            address admin = makeAddr(string.concat("admin", vm.toString(i)));
            _fundTaker(members[i]);
            uint64 id = uint64(100 + i);
            pool.addSponsor(id, admin);
            pool.setPairSponsor(PRIME_PAIR, id, true);
            vm.prank(admin);
            pool.setMembers(PRIME_PAIR, id, _one(members[i]), true);
        }
        for (uint256 i; i < count; ++i) {
            uint64 id = uint64(100 + i);
            uint64 neighbour = uint64(100 + (i + 1) % count);
            assertEq(_sell(PRIME_PAIR, members[i], id), PRIME_OUT);
            assertEq(
                uint8(_access(PRIME_PAIR, members[i], neighbour)), uint8(IManagedDirectPropAMM.TakerAccess.NotListed)
            );
            _expectSellRevert(_notAllowed(members[i]), PRIME_PAIR, members[i], neighbour);
        }
        vm.prank(makeAddr("admin39"));
        pool.setMembers(PRIME_PAIR, 139, _one(members[0]), true);
        assertEq(_sell(PRIME_PAIR, members[0], 139), PRIME_OUT, "an account on two fintechs' lists trades under either");
    }

    /// @dev Only the owner closes a pair: not a listed taker, a sponsor admin or a stranger.
    function test_othersCannotCloseAPair() external {
        _addAlpha();
        _listHome(PRIME_PAIR, taker);
        address[5] memory others = [unauthorized, taker, member, alpha, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            vm.prank(others[i]);
            pool.closePair(PRIME_PAIR);
        }
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Listed));
    }

    /// @dev The TIP-1028 receive-policy guard, which every TIP-403 list used to admit, is an ordinary account now: on
    /// no list it is `NotListed`, `Open` admits it like anyone, and a denial or `Closed` refuses it.
    function test_theReceivePolicyGuardIsAnOrdinaryAccount() external {
        address guard = 0xB10C000000000000000000000000000000000000;
        _addAlpha();
        assertEq(uint8(_access(PRIME_PAIR, guard, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.NotListed));
        assertEq(uint8(_access(PRIME_PAIR, guard, ALPHA)), uint8(IManagedDirectPropAMM.TakerAccess.NotListed));
        _setAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        assertEq(uint8(_access(PRIME_PAIR, guard, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.Allowed));
        pool.setDenied(_one(guard), true);
        assertEq(uint8(_access(PRIME_PAIR, guard, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.Denied));
        pool.closePair(PRIME_PAIR);
        assertEq(uint8(_access(PRIME_PAIR, guard, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.Closed));
    }

    // ---------------------------------------------------------------- reasons

    function test_outcomesAreNoneThenAllowedThenEachRefusalInSwapOrder() external pure {
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.None), 0);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.Allowed), 1);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.UnknownPair), 2);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.Closed), 3);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.Denied), 4);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.UnknownSponsor), 5);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.SponsorDisabled), 6);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted), 7);
        assertEq(uint8(IManagedDirectPropAMM.TakerAccess.NotListed), 8);
        assertEq(uint8(IManagedDirectPropAMM.AccessMode.None), 0);
        assertEq(uint8(IManagedDirectPropAMM.AccessMode.Closed), 1);
        assertEq(uint8(IManagedDirectPropAMM.AccessMode.Listed), 2);
        assertEq(uint8(IManagedDirectPropAMM.AccessMode.Open), 3);
    }

    /// @dev A zero word decodes as `None`, never `Allowed`, and the view never returns it.
    function test_zeroIsNeverAllowed() external {
        IManagedDirectPropAMM.TakerAccess zero = abi.decode(new bytes(32), (IManagedDirectPropAMM.TakerAccess));
        assertEq(uint8(zero), uint8(IManagedDirectPropAMM.TakerAccess.None));
        assertTrue(zero != IManagedDirectPropAMM.TakerAccess.Allowed);
        address noCode = makeAddr("no code");
        bytes memory data = abi.encodeCall(IManagedDirectPropAMM.takerAccess, (PRIME_PAIR, taker, HOME));
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0x00, 0)
            ok := staticcall(gas(), noCode, add(data, 0x20), mload(data), 0x00, 0x20)
            word := mload(0x00)
        }
        assertTrue(ok);
        assertEq(word, uint256(IManagedDirectPropAMM.TakerAccess.None));
        _listHome(PRIME_PAIR, taker);
        assertEq(uint8(_access(PRIME_PAIR, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.Allowed));
        assertEq(uint8(_access(77, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.UnknownPair));
    }

    /// @dev Each step leaves every later refusal in place, so the view must name the first one a swap checks, and the
    /// swap must revert with that refusal's error.
    function test_precedenceFollowsSwapOrder() external {
        pool.addSponsor(BETA, beta);
        pool.setPairSponsor(PRIME_PAIR, BETA, true);
        vm.prank(beta);
        pool.setMembers(PRIME_PAIR, BETA, _one(stranger), true);
        pool.setPairSponsor(PRIME_PAIR, BETA, false);
        pool.setSponsorEnabled(BETA, false);
        pool.setDenied(_one(member), true);
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);

        // A removed pair outranks everything.
        uint16 removed = pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.removePair(removed);
        _check(removed, member, UNREGISTERED, IManagedDirectPropAMM.TakerAccess.UnknownPair);
        // `Closed` outranks the denial and every sponsor refusal.
        pool.closePair(PRIME_PAIR);
        _check(PRIME_PAIR, member, UNREGISTERED, IManagedDirectPropAMM.TakerAccess.Closed);
        _check(PRIME_PAIR, stranger, BETA, IManagedDirectPropAMM.TakerAccess.Closed);
        // The denial outranks every sponsor refusal and the list.
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        _check(PRIME_PAIR, member, UNREGISTERED, IManagedDirectPropAMM.TakerAccess.Denied);
        _check(PRIME_PAIR, member, BETA, IManagedDirectPropAMM.TakerAccess.Denied);
        _check(PRIME_PAIR, member, HOME, IManagedDirectPropAMM.TakerAccess.Denied);
        _check(PRIME_PAIR, member, ALPHA, IManagedDirectPropAMM.TakerAccess.Denied);
        // An unregistered sponsor outranks the list; a switched-off one its admission.
        _check(PRIME_PAIR, stranger, UNREGISTERED, IManagedDirectPropAMM.TakerAccess.UnknownSponsor);
        _check(PRIME_PAIR, stranger, BETA, IManagedDirectPropAMM.TakerAccess.SponsorDisabled);
        _check(PRIME_PAIR, taker, BETA, IManagedDirectPropAMM.TakerAccess.SponsorDisabled);
        pool.setSponsorEnabled(BETA, true);
        _check(PRIME_PAIR, stranger, BETA, IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted);
        _check(PRIME_PAIR, taker, BETA, IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted);
        pool.setPairSponsor(PRIME_PAIR, BETA, true);
        _check(PRIME_PAIR, stranger, BETA, IManagedDirectPropAMM.TakerAccess.Allowed);
        _check(PRIME_PAIR, taker, BETA, IManagedDirectPropAMM.TakerAccess.NotListed);
        // `Open` skips every sponsor refusal and the list, but not the denial.
        pool.setSponsorEnabled(BETA, false);
        _setAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        _check(PRIME_PAIR, taker, BETA, IManagedDirectPropAMM.TakerAccess.Allowed);
        _check(PRIME_PAIR, taker, UNREGISTERED, IManagedDirectPropAMM.TakerAccess.Allowed);
        _check(PRIME_PAIR, member, ALPHA, IManagedDirectPropAMM.TakerAccess.Denied);
    }

    /// @dev `TradeExecuted` carries the swap's sponsor id; on an `Open` pair it is the caller's unchecked claim.
    function test_tradeExecutedCarriesTheSponsorId() external {
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);
        _sellExpectingTrade(member, ALPHA);
        _setAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        _sellExpectingTrade(stranger, UNREGISTERED);
    }

    // ---------------------------------------------------------------- random states

    /// @dev Up to 12 random owner and sponsor-admin calls; for three accounts and four ids
    /// on both pairs the view must match an independent model, `takerAllowed` must be `takerAccess == Allowed`, and a
    /// swap must fill or revert as the view says.
    function testFuzz_takerAllowedIsTakerAccessAllowed(uint256 seed) external {
        _addAlpha();
        pool.addSponsor(BETA, beta);
        _model.registered[ALPHA] = true;
        _model.registered[BETA] = true;
        _model.enabled[ALPHA] = true;
        _model.enabled[BETA] = true;
        _model.generation[ALPHA] = 1;
        _model.generation[BETA] = 1;
        _model.admitted[PRIME_PAIR][ALPHA] = true;
        _model.admitted[EUR_PAIR][ALPHA] = true;
        _model.mode[PRIME_PAIR] = IManagedDirectPropAMM.AccessMode.Listed;
        _model.mode[EUR_PAIR] = IManagedDirectPropAMM.AccessMode.Listed;

        uint256 steps = 1 + seed % 12;
        for (uint256 i; i < steps; ++i) {
            _act(uint256(keccak256(abi.encode(seed, i))));
        }
        address[3] memory who = [taker, member, stranger];
        uint64[4] memory ids = [HOME, ALPHA, BETA, UNREGISTERED];
        for (uint16 p; p < 2; ++p) {
            for (uint256 w; w < who.length; ++w) {
                for (uint256 i; i < ids.length; ++i) {
                    IManagedDirectPropAMM.TakerAccess outcome = pool.takerAccess(p, who[w], ids[i]);
                    assertTrue(outcome != IManagedDirectPropAMM.TakerAccess.None, "never None");
                    assertEq(uint8(outcome), uint8(_modelAccess(p, who[w], ids[i])), "matches the model");
                    assertEq(pool.takerAllowed(p, who[w], ids[i]), outcome == IManagedDirectPropAMM.TakerAccess.Allowed);
                }
            }
        }
        for (uint256 k; k < 2; ++k) {
            uint256 s = uint256(keccak256(abi.encode(seed, "swap", k)));
            uint16 p = uint16(s % 2);
            address account = who[(s >> 8) % who.length];
            uint64 id = ids[(s >> 16) % ids.length];
            IManagedDirectPropAMM.TakerAccess outcome = pool.takerAccess(p, account, id);
            if (outcome == IManagedDirectPropAMM.TakerAccess.Allowed) {
                _sell(p, account, id);
            } else {
                _expectSellRevert(_swapError(outcome, p, account, id), p, account, id);
            }
        }
    }

    // ---------------------------------------------------------------- the model

    struct Model {
        mapping(uint16 => IManagedDirectPropAMM.AccessMode) mode;
        mapping(address => bool) denied;
        mapping(uint64 => bool) registered;
        mapping(uint64 => bool) enabled;
        mapping(uint64 => uint32) generation;
        mapping(uint16 => mapping(uint64 => bool)) admitted;
        mapping(uint16 => mapping(uint64 => mapping(address => uint32))) members;
    }

    Model internal _model;

    /// @dev One random call from the role that may make it, mirrored in the model.
    function _act(uint256 r) internal {
        uint16 p = uint16(r % 2);
        address[3] memory who = [taker, member, stranger];
        address account = who[(r >> 8) % 3];
        uint64 id = (r >> 16) % 2 == 0 ? ALPHA : BETA;
        address admin = id == ALPHA ? alpha : beta;
        bool flag = (r >> 24) % 2 == 0;
        uint256 op = (r >> 32) % 8;
        if (op == 0) {
            pool.setMembers(p, HOME, _one(account), flag);
            _model.members[p][HOME][account] = flag ? 1 : 0;
        } else if (op == 1) {
            // A sponsor lists only where it is enabled and admitted; skip what would revert.
            if (flag && !(_model.enabled[id] && _model.admitted[p][id])) return;
            vm.prank(admin);
            pool.setMembers(p, id, _one(account), flag);
            _model.members[p][id][account] = flag ? _model.generation[id] : 0;
        } else if (op == 2) {
            pool.setSponsorEnabled(id, flag);
            _model.enabled[id] = flag;
        } else if (op == 3) {
            pool.setPairSponsor(p, id, flag);
            _model.admitted[p][id] = flag;
        } else if (op == 4) {
            pool.resetSponsor(id, admin);
            _model.generation[id] += 1;
        } else if (op == 5) {
            pool.setDenied(_one(account), flag);
            _model.denied[account] = flag;
        } else if (op == 6) {
            IManagedDirectPropAMM.AccessMode mode = IManagedDirectPropAMM.AccessMode(1 + (r >> 40) % 3);
            _setAccess(p, mode);
            _model.mode[p] = mode;
        } else {
            pool.closePair(p);
            _model.mode[p] = IManagedDirectPropAMM.AccessMode.Closed;
        }
    }

    function _modelAccess(uint16 p, address account, uint64 id)
        internal
        view
        returns (IManagedDirectPropAMM.TakerAccess)
    {
        IManagedDirectPropAMM.AccessMode mode = _model.mode[p];
        if (mode == IManagedDirectPropAMM.AccessMode.Closed) return IManagedDirectPropAMM.TakerAccess.Closed;
        if (_model.denied[account]) return IManagedDirectPropAMM.TakerAccess.Denied;
        if (mode == IManagedDirectPropAMM.AccessMode.Open) return IManagedDirectPropAMM.TakerAccess.Allowed;
        uint32 generation = 1;
        if (id != HOME) {
            if (!_model.registered[id]) return IManagedDirectPropAMM.TakerAccess.UnknownSponsor;
            if (!_model.enabled[id]) return IManagedDirectPropAMM.TakerAccess.SponsorDisabled;
            if (!_model.admitted[p][id]) return IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted;
            generation = _model.generation[id];
        }
        return _model.members[p][id][account] == generation
            ? IManagedDirectPropAMM.TakerAccess.Allowed
            : IManagedDirectPropAMM.TakerAccess.NotListed;
    }

    function _swapError(IManagedDirectPropAMM.TakerAccess outcome, uint16 p, address account, uint64 id)
        internal
        pure
        returns (bytes memory)
    {
        if (outcome == IManagedDirectPropAMM.TakerAccess.Denied) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.TakerDenied.selector, account);
        }
        if (outcome == IManagedDirectPropAMM.TakerAccess.UnknownSponsor) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, id);
        }
        if (outcome == IManagedDirectPropAMM.TakerAccess.SponsorDisabled) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, id);
        }
        if (outcome == IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.SponsorNotAdmitted.selector, p, id);
        }
        return _notAllowed(account);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The view says `expected`, and a swap fills or reverts with that refusal's error.
    function _check(uint16 p, address account, uint64 id, IManagedDirectPropAMM.TakerAccess expected) internal {
        IManagedDirectPropAMM.TakerAccess outcome = pool.takerAccess(p, account, id);
        assertEq(uint8(outcome), uint8(expected), "takerAccess");
        assertEq(pool.takerAllowed(p, account, id), expected == IManagedDirectPropAMM.TakerAccess.Allowed);
        if (expected == IManagedDirectPropAMM.TakerAccess.Allowed) {
            _sell(p, account, id);
        } else if (expected == IManagedDirectPropAMM.TakerAccess.UnknownPair) {
            _expectSellRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p), p, account, id);
        } else {
            _expectSellRevert(_swapError(expected, p, account, id), p, account, id);
        }
    }

    function _sellExpectingTrade(address from, uint64 sponsorId) internal {
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.TradeExecuted(
            PRIME_PAIR,
            from,
            CUSTOMER,
            sponsorId,
            TRADE,
            address(prime),
            address(pathUsd),
            10 * UNIT,
            PRIME_OUT,
            PRIME_PRICE,
            block.timestamp
        );
        vm.prank(from);
        pool.swapExactInput(
            PRIME_PAIR, true, 10 * UNIT, 0, sponsorId, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
        );
    }

    /// @dev A swap by `account` under `ALPHA` reverts `err` and reads none of `slots`.
    function _assertSwapReadsNone(address account, bytes32[2] memory slots, bytes memory err) internal {
        vm.record();
        vm.prank(account);
        (bool ok, bytes memory ret) = address(pool)
            .call(
                abi.encodeCall(
                    IManagedDirectPropAMM.swapExactInput,
                    (PRIME_PAIR, true, UNIT, 0, ALPHA, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0)
                )
            );
        assertFalse(ok);
        assertEq(ret, err);
        (bytes32[] memory reads,) = vm.accesses(address(pool));
        assertGt(reads.length, 0, "recorded nothing");
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(reads[i] != slots[0] && reads[i] != slots[1], "read a list");
        }
    }

    function _denySlotReadBySwap(address account) internal returns (bool read) {
        vm.record();
        _sell(PRIME_PAIR, account, HOME);
        (bytes32[] memory reads,) = vm.accesses(address(pool));
        bytes32 slot = keccak256(abi.encode(account, SLOT_DENIED));
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i] == slot) read = true;
        }
    }

    function _notAllowed(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IManagedDirectPropAMM.TakerNotAllowed.selector, account);
    }

    function _admittedSlot(uint16 pairIndex, uint64 sponsorId) internal pure returns (bytes32) {
        return keccak256(abi.encode(sponsorId, keccak256(abi.encode(uint256(pairIndex), SLOT_ADMITTED))));
    }

    function _memberSlot(uint16 pairIndex, uint64 sponsorId, address account) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                account, keccak256(abi.encode(sponsorId, keccak256(abi.encode(uint256(pairIndex), SLOT_MEMBERS))))
            )
        );
    }
}
