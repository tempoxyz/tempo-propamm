// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { MockAddressRegistry } from "../mocks/MockAddressRegistry.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";

contract DirectPropAMMRouteActor {
    DirectPropAMM internal immutable pool;
    MockTIP20 internal immutable baseToken;
    MockTIP20 internal immutable quoteToken;

    constructor(DirectPropAMM pool_, MockTIP20 baseToken_, MockTIP20 quoteToken_) {
        pool = pool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        baseToken_.approve(address(pool_), type(uint256).max);
        quoteToken_.approve(address(pool_), type(uint256).max);
    }

    function swap(bool exactOutput, bool baseToQuote, uint256 amount, uint256 limit, bytes32 customerId, uint256 price)
        external
    {
        if (exactOutput) {
            pool.swapExactOutput(
                baseToQuote, amount, limit, address(this), customerId, bytes32(amount), block.timestamp, price, 0, 0
            );
        } else {
            pool.swapExactInput(
                baseToQuote, amount, limit, address(this), customerId, bytes32(amount), block.timestamp, price, 0, 0
            );
        }
    }

    function balanceValue(uint256 price, uint256 scale) external view returns (uint256) {
        return baseToken.balanceOf(address(this)) * price + quoteToken.balanceOf(address(this)) * scale;
    }
}

