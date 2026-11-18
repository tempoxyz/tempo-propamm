// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { MockAddressRegistry } from "../mocks/MockAddressRegistry.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";

contract DirectPropAMMHandler {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant MIN_PRICE = 1e4;
    uint256 internal constant MAX_PRICE = 1e12;
    uint256 internal constant MAX_INPUT = 1e9;
    uint256 internal constant MAX_OUTPUT = 1e9;
    bytes32 public constant CUSTOMER_ID = keccak256("stateful-rounding-audit");
    bytes32 public constant OTHER_CUSTOMER_ID = keccak256("stateful-rounding-audit-other");

    DirectPropAMM public immutable pool;
    MockTIP20 public immutable baseToken;
    MockTIP20 public immutable quoteToken;
    MockOracle public immutable oracle;

    bool public conservationBroken;
    bool public routeIsolationBroken;
    bool public rejectedSwapChangedState;
    uint256 public successfulSwaps;
    uint256 public maximumObservedPrice;

    constructor(DirectPropAMM pool_, MockTIP20 baseToken_, MockTIP20 quoteToken_, MockOracle oracle_) {
        pool = pool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        oracle = oracle_;
        maximumObservedPrice = oracle_.price();

        baseToken_.approve(address(pool_), type(uint256).max);
        quoteToken_.approve(address(pool_), type(uint256).max);
    }

    function setPrice(uint256 seed) external {
        (uint256 trueMinimum, uint256 trueMaximum) = _priceBounds(pool.priceAnchor(true));
        (uint256 falseMinimum, uint256 falseMaximum) = _priceBounds(pool.priceAnchor(false));
        uint256 minimum = trueMinimum > falseMinimum ? trueMinimum : falseMinimum;
        uint256 maximum = trueMaximum < falseMaximum ? trueMaximum : falseMaximum;
        if (minimum < MIN_PRICE) minimum = MIN_PRICE;
        if (maximum > MAX_PRICE) maximum = MAX_PRICE;

        uint256 newPrice = _bound(seed, minimum, maximum);
        oracle.setPrice(newPrice, block.timestamp);
        if (newPrice > maximumObservedPrice) maximumObservedPrice = newPrice;
    }

    function swapExactInput(bool baseToQuote, uint256 seed) external {
        bytes32 customerId = _customerId(seed);
        bytes32 otherRoute = routeKey(customerId == CUSTOMER_ID ? OTHER_CUSTOMER_ID : CUSTOMER_ID);
        uint256 otherCredit = pool.roundingCredit(otherRoute);
        MockTIP20 tokenIn = baseToQuote ? baseToken : quoteToken;
        MockTIP20 tokenOut = baseToQuote ? quoteToken : baseToken;
        uint256 maximum = _min(tokenIn.balanceOf(address(this)), MAX_INPUT);
        if (maximum == 0) return;

        uint256 amountIn = _bound(seed, 1, maximum);
        (uint256 amountOut,,, uint256 creditAfter) =
            pool.quoteExactInputFor(address(this), address(this), customerId, baseToQuote, amountIn);
        if (amountOut == 0 || amountOut > tokenOut.balanceOf(address(pool))) return;

        uint256 price = oracle.price();
        uint256 valueBefore = _routeValue(price);
        pool.swapExactInput(
            baseToQuote,
            amountIn,
            amountOut,
            address(this),
            customerId,
            bytes32(seed),
            block.timestamp,
            price,
            0,
            oracle.updatedAt()
        );
        _recordResult(price, valueBefore);
        if (pool.roundingCredit(routeKey(customerId)) != creditAfter || pool.roundingCredit(otherRoute) != otherCredit)
        {
            routeIsolationBroken = true;
        }
    }

    function swapExactOutput(bool baseToQuote, uint256 seed) external {
        bytes32 customerId = _customerId(seed);
        bytes32 otherRoute = routeKey(customerId == CUSTOMER_ID ? OTHER_CUSTOMER_ID : CUSTOMER_ID);
        uint256 otherCredit = pool.roundingCredit(otherRoute);
        MockTIP20 tokenIn = baseToQuote ? baseToken : quoteToken;
        MockTIP20 tokenOut = baseToQuote ? quoteToken : baseToken;
        uint256 maximum = _min(tokenOut.balanceOf(address(pool)), MAX_OUTPUT);
        if (maximum == 0) return;

        uint256 amountOut = _bound(seed, 1, maximum);
        (uint256 amountIn,,, uint256 creditAfter) =
            pool.quoteExactOutputFor(address(this), address(this), customerId, baseToQuote, amountOut);
        if (amountIn > tokenIn.balanceOf(address(this))) return;

        uint256 price = oracle.price();
        uint256 valueBefore = _routeValue(price);
        pool.swapExactOutput(
            baseToQuote,
            amountOut,
            amountIn,
            address(this),
            customerId,
            bytes32(seed),
            block.timestamp,
            price,
            0,
            oracle.updatedAt()
        );
        _recordResult(price, valueBefore);
        if (pool.roundingCredit(routeKey(customerId)) != creditAfter || pool.roundingCredit(otherRoute) != otherCredit)
        {
            routeIsolationBroken = true;
        }
    }

    /// @notice Every invalid observation or stale quote must reject a swap without changing inventory, credit or anchors.
    function rejectBadObservation(bool baseToQuote, uint256 seed) external {
        uint256 price = oracle.price();
        uint256 updatedAt = oracle.updatedAt();
        bytes32 stateBefore = _stateFingerprint();
        uint256 expectedPrice = price;
        uint256 minimumUpdatedAt = updatedAt;
        uint256 deadline = block.timestamp;
        bytes4 expectedError;
        uint256 kind = seed % 7;
        if (kind == 0) {
            oracle.setPrice(0, block.timestamp);
            expectedError = DirectPropAMM.InvalidPrice.selector;
        } else if (kind == 1) {
            oracle.setPrice(price, block.timestamp + 1);
            expectedError = DirectPropAMM.FutureOracleTimestamp.selector;
        } else if (kind == 2) {
            oracle.setPrice(price, block.timestamp - pool.maxOracleAge() - 1);
            expectedError = DirectPropAMM.StaleOraclePrice.selector;
        } else if (kind == 3) {
            oracle.setPrice(pool.priceAnchor(baseToQuote) * 3, block.timestamp);
            expectedError = DirectPropAMM.PriceDeviationExceeded.selector;
        } else if (kind == 4) {
            expectedPrice = price + 1;
            expectedError = DirectPropAMM.OraclePriceToleranceExceeded.selector;
        } else if (kind == 5) {
            minimumUpdatedAt = updatedAt + 1;
            expectedError = DirectPropAMM.OracleTimestampTooOld.selector;
        } else {
            deadline = block.timestamp - 1;
            expectedError = DirectPropAMM.DeadlineExpired.selector;
        }

        (bool ok, bytes memory result) = address(pool)
            .call(
                abi.encodeCall(
                    DirectPropAMM.swapExactInput,
                    (
                        baseToQuote,
                        1e6,
                        0,
                        address(this),
                        CUSTOMER_ID,
                        bytes32(seed),
                        deadline,
                        expectedPrice,
                        0,
                        minimumUpdatedAt
                    )
                )
            );
        if (ok || bytes4(result) != expectedError || _stateFingerprint() != stateBefore) {
            rejectedSwapChangedState = true;
        }
        oracle.setPrice(price, updatedAt);
    }

    function routeKey(bytes32 customerId) public view returns (bytes32) {
        return pool.roundingRouteKey(address(this), address(this), customerId);
    }

    function _recordResult(uint256 price, uint256 valueBefore) internal {
        if (_routeValue(price) != valueBefore) conservationBroken = true;
        ++successfulSwaps;
    }

    function _priceBounds(uint256 anchor) internal view returns (uint256 minimum, uint256 maximum) {
        uint256 maximumDeviation = anchor * pool.maxPriceDeviationBps() / pool.BPS();
        minimum = anchor > maximumDeviation ? anchor - maximumDeviation : 0;
        maximum = anchor + maximumDeviation;
    }

    function _routeValue(uint256 price) internal view returns (uint256) {
        return baseToken.balanceOf(address(this)) * price + quoteToken.balanceOf(address(this)) * PRICE_SCALE
            + pool.roundingCredit(routeKey(CUSTOMER_ID)) + pool.roundingCredit(routeKey(OTHER_CUSTOMER_ID));
    }

    function _stateFingerprint() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                baseToken.balanceOf(address(pool)),
                quoteToken.balanceOf(address(pool)),
                baseToken.balanceOf(address(this)),
                quoteToken.balanceOf(address(this)),
                pool.roundingCredit(routeKey(CUSTOMER_ID)),
                pool.roundingCredit(routeKey(OTHER_CUSTOMER_ID)),
                pool.priceAnchor(true),
                pool.priceAnchor(false)
            )
        );
    }

    function _customerId(uint256 seed) internal pure returns (bytes32) {
        return uint256(keccak256(abi.encode(seed))) & 1 == 0 ? CUSTOMER_ID : OTHER_CUSTOMER_ID;
    }

    function _bound(uint256 value, uint256 minimum, uint256 maximum) internal pure returns (uint256) {
        return minimum + value % (maximum - minimum + 1);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract DirectPropAMMInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_BALANCE = 1e15;
    uint256 internal constant INITIAL_PRICE = 105_000_000;

    MockTIP20 internal baseToken;
    MockTIP20 internal quoteToken;
    DirectPropAMM internal pool;
    DirectPropAMMHandler internal handler;

    function setUp() external {
        vm.warp(1_000_000);

        MockAddressRegistry registry = new MockAddressRegistry();
        baseToken = new MockTIP20("BASE", 6);
        quoteToken = new MockTIP20("QUOTE", 6);
        MockOracle oracle = new MockOracle(8, INITIAL_PRICE, block.timestamp);
        baseToken.setResolver(registry);
        quoteToken.setResolver(registry);

        pool = new DirectPropAMM(baseToken, quoteToken, oracle, registry, address(this), address(this), 90_000, 10_000);
        handler = new DirectPropAMMHandler(pool, baseToken, quoteToken, oracle);

        pool.setTakerAllowed(address(handler), true);
        pool.setRecipientAllowed(address(handler), true);
        baseToken.mint(address(pool), INITIAL_BALANCE);
        quoteToken.mint(address(pool), INITIAL_BALANCE);
        baseToken.mint(address(handler), INITIAL_BALANCE);
        quoteToken.mint(address(handler), INITIAL_BALANCE);
        pool.unpause();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.setPrice.selector;
        selectors[1] = handler.swapExactInput.selector;
        selectors[2] = handler.swapExactOutput.selector;
        selectors[3] = handler.rejectBadObservation.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// @dev Observe credit writes rather than reproducing the route selector. The old seed-parity selector
    /// cannot reach all four customer/amount-parity combinations in either swap mode.
    function test_routesReceiveOddAndEvenTradeAmounts() external {
        bytes32[2] memory routes =
            [handler.routeKey(handler.CUSTOMER_ID()), handler.routeKey(handler.OTHER_CUSTOMER_ID())];
        for (uint256 mode; mode < 2; ++mode) {
            uint256 seen;
            for (uint256 seed; seed < 32; ++seed) {
                uint256[2] memory before = [pool.roundingCredit(routes[0]), pool.roundingCredit(routes[1])];
                // With the funded fixture, both bounded amount draws are seed + 1.
                if (mode == 0) handler.swapExactInput(true, seed);
                else handler.swapExactOutput(true, seed);
                for (uint256 route; route < 2; ++route) {
                    if (pool.roundingCredit(routes[route]) != before[route]) {
                        seen |= 1 << (2 * route + ((seed + 1) & 1));
                    }
                }
            }
            assertEq(seen, 15, "both customers receive both amount parities");
        }
        assertEq(handler.successfulSwaps(), 64, "every probe settled");
        assertFalse(handler.routeIsolationBroken());
        assertFalse(handler.conservationBroken());
    }

    function invariant_eachSwapConservesRouteValueIncludingCredit() external view {
        assertFalse(handler.conservationBroken());
    }

    function invariant_swapsKeepCreditOnTheirOwnRoute() external view {
        assertFalse(handler.routeIsolationBroken());
    }

    function invariant_rejectedSwapsChangeNoPoolState() external view {
        assertFalse(handler.rejectedSwapChangedState());
    }

    function invariant_tokensOnlyMoveBetweenPoolAndTaker() external view {
        assertEq(baseToken.balanceOf(address(pool)) + baseToken.balanceOf(address(handler)), 2 * INITIAL_BALANCE);
        assertEq(quoteToken.balanceOf(address(pool)) + quoteToken.balanceOf(address(handler)), 2 * INITIAL_BALANCE);
    }

    function invariant_creditRemainsBelowLargestObservedDenominator() external view {
        uint256 bound =
            handler.maximumObservedPrice() > pool.priceScale() ? handler.maximumObservedPrice() : pool.priceScale();
        assertLt(pool.roundingCredit(handler.routeKey(handler.CUSTOMER_ID())), bound);
        assertLt(pool.roundingCredit(handler.routeKey(handler.OTHER_CUSTOMER_ID())), bound);
    }
}
