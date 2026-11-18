// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ITIP20 } from "../../src/interfaces/ITIP20.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { IVenueHook, VenueHookFlags } from "../../src/v2/interfaces/IVenueHook.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { MockGuardedTIP20 } from "./mocks/MockGuardedTIP20.sol";
import { MockSilentTIP20 } from "./mocks/MockSilentTIP20.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { MockVenueHook } from "./mocks/MockVenueHook.sol";
import { VenueFixture } from "./utils/VenueFixture.sol";

contract VenueHooksTest is VenueFixture {
    uint8 internal constant BEFORE = VenueHookFlags.BEFORE_FILL;
    uint8 internal constant AFTER = VenueHookFlags.AFTER_FILL;
    uint8 internal constant TAKE = VenueHookFlags.TAKE_INPUT;
    uint8 internal constant ALL = VenueHookFlags.ALL;
    uint128 internal constant AMOUNT = 100e6;
    /// @dev A sponsor id the `Open` fixture pair doesn't check, so the hook sees the taker's claim as given.
    uint64 internal constant SPONSOR_ID = 42;

    MockVenueHook internal hook;

    function setUp() public override {
        super.setUp();
        hook = new MockVenueHook(venue, ALL);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // setPairHook
    // ---------------------------------------------------------------------------------------------------------------

    function test_setPairHook_flagValidation() public {
        uint8[6] memory incoherent = [uint8(8), 16, 128, 255, TAKE, BEFORE | TAKE];
        vm.startPrank(owner);
        for (uint256 i; i < incoherent.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHookFlags.selector, incoherent[i]));
            venue.setPairHook(pairId, address(hook), incoherent[i]);
        }
        // A zero hook needs zero flags, and a real hook needs some.
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHookFlags.selector, BEFORE));
        venue.setPairHook(pairId, address(0), BEFORE);
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHookFlags.selector, uint8(0)));
        venue.setPairHook(pairId, address(hook), 0);
        // A hook without code supports nothing.
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHookFlags.selector, BEFORE));
        venue.setPairHook(pairId, makeAddr("eoa"), BEFORE);
        vm.stopPrank();

        hook.setFlags(BEFORE, false);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHookFlags.selector, AFTER));
        venue.setPairHook(pairId, address(hook), AFTER);
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHookFlags.selector, BEFORE | AFTER));
        venue.setPairHook(pairId, address(hook), BEFORE | AFTER);
        venue.setPairHook(pairId, address(hook), BEFORE);
        vm.stopPrank();

        hook.setFlags(ALL, true);
        vm.expectRevert(MockVenueHook.HookBoom.selector);
        vm.prank(owner);
        venue.setPairHook(pairId, address(hook), BEFORE);
    }

    function test_setPairHook_installReplaceRemove() public {
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairHookSet(pairId, address(hook), ALL);
        vm.prank(owner);
        venue.setPairHook(pairId, address(hook), ALL);
        IVenue.Pair memory p = venue.pair(pairId);
        assertEq(p.hook, address(hook));
        assertEq(p.hookFlags, ALL);
        // The flags share the pair's second config slot; the rest of the pair is untouched.
        assertEq(p.quote, address(usd));
        assertEq(p.sizeUnit, UNIT);

        MockVenueHook other = new MockVenueHook(venue, AFTER);
        vm.prank(owner);
        venue.setPairHook(pairId, address(other), AFTER);
        assertEq(venue.pair(pairId).hook, address(other));
        assertEq(venue.pair(pairId).hookFlags, AFTER);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairHookSet(pairId, address(0), 0);
        vm.prank(owner);
        venue.setPairHook(pairId, address(0), 0);
        assertEq(venue.pair(pairId).hook, address(0));
        assertEq(venue.pair(pairId).hookFlags, 0);
        assertEq(vm.load(address(venue), _mappingSlot(pairId, SLOT_HOOKS)), bytes32(0));
    }

    function test_setPairHook_ownerKeyOnly() public {
        address[3] memory callers = [updater, settler, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(callers[i]);
            venue.setPairHook(pairId, address(hook), ALL);
        }
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(4)));
        vm.prank(owner);
        venue.setPairHook(4, address(hook), ALL);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Honest just-in-time hook
    // ---------------------------------------------------------------------------------------------------------------

    function test_hook_honestJitPullsBeforeAndSweepsAfter() public {
        uint256 refill = 5e6;
        _install(ALL, MockVenueHook.Action.TopUp, MockVenueHook.Action.Take, 0);
        hook.setAmounts(refill, 0);
        _drain(usd);
        usd.mint(address(hook), 1000e6);

        (uint256 expectedIn, uint256 expectedOut,) = _expect(pairId, true, true, AMOUNT);
        (uint128 quotedIn, uint128 quotedOut) = venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
        assertEq(quotedIn, expectedIn);
        assertEq(quotedOut, expectedOut);

        eur.mint(address(venue), AMOUNT);
        bytes32 hot = venue.hotWord(pairId);
        // The payout goes to the taker and the sweep to the hook, both with the fill's ref as memo.
        vm.expectCall(address(usd), abi.encodeCall(ITIP20.transferWithMemo, (taker, expectedOut, REF)), 1);
        vm.expectCall(address(eur), abi.encodeCall(ITIP20.transferWithMemo, (address(hook), AMOUNT, REF)), 1);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.Fill(
            pairId, taker, REF, SPONSOR_ID, true, AMOUNT, uint128(expectedOut), HotWord.mid(hot), HotWord.seq(hot)
        );
        vm.prank(settler);
        (uint128 amountIn, uint128 amountOut) =
            venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker, SPONSOR_ID, REF);

        assertEq(amountIn, AMOUNT);
        assertEq(amountOut, expectedOut);
        assertEq(usd.balanceOf(taker), expectedOut);
        assertEq(usd.balanceOf(address(venue)), refill);
        assertEq(usd.balanceOf(address(hook)), 1000e6 - expectedOut - refill);
        assertEq(eur.balanceOf(address(venue)), INVENTORY);
        assertEq(eur.balanceOf(address(hook)), AMOUNT);
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 1);

        _assertFill(hook.beforeContext(), AMOUNT, uint128(expectedOut), true, true, SPONSOR_ID, hot);
        _assertFill(hook.afterContext(), AMOUNT, uint128(expectedOut), true, true, SPONSOR_ID, hot);
    }

    function test_hook_fillContextCarriesTheSponsorIdAndExactOut() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);

        (uint128 quotedIn,) = venue.quote(pairId, address(usd), address(eur), AMOUNT, false);
        usd.mint(address(venue), quotedIn);
        vm.prank(settler);
        venue.fill(pairId, address(usd), address(eur), AMOUNT, false, taker, HOME, REF);

        _assertFill(hook.beforeContext(), quotedIn, AMOUNT, false, false, HOME, venue.hotWord(pairId));
        _assertFill(hook.afterContext(), quotedIn, AMOUNT, false, false, HOME, venue.hotWord(pairId));
        assertEq(eur.balanceOf(taker), AMOUNT);
    }

    function test_hook_jitShortfallReverts() public {
        _install(ALL, MockVenueHook.Action.TopUp, MockVenueHook.Action.None, 0);
        _drain(usd);
        usd.mint(address(hook), 50e6);
        (, uint256 expectedOut,) = _expect(pairId, true, true, AMOUNT);

        bytes memory err =
            abi.encodeWithSelector(IVenue.InsufficientInventory.selector, address(usd), 50e6, expectedOut);
        vm.expectRevert(err);
        venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(err);
    }

    function test_hook_onlyFlaggedCallbacksRun() public {
        _install(BEFORE, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        _fill(pairId, true, true, AMOUNT);
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 0);

        _install(AFTER, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        _fill(pairId, true, true, AMOUNT);
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 1);
    }

    function test_hook_otherPairsNeverCallIt() public {
        _install(ALL, MockVenueHook.Action.Revert, MockVenueHook.Action.Revert, 0);
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        vm.startPrank(owner);
        uint16 other = venue.addPair(address(gbp), address(usd), UNIT);
        venue.setShape(other, 0, _defaultShape());
        vm.stopPrank();
        _setAccess(other, IVenue.AccessMode.Open);
        _post(other, _hot(2));
        gbp.mint(address(venue), AMOUNT);
        vm.prank(settler);
        venue.fill(other, address(gbp), address(usd), AMOUNT, true, taker, HOME, REF);
        assertEq(hook.beforeCalls(), 0);
        assertEq(venue.hookLiquidity(other, address(usd)), 0);
    }

    function test_hook_viewsAndQuoteWorkWhileLocked() public {
        _install(ALL, MockVenueHook.Action.Observe, MockVenueHook.Action.None, 0);
        (, uint256 freshOut,) = _expect(pairId, true, true, AMOUNT);
        _fill(pairId, true, true, AMOUNT);
        // Hooks can read the posted ladder's quote mid-fill, from the depth after this fill: the venue stores the
        // fill's consumption before any hook runs.
        (, uint256 deeperOut,) = _expect(pairId, true, true, AMOUNT);
        assertEq(hook.observedQuoteIn(), AMOUNT);
        assertEq(hook.observedQuoteOut(), deeperOut);
        assertLe(deeperOut, freshOut);
    }

    function test_hook_mayAddBalance() public {
        _install(ALL, MockVenueHook.Action.Donate, MockVenueHook.Action.Donate, 1e6);
        eur.mint(address(hook), 2e6);
        usd.mint(address(hook), 2e6);
        (, uint128 amountOut) = _fill(pairId, true, true, AMOUNT);
        assertEq(eur.balanceOf(address(venue)), INVENTORY + AMOUNT + 2e6);
        assertEq(usd.balanceOf(address(venue)), INVENTORY - amountOut + 2e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Balance rules around the callbacks
    // ---------------------------------------------------------------------------------------------------------------

    function test_hook_beforeFillCantReduceInput() public {
        _install(ALL, MockVenueHook.Action.ReduceIn, MockVenueHook.Action.None, 1);
        eur.mint(address(venue), AMOUNT);
        uint256 held = INVENTORY + AMOUNT;
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookReducedBalance.selector, address(eur), held, held - 1));
    }

    function test_hook_beforeFillCantReduceOutput() public {
        _install(ALL, MockVenueHook.Action.ReduceOut, MockVenueHook.Action.None, 1);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(
            abi.encodeWithSelector(IVenue.HookReducedBalance.selector, address(usd), INVENTORY, INVENTORY - 1)
        );
    }

    function test_hook_afterFillCantReduceOutput() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.ReduceOut, 1);
        (, uint256 expectedOut,) = _expect(pairId, true, true, AMOUNT);
        uint256 held = INVENTORY - expectedOut;
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookReducedBalance.selector, address(usd), held, held - 1));
    }

    function test_hook_afterFillCantReduceInputWithoutTake() public {
        _install(BEFORE | AFTER, MockVenueHook.Action.None, MockVenueHook.Action.ReduceIn, 1);
        eur.mint(address(venue), AMOUNT);
        uint256 held = INVENTORY + AMOUNT;
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookReducedBalance.selector, address(eur), held, held - 1));
    }

    function test_hook_afterFillCantReduceInputBeyondWhatItTook() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.TakeThenReduceIn, 1);
        eur.mint(address(venue), AMOUNT);
        // Floor: the balance before `afterFill` (INVENTORY + AMOUNT) less the AMOUNT taken.
        _expectFillRevert(
            abi.encodeWithSelector(IVenue.HookReducedBalance.selector, address(eur), INVENTORY, INVENTORY - 1)
        );
    }

    function test_hook_wrongSelector() public {
        _install(ALL, MockVenueHook.Action.WrongSelector, MockVenueHook.Action.None, 0);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(
            abi.encodeWithSelector(IVenue.HookCallbackFailed.selector, address(hook), IVenueHook.beforeFill.selector)
        );
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.WrongSelector, 0);
        _expectFillRevert(
            abi.encodeWithSelector(IVenue.HookCallbackFailed.selector, address(hook), IVenueHook.afterFill.selector)
        );
    }

    function test_hook_revertBlocksOnlyItsPairsFills() public {
        _install(ALL, MockVenueHook.Action.Revert, MockVenueHook.Action.None, 0);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(MockVenueHook.HookBoom.selector));
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.Revert, 0);
        _expectFillRevert(abi.encodeWithSelector(MockVenueHook.HookBoom.selector));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // hookTake
    // ---------------------------------------------------------------------------------------------------------------

    function test_hookTake_splitWithinBudget() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.TakeTwice, AMOUNT / 2);
        // Each take pays the hook with the fill's ref as memo.
        vm.expectCall(address(eur), abi.encodeCall(ITIP20.transferWithMemo, (address(hook), AMOUNT / 2, REF)), 2);
        _fill(pairId, true, true, AMOUNT);
        assertEq(eur.balanceOf(address(hook)), AMOUNT);
        assertEq(eur.balanceOf(address(venue)), INVENTORY);
    }

    function test_hookTake_overBudget() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.Take, AMOUNT + 1);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookTakeExceedsBudget.selector, AMOUNT + 1, AMOUNT));
    }

    function test_hookTake_cumulativeOverBudget() public {
        uint256 part = AMOUNT / 2 + 1;
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.TakeTwice, part);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookTakeExceedsBudget.selector, part, AMOUNT - part));
    }

    function test_hookTake_wrongToken() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.TakeWrongToken, 0);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookTakeNotAllowed.selector));
    }

    function test_hookTake_notDuringBeforeFill() public {
        _install(ALL, MockVenueHook.Action.Take, MockVenueHook.Action.None, 1);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookTakeNotAllowed.selector));
    }

    function test_hookTake_needsTakeInputFlag() public {
        _install(BEFORE | AFTER, MockVenueHook.Action.None, MockVenueHook.Action.Take, 1);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookTakeNotAllowed.selector));
    }

    function test_hookTake_notByANonHookDuringTheWindow() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.TakeViaAccomplice, 0);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(IVenue.HookTakeNotAllowed.selector));
    }

    function test_hookTake_outsideAFill() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        vm.expectRevert(IVenue.HookTakeNotAllowed.selector);
        vm.prank(stranger);
        venue.hookTake(address(eur), 1);
        vm.expectRevert(IVenue.HookTakeNotAllowed.selector);
        vm.prank(address(hook));
        venue.hookTake(address(eur), 1);
        vm.expectRevert(IVenue.HookTakeNotAllowed.selector);
        vm.prank(address(hook));
        venue.hookTake(address(0), 0);
    }

    function test_hookTake_windowClosesBeforeFillReturns() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        vm.prank(owner);
        venue.setSettler(address(hook));
        eur.mint(address(venue), AMOUNT);
        (, uint256 expectedOut,) = _expect(pairId, true, true, AMOUNT);

        // One transaction: the hook, as settler, fills (its afterFill runs with the window open), then tries to take.
        hook.fillThenTake(_fillCall(pairId, true, true, AMOUNT), address(eur), 1);
        assertEq(usd.balanceOf(taker), expectedOut);
        assertEq(hook.afterCalls(), 1);
        assertFalse(hook.lastCallOk());
        assertEq(hook.lastCallData(), abi.encodeWithSelector(IVenue.HookTakeNotAllowed.selector));
    }

    function test_hookTake_requiresExactVenueDelta() public {
        MockSilentTIP20 silent = new MockSilentTIP20("SIL", 6);
        vm.startPrank(owner);
        uint16 index = venue.addPair(address(silent), address(usd), UNIT);
        venue.setShape(index, 0, _defaultShape());
        venue.setPairHook(index, address(hook), ALL);
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        _post(index, _hot(2));
        hook.setActions(MockVenueHook.Action.None, MockVenueHook.Action.Take, 0);
        silent.mint(address(venue), AMOUNT);
        silent.setSilent(true);

        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(silent), address(venue), AMOUNT, 0)
        );
        vm.prank(settler);
        venue.fill(index, address(silent), address(usd), AMOUNT, true, taker, HOME, REF);
    }

    function test_hookTake_rejectsOverDebit() public {
        // A sender-paid fee on the input token: the venue would lose more than the hook took.
        MockSilentTIP20 skew = new MockSilentTIP20("SKEW", 6);
        vm.startPrank(owner);
        uint16 index = venue.addPair(address(skew), address(usd), UNIT);
        venue.setShape(index, 0, _defaultShape());
        venue.setPairHook(index, address(hook), ALL);
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        _post(index, _hot(2));
        hook.setActions(MockVenueHook.Action.None, MockVenueHook.Action.Take, 0);
        skew.mint(address(venue), AMOUNT + 5);
        skew.setSkew(5, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVenue.BalanceDeltaMismatch.selector, address(skew), address(venue), AMOUNT, AMOUNT + 5
            )
        );
        vm.prank(settler);
        venue.fill(index, address(skew), address(usd), AMOUNT, true, taker, HOME, REF);
    }

    function test_hookTake_rejectsHookCreditMismatch() public {
        // The venue's debit is exact, but the hook is credited more than it took.
        MockSilentTIP20 skew = new MockSilentTIP20("SKEW", 6);
        uint16 index = _hookedPair(address(skew));
        skew.mint(address(venue), AMOUNT);
        skew.setSkew(0, 5);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVenue.BalanceDeltaMismatch.selector, address(skew), address(hook), AMOUNT, AMOUNT + 5
            )
        );
        vm.prank(settler);
        venue.fill(index, address(skew), address(usd), AMOUNT, true, taker, HOME, REF);
    }

    /// @dev A hook whose own TIP-1028 receive policy doesn't accept its venue: on Tempo the take would land in the
    /// ReceivePolicyGuard, under a receipt that with the default originator recovery only the venue could claim, so
    /// the take must revert instead.
    function test_hookTake_receivePolicyBlockOnTheHookReverts() public {
        MockGuardedTIP20 guarded = new MockGuardedTIP20("GEUR");
        uint16 index = _hookedPair(address(guarded));
        guarded.mint(address(venue), AMOUNT);
        vm.prank(address(hook));
        guarded.setReceivePolicy(true, true, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(guarded), address(hook), AMOUNT, 0)
        );
        vm.prank(settler);
        venue.fill(index, address(guarded), address(usd), AMOUNT, true, taker, HOME, REF);

        vm.prank(address(hook));
        guarded.setSenderListed(address(venue), true);
        vm.prank(settler);
        venue.fill(index, address(guarded), address(usd), AMOUNT, true, taker, HOME, REF);
        assertEq(guarded.balanceOf(address(hook)), AMOUNT);
        assertEq(guarded.balanceOf(guarded.GUARD()), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reentry (the hook owns the venue, so only the lock can reject it)
    // ---------------------------------------------------------------------------------------------------------------

    function test_reentry_postWhileLocked() public {
        _makeHookOwner();
        bytes memory data = abi.encodeCall(IVenue.post, (_entry(pairId, _hot(3))));
        _expectReentryBlocked(BEFORE, true, data);
        _expectReentryBlocked(AFTER, false, data);
        // Outside a fill the same call passes auth.
        hook.execute(address(venue), data);
        assertEq(HotWord.seq(venue.hotWord(pairId)), 3);
    }

    function test_reentry_withdrawWhileLocked() public {
        _makeHookOwner();
        bytes memory data = abi.encodeCall(IVenue.withdraw, (address(usd), address(hook), 1, bytes32(0)));
        _expectReentryBlocked(BEFORE, true, data);
        _expectReentryBlocked(AFTER | TAKE, false, data);
        hook.execute(address(venue), data);
        assertEq(usd.balanceOf(address(hook)), 1);
    }

    function test_reentry_fillWhileLocked() public {
        _makeHookOwner();
        hook.execute(address(venue), abi.encodeCall(IVenue.setSettler, (address(hook))));
        bytes memory fillData = _fillCall(pairId, true, true, AMOUNT);
        eur.mint(address(venue), 2 * AMOUNT);

        _installAsHookOwner(BEFORE, MockVenueHook.Action.Reenter, MockVenueHook.Action.None);
        hook.setReentry(address(venue), fillData);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        hook.execute(address(venue), fillData);

        _installAsHookOwner(AFTER, MockVenueHook.Action.None, MockVenueHook.Action.Reenter);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        hook.execute(address(venue), fillData);

        // Outside the lock the hook, as settler, fills normally.
        _installAsHookOwner(ALL, MockVenueHook.Action.None, MockVenueHook.Action.None);
        hook.execute(address(venue), fillData);
        assertEq(hook.beforeCalls(), 1);
    }

    function test_reentry_everyOtherMutatorWhileLocked() public {
        _makeHookOwner();
        // The hook is also the pending owner, so only the lock can reject its acceptOwnership.
        hook.execute(address(venue), abi.encodeCall(IVenue.transferOwnership, (address(hook))));
        uint256[4] memory zero;
        bytes[25] memory calls = [
            abi.encodeCall(IVenue.resetHotWord, (pairId)),
            abi.encodeCall(IVenue.setShape, (pairId, 9, zero)),
            abi.encodeCall(IVenue.setMidBand, (pairId, 1, 2)),
            abi.encodeCall(IVenue.addPair, (address(usd), address(eur), UNIT)),
            abi.encodeCall(IVenue.removePair, (pairId)),
            abi.encodeCall(IVenue.setPairAccess, (pairId, IVenue.AccessMode.Listed)),
            abi.encodeCall(IVenue.closePair, (pairId)),
            abi.encodeCall(IVenue.setMembers, (pairId, 0, _one(stranger), true)),
            abi.encodeCall(IVenue.addSponsor, (7, stranger)),
            abi.encodeCall(IVenue.setSponsorEnabled, (7, false)),
            abi.encodeCall(IVenue.setPairSponsor, (pairId, 7, false)),
            abi.encodeCall(IVenue.transferSponsorAdmin, (7, stranger)),
            abi.encodeCall(IVenue.cancelSponsorAdminTransfer, (7)),
            abi.encodeCall(IVenue.acceptSponsorAdmin, (7)),
            abi.encodeCall(IVenue.resetSponsor, (7, stranger)),
            abi.encodeCall(IVenue.setDenied, (_one(stranger), true)),
            abi.encodeCall(IVenue.setHalted, (true)),
            abi.encodeCall(IVenue.setMaxTakerPriorityFee, (0)),
            abi.encodeCall(IVenue.enableTakerPriorityFeeCap, ()),
            abi.encodeCall(IVenue.setUpdater, (stranger, true)),
            abi.encodeCall(IVenue.setSettler, (stranger)),
            abi.encodeCall(IVenue.setPairHook, (pairId, address(0), 0)),
            abi.encodeCall(IVenue.transferOwnership, (stranger)),
            abi.encodeCall(IVenue.cancelOwnershipTransfer, ()),
            abi.encodeCall(IVenue.acceptOwnership, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            _expectReentryBlocked(BEFORE, true, calls[i]);
        }
        // `initialize` makes no external call, so it takes no lock; only the factory may call it, so a hook is refused.
        _expectReentryRejected(
            BEFORE, true, abi.encodeCall(IVenue.initialize, (stranger, stranger)), IVenue.NotFactory.selector
        );
        // Nothing the rejected calls tried stuck.
        assertEq(venue.pair(pairId).base, address(eur));
        assertEq(venue.settler(), settler);
        assertEq(venue.pendingOwner(), address(hook));
        (, uint96 maxMid) = venue.midBand(pairId);
        assertEq(maxMid, 0);
        assertEq(venue.maxTakerPriorityFee(), venue.NO_PRIORITY_FEE_CAP());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // hookLiquidity
    // ---------------------------------------------------------------------------------------------------------------

    function test_hookLiquidity_zeroWithoutBeforeFill() public {
        assertEq(venue.hookLiquidity(pairId, address(usd)), 0);
        _install(AFTER | TAKE, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Fixed, 1e12);
        vm.expectCall(address(hook), abi.encodeCall(IVenueHook.availableLiquidity, (address(usd))), 0);
        assertEq(venue.hookLiquidity(pairId, address(usd)), 0);
        assertEq(venue.hookLiquidity(99, address(usd)), 0);
    }

    function test_hookLiquidity_readsTheHookWithBeforeFill() public {
        _install(BEFORE, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        usd.mint(address(hook), 77e6);
        assertEq(venue.hookLiquidity(pairId, address(usd)), 77e6);
        assertEq(venue.hookLiquidity(pairId, address(eur)), 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Long, 5e6);
        assertEq(venue.hookLiquidity(pairId, address(usd)), 5e6);
    }

    function test_hookLiquidity_brokenViewsYieldZero() public {
        _install(BEFORE, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Revert, 1e6);
        assertEq(venue.hookLiquidity(pairId, address(usd)), 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Short, 1e6);
        assertEq(venue.hookLiquidity(pairId, address(usd)), 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Burn, 1e6);
        uint256 cap = venue.HOOK_VIEW_GAS();
        uint256 start = gasleft();
        uint256 liquidity = venue.hookLiquidity{ gas: 5_000_000 }(pairId, address(usd));
        uint256 used = start - gasleft();
        assertEq(liquidity, 0);
        // The view burns its whole cap and no more, even with millions of gas available.
        assertGt(used, cap);
        assertLt(used, cap + 50_000);
    }

    /// @dev A view that needs more than `HOOK_VIEW_GAS` (for example a MetaMorpho `maxWithdraw` over many markets) reads
    /// as 0, so `quote` counts nothing from the hook, while `fill`, whose callbacks have no cap, still pulls from it.
    function test_hookLiquidity_expensiveViewHidesLiquidityFromQuoteNotFill() public {
        _install(ALL, MockVenueHook.Action.TopUp, MockVenueHook.Action.None, 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Burn, 0);
        _drain(usd);
        (uint256 expectedIn, uint256 expectedOut,) = _expect(pairId, true, true, AMOUNT);
        usd.mint(address(hook), expectedOut);
        assertEq(venue.hookLiquidity(pairId, address(usd)), 0);
        vm.expectRevert(abi.encodeWithSelector(IVenue.InsufficientInventory.selector, address(usd), 0, expectedOut));
        venue.quote(pairId, address(eur), address(usd), AMOUNT, true);

        eur.mint(address(venue), expectedIn);
        vm.prank(settler);
        (, uint128 amountOut) = venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker, HOME, REF);
        assertEq(amountOut, expectedOut);
        assertEq(usd.balanceOf(taker), expectedOut);
    }

    function test_hookLiquidity_removedPairReadsZero() public {
        _install(BEFORE, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        usd.mint(address(hook), 1e6);
        vm.prank(owner);
        venue.removePair(pairId);
        assertEq(venue.hookLiquidity(pairId, address(usd)), 0);
    }

    function test_quote_skipsTheHookWhenBalanceCovers() public {
        _install(ALL, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        vm.expectCall(address(hook), abi.encodeCall(IVenueHook.availableLiquidity, (address(usd))), 0);
        venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
    }

    function test_quote_countsHookLiquidityWhenShort() public {
        _install(ALL, MockVenueHook.Action.TopUp, MockVenueHook.Action.None, 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Revert, 0);
        _drain(usd);
        (, uint256 expectedOut,) = _expect(pairId, true, true, AMOUNT);
        // A broken view hides the hook's liquidity; it never makes quote revert for another reason.
        vm.expectRevert(abi.encodeWithSelector(IVenue.InsufficientInventory.selector, address(usd), 0, expectedOut));
        venue.quote(pairId, address(eur), address(usd), AMOUNT, true);

        hook.setLiquidity(MockVenueHook.Liquidity.Fixed, expectedOut);
        venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
        hook.setLiquidity(MockVenueHook.Liquidity.Fixed, expectedOut - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.InsufficientInventory.selector, address(usd), expectedOut - 1, expectedOut)
        );
        venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
    }

    function test_quote_saturatesHugeHookLiquidity() public {
        _install(BEFORE, MockVenueHook.Action.None, MockVenueHook.Action.None, 0);
        hook.setLiquidity(MockVenueHook.Liquidity.Fixed, type(uint256).max);
        vm.prank(owner);
        venue.withdraw(address(usd), owner, INVENTORY - 1, bytes32(0));
        (, uint128 amountOut) = venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
        assertGt(amountOut, 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _install(uint8 flags, MockVenueHook.Action beforeAction, MockVenueHook.Action afterAction, uint256 amt)
        internal
    {
        vm.prank(owner);
        venue.setPairHook(pairId, address(hook), flags);
        hook.setActions(beforeAction, afterAction, amt);
    }

    function _installAsHookOwner(uint8 flags, MockVenueHook.Action beforeAction, MockVenueHook.Action afterAction)
        internal
    {
        hook.execute(address(venue), abi.encodeCall(IVenue.setPairHook, (pairId, address(hook), flags)));
        hook.setActions(beforeAction, afterAction, 0);
    }

    function _makeHookOwner() internal {
        vm.prank(owner);
        venue.transferOwnership(address(hook));
        hook.execute(address(venue), abi.encodeCall(IVenue.acceptOwnership, ()));
        assertEq(venue.owner(), address(hook));
    }

    /// @dev Installs `flags` with a reentering callback (before or after) and expects the lock to reject `data`.
    function _expectReentryBlocked(uint8 flags, bool inBefore, bytes memory data) internal {
        _expectReentryRejected(flags, inBefore, data, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    /// @dev The hook re-enters the venue with `data` from `beforeFill` (`inBefore`) or `afterFill`, and the fill
    /// reverts with `err`, the hook bubbling the venue's revert.
    function _expectReentryRejected(uint8 flags, bool inBefore, bytes memory data, bytes4 err) internal {
        _installAsHookOwner(
            flags,
            inBefore ? MockVenueHook.Action.Reenter : MockVenueHook.Action.None,
            inBefore ? MockVenueHook.Action.None : MockVenueHook.Action.Reenter
        );
        hook.setReentry(address(venue), data);
        eur.mint(address(venue), AMOUNT);
        _expectFillRevert(abi.encodeWithSelector(err));
    }

    function _expectFillRevert(bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker, HOME, REF);
    }

    /// @dev A new `base`/USD pair with the default shape, posted, and `hook` installed with ALL and told to take the
    /// whole input after each fill.
    function _hookedPair(address base) internal returns (uint16 index) {
        vm.startPrank(owner);
        index = venue.addPair(base, address(usd), UNIT);
        venue.setShape(index, 0, _defaultShape());
        venue.setPairHook(index, address(hook), ALL);
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        _post(index, _hot(2));
        hook.setActions(MockVenueHook.Action.None, MockVenueHook.Action.Take, 0);
    }

    function _drain(MockTIP20V2 token) internal {
        uint256 held = token.balanceOf(address(venue));
        vm.prank(venue.owner());
        venue.withdraw(address(token), makeAddr("sink"), held, bytes32(0));
    }

    function _assertFill(
        IVenueHook.FillContext memory fill,
        uint128 amountIn,
        uint128 amountOut,
        bool baseIn,
        bool exactIn,
        uint64 sponsorId,
        bytes32 hot
    ) internal view {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        assertEq(fill.pairIndex, pairId);
        assertEq(fill.taker, taker);
        assertEq(fill.sponsorId, sponsorId);
        assertEq(fill.ref, REF);
        assertEq(fill.tokenIn, tokenIn);
        assertEq(fill.tokenOut, tokenOut);
        assertEq(fill.amountIn, amountIn);
        assertEq(fill.amountOut, amountOut);
        assertEq(fill.exactIn, exactIn);
        assertEq(fill.makerMid, HotWord.mid(hot));
        assertEq(fill.seq, HotWord.seq(hot));
    }
}
