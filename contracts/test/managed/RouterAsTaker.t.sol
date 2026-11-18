// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "./utils/TestFeeHook.sol";
using TestFeeHookLib for ManagedDirectPropAMM;

import { ManagedPoolFixture } from "./utils/ManagedPoolFixture.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { Settler } from "../../src/managed/Settler.sol";
import { IManagedDirectPropAMM as IM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { ISettler } from "../../src/managed/interfaces/ISettler.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

/// @dev A Tempo-style test double checks its authenticated user through pool views, but settles only as itself.
contract AuthenticatedManagedTestRouter {
    ISettler public immutable settler;
    address public lastTaker;
    uint256 public outputReceived;

    constructor(ISettler settler_) {
        settler = settler_;
    }

    function swap(address pool, IM.SwapParams calldata s) external returns (uint256 result) {
        require(IM(pool).takerAllowed(s.pairIndex, msg.sender, s.sponsorId), "user not allowed");
        lastTaker = msg.sender;
        IM.Pair memory pair = IM(pool).pair(s.pairIndex);
        MockTIP20 input = MockTIP20(s.baseToQuote ? pair.base : pair.quote);
        MockTIP20 output = MockTIP20(s.baseToQuote ? pair.quote : pair.base);
        uint256 amountIn = s.amount;
        if (!s.exactInput) {
            (amountIn,,,) =
                IM(pool).quoteExactOutputFor(s.pairIndex, address(this), s.customerId, s.baseToQuote, s.amount);
        }
        if (amountIn != 0) require(input.transferFromWithMemo(msg.sender, address(this), amountIn, s.tradeId));
        input.approve(address(settler), amountIn);
        uint256 beforeOut = output.balanceOf(address(this));
        result = settler.swap(pool, s);
        outputReceived = output.balanceOf(address(this)) - beforeOut;
        require(outputReceived == (s.exactInput ? result : s.amount), "router received output");
        input.approve(address(settler), 0);
        output.transferWithMemo(msg.sender, outputReceived, s.tradeId);
    }
}

contract ManagedRouterAsTakerTest is ManagedPoolFixture {
    // Historical tuples keep removed-selector tests ABI-valid without restoring the deleted interface.
    struct LegacyOrder {
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minAmountOut;
        uint256 deadline;
        bytes32 customerId;
        bytes32 tradeId;
    }

    struct LegacyLeg {
        address pool;
        uint16 pairIndex;
        bool baseToQuote;
        uint256 amountIn;
        uint256 minAmountOut;
        uint64 sponsorId;
        uint256 expectedOraclePrice;
        uint256 oraclePriceToleranceBps;
        uint256 minimumOracleUpdatedAt;
    }

    PoolFactory internal factory;
    Settler internal settler;
    AuthenticatedManagedTestRouter internal router;
    AuthenticatedManagedTestRouter internal secondRouter;
    ManagedDirectPropAMM internal poolB;
    address internal VIRTUAL = VirtualAddress.make(0x12345678, 1);

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory();
        settler = Settler(factory.defaultSettler());
        router = new AuthenticatedManagedTestRouter(settler);
        secondRouter = new AuthenticatedManagedTestRouter(settler);
        pool = ManagedDirectPropAMM(factory.createPool(address(this), bytes32("trusted-a")));
        pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.addPair(address(eurx), address(pathUsd), eurOracle, MAX_AGE, MAX_DEVIATION_BPS);
        poolB = ManagedDirectPropAMM(factory.createPool(address(this), bytes32("trusted-b")));
        poolB.addPair(address(eurx), address(pathUsd), eurOracle, MAX_AGE, MAX_DEVIATION_BPS);
        for (uint16 i; i < 2; ++i) {
            pool.configureFees(i, taker, 100, 200);
            pool.configureFees(i, address(router), 1000, 500);
            pool.setPairAccess(i, IM.AccessMode.Listed);
            _listHome(i, taker);
            _listHome(i, member);
        }
        poolB.configureFees(0, taker, 50, 60);
        poolB.configureFees(0, address(router), 1000, 1000);
        poolB.setPairAccess(0, IM.AccessMode.Listed);
        poolB.setMembers(0, HOME, _one(taker), true);
        poolB.setMembers(0, HOME, _one(member), true);
        for (uint16 i; i < 2; ++i) {
            _listHome(i, address(router));
            _listHome(i, address(secondRouter));
        }
        poolB.setMembers(0, HOME, _one(address(router)), true);
        poolB.setMembers(0, HOME, _one(address(secondRouter)), true);
        prime.mint(address(pool), 1_000_000 * UNIT);
        pathUsd.mint(address(pool), 2_000_000 * UNIT);
        eurx.mint(address(pool), 1_000_000 * EUR_UNIT);
        pathUsd.mint(address(poolB), 1_000_000 * UNIT);
        eurx.mint(address(poolB), 1_000_000 * EUR_UNIT);
        pool.unpause();
        poolB.unpause();
        address[3] memory users = [taker, member, stranger];
        MockTIP20[3] memory tokens = [prime, pathUsd, eurx];
        for (uint256 u; u < users.length; ++u) {
            vm.startPrank(users[u]);
            for (uint256 t; t < tokens.length; ++t) {
                tokens[t].approve(address(router), 100_000 * (t == 2 ? EUR_UNIT : UNIT));
                tokens[t].approve(address(secondRouter), 100_000 * (t == 2 ? EUR_UNIT : UNIT));
                tokens[t].approve(address(settler), 100_000 * (t == 2 ? EUR_UNIT : UNIT));
                tokens[t].approve(address(pool), 100_000 * (t == 2 ? EUR_UNIT : UNIT));
            }
            vm.stopPrank();
        }
    }

    function _params(bool exactInput, bool direction) internal view returns (IM.SwapParams memory) {
        return IM.SwapParams(
            0,
            direction,
            exactInput,
            10 * UNIT,
            exactInput ? 0 : 20 * UNIT,
            HOME,
            CUSTOMER,
            TRADE,
            block.timestamp + 100,
            PRIME_PRICE,
            0,
            block.timestamp
        );
    }

    function _quote(ManagedDirectPropAMM p, uint16 index, address user, bool direction, uint256 amount)
        internal
        view
        returns (uint256 result)
    {
        (result,,,) = p.quoteExactInputFor(index, user, CUSTOMER, direction, amount);
    }

    function _assertEmptySettlement() internal view {
        MockTIP20[3] memory tokens = [prime, pathUsd, eurx];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(address(settler)), 0, "settler holds nothing");
            assertEq(tokens[i].balanceOf(address(router)), 0, "router forwarded all tokens");
            assertEq(tokens[i].allowance(address(router), address(settler)), 0, "router clears approvals");
            assertEq(tokens[i].allowance(address(settler), address(pool)), 0, "no settler approval");
            assertEq(tokens[i].allowance(address(settler), address(poolB)), 0, "no settler approval B");
        }
    }

    /// @dev Finite approvals, all custody endpoints, anchors and credits must roll back together.
    function _state() internal view returns (bytes32 digest) {
        MockTIP20[3] memory tokens = [prime, pathUsd, eurx];
        address[8] memory accounts = [
            address(pool),
            address(poolB),
            taker,
            member,
            stranger,
            address(router),
            address(secondRouter),
            address(settler)
        ];
        for (uint256 t; t < tokens.length; ++t) {
            for (uint256 a; a < accounts.length; ++a) {
                digest = keccak256(
                    abi.encode(
                        digest,
                        tokens[t].balanceOf(accounts[a]),
                        tokens[t].allowance(accounts[a], address(settler)),
                        tokens[t].allowance(accounts[a], address(router)),
                        tokens[t].allowance(accounts[a], address(secondRouter)),
                        tokens[t].allowance(accounts[a], address(pool))
                    )
                );
            }
        }
        ManagedDirectPropAMM[2] memory pools = [pool, poolB];
        for (uint256 p; p < pools.length; ++p) {
            for (uint16 i; i < pools[p].pairCount(); ++i) {
                digest = keccak256(abi.encode(digest, pools[p].priceAnchor(i, true), pools[p].priceAnchor(i, false)));
                for (uint256 a; a < accounts.length; ++a) {
                    digest = keccak256(
                        abi.encode(
                            digest,
                            pools[p].roundingCredit(pools[p].roundingRouteKey(i, accounts[a], CUSTOMER)),
                            pools[p].roundingCredit(pools[p].roundingRouteKey(i, accounts[a], bytes32("other")))
                        )
                    );
                }
            }
        }
    }

    function test_routerPaysOwnFeeAndUserReceivesExactOutput() public {
        IM.SwapParams memory s = _params(true, true);
        uint256 expected = _quote(pool, 0, address(router), true, s.amount);
        uint256 beforeIn = prime.balanceOf(taker);
        uint256 beforeOut = pathUsd.balanceOf(taker);
        vm.prank(taker);
        assertEq(router.swap(address(pool), s), expected);
        assertEq(prime.balanceOf(taker), beforeIn - s.amount);
        assertEq(pathUsd.balanceOf(taker), beforeOut + expected);
        _assertEmptySettlement();
    }

    function test_routerNeedsNormalListingEvenWhenUserListed() public {
        pool.setMembers(0, HOME, _one(address(router)), false);
        bytes32 beforeState = _state();
        vm.prank(taker);
        vm.expectRevert();
        router.swap(address(pool), _params(true, true));
        assertEq(_state(), beforeState);
    }

    function test_routerChecksUnderlyingUserAndPoolChecksRouterDenials() public {
        vm.prank(stranger);
        vm.expectRevert("user not allowed");
        router.swap(address(pool), _params(true, true));
        pool.setDenied(_one(taker), true);
        vm.prank(taker);
        vm.expectRevert("user not allowed");
        router.swap(address(pool), _params(true, true));
        pool.setDenied(_one(taker), false);
        pool.setDenied(_one(address(router)), true);
        vm.prank(taker);
        vm.expectRevert();
        router.swap(address(pool), _params(true, true));
    }

    function test_sponsorMustAdmitBothUserAndRouter() public {
        pool.addSponsor(7, address(this));
        pool.setPairSponsor(0, 7, true);
        pool.setMembers(0, 7, _one(taker), true);
        IM.SwapParams memory s = _params(true, true);
        s.sponsorId = 7;
        vm.prank(taker);
        vm.expectRevert();
        router.swap(address(pool), s);
        pool.setMembers(0, 7, _one(address(router)), true);
        vm.prank(taker);
        assertGt(router.swap(address(pool), s), 0);
        pool.setSponsorEnabled(7, false);
        vm.prank(taker);
        vm.expectRevert("user not allowed");
        router.swap(address(pool), s);
    }

    function test_routerCreditIsIsolatedFromUserOtherRouterAndCustomer() public {
        IM.SwapParams memory s = _params(false, true);
        s.amount = 1;
        s.limit = 2;
        // Zero fee makes the exact-output rounding accumulate a whole output unit predictably.
        pool.configureFees(0, address(router), 0, 0);
        for (uint256 i; i < 20; ++i) {
            vm.prank(member);
            router.swap(address(pool), s);
        }
        bytes32 key = pool.roundingRouteKey(0, address(router), CUSTOMER);
        uint256 credit = pool.roundingCredit(key);
        assertGt(credit, 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, member, CUSTOMER)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, address(secondRouter), CUSTOMER)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, address(router), bytes32("other"))), 0);
        s.limit = 0;
        vm.prank(member);
        vm.expectRevert();
        settler.swap(address(pool), s);
        vm.prank(member);
        vm.expectRevert();
        secondRouter.swap(address(pool), s);
        s.customerId = bytes32("other");
        vm.prank(member);
        vm.expectRevert();
        router.swap(address(pool), s);
        assertEq(pool.roundingCredit(key), credit);
        s.customerId = CUSTOMER;
        vm.prank(member);
        assertEq(router.swap(address(pool), s), 0);
    }

    function test_swapIgnoresTrailingForgedIdentity() public {
        IM.SwapParams memory s = _params(true, true);
        uint256 expected = _quote(pool, 0, taker, true, s.amount);
        uint256 beforeIn = prime.balanceOf(taker);
        uint256 beforeOut = pathUsd.balanceOf(taker);
        uint256 memberIn = prime.balanceOf(member);
        uint256 memberOut = pathUsd.balanceOf(member);
        vm.prank(taker);
        (bool ok, bytes memory result) =
            address(settler).call(bytes.concat(abi.encodeCall(ISettler.swap, (address(pool), s)), abi.encode(member)));
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), expected, "caller fee selected, not forged identity");
        assertEq(prime.balanceOf(taker), beforeIn - s.amount);
        assertEq(pathUsd.balanceOf(taker), beforeOut + expected);
        assertEq(prime.balanceOf(member), memberIn);
        assertEq(pathUsd.balanceOf(member), memberOut);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, member, CUSTOMER)), 0);

        _assertEmptySettlement();
    }

    function test_removedMultilegForwardingAndTrustSelectorsFailClosed() public {
        IM.SwapParams memory s = _params(true, true);
        LegacyOrder memory order =
            LegacyOrder(address(prime), s.amount, address(pathUsd), 0, block.timestamp + 100, CUSTOMER, TRADE);
        LegacyLeg[] memory legs = new LegacyLeg[](1);
        legs[0] = LegacyLeg(address(pool), 0, true, s.amount, 0, HOME, PRIME_PRICE, 0, block.timestamp);
        bytes memory tuple = abi.encode(address(pool), s, taker);
        bytes4 oldSwap = bytes4(
            keccak256(
                "swap(address,(uint16,bool,bool,uint256,uint256,uint64,bytes32,bytes32,uint256,uint256,uint256,uint256),address)"
            )
        );
        bytes4 oldRouter = bytes4(
            keccak256(
                "swapFromRouter(address,(uint16,bool,bool,uint256,uint256,uint64,bytes32,bytes32,uint256,uint256,uint256,uint256),address)"
            )
        );
        bytes32 beforeState = _state();
        (bool ok,) = address(settler).call(bytes.concat(oldSwap, tuple));
        assertFalse(ok);
        (ok,) = address(settler).call(bytes.concat(oldRouter, tuple));
        assertFalse(ok);
        vm.prank(taker);
        (bool routeOk, bytes memory routeResult) = address(settler)
            .call(
                abi.encodeWithSignature(
                    "swapRoute((address,uint256,address,uint256,uint256,bytes32,bytes32),(address,uint16,bool,uint256,uint256,uint64,uint256,uint256,uint256)[])",
                    order,
                    legs
                )
            );
        assertFalse(routeOk, "multileg selector was removed");
        assertEq(routeResult.length, 0, "unknown selector, not a downstream policy refusal");
        (ok,) = address(settler)
            .call(
                abi.encodeWithSignature(
                    "swapRoute((address,uint256,address,uint256,uint256,bytes32,bytes32),(address,uint16,bool,uint256,uint256,uint64,uint256,uint256,uint256)[],address)",
                    order,
                    legs,
                    taker
                )
            );
        assertFalse(ok);
        (ok,) = address(settler)
            .call(
                abi.encodeWithSignature(
                    "swapRouteFromRouter((address,uint256,address,uint256,uint256,bytes32,bytes32),(address,uint16,bool,uint256,uint256,uint64,uint256,uint256,uint256)[],address)",
                    order,
                    legs,
                    taker
                )
            );
        assertFalse(ok);
        (ok,) = address(router).call(bytes.concat(oldSwap, tuple));
        assertFalse(ok, "user cannot choose the router's taker");
        (ok,) = address(pool).call(abi.encodeWithSignature("setTrustedRouter(address,bool)", address(router), true));
        assertFalse(ok);
        (ok,) = address(pool).call(abi.encodeWithSignature("trustedRouter(address)", address(router)));
        assertFalse(ok);
        assertEq(_state(), beforeState);
    }
}
