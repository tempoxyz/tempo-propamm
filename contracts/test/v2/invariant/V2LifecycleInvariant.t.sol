// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../src/v2/VenueFactory.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { CoreDeploy } from "../utils/CoreDeploy.sol";

/// @notice Exercises a venue whose owner and updater change while pairs are removed and added at new indices.
/// Each action checks authorization and state immediately so a later action cannot hide a transient violation.
contract V2LifecycleHandler is Test {
    uint256 internal constant MAX_PAIRS = 32;
    uint96 internal constant MIN_MID = 1e18;
    uint96 internal constant MAX_MID = 2e18;

    Venue internal immutable venue;
    MockTIP20V2 internal immutable base;
    MockTIP20V2 internal immutable quoteToken;
    address[2] internal owners;
    address internal updater;
    uint256 internal ownerIndex;
    bool internal updaterAllowed;
    uint16 internal livePair;
    uint16 internal created;
    bytes32 internal expectedHot;

    uint256 public rotations;
    uint256 public handoffs;
    uint256 public updaterChanges;
    uint256 public acceptedPosts;
    uint256 public rejectedPosts;

    constructor(Venue venue_, MockTIP20V2 base_, MockTIP20V2 quote_) {
        venue = venue_;
        base = base_;
        quoteToken = quote_;
        owners[0] = makeAddr("lifecycle owner 0");
        owners[1] = makeAddr("lifecycle owner 1");
        updater = makeAddr("lifecycle updater");
        vm.prank(owners[0]);
        livePair = venue.addPair(address(base), address(quoteToken), 1e6);
        created = 1;
        expectedHot = HotWord.INITIAL;
        vm.startPrank(owners[0]);
        venue.setUpdater(updater, true);
        venue.setMidBand(livePair, MIN_MID, MAX_MID);
        vm.stopPrank();
        updaterAllowed = true;
    }

    function rotatePair(uint256 seed) external {
        if (created == MAX_PAIRS) return;
        address owner = owners[ownerIndex];
        uint16 removed = livePair;
        vm.prank(owner);
        venue.removePair(removed);
        _assertRemoved(removed);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, removed));
        venue.quote(removed, address(base), address(quoteToken), 1e6, true);

        vm.prank(owner);
        uint16 next = venue.addPair(address(base), address(quoteToken), seed % 2 == 0 ? 1e6 : 1e5);
        assertEq(next, created, "pair index reused");
        livePair = next;
        ++created;
        ++rotations;
        expectedHot = HotWord.INITIAL;
        vm.prank(owner);
        venue.setMidBand(next, MIN_MID, MAX_MID);
        _assertCurrent();
    }

    function handoff(uint256) external {
        address former = owners[ownerIndex];
        address next = owners[1 - ownerIndex];
        vm.prank(former);
        venue.transferOwnership(next);
        vm.prank(former);
        vm.expectRevert(IVenue.NotPendingOwner.selector);
        venue.acceptOwnership();
        vm.prank(next);
        venue.acceptOwnership();
        ownerIndex = 1 - ownerIndex;
        ++handoffs;

        vm.prank(former);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.removePair(livePair);
        vm.prank(former);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.setMidBand(livePair, 0, 0);
        _assertCurrent();
    }

    function changeUpdater(uint256 seed) external {
        bool allowed = seed % 2 == 0;
        address owner = owners[ownerIndex];
        vm.prank(owner);
        venue.setUpdater(updater, allowed);
        updaterAllowed = allowed;
        ++updaterChanges;

        vm.prank(owners[1 - ownerIndex]);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.setUpdater(updater, !allowed);
        assertEq(venue.isUpdater(updater), allowed, "updater grant");
    }

    function post(uint256 seed) external {
        address poster = seed % 3 == 0 ? owners[ownerIndex] : seed % 3 == 1 ? updater : owners[1 - ownerIndex];
        uint96 mid = seed % 4 == 0 ? 3e18 : MIN_MID;
        bytes32 word = HotWord.pack(
            HotWord.Fields({
                mid: mid,
                bidWiden: 0,
                askWiden: 0,
                widthScale: 1000,
                depthScale: 1000,
                shapeId: 0,
                validUntil: uint40(block.timestamp + 900),
                seq: HotWord.seq(expectedHot) + 1,
                flags: 0
            })
        );
        vm.prank(poster);
        if (poster != owners[ownerIndex] && (poster != updater || !updaterAllowed)) {
            vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
            venue.post(abi.encodePacked(livePair, word));
            ++rejectedPosts;
        } else if (poster == updater && mid > MAX_MID) {
            vm.expectRevert(abi.encodeWithSelector(IVenue.MidOutOfBand.selector, livePair, mid));
            venue.post(abi.encodePacked(livePair, word));
            ++rejectedPosts;
        } else {
            venue.post(abi.encodePacked(livePair, word));
            expectedHot = word;
            ++acceptedPosts;
        }
        _assertCurrent();
    }

    function probe(uint256) external view {
        _assertCurrent();
    }

    function assertState() external view {
        _assertCurrent();
        for (uint16 p; p < created; ++p) {
            if (p != livePair) _assertRemoved(p);
        }
    }

    function _assertCurrent() internal view {
        assertEq(venue.owner(), owners[ownerIndex], "owner");
        assertEq(venue.isUpdater(updater), updaterAllowed, "updater");
        assertEq(venue.pairCount(), created, "pair count");
        IVenue.Pair memory pair = venue.pair(livePair);
        assertEq(pair.base, address(base), "base");
        assertEq(pair.quote, address(quoteToken), "quote");
        assertEq(uint8(pair.access), uint8(IVenue.AccessMode.Closed), "new pair is closed");
        assertEq(venue.hotWord(livePair), expectedHot, "hot word");
        (uint96 minMid, uint96 maxMid) = venue.midBand(livePair);
        assertEq(minMid, MIN_MID, "band minimum");
        assertEq(maxMid, MAX_MID, "band maximum");
        (uint128 bids, uint128 asks) = venue.consumed(livePair);
        assertEq(bids, 0, "fresh bids");
        assertEq(asks, 0, "fresh asks");
    }

    function _assertRemoved(uint16 p) internal view {
        IVenue.Pair memory pair = venue.pair(p);
        assertEq(pair.base, address(0), "removed base");
        assertEq(pair.quote, address(0), "removed quote");
        assertEq(uint8(pair.access), uint8(IVenue.AccessMode.None), "removed access");
        assertEq(pair.hook, address(0), "removed hook");
        assertEq(pair.hookFlags, 0, "removed flags");
        assertEq(venue.hotWord(p), bytes32(0), "removed word");
        (uint96 minMid, uint96 maxMid) = venue.midBand(p);
        assertEq(minMid, 0, "removed band min");
        assertEq(maxMid, 0, "removed band max");
        (uint128 bids, uint128 asks) = venue.consumed(p);
        assertEq(bids, 0, "removed bids");
        assertEq(asks, 0, "removed asks");
    }
}

