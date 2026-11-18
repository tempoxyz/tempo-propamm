// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { ISettler } from "../../../src/v2/interfaces/ISettler.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { VenueHookFlags } from "../../../src/v2/interfaces/IVenueHook.sol";
import { Settler } from "../../../src/v2/Settler.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { CallbackHook } from "../integration/utils/Actors.sol";
import { IntegrationFixture } from "../integration/utils/IntegrationFixture.sol";

/// @notice Randomly interleaves hostile callbacks, nonstandard tokens, and ordinary trades on one posted ladder.
/// Failures must undo even a Settler input pull and the Venue's tentative consumption; successes must account exactly.
contract V2AdversarialHandler is Test {
    Settler internal immutable settler;
    Venue internal immutable venue;
    MockTIP20V2 internal immutable base;
    MockTIP20V2 internal immutable quoteToken;
    CallbackHook internal immutable hook;
    address internal immutable taker;
    uint16 internal immutable pairIndex;

    uint256 public successes;
    uint256 public rolledBack;
    uint256 public strictCallbackRejections;
    uint256 public tokenRejections;
    uint256 public swallowedCallbackFailures;
    uint256 public exactOutAttempts;

    struct Snapshot {
        uint256 takerBase;
        uint256 takerQuote;
        uint256 venueBase;
        uint256 venueQuote;
        uint256 hookBase;
        uint256 hookQuote;
        uint128 bids;
        uint128 asks;
    }

    constructor(
        Settler settler_,
        Venue venue_,
        MockTIP20V2 base_,
        MockTIP20V2 quote_,
        CallbackHook hook_,
        address taker_,
        uint16 pairIndex_
    ) {
        settler = settler_;
        venue = venue_;
        base = base_;
        quoteToken = quote_;
        hook = hook_;
        taker = taker_;
        pairIndex = pairIndex_;
    }

    function attempt(uint256 seed) external {
        uint256 mode = seed % 6;
        bool baseIn = (seed / 6) % 2 == 0;
        bool exactOut = (seed / 12) % 2 != 0;
        if (exactOut) ++exactOutAttempts;
        MockTIP20V2 input = baseIn ? base : quoteToken;
        MockTIP20V2 output = baseIn ? quoteToken : base;
        uint128 amount = uint128(1e6 + (seed / 24) % 3 * 1e6);

        hook.clearActions();
        if (mode == 0) {
            bytes memory nested = abi.encodeCall(
                ISettler.swapExactIn,
                (
                    address(venue),
                    pairIndex,
                    address(input),
                    address(output),
                    1e6,
                    0,
                    0,
                    uint40(block.timestamp + 30),
                    bytes32(0)
                )
            );
            hook.addAction(CallbackHook.Phase.Before, address(settler), nested, true);
        } else if (mode == 1 || mode == 4) {
            bytes memory wrongTake = abi.encodeCall(IVenue.hookTake, (address(output), 1));
            hook.addAction(CallbackHook.Phase.After, address(venue), wrongTake, mode == 1);
        } else if (mode == 2) {
            input.setFeeBps(100);
        } else if (mode == 3) {
            output.setFeeBps(100);
        }

        Snapshot memory before = _snapshot();
        bytes32 hot = venue.hotWord(pairIndex);
        uint256 requested = amount;
        uint256 quotedIn;
        uint256 quotedOut;
        (quotedIn, quotedOut) = venue.quote(pairIndex, address(input), address(output), amount, !exactOut);
        if (exactOut) requested = quotedIn;
        uint256 result;

        vm.prank(taker);
        if (mode < 4) {
            if (mode == 0) {
                vm.expectRevert(ISettler.Reentrancy.selector);
            } else if (mode == 1) {
                vm.expectRevert(IVenue.HookTakeNotAllowed.selector);
            } else if (mode == 2) {
                vm.expectRevert(
                    abi.encodeWithSelector(ISettler.VenueDeltaMismatch.selector, quotedIn, quotedIn - quotedIn / 100)
                );
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IVenue.BalanceDeltaMismatch.selector,
                        address(output),
                        taker,
                        quotedOut,
                        quotedOut - quotedOut / 100
                    )
                );
            }
        }
        if (exactOut) {
            result = settler.swapExactOut(
                address(venue),
                pairIndex,
                address(input),
                address(output),
                amount,
                type(uint256).max,
                0,
                uint40(block.timestamp + 30),
                bytes32(seed)
            );
        } else {
            result = settler.swapExactIn(
                address(venue),
                pairIndex,
                address(input),
                address(output),
                amount,
                0,
                0,
                uint40(block.timestamp + 30),
                bytes32(seed)
            );
        }

        if (mode < 4) {
            ++rolledBack;
            if (mode < 2) ++strictCallbackRejections;
            else ++tokenRejections;
            _assertSame(before, _snapshot());
        } else {
            ++successes;
            if (mode == 4) {
                ++swallowedCallbackFailures;
                CallbackHook.Outcome[] memory outcomes = hook.outcomes();
                assertEq(outcomes.length, 1, "one swallowed callback");
                assertFalse(outcomes[0].ok, "wrong-token take succeeded");
                assertEq(outcomes[0].selector, IVenue.HookTakeNotAllowed.selector, "wrong-token reason");
            }
            assertEq(result, exactOut ? quotedIn : quotedOut, "swap amount");
            _assertFilled(before, _snapshot(), baseIn, quotedIn, quotedOut);
        }
        assertEq(venue.hotWord(pairIndex), hot, "callback reposted the ladder");
        assertEq(base.balanceOf(address(settler)), 0, "base held by Settler");
        assertEq(quoteToken.balanceOf(address(settler)), 0, "quote held by Settler");
        input.setFeeBps(0);
        output.setFeeBps(0);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        (s.bids, s.asks) = venue.consumed(pairIndex);
        s.takerBase = base.balanceOf(taker);
        s.takerQuote = quoteToken.balanceOf(taker);
        s.venueBase = base.balanceOf(address(venue));
        s.venueQuote = quoteToken.balanceOf(address(venue));
        s.hookBase = base.balanceOf(address(hook));
        s.hookQuote = quoteToken.balanceOf(address(hook));
    }

    function _assertSame(Snapshot memory a, Snapshot memory b) internal pure {
        assert(a.takerBase == b.takerBase && a.takerQuote == b.takerQuote);
        assert(a.venueBase == b.venueBase && a.venueQuote == b.venueQuote);
        assert(a.hookBase == b.hookBase && a.hookQuote == b.hookQuote);
        assert(a.bids == b.bids && a.asks == b.asks);
    }

    function _assertFilled(Snapshot memory a, Snapshot memory b, bool baseIn, uint256 amountIn, uint256 amountOut)
        internal
        pure
    {
        assert(a.hookBase == b.hookBase && a.hookQuote == b.hookQuote);
        if (baseIn) {
            assertEq(a.takerBase - b.takerBase, amountIn, "base paid");
            assertEq(b.takerQuote - a.takerQuote, amountOut, "quote received");
            assertEq(b.venueBase - a.venueBase, amountIn, "venue base credit");
            assertEq(a.venueQuote - b.venueQuote, amountOut, "venue quote debit");
            assertEq(b.bids - a.bids, amountIn, "bid depth");
            assertEq(b.asks, a.asks, "ask depth unchanged");
        } else {
            assertEq(a.takerQuote - b.takerQuote, amountIn, "quote paid");
            assertEq(b.takerBase - a.takerBase, amountOut, "base received");
            assertEq(b.venueQuote - a.venueQuote, amountIn, "venue quote credit");
            assertEq(a.venueBase - b.venueBase, amountOut, "venue base debit");
            assertEq(b.asks - a.asks, amountOut, "ask depth");
            assertEq(b.bids, a.bids, "bid depth unchanged");
        }
    }
}

