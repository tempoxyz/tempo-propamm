// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapParams } from "./utils/SwapParams.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Test, stdError } from "forge-std/Test.sol";

import { ISettler } from "../../src/v2/interfaces/ISettler.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { Settler } from "../../src/v2/Settler.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { SettlerMockFactory } from "./mocks/SettlerMockFactory.sol";
import { SettlerMockVenue } from "./mocks/SettlerMockVenue.sol";
import { Forgery } from "./utils/ForgedCode.sol";
import { SettlerBatcher } from "./utils/SettlerBatcher.sol";

contract SettlerTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SUPPLY = 1e18;
    uint40 internal constant NOW = 1_000_000;
    bytes32 internal constant REF = bytes32("quote-1");
    /// @dev A taker's `tokenOut` balance from before the swap, far above anything a test swap pays.
    uint256 internal constant PRIOR = 1000 * UNIT;
    /// @dev How much better than pair 0 a venue's pair 1 prices, where a test sets it.
    uint256 internal constant PAIR_BONUS_BPS = 40;

    /// @dev Pays USD and receives every output in EUR, which it starts without, so its EUR balance is what it was paid.
    address internal taker = makeAddr("taker");
    /// @dev The sponsor a swap names unless a test says otherwise. The mock venues record it and check nothing.
    uint64 internal constant SPONSOR_ID = 7;

    MockTIP20V2 internal usd;
    MockTIP20V2 internal eur;
    SettlerMockFactory internal factory;
    Settler internal settler;
    SettlerMockVenue internal venueA;
    SettlerMockVenue internal venueB;
    SettlerMockVenue internal venueC;

    function setUp() external {
        vm.warp(NOW);
        usd = new MockTIP20V2("USD", 6);
        eur = new MockTIP20V2("EUR", 6);

        factory = new SettlerMockFactory();
        settler = new Settler(IVenue(address(factory.implementation())));

        venueA = _deployVenue(10_000);
        venueB = _deployVenue(9990);
        venueC = _deployVenue(10_050);

        usd.mint(taker, SUPPLY);
        vm.startPrank(taker);
        usd.approve(address(settler), type(uint256).max);
        eur.approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------------------------------------------------

    function test_constructorStoresDependencies() external view {
        assertEq(settler.factory(), address(factory), "the implementation's factory");
        assertEq(settler.implementation(), address(factory.implementation()));
        bytes memory args = Clones.fetchCloneArgs(address(venueA));
        assertEq(
            address(venueA),
            Clones.predictDeterministicAddressWithImmutableArgs(
                address(factory.implementation()), args, bytes32(args), address(factory)
            ),
            "the factory's CREATE2 address for the venue's salt"
        );
    }

    function test_constructorRejectsZeroImplementationOrFactory() external {
        vm.expectRevert(ISettler.ZeroAddress.selector);
        new Settler(IVenue(address(0)));
        SettlerMockVenue orphan = new SettlerMockVenue(address(0));
        vm.expectRevert(ISettler.ZeroAddress.selector);
        new Settler(IVenue(address(orphan)));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Common checks
    // -----------------------------------------------------------------------------------------------------------------

    function test_deadlineIsInclusive() external {
        uint256 out = _exactIn(_params(venueA, 0, 10 * UNIT), 0);
        assertEq(out, 10 * UNIT);
        uint256 amountIn = _exactOut(_params(venueA, 0, 10 * UNIT), type(uint256).max);
        assertEq(amountIn, 10 * UNIT);
        _assertSettlerEmpty();
    }

    function test_rejectsExpiredDeadline() external {
        vm.warp(uint256(NOW) + 1);
        bytes memory err = abi.encodeWithSelector(ISettler.DeadlineExpired.selector, NOW, uint256(NOW) + 1);
        vm.expectRevert(err);
        _exactIn(_params(venueA, 0, UNIT), 0);
        vm.expectRevert(err);
        _exactOut(_params(venueA, 0, UNIT), type(uint256).max);
    }

    function test_rejectsSameToken() external {
        SwapParams memory request = _params(venueA, 0, UNIT);
        vm.expectRevert(ISettler.SameToken.selector);
        vm.prank(taker);
        settler.swapExactIn(
            request.venue, request.pairIndex, address(usd), address(usd), request.amount, 0, SPONSOR_ID, NOW, REF
        );
        vm.expectRevert(ISettler.SameToken.selector);
        vm.prank(taker);
        settler.swapExactOut(
            request.venue,
            request.pairIndex,
            address(eur),
            address(eur),
            request.amount,
            type(uint256).max,
            SPONSOR_ID,
            NOW,
            REF
        );
    }

    function test_rejectsZeroAddresses() external {
        SwapParams memory request = _params(venueA, 0, UNIT);
        address[2][2] memory cases = [[address(0), address(eur)], [address(usd), address(0)]];
        for (uint256 i; i < cases.length; ++i) {
            vm.expectRevert(ISettler.ZeroAddress.selector);
            vm.prank(taker);
            settler.swapExactIn(
                request.venue, request.pairIndex, cases[i][0], cases[i][1], request.amount, 0, SPONSOR_ID, NOW, REF
            );
            vm.expectRevert(ISettler.ZeroAddress.selector);
            vm.prank(taker);
            settler.swapExactOut(
                request.venue,
                request.pairIndex,
                cases[i][0],
                cases[i][1],
                request.amount,
                type(uint256).max,
                SPONSOR_ID,
                NOW,
                REF
            );
        }
    }

    /// @dev Only the factory's own clones are venues: not the same code deployed on its own, not the implementation
    /// itself, not another factory's clone, and not a clone of the implementation that anyone else deployed, even with
    /// a real venue's exact code, salt included, since it sits at another address than the one that salt names. Each
    /// is initialized with this Settler and priced like an honest venue.
    function test_rejectsUnknownVenue() external {
        address impl = address(factory.implementation());
        SettlerMockVenue standalone = new SettlerMockVenue(address(factory));
        SettlerMockVenue otherClone = new SettlerMockFactory().createVenue(address(settler), 10_000);
        SettlerMockVenue plainClone = SettlerMockVenue(Clones.clone(impl));
        bytes32 salt = bytes32(Clones.fetchCloneArgs(address(venueA)));
        SettlerMockVenue saltClone = SettlerMockVenue(Clones.cloneWithImmutableArgs(impl, abi.encode(salt)));
        SettlerMockVenue copy = SettlerMockVenue(Forgery.deploy(address(venueA).code));
        assertEq(address(copy).codehash, address(venueA).codehash, "a real venue's code");
        assertEq(address(saltClone).codehash, address(venueA).codehash, "a real venue's code");
        SettlerMockVenue[6] memory strangers =
            [standalone, factory.implementation(), otherClone, plainClone, saltClone, copy];
        for (uint256 i; i < strangers.length; ++i) {
            SettlerMockVenue stranger = strangers[i];
            stranger.initialize(address(settler), 10_000);
            stranger.setPair(0, address(eur), address(usd));
            eur.mint(address(stranger), SUPPLY);
            bytes memory err = abi.encodeWithSelector(ISettler.UnknownVenue.selector, address(stranger));
            vm.expectRevert(err);
            _exactIn(_params(stranger, 0, UNIT), 0);
            vm.expectRevert(err);
            _exactOut(_params(stranger, 0, UNIT), type(uint256).max);
        }

        SwapParams memory zeroVenue =
            SwapParams({ venue: address(0), pairIndex: 0, amount: uint128(UNIT), sponsorId: SPONSOR_ID });
        bytes memory zeroErr = abi.encodeWithSelector(ISettler.UnknownVenue.selector, address(0));
        vm.expectRevert(zeroErr);
        _exactIn(zeroVenue, 0);
        vm.expectRevert(zeroErr);
        _exactOut(zeroVenue, type(uint256).max);
    }

    /// @dev A swap's venue is checked from its address and the salt in its code: a swap never calls the factory.
    function test_venueCheckMakesNoFactoryCall() external {
        vm.expectCall(address(factory), bytes(""), 0);
        _exactIn(_params(venueA, 0, UNIT), 0);
        _exactOut(_params(venueC, 0, UNIT), type(uint256).max);
    }

    function test_transferFromReturningFalseReverts() external {
        usd.setReturnFalse(true);
        bytes memory err = abi.encodeWithSelector(ISettler.TransferFailed.selector, address(usd));
        vm.expectRevert(err);
        _exactIn(_params(venueA, 0, UNIT), 0);
        vm.expectRevert(err);
        _exactOut(_params(venueA, 0, UNIT), type(uint256).max);
    }

    /// @dev A pull that returns true but credits the venue less than the swap's input, or nothing, never reaches
    /// `fill`, even at a venue that doesn't check its input itself.
    function test_pullMustCreditTheVenueExactly() external {
        venueA.setCheckInput(false);
        (uint256 quotedIn,) = venueA.quote(0, address(usd), address(eur), uint128(UNIT), false);
        vm.expectCall(address(venueA), abi.encodeWithSelector(IVenue.fill.selector), 0);

        usd.setRedirectRecipient(makeAddr("elsewhere"));
        bytes memory err = abi.encodeWithSelector(ISettler.VenueDeltaMismatch.selector, UNIT, 0);
        vm.expectRevert(err);
        _exactIn(_params(venueA, 0, UNIT), 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.VenueDeltaMismatch.selector, quotedIn, 0));
        _exactOut(_params(venueA, 0, UNIT), type(uint256).max);

        usd.setRedirectRecipient(address(0));
        usd.setFeeBps(1);
        vm.expectRevert(abi.encodeWithSelector(ISettler.VenueDeltaMismatch.selector, UNIT, UNIT - UNIT / BPS));
        _exactIn(_params(venueA, 0, UNIT), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISettler.VenueDeltaMismatch.selector, quotedIn, quotedIn - quotedIn / BPS)
        );
        _exactOut(_params(venueA, 0, UNIT), type(uint256).max);
        assertEq(eur.balanceOf(taker), 0, "no output paid");
    }

    function test_pullsOnlyFromCaller() external {
        address stranger = makeAddr("stranger");
        uint256 takerBefore = usd.balanceOf(taker);
        SwapParams memory request = _params(venueA, 0, UNIT);
        // The taker's standing allowance is to the Settler, but the Settler pulls from the stranger, who has none.
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(stranger);
        settler.swapExactIn(
            request.venue, request.pairIndex, address(usd), address(eur), request.amount, 0, SPONSOR_ID, NOW, REF
        );
        assertEq(usd.balanceOf(taker), takerBefore);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Exact in
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev A venue that claims more output than it paid inflates the sum, and the taker delta catches it.
    function test_exactInOverReportedOutputFailsDeltaCheck() external {
        venueA.setMode(SettlerMockVenue.Mode.ReportOutPlusOne);
        uint256 out = _outFor(venueA, 10 * UNIT, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.TakerDeltaMismatch.selector, out + 1, out));
        _exactIn(_params(venueA, 0, 10 * UNIT), 0);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Exact out
    // -----------------------------------------------------------------------------------------------------------------

    function test_exactOutRejectsInputMismatch() external {
        venueC.setMode(SettlerMockVenue.Mode.ReportInPlusOne);
        uint128 amount = uint128(100 * UNIT);
        uint256 quoted = _inFor(venueC, amount, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.FillMismatch.selector, quoted, quoted + 1, amount, amount));
        _exactOut(_params(venueC, 0, amount), type(uint256).max);
    }

    /// @dev The venue received the quoted input but reports using less, which would undercount the taker's input.
    function test_exactOutRejectsUnderReportedInput() external {
        venueC.setMode(SettlerMockVenue.Mode.ReportInMinusOne);
        uint128 amount = uint128(100 * UNIT);
        uint256 quoted = _inFor(venueC, amount, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.FillMismatch.selector, quoted, quoted - 1, amount, amount));
        _exactOut(_params(venueC, 0, amount), type(uint256).max);
    }

    function test_exactOutRejectsOutputMismatch() external {
        venueA.setMode(SettlerMockVenue.Mode.ReportOutPlusOne);
        uint128 amount = uint128(100 * UNIT);
        uint256 quoted = _inFor(venueA, amount, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.FillMismatch.selector, quoted, quoted, amount, amount + 1));
        _exactOut(_params(venueA, 0, amount), type(uint256).max);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Self-only swaps: the caller is the taker, and its delta is checked
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The Settler hands the venue the swap's sponsor id with its caller as taker, in both directions.
    function test_swapCarriesItsSponsorAndTheCallerAsTaker() external {
        uint64[3] memory ids = [uint64(0), 42, type(uint64).max];
        SettlerMockVenue[3] memory venues = [venueA, venueB, venueC];
        uint256 out;
        for (uint256 i; i < 3; ++i) {
            SwapParams memory request = _params(venues[i], 0, 10 * UNIT);
            request.sponsorId = ids[i];
            out += _exactIn(request, 0);
            _exactOut(request, type(uint256).max);
            assertEq(venues[i].callAt(0).sponsorId, ids[i]);
            assertEq(venues[i].callAt(1).sponsorId, ids[i]);
            assertEq(venues[i].callAt(0).taker, taker);
            assertEq(venues[i].callAt(1).taker, taker);
        }
        assertEq(eur.balanceOf(taker), out + 30 * UNIT, "every output reached the caller");
    }

    /// @dev Another caller swaps for itself: it is the taker the venue sees and the account whose delta is checked.
    function test_outputGoesToWhoeverCalls() external {
        address other = makeAddr("other");
        usd.mint(other, SUPPLY);
        vm.prank(other);
        usd.approve(address(settler), type(uint256).max);
        SwapParams memory request = _params(venueA, 0, 10 * UNIT);
        vm.prank(other);
        uint256 out = settler.swapExactIn(
            request.venue, request.pairIndex, address(usd), address(eur), request.amount, 0, SPONSOR_ID, NOW, REF
        );
        assertEq(venueA.callAt(0).taker, other);
        assertEq(eur.balanceOf(other), out);
        assertEq(eur.balanceOf(taker), 0);
    }

    function test_underpaymentFailsDeltaCheck() external {
        venueB.setMode(SettlerMockVenue.Mode.Underpay);
        uint128 amount = uint128(100 * UNIT);
        uint256 out = _outFor(venueB, amount, 0);
        _expectDeltaMismatch(out, out - 1);
        _exactIn(_params(venueB, 0, amount), 0);
        _expectDeltaMismatch(amount, amount - 1);
        _exactOut(_params(venueB, 0, amount), type(uint256).max);
    }

    function test_redirectedOutputFailsDeltaCheck() external {
        eur.setRedirectRecipient(makeAddr("redirect"));
        uint256 out = _outFor(venueA, 10 * UNIT, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.TakerDeltaMismatch.selector, out, 0));
        _exactIn(_params(venueA, 0, 10 * UNIT), 0);
    }

    function test_feeOnOutputFailsDeltaCheck() external {
        eur.setFeeBps(1);
        uint256 amount = 10 * UNIT;
        uint256 received = amount - amount / BPS;
        vm.expectRevert(abi.encodeWithSelector(ISettler.TakerDeltaMismatch.selector, amount, received));
        _exactOut(_params(venueA, 0, uint128(amount)), type(uint256).max);
    }

    function test_venuePayingSettlerFailsDeltaCheck() external {
        venueA.setMode(SettlerMockVenue.Mode.PaySettler);
        uint256 out = _outFor(venueA, 10 * UNIT, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.TakerDeltaMismatch.selector, out, 0));
        _exactIn(_params(venueA, 0, 10 * UNIT), 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.TakerDeltaMismatch.selector, 10 * UNIT, 0));
        _exactOut(_params(venueA, 0, 10 * UNIT), type(uint256).max);
        _assertSettlerEmpty();
    }

    /// @dev The check is a floor: a taker that gains more than the venue reports still passes.
    function test_takerDeltaAboveReportedOutputPasses() external {
        venueA.setMode(SettlerMockVenue.Mode.Overpay);
        uint256 out = _outFor(venueA, 10 * UNIT, 0);
        assertEq(_exactIn(_params(venueA, 0, 10 * UNIT), out), out);
        assertEq(eur.balanceOf(taker), out + 1);
    }

    // The shortfall cases again, with a taker that already holds far more `tokenOut` than the swap owes it. The check
    // must be a delta taken on `tokenOut`: an absolute balance, or a snapshot of `tokenIn` (which the taker spends),
    // would pass all of them.

    function test_underpaymentFailsDeltaCheckDespitePriorBalance() external {
        eur.mint(taker, PRIOR);
        venueB.setMode(SettlerMockVenue.Mode.Underpay);
        uint128 amount = uint128(100 * UNIT);
        uint256 out = _outFor(venueB, amount, 0);
        _expectDeltaMismatch(out, out - 1);
        _exactIn(_params(venueB, 0, amount), 0);
        _expectDeltaMismatch(amount, amount - 1);
        _exactOut(_params(venueB, 0, amount), type(uint256).max);
    }

    function test_redirectedOutputFailsDeltaCheckDespitePriorBalance() external {
        eur.mint(taker, PRIOR);
        eur.setRedirectRecipient(makeAddr("redirect"));
        uint256 out = _outFor(venueA, 10 * UNIT, 0);
        _expectDeltaMismatch(out, 0);
        _exactIn(_params(venueA, 0, 10 * UNIT), 0);
        _expectDeltaMismatch(10 * UNIT, 0);
        _exactOut(_params(venueA, 0, 10 * UNIT), type(uint256).max);
    }

    function test_feeOnOutputFailsDeltaCheckDespitePriorBalance() external {
        eur.mint(taker, PRIOR);
        eur.setFeeBps(1);
        uint256 out = _outFor(venueC, 10 * UNIT, 0);
        _expectDeltaMismatch(out, out - out / BPS);
        _exactIn(_params(venueC, 0, 10 * UNIT), 0);
        uint256 amount = 10 * UNIT;
        _expectDeltaMismatch(amount, amount - amount / BPS);
        _exactOut(_params(venueC, 0, amount), type(uint256).max);
    }

    function test_venuePayingSettlerFailsDeltaCheckDespitePriorBalance() external {
        eur.mint(taker, PRIOR);
        venueA.setMode(SettlerMockVenue.Mode.PaySettler);
        uint256 out = _outFor(venueA, 10 * UNIT, 0);
        _expectDeltaMismatch(out, 0);
        _exactIn(_params(venueA, 0, 10 * UNIT), 0);
        _expectDeltaMismatch(10 * UNIT, 0);
        _exactOut(_params(venueA, 0, 10 * UNIT), type(uint256).max);
        _assertSettlerEmpty();
    }

    /// @dev If the taker's `tokenOut` balance ends below where it started (here an issuer clawback, triggered from the
    /// input token's transfer callback), the delta saturates at zero. The swap fails with `TakerDeltaMismatch`, not an
    /// arithmetic panic.
    function test_takerBalanceFallingDuringSwapReportsZeroDelta() external {
        eur.mint(taker, PRIOR);
        usd.setReentry(address(eur), abi.encodeCall(MockTIP20V2.clawback, (taker, PRIOR)));
        uint256 out = _outFor(venueA, 10 * UNIT, 0);
        _expectDeltaMismatch(out, 0);
        _exactIn(_params(venueA, 0, 10 * UNIT), 0);
        _expectDeltaMismatch(10 * UNIT, 0);
        _exactOut(_params(venueA, 0, 10 * UNIT), type(uint256).max);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Reentrancy
    // -----------------------------------------------------------------------------------------------------------------

    function test_venueCannotReenterEitherSwap() external {
        venueA.setMode(SettlerMockVenue.Mode.Reenter);
        bool[2] memory exactIn = [true, false];
        for (uint256 outer; outer < 2; ++outer) {
            for (uint256 inner; inner < 2; ++inner) {
                venueA.setReentryData(_reentryCall(exactIn[inner]));
                vm.expectRevert(ISettler.Reentrancy.selector);
                if (exactIn[outer]) _exactIn(_params(venueA, 0, UNIT), 0);
                else _exactOut(_params(venueA, 0, UNIT), type(uint256).max);
            }
        }
    }

    /// @dev A token callback during the pull reenters too; the mock token records the failure instead of bubbling it.
    function test_tokenCallbackCannotReenterEitherSwap() external {
        bool[2] memory exactIn = [true, false];
        for (uint256 outer; outer < 2; ++outer) {
            for (uint256 inner; inner < 2; ++inner) {
                usd.setReentry(address(settler), _reentryCall(exactIn[inner]));
                if (exactIn[outer]) _exactIn(_params(venueA, 0, UNIT), 0);
                else _exactOut(_params(venueA, 0, UNIT), type(uint256).max);
                assertFalse(usd.reentrySucceeded());
                assertEq(usd.reentryResult(), abi.encodeWithSelector(ISettler.Reentrancy.selector));
            }
        }
        _assertSettlerEmpty();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Several request on one venue
    // -----------------------------------------------------------------------------------------------------------------

    // -----------------------------------------------------------------------------------------------------------------
    // Fuzz: conservation and an empty Settler
    // -----------------------------------------------------------------------------------------------------------------

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    function test_singleSwapLockClearsAfterSuccessAndCaughtFailure() public {
        SettlerBatcher batcher = new SettlerBatcher(settler);
        usd.mint(address(batcher), 1_000_000 * UNIT);
        batcher.approve(usd);
        uint128 amount = 10 * uint128(UNIT);
        (uint256 first, uint256 paid, uint256 last) =
            batcher.run(address(usd), address(eur), _params(venueA, 0, amount), NOW);
        assertEq(first, _outFor(venueA, amount, 0));
        assertEq(last, first);
        assertEq(paid, _inFor(venueA, amount, 0));
        assertEq(venueA.callCount(), 3);
        _assertSettlerEmpty();
    }

    function test_zeroAmountRejectedInBothDirections() public {
        vm.expectRevert(ISettler.ZeroAmount.selector);
        _exactIn(_params(venueA, 0, 0), 0);
        vm.expectRevert(ISettler.ZeroAmount.selector);
        _exactOut(_params(venueA, 0, 0), type(uint256).max);
    }

    function test_exactInRejectsReportedInputMismatchAndRollsBack() public {
        uint128 amount = 100 * uint128(UNIT);
        uint256 out = _outFor(venueA, amount, 0);
        uint256 before = usd.balanceOf(taker);
        venueA.setMode(SettlerMockVenue.Mode.ReportInPlusOne);
        vm.expectRevert(abi.encodeWithSelector(ISettler.FillMismatch.selector, amount, amount + 1, out, out));
        _exactIn(_params(venueA, 0, amount), 0);
        venueA.setMode(SettlerMockVenue.Mode.ReportInMinusOne);
        vm.expectRevert(abi.encodeWithSelector(ISettler.FillMismatch.selector, amount, amount - 1, out, out));
        _exactIn(_params(venueA, 0, amount), 0);
        assertEq(usd.balanceOf(taker), before);
        assertEq(eur.balanceOf(taker), 0);
        assertEq(venueA.callCount(), 0);
    }

    function test_exactInMinimumAndExactAllowance() external {
        uint128 amount = 100 * uint128(UNIT);
        uint256 expected = _outFor(venueA, amount, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientOutput.selector, expected, expected + 1));
        _exactIn(_params(venueA, 0, amount), expected + 1);
        vm.prank(taker);
        usd.approve(address(settler), amount);
        assertEq(_exactIn(_params(venueA, 0, amount), expected), expected);
        assertEq(usd.allowance(taker, address(settler)), 0);
    }

    function test_exactOutMaximumIsCheckedBeforeThePull() external {
        uint128 amount = 100 * uint128(UNIT);
        uint256 expected = _inFor(venueB, amount, 0);
        uint256 before = usd.balanceOf(taker);
        vm.expectRevert(abi.encodeWithSelector(ISettler.ExcessiveInput.selector, expected, expected - 1));
        _exactOut(_params(venueB, 0, amount), expected - 1);
        assertEq(usd.balanceOf(taker), before);
        assertEq(venueB.callCount(), 0);
        assertEq(_exactOut(_params(venueB, 0, amount), expected), expected);
        assertEq(venueB.callAt(0).received, expected);
        assertEq(eur.balanceOf(taker), amount);
    }

    function testFuzz_singleSwapConservesBalances(uint128 amount, bool exactIn, uint16 rate) external {
        amount = uint128(bound(amount, 1, 1e12));
        rate = uint16(bound(rate, 5000, 15000));
        SettlerMockVenue venue = _deployVenue(rate);
        uint256 before = usd.balanceOf(taker);
        if (exactIn) {
            uint256 out = _exactIn(_params(venue, 0, amount), 0);
            assertEq(out, _outFor(venue, amount, 0));
            assertEq(before - usd.balanceOf(taker), amount);
            assertEq(eur.balanceOf(taker), out);
        } else {
            uint256 paid = _exactOut(_params(venue, 0, amount), type(uint256).max);
            assertEq(paid, _inFor(venue, amount, 0));
            assertEq(before - usd.balanceOf(taker), paid);
            assertEq(eur.balanceOf(taker), amount);
        }
        _assertSettlerEmpty();
    }

    function _deployVenue(uint256 rateBps) internal returns (SettlerMockVenue venue) {
        venue = factory.createVenue(address(settler), rateBps);
        venue.setPair(0, address(eur), address(usd));
        venue.setPair(1, address(usd), address(eur));
        usd.mint(address(venue), SUPPLY);
        eur.mint(address(venue), SUPPLY);
        venue.sync(address(usd));
        venue.sync(address(eur));
    }

    /// @dev The taker swaps for itself, so the output goes to the taker.
    function _exactIn(SwapParams memory request, uint256 minAmountOut) internal returns (uint256) {
        vm.prank(taker);
        return settler.swapExactIn(
            request.venue,
            request.pairIndex,
            address(usd),
            address(eur),
            request.amount,
            minAmountOut,
            request.sponsorId,
            NOW,
            REF
        );
    }

    function _exactOut(SwapParams memory request, uint256 maxAmountIn) internal returns (uint256) {
        vm.prank(taker);
        return settler.swapExactOut(
            request.venue,
            request.pairIndex,
            address(usd),
            address(eur),
            request.amount,
            maxAmountIn,
            request.sponsorId,
            NOW,
            REF
        );
    }

    function _reentryCall(bool exactIn) internal view returns (bytes memory) {
        SwapParams memory request = _params(venueB, 0, UNIT);
        if (exactIn) {
            return abi.encodeCall(
                ISettler.swapExactIn,
                (request.venue, request.pairIndex, address(usd), address(eur), request.amount, 0, SPONSOR_ID, NOW, REF)
            );
        }
        return abi.encodeCall(
            ISettler.swapExactOut,
            (
                request.venue,
                request.pairIndex,
                address(usd),
                address(eur),
                request.amount,
                type(uint256).max,
                SPONSOR_ID,
                NOW,
                REF
            )
        );
    }

    function _outFor(SettlerMockVenue venue, uint256 amountIn, uint256 priorFills) internal view returns (uint256) {
        return _outAtRate(amountIn, venue.rateBps() - venue.impactBps() * priorFills);
    }

    function _outAtRate(uint256 amountIn, uint256 rate) internal pure returns (uint256) {
        return amountIn * rate / BPS;
    }

    function _inFor(SettlerMockVenue venue, uint256 amountOut, uint256 priorFills) internal view returns (uint256) {
        return _inAtRate(amountOut, venue.rateBps() - venue.impactBps() * priorFills);
    }

    function _inAtRate(uint256 amountOut, uint256 rate) internal pure returns (uint256) {
        return Math.ceilDiv(amountOut * BPS, rate);
    }

    function _expectDeltaMismatch(uint256 expected, uint256 actual) internal {
        vm.expectRevert(abi.encodeWithSelector(ISettler.TakerDeltaMismatch.selector, expected, actual));
    }

    function _assertSettlerEmpty() internal view {
        assertEq(usd.balanceOf(address(settler)), 0, "settler holds tokenIn");
        assertEq(eur.balanceOf(address(settler)), 0, "settler holds tokenOut");
    }

    function _params(SettlerMockVenue venue, uint16 pairIndex, uint256 amount)
        internal
        pure
        returns (SwapParams memory)
    {
        // Test amounts fit in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return
            SwapParams({ venue: address(venue), pairIndex: pairIndex, amount: uint128(amount), sponsorId: SPONSOR_ID });
    }
}
