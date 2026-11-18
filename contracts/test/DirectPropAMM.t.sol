// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockOracle } from "./mocks/MockOracle.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

contract DirectPropAMMTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PRICE = 105_000_000; // $1.05 with 8 decimals.

    address internal guardian = makeAddr("guardian");
    address internal taker = makeAddr("taker");
    address internal recipient = makeAddr("recipient");
    address internal thief = makeAddr("thief");

    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockOracle internal oracle;
    MockAddressRegistry internal registry;
    DirectPropAMM internal pool;

    function setUp() external {
        vm.warp(1_000_000);
        registry = new MockAddressRegistry();
        prime = new MockTIP20("PRIME", 6);
        pathUsd = new MockTIP20("pathUSD", 6);
        oracle = new MockOracle(8, PRICE, block.timestamp);
        prime.setResolver(registry);
        pathUsd.setResolver(registry);

        pool = new DirectPropAMM(prime, pathUsd, oracle, registry, address(this), guardian, 90_000, 50);
        pool.setTakerAllowed(taker, true);
        pool.setRecipientAllowed(recipient, true);

        prime.mint(address(pool), 1_000_000 * UNIT);
        pathUsd.mint(address(pool), 1_000_000 * UNIT);
        prime.mint(taker, 1_000 * UNIT);
        pathUsd.mint(taker, 1_000 * UNIT);

        vm.startPrank(taker);
        prime.approve(address(pool), type(uint256).max);
        pathUsd.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        pool.unpause();
    }

    function test_exactInput_baseToQuote() external {
        vm.prank(taker);
        uint256 amountOut = _swapExactInput(true, 10 * UNIT, 10_500_000, recipient, bytes32("c1"), bytes32("t1"));

        assertEq(amountOut, 10_500_000);
        assertEq(pathUsd.balanceOf(recipient), 10_500_000);
        assertEq(prime.balanceOf(address(pool)), 1_000_010 * UNIT);
    }

    function test_exactInput_quoteToBase() external {
        vm.prank(taker);
        uint256 amountOut = _swapExactInput(false, 10_500_000, 10 * UNIT, recipient, bytes32("c1"), bytes32("t1"));

        assertEq(amountOut, 10 * UNIT);
        assertEq(prime.balanceOf(recipient), 10 * UNIT);
    }

    function test_exactInputRejectsExpiredDeadline() external {
        uint256 deadline = block.timestamp - 1;

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.DeadlineExpired.selector, deadline, block.timestamp));
        vm.prank(taker);
        pool.swapExactInput(
            true, UNIT, 0, recipient, bytes32("c1"), bytes32("expired-input"), deadline, PRICE, 0, block.timestamp
        );
    }

    function test_exactOutputRejectsExpiredDeadline() external {
        uint256 deadline = block.timestamp - 1;

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.DeadlineExpired.selector, deadline, block.timestamp));
        vm.prank(taker);
        pool.swapExactOutput(
            false,
            UNIT,
            type(uint256).max,
            recipient,
            bytes32("c1"),
            bytes32("expired-output"),
            deadline,
            PRICE,
            0,
            block.timestamp
        );
    }

    function test_exactInputAcceptsNewerOracleTimestampAtSamePrice() external {
        uint256 quotedOracleUpdatedAt = oracle.updatedAt();
        vm.warp(block.timestamp + 1);
        oracle.setPrice(PRICE, block.timestamp);

        vm.prank(taker);
        uint256 amountOut = pool.swapExactInput(
            true,
            UNIT,
            0,
            recipient,
            bytes32("c1"),
            bytes32("newer-input"),
            block.timestamp,
            PRICE,
            0,
            quotedOracleUpdatedAt
        );

        assertEq(amountOut, 1_050_000);
    }

    function test_exactOutputAcceptsNewerOracleTimestampAtSamePrice() external {
        uint256 quotedOracleUpdatedAt = oracle.updatedAt();
        vm.warp(block.timestamp + 1);
        oracle.setPrice(PRICE, block.timestamp);

        vm.prank(taker);
        uint256 amountIn = pool.swapExactOutput(
            false,
            UNIT,
            type(uint256).max,
            recipient,
            bytes32("c1"),
            bytes32("newer-output"),
            block.timestamp,
            PRICE,
            0,
            quotedOracleUpdatedAt
        );

        assertEq(amountIn, 1_050_000);
    }

    function test_exactInputRejectsUnexpectedOraclePrice() external {
        uint256 quotedOracleUpdatedAt = oracle.updatedAt();
        uint256 newPrice = PRICE - PRICE / pool.BPS();
        oracle.setPrice(newPrice, quotedOracleUpdatedAt);

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.OraclePriceToleranceExceeded.selector, PRICE, newPrice, 0));
        vm.prank(taker);
        pool.swapExactInput(
            true,
            UNIT,
            0,
            recipient,
            bytes32("c1"),
            bytes32("repriced-input"),
            block.timestamp,
            PRICE,
            0,
            quotedOracleUpdatedAt
        );
    }

    function test_exactOutputRejectsUnexpectedOraclePrice() external {
        uint256 quotedOracleUpdatedAt = oracle.updatedAt();
        uint256 newPrice = PRICE + PRICE / pool.BPS();
        oracle.setPrice(newPrice, quotedOracleUpdatedAt);

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.OraclePriceToleranceExceeded.selector, PRICE, newPrice, 0));
        vm.prank(taker);
        pool.swapExactOutput(
            false,
            UNIT,
            type(uint256).max,
            recipient,
            bytes32("c1"),
            bytes32("repriced-output"),
            block.timestamp,
            PRICE,
            0,
            quotedOracleUpdatedAt
        );
    }

    function test_exactInputAcceptsOraclePriceWithinTolerance() external {
        uint256 quotedOracleUpdatedAt = oracle.updatedAt();
        uint256 toleranceBps = 25;
        uint256 newPrice = PRICE + PRICE * toleranceBps / pool.BPS();
        oracle.setPrice(newPrice, quotedOracleUpdatedAt);

        vm.prank(taker);
        uint256 amountOut = pool.swapExactInput(
            true,
            UNIT,
            0,
            recipient,
            bytes32("c1"),
            bytes32("tolerant-input"),
            block.timestamp,
            PRICE,
            toleranceBps,
            quotedOracleUpdatedAt
        );

        assertEq(amountOut, 1_052_625);
    }

    function test_exactOutputAcceptsOraclePriceWithinTolerance() external {
        uint256 quotedOracleUpdatedAt = oracle.updatedAt();
        uint256 toleranceBps = 25;
        uint256 newPrice = PRICE - PRICE * toleranceBps / pool.BPS();
        oracle.setPrice(newPrice, quotedOracleUpdatedAt);

        vm.prank(taker);
        uint256 amountIn = pool.swapExactOutput(
            false,
            UNIT,
            type(uint256).max,
            recipient,
            bytes32("c1"),
            bytes32("tolerant-output"),
            block.timestamp,
            PRICE,
            toleranceBps,
            quotedOracleUpdatedAt
        );

        assertEq(amountIn, 1_047_375);
    }

    function test_exactInputRejectsOraclePriceOutsideTolerance() external {
        uint256 quotedOracleUpdatedAt = oracle.updatedAt();
        uint256 toleranceBps = 25;
        uint256 newPrice = PRICE + PRICE * 26 / pool.BPS();
        oracle.setPrice(newPrice, quotedOracleUpdatedAt);

        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.OraclePriceToleranceExceeded.selector, PRICE, newPrice, toleranceBps)
        );
        vm.prank(taker);
        pool.swapExactInput(
            true,
            UNIT,
            0,
            recipient,
            bytes32("c1"),
            bytes32("outside-tolerance"),
            block.timestamp,
            PRICE,
            toleranceBps,
            quotedOracleUpdatedAt
        );
    }

    function test_rejectsOraclePriceToleranceAboveBps() external {
        uint256 invalidToleranceBps = pool.BPS() + 1;
        uint256 minimumOracleUpdatedAt = oracle.updatedAt();
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectPropAMM.InvalidOraclePriceToleranceBps.selector, invalidToleranceBps, pool.BPS()
            )
        );
        vm.prank(taker);
        pool.swapExactInput(
            true,
            UNIT,
            0,
            recipient,
            bytes32("c1"),
            bytes32("invalid-tolerance"),
            block.timestamp,
            PRICE,
            invalidToleranceBps,
            minimumOracleUpdatedAt
        );
    }

    function test_exactInputRejectsOracleTimestampOlderThanQuote() external {
        uint256 minimumOracleUpdatedAt = oracle.updatedAt();
        oracle.setPrice(PRICE, minimumOracleUpdatedAt - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                DirectPropAMM.OracleTimestampTooOld.selector, minimumOracleUpdatedAt, minimumOracleUpdatedAt - 1
            )
        );
        vm.prank(taker);
        pool.swapExactInput(
            true,
            UNIT,
            0,
            recipient,
            bytes32("c1"),
            bytes32("older-input"),
            block.timestamp,
            PRICE,
            0,
            minimumOracleUpdatedAt
        );
    }

    function test_firstUnpauseSeedsBothDirectionalPriceAnchors() external view {
        assertEq(pool.priceAnchor(true), PRICE);
        assertEq(pool.priceAnchor(false), PRICE);
        assertEq(pool.maxPriceDeviationBps(), 50);
    }

    function test_successfulTradesAdvanceOnlyTheirDirectionalAnchor() external {
        uint256 higherPrice = PRICE + PRICE * 50 / pool.BPS();
        oracle.setPrice(higherPrice, block.timestamp);

        vm.prank(taker);
        _swapExactInput(true, UNIT, 0, recipient, bytes32("c1"), bytes32("higher"));
        assertEq(pool.priceAnchor(true), higherPrice);
        assertEq(pool.priceAnchor(false), PRICE);

        uint256 lowerPrice = higherPrice - higherPrice * 50 / pool.BPS();
        oracle.setPrice(lowerPrice, block.timestamp);

        vm.prank(taker);
        _swapExactInput(false, UNIT, 0, recipient, bytes32("c2"), bytes32("lower"));
        assertEq(pool.priceAnchor(true), higherPrice);
        assertEq(pool.priceAnchor(false), lowerPrice);
    }

    function test_consecutiveAllowedTradesCanRatchetAnchorBeyondInitialBand() external {
        uint256 firstPrice = PRICE + PRICE * 50 / pool.BPS();
        oracle.setPrice(firstPrice, block.timestamp);

        vm.prank(taker);
        _swapExactInput(true, UNIT, 0, recipient, bytes32("c1"), bytes32("step-1"));

        uint256 secondPrice = firstPrice + firstPrice * 50 / pool.BPS();
        oracle.setPrice(secondPrice, block.timestamp);

        vm.prank(taker);
        _swapExactInput(true, UNIT, 0, recipient, bytes32("c2"), bytes32("step-2"));

        assertGt(secondPrice, PRICE + PRICE * 50 / pool.BPS());
        assertEq(pool.priceAnchor(true), secondPrice);
        assertEq(pool.priceAnchor(false), PRICE);
    }

    function test_swapsAndQuotesRejectPriceOutsideAnchorDeviation() external {
        uint256 badPrice = PRICE + PRICE * 50 / pool.BPS() + 1;
        oracle.setPrice(badPrice, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.PriceDeviationExceeded.selector, true, badPrice, PRICE, uint256(50))
        );
        pool.quoteExactInput(true, UNIT);

        vm.expectPartialRevert(DirectPropAMM.PriceDeviationExceeded.selector);
        _swapExactInputBound(true, UNIT, 0, recipient, bytes32("c1"), bytes32("exact-input"), badPrice, block.timestamp);

        vm.expectPartialRevert(DirectPropAMM.PriceDeviationExceeded.selector);
        _swapExactOutputBound(
            false, UNIT, type(uint256).max, recipient, bytes32("c2"), bytes32("exact-output"), badPrice, block.timestamp
        );

        assertEq(pool.priceAnchor(true), PRICE);
        assertEq(pool.priceAnchor(false), PRICE);
    }

    function test_failedSettlementDoesNotAdvancePriceAnchor() external {
        uint256 newPrice = PRICE + PRICE * 25 / pool.BPS();
        oracle.setPrice(newPrice, block.timestamp);
        prime.setFeeBps(100);

        vm.expectPartialRevert(DirectPropAMM.ExactBalanceDeltaFailed.selector);
        _swapExactInputBound(true, UNIT, 0, recipient, bytes32("c1"), bytes32("failed"), newPrice, block.timestamp);

        assertEq(pool.priceAnchor(true), PRICE);
    }

    function test_ownerCanReanchorOnlyWhilePaused() external {
        uint256 driftedPrice = PRICE * 2;
        oracle.setPrice(driftedPrice, block.timestamp);

        vm.expectRevert(DirectPropAMM.NotPaused.selector);
        pool.resetPriceAnchor(true);

        pool.pause();
        vm.expectPartialRevert(DirectPropAMM.PriceDeviationExceeded.selector);
        pool.unpause();

        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        vm.prank(thief);
        pool.resetPriceAnchor(true);

        pool.resetPriceAnchor(true);
        assertEq(pool.priceAnchor(true), driftedPrice);

        vm.expectPartialRevert(DirectPropAMM.PriceDeviationExceeded.selector);
        pool.unpause();

        pool.resetPriceAnchor(false);
        assertEq(pool.priceAnchor(false), driftedPrice);
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_constructorRejectsExcessivePriceDeviation() external {
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.InvalidMaxPriceDeviationBps.selector, uint256(10_001), uint256(10_000))
        );
        new DirectPropAMM(prime, pathUsd, oracle, registry, address(this), guardian, 90_000, 10_001);
    }

    function test_constructorRejectsMaxOracleAgeAbovePackedRange() external {
        vm.expectRevert(DirectPropAMM.InvalidMaxOracleAge.selector);
        new DirectPropAMM(prime, pathUsd, oracle, registry, address(this), guardian, uint256(type(uint80).max) + 1, 50);
    }

    function test_ownerCanUpdateMaxPriceDeviationOnlyWhilePaused() external {
        vm.expectRevert(DirectPropAMM.NotPaused.selector);
        pool.setMaxPriceDeviationBps(100);

        pool.pause();

        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        vm.prank(thief);
        pool.setMaxPriceDeviationBps(100);

        vm.expectEmit();
        emit DirectPropAMM.MaxPriceDeviationBpsUpdated(50, 100);
        pool.setMaxPriceDeviationBps(100);
        assertEq(pool.maxPriceDeviationBps(), 100);
    }

    function test_updatedMaxPriceDeviationControlsUnpauseAndTrades() external {
        uint256 priceOutsideInitialBand = PRICE + PRICE * 75 / pool.BPS();
        oracle.setPrice(priceOutsideInitialBand, block.timestamp);
        pool.pause();

        vm.expectPartialRevert(DirectPropAMM.PriceDeviationExceeded.selector);
        pool.unpause();

        pool.setMaxPriceDeviationBps(100);
        pool.unpause();

        vm.prank(taker);
        _swapExactInput(true, UNIT, 0, recipient, bytes32("c1"), bytes32("wider-band"));
        assertEq(pool.priceAnchor(true), priceOutsideInitialBand);
    }

    function test_maxPriceDeviationUpdateRejectsExcessiveValue() external {
        pool.pause();
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.InvalidMaxPriceDeviationBps.selector, uint256(10_001), uint256(10_000))
        );
        pool.setMaxPriceDeviationBps(10_001);
    }

    function test_maxOracleAgeUpdateRejectsValueAbovePackedRange() external {
        pool.pause();
        vm.expectRevert(DirectPropAMM.InvalidMaxOracleAge.selector);
        pool.setMaxOracleAge(uint256(type(uint80).max) + 1);
    }

    function test_quoteToBaseExactOutputRoundTripReturnsFullQuote() external {
        uint256 quoteDeposit = 50_000;
        bytes32 customerId = bytes32("c1");
        pool.setRecipientAllowed(taker, true);

        uint256 baseReceived = _swapExactInput(false, quoteDeposit, 1, taker, customerId, bytes32("deposit"));
        uint256 baseReturned = _swapExactOutput(true, quoteDeposit, baseReceived, taker, customerId, bytes32("redeem"));

        assertEq(baseReceived, 47_619);
        assertEq(baseReturned, baseReceived);
        assertEq(pathUsd.balanceOf(taker), 1_000 * UNIT);
        assertEq(prime.balanceOf(taker), 1_000 * UNIT);

        bytes32 routeKey = pool.roundingRouteKey(taker, taker, customerId);
        assertEq(pool.roundingCredit(routeKey), 0);
    }

    function test_exactOutput_roundsInputUp() external {
        vm.prank(taker);
        uint256 baseIn = _swapExactOutput(true, 1, 1, recipient, bytes32("c1"), bytes32("t1"));
        assertEq(baseIn, 1);

        vm.prank(taker);
        uint256 quoteIn = _swapExactOutput(false, 1, 2, recipient, bytes32("c2"), bytes32("t2"));
        assertEq(quoteIn, 2);
    }

    function test_roundingCreditIsIsolatedByCustomerRoute() external {
        uint256 quoteDeposit = 50_000;
        bytes32 creditedCustomer = bytes32("credited");
        bytes32 otherCustomer = bytes32("other");
        pool.setRecipientAllowed(taker, true);

        vm.prank(taker);
        uint256 baseReceived = _swapExactInput(false, quoteDeposit, 1, taker, creditedCustomer, bytes32("deposit"));

        bytes32 routeKey = pool.roundingRouteKey(taker, taker, creditedCustomer);
        assertEq(pool.roundingCredit(routeKey), 5_000_000);

        (uint256 rawInput,,) = pool.quoteExactOutput(true, quoteDeposit);
        (uint256 creditedInput,,, uint256 creditedAfter) =
            pool.quoteExactOutputFor(taker, taker, creditedCustomer, true, quoteDeposit);
        (uint256 otherInput,,, uint256 otherAfter) =
            pool.quoteExactOutputFor(taker, taker, otherCustomer, true, quoteDeposit);

        assertEq(rawInput, 47_620);
        assertEq(creditedInput, baseReceived);
        assertEq(creditedAfter, 0);
        assertEq(otherInput, rawInput);
        assertEq(otherAfter, 100_000_000);
    }

    function test_repeatedDepositsCanBeRedeemedAsOneExactOutput() external {
        uint256 firstDeposit = 50_000;
        uint256 secondDeposit = 73_001;
        bytes32 customerId = bytes32("batched");
        pool.setRecipientAllowed(taker, true);
        uint256 initialQuoteBalance = pathUsd.balanceOf(taker);
        uint256 initialBaseBalance = prime.balanceOf(taker);

        uint256 firstBase = _swapExactInput(false, firstDeposit, 1, taker, customerId, bytes32("deposit-1"));
        uint256 secondBase = _swapExactInput(false, secondDeposit, 1, taker, customerId, bytes32("deposit-2"));
        uint256 baseReturned = _swapExactOutput(
            true, firstDeposit + secondDeposit, firstBase + secondBase, taker, customerId, bytes32("redeem")
        );

        assertEq(baseReturned, firstBase + secondBase);
        assertEq(pathUsd.balanceOf(taker), initialQuoteBalance);
        assertEq(prime.balanceOf(taker), initialBaseBalance);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(taker, taker, customerId)), 0);
    }

    function test_exactOutputCanBePaidEntirelyFromRouteCredit() external {
        bytes32 customerId = bytes32("credit-only");
        pool.setRecipientAllowed(taker, true);

        uint256 baseReceived = _swapExactInput(false, 22, 1, taker, customerId, bytes32("deposit"));
        uint256 baseReturned = _swapExactOutput(true, 1, 0, taker, customerId, bytes32("redeem-dust"));

        assertEq(baseReceived, 20);
        assertEq(baseReturned, 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(taker, taker, customerId)), 0);
    }

    function test_exactInput_revertsOnStalePrice() external {
        uint256 staleUpdatedAt = block.timestamp - 90_001;
        oracle.setPrice(PRICE, staleUpdatedAt);
        vm.expectPartialRevert(DirectPropAMM.StaleOraclePrice.selector);
        _swapExactInputBound(true, UNIT, 0, recipient, bytes32("c1"), bytes32("t1"), PRICE, staleUpdatedAt);
    }

    function test_exactInput_revertsOnFuturePrice() external {
        uint256 futureUpdatedAt = block.timestamp + 1;
        oracle.setPrice(PRICE, futureUpdatedAt);
        vm.expectPartialRevert(DirectPropAMM.FutureOracleTimestamp.selector);
        _swapExactInputBound(true, UNIT, 0, recipient, bytes32("c1"), bytes32("t1"), PRICE, futureUpdatedAt);
    }

    function test_exactInput_revertsOnZeroPrice() external {
        oracle.setPrice(0, block.timestamp);
        vm.expectRevert(DirectPropAMM.InvalidPrice.selector);
        _swapExactInputBound(true, UNIT, 0, recipient, bytes32("c1"), bytes32("t1"), 0, block.timestamp);
    }

    function test_guardianCanPauseButCannotUnpause() external {
        vm.prank(guardian);
        pool.pause();
        assertTrue(pool.paused());

        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        vm.prank(guardian);
        pool.unpause();
    }

    function test_repeatedPauseEmitsCurrentState() external {
        vm.prank(guardian);
        pool.pause();

        vm.expectEmit(address(pool));
        emit DirectPropAMM.PausedStateChanged(true);
        vm.prank(guardian);
        pool.pause();

        assertTrue(pool.paused());
    }

    function test_repeatedUnpauseEmitsCurrentStateWithoutRevalidatingOracle() external {
        oracle.setPrice(0, block.timestamp);

        vm.expectEmit(address(pool));
        emit DirectPropAMM.PausedStateChanged(false);
        pool.unpause();

        assertFalse(pool.paused());
        assertEq(pool.priceAnchor(true), PRICE);
        assertEq(pool.priceAnchor(false), PRICE);
    }

    function test_oracleCanOnlyChangeWhilePaused() external {
        MockOracle replacement = new MockOracle(8, PRICE, block.timestamp);
        vm.expectRevert(DirectPropAMM.NotPaused.selector);
        pool.setOracle(replacement);

        pool.pause();
        pool.setOracle(replacement);
        assertEq(address(pool.oracle()), address(replacement));
    }

    function test_oracleCannotChangeDecimalsAfterDeployment() external {
        MockOracle replacement = new MockOracle(18, 1.05e18, block.timestamp);
        pool.pause();

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.OracleDecimalsChanged.selector, 8, 18));
        pool.setOracle(replacement);
    }

    function test_virtualRecipientSettlesToWhitelistedMaster() external {
        address virtualRecipient = makeAddr("virtual");
        address master = makeAddr("master");
        registry.setResolution(virtualRecipient, master);
        pool.setRecipientAllowed(master, true);

        vm.prank(taker);
        _swapExactInput(true, UNIT, 0, virtualRecipient, bytes32("c1"), bytes32("t1"));
        assertEq(pathUsd.balanceOf(master), 1_050_000);
        assertEq(pathUsd.balanceOf(virtualRecipient), 0);
    }

    function test_feeOnTransferInputRevertsOnBalanceDelta() external {
        prime.setFeeBps(100);
        vm.expectPartialRevert(DirectPropAMM.ExactBalanceDeltaFailed.selector);
        _swapExactInputBound(true, UNIT, 0, recipient, bytes32("c1"), bytes32("t1"), PRICE, block.timestamp);
    }

    function test_redirectedOutputRevertsOnRecipientBalanceDelta() external {
        pathUsd.setRedirectRecipient(thief);
        vm.expectPartialRevert(DirectPropAMM.ExactBalanceDeltaFailed.selector);
        _swapExactInputBound(true, UNIT, 0, recipient, bytes32("c1"), bytes32("t1"), PRICE, block.timestamp);
        assertEq(pathUsd.balanceOf(thief), 0);
    }

    function test_unlistedTakerReverts() external {
        address stranger = makeAddr("stranger");
        uint256 price = oracle.price();
        uint256 updatedAt = oracle.updatedAt();
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.TakerNotAllowed.selector, stranger));
        vm.prank(stranger);
        pool.swapExactInput(
            true, UNIT, 0, recipient, bytes32("c1"), bytes32("t1"), block.timestamp, price, 0, updatedAt
        );
    }

    function test_ownerCanFundAndWithdrawOnlyWhilePaused() external {
        prime.mint(address(this), 10 * UNIT);
        prime.approve(address(pool), 10 * UNIT);
        pool.fund(address(prime), 10 * UNIT, bytes32("fund"));

        vm.expectRevert(DirectPropAMM.NotPaused.selector);
        pool.withdraw(address(prime), recipient, UNIT, bytes32("withdraw"));

        pool.pause();
        pool.withdraw(address(prime), recipient, UNIT, bytes32("withdraw"));
        assertEq(prime.balanceOf(recipient), UNIT);
    }

    function test_twoStepOwnershipTransfer() external {
        address newOwner = makeAddr("newOwner");
        pool.transferOwnership(newOwner);
        assertEq(pool.pendingOwner(), newOwner);

        vm.prank(newOwner);
        pool.acceptOwnership();
        assertEq(pool.owner(), newOwner);
        assertEq(pool.pendingOwner(), address(0));
    }

    function testFuzz_quoteRoundTripDoesNotGiveFreeValue(uint128 amount) external view {
        if (amount == 0) return;
        (uint256 quoteAmount,,) = pool.quoteExactInput(true, amount);
        if (quoteAmount == 0) return;
        (uint256 baseBack,,) = pool.quoteExactInput(false, quoteAmount);
        assertLe(baseBack, amount);
    }

    function testFuzz_quoteToBaseRoundTripDoesNotGiveFreeValue(uint128 amount) external view {
        if (amount == 0) return;
        (uint256 baseAmount,,) = pool.quoteExactInput(false, amount);
        if (baseAmount == 0) return;
        (uint256 quoteBack,,) = pool.quoteExactInput(true, baseAmount);
        assertLe(quoteBack, amount);
    }

    function testFuzz_exactOutputReversesQuoteDeposit(uint96 rawDeposit) external {
        uint256 quoteDeposit = bound(uint256(rawDeposit), 2, 1_000 * UNIT);
        bytes32 customerId = bytes32("fuzz-round-trip");
        pool.setRecipientAllowed(taker, true);
        uint256 initialQuoteBalance = pathUsd.balanceOf(taker);
        uint256 initialBaseBalance = prime.balanceOf(taker);

        uint256 baseReceived = _swapExactInput(false, quoteDeposit, 1, taker, customerId, bytes32("deposit"));
        uint256 baseReturned = _swapExactOutput(true, quoteDeposit, baseReceived, taker, customerId, bytes32("redeem"));

        assertEq(baseReturned, baseReceived);
        assertEq(pathUsd.balanceOf(taker), initialQuoteBalance);
        assertEq(prime.balanceOf(taker), initialBaseBalance);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(taker, taker, customerId)), 0);
    }

    function testFuzz_exactOutputReversesBaseDeposit(uint96 rawDeposit) external {
        uint256 baseDeposit = bound(uint256(rawDeposit), 1, 1_000 * UNIT);
        bytes32 customerId = bytes32("fuzz-reverse");
        pool.setRecipientAllowed(taker, true);
        uint256 initialQuoteBalance = pathUsd.balanceOf(taker);
        uint256 initialBaseBalance = prime.balanceOf(taker);

        uint256 quoteReceived = _swapExactInput(true, baseDeposit, 1, taker, customerId, bytes32("deposit"));
        uint256 quoteReturned =
            _swapExactOutput(false, baseDeposit, quoteReceived, taker, customerId, bytes32("redeem"));

        assertEq(quoteReturned, quoteReceived);
        assertEq(pathUsd.balanceOf(taker), initialQuoteBalance);
        assertEq(prime.balanceOf(taker), initialBaseBalance);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(taker, taker, customerId)), 0);
    }

    function test_reentrantInputTokenCallIsRejected() external {
        bytes memory reentryCall = abi.encodeCall(
            pool.swapExactInput,
            (
                true,
                1,
                0,
                recipient,
                bytes32("reentry"),
                bytes32("reentry"),
                block.timestamp,
                oracle.price(),
                0,
                oracle.updatedAt()
            )
        );
        prime.setReentry(address(pool), reentryCall);

        vm.prank(taker);
        _swapExactInput(true, UNIT, 0, recipient, bytes32("c1"), bytes32("t1"));

        assertFalse(prime.reentrySucceeded());
        assertEq(bytes4(prime.reentryResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    function _swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient_,
        bytes32 customerId,
        bytes32 tradeId
    ) internal returns (uint256 amountOut) {
        uint256 expectedOraclePrice = oracle.price();
        uint256 minimumOracleUpdatedAt = oracle.updatedAt();
        return _swapExactInputBound(
            baseToQuote,
            amountIn,
            minAmountOut,
            recipient_,
            customerId,
            tradeId,
            expectedOraclePrice,
            minimumOracleUpdatedAt
        );
    }

    function _swapExactInputBound(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient_,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 expectedOraclePrice,
        uint256 minimumOracleUpdatedAt
    ) internal returns (uint256 amountOut) {
        vm.prank(taker);
        return pool.swapExactInput(
            baseToQuote,
            amountIn,
            minAmountOut,
            recipient_,
            customerId,
            tradeId,
            block.timestamp,
            expectedOraclePrice,
            0,
            minimumOracleUpdatedAt
        );
    }

    function _swapExactOutput(
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient_,
        bytes32 customerId,
        bytes32 tradeId
    ) internal returns (uint256 amountIn) {
        uint256 expectedOraclePrice = oracle.price();
        uint256 minimumOracleUpdatedAt = oracle.updatedAt();
        return _swapExactOutputBound(
            baseToQuote,
            amountOut,
            maxAmountIn,
            recipient_,
            customerId,
            tradeId,
            expectedOraclePrice,
            minimumOracleUpdatedAt
        );
    }

    function _swapExactOutputBound(
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient_,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 expectedOraclePrice,
        uint256 minimumOracleUpdatedAt
    ) internal returns (uint256 amountIn) {
        vm.prank(taker);
        return pool.swapExactOutput(
            baseToQuote,
            amountOut,
            maxAmountIn,
            recipient_,
            customerId,
            tradeId,
            block.timestamp,
            expectedOraclePrice,
            0,
            minimumOracleUpdatedAt
        );
    }
}