contract V2AdversarialInvariantTest is StdInvariant, IntegrationFixture {
    V2AdversarialHandler internal handler;

    function setUp() public override {
        super.setUp();
        CallbackHook hook = new CallbackHook();
        vm.prank(makerA);
        venueA.setPairHook(pairA, address(hook), VenueHookFlags.ALL);
        handler = new V2AdversarialHandler(settler, venueA, eur, usd, hook, taker, pairA);
        vm.prank(taker);
        eur.approve(address(settler), type(uint256).max);
        vm.prank(taker);
        usd.approve(address(settler), type(uint256).max);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = V2AdversarialHandler.attempt.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_hostileSwapsRemainAtomic() public view {
        assertEq(eur.balanceOf(address(settler)), 0);
        assertEq(usd.balanceOf(address(settler)), 0);
    }

    function test_reachesEveryFaultAndSuccessfulMode() public {
        for (uint256 mode; mode < 6; ++mode) {
            handler.attempt(mode);
            handler.attempt(mode + 6 + 12);
        }
        assertEq(handler.strictCallbackRejections(), 4);
        assertEq(handler.tokenRejections(), 4);
        assertEq(handler.swallowedCallbackFailures(), 2);
        assertEq(handler.successes(), 4);
        assertEq(handler.rolledBack(), 8);
        assertEq(handler.exactOutAttempts(), 6);
    }
}
