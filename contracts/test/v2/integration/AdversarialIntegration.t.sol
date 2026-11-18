// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapParams } from "../utils/SwapParams.sol";

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ISettler } from "../../../src/v2/interfaces/ISettler.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { VenueHookFlags } from "../../../src/v2/interfaces/IVenueHook.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { CallbackHook, MakerBot } from "./utils/Actors.sol";
import { IntegrationFixture } from "./utils/IntegrationFixture.sol";
import { MockSilentTIP20 } from "../mocks/MockSilentTIP20.sol";

/// @notice What a hostile hook, a lying input token or a fast-moving maker can do to a swap in flight: reentry into the
/// Settler and into venues, `hookTake` abuse, a pull that reports success without delivering, and a quote moved between
/// an exact-output fill's `quote` and its `fill`.
contract AdversarialIntegrationTest is IntegrationFixture {
    CallbackHook internal evil;

    function setUp() public override {
        super.setUp();
        evil = new CallbackHook();
        eur.mint(address(evil), FUNDS);
        usd.mint(address(evil), FUNDS);
        evil.execute(address(eur), abi.encodeWithSignature("approve(address,uint256)", address(settler), FUNDS));
        evil.execute(address(usd), abi.encodeWithSignature("approve(address,uint256)", address(settler), FUNDS));
        vm.startPrank(makerA);
        venueA.setPairHook(pairA, address(evil), VenueHookFlags.ALL);
        // The worst case: the maker also gave its hook the updater key.
        venueA.setUpdater(address(evil), true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Malicious hook
    // ---------------------------------------------------------------------------------------------------------------

    function _nestedSwap(bool exactIn) internal view returns (bytes memory) {
        SwapParams memory fills = _request(venueB, pairB, 10e6);
        return exactIn
            ? abi.encodeCall(
                ISettler.swapExactIn,
                (
                    fills.venue,
                    fills.pairIndex,
                    address(eur),
                    address(usd),
                    fills.amount,
                    0,
                    fills.sponsorId,
                    _deadline(),
                    REF
                )
            )
            : abi.encodeCall(
                ISettler.swapExactOut,
                (
                    fills.venue,
                    fills.pairIndex,
                    address(eur),
                    address(usd),
                    fills.amount,
                    type(uint256).max,
                    fills.sponsorId,
                    _deadline(),
                    REF
                )
            );
    }

    function test_hook_reenteringTheSettlerRevertsTheSwap() public {
        uint256[12] memory before = _balances();
        evil.addAction(CallbackHook.Phase.Before, address(settler), _nestedSwap(true), true);
        vm.expectRevert(ISettler.Reentrancy.selector);
        _swapExactIn(taker, address(eur), address(usd), _request(venueA, pairA, 100e6), 0);

        evil.clearActions();
        evil.addAction(CallbackHook.Phase.After, address(settler), _nestedSwap(false), true);
        vm.expectRevert(ISettler.Reentrancy.selector);
        _swapExactOut(taker, address(usd), address(eur), _request(venueA, pairA, 100e6), type(uint256).max);
        _assertUnchanged(before);
    }

    /// @dev Every reentry a hook might try fails on its own guard, and a hook that swallows the failures changes
    /// nothing: the swap settles exactly as it would have without them.
    function test_hook_everyReentryFailsAndChangesNothing() public {
        bytes memory fillB =
            abi.encodeCall(IVenue.fill, (pairB, address(eur), address(usd), 1e6, true, address(evil), HOME, REF));
        bytes memory fillA =
            abi.encodeCall(IVenue.fill, (pairA, address(eur), address(usd), 1e6, true, address(evil), HOME, REF));
        HotWord.Fields memory f = _fields(2e18);
        bytes memory repost = abi.encodeCall(IVenue.post, (abi.encodePacked(pairA, _nextHot(venueA, pairA, f))));

        CallbackHook.Phase[2] memory phases = [CallbackHook.Phase.Before, CallbackHook.Phase.After];
        for (uint256 p; p < 2; ++p) {
            evil.addAction(phases[p], address(settler), _nestedSwap(true), false);
            evil.addAction(phases[p], address(settler), _nestedSwap(false), false);
            evil.addAction(phases[p], address(venueB), fillB, false);
            evil.addAction(phases[p], address(venueA), fillA, false);
            evil.addAction(phases[p], address(venueA), repost, false);
            evil.addAction(phases[p], address(venueB), abi.encodeCall(IVenue.hookTake, (address(eur), 1)), false);
        }
        // Inside its own window: the output token, or more than the input.
        evil.addAction(
            CallbackHook.Phase.After, address(venueA), abi.encodeCall(IVenue.hookTake, (address(usd), 1)), false
        );
        evil.addAction(
            CallbackHook.Phase.After, address(venueA), abi.encodeCall(IVenue.hookTake, (address(eur), 100e6 + 1)), false
        );
        // Before the window opens.
        evil.addAction(
            CallbackHook.Phase.Before, address(venueA), abi.encodeCall(IVenue.hookTake, (address(eur), 1)), false
        );

        (, uint256 outA,) = _expect(venueA, pairA, true, true, 100e6);
        bytes32 hotA = venueA.hotWord(pairA);
        uint256 evilEur = eur.balanceOf(address(evil));
        uint256 takerUsd = usd.balanceOf(taker);

        uint256 out = _swapExactIn(taker, address(eur), address(usd), _request(venueA, pairA, 100e6), outA);
        assertEq(out, outA);
        assertEq(usd.balanceOf(taker), takerUsd + outA);
        assertEq(venueA.hotWord(pairA), hotA);
        assertEq(eur.balanceOf(address(evil)), evilEur);
        assertEq(eur.balanceOf(address(venueA)), INVENTORY + 100e6);
        assertEq(eur.balanceOf(address(venueB)), INVENTORY);

        bytes4 reentrant = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
        bytes4[6] memory perPhase = [
            ISettler.Reentrancy.selector,
            ISettler.Reentrancy.selector,
            IVenue.NotSettler.selector,
            reentrant,
            reentrant,
            IVenue.HookTakeNotAllowed.selector
        ];
        CallbackHook.Outcome[] memory outcomes = evil.outcomes();
        // Run order: beforeFill's seven actions, then afterFill's eight.
        assertEq(outcomes.length, 15);
        for (uint256 i; i < 6; ++i) {
            assertFalse(outcomes[i].ok);
            assertEq(outcomes[i].selector, perPhase[i], "before");
            assertFalse(outcomes[7 + i].ok);
            assertEq(outcomes[7 + i].selector, perPhase[i], "after");
        }
        assertEq(outcomes[6].selector, IVenue.HookTakeNotAllowed.selector, "take before the window");
        assertEq(outcomes[13].selector, IVenue.HookTakeNotAllowed.selector, "take of the output token");
        assertEq(outcomes[14].selector, IVenue.HookTakeExceedsBudget.selector, "take beyond the input");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Input token that reports success without delivering
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A venue admits initialized TIP-20s through the canonical factory, and `fill` trusts its settler to have
    /// delivered the input. A hookless pair whose input token returns true without moving anything still pays nothing:
    /// the Settler requires the venue's exact credit before it calls `fill`, in both directions.
    function test_silentInputToken_neverReleasesOutput() public {
        MockSilentTIP20 silent = new MockSilentTIP20("SIL", 6);
        vm.prank(makerB);
        uint16 pair = venueB.addPair(address(silent), address(usd), UNIT);
        _setShape(venueB, pair, 0, _shapeB());
        _post(venueB, pair, _fields(MID_B));
        _setAccess(venueB, pair, IVenue.AccessMode.Open);
        silent.mint(taker, 100e6);
        silent.setSilent(true);
        uint256[12] memory before = _balances();
        (uint128 quotedIn,) = venueB.quote(pair, address(silent), address(usd), 50e6, false);
        vm.expectCall(address(venueB), abi.encodeWithSelector(IVenue.fill.selector), 0);

        vm.expectRevert(abi.encodeWithSelector(ISettler.VenueDeltaMismatch.selector, 50e6, 0));
        _swapExactIn(taker, address(silent), address(usd), _request(venueB, pair, 50e6), 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.VenueDeltaMismatch.selector, quotedIn, 0));
        _swapExactOut(taker, address(silent), address(usd), _request(venueB, pair, 50e6), type(uint256).max);
        _assertUnchanged(before);
        assertEq(silent.balanceOf(taker), 100e6);
        assertEq(silent.balanceOf(address(venueB)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Quote moved between quote and fill
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev B's bot reposts from inside the USD pull, the one window where the Settler has quoted B's fill but not yet
    /// filled it. B isn't locked there, so the post lands.
    function _armBot(HotWord.Fields memory f, uint256 fireOn) internal returns (MakerBot bot, bytes32 word) {
        bot = new MakerBot(IVenue(address(venueB)));
        vm.prank(makerB);
        venueB.setUpdater(address(bot), true);
        word = _nextHot(venueB, pairB, f);
        bot.arm(abi.encodePacked(pairB, word), fireOn);
        usd.setReentry(address(bot), abi.encodeCall(MakerBot.poke, ()));
    }

    function test_quoteDrift_priceMoveRevertsFillMismatch() public {
        (MakerBot bot, bytes32 word) = _armBot(_fields(1.09e18), 1);
        (uint128 quotedIn,) = venueB.quote(pairB, address(usd), address(eur), 100e6, false);
        (uint256 driftedIn,,) = _expectHot(venueB, pairB, word, false, false, 100e6);
        assertGt(driftedIn, quotedIn);

        vm.expectRevert(
            abi.encodeWithSelector(ISettler.FillMismatch.selector, quotedIn, driftedIn, uint256(100e6), uint256(100e6))
        );
        _swapExactOut(taker, address(usd), address(eur), _request(venueB, pairB, 100e6), type(uint256).max);
        assertFalse(bot.fired(), "the repost is undone with the swap");
    }

    /// @dev A repost that only renews the quote (new seq, later expiry, same curve) lands mid-swap and the fill
    /// still matches the quote.
    function test_quoteDrift_priceNeutralRepostSettlesConsistently() public {
        HotWord.Fields memory f = _fields(MID_B);
        f.validUntil = uint40(block.timestamp) + 1 hours;
        (MakerBot bot, bytes32 word) = _armBot(f, 1);
        (uint128 quotedIn,) = venueB.quote(pairB, address(usd), address(eur), 100e6, false);

        uint256 paid = _swapExactOut(taker, address(usd), address(eur), _request(venueB, pairB, 100e6), quotedIn);
        assertEq(paid, quotedIn);
        assertTrue(bot.fired());
        assertEq(venueB.hotWord(pairB), word);
    }

    /// @dev Exact input has no per-fill quote: the fill fills at the curve live at fill time, and the taker's
    /// `minAmountOut` is the only guard.
    function test_quoteDrift_exactInFillsAtTheLiveCurve() public {
        (, uint256 before,) = _expect(venueB, pairB, false, true, 100e6);
        (, bytes32 word) = _armBot(_fields(1.09e18), 1);
        (, uint256 drifted,) = _expectHot(venueB, pairB, word, false, true, 100e6);
        assertLt(drifted, before);
        SwapParams memory fills = _request(venueB, pairB, 100e6);

        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientOutput.selector, drifted, before));
        _swapExactIn(taker, address(usd), address(eur), fills, before);

        assertEq(_swapExactIn(taker, address(usd), address(eur), fills, drifted), drifted);
    }
}
