// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapParams } from "../utils/SwapParams.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IRegistry } from "../../../src/v2/interfaces/IRegistry.sol";
import { ISettler } from "../../../src/v2/interfaces/ISettler.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../src/v2/VenueFactory.sol";
import { CoreDeploy } from "../utils/CoreDeploy.sol";
import { Forgery } from "../utils/ForgedCode.sol";
import { TxBatcher } from "./utils/Actors.sol";
import { IntegrationFixture } from "./utils/IntegrationFixture.sol";

/// @notice Single-pool swaps through the real Settler into real venue clones.
contract SwapIntegrationTest is IntegrationFixture {
    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    function test_deployment_wiresTheStackWithoutAnAdmin() public view {
        assertEq(settler.factory(), address(factory));
        assertEq(settler.implementation(), factory.implementation());
        assertEq(factory.defaultSettler(), address(settler));
        assertEq(address(discovery.factory()), address(factory));
        Venue[3] memory venues = [venueA, venueB, venueC];
        address[3] memory makers = [makerA, makerB, makerC];
        for (uint256 i; i < 3; ++i) {
            assertTrue(factory.isVenue(address(venues[i])));
            assertEq(venues[i].settler(), address(settler));
            assertEq(venues[i].owner(), makers[i]);
            assertEq(venues[i].factory(), address(factory));
            // No venue starts with a sponsor or anyone listed.
            (address admin,,) = venues[i].sponsor(SPONSOR);
            assertEq(admin, address(0));
        }
        assertEq(address(venueA), factory.predictVenue(makerA, "A"));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Repeated swaps on one pool
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev One swap from a fresh ladder, in either direction and mode, pays the taker exactly the ladder's price.
    function testFuzz_singlePoolBothSidesAndModes(bool baseIn, bool exactIn, uint128 amount) public {
        amount = uint128(bound(amount, 1e6, 200e6));
        (address tokenIn, address tokenOut) = baseIn ? (address(eur), address(usd)) : (address(usd), address(eur));
        (uint256 expectedIn, uint256 expectedOut,) = _expect(venueA, pairA, baseIn, exactIn, amount);
        uint256 takerInBefore = baseIn ? eur.balanceOf(taker) : usd.balanceOf(taker);
        uint256 takerOutBefore = baseIn ? usd.balanceOf(taker) : eur.balanceOf(taker);
        if (exactIn) {
            assertEq(_swapExactIn(taker, tokenIn, tokenOut, _request(venueA, pairA, amount), expectedOut), expectedOut);
        } else {
            assertEq(_swapExactOut(taker, tokenIn, tokenOut, _request(venueA, pairA, amount), expectedIn), expectedIn);
        }
        assertEq(baseIn ? eur.balanceOf(taker) : usd.balanceOf(taker), takerInBefore - expectedIn);
        assertEq(baseIn ? usd.balanceOf(taker) : eur.balanceOf(taker), takerOutBefore + expectedOut);
    }

    /// @dev Three swaps in one transaction: the second sells into the bids where the first left them, at a worse
    /// price, and the third, buying, walks the untouched asks from their top and gives the bids nothing back.
    function test_swapsInOneTransaction_walkTheLadderDown() public {
        TxBatcher batcher = new TxBatcher();
        _fund(address(batcher));
        uint256 amount = 100e6;
        (, uint256 first,) = _expect(venueA, pairA, true, true, amount);
        (, uint256 opposite,) = _expect(venueA, pairA, false, true, amount);

        TxBatcher.Call[] memory calls = new TxBatcher.Call[](3);
        calls[0] = _swapInCall(address(eur), address(usd), amount);
        calls[1] = calls[0];
        calls[2] = _swapInCall(address(usd), address(eur), amount);
        bytes[] memory results = batcher.run(calls);

        // 100 EUR take bid level 1 (1 bp), so the next 100 EUR take level 2 (2 bp).
        assertEq(abi.decode(results[0], (uint256)), first);
        assertEq(abi.decode(results[1], (uint256)), 100e6 * uint256(MID_A) * (1e8 - 20_000) / 1e26);
        assertLt(abi.decode(results[1], (uint256)), first);
        assertEq(abi.decode(results[2], (uint256)), opposite);
        (uint128 bids, uint128 asks) = venueA.consumed(pairA);
        assertEq(bids, 200e6);
        assertEq(asks, opposite);
    }

    /// @dev Through the Settler: one order split into several swaps, in one block or across blocks, never gets more
    /// than the same order sent as one swap, exact in or exact out, and leaves the ladder where the one swap would.
    function testFuzz_splitSwapsNeverBeatOneSwap(bool baseIn, bool exactIn, uint128 amount, uint8 parts, bool blocks)
        public
    {
        parts = uint8(bound(parts, 2, 6));
        amount = uint128(bound(amount, 6e6, exactIn ? 500e6 : 520e6));
        (address tokenIn, address tokenOut) = baseIn ? (address(eur), address(usd)) : (address(usd), address(eur));
        uint256 snapshot = vm.snapshotState();
        uint256 total;
        for (uint256 i; i < parts; ++i) {
            uint128 part = i == parts - 1 ? amount - uint128(amount / parts) * uint128(parts - 1) : amount / parts;
            if (blocks && i != 0) {
                vm.roll(block.number + 1);
                vm.warp(START + i);
            }
            total += exactIn
                ? _swapExactIn(taker, tokenIn, tokenOut, _request(venueA, pairA, part), 0)
                : _swapExactOut(taker, tokenIn, tokenOut, _request(venueA, pairA, part), type(uint256).max);
        }
        (uint128 splitBids, uint128 splitAsks) = venueA.consumed(pairA);
        vm.revertToState(snapshot);

        uint256 whole = exactIn
            ? _swapExactIn(taker, tokenIn, tokenOut, _request(venueA, pairA, amount), 0)
            : _swapExactOut(taker, tokenIn, tokenOut, _request(venueA, pairA, amount), type(uint256).max);
        if (exactIn) assertLe(total, whole, "split swaps paid out more");
        else assertGe(total, whole, "split swaps cost less");
        (uint128 bids, uint128 asks) = venueA.consumed(pairA);
        // A base-targeting order moves the same base either way; a quote-targeting one moves at most (paying quote)
        // or at least (wanting quote) the whole's.
        if (baseIn == exactIn) {
            assertEq(splitBids, bids);
            assertEq(splitAsks, asks);
        } else if (exactIn) {
            assertLe(splitAsks, asks);
        } else {
            assertGe(splitBids, bids);
        }
    }

    function _swapInCall(address tokenIn, address tokenOut, uint256 amount)
        internal
        view
        returns (TxBatcher.Call memory)
    {
        SwapParams memory fills = _request(venueA, pairA, amount);
        return TxBatcher.Call(
            address(settler),
            abi.encodeCall(
                ISettler.swapExactIn,
                (fills.venue, fills.pairIndex, tokenIn, tokenOut, fills.amount, 0, fills.sponsorId, _deadline(), REF)
            )
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Venue provenance
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Code and storage prove nothing about who created a contract: its constructor can write any slot and then
    /// return any runtime code. Each forgery here returns a venue's code (a real venue's exact code, salt included, or
    /// a plain clone of the implementation) over the slots a victim would check: the victim as owner, this Settler, and
    /// a hidden pending owner and updater. It runs the venue code like a venue, and its owner can configure and fund
    /// it, but it doesn't sit where the factory deploys a venue for the salt its code claims, so the Settler, `isVenue`
    /// and the directory all reject it, and no swap moves a balance.
    function test_forgedVenueNeverFills() public {
        address victim = makeAddr("victim");
        address attacker = makeAddr("attacker");
        bytes[2] memory codes = [
            address(venueA).code,
            abi.encodePacked(hex"363d3d373d3d3d363d73", factory.implementation(), hex"5af43d82803e903d91602b57fd5bf3")
        ];
        for (uint256 i; i < codes.length; ++i) {
            Venue forged = _forgeVenue(codes[i], victim, attacker);
            assertEq(forged.owner(), victim);
            assertEq(forged.settler(), address(settler));
            assertEq(forged.pendingOwner(), attacker);
            assertTrue(forged.isUpdater(attacker));
            assertFalse(factory.isVenue(address(forged)));

            vm.startPrank(victim);
            uint16 p = forged.addPair(address(eur), address(usd), UNIT);
            forged.setShape(p, 0, _shapeA());
            vm.stopPrank();
            _setAccess(forged, p, IVenue.AccessMode.Open);
            _post(forged, p, _fields(MID_A));
            usd.mint(address(forged), INVENTORY);

            uint256[12] memory before = _balances();
            uint256 forgedUsd = usd.balanceOf(address(forged));
            bytes memory err = abi.encodeWithSelector(ISettler.UnknownVenue.selector, address(forged));
            vm.expectRevert(err);
            _swapExactIn(taker, address(eur), address(usd), _request(forged, p, 100e6), 0);
            vm.expectRevert(err);
            _swapExactOut(taker, address(eur), address(usd), _request(forged, p, 100e6), type(uint256).max);
            _assertUnchanged(before);
            assertEq(usd.balanceOf(address(forged)), forgedUsd);

            vm.prank(tempoOps);
            vm.expectRevert(abi.encodeWithSelector(IRegistry.UnknownVenue.selector, address(forged)));
            discovery.register(address(forged));
        }
    }

    /// @dev A clone of the implementation that anyone else deployed, here with a real venue's salt, never fills, and
    /// only the factory can initialize it, so it has no owner and no account can configure it.
    function test_foreignCloneOfTheImplementationNeverFills() public {
        vm.prank(stranger);
        Venue foreign =
            Venue(Clones.cloneWithImmutableArgs(factory.implementation(), Clones.fetchCloneArgs(address(venueA))));
        assertEq(address(foreign).code, address(venueA).code, "a real venue's code");
        assertFalse(factory.isVenue(address(foreign)));
        eur.mint(address(foreign), INVENTORY);
        usd.mint(address(foreign), INVENTORY);

        vm.startPrank(stranger);
        vm.expectRevert(IVenue.NotFactory.selector);
        foreign.initialize(stranger, stranger);
        vm.expectRevert(IVenue.NotOwner.selector);
        foreign.addPair(address(eur), address(usd), UNIT);
        vm.expectRevert(IVenue.NotOwner.selector);
        foreign.setSettler(address(settler));
        vm.expectRevert(IVenue.NotOwner.selector);
        foreign.setUpdater(stranger, true);
        vm.expectRevert(IVenue.NotPendingOwner.selector);
        foreign.acceptOwnership();
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        foreign.post(abi.encodePacked(uint16(0), HotWord.pack(_fields(MID_A))));
        vm.stopPrank();
        assertEq(foreign.owner(), address(0));
        assertEq(foreign.settler(), address(0));

        uint256[12] memory before = _balances();
        uint256 foreignEur = eur.balanceOf(address(foreign));
        uint256 foreignUsd = usd.balanceOf(address(foreign));
        bytes memory err = abi.encodeWithSelector(ISettler.UnknownVenue.selector, address(foreign));
        vm.expectRevert(err);
        _swapExactIn(taker, address(eur), address(usd), _request(foreign, 0, 100e6), 0);
        vm.expectRevert(err);
        _swapExactOut(taker, address(eur), address(usd), _request(foreign, 0, 100e6), type(uint256).max);
        _assertUnchanged(before);
        assertEq(eur.balanceOf(address(foreign)), foreignEur);
        assertEq(usd.balanceOf(address(foreign)), foreignUsd);

        vm.prank(tempoOps);
        vm.expectRevert(abi.encodeWithSelector(IRegistry.UnknownVenue.selector, address(foreign)));
        discovery.register(address(foreign));
    }

    /// @dev The Settler accepts every factory venue, but each venue's own settler still gates `fill`: once its owner
    /// repoints it, swaps through this Settler revert `NotSettler`, and pointing it back restores them.
    function test_repointedVenueRejectsThisSettler() public {
        vm.prank(makerA);
        venueA.setSettler(makeAddr("privateSettler"));
        uint256[12] memory before = _balances();
        vm.expectRevert(IVenue.NotSettler.selector);
        _swapExactIn(taker, address(eur), address(usd), _request(venueA, pairA, 100e6), 0);
        _assertUnchanged(before);

        vm.prank(makerA);
        venueA.setSettler(address(settler));
        assertGt(_swapExactIn(taker, address(eur), address(usd), _request(venueA, pairA, 100e6), 0), 0);
    }

    /// @dev A venue from another factory, even one pointed at this Settler, is not a venue to this Settler.
    function test_unknownVenue_foreignFactoryCloneIsRejected() public {
        VenueFactory otherFactory = CoreDeploy.factoryWith(address(settler));
        vm.startPrank(makerA);
        Venue foreign = Venue(otherFactory.createVenue(makerA, "A"));
        uint16 p = foreign.addPair(address(eur), address(usd), UNIT);
        foreign.setShape(p, 0, _shapeA());
        vm.stopPrank();
        _setAccess(foreign, p, IVenue.AccessMode.Open);
        _post(foreign, p, _fields(MID_A));
        usd.mint(address(foreign), INVENTORY);

        vm.expectRevert(abi.encodeWithSelector(ISettler.UnknownVenue.selector, address(foreign)));
        _swapExactIn(taker, address(eur), address(usd), _request(foreign, p, 100e6), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Self-only swaps
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Every output goes to the caller: two takers swapping the same pool each receive their own output, and
    /// nobody else's balance moves.
    function test_output_goesToTheCaller() public {
        SwapParams memory fills = _request(venueA, pairA, 100e6);
        uint256 takerUsd = usd.balanceOf(taker);
        uint256 otherUsd = usd.balanceOf(taker2);
        uint256 out = _swapExactIn(taker, address(eur), address(usd), fills, 0);
        assertEq(usd.balanceOf(taker), takerUsd + out);
        assertEq(usd.balanceOf(taker2), otherUsd);

        uint256 paid = _swapExactOut(taker2, address(eur), address(usd), fills, type(uint256).max);
        assertGt(paid, 0);
        assertEq(usd.balanceOf(taker2), otherUsd + 100e6);
        assertEq(usd.balanceOf(taker), takerUsd + out);
        assertEq(usd.balanceOf(address(settler)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Halts, closes and expiry
    // ---------------------------------------------------------------------------------------------------------------

    function _request(uint256 amount) internal view returns (SwapParams memory) {
        return _request(venueB, pairB, amount);
    }

    function test_singleSwap_haltedVenueRevertsTheWholeSwap() public {
        vm.prank(updaterB);
        venueB.setHalted(true);
        uint256[12] memory before = _balances();

        vm.expectRevert(IVenue.VenueHalted.selector);
        _swapExactIn(taker, address(eur), address(usd), _request(100e6), 0);
        vm.expectRevert(IVenue.VenueHalted.selector);
        _swapExactOut(taker, address(usd), address(eur), _request(100e6), type(uint256).max);
        _assertUnchanged(before);

        // Only the owner can reopen it; then the same swap fills.
        vm.prank(updaterB);
        vm.expectRevert(IVenue.NotOwner.selector);
        venueB.setHalted(false);
        vm.prank(makerB);
        venueB.setHalted(false);
        _swapExactIn(taker, address(eur), address(usd), _request(100e6), 0);
    }

    function test_singleSwap_closedPairRevertsTheWholeSwap() public {
        vm.prank(updaterB);
        venueB.closePair(pairB);
        assertEq(uint8(venueB.pair(pairB).access), uint8(IVenue.AccessMode.Closed));
        uint256[12] memory before = _balances();

        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _swapExactIn(taker, address(eur), address(usd), _request(100e6), 0);
        // `quote` skips the access check, so exact output gets as far as the pool's fill.
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        _swapExactOut(taker, address(usd), address(eur), _request(100e6), type(uint256).max);
        _assertUnchanged(before);
    }

    function test_singleSwap_expiredQuoteRevertsTheWholeSwap() public {
        // A and C refresh with a long TTL; B's quote lapses.
        HotWord.Fields memory f = _fields(MID_A);
        f.validUntil = uint40(block.timestamp) + 1 hours;
        _post(venueA, pairA, f);
        f.mid = MID_C;
        _post(venueC, pairC, f);
        uint40 validUntilB = HotWord.validUntil(venueB.hotWord(pairB));
        vm.warp(uint256(validUntilB) + 1);
        uint256[12] memory before = _balances();

        vm.expectRevert(abi.encodeWithSelector(IVenue.QuoteExpired.selector, validUntilB));
        _swapExactIn(taker, address(eur), address(usd), _request(100e6), 0);
        _assertUnchanged(before);
    }

    /// @dev A contract with `code` as its runtime over the slots a venue's owner, settler, pending owner and updater
    /// checks read: `owner_` owns it, this Settler settles it, and `hidden` is its pending owner and an updater.
    function _forgeVenue(bytes memory code, address owner_, address hidden) internal returns (Venue) {
        bytes32[] memory slots = new bytes32[](4);
        bytes32[] memory values = new bytes32[](4);
        (slots[0], values[0]) = (bytes32(uint256(0)), bytes32(uint256(uint160(owner_))));
        (slots[1], values[1]) = (bytes32(uint256(1)), bytes32(uint256(uint160(address(settler)))));
        (slots[2], values[2]) = (bytes32(uint256(2)), bytes32(uint256(uint160(hidden))));
        (slots[3], values[3]) = (keccak256(abi.encode(hidden, uint256(3))), bytes32(uint256(1)));
        return Venue(Forgery.deploy(code, slots, values));
    }
}
