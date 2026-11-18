// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "./utils/TestFeeHook.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
using TestFeeHookLib for ManagedDirectPropAMM;

import { Vm } from "forge-std/Vm.sol";

import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { ManagedPoolFixture } from "./utils/ManagedPoolFixture.sol";
import { IManagedPoolHook, ManagedPoolHookFlags } from "../../src/managed/interfaces/IManagedPoolHook.sol";

/// @notice Test-only hook-provided, per-pair per-taker directional fees: permissions, gross settlement, independent bounded arithmetic, credits,
/// quote parity and event accounting. The existing v1 differential separately pins zero-fee compatibility.
contract ManagedHookFeeEconomicsTest is ManagedPoolFixture {
    bytes32 private constant FEE_EVENT = keccak256("HookFeeCharged(uint16,address,address,uint256)");

    struct Fill {
        uint256 gross;
        uint256 output;
        uint256 fee;
        uint256 credit;
    }

    struct Balances {
        uint256 poolIn;
        uint256 poolOut;
        uint256 takerIn;
        uint256 takerOut;
    }

    function setUp() public override {
        super.setUp();
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
    }

    function test_feesDefaultToZeroAndEmitNoFeeEvent() external {
        assertEq(pool.MAX_HOOK_FEE_BPS(), 1_000);
        _assertFees(PRIME_PAIR, 0, 0);
        _assertFees(EUR_PAIR, 0, 0);
        this.checkTrade(PRIME_PAIR, true, true, 10 * UNIT, CUSTOMER);
        this.checkTrade(PRIME_PAIR, false, false, UNIT, CUSTOMER);
    }

    function test_onlyCurrentOwnerRegistersHookNotOtherAccountsOrPendingOwner() external {
        _addAlpha();
        pool.closePair(PRIME_PAIR);
        TestFeeHook hook = new TestFeeHook(pool);
        address[4] memory others = [unauthorized, alpha, taker, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            vm.prank(others[i]);
            pool.setPairHook(PRIME_PAIR, address(hook), ManagedPoolHookFlags.QUOTE);
        }
        pool.transferOwnership(stranger);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(stranger);
        pool.setPairHook(PRIME_PAIR, address(hook), ManagedPoolHookFlags.QUOTE);
        pool.setPairHook(PRIME_PAIR, address(hook), ManagedPoolHookFlags.QUOTE);
        vm.prank(stranger);
        pool.acceptOwnership();
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setPairHook(PRIME_PAIR, address(0), 0);
        vm.prank(stranger);
        pool.setPairHook(PRIME_PAIR, address(0), 0);
        (address installed, uint8 flags) = pool.pairHook(PRIME_PAIR);
        assertEq(installed, address(0));
        assertEq(flags, 0);
        vm.expectRevert(TestFeeHook.NotOwner.selector);
        hook.setFees(PRIME_PAIR, taker, 1, 2);
        vm.prank(stranger);
        hook.setFees(PRIME_PAIR, taker, 3, 4);
        (uint16 sell, uint16 buy) = hook.fees(PRIME_PAIR, taker);
        assertEq(sell, 3);
        assertEq(buy, 4);
    }

    function test_registrationNeedsClosedPairEvenWhenPoolPausedOrPairOpen() external {
        TestFeeHook hook = new TestFeeHook(pool);
        bytes memory err = abi.encodeWithSelector(IManagedDirectPropAMM.PairNotClosed.selector, PRIME_PAIR);
        vm.expectRevert(err);
        pool.setPairHook(PRIME_PAIR, address(hook), ManagedPoolHookFlags.QUOTE);
        pool.pause();
        vm.expectRevert(err);
        pool.setPairHook(PRIME_PAIR, address(hook), ManagedPoolHookFlags.QUOTE);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        vm.expectRevert(err);
        pool.setPairHook(PRIME_PAIR, address(hook), ManagedPoolHookFlags.QUOTE);
        pool.closePair(PRIME_PAIR);
        pool.setPairHook(PRIME_PAIR, address(hook), ManagedPoolHookFlags.QUOTE);
        pool.unpause();
        pool.setPairHook(PRIME_PAIR, address(0), 0);
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Closed));
    }

    function test_hookFeeCapCheckedIndependentlyForBothDirectionsAtQuoteTime() external {
        _fees(PRIME_PAIR, 1_000, 1_000);
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
        pool.quoteExactOutput(PRIME_PAIR, taker, false, UNIT);
        (address installed,) = pool.pairHook(PRIME_PAIR);
        TestFeeHook hook = TestFeeHook(installed);
        hook.setFees(PRIME_PAIR, taker, 1_001, 0);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.HookFeeTooHigh.selector, 1_001, 1_000));
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.HookFeeTooHigh.selector, 1_001, 1_000));
        pool.quoteExactOutput(PRIME_PAIR, taker, true, UNIT);
        pool.quoteExactInput(PRIME_PAIR, taker, false, UNIT);
        hook.setFees(PRIME_PAIR, taker, 0, type(uint16).max);
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.HookFeeTooHigh.selector, type(uint16).max, 1_000));
        pool.quoteExactInput(PRIME_PAIR, taker, false, UNIT);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.HookFeeTooHigh.selector, type(uint16).max, 1_000));
        pool.quoteExactOutput(PRIME_PAIR, taker, false, UNIT);
        hook.setFees(PRIME_PAIR, taker, 0, 0);
        _assertFees(PRIME_PAIR, 0, 0);
    }

    function test_hookRegistrationAndPairIsolationLeavePricingAndAccessUnchanged() external {
        _fees(PRIME_PAIR, 17, 901);
        _assertFees(PRIME_PAIR, 17, 901);
        _assertFees(EUR_PAIR, 0, 0);
        (address first, uint8 flags) = pool.pairHook(PRIME_PAIR);
        (address second,) = pool.pairHook(EUR_PAIR);
        assertTrue(first != address(0));
        assertEq(flags, ManagedPoolHookFlags.QUOTE);
        assertEq(second, address(0));
        assertEq(pool.priceAnchor(PRIME_PAIR, true), PRIME_PRICE);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), PRIME_PRICE);
        assertTrue(pool.isMember(PRIME_PAIR, HOME, taker));
        assertEq(pool.pair(PRIME_PAIR).maxPriceDeviationBps, MAX_DEVIATION_BPS);
    }

    function test_unknownAndRemovedPairsRefuseHooksAndNewPairStartsWithoutHook() external {
        TestFeeHook hook = new TestFeeHook(pool);
        bytes memory unknown = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, uint16(99));
        vm.expectRevert(unknown);
        pool.pairHook(99);
        vm.expectRevert(unknown);
        pool.setPairHook(99, address(hook), ManagedPoolHookFlags.QUOTE);
        _fees(PRIME_PAIR, 40, 90);
        pool.removePair(PRIME_PAIR);
        unknown = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, PRIME_PAIR);
        vm.expectRevert(unknown);
        pool.pairHook(PRIME_PAIR);
        vm.expectRevert(unknown);
        pool.setPairHook(PRIME_PAIR, address(0), 0);
        uint16 next = pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        assertGt(next, PRIME_PAIR);
        (address installed, uint8 flags) = pool.pairHook(next);
        assertEq(installed, address(0));
        assertEq(flags, 0);
    }

    function test_testFeeHookCallbacksAuthenticatePool() external {
        TestFeeHook hook = new TestFeeHook(pool);
        IManagedPoolHook.QuoteContext memory context =
            IManagedPoolHook.QuoteContext(PRIME_PAIR, taker, true, true, UNIT);
        vm.expectRevert(TestFeeHook.NotPool.selector);
        hook.quote(context);
        IManagedPoolHook.SwapContext memory swapContext;
        swapContext.quote = context;
        vm.expectRevert(TestFeeHook.NotPool.selector);
        hook.beforeSwap(swapContext);
        vm.expectRevert(TestFeeHook.NotPool.selector);
        hook.afterSwap(swapContext);
    }

    function test_unsetAndClearedTakersHaveNoFallbackAndOtherRatesStayIndependent() external {
        _listHome(PRIME_PAIR, member);
        _fees(PRIME_PAIR, 1_000, 500);
        (uint16 sell, uint16 buy) = pool.testFees(PRIME_PAIR, member);
        assertEq(sell, 0);
        assertEq(buy, 0);
        assertEq(_sell(PRIME_PAIR, member, HOME), PRIME_OUT, "unset taker is free");
        assertEq(_sell(EUR_PAIR, taker, HOME), 10 * EUR_OUT, "another pair is free");
        pool.closePair(PRIME_PAIR);
        pool.configureFees(PRIME_PAIR, member, 250, 750);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        assertEq(_sell(PRIME_PAIR, member, HOME), PRIME_OUT * 9_750 / 10_000);
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT * 9 / 10);
        _fees(PRIME_PAIR, 0, 0);
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT, "cleared taker is free");
        (sell, buy) = pool.testFees(PRIME_PAIR, member);
        assertEq(sell, 250);
        assertEq(buy, 750);
        address original = taker;
        taker = member;
        this.checkTrade(PRIME_PAIR, false, true, 10 * UNIT, TRADE);
        this.checkTrade(PRIME_PAIR, false, false, UNIT, TRADE);
        taker = original;
        this.checkTrade(PRIME_PAIR, false, true, 10 * UNIT, TRADE);
        this.checkTrade(PRIME_PAIR, false, false, UNIT, TRADE);
    }

    function test_quoteUsesNamedTakerAndWrongAddressCannotBypassSwapFee() external {
        _fees(PRIME_PAIR, 1_000, 500);
        for (uint256 d; d < 2; ++d) {
            bool direction = d == 0;
            (uint256 freeOut,,) = pool.quoteExactInput(PRIME_PAIR, member, direction, UNIT);
            vm.prank(member);
            (uint256 paidOut,,) = pool.quoteExactInput(PRIME_PAIR, taker, direction, UNIT);
            assertLt(paidOut, freeOut, "quote caller must not choose the rate");
            (uint256 routeOut,,,) = pool.quoteExactInputFor(PRIME_PAIR, taker, CUSTOMER, direction, UNIT);
            assertEq(routeOut, paidOut);
            vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.SlippageExceeded.selector, freeOut, paidOut));
            vm.prank(taker);
            pool.swapExactInput(
                PRIME_PAIR, direction, UNIT, freeOut, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
            );
            (uint256 freeIn,,) = pool.quoteExactOutput(PRIME_PAIR, member, direction, UNIT);
            vm.prank(member);
            (uint256 paidIn,,) = pool.quoteExactOutput(PRIME_PAIR, taker, direction, UNIT);
            assertGt(paidIn, freeIn);
            (uint256 routeIn,,,) = pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, direction, UNIT);
            assertEq(routeIn, paidIn);
            vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.SlippageExceeded.selector, freeIn, paidIn));
            vm.prank(taker);
            pool.swapExactOutput(
                PRIME_PAIR, direction, UNIT, freeIn, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
            );
        }
    }

    function test_sponsorAndCustomerIdCannotSelectAnotherFeeSchedule() external {
        _fees(PRIME_PAIR, 1_000, 500);
        _addAlpha();
        _listAlpha(PRIME_PAIR, taker);
        uint64[2] memory sponsors = [HOME, ALPHA];
        bytes32[2] memory customers = [CUSTOMER, TRADE];
        for (uint256 i; i < sponsors.length; ++i) {
            for (uint256 j; j < customers.length; ++j) {
                assertEq(_sellFor(PRIME_PAIR, taker, sponsors[i], customers[j], 10 * UNIT), PRIME_OUT * 9 / 10);
                (uint256 gross,,,) = pool.quoteExactOutputFor(PRIME_PAIR, taker, customers[j], false, UNIT);
                assertEq(gross, _ceil(PRIME_PRICE * UNIT / 1e8 * 10_000, 9_500));
                vm.prank(taker);
                assertEq(
                    pool.swapExactOutput(
                        PRIME_PAIR,
                        false,
                        UNIT,
                        gross,
                        sponsors[i],
                        customers[j],
                        TRADE,
                        block.timestamp,
                        PRIME_PRICE,
                        0,
                        0
                    ),
                    gross
                );
            }
        }
    }

    function test_legacyPairFeeAndAnonymousQuoteSelectorsAreAbsent() external {
        pool.closePair(PRIME_PAIR);
        (bool ok,) = address(pool)
            .call(abi.encodeWithSignature("setTakerFees(uint16,address,uint16,uint16)", PRIME_PAIR, taker, 1, 2));
        assertFalse(ok);
        (ok,) = address(pool).staticcall(abi.encodeWithSignature("takerFees(uint16,address)", PRIME_PAIR, taker));
        assertFalse(ok);
        (ok,) = address(pool).staticcall(abi.encodeWithSignature("MAX_SWAP_FEE_BPS()"));
        assertFalse(ok);
        (ok,) = address(pool).call(abi.encodeWithSignature("setPairFees(uint16,uint16,uint16)", PRIME_PAIR, 1, 2));
        assertFalse(ok);
        (ok,) = address(pool).staticcall(abi.encodeWithSignature("pairFees(uint16)", PRIME_PAIR));
        assertFalse(ok);
        (ok,) = address(pool)
            .staticcall(abi.encodeWithSignature("quoteExactInput(uint16,bool,uint256)", PRIME_PAIR, true, UNIT));
        assertFalse(ok);
        (ok,) = address(pool)
            .staticcall(abi.encodeWithSignature("quoteExactOutput(uint16,bool,uint256)", PRIME_PAIR, true, UNIT));
        assertFalse(ok);
    }

    function test_directionalFeesAndAllQuoteFormsMatchSettlement() external {
        _fees(PRIME_PAIR, 100, 750);
        _fees(EUR_PAIR, 900, 25);
        for (uint16 pairIndex; pairIndex < 2; ++pairIndex) {
            this.checkTrade(pairIndex, true, true, 7 * _baseUnit(pairIndex) + 123, CUSTOMER);
            this.checkTrade(pairIndex, false, true, 9 * UNIT + 321, CUSTOMER);
            this.checkTrade(pairIndex, true, false, 3 * UNIT + 7, CUSTOMER);
            this.checkTrade(pairIndex, false, false, _baseUnit(pairIndex) + 11, CUSTOMER);
        }
    }

    function test_directionWithZeroFeeStaysFree() external {
        _fees(PRIME_PAIR, 1_000, 0);
        assertGt(this.checkTrade(PRIME_PAIR, true, true, UNIT, CUSTOMER).fee, 0);
        assertEq(this.checkTrade(PRIME_PAIR, false, true, UNIT, CUSTOMER).fee, 0);
        assertEq(this.checkTrade(PRIME_PAIR, false, false, UNIT, CUSTOMER).fee, 0);
    }

    function test_roundingCreditsNeverRefundFeesAndCanFundAZeroInputFill() external {
        _fees(PRIME_PAIR, 1, 1);
        uint256 totalGross;
        uint256 totalFees;
        // 20 net base units buy 21 quote units at 1.05. Splitting into one-unit exact outputs charges
        // a one-unit input fee on each of the 20 nonzero inputs. Only price rounding earns credit.
        for (uint256 i; i < 21; ++i) {
            Fill memory fill = this.checkTrade(PRIME_PAIR, true, false, 1, CUSTOMER);
            totalGross += fill.gross;
            totalFees += fill.fee;
            if (i == 20) {
                assertEq(fill.gross, 0, "last output is funded by real rounding credit");
                assertEq(fill.fee, 0, "no fee event for a zero-input fill");
            }
        }
        assertEq(totalGross, 40);
        assertEq(totalFees, 20);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER)), 0);
    }

    function test_feeChangesPreserveCreditAndUseNewRateOnNextFill() external {
        _fees(PRIME_PAIR, 1, 2);
        this.checkTrade(PRIME_PAIR, true, false, 1, CUSTOMER);
        bytes32 key = pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER);
        uint256 credit = pool.roundingCredit(key);
        assertEq(credit, 5_000_000);
        _fees(PRIME_PAIR, 1_000, 500);
        assertEq(pool.roundingCredit(key), credit);
        this.checkTrade(PRIME_PAIR, true, true, 23, CUSTOMER);
        this.checkTrade(PRIME_PAIR, false, false, 17, CUSTOMER);
        _fees(PRIME_PAIR, 0, 0);
        this.checkTrade(PRIME_PAIR, true, false, 13, CUSTOMER);
    }

    function test_feesDoNotLeakCreditsAcrossCustomersTakersOrPairs() external {
        _fees(PRIME_PAIR, 1, 1);
        _fees(EUR_PAIR, 1, 1);
        this.checkTrade(PRIME_PAIR, true, false, 1, CUSTOMER);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER)), 5_000_000);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, member, CUSTOMER)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, taker, TRADE)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(EUR_PAIR, taker, CUSTOMER)), 0);
        this.checkTrade(PRIME_PAIR, true, false, 1, TRADE);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER)), 5_000_000);
    }

    function test_exactInputConsumedEntirelyByRoundedFeeRevertsWithoutSettlement() external {
        _fees(PRIME_PAIR, 1, 1);
        uint256 beforeBalance = prime.balanceOf(taker);
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, true, 1, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        assertEq(prime.balanceOf(taker), beforeBalance);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER)), 0);
    }

    function test_slippageLimitsUseNetOutputAndGrossInputAndRevertAtomically() external {
        _fees(PRIME_PAIR, 1_000, 500);
        uint256 baseBefore = prime.balanceOf(taker);
        uint256 quoteBefore = pathUsd.balanceOf(taker);
        (uint256 output,,,) = pool.quoteExactInputFor(PRIME_PAIR, taker, CUSTOMER, true, UNIT);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.SlippageExceeded.selector, output + 1, output));
        vm.prank(taker);
        pool.swapExactInput(
            PRIME_PAIR, true, UNIT, output + 1, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
        );
        (uint256 gross,,,) = pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, false, UNIT);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.SlippageExceeded.selector, gross - 1, gross));
        vm.prank(taker);
        pool.swapExactOutput(
            PRIME_PAIR, false, UNIT, gross - 1, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
        );
        assertEq(prime.balanceOf(taker), baseBefore);
        assertEq(pathUsd.balanceOf(taker), quoteBefore);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER)), 0);
        this.checkTrade(PRIME_PAIR, true, true, UNIT, CUSTOMER);
        this.checkTrade(PRIME_PAIR, false, false, UNIT, CUSTOMER);
    }

    function test_feeSpreadDoesNotChangeRawOracleBindingOrDirectionalAnchors() external {
        _fees(PRIME_PAIR, 1_000, 800);
        // Fees exceed the 50 bps oracle-deviation limit, but they are not oracle movements.
        this.checkTrade(PRIME_PAIR, true, true, UNIT, CUSTOMER);
        this.checkTrade(PRIME_PAIR, false, false, UNIT, CUSTOMER);
        assertEq(pool.priceAnchor(PRIME_PAIR, true), PRIME_PRICE);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), PRIME_PRICE);
        uint256 moved = PRIME_PRICE + PRIME_PRICE * 40 / 10_000;
        primeOracle.setPrice(moved, block.timestamp);
        this.checkTrade(PRIME_PAIR, true, true, UNIT, CUSTOMER);
        assertEq(pool.priceAnchor(PRIME_PAIR, true), moved);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), PRIME_PRICE, "other direction unchanged");
        this.checkTrade(PRIME_PAIR, false, false, UNIT, CUSTOMER);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), moved);
        uint256 outside = moved + moved / 100;
        primeOracle.setPrice(outside, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector, true, outside, moved, MAX_DEVIATION_BPS
            )
        );
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
    }

    function test_feeAdjustedPriceCannotSatisfyRawOracleObservationBinding() external {
        _fees(PRIME_PAIR, 1_000, 0);
        uint256 adjusted = PRIME_PRICE * 9 / 10;
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.OraclePriceToleranceExceeded.selector, adjusted, PRIME_PRICE, 0
            )
        );
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, true, UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, adjusted, 0, 0);
    }

    function test_feeRatesDoNotGrantAccessAndSponsorsPaySameFees() external {
        _fees(PRIME_PAIR, 1_000, 400);
        pool.closePair(PRIME_PAIR);
        pool.configureFees(PRIME_PAIR, stranger, 750, 250);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        assertEq(
            uint8(pool.takerAccess(PRIME_PAIR, stranger, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.NotListed)
        );
        _expectSellRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.TakerNotAllowed.selector, stranger), PRIME_PAIR, stranger, HOME
        );
        _addAlpha();
        _listAlpha(PRIME_PAIR, taker);
        assertEq(_sell(PRIME_PAIR, taker, ALPHA), PRIME_OUT * 9 / 10);
        pool.setSponsorEnabled(ALPHA, false);
        _expectSellRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, ALPHA), PRIME_PAIR, taker, ALPHA
        );
        pool.setDenied(_one(taker), true);
        _expectSellRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.TakerDenied.selector, taker), PRIME_PAIR, taker, HOME
        );
        pool.setDenied(_one(taker), false);
    }

    function test_retainedFeesAreInventoryWithdrawableOnlyByOwner() external {
        _fees(PRIME_PAIR, 1_000, 0);
        uint256 inventory = prime.balanceOf(address(pool));
        Fill memory fill = this.checkTrade(PRIME_PAIR, true, true, UNIT, CUSTOMER);
        assertEq(prime.balanceOf(address(pool)), inventory + fill.gross);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.withdraw(address(prime), stranger, fill.fee, TRADE);
        uint256 received = prime.balanceOf(stranger);
        pool.withdraw(address(prime), stranger, fill.fee, TRADE);
        assertEq(prime.balanceOf(stranger), received + fill.fee);
        assertEq(prime.balanceOf(address(pool)), inventory + fill.gross - fill.fee);
    }

    function testFuzz_feeSettlementAndQuoteParity(
        uint16 sellSeed,
        uint16 buySeed,
        uint96 amountSeed,
        bool euro,
        bool direction,
        bool exactInput
    ) external {
        uint16 pairIndex = euro ? EUR_PAIR : PRIME_PAIR;
        _fees(pairIndex, uint16(bound(sellSeed, 0, 1_000)), uint16(bound(buySeed, 0, 1_000)));
        uint256 unit = (exactInput == direction) ? _baseUnit(pairIndex) : UNIT;
        uint256 amount = bound(amountSeed, unit, 100 * unit);
        this.checkTrade(pairIndex, direction, exactInput, amount, CUSTOMER);
        // Same route, opposite direction and the other exactness, now with any rounding credit from the first fill.
        this.checkTrade(pairIndex, !direction, !exactInput, amount, CUSTOMER);
    }

    function testFuzz_splittingExactInputCannotReduceFees(uint32 a, uint32 b, uint16 rate, bool direction) external {
        rate = uint16(bound(rate, 1, 1_000));
        _fees(PRIME_PAIR, rate, rate);
        uint256 first = bound(a, 100, 100 * UNIT);
        uint256 second = bound(b, 100, 100 * UNIT);
        Fill memory bulk = this.checkTrade(PRIME_PAIR, direction, true, first + second, TRADE);
        Fill memory partA = this.checkTrade(PRIME_PAIR, direction, true, first, CUSTOMER);
        Fill memory partB = this.checkTrade(PRIME_PAIR, direction, true, second, CUSTOMER);
        assertGe(partA.fee + partB.fee, bulk.fee);
        assertLe(partA.output + partB.output, bulk.output);
    }

    function testFuzz_splittingExactOutputCannotReduceFees(uint32 a, uint32 b, uint16 rate, bool direction) external {
        rate = uint16(bound(rate, 1, 1_000));
        _fees(PRIME_PAIR, rate, rate);
        uint256 first = bound(a, 1, 100 * UNIT);
        uint256 second = bound(b, 1, 100 * UNIT);
        Fill memory bulk = this.checkTrade(PRIME_PAIR, direction, false, first + second, TRADE);
        Fill memory partA = this.checkTrade(PRIME_PAIR, direction, false, first, CUSTOMER);
        Fill memory partB = this.checkTrade(PRIME_PAIR, direction, false, second, CUSTOMER);
        assertGe(partA.fee + partB.fee, bulk.fee);
        assertGe(partA.gross + partB.gross, bulk.gross);
        assertEq(partB.credit, bulk.credit, "price rounding is cumulative, not refunded fees");
    }

    /// @dev Decompose the reference products so they never overflow uint256, while production must use mulDiv.
    function testFuzz_fullWidthQuotesAndGrossOverflow(uint16 rate, bool direction) external {
        rate = uint16(bound(rate, 1, 1_000));
        pool.closePair(PRIME_PAIR);
        primeOracle.setPrice(1e8, block.timestamp);
        pool.resetPriceAnchor(PRIME_PAIR, true);
        pool.resetPriceAnchor(PRIME_PAIR, false);
        pool.configureFees(PRIME_PAIR, taker, rate, rate);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        uint256 maximum = type(uint256).max;
        uint256 factor = 10_000 - rate;
        uint256 net = (maximum / 10_000) * factor + (maximum % 10_000) * factor / 10_000;
        (uint256 output,,) = pool.quoteExactInput(PRIME_PAIR, taker, direction, maximum);
        assertEq(output, net);
        (output,,,) = pool.quoteExactInputFor(PRIME_PAIR, taker, CUSTOMER, direction, maximum);
        assertEq(output, net);
        uint256 expected = (net / factor) * 10_000 + _ceil((net % factor) * 10_000, factor);
        (uint256 gross,,) = pool.quoteExactOutput(PRIME_PAIR, taker, direction, net);
        assertEq(gross, expected);
        (gross,,,) = pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, direction, net);
        assertEq(gross, expected);
        vm.expectRevert();
        pool.quoteExactOutput(PRIME_PAIR, taker, direction, net + 1);
        vm.expectRevert();
        pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, direction, net + 1);
    }

    /// @dev N is the largest net input any uint256 gross can fund. N succeeds, N+1 must panic, not wrap.
    function testFuzz_fullWidthExactOutputBoundary(uint16 seed, bool direction) external {
        uint16 rate = uint16(bound(seed, 1, 1_000));
        _unitPriceWithFees(rate);
        uint256 maximumNet = _fullWidthNet(type(uint256).max, rate);
        (uint256 gross,,) = pool.quoteExactOutput(PRIME_PAIR, taker, direction, maximumNet);
        assertEq(_fullWidthNet(gross, rate), maximumNet, "gross funds exactly N");
        assertLt(_fullWidthNet(gross - 1, rate), maximumNet, "one less gross cannot fund N");
        (uint256 routeGross,,, uint256 credit) =
            pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, direction, maximumNet);
        assertEq(routeGross, gross);
        assertEq(credit, 0);
        bytes memory overflow = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
        vm.expectRevert(overflow);
        pool.quoteExactOutput(PRIME_PAIR, taker, direction, maximumNet + 1);
        vm.expectRevert(overflow);
        pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, direction, maximumNet + 1);
    }

    function _unitPriceWithFees(uint16 rate) private {
        pool.closePair(PRIME_PAIR);
        primeOracle.setPrice(1e8, block.timestamp);
        pool.resetPriceAnchor(PRIME_PAIR, true);
        pool.resetPriceAnchor(PRIME_PAIR, false);
        pool.configureFees(PRIME_PAIR, taker, rate, rate);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
    }

    /// @dev Independent full-width reference: gross - ceil(gross * rate / BPS) equals
    /// floor(gross * (BPS - rate) / BPS). Dividing first keeps each intermediate within uint256.
    function _fullWidthNet(uint256 gross, uint16 rate) private pure returns (uint256) {
        uint256 retainedBps = 10_000 - rate;
        return (gross / 10_000) * retainedBps + (gross % 10_000) * retainedBps / 10_000;
    }

    // ---------------------------------------------------------------- independent bounded reference and assertions

    function _fees(uint16 pairIndex, uint16 sell, uint16 buy) private {
        (address installed,) = pool.pairHook(pairIndex);
        if (installed == address(0)) {
            IManagedDirectPropAMM.AccessMode mode = pool.pair(pairIndex).access;
            pool.closePair(pairIndex);
            pool.configureFees(pairIndex, taker, sell, buy);
            _setAccess(pairIndex, mode);
        } else {
            TestFeeHook(installed).setFees(pairIndex, taker, sell, buy);
        }
        _assertFees(pairIndex, sell, buy);
    }

    function _assertFees(uint16 pairIndex, uint16 sell, uint16 buy) private view {
        (uint16 actualSell, uint16 actualBuy) = pool.testFees(pairIndex, taker);
        assertEq(actualSell, sell);
        assertEq(actualBuy, buy);
    }

    function _ceil(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
    }

    /// @dev Bounded test amounts make simple value multiplication safe. This does not copy production's
    /// quotient/remainder algorithm, and explicitly excludes fees from the conserved rounding-credit value.
    function _model(uint16 pairIndex, bool direction, bool exactInput, uint256 amount, uint256 credit)
        private
        view
        returns (Fill memory f)
    {
        (uint256 price,) = _oracle(pairIndex).latestPrice();
        uint256 scale = pool.pair(pairIndex).priceScale;
        (uint16 sell, uint16 buy) = pool.testFees(pairIndex, taker);
        uint256 feeBps = direction ? sell : buy;
        uint256 inputValue = direction ? price : scale;
        uint256 outputValue = direction ? scale : price;
        if (exactInput) {
            f.gross = amount;
            f.fee = _ceil(amount * feeBps, 10_000);
            uint256 value = (amount - f.fee) * inputValue + credit;
            f.output = value / outputValue;
            f.credit = value % outputValue;
        } else {
            f.output = amount;
            uint256 required = amount * outputValue;
            uint256 net = required > credit ? _ceil(required - credit, inputValue) : 0;
            f.gross = _ceil(net * 10_000, 10_000 - feeBps);
            f.fee = f.gross - net;
            assertEq(f.gross - _ceil(f.gross * feeBps, 10_000), net, "gross delivers exactly the required net");
            if (f.gross != 0) {
                uint256 less = f.gross - 1;
                assertLt(less - _ceil(less * feeBps, 10_000), net, "one less gross cannot fund the net input");
            }
            f.credit = net * inputValue + credit - required;
        }
    }

    /// @dev An external self-call keeps this assertion-heavy helper out of the via-IR inliner. Credit and
    /// balance assertions use persistent state; none relies on transient storage surviving this boundary.
    function checkTrade(uint16 pairIndex, bool direction, bool exactInput, uint256 amount, bytes32 customer)
        external
        returns (Fill memory expected)
    {
        bytes32 key = pool.roundingRouteKey(pairIndex, taker, customer);
        expected = _model(pairIndex, direction, exactInput, amount, pool.roundingCredit(key));
        _assertQuotes(pairIndex, direction, exactInput, amount, customer, expected);
        IManagedDirectPropAMM.Pair memory pairInfo = pool.pair(pairIndex);
        MockTIP20 tokenIn = MockTIP20(direction ? pairInfo.base : pairInfo.quote);
        MockTIP20 tokenOut = MockTIP20(direction ? pairInfo.quote : pairInfo.base);
        Balances memory beforeFill = Balances(
            tokenIn.balanceOf(address(pool)),
            tokenOut.balanceOf(address(pool)),
            tokenIn.balanceOf(taker),
            tokenOut.balanceOf(taker)
        );
        vm.recordLogs();
        uint256 result = _execute(pairIndex, direction, exactInput, amount, customer, expected);
        assertEq(result, exactInput ? expected.output : expected.gross);
        _assertFeeEvents(vm.getRecordedLogs(), pairIndex, address(tokenIn), expected.fee);
        assertEq(pool.roundingCredit(key), expected.credit, "fees never enter rounding credit");
        assertEq(tokenIn.balanceOf(address(pool)), beforeFill.poolIn + expected.gross, "pool keeps gross input");
        assertEq(tokenOut.balanceOf(address(pool)), beforeFill.poolOut - expected.output);
        assertEq(tokenIn.balanceOf(taker), beforeFill.takerIn - expected.gross, "taker pays gross input");
        assertEq(tokenOut.balanceOf(taker), beforeFill.takerOut + expected.output);
    }

    function _assertQuotes(
        uint16 pairIndex,
        bool direction,
        bool exactInput,
        uint256 amount,
        bytes32 customer,
        Fill memory expected
    ) private view {
        Fill memory noCredit = _model(pairIndex, direction, exactInput, amount, 0);
        (uint256 price, uint256 updatedAt) = _oracle(pairIndex).latestPrice();
        uint256 quoted;
        uint256 quotedPrice;
        uint256 quotedAt;
        uint256 quotedCredit;
        if (exactInput) {
            (quoted, quotedPrice, quotedAt) = pool.quoteExactInput(pairIndex, taker, direction, amount);
            assertEq(quoted, noCredit.output, "creditless exact-input quote");
            (quoted, quotedPrice, quotedAt, quotedCredit) =
                pool.quoteExactInputFor(pairIndex, taker, customer, direction, amount);
        } else {
            (quoted, quotedPrice, quotedAt) = pool.quoteExactOutput(pairIndex, taker, direction, amount);
            assertEq(quoted, noCredit.gross, "creditless exact-output quote");
            (quoted, quotedPrice, quotedAt, quotedCredit) =
                pool.quoteExactOutputFor(pairIndex, taker, customer, direction, amount);
        }
        assertEq(quoted, exactInput ? expected.output : expected.gross, "route-aware quote");
        assertEq(quotedPrice, price, "quoted oracle is raw");
        assertEq(quotedAt, updatedAt);
        assertEq(quotedCredit, expected.credit);
    }

    function _execute(
        uint16 pairIndex,
        bool direction,
        bool exactInput,
        uint256 amount,
        bytes32 customer,
        Fill memory expected
    ) private returns (uint256) {
        (uint256 price, uint256 updatedAt) = _oracle(pairIndex).latestPrice();
        vm.prank(taker);
        if (exactInput) {
            return pool.swapExactInput(
                pairIndex,
                direction,
                amount,
                expected.output,
                HOME,
                customer,
                TRADE,
                block.timestamp,
                price,
                0,
                updatedAt
            );
        }
        return pool.swapExactOutput(
            pairIndex, direction, amount, expected.gross, HOME, customer, TRADE, block.timestamp, price, 0, updatedAt
        );
    }

    function _assertFeeEvents(Vm.Log[] memory logs, uint16 pairIndex, address tokenIn, uint256 expectedFee)
        private
        view
    {
        uint256 fees;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool) || logs[i].topics[0] != FEE_EVENT) continue;
            ++fees;
            assertEq(logs[i].topics.length, 4);
            assertEq(logs[i].topics[1], bytes32(uint256(pairIndex)));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(taker))));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(tokenIn))));
            assertEq(abi.decode(logs[i].data, (uint256)), expectedFee);
        }
        assertEq(fees, expectedFee == 0 ? 0 : 1, "one event iff a nonzero fee was charged");
    }
}
