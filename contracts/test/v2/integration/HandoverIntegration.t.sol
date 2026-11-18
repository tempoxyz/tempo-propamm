// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapParams } from "../utils/SwapParams.sol";

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../../src/v2/libraries/LadderMath.sol";
import { IntegrationFixture } from "./utils/IntegrationFixture.sol";

/// @notice The venue ownership handover in `docs/v2-deployment.md`, against a hostile inherited updater. Before the
/// new owner accepts, the old owner's updater halts the venue, redefines shape 0 as one deep flat level and posts a
/// year-long word on it at a mid of 1 wei. `post` and `setShape` work while halted, and a band set later doesn't
/// bind that word, so revoking the key isn't enough, and neither is closing the pair: the new owner must replace every
/// pair's word, or remove the pair, before unhalting.
contract HandoverIntegrationTest is IntegrationFixture {
    uint96 internal constant BAND_MIN = 1.08e18;
    uint96 internal constant BAND_MAX = 1.09e18;

    address internal newOwner = makeAddr("newOwner");
    address internal thief = makeAddr("thief");

    function setUp() public override {
        super.setUp();
        _fund(thief);
        vm.prank(makerA);
        venueA.transferOwnership(newOwner);
    }

    /// @dev The inherited key's last acts before its revocation. Returns the planted word.
    function _plant(uint32 seq) internal returns (bytes32 planted) {
        HotWord.Fields memory f = _fields(1);
        f.validUntil = uint40(block.timestamp + 365 days);
        f.seq = seq;
        planted = HotWord.pack(f);
        vm.startPrank(updaterA);
        venueA.setHalted(true);
        venueA.setShape(pairA, 0, _flatShape(type(uint32).max, 0));
        venueA.post(abi.encodePacked(pairA, planted));
        vm.stopPrank();
        assertEq(venueA.hotWord(pairA), planted);
    }

    /// @dev Checklist steps 1 to 3: accept, halt and revoke the listed keys (one batch on Tempo), then band the pair.
    function _acceptHaltRevokeAndBand() internal {
        vm.startPrank(newOwner);
        venueA.acceptOwnership();
        venueA.setHalted(true);
        venueA.setUpdater(updaterA, false);
        venueA.setMidBand(pairA, BAND_MIN, BAND_MAX);
        vm.stopPrank();
    }

    /// @dev Buys the venue's whole EUR inventory, paying whatever the curve asks.
    function _buyEverything() internal returns (uint256 paid) {
        uint256 loot = eur.balanceOf(address(venueA));
        SwapParams memory fills = _request(venueA, pairA, loot);
        paid = _swapExactOut(thief, address(usd), address(eur), fills, type(uint256).max);
    }

    /// @dev Why step 4 exists: without it, the planted word survives the revocation and the band, and sells the
    /// whole inventory for 1 unit once the venue is unhalted.
    function test_handover_revokingTheKeyLeavesItsWordLive() public {
        bytes32 planted = _plant(HotWord.seq(venueA.hotWord(pairA)) + 1);
        _acceptHaltRevokeAndBand();
        assertEq(venueA.hotWord(pairA), planted, "the band doesn't bind a word posted before it");

        vm.prank(newOwner);
        venueA.setHalted(false);
        assertLe(_buyEverything(), 1);
        assertEq(eur.balanceOf(address(venueA)), 0);
    }

    /// @dev Step 4: the owner redefines the shape its word selects and posts a fresh word inside the band, which
    /// replaces the planted one. The venue then prices at the owner's curve.
    function test_handover_freshWordsReplaceTheInheritedOnes() public {
        bytes32 planted = _plant(HotWord.seq(venueA.hotWord(pairA)) + 1);
        _acceptHaltRevokeAndBand();

        vm.startPrank(newOwner);
        venueA.setShape(pairA, 0, _shapeA());
        bytes32 fresh = _nextHot(venueA, pairA, _fields(MID_A));
        venueA.post(abi.encodePacked(pairA, fresh));
        vm.stopPrank();
        assertEq(venueA.hotWord(pairA), fresh, "the fresh word landed");
        assertTrue(fresh != planted);

        vm.prank(newOwner);
        venueA.setHalted(false);
        // The owner's ladder holds 600 EUR a side, so a buy of the whole inventory can't fill at all.
        SwapParams memory fills = _request(venueA, pairA, eur.balanceOf(address(venueA)));
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        _swapExactOut(thief, address(usd), address(eur), fills, type(uint256).max);

        // A buy the ladder covers pays at least the band's floor per EUR.
        uint256 paid = _swapExactOut(thief, address(usd), address(eur), _request(venueA, pairA, 100e6), 1e12);
        assertGe(paid, uint256(100e6) * BAND_MIN / 1e18);
    }

    /// @dev Why step 4 doesn't close such a pair: `closePair` only sets `Closed` and leaves the planted word in
    /// place, so reopening the pair with `setPairAccess`, however much later, sells the whole inventory for 1 unit.
    function test_handover_reopeningAClosedPairRearmsItsWord() public {
        _closeAndReopenLater(HotWord.seq(venueA.hotWord(pairA)) + 1);
    }

    /// @dev The same with the word at the highest `seq`, which no owner word can ever replace.
    function test_handover_reopeningAClosedMaxSeqPairRearmsItsWord() public {
        _closeAndReopenLater(type(uint32).max);
    }

    function _closeAndReopenLater(uint32 seq) internal {
        bytes32 planted = _plant(seq);
        _acceptHaltRevokeAndBand();
        vm.startPrank(newOwner);
        venueA.closePair(pairA);
        venueA.setHalted(false);
        vm.stopPrank();
        assertEq(venueA.hotWord(pairA), planted, "closePair leaves the word in place");

        vm.warp(block.timestamp + 180 days);
        vm.startPrank(newOwner);
        venueA.setHalted(true);
        venueA.setPairAccess(pairA, IVenue.AccessMode.Open);
        venueA.setHalted(false);
        vm.stopPrank();
        assertLe(_buyEverything(), 1);
        assertEq(eur.balanceOf(address(venueA)), 0);
    }

    /// @dev A word planted just below the highest `seq` leaves the owner only the `seq`s above it: at `2^32 - 2`, one
    /// owner word lands and then the pair is frozen on it, so step 4 removes such a pair too.
    function test_handover_aNearMaxSeqWordLeavesOneOwnerPost() public {
        _plant(type(uint32).max - 1);
        _acceptHaltRevokeAndBand();

        HotWord.Fields memory f = _fields(MID_A);
        f.seq = type(uint32).max;
        bytes32 last = HotWord.pack(f);
        vm.startPrank(newOwner);
        venueA.post(abi.encodePacked(pairA, last));
        assertEq(venueA.hotWord(pairA), last, "the owner's one word landed");

        vm.warp(block.timestamp + 1 hours);
        f = _fields(MID_A);
        f.seq = type(uint32).max;
        venueA.post(abi.encodePacked(pairA, HotWord.pack(f)));
        vm.stopPrank();
        assertEq(venueA.hotWord(pairA), last, "the owner's own word is final");
        assertLt(HotWord.validUntil(last), block.timestamp, "and has expired");
    }

    /// @dev Step 4 for a word at the highest `seq`: the owner's post is skipped, so the owner zeroes the pair's shape,
    /// removes the pair and adds it again. The new index starts at `seq = 1` with the owner's band and curve, and the
    /// planted word is gone with the old index, which no taker can fill.
    function test_handover_aMaxSeqPairIsRemovedAndAddedAgain() public {
        bytes32 planted = _plant(type(uint32).max);
        _acceptHaltRevokeAndBand();

        HotWord.Fields memory f = _fields(MID_A);
        f.seq = type(uint32).max;
        vm.startPrank(newOwner);
        venueA.post(abi.encodePacked(pairA, HotWord.pack(f)));
        assertEq(venueA.hotWord(pairA), planted, "no word can follow seq 2^32 - 1");

        uint256[4] memory none;
        venueA.setShape(pairA, 0, none);
        venueA.removePair(pairA);
        uint16 fresh = venueA.addPair(address(eur), address(usd), UNIT);
        assertEq(HotWord.seq(venueA.hotWord(fresh)), 1, "a fresh index starts at seq 1");
        // The venue is still halted, so the owner can open the fresh pair before unhalting.
        venueA.setPairAccess(fresh, IVenue.AccessMode.Open);
        venueA.setMidBand(fresh, BAND_MIN, BAND_MAX);
        venueA.setShape(fresh, 0, _shapeA());
        venueA.post(abi.encodePacked(fresh, _nextHot(venueA, fresh, _fields(MID_A))));
        venueA.setHalted(false);
        vm.stopPrank();
        assertEq(venueA.hotWord(pairA), bytes32(0), "the planted word is gone");
        assertEq(venueA.shape(pairA, 0)[0], 0, "and so is the old index's shape");

        uint256 loot = eur.balanceOf(address(venueA));
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, pairA));
        _swapExactOut(thief, address(usd), address(eur), _request(venueA, pairA, loot), type(uint256).max);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        _swapExactOut(thief, address(usd), address(eur), _request(venueA, fresh, loot), type(uint256).max);

        uint256 paid = _swapExactOut(thief, address(usd), address(eur), _request(venueA, fresh, 100e6), 1e12);
        assertGe(paid, uint256(100e6) * BAND_MIN / 1e18);
    }
}
