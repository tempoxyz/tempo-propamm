// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockReentrantTIP20 } from "../mocks/MockReentrantTIP20.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { ManagedPoolFixture } from "./utils/ManagedPoolFixture.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

/// @notice `ManagedDirectPropAMM`'s pairs, their lifecycle and pricing, the shared inventory, `fund` and `withdraw`
/// (which refuses a TIP-1022 virtual recipient, as v2 `Venue` does), the locks and the storage layout. The access model
/// has its own suite (`ManagedDirectPropAMMAccess.t.sol`), and the v1 pricing differential its own
/// (`ManagedDirectPropAMMDifferential`).
contract ManagedDirectPropAMMTest is ManagedPoolFixture {
    // Storage slots follow the core declarations; runtime assertions pin their packing.
    uint256 internal constant SLOT_WORD = 0;
    uint256 internal constant SLOT_PENDING_OWNER = 1;
    uint256 internal constant SLOT_PAIRS = 2;
    uint256 internal constant SLOT_ANCHORS = 3;
    uint256 internal constant SLOT_CREDITS = 4;
    uint256 internal constant SLOT_TOKEN_PAIRS = 5;
    uint256 internal constant SLOT_DENIED = 6;
    /// @dev The fixture's `vm.warp`, when every oracle was last updated.
    uint256 internal constant START = 1_000_000;

    // ---------------------------------------------------------------- construction

    function test_constructorStartsPausedWithNothing() external {
        vm.expectEmit(false, false, false, true);
        emit IManagedDirectPropAMM.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(false, false, false, true);
        emit IManagedDirectPropAMM.PausedStateChanged(true);
        ManagedDirectPropAMM fresh = new ManagedDirectPropAMM(address(this), address(0));

        assertEq(fresh.owner(), address(this));
        assertEq(fresh.pendingOwner(), address(0));
        assertTrue(fresh.paused());
        assertEq(fresh.pairCount(), 0);
        assertEq(fresh.deniedCount(), 0);
        assertEq(fresh.MAX_BATCH(), MAX_BATCH);
        assertEq(fresh.BPS(), 10_000);
        assertEq(uint8(fresh.pair(0).access), uint8(IManagedDirectPropAMM.AccessMode.None));
        assertEq(uint8(fresh.takerAccess(0, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.UnknownPair));
        // No TIP-1022 surface: the pool holds no address registry and resolves nothing, as v2 `Venue`.
        (bool hasRegistry,) = address(fresh).staticcall(abi.encodeWithSignature("addressRegistry()"));
        (bool resolves,) = address(fresh).staticcall(abi.encodeWithSignature("resolveRecipient(address)", taker));
        assertFalse(hasRegistry, "addressRegistry()");
        assertFalse(resolves, "resolveRecipient(address)");
    }

    function test_constructorRejectsZeroAddresses() external {
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        new ManagedDirectPropAMM(address(0), address(0));
    }

    // ---------------------------------------------------------------- pairs

    /// @dev `pair` reports what `addPair` stored, with `DirectPropAMM`'s price scale for every decimals mix.
    function test_addPairStoresTheConfigClosedWithZeroAnchors() external {
        MockTIP20 usdc = new MockTIP20("USDC", 6);
        MockTIP20 dai = new MockTIP20("DAI", 18);
        MockOracle oracle18 = new MockOracle(18, 1e18, block.timestamp);
        uint16 next = pool.pairCount();

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PairAdded(next, address(usdc), address(dai));
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.OracleUpdated(next, address(0), address(oracle18), 18);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.MaxOracleAgeUpdated(next, 0, 3_600);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.MaxPriceDeviationBpsUpdated(next, 0, 25);
        assertEq(pool.addPair(address(usdc), address(dai), oracle18, 3_600, 25), next);

        IManagedDirectPropAMM.Pair memory info = pool.pair(next);
        assertEq(info.base, address(usdc));
        assertEq(info.quote, address(dai));
        assertEq(address(info.oracle), address(oracle18));
        assertEq(info.baseDecimals, 6);
        assertEq(info.quoteDecimals, 18);
        assertEq(info.oracleDecimals, 18);
        assertEq(info.priceScale, 1e6, "10 ** (6 + 18 - 18)");
        assertEq(info.maxOracleAge, 3_600);
        assertEq(info.maxPriceDeviationBps, 25);
        assertEq(uint8(info.access), uint8(IManagedDirectPropAMM.AccessMode.Closed));
        assertEq(pool.pairCount(), next + 1);
        assertEq(pool.priceAnchor(next, true), 0);
        assertEq(pool.priceAnchor(next, false), 0);
        assertEq(pool.tokenPairCount(address(usdc)), 1);
        assertEq(pool.tokenPairCount(address(dai)), 1);
        assertEq(uint8(_access(next, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.Closed));

        // The fixture's pairs: 6/6 with 8 oracle decimals, and 18/6 with 8.
        assertEq(pool.pair(PRIME_PAIR).priceScale, 1e8);
        assertEq(pool.pair(EUR_PAIR).priceScale, 1e20);
        assertEq(pool.tokenPairCount(address(pathUsd)), 2, "pathUSD backs both pairs");
    }

    /// @dev The same tokens may form several pairs, either way round, each with its own oracle and settings.
    function test_addPairAllowsDuplicateAndReversedPairs() external {
        uint16 same = pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        MockOracle inverse = new MockOracle(8, 95_238_095, block.timestamp);
        uint16 reversed = pool.addPair(address(pathUsd), address(prime), inverse, MAX_AGE, MAX_DEVIATION_BPS);
        assertEq(same, 2);
        assertEq(reversed, 3);
        assertEq(pool.tokenPairCount(address(prime)), 3);
        assertEq(pool.tokenPairCount(address(pathUsd)), 4);
        assertEq(pool.pair(reversed).base, address(pathUsd));
    }

    /// @dev `DirectPropAMM`'s constructor checks, in its order, then the pair limit.
    function test_addPairValidation() external {
        address p = address(prime);
        address q = address(pathUsd);
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.addPair(address(0), q, primeOracle, MAX_AGE, 0);
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.addPair(p, address(0), primeOracle, MAX_AGE, 0);
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.addPair(p, q, IPriceOracle(address(0)), MAX_AGE, 0);
        // A zero token wins over the same-token check, as in v1.
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.addPair(address(0), address(0), primeOracle, MAX_AGE, 0);
        vm.expectRevert(IManagedDirectPropAMM.SameToken.selector);
        pool.addPair(p, p, primeOracle, MAX_AGE, 0);
        vm.expectRevert(IManagedDirectPropAMM.InvalidMaxOracleAge.selector);
        pool.addPair(p, q, primeOracle, 0, 0);
        vm.expectRevert(IManagedDirectPropAMM.InvalidMaxOracleAge.selector);
        pool.addPair(p, q, primeOracle, uint256(type(uint80).max) + 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.InvalidMaxPriceDeviationBps.selector, 10_001, 10_000)
        );
        pool.addPair(p, q, primeOracle, MAX_AGE, 10_001);
        // `uint80` age and the full 10,000 bps are accepted.
        pool.addPair(p, q, primeOracle, type(uint80).max, 10_000);
        assertEq(pool.pair(2).maxOracleAge, type(uint80).max);

        // Decimals: below zero, and above 10 ** 77.
        MockTIP20 zero = new MockTIP20("ZERO", 0);
        MockOracle oracle0 = new MockOracle(0, 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedDecimals.selector, 0, 6, 0));
        pool.addPair(address(zero), q, oracle0, MAX_AGE, 0);
        MockTIP20 wide = new MockTIP20("WIDE", 70);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedDecimals.selector, 70, 0, 8));
        pool.addPair(address(wide), address(zero), primeOracle, MAX_AGE, 0);
        // An account without `decimals()` reverts the call.
        vm.expectRevert();
        pool.addPair(makeAddr("eoa"), q, primeOracle, MAX_AGE, 0);

        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.addPair(p, q, primeOracle, MAX_AGE, 0);
    }

    function test_addPairStopsAtTheIndexLimit() external {
        uint256 word = uint256(vm.load(address(pool), bytes32(SLOT_WORD)));
        word = (word & ~(uint256(type(uint16).max) << 192)) | (uint256(type(uint16).max - 1) << 192);
        vm.store(address(pool), bytes32(SLOT_WORD), bytes32(word));
        assertEq(pool.pairCount(), type(uint16).max - 1);
        assertEq(pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, 0), type(uint16).max - 1);
        assertEq(pool.pairCount(), type(uint16).max);
        vm.expectRevert(IManagedDirectPropAMM.PairLimitReached.selector);
        pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, 0);
        assertEq(pool.owner(), address(this), "owner kept beside pairCount");
        assertFalse(pool.paused(), "pause kept beside pairCount");
    }

    /// @dev A removed pair reads all zero and `None`, refuses quotes, swaps and listings with `UnknownPair`, gives its
    /// tokens' counts back, and its index is never reused. Its inventory stays and can still be withdrawn.
    function test_removePairNeverReusesTheIndex() external {
        _listHome(PRIME_PAIR, taker);
        _addAlpha();
        _listAlpha(PRIME_PAIR, member);
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT);

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PairRemoved(PRIME_PAIR);
        pool.removePair(PRIME_PAIR);

        IManagedDirectPropAMM.Pair memory info = pool.pair(PRIME_PAIR);
        assertEq(info.base, address(0));
        assertEq(info.quote, address(0));
        assertEq(address(info.oracle), address(0));
        assertEq(info.priceScale, 0);
        assertEq(uint8(info.access), uint8(IManagedDirectPropAMM.AccessMode.None));
        assertEq(pool.priceAnchor(PRIME_PAIR, true), 0, "anchors cleared");
        assertEq(pool.priceAnchor(PRIME_PAIR, false), 0);
        assertEq(uint8(_access(PRIME_PAIR, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.UnknownPair));
        assertFalse(pool.takerAllowed(PRIME_PAIR, taker, HOME));
        assertFalse(pool.pairSponsor(PRIME_PAIR, HOME));
        assertFalse(pool.pairSponsor(PRIME_PAIR, ALPHA));
        assertFalse(pool.isMember(PRIME_PAIR, HOME, taker));
        assertFalse(pool.isMember(PRIME_PAIR, ALPHA, member));
        assertEq(pool.tokenPairCount(address(prime)), 0);
        assertEq(pool.tokenPairCount(address(pathUsd)), 1);

        bytes memory unknown = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, PRIME_PAIR);
        vm.expectRevert(unknown);
        pool.quoteExactInput(PRIME_PAIR, taker, true, UNIT);
        vm.expectRevert(unknown);
        pool.quoteExactOutput(PRIME_PAIR, taker, true, UNIT);
        vm.expectRevert(unknown);
        pool.quoteExactInputFor(PRIME_PAIR, taker, CUSTOMER, true, UNIT);
        vm.expectRevert(unknown);
        pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, true, UNIT);
        _expectSellRevert(unknown, PRIME_PAIR, taker, HOME);
        vm.expectRevert(unknown);
        pool.setMembers(PRIME_PAIR, HOME, _one(stranger), true);
        pool.setMembers(PRIME_PAIR, HOME, _one(taker), false);
        vm.expectRevert(unknown);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        vm.expectRevert(unknown);
        pool.closePair(PRIME_PAIR);
        vm.expectRevert(unknown);
        pool.removePair(PRIME_PAIR);
        vm.expectRevert(unknown);
        pool.setOracle(PRIME_PAIR, primeOracle);

        // PRIME no longer backs a live pair, so it can't be funded, but it can always be withdrawn.
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedToken.selector, address(prime)));
        pool.fund(address(prime), UNIT, bytes32(0));
        uint256 inventory = prime.balanceOf(address(pool));
        pool.withdraw(address(prime), stranger, inventory, bytes32(0));
        assertEq(prime.balanceOf(address(pool)), 0);

        // The other pair is untouched, and a new pair takes a new index.
        _listHome(EUR_PAIR, taker);
        assertEq(_sell(EUR_PAIR, taker, HOME), 10 * EUR_OUT);
        assertEq(pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS), 2);
        assertFalse(pool.isMember(2, HOME, taker), "the new index has no lists");
        assertEq(pool.pairCount(), 3);

        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.removePair(EUR_PAIR);
    }

    /// @dev A pair can be removed in any mode, and removal of a never-opened pair works too.
    function test_removePairInAnyMode() external {
        uint16 fresh = pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.removePair(fresh);
        _setAccess(EUR_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        pool.removePair(EUR_PAIR);
        pool.removePair(PRIME_PAIR);
        assertEq(pool.tokenPairCount(address(pathUsd)), 0);
        assertEq(pool.pairCount(), 3);
    }

    // ---------------------------------------------------------------- per-pair risk settings

    /// @dev A pair's oracle, risk settings and anchors change only while it is `Closed`; the other pair keeps trading.
    function test_riskSettingsNeedTheirPairClosed() external {
        MockOracle replacement = new MockOracle(8, PRIME_PRICE, block.timestamp);
        bytes memory notClosed = abi.encodeWithSelector(IManagedDirectPropAMM.PairNotClosed.selector, PRIME_PAIR);
        vm.expectRevert(notClosed);
        pool.setOracle(PRIME_PAIR, replacement);
        vm.expectRevert(notClosed);
        pool.setMaxOracleAge(PRIME_PAIR, 60);
        vm.expectRevert(notClosed);
        pool.setMaxPriceDeviationBps(PRIME_PAIR, 10);
        vm.expectRevert(notClosed);
        pool.resetPriceAnchor(PRIME_PAIR, true);
        // The pool-wide pause doesn't open them.
        pool.pause();
        vm.expectRevert(notClosed);
        pool.setMaxOracleAge(PRIME_PAIR, 60);
        pool.unpause();

        pool.closePair(PRIME_PAIR);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.OracleUpdated(PRIME_PAIR, address(primeOracle), address(replacement), 8);
        pool.setOracle(PRIME_PAIR, replacement);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.MaxOracleAgeUpdated(PRIME_PAIR, MAX_AGE, 60);
        pool.setMaxOracleAge(PRIME_PAIR, 60);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.MaxPriceDeviationBpsUpdated(PRIME_PAIR, MAX_DEVIATION_BPS, 10);
        pool.setMaxPriceDeviationBps(PRIME_PAIR, 10);
        IManagedDirectPropAMM.Pair memory info = pool.pair(PRIME_PAIR);
        assertEq(address(info.oracle), address(replacement));
        assertEq(info.maxOracleAge, 60);
        assertEq(info.maxPriceDeviationBps, 10);
        // `DirectPropAMM`'s own checks.
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.setOracle(PRIME_PAIR, IPriceOracle(address(0)));
        MockOracle wider = new MockOracle(18, 1e18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.OracleDecimalsChanged.selector, 8, 18));
        pool.setOracle(PRIME_PAIR, wider);
        vm.expectRevert(IManagedDirectPropAMM.InvalidMaxOracleAge.selector);
        pool.setMaxOracleAge(PRIME_PAIR, 0);
        vm.expectRevert(IManagedDirectPropAMM.InvalidMaxOracleAge.selector);
        pool.setMaxOracleAge(PRIME_PAIR, uint256(type(uint80).max) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.InvalidMaxPriceDeviationBps.selector, 10_001, 10_000)
        );
        pool.setMaxPriceDeviationBps(PRIME_PAIR, 10_001);
        vm.startPrank(unauthorized);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setOracle(PRIME_PAIR, replacement);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setMaxOracleAge(PRIME_PAIR, 60);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setMaxPriceDeviationBps(PRIME_PAIR, 10);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.resetPriceAnchor(PRIME_PAIR, true);
        vm.stopPrank();
        bytes memory unknown = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, uint16(9));
        vm.expectRevert(unknown);
        pool.setMaxOracleAge(9, 60);

        // Meanwhile the EUR pair trades.
        _listHome(EUR_PAIR, taker);
        assertEq(_sell(EUR_PAIR, taker, HOME), 10 * EUR_OUT);
        assertEq(address(pool.pair(EUR_PAIR).oracle), address(eurOracle));
    }

    /// @dev `resetPriceAnchor` takes the fresh price without a deviation check, as in v1, and reopening then validates
    /// against it.
    function test_resetPriceAnchorRecoversADriftedPair() external {
        uint256 drifted = PRIME_PRICE * 102 / 100;
        primeOracle.setPrice(drifted, block.timestamp);
        pool.closePair(PRIME_PAIR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector, true, drifted, PRIME_PRICE, MAX_DEVIATION_BPS
            )
        );
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PriceAnchorUpdated(PRIME_PAIR, true, PRIME_PRICE, drifted);
        pool.resetPriceAnchor(PRIME_PAIR, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector, false, drifted, PRIME_PRICE, MAX_DEVIATION_BPS
            )
        );
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        pool.resetPriceAnchor(PRIME_PAIR, false);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        assertEq(pool.priceAnchor(PRIME_PAIR, true), drifted);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), drifted);
        assertEq(pool.priceAnchor(EUR_PAIR, true), EUR_PRICE, "the other pair's anchors are untouched");

        // `resetPriceAnchor` reads the oracle fresh, with v1's checks. (No `block.timestamp` across the warp: via_ir
        // may re-read it.)
        pool.closePair(PRIME_PAIR);
        vm.warp(START + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, START, MAX_AGE));
        pool.resetPriceAnchor(PRIME_PAIR, true);
    }

    /// @dev One direction trades and walks its anchor with the oracle; the other, untraded, keeps its old anchor and
    /// drifts out of band. The owner refreshes it on the live pair, with no close, reopen or pool-wide pause (also for an
    /// `Open` pair), only to a fresh price within its own bound: a different price at execution reverts and changes
    /// nothing. An unauthorized account can't, and a stale oracle still refuses.
    function test_refreshPriceAnchorRecoversALivePair() external {
        _listHome(PRIME_PAIR, taker);
        uint256 step = PRIME_PRICE * 1004 / 1000;
        primeOracle.setPrice(step, block.timestamp);
        _sell(PRIME_PAIR, taker, HOME);
        assertEq(pool.priceAnchor(PRIME_PAIR, true), step, "the traded direction follows the oracle");
        uint256 drifted = step * 1004 / 1000;
        primeOracle.setPrice(drifted, block.timestamp);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), PRIME_PRICE, "the untraded direction kept its anchor");
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector, false, drifted, PRIME_PRICE, MAX_DEVIATION_BPS
            )
        );
        pool.quoteExactInput(PRIME_PAIR, taker, false, UNIT);

        vm.prank(unauthorized);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.refreshPriceAnchor(PRIME_PAIR, false, drifted, 0);
        // The owner validated `step`, but the oracle reads `drifted` at execution: nothing changes.
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.OraclePriceToleranceExceeded.selector, step, drifted, 10)
        );
        pool.refreshPriceAnchor(PRIME_PAIR, false, step, 10);
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.InvalidOraclePriceToleranceBps.selector, 10_001, 10_000)
        );
        pool.refreshPriceAnchor(PRIME_PAIR, false, drifted, 10_001);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), PRIME_PRICE);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PriceAnchorUpdated(PRIME_PAIR, false, PRIME_PRICE, drifted);
        pool.refreshPriceAnchor(PRIME_PAIR, false, drifted, 0);
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Listed));
        assertFalse(pool.paused());
        pool.quoteExactInput(PRIME_PAIR, taker, false, UNIT);

        // An `Open` pair recovers the same way, without pausing the pool again.
        pool.pause();
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        pool.unpause();
        _sell(PRIME_PAIR, taker, HOME);
        uint256 again = drifted;
        for (uint256 i; i < 2; ++i) {
            again = again * 1004 / 1000;
            primeOracle.setPrice(again, block.timestamp);
            _sell(PRIME_PAIR, taker, HOME);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector, false, again, drifted, MAX_DEVIATION_BPS
            )
        );
        pool.quoteExactInput(PRIME_PAIR, taker, false, UNIT);
        pool.refreshPriceAnchor(PRIME_PAIR, false, again * 1001 / 1000, 10);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), again);
        assertFalse(pool.paused());

        // Still a fresh read with v1's checks.
        vm.warp(START + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, START, MAX_AGE));
        pool.refreshPriceAnchor(PRIME_PAIR, true, again, 10_000);
    }

    // ---------------------------------------------------------------- the pair lifecycle

    /// @dev Leaving `Closed` is the pair's own unpause: the first exit sets both anchors from one fresh read; later
    /// exits validate it, as `DirectPropAMM.unpause` does. `Listed` to `Open` and back reads no oracle.
    function test_leavingClosedRunsV1UnpauseChecksOnThePair() external {
        MockOracle oracle = new MockOracle(8, PRIME_PRICE, block.timestamp);
        uint16 fresh = pool.addPair(address(prime), address(pathUsd), oracle, MAX_AGE, MAX_DEVIATION_BPS);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.PriceAnchorNotInitialized.selector, true));
        pool.quoteExactInput(fresh, taker, true, UNIT);

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PriceAnchorUpdated(fresh, true, 0, PRIME_PRICE);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PriceAnchorUpdated(fresh, false, 0, PRIME_PRICE);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PairAccessUpdated(
            fresh, IManagedDirectPropAMM.AccessMode.Closed, IManagedDirectPropAMM.AccessMode.Listed
        );
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Listed);
        assertEq(pool.priceAnchor(fresh, true), PRIME_PRICE);
        assertEq(pool.priceAnchor(fresh, false), PRIME_PRICE);

        // Each later exit validates: deviation, freshness, a zero price and a future timestamp.
        pool.closePair(fresh);
        oracle.setPrice(PRIME_PRICE * 101 / 100, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector,
                true,
                PRIME_PRICE * 101 / 100,
                PRIME_PRICE,
                MAX_DEVIATION_BPS
            )
        );
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Listed);
        oracle.setPrice(PRIME_PRICE, block.timestamp - MAX_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.StaleOraclePrice.selector, block.timestamp - MAX_AGE - 1, MAX_AGE
            )
        );
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Listed);
        oracle.setPrice(0, block.timestamp);
        vm.expectRevert(IManagedDirectPropAMM.InvalidPrice.selector);
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Listed);
        oracle.setPrice(PRIME_PRICE, block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.FutureOracleTimestamp.selector, block.timestamp + 1, block.timestamp
            )
        );
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Listed);
        // A price within the limit reopens it and keeps the anchors: v1's unpause only validates them.
        oracle.setPrice(PRIME_PRICE * 1004 / 1000, block.timestamp);
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Listed);
        assertEq(pool.priceAnchor(fresh, true), PRIME_PRICE);

        // `Listed` to `Open` and back read no oracle: a broken feed doesn't stop them.
        oracle.setPrice(0, 0);
        pool.pause();
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Open);
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Listed);
        // Closing never reads one either.
        pool.closePair(fresh);
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Closed);
        // Closed to Open validates, like Closed to Listed.
        vm.expectRevert(IManagedDirectPropAMM.InvalidPrice.selector);
        pool.setPairAccess(fresh, IManagedDirectPropAMM.AccessMode.Open);
    }

    function test_setPairAccessValidation() external {
        vm.expectRevert(IManagedDirectPropAMM.InvalidAccessMode.selector);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.None);
        vm.expectRevert(IManagedDirectPropAMM.NotPaused.selector);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, uint16(9)));
        pool.setPairAccess(9, IManagedDirectPropAMM.AccessMode.Listed);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Closed);

        // The current mode emits and changes nothing, so re-setting `Open` needs no pause.
        _setAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PairAccessUpdated(
            PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open, IManagedDirectPropAMM.AccessMode.Open
        );
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        vm.expectRevert(IManagedDirectPropAMM.InvalidAccessMode.selector);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.None);
    }

    /// @dev Only the owner closes a pair, in any mode, and every call emits; only the owner reopens.
    function test_closePairAnyTimeAndOnlyTheOwnerReopens() external {
        _listHome(PRIME_PAIR, taker);
        for (uint256 k; k < 2; ++k) {
            IManagedDirectPropAMM.AccessMode previous = pool.pair(PRIME_PAIR).access;
            vm.expectEmit(address(pool));
            emit IManagedDirectPropAMM.PairAccessUpdated(PRIME_PAIR, previous, IManagedDirectPropAMM.AccessMode.Closed);
            pool.closePair(PRIME_PAIR);
        }
        _expectSellRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.TakerNotAllowed.selector, taker), PRIME_PAIR, taker, HOME
        );
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.closePair(PRIME_PAIR);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT);
    }

    // ---------------------------------------------------------------- the pool-wide pause

    /// @dev `pause` stops every pair; `unpause` reads no oracle, so a broken feed on one pair doesn't keep the others
    /// stopped. That pair's swaps still fail on its own oracle.
    function test_pauseStopsEveryPairAndUnpauseChecksNoOracle() external {
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PausedStateChanged(true);
        pool.pause();
        _expectSellRevert(abi.encodeWithSelector(IManagedDirectPropAMM.Paused.selector), PRIME_PAIR, taker, HOME);
        _expectSellRevert(abi.encodeWithSelector(IManagedDirectPropAMM.Paused.selector), EUR_PAIR, taker, HOME);
        // The access views ignore the pause, as v2's ignore `halted`.
        assertTrue(pool.takerAllowed(PRIME_PAIR, taker, HOME));

        primeOracle.setPrice(0, 0);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.unpause();
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.PausedStateChanged(false);
        pool.unpause();
        assertFalse(pool.paused());
        assertEq(_sell(EUR_PAIR, taker, HOME), 10 * EUR_OUT);
        vm.expectRevert(IManagedDirectPropAMM.InvalidPrice.selector);
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, true, UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, 0, 0, 0);

        // Both are idempotent, and no-op calls emit nothing.
        vm.recordLogs();
        pool.unpause();
        assertEq(vm.getRecordedLogs().length, 0, "an owner no-op unpause emits nothing");
        pool.pause();
        vm.recordLogs();
        pool.pause();
        assertEq(vm.getRecordedLogs().length, 0, "an owner no-op pause emits nothing");
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(stranger);
        pool.pause();
    }

    // ---------------------------------------------------------------- swaps

    /// @dev Exact in and exact out on both pairs pay the caller, move only the pair's tokens, and emit the pair, the
    /// sponsor and v1's route credit.
    function test_swapsPayTheCallerOnTheirPair() external {
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
        bytes32 routeKey = pool.roundingRouteKey(EUR_PAIR, taker, CUSTOMER);
        uint256 eurBefore = eurx.balanceOf(taker);
        uint256 usdBefore = pathUsd.balanceOf(taker);
        uint256 primeBefore = prime.balanceOf(taker);

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.RoundingCreditUpdated(routeKey, 0, 0);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.TradeExecuted(
            EUR_PAIR,
            taker,
            CUSTOMER,
            HOME,
            TRADE,
            address(eurx),
            address(pathUsd),
            EUR_UNIT,
            EUR_OUT,
            EUR_PRICE,
            block.timestamp
        );
        vm.prank(taker);
        assertEq(
            pool.swapExactInput(
                EUR_PAIR, true, EUR_UNIT, EUR_OUT, HOME, CUSTOMER, TRADE, block.timestamp, EUR_PRICE, 0, 0
            ),
            EUR_OUT
        );
        assertEq(eurx.balanceOf(taker), eurBefore - EUR_UNIT);
        assertEq(pathUsd.balanceOf(taker), usdBefore + EUR_OUT);
        assertEq(prime.balanceOf(taker), primeBefore, "the other pair's base never moves");

        // Exact output, quote to base, on the PRIME pair: 10.5 pathUSD buys 10 PRIME.
        vm.prank(taker);
        assertEq(
            pool.swapExactOutput(
                PRIME_PAIR, false, 10 * UNIT, PRIME_OUT, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
            ),
            PRIME_OUT
        );
        assertEq(prime.balanceOf(taker), primeBefore + 10 * UNIT);
        assertEq(pathUsd.balanceOf(taker), usdBefore + EUR_OUT - PRIME_OUT);
        assertEq(eurx.balanceOf(taker), eurBefore - EUR_UNIT);

        // v1's limits and checks, unchanged.
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.SlippageExceeded.selector, PRIME_OUT - 1, PRIME_OUT)
        );
        vm.prank(taker);
        pool.swapExactOutput(
            PRIME_PAIR, false, 10 * UNIT, PRIME_OUT - 1, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
        );
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.DeadlineExpired.selector, block.timestamp - 1, block.timestamp)
        );
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, true, UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp - 1, PRIME_PRICE, 0, 0);
        vm.expectRevert(IManagedDirectPropAMM.CustomerIdIsZero.selector);
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, true, UNIT, 0, HOME, bytes32(0), TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, true, 0, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.OraclePriceToleranceExceeded.selector, PRIME_PRICE + 1, PRIME_PRICE, 0
            )
        );
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, true, UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE + 1, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.OracleTimestampTooOld.selector, block.timestamp + 1, block.timestamp
            )
        );
        vm.prank(taker);
        pool.swapExactInput(
            PRIME_PAIR, true, UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, block.timestamp + 1
        );
    }

    /// @dev The output must reach the caller exactly: a fee or a redirect on the output token reverts the swap.
    function test_outputMustReachTheCallerExactly() external {
        _listHome(PRIME_PAIR, taker);
        pathUsd.setFeeBps(1);
        _expectSellRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.ExactBalanceDeltaFailed.selector, address(pathUsd), PRIME_OUT, PRIME_OUT - 1_050
            ),
            PRIME_PAIR,
            taker,
            HOME
        );
        pathUsd.setFeeBps(0);
        pathUsd.setRedirectRecipient(stranger);
        _expectSellRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.ExactBalanceDeltaFailed.selector, address(pathUsd), PRIME_OUT, 0
            ),
            PRIME_PAIR,
            taker,
            HOME
        );
    }

    /// @dev v1's limits on both swaps: an exact input below its minimum output and an exact output above its maximum
    /// input revert `SlippageExceeded`, and one unit of slack fills.
    function test_slippageLimitsOnBothPairs() external {
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.SlippageExceeded.selector, 10 * EUR_OUT + 1, 10 * EUR_OUT)
        );
        vm.prank(taker);
        pool.swapExactInput(
            EUR_PAIR, true, 10 * EUR_UNIT, 10 * EUR_OUT + 1, HOME, CUSTOMER, TRADE, block.timestamp, EUR_PRICE, 0, 0
        );
        vm.prank(taker);
        assertEq(
            pool.swapExactInput(
                EUR_PAIR, true, 10 * EUR_UNIT, 10 * EUR_OUT, HOME, CUSTOMER, TRADE, block.timestamp, EUR_PRICE, 0, 0
            ),
            10 * EUR_OUT
        );
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.SlippageExceeded.selector, 10 * UNIT - 1, 10 * UNIT)
        );
        vm.prank(taker);
        pool.swapExactOutput(
            PRIME_PAIR, true, PRIME_OUT, 10 * UNIT - 1, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
        );
    }

    /// @dev The pool's debit must be exact too: a token that takes more from the pool than it sends reverts the swap's
    /// payout and a withdrawal alike.
    function test_aPayoutThatOverdebitsThePoolReverts() external {
        OverdebitTIP20 base = new OverdebitTIP20();
        uint16 index = pool.addPair(address(base), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.setPairAccess(index, IManagedDirectPropAMM.AccessMode.Listed);
        _listHome(index, taker);
        base.mint(address(pool), 1_000 * UNIT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.ExactBalanceDeltaFailed.selector, address(base), UNIT, UNIT + 1
            )
        );
        pool.withdraw(address(base), stranger, UNIT, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.ExactBalanceDeltaFailed.selector, address(base), 10 * UNIT, 10 * UNIT + 1
            )
        );
        vm.prank(taker);
        pool.swapExactOutput(
            index, false, 10 * UNIT, type(uint256).max, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0
        );
    }

    /// @dev The same taker and customer on two pairs keep separate rounding credits, and a swap moves only its own
    /// pair's anchor in its own direction.
    function test_pairsKeepSeparateCreditsAndAnchors() external {
        // Same tokens, two pairs: one priced so a 1-unit sale leaves a remainder, the other at a round price.
        MockOracle odd = new MockOracle(8, 100_000_003, block.timestamp);
        uint16 a = pool.addPair(address(prime), address(pathUsd), odd, MAX_AGE, MAX_DEVIATION_BPS);
        uint16 b = pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.setPairAccess(a, IManagedDirectPropAMM.AccessMode.Listed);
        pool.setPairAccess(b, IManagedDirectPropAMM.AccessMode.Listed);
        _listHome(a, taker);
        _listHome(b, taker);
        bytes32 keyA = pool.roundingRouteKey(a, taker, CUSTOMER);
        bytes32 keyB = pool.roundingRouteKey(b, taker, CUSTOMER);
        assertTrue(keyA != keyB, "the route names the pair");

        vm.prank(taker);
        pool.swapExactInput(a, true, 1, 0, HOME, CUSTOMER, TRADE, block.timestamp, 100_000_003, 0, 0);
        // 1 unit at 1.00000003 is worth 100_000_003 / 1e8 units: 1 out and a credit of 3.
        assertEq(pool.roundingCredit(keyA), 3);
        assertEq(pool.roundingCredit(keyB), 0, "the other pair's route earns nothing");
        // Pair b's quote starts from its own empty route: 1 unit at 1.05 leaves a credit of 5_000_000 there.
        (,,, uint256 creditAfter) = pool.quoteExactInputFor(b, taker, CUSTOMER, true, 1);
        assertEq(creditAfter, 5_000_000);

        // Move pair b's anchor; pair a's and the fixture's stay.
        primeOracle.setPrice(PRIME_PRICE * 1004 / 1000, block.timestamp);
        vm.prank(taker);
        pool.swapExactInput(b, false, UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE * 1004 / 1000, 0, 0);
        assertEq(pool.priceAnchor(b, false), PRIME_PRICE * 1004 / 1000);
        assertEq(pool.priceAnchor(b, true), PRIME_PRICE, "only the traded direction moves");
        assertEq(pool.priceAnchor(a, false), 100_000_003);
        assertEq(pool.priceAnchor(PRIME_PAIR, false), PRIME_PRICE, "another pair on the same oracle keeps its anchor");
    }

    /// @dev Inventory is shared per token: pair 0's swaps use up the pathUSD pair 1 needs, which then reverts with
    /// the pool's whole balance as `available`.
    function test_pairsShareInventoryPerToken() external {
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
        uint256 keep = 15 * UNIT;
        pool.withdraw(address(pathUsd), stranger, pathUsd.balanceOf(address(pool)) - keep, bytes32(0));
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT);
        _expectSellRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.InsufficientInventory.selector, address(pathUsd), keep - PRIME_OUT, 10 * EUR_OUT
            ),
            EUR_PAIR,
            taker,
            HOME
        );
        // Selling pathUSD back on pair 0 refills what pair 1 can pay.
        vm.prank(taker);
        pool.swapExactInput(PRIME_PAIR, false, 7 * UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        assertEq(_sell(EUR_PAIR, taker, HOME), 10 * EUR_OUT);
    }

    // ---------------------------------------------------------------- quotes

    /// @dev Quotes ignore access and the pool-wide pause, and `quote*For` predicts the swap exactly.
    function test_quotesIgnoreAccessAndPause() external {
        (uint256 out, uint256 price, uint256 updatedAt) = pool.quoteExactInput(EUR_PAIR, taker, true, EUR_UNIT);
        assertEq(out, EUR_OUT);
        assertEq(price, EUR_PRICE);
        assertEq(updatedAt, block.timestamp);
        (uint256 amountIn,,) = pool.quoteExactOutput(PRIME_PAIR, taker, false, 10 * UNIT);
        assertEq(amountIn, PRIME_OUT);

        pool.closePair(EUR_PAIR);
        pool.pause();
        (uint256 closedOut,,) = pool.quoteExactInput(EUR_PAIR, taker, true, EUR_UNIT);
        assertEq(closedOut, EUR_OUT);
        (uint256 forOut,,, uint256 creditAfter) = pool.quoteExactInputFor(EUR_PAIR, taker, CUSTOMER, true, EUR_UNIT);
        assertEq(forOut, EUR_OUT);
        assertEq(creditAfter, 0);
        (uint256 forIn,,,) = pool.quoteExactOutputFor(PRIME_PAIR, taker, CUSTOMER, false, 10 * UNIT);
        assertEq(forIn, PRIME_OUT);
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        pool.quoteExactInput(EUR_PAIR, taker, true, 0);
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        pool.quoteExactOutputFor(EUR_PAIR, taker, CUSTOMER, true, 0);
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.quoteExactInputFor(EUR_PAIR, address(0), CUSTOMER, true, 1);
        vm.expectRevert(IManagedDirectPropAMM.CustomerIdIsZero.selector);
        pool.quoteExactOutputFor(EUR_PAIR, taker, bytes32(0), true, 1);
    }

    function test_roundingRouteKeyNamesThePairTheTakerAndTheCustomer() external view {
        assertEq(pool.roundingRouteKey(EUR_PAIR, taker, CUSTOMER), keccak256(abi.encode(EUR_PAIR, taker, CUSTOMER)));
        assertTrue(
            pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER) != pool.roundingRouteKey(EUR_PAIR, taker, CUSTOMER)
        );
        // An unknown pair still has a key; it never trades.
        assertEq(pool.roundingRouteKey(77, taker, CUSTOMER), keccak256(abi.encode(uint16(77), taker, CUSTOMER)));
    }

    function test_roundingRouteKeyRejectsZeroes() external {
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.roundingRouteKey(PRIME_PAIR, address(0), CUSTOMER);
        vm.expectRevert(IManagedDirectPropAMM.CustomerIdIsZero.selector);
        pool.roundingRouteKey(PRIME_PAIR, taker, bytes32(0));
    }

    // ---------------------------------------------------------------- fund

    /// @dev The owner funds any token a live pair uses, paused or not, with an exact credit; nobody else funds.
    function test_fundTakesALivePairsTokenPausedOrNot() external {
        pathUsd.mint(address(this), 2 * UNIT);
        pathUsd.approve(address(pool), type(uint256).max);
        for (uint256 p; p < 2; ++p) {
            if (p == 1) pool.pause();
            uint256 before = pathUsd.balanceOf(address(pool));
            vm.expectEmit(address(pool));
            emit IManagedDirectPropAMM.Funded(address(pathUsd), UNIT, bytes32("f"));
            pool.fund(address(pathUsd), UNIT, bytes32("f"));
            assertEq(pathUsd.balanceOf(address(pool)), before + UNIT);
        }
        MockTIP20 stray = new MockTIP20("STRAY", 6);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedToken.selector, address(stray)));
        pool.fund(address(stray), UNIT, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedToken.selector, address(0)));
        pool.fund(address(0), UNIT, bytes32(0));
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        pool.fund(address(pathUsd), 0, bytes32(0));
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(unauthorized);
        pool.fund(address(pathUsd), UNIT, bytes32(0));

        // The pool's credit must be exact.
        eurx.mint(address(this), EUR_UNIT);
        eurx.approve(address(pool), type(uint256).max);
        eurx.setFeeBps(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.ExactBalanceDeltaFailed.selector, address(eurx), EUR_UNIT, EUR_UNIT - 1e14
            )
        );
        pool.fund(address(eurx), EUR_UNIT, bytes32(0));
        eurx.setFeeBps(0);
        eurx.setReturnFalse(true);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.TokenTransferFailed.selector, address(eurx)));
        pool.fund(address(eurx), EUR_UNIT, bytes32(0));
    }

    // ---------------------------------------------------------------- withdraw: no TIP-1022 virtual recipient

    /// @dev A withdrawal to a TIP-1022 virtual address reverts `VirtualRecipient` with nothing moved, as v2 `Venue`
    /// refuses one: registered to a master (a Bridge liquidation address), registered to the pool, or unregistered,
    /// since the layout alone decides. The tokens forward a transfer to a registered one to its master, as Tempo's
    /// TIP-20 does, so it is the pool's check that refuses. On either pair's tokens, paused or not.
    function test_withdrawToAVirtualAddressReverts() external {
        address master = makeAddr("bridgeMaster");
        address liquidation = VirtualAddress.make(0x0badf00d, 1);
        address mastered = VirtualAddress.make(0x12345678, 9);
        address unregistered = VirtualAddress.make(0x0000beef, 1);
        registry.setVirtual(liquidation, master);
        registry.setVirtual(mastered, address(pool));
        address[3] memory recipients = [liquidation, mastered, unregistered];
        MockTIP20[2] memory tokens = [pathUsd, eurx];
        uint256[2] memory inventory = [pathUsd.balanceOf(address(pool)), eurx.balanceOf(address(pool))];
        for (uint256 paused; paused < 2; ++paused) {
            if (paused == 1) pool.pause();
            for (uint256 t; t < tokens.length; ++t) {
                for (uint256 r; r < recipients.length; ++r) {
                    vm.expectRevert(
                        abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, recipients[r])
                    );
                    pool.withdraw(address(tokens[t]), recipients[r], UNIT, bytes32("rebalance"));
                }
                assertEq(tokens[t].balanceOf(address(pool)), inventory[t], "nothing left the pool");
                assertEq(tokens[t].balanceOf(master), 0, "the master is not paid");
                assertEq(tokens[t].balanceOf(liquidation), 0);
            }
        }
    }

    /// @dev The supported way to pay a virtual address, such as a Bridge liquidation address: withdraw to an account,
    /// which gets its exact credit, then send from there; the token forwards that transfer to the master.
    function test_withdrawToAnAccountThenSendPaysAVirtualAddress() external {
        address master = makeAddr("bridgeMaster");
        address liquidation = VirtualAddress.make(0x0badf00d, 1);
        registry.setVirtual(liquidation, master);
        address treasury = makeAddr("treasury");
        uint256 inventory = pathUsd.balanceOf(address(pool));

        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.Withdrawn(address(pathUsd), treasury, 3 * UNIT, bytes32("rebalance"));
        vm.expectCall(
            address(pathUsd), abi.encodeCall(MockTIP20.transferWithMemo, (treasury, 3 * UNIT, bytes32("rebalance")))
        );
        pool.withdraw(address(pathUsd), treasury, 3 * UNIT, bytes32("rebalance"));
        assertEq(pathUsd.balanceOf(treasury), 3 * UNIT, "the account gets its exact credit");
        assertEq(pathUsd.balanceOf(address(pool)), inventory - 3 * UNIT);

        vm.prank(treasury);
        pathUsd.transferWithMemo(liquidation, 3 * UNIT, bytes32("rebalance"));
        assertEq(pathUsd.balanceOf(master), 3 * UNIT, "the master is paid");
        assertEq(pathUsd.balanceOf(liquidation), 0, "the virtual address holds nothing");
        // The master is an ordinary account, which the pool pays directly.
        pool.withdraw(address(eurx), master, EUR_UNIT, bytes32(0));
        assertEq(eurx.balanceOf(master), EUR_UNIT);
    }

    /// @dev A zero recipient and the pool revert `InvalidAddress`, before the virtual-address check; the token and
    /// amount checks come first. Nothing moves.
    function test_withdrawRejectsZeroAndThePool() external {
        uint256 inventory = pathUsd.balanceOf(address(pool));
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.withdraw(address(pathUsd), address(0), UNIT, bytes32(0));
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.withdraw(address(pathUsd), address(pool), UNIT, bytes32(0));
        address liquidation = VirtualAddress.make(0x0badf00d, 1);
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        pool.withdraw(address(pathUsd), liquidation, 0, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedToken.selector, address(0)));
        pool.withdraw(address(0), liquidation, UNIT, bytes32(0));
        assertEq(pathUsd.balanceOf(address(pool)), inventory);
    }

    /// @dev The pool's debit and the recipient's own credit must be exact, so a fee, a redirect or a park (a TIP-1028
    /// receive policy sends the funds elsewhere) reverts, and inventory bounds the amount.
    function test_withdrawChecksTheExactCredit() external {
        uint256 inventory = pathUsd.balanceOf(address(pool));
        pathUsd.setFeeBps(10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.ExactBalanceDeltaFailed.selector, address(pathUsd), 10 * UNIT, 10 * UNIT - 10_000
            )
        );
        pool.withdraw(address(pathUsd), stranger, 10 * UNIT, bytes32(0));
        pathUsd.setFeeBps(0);
        pathUsd.setRedirectRecipient(makeAddr("receivePolicyGuard"));
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.ExactBalanceDeltaFailed.selector, address(pathUsd), UNIT, 0)
        );
        pool.withdraw(address(pathUsd), stranger, UNIT, bytes32(0));
        pathUsd.setRedirectRecipient(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.InsufficientInventory.selector, address(pathUsd), inventory, inventory + 1
            )
        );
        pool.withdraw(address(pathUsd), stranger, inventory + 1, bytes32(0));
        assertEq(pathUsd.balanceOf(address(pool)), inventory);
    }

    /// @dev The owner withdraws any token, paused or not, in every mode, and a withdrawal only caps what later swaps
    /// can pay. Nobody else withdraws.
    function test_withdrawAnyTokenPausedOrNot() external {
        MockTIP20 stray = new MockTIP20("STRAY", 6);
        stray.mint(address(pool), UNIT);
        pool.withdraw(address(stray), stranger, UNIT, bytes32(0));
        assertEq(stray.balanceOf(stranger), UNIT, "a token no pair uses");
        pool.pause();
        pool.withdraw(address(prime), stranger, UNIT, bytes32(0));
        pool.unpause();
        pool.closePair(PRIME_PAIR);
        pool.withdraw(address(prime), stranger, UNIT, bytes32(0));
        assertEq(prime.balanceOf(stranger), 1_000_000 * UNIT + 2 * UNIT);

        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedToken.selector, address(0)));
        pool.withdraw(address(0), stranger, UNIT, bytes32(0));
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        pool.withdraw(address(prime), stranger, 0, bytes32(0));
        address[2] memory others = [unauthorized, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            vm.prank(others[i]);
            pool.withdraw(address(prime), others[i], UNIT, bytes32(0));
        }
    }

    /// @dev Every mode on either pair, paused or not: `withdraw` asks no list, sponsor, denial or mode, and reads no pool
    /// storage but the owner's slot and writes none, so it changes no access state, anchor or credit.
    function test_withdrawInEveryModeReadsOnlyTheOwner() external {
        _listHome(PRIME_PAIR, taker);
        _sell(PRIME_PAIR, taker, HOME);
        pool.setDenied(_one(stranger), true);
        bytes32 routeKey = pool.roundingRouteKey(PRIME_PAIR, taker, CUSTOMER);
        uint256 credit = pool.roundingCredit(routeKey);
        IManagedDirectPropAMM.AccessMode[3] memory modes = [
            IManagedDirectPropAMM.AccessMode.Listed,
            IManagedDirectPropAMM.AccessMode.Open,
            IManagedDirectPropAMM.AccessMode.Closed
        ];
        for (uint256 m; m < modes.length; ++m) {
            pool.pause();
            if (modes[m] == IManagedDirectPropAMM.AccessMode.Closed) pool.closePair(PRIME_PAIR);
            else pool.setPairAccess(PRIME_PAIR, modes[m]);
            for (uint256 paused; paused < 2; ++paused) {
                if (paused == 1) pool.unpause();
                uint256 before = prime.balanceOf(stranger);
                vm.record();
                pool.withdraw(address(prime), stranger, UNIT, bytes32("w"));
                (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(pool));
                assertEq(writes.length, 0, "pool storage writes");
                for (uint256 i; i < reads.length; ++i) {
                    assertEq(reads[i], bytes32(SLOT_WORD), "a read beside the owner's slot");
                }
                assertEq(prime.balanceOf(stranger), before + UNIT);
            }
        }
        assertEq(pool.priceAnchor(PRIME_PAIR, true), PRIME_PRICE);
        assertEq(pool.roundingCredit(routeKey), credit);
        assertTrue(pool.denied(stranger));
    }

    /// @dev A withdrawal changes no swap's price, only whether it fits. From the same state, a swap on either pair with
    /// and without a withdrawal of its output token before it pays and charges the same and leaves the same credit
    /// and anchor while its output fits what is left; otherwise it reverts `InsufficientInventory` with what is left.
    /// Withdrawing its input token, or a token only the other pair uses, changes nothing.
    function testFuzz_withdrawOnlyCapsCapacity(
        bool onEur,
        bool baseToQuote,
        bool exactInput,
        uint256 amount,
        uint256 left,
        uint256 otherWithdrawn,
        int16 move
    ) external {
        uint16 pairIndex = onEur ? EUR_PAIR : PRIME_PAIR;
        _listHome(pairIndex, taker);
        uint256 basePrice = onEur ? EUR_PRICE : PRIME_PRICE;
        uint256 price = uint256(int256(basePrice) + int256(basePrice) * bound(int256(move), -50, 50) / 10_000);
        _oracle(pairIndex).setPrice(price, block.timestamp);
        MockTIP20 base = onEur ? eurx : prime;
        MockTIP20 tokenIn = baseToQuote ? base : pathUsd;
        MockTIP20 tokenOut = baseToQuote ? pathUsd : base;
        // The other pair's base, or this pair's input: neither is this swap's output.
        MockTIP20 other = otherWithdrawn % 2 == 0 ? (onEur ? prime : eurx) : tokenIn;
        uint256 unit = 10 ** (exactInput ? tokenIn : tokenOut).decimals();
        amount = bound(amount, 1, 5_000 * unit);
        left = bound(left, 0, 20_000 * 10 ** tokenOut.decimals());
        otherWithdrawn = bound(otherWithdrawn, 0, other.balanceOf(address(pool)));
        bytes memory swap = exactInput
            ? abi.encodeCall(
                ManagedDirectPropAMM.swapExactInput,
                (pairIndex, baseToQuote, amount, 0, HOME, CUSTOMER, TRADE, block.timestamp, price, 0, 0)
            )
            : abi.encodeCall(
                ManagedDirectPropAMM.swapExactOutput,
                (pairIndex, baseToQuote, amount, type(uint256).max, HOME, CUSTOMER, TRADE, block.timestamp, price, 0, 0)
            );
        bytes32 routeKey = pool.roundingRouteKey(pairIndex, taker, CUSTOMER);

        uint256 snapshot = vm.snapshotState();
        vm.prank(taker);
        (bool filled, bytes memory ret) = address(pool).call(swap);
        uint256 creditAfter = pool.roundingCredit(routeKey);
        uint256 anchorAfter = pool.priceAnchor(pairIndex, baseToQuote);
        uint256 paidOut = tokenOut.balanceOf(taker);
        vm.revertToState(snapshot);

        pool.withdraw(address(tokenOut), stranger, tokenOut.balanceOf(address(pool)) - left, bytes32("w"));
        if (otherWithdrawn != 0) pool.withdraw(address(other), stranger, otherWithdrawn, bytes32("w"));
        uint256 outBefore = tokenOut.balanceOf(taker);
        vm.prank(taker);
        (bool filledAfter, bytes memory retAfter) = address(pool).call(swap);
        if (!filled) {
            assertFalse(filledAfter, "a withdrawal made a refused swap fill");
            assertEq(retAfter, ret);
            return;
        }
        uint256 amountOut = exactInput ? abi.decode(ret, (uint256)) : amount;
        if (amountOut <= left) {
            assertTrue(filledAfter, "a swap that fits reverted");
            assertEq(retAfter, ret, "the withdrawal changed the swap's amounts");
            assertEq(pool.roundingCredit(routeKey), creditAfter, "credit");
            assertEq(pool.priceAnchor(pairIndex, baseToQuote), anchorAfter, "anchor");
            assertEq(tokenOut.balanceOf(taker) - outBefore, paidOut - outBefore, "payout");
        } else {
            assertFalse(filledAfter);
            assertEq(
                retAfter,
                abi.encodeWithSelector(
                    IManagedDirectPropAMM.InsufficientInventory.selector, address(tokenOut), left, amountOut
                )
            );
        }
    }

    /// @dev A withdrawal only lowers what swaps can pay out, on every pair that uses the token: a swap that no longer
    /// fits reverts in full, one that fits fills at its quote, one for exactly what is left fills, and `fund` restores
    /// the capacity, all while trading.
    function test_swapAfterWithdrawSeesReducedInventory() external {
        _listHome(PRIME_PAIR, taker);
        _listHome(EUR_PAIR, taker);
        (uint256 quoted,,,) = pool.quoteExactInputFor(PRIME_PAIR, taker, CUSTOMER, true, 5 * UNIT);
        assertEq(quoted, PRIME_OUT / 2);
        uint256 inventory = pathUsd.balanceOf(address(pool));
        pool.withdraw(address(pathUsd), address(this), inventory - (PRIME_OUT - 1), bytes32("w"));
        bytes memory short = abi.encodeWithSelector(
            IManagedDirectPropAMM.InsufficientInventory.selector, address(pathUsd), PRIME_OUT - 1, PRIME_OUT
        );
        _expectSellRevert(short, PRIME_PAIR, taker, HOME);
        // The EUR pair shares the pathUSD: 10 EURX pays 10.85 pathUSD, more than is left.
        _expectSellRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.InsufficientInventory.selector, address(pathUsd), PRIME_OUT - 1, 10 * EUR_OUT
            ),
            EUR_PAIR,
            taker,
            HOME
        );
        assertEq(_sellFor(PRIME_PAIR, taker, HOME, CUSTOMER, 5 * UNIT), quoted, "half fits, as quoted");
        uint256 left = pathUsd.balanceOf(address(pool));
        assertEq(left, PRIME_OUT - 1 - quoted);
        (uint256 amountIn,,,) = pool.quoteExactOutputFor(EUR_PAIR, taker, bytes32("c2"), true, left);
        vm.prank(taker);
        assertEq(
            pool.swapExactOutput(
                EUR_PAIR, true, left, amountIn, HOME, bytes32("c2"), TRADE, block.timestamp, EUR_PRICE, 0, 0
            ),
            amountIn,
            "exactly what is left, on the other pair"
        );
        assertEq(pathUsd.balanceOf(address(pool)), 0);
        pathUsd.mint(address(this), PRIME_OUT);
        pathUsd.approve(address(pool), PRIME_OUT);
        pool.fund(address(pathUsd), PRIME_OUT, bytes32("f"));
        assertEq(_sell(PRIME_PAIR, taker, HOME), PRIME_OUT, "funding restores the capacity");
    }

    /// @dev Listed accounts and sponsor admins hold no pool role: every owner call refuses them.
    function test_listedAccountsAndSponsorAdminsHaveNoPoolRole() external {
        _addAlpha();
        _listHome(PRIME_PAIR, taker);
        _listAlpha(PRIME_PAIR, member);
        address[3] memory others = [taker, member, alpha];
        for (uint256 i; i < others.length; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Closed);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.closePair(PRIME_PAIR);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.setDenied(_one(stranger), true);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.setSponsorEnabled(ALPHA, false);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.setPairSponsor(PRIME_PAIR, ALPHA, false);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.pause();
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.unpause();
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.addSponsor(BETA, others[i]);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.resetSponsor(ALPHA, others[i]);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.setMembers(PRIME_PAIR, HOME, _one(others[i]), true);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.fund(address(prime), UNIT, bytes32(0));
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.withdraw(address(prime), others[i], UNIT, bytes32(0));
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, 0);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.removePair(PRIME_PAIR);
            vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
            pool.transferOwnership(others[i]);
            vm.stopPrank();
        }
        // The sponsor admin edits only its own list.
        vm.prank(alpha);
        pool.setMembers(PRIME_PAIR, ALPHA, _one(stranger), true);
        assertTrue(pool.isMember(PRIME_PAIR, ALPHA, stranger));
    }

    /// @dev `Open` keeps v1's checks after access: a zero `customerId` and a zero amount still revert.
    function test_openKeepsTheCustomerAndAmountChecks() external {
        _setAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        vm.expectRevert(IManagedDirectPropAMM.CustomerIdIsZero.selector);
        vm.prank(stranger);
        pool.swapExactInput(PRIME_PAIR, true, UNIT, 0, 4242, bytes32(0), TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        vm.expectRevert(IManagedDirectPropAMM.AmountIsZero.selector);
        vm.prank(stranger);
        pool.swapExactOutput(PRIME_PAIR, true, 0, 0, 4242, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        assertEq(_sell(PRIME_PAIR, stranger, 4242), PRIME_OUT, "any sponsor id, unchecked");
    }

    // ---------------------------------------------------------------- per-pair oracle isolation

    /// @dev A broken, stale, future-dated or drifted oracle on one pair reaches no other pair: the other pair's quotes
    /// return the same bytes and its swaps fill, while the broken pair refuses with v1's error for its own feed, and
    /// can't reopen until it gets a fresh feed (`setOracle` while `Closed`).
    function testFuzz_aBrokenOracleReachesNoOtherPair(uint8 kind, bool breakEur, uint256 amount) external {
        uint16 broken = breakEur ? EUR_PAIR : PRIME_PAIR;
        uint16 healthy = breakEur ? PRIME_PAIR : EUR_PAIR;
        _listHome(broken, taker);
        _listHome(healthy, taker);
        amount = bound(amount, 1, 1_000 * _baseUnit(healthy));
        bytes memory quoteCall = abi.encodeCall(IManagedDirectPropAMM.quoteExactInput, (healthy, taker, true, amount));
        bytes memory quoteForCall =
            abi.encodeCall(IManagedDirectPropAMM.quoteExactOutputFor, (healthy, taker, CUSTOMER, false, amount));
        bytes memory quoteBefore = _healthyQuote(quoteCall);
        bytes memory quoteForBefore = _healthyQuote(quoteForCall);

        MockOracle oracle = _oracle(broken);
        uint256 basePrice = breakEur ? EUR_PRICE : PRIME_PRICE;
        bytes memory expected;
        kind %= 4;
        if (kind == 0) {
            oracle.setPrice(0, block.timestamp);
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.InvalidPrice.selector);
        } else if (kind == 1) {
            oracle.setPrice(basePrice, START - 1);
            vm.warp(START + MAX_AGE);
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, START - 1, MAX_AGE);
            _oracle(healthy).setPrice(breakEur ? PRIME_PRICE : EUR_PRICE, START + MAX_AGE);
        } else if (kind == 2) {
            oracle.setPrice(basePrice, START + 1);
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.FutureOracleTimestamp.selector, START + 1, START);
        } else {
            oracle.setPrice(basePrice * 2, block.timestamp);
            expected = abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector, true, basePrice * 2, basePrice, MAX_DEVIATION_BPS
            );
        }
        (bool ok, bytes memory ret) =
            address(pool).staticcall(abi.encodeCall(IManagedDirectPropAMM.quoteExactInput, (broken, taker, true, UNIT)));
        assertFalse(ok);
        assertEq(ret, expected, "the broken pair's own error");
        (uint256 price,) = oracle.latestPrice();
        vm.expectRevert(expected);
        vm.prank(taker);
        pool.swapExactInput(broken, true, UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, price, 0, 0);

        // The healthy pair: the same quotes (kind 1 moves the clock and refreshes its feed at the same price).
        bytes memory quoteAfter = _healthyQuote(quoteCall);
        bytes memory quoteForAfter = _healthyQuote(quoteForCall);
        if (kind != 1) {
            assertEq(quoteAfter, quoteBefore, "another pair's quote moved");
            assertEq(quoteForAfter, quoteForBefore, "another pair's quote moved");
        } else {
            (uint256 outBefore,,) = abi.decode(quoteBefore, (uint256, uint256, uint256));
            (uint256 outAfter,,) = abi.decode(quoteAfter, (uint256, uint256, uint256));
            assertEq(outAfter, outBefore, "another pair's price moved");
        }
        _sell(healthy, taker, HOME);

        // Closing the broken pair and reopening it re-validates its feed; a fresh feed lets it reopen.
        pool.closePair(broken);
        vm.expectRevert(expected);
        pool.setPairAccess(broken, IManagedDirectPropAMM.AccessMode.Listed);
        MockOracle fresh = new MockOracle(8, basePrice, block.timestamp);
        pool.setOracle(broken, fresh);
        pool.setPairAccess(broken, IManagedDirectPropAMM.AccessMode.Listed);
        vm.prank(taker);
        pool.swapExactInput(broken, true, _baseUnit(broken), 0, HOME, CUSTOMER, TRADE, block.timestamp, basePrice, 0, 0);
    }

    /// @dev Swaps pay only their caller: whoever calls, on either pair, either way, exact in or out, the caller gets
    /// exactly the output and pays exactly the input, the pool the reverse, and no other account's balance of any
    /// token moves.
    function testFuzz_swapsPayOnlyTheirCaller(uint8 who, bool onEur, bool baseToQuote, bool exactInput, uint256 amount)
        external
    {
        address[3] memory callers = [taker, member, stranger];
        address from = callers[who % 3];
        uint16 pairIndex = onEur ? EUR_PAIR : PRIME_PAIR;
        _listHome(pairIndex, from);
        MockTIP20 base = onEur ? eurx : prime;
        MockTIP20 tokenIn = baseToQuote ? base : pathUsd;
        MockTIP20 tokenOut = baseToQuote ? pathUsd : base;
        amount = bound(amount, 1, 1_000 * 10 ** (exactInput ? tokenIn : tokenOut).decimals());
        address[6] memory holders = [taker, member, stranger, unauthorized, address(this), address(pool)];
        MockTIP20[3] memory tokens = [prime, pathUsd, eurx];
        uint256[3][6] memory before;
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 t; t < tokens.length; ++t) {
                before[h][t] = tokens[t].balanceOf(holders[h]);
            }
        }
        (uint256 price,) = _oracle(pairIndex).latestPrice();
        vm.prank(from);
        (bool ok, bytes memory ret) = address(pool)
            .call(
                exactInput
                    ? abi.encodeCall(
                        ManagedDirectPropAMM.swapExactInput,
                        (pairIndex, baseToQuote, amount, 0, HOME, CUSTOMER, TRADE, block.timestamp, price, 0, 0)
                    )
                    : abi.encodeCall(
                        ManagedDirectPropAMM.swapExactOutput,
                        (
                            pairIndex,
                            baseToQuote,
                            amount,
                            type(uint256).max,
                            HOME,
                            CUSTOMER,
                            TRADE,
                            block.timestamp,
                            price,
                            0,
                            0
                        )
                    )
            );
        if (!ok) {
            // Only a dust exact input, which buys nothing.
            assertEq(ret, abi.encodeWithSelector(IManagedDirectPropAMM.AmountIsZero.selector));
            return;
        }
        uint256 amountIn = exactInput ? amount : abi.decode(ret, (uint256));
        uint256 amountOut = exactInput ? abi.decode(ret, (uint256)) : amount;
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 t; t < tokens.length; ++t) {
                uint256 expected = before[h][t];
                if (holders[h] == from) {
                    if (tokens[t] == tokenIn) expected -= amountIn;
                    if (tokens[t] == tokenOut) expected += amountOut;
                } else if (holders[h] == address(pool)) {
                    if (tokens[t] == tokenIn) expected += amountIn;
                    if (tokens[t] == tokenOut) expected -= amountOut;
                }
                assertEq(tokens[t].balanceOf(holders[h]), expected, "a balance moved for someone other than the caller");
            }
        }
    }

    // ---------------------------------------------------------------- locks

    /// @dev Calls the pool as its owner (this contract), for a token's re-entry.
    function callAsOwner(address target, bytes calldata data) external returns (bytes memory) {
        return Address.functionCall(target, data);
    }

    /// @dev A token that calls back from inside a withdrawal's payout can't swap, withdraw again or fund: the lock the
    /// swaps share stops it, and the withdrawal still moves exactly its amount.
    function test_withdrawPayoutCannotReenter() external {
        MockReentrantTIP20 base = new MockReentrantTIP20("BASE", 6);
        ManagedDirectPropAMM reentered = _reentrantPool(base);
        address[3] memory targets = [address(reentered), address(this), address(this)];
        bytes[3] memory calls = [
            abi.encodeCall(
                ManagedDirectPropAMM.swapExactInput,
                (0, false, UNIT, 0, HOME, bytes32("c1"), TRADE, block.timestamp, PRIME_PRICE, 0, 0)
            ),
            abi.encodeCall(
                this.callAsOwner,
                (
                    address(reentered),
                    abi.encodeCall(ManagedDirectPropAMM.withdraw, (address(base), stranger, UNIT, bytes32("again")))
                )
            ),
            abi.encodeCall(
                this.callAsOwner,
                (address(reentered), abi.encodeCall(ManagedDirectPropAMM.fund, (address(pathUsd), UNIT, bytes32("f"))))
            )
        ];
        for (uint256 i; i < calls.length; ++i) {
            base.setReentry(targets[i], calls[i]);
            uint256 poolBefore = base.balanceOf(address(reentered));
            uint256 strangerBefore = base.balanceOf(stranger);
            reentered.withdraw(address(base), stranger, 10 * UNIT, bytes32("w"));
            assertEq(base.reentryTarget(), address(0), "the payout did not call back");
            assertFalse(base.reentrySucceeded(), "re-entered");
            assertEq(
                base.reentryResult(),
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
                "not stopped by the lock"
            );
            assertEq(base.balanceOf(address(reentered)), poolBefore - 10 * UNIT, "pool debit");
            assertEq(base.balanceOf(stranger), strangerBefore + 10 * UNIT, "recipient credit");
        }
    }

    /// @dev A token that calls back from inside a swap's input pull can't have the owner withdraw the output mid-swap,
    /// swap again, or change access: every pool mutation shares the swap lock.
    function test_swapPullCannotReenter() external {
        MockReentrantTIP20 base = new MockReentrantTIP20("BASE", 6);
        ManagedDirectPropAMM reentered = _reentrantPool(base);
        reentered.setMembers(0, HOME, _one(taker), true);
        base.mint(taker, 100 * UNIT);
        vm.prank(taker);
        base.approve(address(reentered), type(uint256).max);
        uint256 inventory = pathUsd.balanceOf(address(reentered));

        base.setReentry(
            address(this),
            abi.encodeCall(
                this.callAsOwner,
                (
                    address(reentered),
                    abi.encodeCall(ManagedDirectPropAMM.withdraw, (address(pathUsd), stranger, inventory, bytes32("w")))
                )
            )
        );
        vm.prank(taker);
        reentered.swapExactInput(0, true, 10 * UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        assertFalse(base.reentrySucceeded(), "withdrew mid-swap");
        assertEq(
            base.reentryResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "not stopped by the lock"
        );
        assertEq(pathUsd.balanceOf(address(reentered)), inventory - PRIME_OUT);
        assertEq(pathUsd.balanceOf(stranger), 1_000_000 * UNIT);

        // The token itself can't touch access mid-swap: administrative mutations share the lock.
        base.setReentry(
            address(reentered), abi.encodeCall(ManagedDirectPropAMM.setMembers, (0, HOME, _one(stranger), true))
        );
        vm.prank(taker);
        reentered.swapExactInput(0, true, 10 * UNIT, 0, HOME, CUSTOMER, TRADE, block.timestamp, PRIME_PRICE, 0, 0);
        assertEq(
            base.reentryResult(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertFalse(reentered.isMember(0, HOME, stranger));
    }

    // ---------------------------------------------------------------- roles

    /// @dev Every owner power moves at `acceptOwnership`; no previous owner keeps narrowing powers.
    function test_ownershipIsTwoStepAndMovesEveryOwnerPower() external {
        address next = makeAddr("nextOwner");
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.transferOwnership(address(0));
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.OwnershipTransferStarted(address(this), next);
        pool.transferOwnership(next);
        assertEq(pool.pendingOwner(), next);
        vm.expectRevert(IManagedDirectPropAMM.NotPendingOwner.selector);
        vm.prank(stranger);
        pool.acceptOwnership();
        pool.setMembers(PRIME_PAIR, HOME, _one(taker), true);
        pool.setDenied(_one(stranger), true);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.OwnershipTransferred(address(this), next);
        vm.prank(next);
        pool.acceptOwnership();
        assertEq(pool.owner(), next);
        assertEq(pool.deniedCount(), 1, "deny count kept");
        assertFalse(pool.paused(), "pause kept");
        assertEq(pool.pendingOwner(), address(0));
        assertEq(pool.pairCount(), 2, "pairCount kept");
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, 0);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setMembers(PRIME_PAIR, HOME, _one(stranger), true);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.withdraw(address(prime), stranger, UNIT, bytes32(0));
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.pause();
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.closePair(PRIME_PAIR);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setDenied(_one(taker), true);
        vm.startPrank(next);
        pool.setMembers(PRIME_PAIR, HOME, _one(stranger), true);
        pool.closePair(PRIME_PAIR);
        pool.pause();
        vm.stopPrank();
        assertTrue(pool.paused());
    }

    function test_narrowingOperationsRequireTheCurrentOwner() external {
        _addAlpha();
        vm.startPrank(unauthorized);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.pause();
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.closePair(PRIME_PAIR);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setDenied(_one(taker), true);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setSponsorEnabled(ALPHA, false);
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        pool.setPairSponsor(PRIME_PAIR, ALPHA, false);
        vm.stopPrank();
        assertFalse(pool.paused());
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Listed));
        assertFalse(pool.denied(taker));
        pool.setSponsorEnabled(ALPHA, false);
        pool.setPairSponsor(PRIME_PAIR, ALPHA, false);
        pool.setDenied(_one(taker), true);
        pool.closePair(PRIME_PAIR);
        pool.pause();
        assertTrue(pool.paused());
        assertTrue(pool.denied(taker));
    }

    /// @dev Priority fees do not affect managed access, quotes or execution, even above the former default cap.
    function test_allowedTakerFillsAtHighPriorityFee() external {
        _listHome(PRIME_PAIR, taker);
        address tempoPathUsd = 0x20C0000000000000000000000000000000000000;
        if (tempoPathUsd.code.length != 0) {
            // Forge's local Tempo genesis grants the test contract pathUSD's issuer role. The mock trade
            // tokens cannot pay real transaction fees for the isolated, pranked taker call.
            (bool funded,) = tempoPathUsd.call(abi.encodeWithSignature("mint(address,uint256)", taker, 1_000 * UNIT));
            assertTrue(funded, "fund the taker's real Tempo fee token");
        }
        vm.fee(7);
        vm.txGasPrice(11 gwei);
        assertTrue(pool.takerAllowed(PRIME_PAIR, taker, HOME));
        assertEq(uint8(pool.takerAccess(PRIME_PAIR, taker, HOME)), uint8(IManagedDirectPropAMM.TakerAccess.Allowed));
        (uint256 quoted,,) = pool.quoteExactInput(PRIME_PAIR, taker, true, 10 * UNIT);
        assertEq(quoted, PRIME_OUT);
        assertGt(tx.gasprice - block.basefee, 10 gwei, "above the removed default cap");
        assertEq(_sell(PRIME_PAIR, taker, HOME), quoted);
        assertEq(tx.gasprice, 11 gwei, "fill kept the high gas price");
        // Restore the harness transaction's price only after testing the high-fee access, quote and fill.
        vm.txGasPrice(0);
    }

    function test_removedGuardianAndPriorityFeeSelectorsAreAbsent() external {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeWithSignature("guardian()");
        calls[1] = abi.encodeWithSignature("setGuardian(address)", unauthorized);
        calls[2] = abi.encodeWithSignature("maxTakerPriorityFee()");
        calls[3] = abi.encodeWithSignature("setMaxTakerPriorityFee(uint64)", uint64(0));
        calls[4] = abi.encodeWithSignature("enableTakerPriorityFeeCap()");
        calls[5] = abi.encodeWithSignature("NO_PRIORITY_FEE_CAP()");
        calls[6] = abi.encodeWithSignature("DEFAULT_TAKER_PRIORITY_FEE_CAP()");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(pool).call(calls[i]);
            assertFalse(ok, "removed selector succeeded");
            assertEq(ret.length, 0, "unknown selector should revert without a role error");
        }
    }

    // ---------------------------------------------------------------- storage layout

    /// @dev Slot 0 packs pause, deny count, owner and pair count; a pair occupies three slots.
    function test_storageLayout() external {
        address[] memory accounts = _accounts(3);
        pool.setDenied(accounts, true);
        pool.pause();
        uint256 word = uint256(vm.load(address(pool), bytes32(SLOT_WORD)));
        assertEq(word & 0xff, 1, "paused");
        assertEq((word >> 8) & 0xffffff, 3, "deniedCount");
        assertEq(address(uint160(word >> 32)), address(this), "owner");
        assertEq((word >> 192) & 0xffff, 2, "pairCount");
        assertEq(word >> 208, 0, "unused high bits");

        pool.transferOwnership(stranger);
        assertEq(address(uint160(uint256(vm.load(address(pool), bytes32(SLOT_PENDING_OWNER))))), stranger);

        bytes32 base = keccak256(abi.encode(uint256(EUR_PAIR), SLOT_PAIRS));
        uint256 a = uint256(vm.load(address(pool), base));
        assertEq(address(uint160(a)), address(eurx), "base");
        assertEq((a >> 160) & 0xff, uint256(IManagedDirectPropAMM.AccessMode.Listed), "access beside the base");
        assertEq((a >> 168) & 0xff, 18, "base decimals");
        assertEq((a >> 176) & 0xff, 6, "quote decimals");
        assertEq((a >> 184) & 0xff, 8, "oracle decimals");
        assertEq((a >> 192) & 0xff, 20, "scale exponent");
        assertEq(a >> 200, 0, "nothing after the exponent");
        uint256 b = uint256(vm.load(address(pool), bytes32(uint256(base) + 1)));
        assertEq(b, uint256(uint160(address(pathUsd))), "quote alone");
        uint256 c = uint256(vm.load(address(pool), bytes32(uint256(base) + 2)));
        assertEq(address(uint160(c)), address(eurOracle), "oracle");
        assertEq((c >> 160) & 0xffff, MAX_DEVIATION_BPS, "deviation beside the oracle");
        assertEq(c >> 176, MAX_AGE, "age last");

        bytes32 anchors = keccak256(abi.encode(uint256(EUR_PAIR), SLOT_ANCHORS));
        assertEq(uint256(vm.load(address(pool), anchors)), EUR_PRICE, "baseToQuote anchor");
        assertEq(uint256(vm.load(address(pool), bytes32(uint256(anchors) + 1))), EUR_PRICE, "quoteToBase anchor");
        assertEq(
            uint256(vm.load(address(pool), keccak256(abi.encode(address(pathUsd), SLOT_TOKEN_PAIRS)))), 2, "pair count"
        );
        assertEq(uint256(vm.load(address(pool), keccak256(abi.encode(accounts[0], SLOT_DENIED)))), 1, "denied");
        assertEq(SLOT_CREDITS, 4);
    }

    /// @dev A swap reads slot 0 for the pause and deny count, and the three pair slots.
    function test_aSwapReadsThePairsThreeSlotsAndSlotZero() external {
        _listHome(EUR_PAIR, taker);
        vm.record();
        _sell(EUR_PAIR, taker, HOME);
        (bytes32[] memory reads,) = vm.accesses(address(pool));
        bytes32 base = keccak256(abi.encode(uint256(EUR_PAIR), SLOT_PAIRS));
        bool[4] memory seen;
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i] == bytes32(SLOT_WORD)) seen[0] = true;
            for (uint256 k; k < 3; ++k) {
                if (reads[i] == bytes32(uint256(base) + k)) seen[k + 1] = true;
            }
            assertTrue(reads[i] != bytes32(SLOT_PENDING_OWNER), "no pending owner read");
        }
        for (uint256 k; k < 4; ++k) {
            assertTrue(seen[k]);
        }
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A quote view call on the healthy pair, which must price.
    function _healthyQuote(bytes memory data) internal view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(pool).staticcall(data);
        assertTrue(ok, "the healthy pair's quote reverted");
    }

    /// @dev A pool whose only pair's base re-enters on its next transfer, funded and open on its home list.
    function _reentrantPool(MockReentrantTIP20 base) internal returns (ManagedDirectPropAMM reentered) {
        reentered = new ManagedDirectPropAMM(address(this), address(0));
        MockOracle oracle = new MockOracle(8, PRIME_PRICE, block.timestamp);
        reentered.addPair(address(base), address(pathUsd), oracle, MAX_AGE, MAX_DEVIATION_BPS);
        reentered.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        base.mint(address(reentered), 1_000 * UNIT);
        pathUsd.mint(address(reentered), 1_000 * UNIT);
        reentered.unpause();
    }
}

/// @notice A TIP-20 stand-in whose payouts take one unit more from the sender than they credit, for the pool's exact
/// debit check.
contract OverdebitTIP20 {
    uint8 public constant decimals = 6;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        balanceOf[msg.sender] -= amount + 1;
        balanceOf[to] += amount;
    }
}
