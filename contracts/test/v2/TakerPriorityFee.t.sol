// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { VenueFixture } from "./utils/VenueFixture.sol";

/// @notice The venue's taker priority-fee cap: `fill` and `quote` revert `TakerPriorityFeeTooHigh` when the
/// transaction's priority fee per gas, `tx.gasprice - block.basefee`, is above `maxTakerPriorityFee`, so a take can't
/// outbid the maker's `post` in a block ordered by priority fee. The check is the first step of the fill's access
/// check, after pricing and before every check on the taker, so `takerAccess` reports it (`PriorityFeeTooHigh`) and
/// `takerAllowed` is false for it, reading the calling transaction's own fee. The owner or an updater sets it to any
/// value, or to `DEFAULT_TAKER_PRIORITY_FEE_CAP` (10 gwei) with `enableTakerPriorityFeeCap`. A new venue has none.
/// `VenueAccessReasons` holds each outcome to real `Settler` swaps.
contract TakerPriorityFeeTest is VenueFixture {
    /// @dev Moderato's base fee at the time of writing, 0.6 gwei.
    uint256 internal constant BASE_FEE = 600_000_000;
    uint64 internal constant CAP = 2 gwei;
    uint64 internal constant NO_CAP = type(uint64).max;
    uint64 internal constant DEFAULT_CAP = 10_000_000_000;
    uint128 internal constant AMOUNT = 1e6;
    /// @dev `_invertedFeeCap`, after `settler`, `halted` and the deny count in the settler's slot, as
    /// `test_capPacksIntoTheSettlerSlot` here and `test_accessWordLayout` (test/v2/VenueAccess.t.sol) pin it.
    uint256 internal constant FEE_CAP_SHIFT = 192;
    uint256 internal constant DENIED_COUNT_SHIFT = 168;
    uint256 internal constant HALTED_SHIFT = 160;

    function setUp() public override {
        super.setUp();
        vm.fee(BASE_FEE);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Default
    // ---------------------------------------------------------------------------------------------------------------

    function test_noCapByDefault() public {
        assertEq(venue.NO_PRIORITY_FEE_CAP(), NO_CAP);
        assertEq(venue.maxTakerPriorityFee(), NO_CAP);
        assertEq(uint256(vm.load(address(venue), bytes32(SLOT_SETTLER))) >> FEE_CAP_SHIFT, 0, "nothing stored");
        // Any priority fee fills, up to the highest gas price `vm.txGasPrice` takes (a uint64).
        vm.txGasPrice(NO_CAP);
        _fillEverySide();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The check
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Every side and both kinds of amount, through `fill` and `quote`.
    function test_fillsAtOrBelowTheCapAndRevertsAbove() public {
        _setCap(owner, CAP);
        vm.txGasPrice(BASE_FEE + CAP);
        _fillEverySide();
        vm.txGasPrice(BASE_FEE + CAP - 1);
        _fillEverySide();
        vm.txGasPrice(BASE_FEE);
        _fillEverySide();
        vm.txGasPrice(BASE_FEE + CAP + 1);
        _expectEverySideReverts(uint256(CAP) + 1, CAP);
        vm.txGasPrice(NO_CAP);
        _expectEverySideReverts(NO_CAP - BASE_FEE, CAP);
    }

    /// @dev A zero cap admits only transactions that pay no priority fee.
    function test_zeroCapAdmitsOnlyNoPriorityFee() public {
        _setCap(owner, 0);
        assertEq(venue.maxTakerPriorityFee(), 0);
        vm.txGasPrice(BASE_FEE);
        _fillEverySide();
        vm.txGasPrice(BASE_FEE + 1);
        _expectEverySideReverts(1, 0);
    }

    /// @dev A gas price below the base fee, as in a call simulated without fees, counts as paying no priority fee.
    function test_gasPriceBelowTheBaseFeeCountsAsNoPriorityFee() public {
        _setCap(owner, 0);
        vm.txGasPrice(BASE_FEE - 1);
        _fillEverySide();
        vm.txGasPrice(0);
        _fillEverySide();
        vm.fee(0);
        vm.txGasPrice(0);
        _fillEverySide();
    }

    /// @dev The caller and `halted` come first, then pricing, then the cap, then the taker: an over-cap take reverts
    /// on the pricing error for an unknown pair, the wrong tokens or an expired quote, and on its fee whatever the
    /// taker's access says. `quote`, which has no taker, checks the cap at the same point.
    function test_checkOrder() public {
        _setCap(owner, CAP);
        vm.txGasPrice(BASE_FEE + CAP + 1);
        bytes memory tooHigh = abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, uint256(CAP) + 1, CAP);
        bytes memory unknown = abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(77));
        vm.expectRevert(unknown);
        vm.prank(settler);
        venue.fill(77, address(eur), address(usd), AMOUNT, true, taker, HOME, REF);
        vm.expectRevert(unknown);
        venue.quote(77, address(eur), address(usd), AMOUNT, true);
        assertEq(uint256(venue.takerAccess(77, taker, HOME)), uint256(IVenue.TakerAccess.UnknownPair));
        vm.expectRevert(abi.encodeWithSelector(IVenue.TokenMismatch.selector, address(usd), address(usd)));
        venue.quote(pairId, address(usd), address(usd), AMOUNT, true);

        // After pricing, the fee outranks every refusal of the taker: a denial, a `Closed` pair, an unlisted taker.
        _expectReverts(tooHigh, true, true);
        vm.prank(owner);
        venue.setDenied(_one(taker), true);
        _expectReverts(tooHigh, true, true);
        _setAccess(pairId, IVenue.AccessMode.Listed);
        _expectReverts(tooHigh, true, true);
        vm.prank(updater);
        venue.closePair(pairId);
        _expectReverts(tooHigh, false, false);
        assertEq(uint256(venue.takerAccess(pairId, taker, HOME)), uint256(IVenue.TakerAccess.PriorityFeeTooHigh));
        // At the cap, the taker's own refusal shows: the pair is `Closed`.
        vm.txGasPrice(BASE_FEE + CAP);
        assertEq(uint256(venue.takerAccess(pairId, taker, HOME)), uint256(IVenue.TakerAccess.Closed));
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker));
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker, HOME, REF);

        vm.txGasPrice(BASE_FEE + CAP + 1);
        _setAccess(pairId, IVenue.AccessMode.Open);
        vm.warp(START + TTL + 1);
        _expectReverts(abi.encodeWithSelector(IVenue.QuoteExpired.selector, uint40(START + TTL)), true, true);
        vm.prank(updater);
        venue.setHalted(true);
        _expectReverts(abi.encodeWithSelector(IVenue.VenueHalted.selector), true, true);
        // Only the settler fills, whatever the fee.
        vm.expectRevert(IVenue.NotSettler.selector);
        vm.prank(stranger);
        venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker, HOME, REF);
    }

    /// @dev `takerAccess` and `takerAllowed` read the cap against the calling transaction's own priority fee, whoever
    /// the taker and whatever the sponsor id; a call with no gas price, as an `eth_call` without fee fields has, sees
    /// none, so it can't report the cap.
    function test_viewsReadTheCallsOwnFee() public {
        _setCap(owner, CAP);
        address[2] memory who = [taker, stranger];
        uint64[2] memory ids = [HOME, uint64(42)];
        for (uint256 i; i < 4; ++i) {
            (address account, uint64 id) = (who[i & 1], ids[i >> 1]);
            vm.txGasPrice(BASE_FEE + CAP + 1);
            assertEq(uint256(venue.takerAccess(pairId, account, id)), uint256(IVenue.TakerAccess.PriorityFeeTooHigh));
            assertFalse(venue.takerAllowed(pairId, account, id));
            vm.txGasPrice(BASE_FEE + CAP);
            assertEq(uint256(venue.takerAccess(pairId, account, id)), uint256(IVenue.TakerAccess.Allowed));
            assertTrue(venue.takerAllowed(pairId, account, id));
            vm.txGasPrice(0);
            assertEq(uint256(venue.takerAccess(pairId, account, id)), uint256(IVenue.TakerAccess.Allowed));
        }
        // A cap of 0 still admits a call without fees, which an over-cap swap would then fail on-chain.
        _setCap(owner, 0);
        vm.txGasPrice(0);
        assertTrue(venue.takerAllowed(pairId, taker, HOME));
        vm.txGasPrice(BASE_FEE + 1);
        assertFalse(venue.takerAllowed(pairId, taker, HOME));
        // An unknown pair is `UnknownPair` whatever the fee.
        assertEq(uint256(venue.takerAccess(77, taker, HOME)), uint256(IVenue.TakerAccess.UnknownPair));
    }

    /// @dev One venue-wide cap binds every pair.
    function test_capBindsEveryPair() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        vm.startPrank(owner);
        uint16 second = venue.addPair(address(gbp), address(usd), UNIT);
        venue.setShape(second, 0, _defaultShape());
        vm.stopPrank();
        _setAccess(second, IVenue.AccessMode.Open);
        _post(second, _hot(2));
        _setCap(owner, CAP);
        vm.txGasPrice(BASE_FEE + CAP + 1);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, uint256(CAP) + 1, CAP));
        venue.quote(second, address(gbp), address(usd), AMOUNT, true);
        vm.txGasPrice(BASE_FEE + CAP);
        venue.quote(second, address(gbp), address(usd), AMOUNT, true);
    }

    /// @dev Fills exactly when the priority fee is at most the cap, around the boundary, from either function, on any
    /// side, whatever the base fee.
    function testFuzz_capBoundary(uint64 cap, uint64 baseFee, int8 offset, bool baseIn, bool exactIn) public {
        cap = uint64(bound(cap, 0, NO_CAP - 3));
        // The gas price, the base fee plus up to `cap + 3`, stays a uint64.
        baseFee = uint64(bound(baseFee, 0, NO_CAP - cap - 3));
        int256 tip = int256(uint256(cap)) + bound(offset, -3, 3);
        if (tip < 0) tip = 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(tip);
        _setCap(owner, cap);
        vm.fee(baseFee);
        vm.txGasPrice(uint256(baseFee) + fee);
        _checkTake(fee > cap, fee, cap, baseIn, exactIn);
    }

    /// @dev Any gas price against any base fee: a gas price at or below the base fee always fills.
    function testFuzz_anyGasPrice(uint64 cap, uint64 baseFee, uint64 gasPrice, bool baseIn, bool exactIn) public {
        cap = uint64(bound(cap, 0, NO_CAP - 1));
        _setCap(owner, cap);
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        uint256 fee = gasPrice > baseFee ? gasPrice - baseFee : 0;
        _checkTake(fee > cap, fee, cap, baseIn, exactIn);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Setting the cap
    // ---------------------------------------------------------------------------------------------------------------

    function test_ownerRaisesLowersAndRemovesTheCap() public {
        _raiseLowerAndRemove(owner);
    }

    /// @dev The cap is a quoting setting, not an access one, so an updater sets it as the owner does.
    function test_updaterRaisesLowersAndRemovesTheCap() public {
        _raiseLowerAndRemove(updater);
    }

    /// @dev The owner and an updater each move the cap the other set, either way.
    function test_ownerAndUpdaterOverrideEachOther() public {
        _setCap(owner, 1 gwei);
        vm.expectEmit(address(venue));
        emit IVenue.MaxTakerPriorityFeeSet(1 gwei, 10 gwei, updater);
        _setCap(updater, 10 gwei);
        vm.expectEmit(address(venue));
        emit IVenue.MaxTakerPriorityFeeSet(10 gwei, 2 gwei, owner);
        _setCap(owner, 2 gwei);
        vm.expectEmit(address(venue));
        emit IVenue.MaxTakerPriorityFeeSet(2 gwei, NO_CAP, updater);
        _setCap(updater, NO_CAP);
        assertEq(venue.maxTakerPriorityFee(), NO_CAP);
    }

    /// @dev Anyone else is refused, an updater the owner has removed included.
    function test_onlyTheOwnerOrAnUpdaterSetsTheCap() public {
        vm.prank(owner);
        venue.setUpdater(updater, false);
        address[4] memory others = [stranger, settler, taker, updater];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
            vm.prank(others[i]);
            venue.setMaxTakerPriorityFee(0);
            vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
            vm.prank(others[i]);
            venue.setMaxTakerPriorityFee(NO_CAP);
        }
        assertEq(venue.maxTakerPriorityFee(), NO_CAP);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The default cap
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev 10 gwei per gas: a 100,000-gas swap tipping at the cap pays 1,000 units of a 6-decimal stablecoin
    /// (`gas * gasPrice / 1e12`), 0.1 cent. It isn't a new venue's cap.
    function test_defaultCapValue() public view {
        assertEq(venue.DEFAULT_TAKER_PRIORITY_FEE_CAP(), DEFAULT_CAP);
        assertEq(DEFAULT_CAP, 10 gwei);
        assertEq(uint256(100_000) * DEFAULT_CAP / 1e12, 1000, "0.1 cent on a 100k-gas swap");
        assertEq(venue.maxTakerPriorityFee(), NO_CAP, "a new venue is uncapped");
    }

    function test_ownerEnablesTheDefaultCap() public {
        _enableFromAnyCap(owner);
    }

    /// @dev An updater enables it as it sets any other cap.
    function test_updaterEnablesTheDefaultCap() public {
        _enableFromAnyCap(updater);
    }

    /// @dev The default is an ordinary cap: the inverted value in the settler's slot, which `setMaxTakerPriorityFee`
    /// moves again, from the other role.
    function test_defaultCapIsAnOrdinaryCap() public {
        _enable(updater);
        uint256 word = uint256(vm.load(address(venue), bytes32(SLOT_SETTLER)));
        assertEq(word >> FEE_CAP_SHIFT, uint256(~DEFAULT_CAP), "the inverted cap");
        assertEq(address(uint160(word)), settler, "settler");
        vm.expectEmit(address(venue));
        emit IVenue.MaxTakerPriorityFeeSet(DEFAULT_CAP, NO_CAP, owner);
        _setCap(owner, NO_CAP);
        assertEq(uint256(vm.load(address(venue), bytes32(SLOT_SETTLER))) >> FEE_CAP_SHIFT, 0, "uncapped");
        vm.txGasPrice(NO_CAP);
        _fillEverySide();
    }

    /// @dev Anyone else is refused, an updater the owner has removed included, as for `setMaxTakerPriorityFee`.
    function test_onlyTheOwnerOrAnUpdaterEnablesTheDefaultCap() public {
        vm.prank(owner);
        venue.setUpdater(updater, false);
        address[4] memory others = [stranger, settler, taker, updater];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
            vm.prank(others[i]);
            venue.enableTakerPriorityFeeCap();
        }
        assertEq(venue.maxTakerPriorityFee(), NO_CAP);
    }

    /// @dev At the default cap a take fills up to a 10 gwei priority fee, on every side through `fill` and `quote`,
    /// and one wei more reverts, which `takerAccess` and `takerAllowed` report.
    function test_fillsAtTheDefaultCapAndRevertsAbove() public {
        _enable(owner);
        vm.txGasPrice(BASE_FEE + DEFAULT_CAP);
        assertEq(uint256(venue.takerAccess(pairId, taker, HOME)), uint256(IVenue.TakerAccess.Allowed));
        assertTrue(venue.takerAllowed(pairId, taker, HOME));
        _fillEverySide();
        vm.txGasPrice(BASE_FEE);
        _fillEverySide();
        vm.txGasPrice(BASE_FEE + DEFAULT_CAP + 1);
        assertEq(uint256(venue.takerAccess(pairId, taker, HOME)), uint256(IVenue.TakerAccess.PriorityFeeTooHigh));
        assertFalse(venue.takerAllowed(pairId, taker, HOME));
        _expectEverySideReverts(uint256(DEFAULT_CAP) + 1, DEFAULT_CAP);
        // A call without fee fields sees no priority fee, so the views can't report the cap.
        vm.txGasPrice(0);
        assertEq(uint256(venue.takerAccess(pairId, taker, HOME)), uint256(IVenue.TakerAccess.Allowed));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The cap fills the settler's slot, bit-inverted, beside the fields it leaves alone.
    function test_capPacksIntoTheSettlerSlot() public {
        vm.prank(owner);
        venue.setDenied(_one(stranger), true);
        vm.prank(updater);
        venue.setHalted(true);
        _setCap(owner, CAP);
        uint256 word = uint256(vm.load(address(venue), bytes32(SLOT_SETTLER)));
        assertEq(address(uint160(word)), settler, "settler");
        assertEq((word >> HALTED_SHIFT) & 0xff, 1, "halted");
        assertEq((word >> DENIED_COUNT_SHIFT) & type(uint24).max, 1, "deniedCount");
        assertEq(word >> FEE_CAP_SHIFT, uint256(~CAP), "the inverted cap");
        assertEq(venue.settler(), settler);
        assertTrue(venue.halted());
        assertEq(venue.deniedCount(), 1);
    }

    /// @dev A capped fill or quote reads exactly the slots an uncapped one does: the cap shares the settler's slot.
    function test_capAddsNoStorageRead() public {
        vm.txGasPrice(BASE_FEE + CAP);
        uint256 snapshot = vm.snapshotState();
        (bytes32[] memory fillReads, bytes32[] memory quoteReads) = _reads();
        vm.revertToState(snapshot);
        _setCap(owner, CAP);
        (bytes32[] memory cappedFillReads, bytes32[] memory cappedQuoteReads) = _reads();
        bytes32[] memory distinctFill = _distinct(fillReads);
        assertEq(_distinct(cappedFillReads), distinctFill, "fill");
        assertEq(_distinct(cappedQuoteReads), _distinct(quoteReads), "quote");
        // The settler's slot is among the reads, the one the cap shares.
        bool readsSettlerSlot;
        for (uint256 i; i < distinctFill.length; ++i) {
            if (distinctFill[i] == bytes32(SLOT_SETTLER)) readsSettlerSlot = true;
        }
        assertTrue(readsSettlerSlot, "fill reads the settler's slot");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _setCap(address caller, uint64 cap) internal {
        vm.prank(caller);
        venue.setMaxTakerPriorityFee(cap);
    }

    function _enable(address caller) internal {
        vm.prank(caller);
        venue.enableTakerPriorityFeeCap();
    }

    /// @dev `caller` enables the default from no cap, again (emitting though nothing changes), from a lower cap
    /// (raising it), from a higher one (lowering it) and from 0, each call emitting the change.
    function _enableFromAnyCap(address caller) internal {
        uint64[5] memory from = [NO_CAP, DEFAULT_CAP, uint64(2 gwei), 50 gwei, 0];
        for (uint256 i; i < from.length; ++i) {
            if (i > 1) _setCap(caller, from[i]);
            vm.expectEmit(address(venue));
            emit IVenue.MaxTakerPriorityFeeSet(from[i], DEFAULT_CAP, caller);
            _enable(caller);
            assertEq(venue.maxTakerPriorityFee(), DEFAULT_CAP);
        }
    }

    /// @dev `caller` sets, raises, keeps, lowers to 0 and removes the cap, each call emitting the change, and the
    /// last fill pays a priority fee far above every earlier cap.
    function _raiseLowerAndRemove(address caller) internal {
        uint64[6] memory caps = [uint64(5 gwei), 10 gwei, 10 gwei, 3 gwei, 0, NO_CAP];
        uint64 previous = NO_CAP;
        for (uint256 i; i < caps.length; ++i) {
            vm.expectEmit(address(venue));
            emit IVenue.MaxTakerPriorityFeeSet(previous, caps[i], caller);
            _setCap(caller, caps[i]);
            assertEq(venue.maxTakerPriorityFee(), caps[i]);
            previous = caps[i];
        }
        vm.txGasPrice(BASE_FEE + 100 gwei);
        _fill(pairId, true, true, AMOUNT);
    }

    function _fillEverySide() internal {
        for (uint256 i; i < 4; ++i) {
            (bool baseIn, bool exactIn) = (i & 1 == 0, i & 2 == 0);
            (address tokenIn, address tokenOut) = _tokens(baseIn);
            (uint128 quotedIn, uint128 quotedOut) = venue.quote(pairId, tokenIn, tokenOut, AMOUNT, exactIn);
            (uint128 amountIn, uint128 amountOut) = _fill(pairId, baseIn, exactIn, AMOUNT);
            assertEq(amountIn, quotedIn);
            assertEq(amountOut, quotedOut);
        }
    }

    function _expectEverySideReverts(uint256 fee, uint64 cap) internal {
        bytes memory err = abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, fee, cap);
        for (uint256 i; i < 4; ++i) {
            _expectReverts(err, i & 1 == 0, i & 2 == 0);
        }
    }

    /// @dev `quote` and `fill` both revert with `err`, and nothing is consumed.
    function _expectReverts(bytes memory err, bool baseIn, bool exactIn) internal {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        (uint128 bids, uint128 asks) = venue.consumed(pairId);
        vm.expectRevert(err);
        venue.quote(pairId, tokenIn, tokenOut, AMOUNT, exactIn);
        MockTIP20V2(tokenIn).mint(address(venue), AMOUNT * 2);
        vm.expectRevert(err);
        vm.prank(settler);
        venue.fill(pairId, tokenIn, tokenOut, AMOUNT, exactIn, taker, HOME, REF);
        (uint128 bidsAfter, uint128 asksAfter) = venue.consumed(pairId);
        assertEq(bidsAfter, bids);
        assertEq(asksAfter, asks);
    }

    /// @dev A take whose expected outcome is `reverts`: the error carries the fee and the cap, else the fill matches
    /// its quote. `takerAccess` and `takerAllowed` agree either way.
    function _checkTake(bool reverts, uint256 fee, uint64 cap, bool baseIn, bool exactIn) internal {
        IVenue.TakerAccess outcome = reverts ? IVenue.TakerAccess.PriorityFeeTooHigh : IVenue.TakerAccess.Allowed;
        assertEq(uint256(venue.takerAccess(pairId, taker, HOME)), uint256(outcome), "takerAccess");
        assertEq(venue.takerAllowed(pairId, taker, HOME), !reverts, "takerAllowed");
        if (reverts) {
            _expectReverts(abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, fee, cap), baseIn, exactIn);
            return;
        }
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        (uint128 quotedIn, uint128 quotedOut) = venue.quote(pairId, tokenIn, tokenOut, AMOUNT, exactIn);
        (uint128 amountIn, uint128 amountOut) = _fill(pairId, baseIn, exactIn, AMOUNT);
        assertEq(amountIn, quotedIn);
        assertEq(amountOut, quotedOut);
    }

    /// @dev The venue slots one exact-in fill and one quote read.
    function _reads() internal returns (bytes32[] memory fillReads, bytes32[] memory quoteReads) {
        eur.mint(address(venue), AMOUNT);
        vm.record();
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), AMOUNT, true, taker, HOME, REF);
        (fillReads,) = vm.accesses(address(venue));
        vm.record();
        venue.quote(pairId, address(eur), address(usd), AMOUNT, true);
        (quoteReads,) = vm.accesses(address(venue));
    }

    /// @dev `slots` without repeats, sorted.
    function _distinct(bytes32[] memory slots) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        uint256 n;
        for (uint256 i; i < slots.length; ++i) {
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (out[j] == slots[i]) seen = true;
            }
            if (!seen) out[n++] = slots[i];
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = i; j > 0 && out[j - 1] > out[j]; --j) {
                (out[j - 1], out[j]) = (out[j], out[j - 1]);
            }
        }
    }
}