contract V2LifecycleInvariantTest is StdInvariant, Test {
    V2LifecycleHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        address owner = makeAddr("lifecycle owner 0");
        VenueFactory factory = CoreDeploy.factoryWith(makeAddr("settler"));
        Venue venue = Venue(factory.createVenue(owner, "lifecycle"));
        MockTIP20V2 base = new MockTIP20V2("EURC", 6);
        MockTIP20V2 quoteToken = new MockTIP20V2("USD", 6);
        handler = new V2LifecycleHandler(venue, base, quoteToken);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = V2LifecycleHandler.rotatePair.selector;
        selectors[1] = V2LifecycleHandler.handoff.selector;
        selectors[2] = V2LifecycleHandler.changeUpdater.selector;
        selectors[3] = V2LifecycleHandler.post.selector;
        selectors[4] = V2LifecycleHandler.probe.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_removedPairsAndRolesRemainIsolated() public view {
        handler.assertState();
    }

    function test_lifecycleActionsReachTransitions() public {
        handler.post(0);
        handler.changeUpdater(1);
        handler.post(1);
        handler.handoff(0);
        handler.post(2);
        handler.rotatePair(0);
        handler.changeUpdater(0);
        handler.post(1);
        handler.post(4);
        handler.assertState();
        assertEq(handler.rotations(), 1);
        assertEq(handler.handoffs(), 1);
        assertEq(handler.updaterChanges(), 2);
        assertEq(handler.acceptedPosts(), 2);
        assertEq(handler.rejectedPosts(), 3);
    }
}