contract DirectPropAMMExtendedHandler {
    uint256 internal constant MAX_TRADE = 1e8;

    DirectPropAMM public immutable pool;
    MockTIP20 public immutable baseToken;
    MockTIP20 public immutable quoteToken;
    MockOracle public immutable firstOracle;
    MockOracle public immutable secondOracle;
    DirectPropAMMRouteActor public immutable firstActor;
    DirectPropAMMRouteActor public immutable secondActor;

    bool public invariantBroken;
    uint256 public successfulSwaps;
    uint256 public rejectedSwaps;

    constructor(DirectPropAMM pool_, MockTIP20 baseToken_, MockTIP20 quoteToken_, MockOracle oracle_) {
        pool = pool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        firstOracle = oracle_;
        secondOracle = new MockOracle(8, oracle_.price(), block.timestamp);
        firstActor = new DirectPropAMMRouteActor(pool_, baseToken_, quoteToken_);
        secondActor = new DirectPropAMMRouteActor(pool_, baseToken_, quoteToken_);
    }

    function acceptOwnership() external {
        pool.acceptOwnership();
    }

    function unpause() external {
        pool.unpause();
    }

    function customerId(uint256 index) public pure returns (bytes32) {
        return index % 2 == 0 ? keccak256("customer-A") : keccak256("customer-B");
    }

    function routeKey(uint256 index) public view returns (bytes32) {
        address actor = index / 2 == 0 ? address(firstActor) : address(secondActor);
        return pool.roundingRouteKey(actor, actor, customerId(index));
    }

    function advanceTime(uint256 seed) external {
        // Cross both sides of the current freshness boundary without huge or overflowing timestamps.
        vmWarp(1 + seed % (2 * uint256(pool.maxOracleAge()) + 2));
    }

    function observe(uint256 priceSeed, uint256 timestampSeed, bool replacement) external {
        MockOracle selected = replacement ? secondOracle : firstOracle;
        uint256 anchor = pool.priceAnchor(priceSeed % 2 == 0);
        uint256 price;
        if (priceSeed % 9 == 0) {
            price = 0;
        } else if (priceSeed % 9 == 1) {
            price = anchor * 3;
        } else {
            price = 50_000_000 + priceSeed % 120_000_000;
        }
        uint256 timestamp = timestampSeed % 7 == 0
            ? 0
            : timestampSeed % 7 == 1
                ? block.timestamp + 1
                : timestampSeed % 7 == 2 && block.timestamp > pool.maxOracleAge()
                    ? block.timestamp - uint256(pool.maxOracleAge()) - 1
                    : block.timestamp;
        selected.setPrice(price, timestamp);
    }

    function changeRisk(uint256 seed, bool replacement, bool resetBase, bool resetQuote) external {
        pool.pause();
        pool.setMaxOracleAge(1 + seed % 100_000);
        pool.setMaxPriceDeviationBps(seed % 10_001);
        if (replacement) pool.setOracle(pool.oracle() == firstOracle ? secondOracle : firstOracle);
        if (resetBase) {
            try pool.resetPriceAnchor(true) { } catch { }
        }
        if (resetQuote) {
            try pool.resetPriceAnchor(false) { } catch { }
        }
        try pool.unpause() { } catch { }
    }

    function recover(uint256 seed, bool replacement) external {
        pool.pause();
        if (replacement) pool.setOracle(pool.oracle() == firstOracle ? secondOracle : firstOracle);
        pool.setMaxPriceDeviationBps(pool.BPS());
        MockOracle(address(pool.oracle())).setPrice(90_000_000 + seed % 30_000_001, block.timestamp);
        pool.resetPriceAnchor(true);
        pool.resetPriceAnchor(false);
        pool.unpause();
    }

    function trade(uint256 actorSeed, uint256 amountSeed, bool exactOutput, bool baseToQuote) external {
        uint256 route = actorSeed % 4;
        DirectPropAMMRouteActor actor = route / 2 == 0 ? firstActor : secondActor;
        MockTIP20 tokenIn = baseToQuote ? baseToken : quoteToken;
        MockTIP20 tokenOut = baseToQuote ? quoteToken : baseToken;
        uint256 maxAmount = exactOutput ? tokenOut.balanceOf(address(pool)) : tokenIn.balanceOf(address(actor));
        if (maxAmount > MAX_TRADE) maxAmount = MAX_TRADE;
        if (maxAmount == 0) return;
        uint256 amount = 1 + amountSeed % maxAmount;
        uint256 price = MockOracle(address(pool.oracle())).price();
        uint256 limit = exactOutput ? tokenIn.balanceOf(address(actor)) : 0;
        uint256 quoted;
        bool hasQuote;
        if (exactOutput) {
            try pool.quoteExactOutputFor(
                address(actor), address(actor), customerId(route), baseToQuote, amount
            ) returns (
                uint256 required, uint256, uint256, uint256
            ) {
                quoted = required;
                hasQuote = required <= limit;
            } catch { }
        } else {
            try pool.quoteExactInputFor(
                address(actor), address(actor), customerId(route), baseToQuote, amount
            ) returns (
                uint256 output, uint256, uint256, uint256
            ) {
                quoted = output;
                hasQuote = output > 0 && output <= tokenOut.balanceOf(address(pool));
            } catch { }
        }
        if (hasQuote) limit = quoted;

        uint256[4] memory creditsBefore;
        for (uint256 i; i < 4; ++i) {
            creditsBefore[i] = pool.roundingCredit(routeKey(i));
        }
        uint256 actorValueBefore = actor.balanceValue(price, pool.priceScale());
        uint256 basePoolBefore = baseToken.balanceOf(address(pool));
        uint256 quotePoolBefore = quoteToken.balanceOf(address(pool));
        uint256 baseAnchorBefore = pool.priceAnchor(true);
        uint256 quoteAnchorBefore = pool.priceAnchor(false);

        try actor.swap(exactOutput, baseToQuote, amount, limit, customerId(route), price) {
            if (!hasQuote) invariantBroken = true;
            if (
                actor.balanceValue(price, pool.priceScale()) + pool.roundingCredit(routeKey(route))
                    != actorValueBefore + creditsBefore[route]
            ) invariantBroken = true;
            for (uint256 i; i < 4; ++i) {
                if (i != route && pool.roundingCredit(routeKey(i)) != creditsBefore[i]) invariantBroken = true;
            }
            ++successfulSwaps;
        } catch {
            if (hasQuote && !pool.paused()) invariantBroken = true;
            if (
                actor.balanceValue(price, pool.priceScale()) != actorValueBefore
                    || baseToken.balanceOf(address(pool)) != basePoolBefore
                    || quoteToken.balanceOf(address(pool)) != quotePoolBefore
                    || pool.priceAnchor(true) != baseAnchorBefore || pool.priceAnchor(false) != quoteAnchorBefore
            ) {
                invariantBroken = true;
            }
            for (uint256 i; i < 4; ++i) {
                if (pool.roundingCredit(routeKey(i)) != creditsBefore[i]) invariantBroken = true;
            }
            ++rejectedSwaps;
        }
    }

    function vmWarp(uint256 delta) internal {
        // Forge exposes the cheatcode at its well-known address to handler contracts too.
        (bool success,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("warp(uint256)", block.timestamp + delta));
        require(success);
    }
}

contract DirectPropAMMExtendedInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_BALANCE = 1e15;

    DirectPropAMM internal pool;
    MockTIP20 internal baseToken;
    MockTIP20 internal quoteToken;
    DirectPropAMMExtendedHandler internal handler;

    function setUp() external {
        vm.warp(1_000_000);
        MockAddressRegistry registry = new MockAddressRegistry();
        baseToken = new MockTIP20("BASE", 6);
        quoteToken = new MockTIP20("QUOTE", 6);
        MockOracle oracle = new MockOracle(8, 105_000_000, block.timestamp);
        baseToken.setResolver(registry);
        quoteToken.setResolver(registry);
        pool = new DirectPropAMM(baseToken, quoteToken, oracle, registry, address(this), address(this), 90_000, 10_000);
        handler = new DirectPropAMMExtendedHandler(pool, baseToken, quoteToken, oracle);
        pool.setTakerAllowed(address(handler.firstActor()), true);
        pool.setTakerAllowed(address(handler.secondActor()), true);
        pool.setRecipientAllowed(address(handler.firstActor()), true);
        pool.setRecipientAllowed(address(handler.secondActor()), true);
        baseToken.mint(address(pool), INITIAL_BALANCE);
        quoteToken.mint(address(pool), INITIAL_BALANCE);
        baseToken.mint(address(handler.firstActor()), INITIAL_BALANCE);
        quoteToken.mint(address(handler.firstActor()), INITIAL_BALANCE);
        baseToken.mint(address(handler.secondActor()), INITIAL_BALANCE);
        quoteToken.mint(address(handler.secondActor()), INITIAL_BALANCE);
        pool.transferOwnership(address(handler));
        handler.acceptOwnership();
        handler.unpause();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.advanceTime.selector;
        selectors[1] = handler.observe.selector;
        selectors[2] = handler.changeRisk.selector;
        selectors[3] = handler.recover.selector;
        selectors[4] = handler.trade.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    function test_staleObservationRejectsSwapThenFreshObservationAllowsIt() external {
        handler.observe(2, 2, false);
        uint256 baseBefore = baseToken.balanceOf(address(handler.firstActor()));
        uint256 quoteBefore = quoteToken.balanceOf(address(handler.firstActor()));
        handler.trade(0, 1_000_000, false, true);
        assertEq(handler.rejectedSwaps(), 1);
        assertEq(baseToken.balanceOf(address(handler.firstActor())), baseBefore);
        assertEq(quoteToken.balanceOf(address(handler.firstActor())), quoteBefore);

        handler.observe(55_000_001, 3, false);
        handler.trade(0, 1_000_000, false, true);
        assertEq(handler.successfulSwaps(), 1);
        assertFalse(handler.invariantBroken());
    }

    function test_distinctRoutesKeepTheirCreditAcrossOracleReplacement() external {
        handler.trade(0, 0, false, true);
        uint256 firstCredit = pool.roundingCredit(handler.routeKey(0));
        assertGt(firstCredit, 0);
        assertEq(pool.roundingCredit(handler.routeKey(1)), 0);

        handler.recover(15_000_000, true);
        handler.trade(1, 0, false, true);
        assertEq(pool.roundingCredit(handler.routeKey(0)), firstCredit);
        assertGt(pool.roundingCredit(handler.routeKey(1)), 0);
        assertFalse(handler.invariantBroken());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_routeIsolationAndFailedSwapRollback() external view {
        assertFalse(handler.invariantBroken());
        assertEq(
            baseToken.balanceOf(address(pool)) + baseToken.balanceOf(address(handler.firstActor()))
                + baseToken.balanceOf(address(handler.secondActor())),
            3 * INITIAL_BALANCE
        );
        assertEq(
            quoteToken.balanceOf(address(pool)) + quoteToken.balanceOf(address(handler.firstActor()))
                + quoteToken.balanceOf(address(handler.secondActor())),
            3 * INITIAL_BALANCE
        );
    }
}
