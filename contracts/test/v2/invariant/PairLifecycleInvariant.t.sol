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

/// @notice A separate campaign for pair removal, non-reused indices and owner/updater authority across handovers.
/// The pricing campaign has a fixed pair set, so it cannot reach these transitions.
contract PairLifecycleInvariantTest is StdInvariant, Test {
    PairLifecycleHandler internal handler;

    function setUp() public {
        (, VenueFactory factory) = CoreDeploy.core();
        handler = new PairLifecycleHandler(Venue(factory.createVenue(makeAddr("firstOwner"), keccak256("lifecycle"))));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = PairLifecycleHandler.addPair.selector;
        selectors[1] = PairLifecycleHandler.removePair.selector;
        selectors[2] = PairLifecycleHandler.proposeOwner.selector;
        selectors[3] = PairLifecycleHandler.acceptOwner.selector;
        selectors[4] = PairLifecycleHandler.setUpdater.selector;
        selectors[5] = PairLifecycleHandler.accessPair.selector;
        selectors[6] = PairLifecycleHandler.postPair.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_pairIndicesAndAuthority() public view {
        handler.checkState();
    }

    function test_lifecycleCoverage() public {
        handler.addPair(0, 0);
        handler.accessPair(0, 1, false);
        handler.accessPair(0, 0, false);
        handler.setUpdater(0, true);
        handler.accessPair(0, 2, true);
        handler.proposeOwner(0, true);
        handler.acceptOwner(1);
        handler.removePair(0, 0);
        handler.removePair(0, 1);
        handler.postPair(0, 1);
        handler.addPair(1, 1);
        handler.checkState();
        assertEq(handler.count(), 2, "pair index must not be reused");
        assertEq(handler.successfulRemovals(), 1, "removed a live pair");
        assertEq(handler.successfulTransfers(), 1, "accepted a handover");
    }
}

contract PairLifecycleHandler is Test {
    uint256 internal constant MAX_PAIRS = 8;

    Venue public immutable venue;
    address[3] internal actors;
    MockTIP20V2[3] internal tokens;
    address internal ownerGhost;
    address internal pendingGhost;
    mapping(address actor => bool) internal updaterGhost;
    mapping(uint16 pairIndex => bool) internal live;
    mapping(uint16 pairIndex => address) internal bases;
    mapping(uint16 pairIndex => address) internal quotes;
    mapping(uint16 pairIndex => IVenue.AccessMode) internal modes;
    uint16 public count;
    uint256 public successfulRemovals;
    uint256 public successfulTransfers;

    constructor(Venue venue_) {
        venue = venue_;
        actors[0] = venue.owner();
        actors[1] = makeAddr("secondOwner");
        actors[2] = makeAddr("updater");
        ownerGhost = actors[0];
        tokens[0] = new MockTIP20V2("EURC", 6);
        tokens[1] = new MockTIP20V2("USDC", 6);
        tokens[2] = new MockTIP20V2("OUSD", 6);
    }

    function addPair(uint256 seed, uint256 caller) external {
        if (count == MAX_PAIRS) return;
        address base = address(tokens[seed % 3]);
        address quote = address(tokens[(seed % 3 + 1) % 3]);
        address actor = actors[caller % 3];
        vm.prank(actor);
        (bool ok, bytes memory data) = address(venue).call(abi.encodeCall(IVenue.addPair, (base, quote, 1e6)));
        assertEq(ok, actor == ownerGhost, "addPair authority");
        if (ok) {
            assertEq(abi.decode(data, (uint16)), count, "monotonic pair index");
            live[count] = true;
            bases[count] = base;
            quotes[count] = quote;
            modes[count] = IVenue.AccessMode.Closed;
            ++count;
        }
    }

    function removePair(uint256 seed, uint256 caller) external {
        uint16 p = _drawPair(seed);
        address actor = actors[caller % 3];
        vm.prank(actor);
        (bool ok,) = address(venue).call(abi.encodeCall(IVenue.removePair, (p)));
        assertEq(ok, actor == ownerGhost && live[p], "removePair authority and liveness");
        if (ok) {
            live[p] = false;
            modes[p] = IVenue.AccessMode.None;
            ++successfulRemovals;
        }
    }

    function proposeOwner(uint256 caller, bool second) external {
        address actor = actors[caller % 3];
        address next = actors[second ? 1 : 0];
        vm.prank(actor);
        (bool ok,) = address(venue).call(abi.encodeCall(IVenue.transferOwnership, (next)));
        assertEq(ok, actor == ownerGhost, "ownership proposal authority");
        if (ok) pendingGhost = next;
    }

    function acceptOwner(uint256 caller) external {
        address actor = actors[caller % 3];
        vm.prank(actor);
        (bool ok,) = address(venue).call(abi.encodeCall(IVenue.acceptOwnership, ()));
        assertEq(ok, actor == pendingGhost && pendingGhost != address(0), "pending owner authority");
        if (ok) {
            ownerGhost = actor;
            pendingGhost = address(0);
            ++successfulTransfers;
        }
    }

    function setUpdater(uint256 caller, bool allowed) external {
        address actor = actors[caller % 3];
        vm.prank(actor);
        (bool ok,) = address(venue).call(abi.encodeCall(IVenue.setUpdater, (actors[2], allowed)));
        assertEq(ok, actor == ownerGhost, "updater grant authority");
        if (ok) updaterGhost[actors[2]] = allowed;
    }

    function accessPair(uint256 seed, uint256 caller, bool close) external {
        uint16 p = _drawPair(seed);
        address actor = actors[caller % 3];
        bytes memory callData = close
            ? abi.encodeCall(IVenue.closePair, (p))
            : abi.encodeCall(IVenue.setPairAccess, (p, IVenue.AccessMode.Listed));
        vm.prank(actor);
        (bool ok,) = address(venue).call(callData);
        bool authorized = actor == ownerGhost || (close && updaterGhost[actor]);
        assertEq(ok, live[p] && authorized, "access mutation authority and liveness");
        if (ok) modes[p] = close ? IVenue.AccessMode.Closed : IVenue.AccessMode.Listed;
    }

    function postPair(uint256 seed, uint256 caller) external {
        uint16 p = _drawPair(seed);
        address actor = actors[caller % 3];
        vm.prank(actor);
        (bool ok,) = address(venue)
            .call(abi.encodeCall(IVenue.post, (abi.encodePacked(p, HotWord.INITIAL | bytes32(uint256(1))))));
        assertEq(ok, live[p] && (actor == ownerGhost || updaterGhost[actor]), "post authority and liveness");
    }

    function checkState() external view {
        assertEq(venue.owner(), ownerGhost, "owner");
        assertEq(venue.pendingOwner(), pendingGhost, "pending owner");
        assertEq(venue.pairCount(), count, "pair count must not fall on removal");
        for (uint256 i; i < 3; ++i) {
            assertEq(venue.isUpdater(actors[i]), updaterGhost[actors[i]], "updater persistence");
        }
        for (uint16 p; p < count; ++p) {
            IVenue.Pair memory pair = venue.pair(p);
            if (live[p]) {
                assertEq(pair.base, bases[p], "live pair base");
                assertEq(pair.quote, quotes[p], "live pair quote");
                assertEq(pair.sizeUnit, 1e6, "live pair unit");
                assertEq(uint8(pair.access), uint8(modes[p]), "live pair access");
                assertEq(venue.hotWord(p), HotWord.INITIAL, "hot word untouched by stale posts");
                (uint128 bids, uint128 asks) = venue.consumed(p);
                assertEq(bids, 0, "bid depth untouched");
                assertEq(asks, 0, "ask depth untouched");
            } else {
                assertEq(pair.base, address(0), "removed pair base");
                assertEq(pair.quote, address(0), "removed pair quote");
                assertEq(uint8(pair.access), uint8(IVenue.AccessMode.None), "removed pair access");
                assertEq(venue.hotWord(p), bytes32(0), "removed pair hot word");
                assertFalse(venue.takerAllowed(p, actors[0], 0), "removed pair admits no taker");
            }
        }
    }

    function _drawPair(uint256 seed) internal view returns (uint16) {
        // `count` is bounded to eight, so this result is at most nine.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(seed % (uint256(count) + 2));
    }
}
