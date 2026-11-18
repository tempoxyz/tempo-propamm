// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { IVenueHook, VenueHookFlags } from "../../../src/v2/interfaces/IVenueHook.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { MockVenueHook } from "../mocks/MockVenueHook.sol";
import { IntegrationFixture } from "./utils/IntegrationFixture.sol";

/// @notice The access model end to end, through the real Settler: each maker registers the sponsors it serves
/// under their shared ids and admits them pair by pair, each sponsor lists its own customers on each venue and pair,
/// each maker keeps its own home list and a deny list above them all, takers only swap for themselves, and each swap
/// names the sponsor it trades under. The directory registers venue A; the Settler fills any factory venue, so swaps
/// reach B and C too.
contract SponsorIntegrationTest is IntegrationFixture {
    address internal ops2 = makeAddr("ops2");
    /// @dev A second sponsor, its admin key and its customer.
    uint64 internal constant SPONSOR2 = 8;
    address internal sponsor2 = makeAddr("sponsor2");
    address internal customer2 = makeAddr("customer2");

    /// @dev Sells 100 EUR on venue A's pair under `sponsorId`.
    function _sell(address from, uint64 sponsorId) internal returns (uint256) {
        return _sellAt(venueA, pairA, from, sponsorId);
    }

    function _sellAt(Venue venue, uint16 pairIndex, address from, uint64 sponsorId) internal returns (uint256) {
        return _swapExactIn(from, address(eur), address(usd), _requestUnder(venue, pairIndex, 100e6, sponsorId), 0);
    }

    function _venues() internal view returns (Venue[3] memory venues, uint16[3] memory pairs) {
        venues = [venueA, venueB, venueC];
        pairs = [pairA, pairB, pairC];
    }

    /// @dev Every venue's pair to `Listed`, `accounts` on every pair's home list.
    function _listAllHome(address[] memory accounts) internal {
        _listHome(venueA, pairA, accounts);
        _listHome(venueB, pairB, accounts);
        _listHome(venueC, pairC, accounts);
    }

    /// @dev Every venue's pair to `Listed`, with `SPONSOR` registered and admitted on each.
    function _admitSponsorEverywhere() internal {
        (Venue[3] memory venues, uint16[3] memory pairs) = _venues();
        for (uint256 i; i < 3; ++i) {
            _setAccess(venues[i], pairs[i], IVenue.AccessMode.Listed);
            _admitSponsor(venues[i], pairs[i]);
        }
    }

    /// @dev `SPONSOR` lists `account` on every venue's pair: one call per venue.
    function _listSponsorEverywhere(address account) internal {
        (Venue[3] memory venues, uint16[3] memory pairs) = _venues();
        for (uint256 i; i < 3; ++i) {
            _listSponsor(venues[i], pairs[i], _one(account), true);
        }
    }

    function _ids(uint64 a) internal pure returns (uint64[] memory ids) {
        ids = new uint64[](1);
        ids[0] = a;
    }

    function _ids(uint64 a, uint64 b) internal pure returns (uint64[] memory ids) {
        ids = new uint64[](2);
        (ids[0], ids[1]) = (a, b);
    }

    /// @dev Requires venue A's pair to admit `who` under the first of `candidates` that admits it, as a router asks
    /// `takerAllowed` in its order of preference, and that id to be `sponsorId` (none when not `allowed`).
    function _assertAdmitted(address who, uint64[] memory candidates, bool allowed, uint64 sponsorId) internal view {
        bool found;
        uint64 id;
        for (uint256 i; i < candidates.length && !found; ++i) {
            if (venueA.takerAllowed(pairA, who, candidates[i])) (found, id) = (true, candidates[i]);
        }
        assertEq(found, allowed, "takerAllowed");
        assertEq(id, allowed ? sponsorId : 0, "sponsorId");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The maker's home list
    // ---------------------------------------------------------------------------------------------------------------

    function test_homeList_gatesTakersUnderSponsorZero() public {
        _listAllHome(_one(stranger));
        _assertAdmitted(taker, _ids(HOME), false, 0);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sell(taker, HOME);

        vm.prank(makerA);
        venueA.setMembers(pairA, HOME, _one(taker), true);
        _assertAdmitted(taker, _ids(HOME), true, HOME);
        uint256 before = usd.balanceOf(taker);
        uint256 out = _sell(taker, HOME);
        assertEq(usd.balanceOf(taker), before + out, "the taker is paid");
        // Each venue's home list is its own: B's doesn't list the taker.
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sellAt(venueB, pairB, taker, HOME);
        // Only A's owner edits A's home list.
        vm.prank(makerB);
        vm.expectRevert(IVenue.NotOwner.selector);
        venueA.setMembers(pairA, HOME, _one(stranger), false);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Sponsor lists
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A sponsor lists its customers itself, venue by venue: a listing on one venue admits nothing on another,
    /// and each edit applies from the next fill.
    function test_sponsor_listsItsCustomersOnEachVenueItServes() public {
        _admitSponsorEverywhere();
        _assertAdmitted(taker, _ids(SPONSOR), false, 0);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sell(taker, SPONSOR);

        _listSponsor(venueA, pairA, _one(taker), true);
        _assertAdmitted(taker, _ids(HOME, SPONSOR), true, SPONSOR);
        assertGt(_sell(taker, SPONSOR), 0);
        // Listed on A only: B rejects it until the sponsor lists it there too.
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sellAt(venueB, pairB, taker, SPONSOR);
        _listSponsor(venueB, pairB, _one(taker), true);
        assertGt(_sellAt(venueB, pairB, taker, SPONSOR), 0);
        // The taker isn't on any home list, so sponsor 0 still rejects it.
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sell(taker, HOME);

        // A delisting applies from the next fill, and a listing again after it.
        _listSponsor(venueA, pairA, _one(taker), false);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sell(taker, SPONSOR);
        _listSponsor(venueA, pairA, _one(taker), true);
        assertGt(_sell(taker, SPONSOR), 0);

        // Nobody else edits the sponsor's list: not the maker, not its updater.
        vm.prank(makerA);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, SPONSOR));
        venueA.setMembers(pairA, SPONSOR, _one(stranger), true);
        vm.prank(updaterA);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, SPONSOR));
        venueA.setMembers(pairA, SPONSOR, _one(taker), false);
    }

    /// @dev Each customer trades under its own sponsor's id, and a customer can't borrow another sponsor's id.
    function test_sponsors_areSeparate() public {
        _admitSponsorEverywhere();
        vm.startPrank(makerA);
        venueA.addSponsor(SPONSOR2, sponsor2);
        venueA.setPairSponsor(pairA, SPONSOR2, true);
        vm.stopPrank();
        _listSponsor(venueA, pairA, _one(taker), true);
        vm.prank(sponsor2);
        venueA.setMembers(pairA, SPONSOR2, _one(customer2), true);
        _fund(customer2);

        assertGt(_sell(taker, SPONSOR), 0);
        assertGt(_sell(customer2, SPONSOR2), 0);
        _assertAdmitted(customer2, _ids(SPONSOR, SPONSOR2), true, SPONSOR2);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, customer2));
        _sell(customer2, SPONSOR);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sell(taker, SPONSOR2);
        // One sponsor can't touch the other's list.
        vm.prank(sponsor2);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, SPONSOR));
        venueA.setMembers(pairA, SPONSOR, _one(taker), false);
    }

    /// @dev Each swap names the sponsor it trades under on its venue: A admits the taker on its home list, B through
    /// the sponsor's list. Each `Fill` carries the swap's sponsor, for per-sponsor attribution.
    function test_aSponsorPerVenue() public {
        _listHome(venueA, pairA, _one(taker));
        _setAccess(venueB, pairB, IVenue.AccessMode.Listed);
        _admitSponsor(venueB, pairB);
        _listSponsor(venueB, pairB, _one(taker), true);

        uint256 before = usd.balanceOf(taker);
        vm.recordLogs();
        uint256 out = _sellAt(venueA, pairA, taker, HOME) + _sellAt(venueB, pairB, taker, SPONSOR);
        FillLog[] memory fills = _fillLogs();
        assertEq(usd.balanceOf(taker), before + out);
        assertEq(fills.length, 2);
        assertEq(fills[0].venue, address(venueA));
        assertEq(fills[0].sponsorId, HOME);
        assertEq(fills[1].venue, address(venueB));
        assertEq(fills[1].sponsorId, SPONSOR);
        assertEq(fills[0].taker, taker);
        assertEq(fills[1].taker, taker);

        // A router asks the venue which id it admits the taker under, in its order of preference.
        _assertAdmitted(taker, _ids(HOME, SPONSOR), true, HOME);
        _assertAdmitted(taker, _ids(SPONSOR, HOME), true, HOME);

        // Swapped ids fail: A never registered the sponsor, and the taker isn't on B's home list.
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownSponsor.selector, SPONSOR));
        _sellAt(venueA, pairA, taker, SPONSOR);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sellAt(venueB, pairB, taker, HOME);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Keys, switches and denial
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A sponsor hands its lists to a new key venue by venue: the handover on A moves A's lists only, and the
    /// lists keep admitting their members throughout.
    function test_handover_isPerVenueAndKeepsTheLists() public {
        _admitSponsorEverywhere();
        _listSponsorEverywhere(taker);
        vm.prank(sponsorOps);
        venueA.transferSponsorAdmin(SPONSOR, ops2);
        vm.prank(ops2);
        venueA.acceptSponsorAdmin(SPONSOR);
        assertGt(_sell(taker, SPONSOR), 0, "the list moved with the key");

        vm.prank(sponsorOps);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, SPONSOR));
        venueA.setMembers(pairA, SPONSOR, _one(stranger), true);
        vm.prank(ops2);
        venueA.setMembers(pairA, SPONSOR, _one(stranger), true);
        // B still answers to the old key.
        (address adminB,,) = venueB.sponsor(SPONSOR);
        assertEq(adminB, sponsorOps);
        vm.prank(ops2);
        vm.expectRevert(abi.encodeWithSelector(IVenue.NotSponsorAdmin.selector, SPONSOR));
        venueB.setMembers(pairB, SPONSOR, _one(stranger), true);
    }

    /// @dev An updater can switch a sponsor off or remove it from a pair (only narrowing), and the next fill under it
    /// reverts; only the owner restores it, with the list intact. Each venue's switches are its own.
    function test_switches_narrowNowAndRestoreTheList() public {
        _admitSponsorEverywhere();
        _listSponsorEverywhere(taker);
        assertGt(_sellAt(venueB, pairB, taker, SPONSOR), 0);

        vm.prank(updaterB);
        venueB.setSponsorEnabled(SPONSOR, false);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SponsorDisabled.selector, SPONSOR));
        _sellAt(venueB, pairB, taker, SPONSOR);
        assertGt(_sell(taker, SPONSOR), 0, "B's switch is B's alone");
        vm.prank(updaterB);
        vm.expectRevert(IVenue.NotOwner.selector);
        venueB.setSponsorEnabled(SPONSOR, true);
        vm.prank(makerB);
        venueB.setSponsorEnabled(SPONSOR, true);
        assertGt(_sellAt(venueB, pairB, taker, SPONSOR), 0);

        vm.prank(updaterB);
        venueB.setPairSponsor(pairB, SPONSOR, false);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SponsorNotAdmitted.selector, pairB, SPONSOR));
        _sellAt(venueB, pairB, taker, SPONSOR);
        _admitSponsor(venueB, pairB);
        assertGt(_sellAt(venueB, pairB, taker, SPONSOR), 0, "readmission restores the list");
    }

    /// @dev A sponsor that lost its key on one venue: the maker resets the id to a new key there, which starts with an
    /// empty list. The maker never gets the old list, and other venues are untouched.
    function test_reset_startsANewListOnThatVenueOnly() public {
        _admitSponsorEverywhere();
        _listSponsorEverywhere(taker);
        vm.prank(makerB);
        venueB.resetSponsor(SPONSOR, ops2);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sellAt(venueB, pairB, taker, SPONSOR);
        assertGt(_sell(taker, SPONSOR), 0, "A's list is untouched");
        vm.prank(ops2);
        venueB.setMembers(pairB, SPONSOR, _one(taker), true);
        assertGt(_sellAt(venueB, pairB, taker, SPONSOR), 0);
    }

    /// @dev A denial overrides the home list, a sponsor's list and `Open`. An updater denies; only the owner lifts.
    function test_deny_overridesEveryListAndOpen() public {
        // A: home list. B: the sponsor's list. C: Open.
        _listHome(venueA, pairA, _one(taker));
        _setAccess(venueB, pairB, IVenue.AccessMode.Listed);
        _admitSponsor(venueB, pairB);
        _listSponsor(venueB, pairB, _one(taker), true);
        (Venue[3] memory venues, uint16[3] memory pairs) = _venues();
        uint64[3] memory ids = [HOME, SPONSOR, HOME];
        address[3] memory updaters = [updaterA, updaterB, updaterC];
        for (uint256 i; i < 3; ++i) {
            assertGt(_sellAt(venues[i], pairs[i], taker, ids[i]), 0);
            vm.prank(updaters[i]);
            venues[i].setDenied(_one(taker), true);
            vm.expectRevert(abi.encodeWithSelector(IVenue.TakerDenied.selector, taker));
            _sellAt(venues[i], pairs[i], taker, ids[i]);
            vm.prank(updaters[i]);
            vm.expectRevert(IVenue.NotOwner.selector);
            venues[i].setDenied(_one(taker), false);
        }
        _assertAdmitted(taker, _ids(HOME, SPONSOR), false, 0);
        for (uint256 i; i < 3; ++i) {
            vm.prank(venues[i].owner());
            venues[i].setDenied(_one(taker), false);
            assertGt(_sellAt(venues[i], pairs[i], taker, ids[i]), 0);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Open and closePair
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `Open` admits anyone not denied, whatever id the swap names, and pays the caller. A pair moved to `Listed`
    /// gates only its own venue's swaps.
    function test_open_isPermissionlessAndIgnoresTheId() public {
        address anyone = makeAddr("anyone");
        _fund(anyone);
        _assertAdmitted(anyone, _ids(42), true, 42);
        uint256 before = usd.balanceOf(anyone);
        uint256 out = _sell(anyone, 42);
        assertEq(usd.balanceOf(anyone), before + out);

        _setAccess(venueB, pairB, IVenue.AccessMode.Listed);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownSponsor.selector, 42));
        _sellAt(venueB, pairB, anyone, 42);
        assertGt(_sell(anyone, 42), 0);
        assertGt(_sellAt(venueC, pairC, anyone, 42), 0);
    }

    /// @dev The updater's kill switch closes the pair. The venue reports it closed, so a router drops it, and only the
    /// owner can reopen it.
    function test_closePair_untilTheOwnerReopens() public {
        _admitSponsorEverywhere();
        _listSponsorEverywhere(taker);

        vm.prank(updaterA);
        venueA.closePair(pairA);
        assertEq(uint8(venueA.pair(pairA).access), uint8(IVenue.AccessMode.Closed));
        _assertAdmitted(taker, _ids(HOME, SPONSOR), false, 0);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _sell(taker, SPONSOR);
        // Another venue's pair is untouched.
        assertGt(_sellAt(venueB, pairB, taker, SPONSOR), 0);

        vm.prank(updaterA);
        vm.expectRevert(IVenue.NotOwner.selector);
        venueA.setPairAccess(pairA, IVenue.AccessMode.Listed);
        _setAccess(venueA, pairA, IVenue.AccessMode.Listed);
        _assertAdmitted(taker, _ids(HOME, SPONSOR), true, SPONSOR);
        assertGt(_sell(taker, SPONSOR), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hooks and receive policies
    // ---------------------------------------------------------------------------------------------------------------

    function test_hook_seesTheTakerAndItsSponsor() public {
        _setAccess(venueA, pairA, IVenue.AccessMode.Listed);
        _admitSponsor(venueA, pairA);
        _listSponsor(venueA, pairA, _one(taker), true);
        MockVenueHook observer = new MockVenueHook(IVenue(address(venueA)), VenueHookFlags.BEFORE_FILL);
        vm.prank(makerA);
        venueA.setPairHook(pairA, address(observer), VenueHookFlags.BEFORE_FILL);
        _sell(taker, SPONSOR);
        IVenueHook.FillContext memory context = observer.beforeContext();
        assertEq(context.taker, taker);
        assertEq(context.sponsorId, SPONSOR);
    }

    /// @dev A TIP-1028 receive policy that parks the payment in the guard leaves the taker's balance unchanged, so the
    /// venue's exact-delta check reverts the fill and with it the swap.
    function test_receivePolicyRedirect_revertsTheWholeSwap() public {
        address guard = makeAddr("receivePolicyGuard");
        usd.setRedirectRecipient(guard);
        (, uint256 outA,) = _expect(venueA, pairA, true, true, 100e6);
        uint256[12] memory before = _balances();

        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(usd), taker, outA, uint256(0))
        );
        _sell(taker, HOME);
        _assertUnchanged(before);
        assertEq(usd.balanceOf(guard), 0);
    }
}
