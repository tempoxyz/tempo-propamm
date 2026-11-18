// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { Registry } from "../../src/v2/Registry.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { VenueFixture } from "./utils/VenueFixture.sol";

contract VenueSequenceResetTest is VenueFixture {
    function _postAs(address account, uint16 index, bytes32 word) private {
        vm.prank(account);
        venue.post(_entry(index, word));
    }

    function test_resetRecoversExhaustedPairWithoutChangingInventoryDepthOrRegistration() public {
        Registry directory = new Registry(factory);
        directory.register(address(venue));
        _fill(pairId, false, false, 30e6);
        _fill(pairId, true, true, 20e6);
        (uint128 bidsBefore, uint128 asksBefore) = venue.consumed(pairId);
        bytes32 pairBefore = keccak256(abi.encode(venue.pair(pairId)));
        bytes32 shapeBefore = keccak256(abi.encode(venue.shape(pairId, 0)));
        uint256 eurBefore = eur.balanceOf(address(venue));
        uint256 usdBefore = usd.balanceOf(address(venue));

        _postAs(updater, pairId, _hot(type(uint32).max));
        vm.startPrank(owner);
        venue.setHalted(true);
        venue.setUpdater(updater, false);
        vm.expectEmit(true, false, false, true, address(venue));
        emit IVenue.HotWordReset(pairId, type(uint32).max);
        venue.resetHotWord(pairId);
        vm.stopPrank();

        assertEq(venue.hotWord(pairId), HotWord.INITIAL);
        assertEq(keccak256(abi.encode(venue.pair(pairId))), pairBefore);
        assertEq(keccak256(abi.encode(venue.shape(pairId, 0))), shapeBefore);
        assertEq(venue.pairCount(), 1);
        assertTrue(directory.isRegistered(address(venue)));
        (uint128 bidsAfter, uint128 asksAfter) = venue.consumed(pairId);
        assertEq(bidsAfter, bidsBefore);
        assertEq(asksAfter, asksBefore);
        assertEq(eur.balanceOf(address(venue)), eurBefore);
        assertEq(usd.balanceOf(address(venue)), usdBefore);

        // The revoked key cannot replay a queued high-sequence post after the reset.
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        _postAs(updater, pairId, _hot(type(uint32).max));
        vm.prank(owner);
        venue.setHalted(false);
        vm.expectRevert(abi.encodeWithSelector(IVenue.QuoteExpired.selector, uint40(0)));
        venue.quote(pairId, address(usd), address(eur), 1e6, false);

        // A fresh quote at seq 2 resumes the same pair from its preserved consumed depth.
        _post(pairId, _hot(2));
        (uint128 quotedIn, uint128 quotedOut) = venue.quote(pairId, address(usd), address(eur), 1e6, false);
        (uint128 filledIn, uint128 filledOut) = _fill(pairId, false, false, 1e6);
        assertEq(filledIn, quotedIn);
        assertEq(filledOut, quotedOut);
        (, asksAfter) = venue.consumed(pairId);
        assertEq(asksAfter, asksBefore + 1e6);
    }

    function test_resetRequiresOwnerAndHaltAndLivePair() public {
        address[3] memory others = [updater, settler, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(others[i]);
            venue.resetHotWord(pairId);
        }
        vm.expectRevert(IVenue.NotHalted.selector);
        vm.prank(owner);
        venue.resetHotWord(pairId);

        vm.startPrank(owner);
        venue.setHalted(true);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(9)));
        venue.resetHotWord(9);
        venue.removePair(pairId);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, pairId));
        venue.resetHotWord(pairId);
        vm.stopPrank();
    }

    function test_resetPreservesAccessAndBands() public {
        uint64 sponsorId = 7;
        address sponsorAdmin = makeAddr("sponsor admin");
        vm.startPrank(owner);
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);
        venue.addSponsor(sponsorId, sponsorAdmin);
        venue.setPairSponsor(pairId, sponsorId, true);
        venue.setMembers(pairId, HOME, _one(taker), true);
        venue.setMidBand(pairId, MID - 1, MID + 1);
        vm.stopPrank();
        vm.prank(sponsorAdmin);
        venue.setMembers(pairId, sponsorId, _one(stranger), true);
        vm.startPrank(owner);
        venue.setHalted(true);
        venue.resetHotWord(pairId);
        vm.stopPrank();
        assertTrue(venue.pairSponsor(pairId, sponsorId));
        assertTrue(venue.isMember(pairId, HOME, taker));
        assertTrue(venue.isMember(pairId, sponsorId, stranger));
        assertEq(uint8(venue.pair(pairId).access), uint8(IVenue.AccessMode.Listed));
        (uint96 minimum, uint96 maximum) = venue.midBand(pairId);
        assertEq(minimum, MID - 1);
        assertEq(maximum, MID + 1);
    }
}
