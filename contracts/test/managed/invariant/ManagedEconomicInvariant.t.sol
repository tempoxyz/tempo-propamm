// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "../utils/TestFeeHook.sol";
using TestFeeHookLib for ManagedDirectPropAMM;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";
import { IManagedDirectPropAMM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";

/// @notice Fuzzes custody, directional fees and swaps against an independent bounded value ledger.
contract ManagedEconomicHandler is Test {
    uint256 internal constant PRICE = 105_000_000;
    // Both tokens have 6 decimals and the fixed oracle has 8. Amounts are bounded, so these
    // products fit uint256 without production's mulDiv/quotient-and-remainder implementation.
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BPS = 10_000;
    bytes32 internal constant CUSTOMER = bytes32("economic-route");

    struct Fill {
        uint256 gross;
        uint256 output;
        uint256 fee;
        uint256 credit;
    }

    struct State {
        uint256 poolBase;
        uint256 poolQuote;
        uint256 takerBase;
        uint256 takerQuote;
        uint256 credit;
        uint256 sellAnchor;
        uint256 buyAnchor;
    }

    ManagedDirectPropAMM public immutable pool;
    TestFeeHook public immutable hook;
    MockTIP20 public immutable base;
    MockTIP20 public immutable quote;

    // Ghost inputs: never seed the model from the pool's quotes, fee getters or credit getters.
    uint16 public sellFeeBps;
    uint16 public buyFeeBps;
    uint256 public ghostCredit;
    uint256 public baseFees;
    uint256 public quoteFees;
    uint256 public successfulSwaps;
    uint256[4] public swapsByOrder;
    uint256 public feeBearingSwaps;
    uint256 public zeroFeeSwaps;
    uint256 public maxFeeSwaps;
    uint256 public creditOnlySwaps;
    uint256 public insufficientInventory;
    uint256 public zeroOutput;
    uint256 public slippageFailures;
    uint256 public custodyChanges;
    uint256 public feeChanges;
    bytes4 public unexpectedReason;
    bool public accountingBroken;

    constructor(ManagedDirectPropAMM pool_, MockTIP20 base_, MockTIP20 quote_) {
        pool = pool_;
        (address installed,) = pool_.pairHook(0);
        hook = TestFeeHook(installed);
        base = base_;
        quote = quote_;
        base_.approve(address(pool_), type(uint256).max);
        quote_.approve(address(pool_), type(uint256).max);
    }

    /// @notice Change each direction independently, retaining prepaid route value across rate changes.
    function changeFees(uint16 sell, uint16 buy) external {
        State memory beforeState = _state();
        sellFeeBps = sell % 1_001;
        buyFeeBps = buy % 1_001;
        hook.setFees(0, address(this), sellFeeBps, buyFeeBps);
        if (keccak256(abi.encode(_state())) != keccak256(abi.encode(beforeState))) accountingBroken = true;
        ++feeChanges;
    }

    /// @notice Funds or removes inventory while the pool is active; a withdrawal may empty either side.
    function changeInventory(bool baseToken, bool deposit, uint256 seed) external {
        MockTIP20 token = baseToken ? base : quote;
        uint256 balance = token.balanceOf(deposit ? address(this) : address(pool));
        if (balance == 0) return;
        uint256 amount = 1 + seed % balance;
        uint256 beforePool = token.balanceOf(address(pool));
        uint256 beforeOwner = token.balanceOf(address(this));
        if (deposit) pool.fund(address(token), amount, bytes32(seed));
        else pool.withdraw(address(token), address(this), amount, bytes32(seed));
        if (
            token.balanceOf(address(pool)) != (deposit ? beforePool + amount : beforePool - amount)
                || token.balanceOf(address(this)) != (deposit ? beforeOwner - amount : beforeOwner + amount)
                || _credit() != ghostCredit
        ) accountingBroken = true;
        ++custodyChanges;
    }

    /// @notice Both directions and order types, including outputs above available inventory.
    function swap(bool baseToQuote, bool exactInput, uint256 seed) external {
        _swap(baseToQuote, exactInput, seed, false);
    }

    /// @notice An independently calculated limit one unit too tight must revert without committing any state.
    function swapWithBadLimit(bool baseToQuote, bool exactInput, uint256 seed) external {
        _swap(baseToQuote, exactInput, seed, true);
    }

    function _swap(bool baseToQuote, bool exactInput, uint256 seed, bool badLimit) private {
        State memory beforeState = _state();
        uint256 inputTaker = baseToQuote ? beforeState.takerBase : beforeState.takerQuote;
        uint256 outputPool = baseToQuote ? beforeState.poolQuote : beforeState.poolBase;
        // Keep exact outputs affordable even with the maximum fee; still permit credit-only fills
        // with an empty wallet. The independent gross check below handles very small balances.
        uint256 affordable = exactInput ? inputTaker : inputTaker / 2;
        if (exactInput && affordable == 0) return;
        if (!exactInput && affordable == 0) affordable = 1;
        uint256 amount = 1 + seed % 1_000_000_000;
        if (amount > affordable) amount = affordable;
        uint16 rate = baseToQuote ? sellFeeBps : buyFeeBps;
        Fill memory expected = _model(baseToQuote, exactInput, amount, rate);
        if (expected.gross > inputTaker) return;
        // Zero is already the strictest exact-output limit; it cannot be tightened.
        if (badLimit && !exactInput && expected.gross == 0) return;
        uint256 limit = exactInput ? expected.output + (badLimit ? 1 : 0) : expected.gross - (badLimit ? 1 : 0);

        // Predict the exact revert (including its arguments), not just an allowlist of possible errors.
        bytes memory expectedRevert;
        if (exactInput && expected.output == 0) {
            expectedRevert = abi.encodeWithSelector(IManagedDirectPropAMM.AmountIsZero.selector);
        } else if (badLimit) {
            expectedRevert = abi.encodeWithSelector(
                IManagedDirectPropAMM.SlippageExceeded.selector, limit, exactInput ? expected.output : expected.gross
            );
        } else if (expected.output > outputPool) {
            expectedRevert = abi.encodeWithSelector(
                IManagedDirectPropAMM.InsufficientInventory.selector,
                baseToQuote ? address(quote) : address(base),
                outputPool,
                expected.output
            );
        }

        bytes memory callData = exactInput
            ? abi.encodeCall(
                ManagedDirectPropAMM.swapExactInput,
                (0, baseToQuote, amount, limit, 0, CUSTOMER, bytes32(seed), block.timestamp, PRICE, 0, block.timestamp)
            )
            : abi.encodeCall(
                ManagedDirectPropAMM.swapExactOutput,
                (0, baseToQuote, amount, limit, 0, CUSTOMER, bytes32(seed), block.timestamp, PRICE, 0, block.timestamp)
            );
        (bool ok, bytes memory result) = address(pool).call(callData);
        if (ok != (expectedRevert.length == 0) || (!ok && keccak256(result) != keccak256(expectedRevert))) {
            accountingBroken = true;
            unexpectedReason = bytes4(result);
            return;
        }
        if (!ok) {
            if (keccak256(abi.encode(_state())) != keccak256(abi.encode(beforeState))) accountingBroken = true;
            if (bytes4(result) == IManagedDirectPropAMM.InsufficientInventory.selector) ++insufficientInventory;
            else if (bytes4(result) == IManagedDirectPropAMM.AmountIsZero.selector) ++zeroOutput;
            else ++slippageFailures;
            return;
        }

        if (abi.decode(result, (uint256)) != (exactInput ? expected.output : expected.gross)) accountingBroken = true;
        State memory afterState = _state();
        if (
            afterState.poolBase
                    != beforeState.poolBase + (baseToQuote ? expected.gross : 0) - (baseToQuote ? 0 : expected.output)
                || afterState.poolQuote
                    != beforeState.poolQuote + (baseToQuote ? 0 : expected.gross) - (baseToQuote ? expected.output : 0)
                || afterState.takerBase
                    != beforeState.takerBase + (baseToQuote ? 0 : expected.output) - (baseToQuote ? expected.gross : 0)
                || afterState.takerQuote
                    != beforeState.takerQuote + (baseToQuote ? expected.output : 0) - (baseToQuote ? 0 : expected.gross)
                || afterState.credit != expected.credit || afterState.sellAnchor != PRICE
                || afterState.buyAnchor != PRICE
                || _value(afterState) + expected.fee * (baseToQuote ? PRICE : PRICE_SCALE) != _value(beforeState)
        ) accountingBroken = true;
        ghostCredit = expected.credit;
        if (baseToQuote) baseFees += expected.fee;
        else quoteFees += expected.fee;
        ++successfulSwaps;
        ++swapsByOrder[(baseToQuote ? 0 : 2) + (exactInput ? 0 : 1)];
        if (expected.fee != 0) ++feeBearingSwaps;
        if (rate == 0) ++zeroFeeSwaps;
        if (rate == 1_000) ++maxFeeSwaps;
        if (!exactInput && expected.gross == 0) ++creditOnlySwaps;
    }

    function _model(bool direction, bool exactInput, uint256 amount, uint16 rate) private view returns (Fill memory f) {
        uint256 inputValue = direction ? PRICE : PRICE_SCALE;
        uint256 outputValue = direction ? PRICE_SCALE : PRICE;
        if (exactInput) {
            f.gross = amount;
            // floor(gross * retainedBps / BPS) independently gives the post-fee input.
            uint256 net = amount * (BPS - rate) / BPS;
            f.fee = amount - net;
            uint256 value = net * inputValue + ghostCredit;
            f.output = value / outputValue;
            f.credit = value % outputValue;
        } else {
            f.output = amount;
            uint256 requiredValue = amount * outputValue;
            uint256 net = requiredValue > ghostCredit ? _ceil(requiredValue - ghostCredit, inputValue) : 0;
            f.gross = _ceil(net * BPS, BPS - rate);
            f.fee = f.gross - net;
            f.credit = ghostCredit + net * inputValue - requiredValue;
        }
    }

    function _ceil(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator / denominator + (numerator % denominator == 0 ? 0 : 1);
    }

    function _value(State memory s) private pure returns (uint256) {
        return s.takerBase * PRICE + s.takerQuote * PRICE_SCALE + s.credit;
    }

    function _state() private view returns (State memory s) {
        s = State(
            base.balanceOf(address(pool)),
            quote.balanceOf(address(pool)),
            base.balanceOf(address(this)),
            quote.balanceOf(address(this)),
            _credit(),
            pool.priceAnchor(0, true),
            pool.priceAnchor(0, false)
        );
    }

    function _credit() internal view returns (uint256) {
        return pool.roundingCredit(keccak256(abi.encode(uint16(0), address(this), CUSTOMER)));
    }
}

contract ManagedEconomicInvariantTest is StdInvariant, Test {
    uint256 internal constant PRICE = 105_000_000;

    ManagedEconomicHandler internal handler;
    MockTIP20 internal base;
    MockTIP20 internal quote;
    ManagedDirectPropAMM internal pool;

    function setUp() external {
        vm.warp(1_000_000);
        base = new MockTIP20("PRIME", 6);
        quote = new MockTIP20("pathUSD", 6);
        pool = new ManagedDirectPropAMM(address(this), address(0));
        pool.addPair(address(base), address(quote), new MockOracle(8, PRICE, block.timestamp), 90_000, 50);
        pool.setPairHook(0, address(new TestFeeHook(pool)), 1);
        handler = new ManagedEconomicHandler(pool, base, quote);
        address[] memory home = new address[](1);
        home[0] = address(handler);
        pool.setMembers(0, 0, home, true);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        pool.unpause();
        // Transfer ownership so the handler can fund or withdraw without granting powers to fuzzed callers.
        pool.transferOwnership(address(handler));
        vm.prank(address(handler));
        pool.acceptOwnership();
        base.mint(address(handler), 1_000_000_000_000);
        quote.mint(address(handler), 1_000_000_000_000);
        base.mint(address(pool), 1_000_000);
        quote.mint(address(pool), 1_000_000);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.changeInventory.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.changeFees.selector;
        selectors[3] = handler.swapWithBadLimit.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_swapsAndCustodyConserveExactBalancesAndRouteValue() external view {
        assertEq(handler.unexpectedReason(), bytes4(0), "unexpected swap revert");
        assertFalse(handler.accountingBroken(), "accounting or route conservation failed");
        assertEq(
            pool.roundingCredit(keccak256(abi.encode(uint16(0), address(handler), bytes32("economic-route")))),
            handler.ghostCredit(),
            "route credit follows the independent ledger"
        );
        assertLt(handler.ghostCredit(), PRICE, "credit stays below the larger token unit");
        (uint16 sell, uint16 buy) = pool.testFees(0, address(handler));
        assertEq(sell, handler.sellFeeBps());
        assertEq(buy, handler.buyFeeBps());
        assertEq(base.balanceOf(address(pool)) + base.balanceOf(address(handler)), 1_000_001_000_000);
        assertEq(quote.balanceOf(address(pool)) + quote.balanceOf(address(handler)), 1_000_001_000_000);
    }

    function test_inventoryShortfallAndRefill() external {
        handler.changeInventory(false, false, 999_999);
        assertEq(quote.balanceOf(address(pool)), 0);
        handler.swap(true, false, 0);
        assertEq(handler.insufficientInventory(), 1);
        handler.changeInventory(false, true, 0);
        handler.swap(true, false, 0);
        assertEq(handler.successfulSwaps(), 1);
        this.invariant_swapsAndCustodyConserveExactBalancesAndRouteValue();
    }

    function test_allOrderTypesKeepExactRouteValue() external {
        handler.swap(true, true, 99_999);
        handler.swap(false, true, 99_999);
        handler.swap(true, false, 99_999);
        handler.swap(false, false, 99_999);
        assertEq(handler.successfulSwaps(), 4);
        assertEq(handler.zeroFeeSwaps(), 4);
        assertEq(handler.feeBearingSwaps(), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(handler.swapsByOrder(i), 1);
        }
        this.invariant_swapsAndCustodyConserveExactBalancesAndRouteValue();
    }

    function test_zeroNonzeroMaximumAndAsymmetricFeesReachEveryOrderType() external {
        uint16[5] memory sells = [uint16(0), 1, 1_000, 17, 0];
        uint16[5] memory buys = [uint16(0), 1, 1_000, 901, 1_000];
        // Non-round amounts force fractional fees; round multiples could hide ceil-to-floor regressions.
        for (uint256 i; i < sells.length; ++i) {
            handler.changeFees(sells[i], buys[i]);
            handler.swap(true, true, 100_002);
            handler.swap(false, true, 100_002);
            handler.swap(true, false, 100_002);
            handler.swap(false, false, 100_002);
            assertEq(handler.successfulSwaps(), (i + 1) * 4, "each schedule must actually settle");
            this.invariant_swapsAndCustodyConserveExactBalancesAndRouteValue();
        }
        for (uint256 i; i < 4; ++i) {
            assertEq(handler.swapsByOrder(i), 5);
        }
        assertEq(handler.feeChanges(), 5);
        assertEq(handler.feeBearingSwaps(), 14);
        assertEq(handler.zeroFeeSwaps(), 6);
        assertEq(handler.maxFeeSwaps(), 6);
        assertGt(handler.baseFees(), 0);
        assertGt(handler.quoteFees(), 0);
    }

    function test_creditSurvivesFeeChangesAndPaysZeroInputWithoutAnotherFee() external {
        handler.changeFees(1, 901);
        uint256 baseBefore = base.balanceOf(address(handler));
        uint256 quoteBefore = quote.balanceOf(address(handler));
        // Twenty net base units buy 21 quote units; the first twenty outputs leave one in credit.
        for (uint256 i; i < 20; ++i) {
            handler.swap(true, false, 0);
        }
        assertEq(handler.successfulSwaps(), 20);
        assertEq(handler.ghostCredit(), 100_000_000);
        assertEq(handler.baseFees(), 20);
        handler.changeFees(1_000, 0);
        assertEq(handler.ghostCredit(), 100_000_000);
        // Even an empty input wallet must not suppress the zero-input path.
        handler.changeInventory(true, true, base.balanceOf(address(handler)) - 1);
        assertEq(base.balanceOf(address(handler)), 0);
        handler.swap(true, false, 0);
        assertEq(handler.successfulSwaps(), 21);
        assertEq(handler.creditOnlySwaps(), 1);
        assertEq(handler.feeBearingSwaps(), 20);
        assertEq(handler.baseFees(), 20);
        assertEq(handler.ghostCredit(), 0);
        assertEq(base.balanceOf(address(pool)), 1_000_000 + baseBefore);
        assertEq(quote.balanceOf(address(handler)), quoteBefore + 21);
        this.invariant_swapsAndCustodyConserveExactBalancesAndRouteValue();
    }

    function test_feeFailuresRollBackBalancesCreditsAndAnchorsBeforeRecovery() external {
        handler.changeFees(1_000, 17);
        handler.swap(true, false, 0);
        assertEq(handler.successfulSwaps(), 1);
        assertEq(handler.ghostCredit(), 5_000_000);
        handler.swap(true, true, 0); // The entire one-unit input is the rounded fee.
        assertEq(handler.zeroOutput(), 1);
        handler.swapWithBadLimit(true, true, 999);
        handler.swapWithBadLimit(false, true, 999);
        handler.swapWithBadLimit(true, false, 999);
        handler.swapWithBadLimit(false, false, 999);
        assertEq(handler.slippageFailures(), 4);
        handler.changeInventory(false, false, quote.balanceOf(address(pool)) - 1);
        handler.swap(true, true, 100);
        handler.swap(true, false, 0);
        assertEq(handler.insufficientInventory(), 2);
        assertEq(handler.successfulSwaps(), 1);
        assertEq(handler.baseFees(), 1);
        assertEq(handler.ghostCredit(), 5_000_000, "failed fills cannot consume or create credit");
        this.invariant_swapsAndCustodyConserveExactBalancesAndRouteValue();
        handler.changeInventory(false, true, 0);
        handler.swap(true, false, 0);
        assertEq(handler.successfulSwaps(), 2);
        assertEq(handler.ghostCredit(), 10_000_000);
        assertEq(handler.baseFees(), 2);
        this.invariant_swapsAndCustodyConserveExactBalancesAndRouteValue();
    }
}
