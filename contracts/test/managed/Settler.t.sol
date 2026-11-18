// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "./utils/TestFeeHook.sol";
using TestFeeHookLib for ManagedDirectPropAMM;

import { TestRouter } from "./utils/TestRouter.sol";
import { ISettler } from "../../src/managed/interfaces/ISettler.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ManagedPoolFixture } from "./utils/ManagedPoolFixture.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { Settler } from "../../src/managed/Settler.sol";
import { IManagedDirectPropAMM as IM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";

contract ManagedSettlerTest is ManagedPoolFixture {
    PoolFactory internal factory;
    Settler internal settler;
    TestRouter internal router;

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory();
        settler = Settler(factory.defaultSettler());
        pool = ManagedDirectPropAMM(factory.createPool(address(this), bytes32("pool")));
        pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.addPair(address(eurx), address(pathUsd), eurOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.configureFees(0, taker, 100, 200);
        pool.configureFees(1, taker, 300, 400);
        router = new TestRouter(settler);
        pool.configureFees(0, address(router), 1000, 500);
        pool.configureFees(1, address(router), 200, 100);
        for (uint16 i; i < 2; ++i) {
            pool.setPairAccess(i, IM.AccessMode.Listed);
            _listHome(i, taker);
            _listHome(i, member);
            _listHome(i, address(router));
        }
        prime.mint(address(pool), 1_000_000 * UNIT);
        pathUsd.mint(address(pool), 2_000_000 * UNIT);
        eurx.mint(address(pool), 1_000_000 * EUR_UNIT);
        for (uint256 i; i < 2; ++i) {
            address account = i == 0 ? taker : member;
            vm.startPrank(account);
            prime.approve(address(settler), type(uint256).max);
            pathUsd.approve(address(settler), type(uint256).max);
            eurx.approve(address(settler), type(uint256).max);
            prime.approve(address(router), type(uint256).max);
            pathUsd.approve(address(router), type(uint256).max);
            eurx.approve(address(router), type(uint256).max);
            prime.approve(address(pool), type(uint256).max);
            pathUsd.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        pool.unpause();
    }

    function params(bool exactInput, bool direction) internal view returns (IM.SwapParams memory s) {
        s = IM.SwapParams(
            0,
            direction,
            exactInput,
            10 * UNIT,
            exactInput ? 0 : 20 * UNIT,
            0,
            CUSTOMER,
            TRADE,
            block.timestamp + 100,
            PRIME_PRICE,
            0,
            block.timestamp
        );
    }

    function test_counterfeitCloneRejectedBeforePull() public {
        address fake = Clones.clone(factory.implementation());
        vm.expectRevert(IM.InvalidAddress.selector);
        IM(fake).initialize(address(this), address(settler));
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(ISettler.UnknownPool.selector, fake));
        settler.swap(fake, params(true, true));
    }

    function test_poolOnlyAcceptsCurrentSettler() public {
        vm.prank(taker);
        vm.expectRevert(IM.NotSettler.selector);
        pool.fill(params(true, true), member);
    }

    function test_settlerCannotForwardArbitraryTaker() public {
        vm.prank(taker);
        (bool ok,) = address(settler)
            .call(
                abi.encodeWithSignature(
                    "swap(address,(uint16,bool,bool,uint256,uint256,uint64,bytes32,bytes32,uint256,uint256,uint256,uint256),address)",
                    address(pool),
                    params(true, true),
                    member
                )
            );
        assertFalse(ok);
    }

    function test_ownerReplacesSettlerAndOldOneStops() public {
        Settler replacement = new Settler(IM(factory.implementation()));
        vm.prank(unauthorized);
        vm.expectRevert(IM.NotOwner.selector);
        pool.setSettler(address(replacement));
        vm.expectRevert(IM.InvalidAddress.selector);
        pool.setSettler(address(0));
        pool.setSettler(address(replacement)); // No pause required, as in v2.
        uint256 beforeIn = prime.balanceOf(taker);
        vm.startPrank(taker);
        vm.expectRevert(IM.NotSettler.selector);
        settler.swap(address(pool), params(true, true));
        assertEq(prime.balanceOf(taker), beforeIn);
        prime.approve(address(replacement), type(uint256).max);
        assertEq(replacement.swap(address(pool), params(true, true)), 10_395_000);
        vm.stopPrank();
    }

    function test_newOwnerControlsSettler() public {
        pool.transferOwnership(member);
        vm.prank(member);
        pool.acceptOwnership();
        vm.expectRevert(IM.NotOwner.selector);
        pool.setSettler(taker);
        vm.prank(member);
        pool.setSettler(taker);
        assertEq(pool.settler(), taker);
    }

    function test_routedFeesBelongToRouterNotUser() public {
        uint256 beforeBalance = pathUsd.balanceOf(taker);
        vm.prank(taker);
        uint256 result = router.swap(address(pool), params(true, true));
        assertEq(result, 9_450_000); // Router's 10%, not user's 1%.
        assertEq(pathUsd.balanceOf(taker) - beforeBalance, result);
        vm.prank(member);
        assertEq(router.swap(address(pool), params(true, true)), result); // Same router rate for another user.
        assertEq(prime.balanceOf(address(settler)), 0);
        assertEq(prime.allowance(address(settler), address(pool)), 0);
    }

    function test_routedAccessChecksRouterNotUser() public {
        pool.setMembers(0, 0, _one(taker), false);
        vm.prank(taker);
        router.swap(address(pool), params(true, true));
        pool.setMembers(0, 0, _one(address(router)), false);
        vm.prank(member);
        vm.expectRevert(abi.encodeWithSelector(IM.TakerNotAllowed.selector, address(router)));
        router.swap(address(pool), params(true, true));
    }

    function test_denyRouterStopsEveryUser() public {
        pool.setDenied(_one(address(router)), true);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(IM.TakerDenied.selector, address(router)));
        router.swap(address(pool), params(true, true));
    }

    function test_exactOutBothDirectionsAndDirectSettlement() public {
        for (uint256 i; i < 2; ++i) {
            IM.SwapParams memory s = params(false, i == 0);
            (uint256 expected,,,) =
                pool.quoteExactOutputFor(0, i == 0 ? taker : address(router), CUSTOMER, s.baseToQuote, s.amount);
            MockTIP20 input = s.baseToQuote ? prime : pathUsd;
            MockTIP20 output = s.baseToQuote ? pathUsd : prime;
            uint256 beforeIn = input.balanceOf(taker);
            uint256 beforeOut = output.balanceOf(taker);
            vm.prank(taker);
            uint256 paid = i == 0 ? settler.swap(address(pool), s) : router.swap(address(pool), s);
            assertEq(paid, expected);
            assertEq(beforeIn - input.balanceOf(taker), paid);
            assertEq(output.balanceOf(taker) - beforeOut, s.amount);
            assertEq(input.balanceOf(address(settler)), 0);
            assertEq(input.allowance(address(settler), address(pool)), 0);
        }
    }

    function testFuzz_quoteParity(uint96 amount, bool exactInput, bool direction, bool routed, bool secondPair) public {
        IM.SwapParams memory s = params(exactInput, direction);
        s.pairIndex = secondPair ? 1 : 0;
        s.expectedOraclePrice = secondPair ? EUR_PRICE : PRIME_PRICE;
        s.amount = bound(uint256(amount), 1e6, 1000e6);
        if (secondPair && direction == exactInput) s.amount *= 1e12;
        s.limit = exactInput ? 0 : type(uint256).max;
        uint256 expected;
        if (exactInput) {
            (expected,,,) =
                pool.quoteExactInputFor(s.pairIndex, routed ? address(router) : taker, CUSTOMER, direction, s.amount);
        } else {
            (expected,,,) =
                pool.quoteExactOutputFor(s.pairIndex, routed ? address(router) : taker, CUSTOMER, direction, s.amount);
        }
        vm.prank(taker);
        uint256 result = routed ? router.swap(address(pool), s) : settler.swap(address(pool), s);
        assertEq(result, expected);
        assertEq(prime.balanceOf(address(settler)), 0);
        assertEq(pathUsd.balanceOf(address(settler)), 0);
        assertEq(eurx.balanceOf(address(settler)), 0);
    }

    function test_creditDoesNotCrossFromUserToRouter() public {
        IM.SwapParams memory s = params(false, true);
        s.amount = 1;
        s.limit = 2;
        for (uint256 i; i < 20; ++i) {
            vm.prank(member);
            assertEq(settler.swap(address(pool), s), 1);
        }
        bytes32 key = pool.roundingRouteKey(0, member, CUSTOMER);
        assertGt(pool.roundingCredit(key), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, taker, CUSTOMER)), 0);
        s.limit = 0;
        (uint256 input,,,) = pool.quoteExactOutputFor(0, member, CUSTOMER, true, 1);
        assertEq(input, 0);
        vm.prank(member);
        vm.expectRevert();
        router.swap(address(pool), s);
        assertGt(pool.roundingCredit(key), 0);
        vm.prank(member);
        assertEq(settler.swap(address(pool), s), 0);
        assertEq(pool.roundingCredit(key), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, address(router), CUSTOMER)), 0);
    }

    function test_slippageAndDeadlineAtomic() public {
        IM.SwapParams memory s = params(true, true);
        s.limit = PRIME_OUT;
        bytes32 beforeState = _settlementState();
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(IM.SlippageExceeded.selector, s.limit, uint256(10_395_000)));
        settler.swap(address(pool), s);
        assertEq(_settlementState(), beforeState);
        s.limit = 0;
        s.deadline = block.timestamp - 1;
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(IM.DeadlineExpired.selector, s.deadline, block.timestamp));
        settler.swap(address(pool), s);
        assertEq(_settlementState(), beforeState);
    }

    function test_oracleBindingAndPausePreserved() public {
        IM.SwapParams memory s = params(true, true);
        s.expectedOraclePrice = PRIME_PRICE + 1;
        bytes32 beforeState = _settlementState();
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IM.OraclePriceToleranceExceeded.selector, s.expectedOraclePrice, PRIME_PRICE, uint256(0)
            )
        );
        settler.swap(address(pool), s);
        assertEq(_settlementState(), beforeState);
        pool.pause();
        vm.prank(taker);
        vm.expectRevert(IM.Paused.selector);
        settler.swap(address(pool), params(true, true));
        assertEq(_settlementState(), beforeState);
    }

    function test_ambientInputCannotReplaceCallerPayment() public {
        prime.mint(address(settler), 100 * UNIT);
        vm.prank(taker);
        prime.approve(address(settler), 0);
        bytes32 beforeState = _settlementState();
        vm.prank(taker);
        // MockTIP20's allowance subtraction underflows. Access and inventory are otherwise valid.
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        settler.swap(address(pool), params(true, true));
        assertEq(_settlementState(), beforeState);
        // Prove the same caller and route can fill once the missing approval is supplied.
        vm.prank(taker);
        prime.approve(address(settler), 10 * UNIT);
        vm.prank(taker);
        assertEq(settler.swap(address(pool), params(true, true)), 10_395_000);
        assertEq(prime.balanceOf(address(settler)), 100 * UNIT);
        assertEq(prime.allowance(taker, address(settler)), 0);
    }

    function test_donationsRemainUntouched() public {
        prime.mint(address(settler), 123);
        pathUsd.mint(address(settler), 456);
        vm.prank(taker);
        settler.swap(address(pool), params(true, true));
        assertEq(prime.balanceOf(address(settler)), 123);
        assertEq(pathUsd.balanceOf(address(settler)), 456);
    }

    function test_exactOutFillMustEqualQuoteAndRollsBackInput() public {
        IM.SwapParams memory s = params(false, true);
        (uint256 quoted,,,) = pool.quoteExactOutputFor(0, taker, CUSTOMER, true, s.amount);
        vm.mockCall(address(pool), abi.encodeCall(IM.fill, (s, taker)), abi.encode(quoted + 1));
        vm.prank(taker);
        prime.approve(address(settler), 20 * UNIT);
        bytes32 beforeState = _settlementState();
        vm.prank(taker);
        vm.expectRevert(ISettler.FillMismatch.selector);
        settler.swap(address(pool), s);
        assertEq(_settlementState(), beforeState);
    }

    function test_inputMovesDirectlyToPool() public {
        IM.SwapParams memory s = params(true, true);
        bytes32 memo = keccak256(abi.encode("SWAP_IN", s.customerId, s.tradeId));
        vm.expectCall(
            address(prime), abi.encodeCall(prime.transferFromWithMemo, (taker, address(pool), s.amount, memo)), 1
        );
        vm.prank(taker);
        settler.swap(address(pool), s);
        assertEq(prime.balanceOf(address(settler)), 0);
        assertEq(prime.allowance(address(settler), address(pool)), 0);
    }

    function test_copiedCloneCodeAndStorageCannotProveProvenance() public {
        address fake = makeAddr("fake");
        vm.etch(fake, address(pool).code);
        vm.store(fake, bytes32(uint256(0)), vm.load(address(pool), bytes32(uint256(0))));
        assertFalse(factory.isPool(fake));
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(ISettler.UnknownPool.selector, fake));
        settler.swap(fake, params(true, true));
    }

    /// @dev Exercise the last external payout, after input custody and pool accounting have changed.
    /// Each attack has a healthy-transfer positive control; an earlier access/oracle failure cannot pass the test.
    function test_outputFailureRollsBackBalancesAllowancesAnchorsAndCredits() public {
        // Finite approvals make an accidentally consumed allowance observable after a rejected swap.
        vm.startPrank(taker);
        prime.approve(address(settler), 1000 * UNIT);
        pathUsd.approve(address(settler), 1000 * UNIT);
        vm.stopPrank();
        prime.mint(address(settler), 123);
        pathUsd.mint(address(settler), 456);
        IM.SwapParams memory seed = params(true, true);
        seed.amount = 103;
        vm.prank(taker);
        settler.swap(address(pool), seed);
        assertGt(pool.roundingCredit(pool.roundingRouteKey(0, taker, CUSTOMER)), 0, "seed real credit");

        for (uint256 i; i < 8; ++i) {
            bool direction = i & 1 == 0;
            bool exactInput = i & 2 == 0;
            bool redirect = i & 4 == 0;
            IM.SwapParams memory s = params(exactInput, direction);
            // Move the observation within its band so a successful fill changes its directional anchor.
            uint256 price = PRIME_PRICE + (i + 1) * 1000;
            primeOracle.setPrice(price, block.timestamp);
            s.expectedOraclePrice = price;
            MockTIP20 output = direction ? pathUsd : prime;
            uint256 amountOut;
            if (exactInput) {
                (amountOut,,,) = pool.quoteExactInputFor(0, taker, CUSTOMER, direction, s.amount);
            } else {
                amountOut = s.amount;
            }
            if (redirect) output.setRedirectRecipient(stranger);
            else output.setFeeBps(100);
            bytes32 beforeState = _settlementState();
            uint256 actual = redirect ? 0 : amountOut - amountOut / 100;
            vm.prank(taker);
            vm.expectRevert(
                abi.encodeWithSelector(IM.ExactBalanceDeltaFailed.selector, address(output), amountOut, actual)
            );
            settler.swap(address(pool), s);
            assertEq(_settlementState(), beforeState, "late failure did not roll back the full settlement");

            output.setRedirectRecipient(address(0));
            output.setFeeBps(0);
            uint256 beforeOutput = output.balanceOf(taker);
            vm.prank(taker);
            settler.swap(address(pool), s);
            assertEq(output.balanceOf(taker) - beforeOutput, amountOut, "healthy payout must execute");
            assertEq(pool.priceAnchor(0, direction), price, "healthy fill must advance the anchor");
            assertEq(prime.balanceOf(address(settler)), 123, "ambient base untouched");
            assertEq(pathUsd.balanceOf(address(settler)), 456, "ambient quote untouched");
        }
    }

    /// @dev Include both shared-inventory pairs and multiple routes, not just the caller's input balance.
    function _settlementState() internal view returns (bytes32 digest) {
        MockTIP20[3] memory tokens = [prime, pathUsd, eurx];
        address[5] memory accounts = [address(pool), taker, member, address(settler), stranger];
        for (uint256 t; t < tokens.length; ++t) {
            for (uint256 a; a < accounts.length; ++a) {
                digest = keccak256(
                    abi.encode(
                        digest,
                        tokens[t].balanceOf(accounts[a]),
                        tokens[t].allowance(accounts[a], address(settler)),
                        tokens[t].allowance(accounts[a], address(pool))
                    )
                );
            }
        }
        for (uint16 p; p < 2; ++p) {
            digest = keccak256(abi.encode(digest, pool.priceAnchor(p, true), pool.priceAnchor(p, false)));
            for (uint256 a; a < accounts.length; ++a) {
                digest = keccak256(
                    abi.encode(
                        digest,
                        pool.roundingCredit(pool.roundingRouteKey(p, accounts[a], CUSTOMER)),
                        pool.roundingCredit(pool.roundingRouteKey(p, accounts[a], bytes32("other-customer")))
                    )
                );
            }
        }
    }

    function test_feeOnTransferRejected() public {
        prime.setFeeBps(100);
        vm.prank(taker);
        prime.approve(address(settler), 20 * UNIT);
        bytes32 beforeState = _settlementState();
        vm.prank(taker);
        vm.expectRevert(ISettler.BalanceMismatch.selector);
        settler.swap(address(pool), params(true, true));
        assertEq(_settlementState(), beforeState, "input mismatch must roll back custody and allowance");
    }

    function test_falseTransferRejected() public {
        prime.setReturnFalse(true);
        bytes32 beforeState = _settlementState();
        vm.prank(taker);
        vm.expectRevert(ISettler.TransferFailed.selector);
        settler.swap(address(pool), params(true, true));
        assertEq(_settlementState(), beforeState);
    }

    function test_reentrancyBlockedWithinOneSwap() public {
        IM.SwapParams memory s = params(true, true);
        prime.setReentry(address(settler), abi.encodeCall(settler.swap, (address(pool), s)));
        vm.prank(taker);
        settler.swap(address(pool), s);
        assertFalse(prime.reentrySucceeded());
        assertEq(prime.reentryResult(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
    }

    /// @dev A settled trade's input carries the direct path's documented memo, so reconciliation by memo sees one
    /// trade the same way whichever entry point settles it.
    function test_settledAndDirectInputShareMemo() public {
        IM.SwapParams memory s = params(true, true);
        bytes32 memo = keccak256(abi.encode("SWAP_IN", s.customerId, s.tradeId));
        vm.expectCall(
            address(prime), abi.encodeCall(prime.transferFromWithMemo, (taker, address(pool), s.amount, memo)), 2
        );
        vm.startPrank(taker);
        settler.swap(address(pool), s);
        pool.swapExactInput(
            s.pairIndex,
            s.baseToQuote,
            s.amount,
            s.limit,
            s.sponsorId,
            s.customerId,
            s.tradeId,
            s.deadline,
            s.expectedOraclePrice,
            s.oraclePriceToleranceBps,
            s.minimumOracleUpdatedAt
        );
        vm.stopPrank();
    }

    /// @dev A removed pair reverts the pool's own `UnknownPair` before anything moves, not a bare call into address 0.
    function test_removedPairRevertsUnknownPair() public {
        pool.removePair(0);
        uint256 beforeIn = prime.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(IM.UnknownPair.selector, uint16(0)));
        settler.swap(address(pool), params(true, true));
        IM.SwapParams memory s = params(true, true);
        s.pairIndex = 7;
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(IM.UnknownPair.selector, uint16(7)));
        settler.swap(address(pool), s);
        assertEq(prime.balanceOf(taker), beforeIn);
    }
}
