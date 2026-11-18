// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { CoreDeploy } from "./utils/CoreDeploy.sol";
import { VirtualAddress } from "./utils/VirtualAddress.sol";

/// @notice The venue's access control: per pair, per sponsor, per user, `[pairIndex][sponsorId][account] -> listed`.
/// The owner registers sponsors under ids it chooses, switches them on and off and admits them pair by pair; each
/// sponsor's admin alone lists its users; sponsor 0 is the owner's own home list; a venue-wide deny list sits above
/// every list. Fills pay their taker and name the sponsor they trade under.
/// @dev The venue calls nothing for access, so the suite runs the same with or without `--network tempo`.
contract VenueAccessTest is Test {
    uint64 internal constant UNIT = 1e6;
    uint96 internal constant MID = 1.085e18;
    uint128 internal constant AMOUNT = 1e6;
    bytes32 internal constant REF = keccak256("access");
    uint256 internal constant MAX_BATCH = 100;
    /// @dev The `sponsorId` that names the venue's home list.
    uint64 internal constant HOME = 0;
    /// @dev The sponsors the suite registers: `ALPHA` (admin `alpha`) in `setUp`, `BETA` (admin `beta`) where needed.
    uint64 internal constant ALPHA = 7;
    uint64 internal constant BETA = 9;
    // Storage slots, from `forge inspect Venue storageLayout`.
    uint256 internal constant SLOT_OWNER = 0;
    uint256 internal constant SLOT_SETTLER = 1;
    uint256 internal constant SLOT_PAIRS = 4;
    uint256 internal constant SLOT_DENIED = 9;
    uint256 internal constant SLOT_SPONSORS = 10;
    uint256 internal constant SLOT_ADMITTED = 12;
    uint256 internal constant SLOT_MEMBERS = 13;
    /// @dev Bit offsets: the band count after `owner` and `pairCount`; `halted` and the deny count after `settler`.
    uint256 internal constant BANDED_PAIRS_SHIFT = 176;
    uint256 internal constant HALTED_SHIFT = 160;
    uint256 internal constant DENIED_COUNT_SHIFT = 168;

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal settler = makeAddr("settler");
    address internal stranger = makeAddr("stranger");
    /// @dev On the home list in most tests.
    address internal taker = makeAddr("taker");
    /// @dev On `ALPHA`'s list in most tests.
    address internal member = makeAddr("member");
    /// @dev The admin keys of `ALPHA` and `BETA`.
    address internal alpha = makeAddr("alpha");
    address internal beta = makeAddr("beta");

    VenueFactory internal factory;
    Venue internal venue;
    MockTIP20V2 internal eur;
    MockTIP20V2 internal usd;
    uint16 internal pairId;

    function setUp() external {
        vm.warp(1_800_000_000);
        factory = CoreDeploy.factoryWith(settler);
        venue = Venue(factory.createVenue(owner, "access"));
        eur = new MockTIP20V2("EURC", 6);
        usd = new MockTIP20V2("USDC", 6);
        pairId = _livePair();
        _setAccess(pairId, IVenue.AccessMode.Listed);
        vm.startPrank(owner);
        venue.setUpdater(updater, true);
        venue.addSponsor(ALPHA, alpha);
        venue.setPairSponsor(pairId, ALPHA, true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- the home list (sponsor 0)

    function test_ownerListsAndDelistsOnTheHomeList() external {
        assertEq(venue.MAX_BATCH(), MAX_BATCH);
        assertFalse(venue.takerAllowed(pairId, taker, HOME), "starts empty");
        assertTrue(venue.pairSponsor(pairId, HOME), "every live pair admits the home list");
        _listHome(taker);
        assertTrue(venue.isMember(pairId, HOME, taker));
        _fillAs(taker, HOME);
        vm.prank(owner);
        venue.setMembers(pairId, HOME, _one(taker), false);
        assertFalse(venue.isMember(pairId, HOME, taker));
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker), taker, HOME);
    }

    function test_onlyTheOwnerEditsTheHomeList() external {
        address[4] memory notOwner = [updater, stranger, alpha, settler];
        for (uint256 i; i < notOwner.length; ++i) {
            vm.prank(notOwner[i]);
            vm.expectRevert(IVenue.NotOwner.selector);
            venue.setMembers(pairId, HOME, _one(taker), true);
            vm.prank(notOwner[i]);
            vm.expectRevert(IVenue.NotOwner.selector);
            venue.setMembers(pairId, HOME, _one(taker), false);
        }
    }

    /// @dev Only the current owner edits the home list, so control of it moves with `acceptOwnership`.
    function test_homeListControlFollowsOwnership() external {
        _listHome(taker);
        address next = makeAddr("next owner");
        vm.prank(owner);
        venue.transferOwnership(next);
        vm.prank(next);
        venue.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.setMembers(pairId, HOME, _one(stranger), true);
        vm.prank(next);
        venue.setMembers(pairId, HOME, _one(taker), false);
        assertFalse(venue.isMember(pairId, HOME, taker));
    }

    // ---------------------------------------------------------------- registering sponsors

    function test_addSponsorRegistersItEnabledAndAdmittedNowhere() external {
        vm.expectEmit(address(venue));
        emit IVenue.SponsorAdded(BETA, beta);
        vm.prank(owner);
        venue.addSponsor(BETA, beta);
        (address admin, bool enabled, uint32 generation) = venue.sponsor(BETA);
        assertEq(admin, beta);
        assertTrue(enabled);
        assertEq(generation, 1);
        assertFalse(venue.pairSponsor(pairId, BETA), "admitted on no pair");
        assertEq(venue.pendingSponsorAdmin(BETA), address(0));
        // The owner chooses ids, so any nonzero id works, the largest included.
        vm.prank(owner);
        venue.addSponsor(type(uint64).max, beta);
        (admin,,) = venue.sponsor(type(uint64).max);
        assertEq(admin, beta, "one key may serve several ids");
    }

    function test_addSponsorValidation() external {
        vm.prank(updater);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.addSponsor(BETA, beta);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SponsorExists.selector, HOME));
        venue.addSponsor(HOME, beta);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SponsorExists.selector, ALPHA));
        venue.addSponsor(ALPHA, beta);
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.addSponsor(BETA, address(0));
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.addSponsor(BETA, address(venue));
        // A TIP-1022 virtual address never sends a call, so it could never list anyone.
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.addSponsor(BETA, VirtualAddress.make(0x12345678, 1));
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.addSponsor(BETA, VirtualAddress.make(0, 0));
        vm.stopPrank();
        (address admin,,) = venue.sponsor(ALPHA);
        assertEq(admin, alpha, "a registered id keeps its admin");
        // One byte off the layout is an ordinary account.
        address ordinary = address(uint160(VirtualAddress.make(0x12345678, 1)) ^ (uint160(1) << 48));
        vm.prank(owner);
        venue.addSponsor(BETA, ordinary);
        (admin,,) = venue.sponsor(BETA);
        assertEq(admin, ordinary);
    }

    /// @dev The owner switches a sponsor either way; an updater only off. Off stops every fill under it and every
    /// listing, but keeps its lists, so switching it back on restores them.
    function test_switchingASponsorOffStopsItsFillsAndOnRestoresThem() external {
        _listAlpha(member);
        _fillAs(member, ALPHA);
        vm.expectEmit(address(venue));
        emit IVenue.SponsorEnabledSet(ALPHA, false, updater);
        vm.prank(updater);
        venue.setSponsorEnabled(ALPHA, false);
        _expectFillRevert(abi.encodeWithSelector(IVenue.SponsorDisabled.selector, ALPHA), member, ALPHA);
        assertFalse(venue.takerAllowed(pairId, member, ALPHA));
        assertTrue(venue.isMember(pairId, ALPHA, member), "the list is kept");
        // While off it can't list, but it can still delist.
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SponsorDisabled.selector, ALPHA));
        venue.setMembers(pairId, ALPHA, _one(stranger), true);
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(stranger), false);

        vm.prank(updater);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.setSponsorEnabled(ALPHA, true);
        vm.prank(stranger);
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        venue.setSponsorEnabled(ALPHA, false);
        vm.prank(owner);
        venue.setSponsorEnabled(ALPHA, true);
        _fillAs(member, ALPHA);
    }

    /// @dev Admission is per pair: the owner admits and removes, an updater only removes. Removal keeps the list, so
    /// admitting again restores every member.
    function test_removingASponsorFromAPairStopsItThereAndReadmittingRestoresIt() external {
        uint16 second = _livePair();
        _setAccess(second, IVenue.AccessMode.Listed);
        vm.prank(owner);
        venue.setPairSponsor(second, ALPHA, true);
        _listAlpha(member);
        vm.prank(alpha);
        venue.setMembers(second, ALPHA, _one(member), true);

        vm.expectEmit(address(venue));
        emit IVenue.PairSponsorSet(pairId, ALPHA, false, updater);
        vm.prank(updater);
        venue.setPairSponsor(pairId, ALPHA, false);
        _expectFillRevert(abi.encodeWithSelector(IVenue.SponsorNotAdmitted.selector, pairId, ALPHA), member, ALPHA);
        _fillOn(second, member, ALPHA);
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SponsorNotAdmitted.selector, pairId, ALPHA));
        venue.setMembers(pairId, ALPHA, _one(stranger), true);

        vm.prank(updater);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.setPairSponsor(pairId, ALPHA, true);
        // The removal kept the admission's slot nonzero, so readmitting rewrites it rather than creating it again.
        assertEq(uint256(vm.load(address(venue), _admittedSlot(pairId, ALPHA))), 2, "removed, slot kept");
        vm.prank(owner);
        venue.setPairSponsor(pairId, ALPHA, true);
        assertEq(uint256(vm.load(address(venue), _admittedSlot(pairId, ALPHA))), 1, "admitted again");
        _fillAs(member, ALPHA);

        // Removing a sponsor never admitted on a pair writes nothing.
        uint16 third = _livePair();
        vm.record();
        vm.prank(updater);
        venue.setPairSponsor(third, ALPHA, false);
        (, bytes32[] memory writes) = vm.accesses(address(venue));
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(writes[i] != _admittedSlot(third, ALPHA), "no write for a sponsor never admitted");
        }
        assertFalse(venue.pairSponsor(third, ALPHA));
    }

    function test_switchesNeedARegisteredSponsor() external {
        uint64[2] memory unknown = [HOME, BETA];
        for (uint256 i; i < unknown.length; ++i) {
            vm.startPrank(owner);
            vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownSponsor.selector, unknown[i]));
            venue.setSponsorEnabled(unknown[i], true);
            vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownSponsor.selector, unknown[i]));
            venue.setPairSponsor(pairId, unknown[i], true);
            vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownSponsor.selector, unknown[i]));
            venue.resetSponsor(unknown[i], beta);
            vm.stopPrank();
        }
        // Admission needs a live pair; removal doesn't.
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(77)));
        venue.setPairSponsor(77, ALPHA, true);
        venue.setPairSponsor(77, ALPHA, false);
        vm.stopPrank();
    }

    /// @dev Every switch emits on every call, even when nothing changes, and writes only real changes.
    function test_switchesEmitEveryCall() external {
        vm.recordLogs();
        vm.startPrank(owner);
        venue.setSponsorEnabled(ALPHA, true);
        venue.setPairSponsor(pairId, ALPHA, true);
        vm.stopPrank();
        assertEq(_logsFrom(address(venue)), 2);
        (, bool enabled,) = venue.sponsor(ALPHA);
        assertTrue(enabled);
        assertTrue(venue.pairSponsor(pairId, ALPHA));
    }

    // ---------------------------------------------------------------- a sponsor's own lists

    /// @dev Only the sponsor's admin lists or delists under its id: not the owner, an updater or another sponsor.
    function test_onlyTheSponsorAdminEditsItsList() external {
        vm.startPrank(owner);
        venue.addSponsor(BETA, beta);
        venue.setPairSponsor(pairId, BETA, true);
        vm.stopPrank();
        address[4] memory others = [owner, updater, beta, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, ALPHA));
            venue.setMembers(pairId, ALPHA, _one(member), true);
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, ALPHA));
            venue.setMembers(pairId, ALPHA, _one(member), false);
        }
        // An unregistered id has no admin, so nobody edits it.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, uint64(42)));
        venue.setMembers(pairId, 42, _one(member), true);

        _listAlpha(member);
        assertTrue(venue.isMember(pairId, ALPHA, member));
        assertFalse(venue.isMember(pairId, BETA, member), "one sponsor's listing is its own");
    }

    /// @dev A fill names one sponsor and reads only that sponsor's list: a user one sponsor lists can't trade under
    /// another's id or the home list, and the reverse.
    function test_aFillReadsOnlyTheNamedList() external {
        vm.startPrank(owner);
        venue.addSponsor(BETA, beta);
        venue.setPairSponsor(pairId, BETA, true);
        vm.stopPrank();
        _listAlpha(member);
        _listHome(taker);

        _fillAs(member, ALPHA);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member), member, BETA);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member), member, HOME);
        _fillAs(taker, HOME);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker), taker, ALPHA);

        // Listed by both, a user trades under either, and each fill records the one it named.
        vm.prank(beta);
        venue.setMembers(pairId, BETA, _one(member), true);
        _fillEmitting(member, ALPHA);
        _fillEmitting(member, BETA);
        // Delisted by one, it still trades under the other.
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(member), false);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member), member, ALPHA);
        _fillAs(member, BETA);
    }

    /// @dev Lists are per pair: a listing on one pair admits nothing on another, even where the sponsor is admitted.
    function test_listsArePerPair() external {
        uint16 second = _livePair();
        _setAccess(second, IVenue.AccessMode.Listed);
        vm.prank(owner);
        venue.setPairSponsor(second, ALPHA, true);
        _listAlpha(member);
        _listHome(taker);
        assertTrue(venue.takerAllowed(pairId, member, ALPHA));
        assertFalse(venue.takerAllowed(second, member, ALPHA));
        assertFalse(venue.takerAllowed(second, taker, HOME));
        vm.prank(alpha);
        venue.setMembers(second, ALPHA, _one(member), true);
        _fillOn(second, member, ALPHA);
    }

    /// @dev The order `fill` checks a `Listed` fill under a sponsor: registered, enabled, admitted on the pair, then
    /// the member.
    function test_listedCheckOrder() external {
        _expectFillRevert(abi.encodeWithSelector(IVenue.UnknownSponsor.selector, BETA), member, BETA);
        vm.prank(owner);
        venue.addSponsor(BETA, beta);
        vm.prank(owner);
        venue.setSponsorEnabled(BETA, false);
        _expectFillRevert(abi.encodeWithSelector(IVenue.SponsorDisabled.selector, BETA), member, BETA);
        vm.prank(owner);
        venue.setSponsorEnabled(BETA, true);
        _expectFillRevert(abi.encodeWithSelector(IVenue.SponsorNotAdmitted.selector, pairId, BETA), member, BETA);
        vm.prank(owner);
        venue.setPairSponsor(pairId, BETA, true);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member), member, BETA);
        vm.prank(beta);
        venue.setMembers(pairId, BETA, _one(member), true);
        _fillAs(member, BETA);
    }

    function test_setMembersValidation() external {
        vm.startPrank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.BatchTooLarge.selector, 101, 100));
        venue.setMembers(pairId, ALPHA, new address[](101), true);
        address[] memory accounts = new address[](2);
        accounts[0] = member;
        address[2] memory invalid = [address(0), address(venue)];
        for (uint256 i; i < invalid.length; ++i) {
            accounts[1] = invalid[i];
            vm.expectRevert(IVenue.InvalidAddress.selector);
            venue.setMembers(pairId, ALPHA, accounts, true);
        }
        vm.stopPrank();
        assertFalse(venue.isMember(pairId, ALPHA, member), "atomic");

        // A listing needs a live pair; a delisting doesn't, for a sponsor or the home list.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(77)));
        venue.setMembers(77, HOME, _one(member), true);
        vm.prank(owner);
        venue.setMembers(77, HOME, _one(member), false);
        vm.prank(alpha);
        venue.setMembers(77, ALPHA, _one(member), false);
    }

    /// @dev A removed pair hides its retained lists and admissions, and nobody can list on it.
    function test_removedPairHidesRetainedListsAndAdmissions() external {
        _listHome(taker);
        _listAlpha(member);
        vm.prank(owner);
        venue.removePair(pairId);
        assertFalse(venue.pairSponsor(pairId, HOME));
        assertFalse(venue.pairSponsor(pairId, ALPHA));
        assertFalse(venue.isMember(pairId, HOME, taker));
        assertFalse(venue.isMember(pairId, ALPHA, member));
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, pairId));
        venue.setMembers(pairId, ALPHA, _one(member), true);
        assertFalse(venue.takerAllowed(pairId, member, ALPHA));
    }

    /// @dev `setMembers` emits one `MemberUpdated` per entry, no-ops included, and writes only real changes.
    function test_setMembersEmitsEveryEntry() external {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (member, taker, member);
        vm.recordLogs();
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, accounts, true);
        assertEq(_logsFrom(address(venue)), 3, "one MemberUpdated per entry");
        vm.expectEmit(address(venue));
        emit IVenue.MemberUpdated(pairId, ALPHA, taker, false);
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(taker), false);
        assertTrue(venue.isMember(pairId, ALPHA, member));
        assertFalse(venue.isMember(pairId, ALPHA, taker));
        // A no-op write leaves the slot alone.
        vm.record();
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(member), true);
        (, bytes32[] memory writes) = vm.accesses(address(venue));
        bytes32 slot = _memberSlot(pairId, ALPHA, member);
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(writes[i] != slot, "no rewrite of an unchanged member");
        }
    }

    // ---------------------------------------------------------------- handing a sponsor's lists to a new key

    function test_sponsorAdminHandsItsListsOnInTwoSteps() external {
        _listAlpha(member);
        address next = makeAddr("next key");
        vm.expectEmit(address(venue));
        emit IVenue.SponsorAdminTransferStarted(ALPHA, alpha, next);
        vm.prank(alpha);
        venue.transferSponsorAdmin(ALPHA, next);
        assertEq(venue.pendingSponsorAdmin(ALPHA), next);
        // Until it accepts, the old key still edits.
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(taker), true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotPendingSponsorAdmin.selector, ALPHA));
        venue.acceptSponsorAdmin(ALPHA);

        vm.expectEmit(address(venue));
        emit IVenue.SponsorAdminTransferred(ALPHA, alpha, next);
        vm.prank(next);
        venue.acceptSponsorAdmin(ALPHA);
        (address admin, bool enabled, uint32 generation) = venue.sponsor(ALPHA);
        assertEq(admin, next);
        assertTrue(enabled);
        assertEq(generation, 1, "a handover keeps the list");
        assertEq(venue.pendingSponsorAdmin(ALPHA), address(0));
        assertTrue(venue.isMember(pairId, ALPHA, member), "the list moves with the key");
        _fillAs(member, ALPHA);

        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, ALPHA));
        venue.setMembers(pairId, ALPHA, _one(stranger), true);
        vm.prank(next);
        venue.setMembers(pairId, ALPHA, _one(member), false);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotPendingSponsorAdmin.selector, ALPHA));
        venue.acceptSponsorAdmin(ALPHA);
    }

    /// @dev Only the sponsor's admin starts a handover; zero, the venue and virtual addresses cannot be nominated.
    function test_handoverValidation() external {
        address[3] memory notAdmin = [owner, updater, stranger];
        for (uint256 i; i < notAdmin.length; ++i) {
            vm.prank(notAdmin[i]);
            vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, ALPHA));
            venue.transferSponsorAdmin(ALPHA, notAdmin[i]);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, HOME));
        venue.transferSponsorAdmin(HOME, stranger);
        vm.prank(alpha);
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.transferSponsorAdmin(ALPHA, address(venue));
        vm.prank(alpha);
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.transferSponsorAdmin(ALPHA, VirtualAddress.make(0x12345678, 1));

        vm.prank(alpha);
        venue.transferSponsorAdmin(ALPHA, stranger);
        vm.prank(alpha);
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.transferSponsorAdmin(ALPHA, address(0));
        assertEq(venue.pendingSponsorAdmin(ALPHA), stranger, "invalid nomination preserves the handover");
        vm.prank(alpha);
        venue.cancelSponsorAdminTransfer(ALPHA);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotPendingSponsorAdmin.selector, ALPHA));
        venue.acceptSponsorAdmin(ALPHA);
    }

    function test_sponsorAdminCancellationPreservesListsAndOnlyCurrentAdminCanCancel() external {
        _listAlpha(member);
        vm.prank(owner);
        venue.addSponsor(BETA, beta);
        vm.prank(beta);
        venue.transferSponsorAdmin(BETA, member);
        vm.prank(alpha);
        venue.transferSponsorAdmin(ALPHA, stranger);
        address[4] memory notAdmin = [owner, updater, stranger, beta];
        for (uint256 i; i < notAdmin.length; ++i) {
            vm.prank(notAdmin[i]);
            vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, ALPHA));
            venue.cancelSponsorAdminTransfer(ALPHA);
            assertEq(venue.pendingSponsorAdmin(ALPHA), stranger);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, HOME));
        venue.cancelSponsorAdminTransfer(HOME);
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, uint64(99)));
        venue.cancelSponsorAdminTransfer(99);

        // Disabling the sponsor does not stop its current admin from revoking a pending handover.
        vm.prank(owner);
        venue.setSponsorEnabled(ALPHA, false);
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(address(venue));
            emit IVenue.SponsorAdminTransferStarted(ALPHA, alpha, address(0));
            vm.prank(alpha);
            venue.cancelSponsorAdminTransfer(ALPHA);
            assertEq(venue.pendingSponsorAdmin(ALPHA), address(0));
        }
        assertEq(venue.pendingSponsorAdmin(BETA), member, "other sponsor's handover stays pending");
        (address admin, bool enabled, uint32 generation) = venue.sponsor(ALPHA);
        assertEq(admin, alpha);
        assertFalse(enabled);
        assertEq(generation, 1);
        assertTrue(venue.isMember(pairId, ALPHA, member));
        assertTrue(venue.pairSponsor(pairId, ALPHA));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotPendingSponsorAdmin.selector, ALPHA));
        venue.acceptSponsorAdmin(ALPHA);

        vm.prank(alpha);
        venue.transferSponsorAdmin(ALPHA, stranger);
        vm.prank(stranger);
        venue.acceptSponsorAdmin(ALPHA);
        vm.prank(stranger);
        venue.transferSponsorAdmin(ALPHA, beta);
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, ALPHA));
        venue.cancelSponsorAdminTransfer(ALPHA);
        assertEq(venue.pendingSponsorAdmin(ALPHA), beta);
        vm.prank(stranger);
        venue.cancelSponsorAdminTransfer(ALPHA);
        assertEq(venue.pendingSponsorAdmin(ALPHA), address(0));
        assertTrue(venue.isMember(pairId, ALPHA, member));
    }

    // ---------------------------------------------------------------- resetting a sponsor that lost its key

    /// @dev The owner can give a sponsor a new admin, but only with an empty list: every earlier listing stops at
    /// once, so the owner never takes over a sponsor's list. The id, its switch and its admissions are kept.
    function test_resetVoidsTheOldListAndKeepsTheIdSwitchAndAdmissions() external {
        _listAlpha(member);
        vm.prank(alpha);
        venue.transferSponsorAdmin(ALPHA, stranger);
        address fresh = makeAddr("fresh key");
        vm.expectEmit(address(venue));
        emit IVenue.SponsorReset(ALPHA, alpha, fresh, 2);
        vm.prank(owner);
        venue.resetSponsor(ALPHA, fresh);

        (address admin, bool enabled, uint32 generation) = venue.sponsor(ALPHA);
        assertEq(admin, fresh);
        assertTrue(enabled);
        assertEq(generation, 2);
        assertEq(venue.pendingSponsorAdmin(ALPHA), address(0), "the reset cancels a handover");
        assertTrue(venue.pairSponsor(pairId, ALPHA));
        assertFalse(venue.isMember(pairId, ALPHA, member), "the old list is void");
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member), member, ALPHA);
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, ALPHA));
        venue.setMembers(pairId, ALPHA, _one(member), true);

        // The new key lists again, rewriting the old slot rather than creating one.
        uint256 stale = uint256(vm.load(address(venue), _memberSlot(pairId, ALPHA, member)));
        assertEq(stale, 1, "the old listing stays in its slot");
        vm.prank(fresh);
        venue.setMembers(pairId, ALPHA, _one(member), true);
        assertEq(uint256(vm.load(address(venue), _memberSlot(pairId, ALPHA, member))), 2);
        _fillAs(member, ALPHA);
    }

    function test_resetValidation() external {
        vm.prank(updater);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.resetSponsor(ALPHA, beta);
        vm.prank(alpha);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.resetSponsor(ALPHA, beta);
        vm.startPrank(owner);
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.resetSponsor(ALPHA, address(0));
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.resetSponsor(ALPHA, address(venue));
        vm.expectRevert(IVenue.InvalidAddress.selector);
        venue.resetSponsor(ALPHA, VirtualAddress.make(0x12345678, 1));
        vm.stopPrank();
        // A stale listing can still be cleared.
        _listAlpha(member);
        vm.prank(owner);
        venue.resetSponsor(ALPHA, beta);
        vm.prank(beta);
        venue.setMembers(pairId, ALPHA, _one(member), false);
        assertEq(uint256(vm.load(address(venue), _memberSlot(pairId, ALPHA, member))), 0);
    }

    // ---------------------------------------------------------------- access modes

    function test_openIgnoresTheSponsorAndReadsNoList() external {
        _setAccess(pairId, IVenue.AccessMode.Open);
        bytes32 sponsorSlot = keccak256(abi.encode(BETA, SLOT_SPONSORS));
        vm.record();
        _fillAs(stranger, HOME);
        _fillAs(stranger, BETA);
        _fillAs(stranger, type(uint64).max);
        (bytes32[] memory reads,) = vm.accesses(address(venue));
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(reads[i] != sponsorSlot && reads[i] != _memberSlot(pairId, BETA, stranger), "no list read");
        }
        assertTrue(venue.takerAllowed(pairId, stranger, type(uint64).max));
    }

    function test_closedRejectsEveryoneAndReadsNoList() external {
        _listAlpha(member);
        vm.prank(updater);
        venue.closePair(pairId);
        vm.record();
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member), member, ALPHA);
        (bytes32[] memory reads,) = vm.accesses(address(venue));
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(reads[i] != _memberSlot(pairId, ALPHA, member), "no list read");
        }
        assertFalse(venue.takerAllowed(pairId, member, ALPHA));
    }

    // ---------------------------------------------------------------- the deny list

    function test_denyOverridesEveryListAndOpen() external {
        _listAlpha(taker);
        _listHome(taker);
        vm.prank(owner);
        venue.setDenied(_one(taker), true);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerDenied.selector, taker), taker, HOME);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerDenied.selector, taker), taker, ALPHA);
        // The deny list comes before the sponsor checks.
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerDenied.selector, taker), taker, BETA);
        _setAccess(pairId, IVenue.AccessMode.Open);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerDenied.selector, taker), taker, HOME);
        assertFalse(venue.takerAllowed(pairId, taker, HOME));
        _fillAs(stranger, HOME);
    }

    function test_updaterDeniesButOnlyOwnerLifts() external {
        _listHome(taker);
        vm.prank(updater);
        venue.setDenied(_one(taker), true);
        assertTrue(venue.denied(taker));
        vm.prank(updater);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.setDenied(_one(taker), false);
        vm.prank(stranger);
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        venue.setDenied(_one(member), true);
        vm.prank(alpha);
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        venue.setDenied(_one(member), true);
        vm.prank(owner);
        venue.setDenied(_one(taker), false);
        _fillAs(taker, HOME);
    }

    function test_setDeniedValidation() external {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.BatchTooLarge.selector, 101, 100));
        venue.setDenied(new address[](101), true);
        address[] memory accounts = new address[](2);
        accounts[0] = stranger;
        address[2] memory invalid = [address(0), address(venue)];
        for (uint256 i; i < invalid.length; ++i) {
            accounts[1] = invalid[i];
            vm.expectRevert(IVenue.InvalidAddress.selector);
            venue.setDenied(accounts, true);
        }
        vm.stopPrank();
        assertFalse(venue.denied(stranger), "atomic");
        assertEq(venue.deniedCount(), 0);
    }

    function test_setDeniedCountsExactlyAndEmitsChangedEntries() external {
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (taker, member, taker);
        vm.recordLogs();
        vm.prank(owner);
        venue.setDenied(accounts, true);
        assertEq(_logsFrom(address(venue)), 2, "one DenyUpdated per state transition");
        assertEq(venue.deniedCount(), 2);
        vm.expectEmit(address(venue));
        emit IVenue.DenyUpdated(member, false, owner);
        vm.prank(owner);
        venue.setDenied(_one(member), false);
        assertEq(venue.deniedCount(), 1);
        vm.prank(owner);
        venue.setDenied(_one(member), false);
        assertEq(venue.deniedCount(), 1, "a no-op lift changes nothing");
        vm.recordLogs();
        vm.prank(owner);
        venue.setDenied(_one(member), false);
        assertEq(_logsFrom(address(venue)), 0, "a no-op lift emits nothing");

        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(updater);
        venue.setDenied(_one(member), false);
    }

    /// @dev While `deniedCount` is zero a fill reads no deny slot; a denial anywhere makes every fill read its taker's.
    function test_emptyDenyListReadsNoDenySlot() external {
        _listHome(taker);
        assertFalse(_denySlotReadByFill(taker), "empty");
        vm.prank(owner);
        venue.setDenied(_one(stranger), true);
        assertTrue(_denySlotReadByFill(taker), "someone denied");
        vm.prank(owner);
        venue.setDenied(_one(stranger), false);
        assertFalse(_denySlotReadByFill(taker), "lifted");
    }

    // ---------------------------------------------------------------- views, events and layout

    /// @dev `takerAllowed` agrees with `fill` across modes, lists, switches, admissions, resets and denials.
    function test_takerAllowedMatchesFill() external {
        vm.startPrank(owner);
        venue.addSponsor(BETA, beta);
        vm.stopPrank();
        _listAlpha(member);
        _listHome(taker);
        address[3] memory who = [taker, member, stranger];
        uint64[4] memory ids = [HOME, ALPHA, BETA, uint64(42)];
        for (uint256 step; step < 7; ++step) {
            vm.startPrank(owner);
            if (step == 1) venue.setPairSponsor(pairId, BETA, true);
            else if (step == 2) venue.setSponsorEnabled(ALPHA, false);
            else if (step == 3) venue.setDenied(_one(taker), true);
            else if (step == 4) venue.resetSponsor(ALPHA, stranger);
            vm.stopPrank();
            if (step == 5) _setAccess(pairId, IVenue.AccessMode.Open);
            if (step == 6) {
                vm.prank(owner);
                venue.closePair(pairId);
            }
            for (uint256 w; w < who.length; ++w) {
                for (uint256 i; i < ids.length; ++i) {
                    bool allowed = venue.takerAllowed(pairId, who[w], ids[i]);
                    eur.mint(address(venue), AMOUNT);
                    vm.prank(settler);
                    (bool ok,) = address(venue)
                        .call(
                            abi.encodeCall(
                                IVenue.fill, (pairId, address(eur), address(usd), AMOUNT, true, who[w], ids[i], REF)
                            )
                        );
                    assertEq(ok, allowed, "takerAllowed predicts fill");
                }
            }
        }
        assertFalse(venue.takerAllowed(77, taker, HOME), "an unknown pair admits no one");
    }

    function test_fillCarriesTheSponsorId() external {
        _listAlpha(member);
        _listHome(taker);
        _fillEmitting(taker, HOME);
        _fillEmitting(member, ALPHA);
        // On an Open pair it is the taker's unchecked claim.
        _setAccess(pairId, IVenue.AccessMode.Open);
        _fillEmitting(stranger, 4242);
    }

    /// @dev `settler`, `halted` and `deniedCount` share one slot, which `fill` reads in its first check, so a fill
    /// reads no other venue-wide slot (the owner's holds only `owner`, `pairCount` and the band count); a pair's access
    /// mode shares its first config slot with the base token; a sponsor is one slot, and a member's slot holds the
    /// generation it was listed in.
    function test_accessWordLayout() external {
        uint256 word = uint256(vm.load(address(venue), bytes32(SLOT_SETTLER)));
        assertEq(address(uint160(word)), settler, "settler");
        assertEq((word >> HALTED_SHIFT) & 0xff, 0, "halted");
        assertEq(word >> DENIED_COUNT_SHIFT, 0, "deniedCount");
        address[] memory accounts = _accounts(3);
        vm.prank(owner);
        venue.setDenied(accounts, true);
        vm.prank(updater);
        venue.setHalted(true);
        word = uint256(vm.load(address(venue), bytes32(SLOT_SETTLER)));
        assertEq(word >> DENIED_COUNT_SHIFT, 3, "deniedCount");
        assertEq((word >> HALTED_SHIFT) & 0xff, 1, "halted");
        assertEq(address(uint160(word)), settler, "settler beside the count");
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(uint256(vm.load(address(venue), keccak256(abi.encode(accounts[i], SLOT_DENIED)))), 1, "denied");
        }
        uint256 ownerWord = uint256(vm.load(address(venue), bytes32(SLOT_OWNER)));
        assertEq(address(uint160(ownerWord)), owner, "owner");
        assertEq(ownerWord >> (BANDED_PAIRS_SHIFT + 16), 0, "nothing after the band count");

        bytes32 pairSlot = keccak256(abi.encode(uint256(pairId), SLOT_PAIRS));
        uint256 config = uint256(vm.load(address(venue), pairSlot));
        assertEq(address(uint160(config)), address(eur), "base");
        assertEq(config >> 160, uint256(IVenue.AccessMode.Listed), "access beside the base");

        uint256 sponsorWord = uint256(vm.load(address(venue), keccak256(abi.encode(ALPHA, SLOT_SPONSORS))));
        assertEq(address(uint160(sponsorWord)), alpha, "admin");
        assertEq((sponsorWord >> 160) & 0xff, 1, "enabled beside the admin");
        assertEq(sponsorWord >> 168, 1, "generation beside the switch");
        assertEq(uint256(vm.load(address(venue), _admittedSlot(pairId, ALPHA))), 1, "admitted");
        _listHome(taker);
        assertEq(uint256(vm.load(address(venue), _memberSlot(pairId, HOME, taker))), 1, "a home member stores 1");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A new EUR/USD pair with a deep flat ladder, a long-lived hot word and inventory. It starts `Closed`.
    function _livePair() internal returns (uint16 index) {
        uint32[] memory sizes = new uint32[](1);
        uint16[] memory spreads = new uint16[](1);
        (sizes[0], spreads[0]) = (1_000_000, 10);
        uint256[4] memory words;
        (words[0],) = ShapeWord.packSide(sizes, spreads);
        words[2] = words[0];
        vm.startPrank(owner);
        index = venue.addPair(address(eur), address(usd), UNIT);
        venue.setShape(index, 0, words);
        venue.post(
            abi.encodePacked(
                index,
                HotWord.pack(
                    HotWord.Fields({
                        mid: MID,
                        bidWiden: 0,
                        askWiden: 0,
                        widthScale: 1000,
                        depthScale: 1000,
                        shapeId: 0,
                        validUntil: uint40(block.timestamp + 30 days),
                        seq: 2,
                        flags: 0
                    })
                )
            )
        );
        vm.stopPrank();
        eur.mint(address(venue), 1_000_000e6);
        usd.mint(address(venue), 1_000_000e6);
    }

    function _setAccess(uint16 pairIndex, IVenue.AccessMode mode) internal {
        bool halted = venue.halted();
        vm.startPrank(owner);
        if (mode == IVenue.AccessMode.Open && !halted) venue.setHalted(true);
        venue.setPairAccess(pairIndex, mode);
        if (mode == IVenue.AccessMode.Open && !halted) venue.setHalted(false);
        vm.stopPrank();
    }

    function _listHome(address account) internal {
        vm.prank(owner);
        venue.setMembers(pairId, HOME, _one(account), true);
    }

    function _listAlpha(address account) internal {
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(account), true);
    }

    function _fillAs(address taker_, uint64 sponsorId) internal returns (uint128 amountOut) {
        return _fillOn(pairId, taker_, sponsorId);
    }

    /// @dev Moves the input in as the settler does, fills as the settler and requires the taker to be paid.
    function _fillOn(uint16 pairIndex, address taker_, uint64 sponsorId) internal returns (uint128 amountOut) {
        eur.mint(address(venue), AMOUNT);
        uint256 before = usd.balanceOf(taker_);
        vm.prank(settler);
        (, amountOut) = venue.fill(pairIndex, address(eur), address(usd), AMOUNT, true, taker_, sponsorId, REF);
        assertEq(usd.balanceOf(taker_), before + amountOut, "the taker is paid");
    }

    function _expectFillRevert(bytes memory err, address taker_, uint64 sponsorId) internal {
        eur.mint(address(venue), AMOUNT);
        vm.prank(settler);
        vm.expectRevert(err);
        venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker_, sponsorId, REF);
    }

    /// @dev Fills and requires its `Fill` event, topics and `sponsorId` included.
    function _fillEmitting(address taker_, uint64 sponsorId) internal {
        (uint128 amountIn, uint128 amountOut) = venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
        bytes32 hot = venue.hotWord(pairId);
        eur.mint(address(venue), AMOUNT);
        vm.expectEmit(address(venue));
        emit IVenue.Fill(pairId, taker_, REF, sponsorId, true, amountIn, amountOut, HotWord.mid(hot), HotWord.seq(hot));
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker_, sponsorId, REF);
    }

    /// @dev Whether a fill for `taker_` under the home list reads its deny slot.
    function _denySlotReadByFill(address taker_) internal returns (bool read) {
        eur.mint(address(venue), AMOUNT);
        vm.record();
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker_, HOME, REF);
        (bytes32[] memory reads,) = vm.accesses(address(venue));
        bytes32 slot = keccak256(abi.encode(taker_, SLOT_DENIED));
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i] == slot) read = true;
        }
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

    function _logsFrom(address emitter) internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++n;
        }
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _accounts(uint256 n) internal pure returns (address[] memory accounts) {
        accounts = new address[](n);
        for (uint256 i; i < n; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode("account", i)))));
        }
    }
}
