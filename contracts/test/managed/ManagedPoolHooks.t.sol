// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ManagedPoolFixture } from "./utils/ManagedPoolFixture.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM as IM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IManagedPoolHook, ManagedPoolHookFlags as HF } from "../../src/managed/interfaces/IManagedPoolHook.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { Settler } from "../../src/managed/Settler.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Adversarial, pool-bound hook; cheatcodes in the drain mode simulate an untrusted token changing balances.
contract ExercisedManagedHook is IManagedPoolHook, Test {
    address public immutable pool;
    uint8 public flags = HF.ALL;
    uint16 public fee;
    bool public refuseQuote;
    bool public badAck;
    bool public refuseBefore;
    bool public refuseAfter;
    bool public burnQuoteGas;
    bool public balanceFee;
    uint256 public threshold;
    address public feeToken;
    uint256 public beforeCalls;
    uint256 public afterCalls;
    uint256 public donate;
    bool public drainBefore;
    bool public drainAfter;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    SwapContext private _last;

    constructor(address pool_) {
        pool = pool_;
    }

    function supportedFlags() external view returns (uint8) {
        return flags;
    }

    function configure(uint16 fee_, bool badAck_, bool before_, bool after_) external {
        fee = fee_;
        badAck = badAck_;
        refuseBefore = before_;
        refuseAfter = after_;
    }

    function quoteMode(bool refuse_, bool burn_) external {
        refuseQuote = refuse_;
        burnQuoteGas = burn_;
    }

    function balanceMode(address token, uint256 threshold_) external {
        feeToken = token;
        threshold = threshold_;
        balanceFee = true;
    }

    function movement(uint256 donate_, bool before_, bool after_) external {
        donate = donate_;
        drainBefore = before_;
        drainAfter = after_;
    }

    function reenter(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function last() external view returns (SwapContext memory) {
        return _last;
    }

    function quote(QuoteContext calldata) external view returns (uint16) {
        require(msg.sender == pool, "pool only");
        require(!refuseQuote, "policy rejected");
        if (burnQuoteGas) {
            assembly { for { } 1 { } { } }
        }
        if (balanceFee) return MockTIP20(feeToken).balanceOf(pool) > threshold ? fee : 0;
        return fee;
    }

    function beforeSwap(SwapContext calldata c) external returns (bytes4) {
        require(msg.sender == pool, "pool only");
        require(!refuseBefore, "before rejected");
        beforeCalls++;
        _last = c;
        if (reentryTarget != address(0)) (reentrySucceeded,) = reentryTarget.call(reentryData);
        if (donate != 0) MockTIP20(c.tokenOut).mint(pool, donate);
        if (drainBefore) _drain(c.tokenOut);
        return badAck ? bytes4(0) : IManagedPoolHook.beforeSwap.selector;
    }

    function afterSwap(SwapContext calldata c) external returns (bytes4) {
        require(msg.sender == pool, "pool only");
        require(!refuseAfter, "after rejected");
        afterCalls++;
        _last = c;
        if (drainAfter) _drain(c.tokenIn);
        return badAck ? bytes4(0) : IManagedPoolHook.afterSwap.selector;
    }

    function _drain(address token) private {
        vm.prank(pool);
        MockTIP20(token).transferWithMemo(address(this), 1, bytes32(0));
    }
}

/// @dev Adversarial ABI responses, including overlong and noncanonical words.
contract MalformedManagedHook {
    uint256 public word = 7;
    uint256 public size = 32;

    function set(uint256 word_, uint256 size_) external {
        word = word_;
        size = size_;
    }

    fallback() external {
        uint256 w = msg.sig == IManagedPoolHook.supportedFlags.selector ? 7 : word;
        uint256 n = size;
        assembly {
            mstore(0, w)
            return(0, n)
        }
    }
}

contract ManagedPoolHooksTest is ManagedPoolFixture {
    ExercisedManagedHook private hook;

    function setUp() public override {
        super.setUp();
        hook = new ExercisedManagedHook(address(pool));
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
    }

    function _install(uint8 flags) private {
        pool.closePair(PRIME_PAIR);
        pool.setPairHook(PRIME_PAIR, address(hook), flags);
        pool.setPairAccess(PRIME_PAIR, IM.AccessMode.Listed);
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                prime.balanceOf(address(pool)),
                pathUsd.balanceOf(address(pool)),
                prime.balanceOf(taker),
                pathUsd.balanceOf(taker),
                pool.roundingCredit(pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER)),
                pool.priceAnchor(PRIME_PAIR, true),
                hook.beforeCalls(),
                hook.afterCalls()
            )
        );
    }

    function attemptSell() external returns (uint256) {
        return _sell(PRIME_PAIR, taker, HOME);
    }

    function test_noHookHasZeroFeeAndOriginalQuote() public view {
        (address h, uint8 f) = pool.pairHook(PRIME_PAIR);
        assertEq(h, address(0));
        assertEq(f, 0);
        (uint256 amount,,) = pool.quoteExactInput(PRIME_PAIR, taker, true, 10 * UNIT);
        assertEq(amount, PRIME_OUT);
    }

    function test_onlyOwnerCanInstallOrRemoveHook() public {
        pool.closePair(PRIME_PAIR);
        address[3] memory others = [unauthorized, taker, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert();
            pool.setPairHook(PRIME_PAIR, address(hook), HF.ALL);
        }
        pool.setPairHook(PRIME_PAIR, address(hook), HF.ALL);
        vm.prank(unauthorized);
        vm.expectRevert();
        pool.setPairHook(PRIME_PAIR, address(0), 0);
        pool.setPairHook(PRIME_PAIR, address(0), 0);
        (address h, uint8 f) = pool.pairHook(PRIME_PAIR);
        assertEq(h, address(0));
        assertEq(f, 0);
    }

    function test_installRequiresClosedPairNotJustPausedPool() public {
        vm.expectRevert();
        pool.setPairHook(PRIME_PAIR, address(hook), HF.ALL);
        pool.pause();
        vm.expectRevert();
        pool.setPairHook(PRIME_PAIR, address(hook), HF.ALL);
        pool.closePair(PRIME_PAIR);
        pool.setPairHook(PRIME_PAIR, address(hook), HF.ALL);
    }

    function test_invalidHookConfigurationsFailClosed() public {
        pool.closePair(PRIME_PAIR);
        vm.expectRevert();
        pool.setPairHook(PRIME_PAIR, taker, HF.ALL);
        vm.expectRevert();
        pool.setPairHook(PRIME_PAIR, address(pool), HF.ALL);
        vm.expectRevert();
        pool.setPairHook(PRIME_PAIR, address(0), HF.QUOTE);
        vm.expectRevert();
        pool.setPairHook(PRIME_PAIR, address(hook), 128);
        vm.expectRevert();
        pool.setPairHook(99, address(hook), HF.ALL);
    }

    function test_removedPairCannotRetainHook() public {
        pool.closePair(PRIME_PAIR);
        pool.setPairHook(PRIME_PAIR, address(hook), HF.ALL);
        pool.removePair(PRIME_PAIR);
        vm.expectRevert();
        pool.pairHook(PRIME_PAIR);
        uint16 next = pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        (address h, uint8 f) = pool.pairHook(next);
        assertEq(h, address(0));
        assertEq(f, 0);
    }

    function test_zeroFlagsNeverInvokeConfiguredHook() public {
        _install(0);
        hook.configure(1000, true, true, true);
        hook.quoteMode(true, true);
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT);
        assertEq(hook.beforeCalls(), 0);
        assertEq(hook.afterCalls(), 0);
    }

    function test_callbacksSeeFinalGrossAmountsAndAuthenticatedIdentity() public {
        _install(HF.ALL);
        hook.configure(100, false, false, false);
        uint256 out = _sell(PRIME_PAIR, taker, HOME);
        IManagedPoolHook.SwapContext memory c = hook.last();
        assertEq(c.quote.pairIndex, PRIME_PAIR);
        assertEq(c.quote.taker, taker);
        assertEq(c.caller, taker);
        assertTrue(c.quote.baseToQuote);
        assertTrue(c.quote.exactInput);
        assertEq(c.quote.amount, 10 * UNIT);
        assertEq(c.amountIn, 10 * UNIT);
        assertEq(c.amountOut, out);
        assertEq(c.tokenIn, address(prime));
        assertEq(c.tokenOut, address(pathUsd));
        assertEq(c.customerId, CUSTOMER);
        assertEq(c.tradeId, TRADE);
        assertEq(c.sponsorId, HOME);
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 1);
    }

    function test_callbackFlagsAreIndependentAndPairLocal() public {
        _install(HF.BEFORE_SWAP);
        _sell(PRIME_PAIR, taker, HOME);
        _sell(EUR_PAIR, taker, HOME);
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 0);
        _install(HF.AFTER_SWAP);
        _sell(PRIME_PAIR, taker, HOME);
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 1);
    }

    function test_quoteRejectionAndGasBurnFailWithoutFallback() public {
        _install(HF.QUOTE);
        hook.quoteMode(true, false);
        vm.expectRevert();
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
        vm.expectRevert();
        this.attemptSell();
        hook.quoteMode(false, true);
        vm.expectRevert();
        pool.quoteExactOutput(PRIME_PAIR, taker, true, UNIT);
        vm.expectRevert();
        this.attemptSell();
    }

    function test_hookCannotReturnFeeAboveCap() public {
        _install(HF.QUOTE);
        hook.configure(1001, false, false, false);
        vm.expectRevert();
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
        vm.expectRevert();
        this.attemptSell();
    }

    function test_eachCallbackFailureRollsBackTokensCreditsAndHookState() public {
        _install(HF.ALL);
        for (uint256 i; i < 3; ++i) {
            hook.configure(100, i == 0, i == 1, i == 2);
            bytes32 beforeState = _state();
            vm.expectRevert();
            this.attemptSell();
            assertEq(_state(), beforeState);
        }
    }

    function test_callbacksMayAddInventoryButNeverReduceIt() public {
        _install(HF.ALL);
        hook.movement(100, false, false);
        uint256 balance = pathUsd.balanceOf(address(pool));
        uint256 out = _sell(PRIME_PAIR, taker, HOME);
        assertEq(pathUsd.balanceOf(address(pool)), balance + 100 - out);
        for (uint256 i; i < 2; ++i) {
            hook.movement(0, i == 0, i == 1);
            bytes32 beforeState = _state();
            vm.expectRevert();
            this.attemptSell();
            assertEq(_state(), beforeState);
        }
    }

    function test_ownerHookCannotReenterPoolAdministration() public {
        _install(HF.BEFORE_SWAP);
        pool.transferOwnership(address(hook));
        vm.prank(address(hook));
        pool.acceptOwnership();
        hook.reenter(address(pool), abi.encodeCall(pool.pause, ()));
        _sell(PRIME_PAIR, taker, HOME);
        assertFalse(hook.reentrySucceeded());
        assertFalse(pool.paused());
    }

    function test_coreAccessAndOracleStillPrecedeHook() public {
        _install(HF.ALL);
        hook.configure(0, false, false, false);
        pool.setDenied(_one(taker), true);
        vm.expectRevert();
        this.attemptSell();
        assertEq(hook.beforeCalls(), 0);
        pool.setDenied(_one(taker), false);
        primeOracle.setPrice(PRIME_PRICE, block.timestamp - MAX_AGE - 1);
        vm.expectRevert();
        this.attemptSell();
        assertEq(hook.beforeCalls(), 0);
    }

    function test_hookRejectsDirectCallbacksFromStranger() public {
        IManagedPoolHook.SwapContext memory c;
        vm.prank(stranger);
        vm.expectRevert();
        hook.beforeSwap(c);
        vm.prank(stranger);
        vm.expectRevert();
        hook.afterSwap(c);
    }

    function test_malformedQuoteResponseAndCallbackAckCannotPass() public {
        MalformedManagedHook bad = new MalformedManagedHook();
        pool.closePair(PRIME_PAIR);
        pool.setPairHook(PRIME_PAIR, address(bad), HF.QUOTE);
        pool.setPairAccess(PRIME_PAIR, IM.AccessMode.Listed);
        bad.set(1 << 16, 32);
        vm.expectRevert();
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
        bad.set(0, 16384);
        vm.expectRevert();
        pool.quoteExactOutput(PRIME_PAIR, taker, true, UNIT);
        bad.set(0, 0);
        vm.expectRevert();
        this.attemptSell();
        pool.closePair(PRIME_PAIR);
        bad.set(0, 32);
        pool.setPairHook(PRIME_PAIR, address(bad), HF.AFTER_SWAP);
        pool.setPairAccess(PRIME_PAIR, IM.AccessMode.Listed);
        bytes32 beforeState = _state();
        vm.expectRevert();
        this.attemptSell();
        assertEq(_state(), beforeState);
    }

    function _factoryPool() private returns (Settler settler) {
        PoolFactory factory = new PoolFactory();
        settler = Settler(factory.defaultSettler());
        pool = ManagedDirectPropAMM(factory.createPool(address(this), bytes32("hook-forwarding")));
        pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        hook = new ExercisedManagedHook(address(pool));
        pool.setPairHook(0, address(hook), HF.ALL);
        _listHome(0, taker);
        pool.setPairAccess(0, IM.AccessMode.Listed);
        prime.mint(address(pool), 1000 * UNIT);
        pathUsd.mint(address(pool), 1000 * UNIT);
        pool.unpause();
    }

    function _params(bool exactIn) private view returns (IM.SwapParams memory s) {
        s = IM.SwapParams({
            pairIndex: 0,
            baseToQuote: true,
            exactInput: exactIn,
            amount: UNIT,
            limit: exactIn ? 0 : 2 * UNIT,
            sponsorId: HOME,
            customerId: CUSTOMER,
            tradeId: TRADE,
            deadline: block.timestamp,
            expectedOraclePrice: PRIME_PRICE,
            oraclePriceToleranceBps: 0,
            minimumOracleUpdatedAt: 0
        });
    }

    function test_hookReceivesRouterIdentityAndCallerGetsOutput() public {
        Settler settler = _factoryPool();
        pool.setMembers(0, HOME, _one(address(this)), true);
        prime.mint(address(this), 10 * UNIT);
        prime.approve(address(settler), UNIT);
        uint256 beforeOut = pathUsd.balanceOf(address(this));
        hook.configure(100, false, false, false);
        uint256 out = settler.swap(address(pool), _params(true));
        IManagedPoolHook.SwapContext memory c = hook.last();
        assertEq(c.quote.taker, address(this));
        assertEq(c.caller, address(this));
        assertEq(pathUsd.balanceOf(address(this)), beforeOut + out);
        assertEq(out, 1_039_500);
    }

    function test_stateDependentExactOutputFeeCannotSpendAmbientInventory() public {
        Settler settler = _factoryPool();
        hook.balanceMode(address(prime), prime.balanceOf(address(pool)));
        hook.configure(100, false, false, false);
        vm.startPrank(taker);
        prime.approve(address(settler), 2 * UNIT);
        vm.stopPrank();
        bytes32 beforeState = _state();
        vm.prank(taker);
        vm.expectRevert();
        settler.swap(address(pool), _params(false));
        assertEq(_state(), beforeState);
        assertEq(prime.balanceOf(address(settler)), 0);
        assertEq(pathUsd.balanceOf(address(settler)), 0);
    }
}
