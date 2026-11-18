// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { IntegrationFixture } from "./utils/IntegrationFixture.sol";

/// @notice A venue's taker priority-fee cap through the real Settler: a swap whose transaction pays a priority fee
/// above venue A's cap reverts, exact in or exact out, and moves nothing, so in a block ordered by priority fee no
/// take can outbid A's `post` to fill at the quote it replaces.
contract PriorityFeeIntegrationTest is IntegrationFixture {
    uint256 internal constant BASE_FEE = 600_000_000;
    uint64 internal constant CAP = 1 gwei;
    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        vm.fee(BASE_FEE);
        vm.prank(makerA);
        venueA.setMaxTakerPriorityFee(CAP);
    }

    function test_swapsFillAtTheCapAndRevertAbove() public {
        (address tokenIn, address tokenOut) = (address(eur), address(usd));
        vm.txGasPrice(BASE_FEE + CAP + 1);
        bytes memory tooHigh = abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, uint256(CAP) + 1, CAP);
        uint256[12] memory before = _balances();
        vm.expectRevert(tooHigh);
        _swapExactIn(taker, tokenIn, tokenOut, _request(venueA, pairA, AMOUNT), 0);
        vm.expectRevert(tooHigh);
        _swapExactOut(taker, tokenIn, tokenOut, _request(venueA, pairA, AMOUNT), type(uint256).max);
        _assertUnchanged(before);

        vm.txGasPrice(BASE_FEE + CAP);
        (, uint256 expectedOut,) = _expect(venueA, pairA, true, true, AMOUNT);
        assertEq(_swapExactIn(taker, tokenIn, tokenOut, _request(venueA, pairA, AMOUNT), 0), expectedOut);
        (uint256 expectedIn,,) = _expect(venueA, pairA, true, false, AMOUNT);
        assertEq(
            _swapExactOut(taker, tokenIn, tokenOut, _request(venueA, pairA, AMOUNT), type(uint256).max), expectedIn
        );
    }

    /// @dev The cap is venue A's alone: venue B, which has none, fills at any priority fee.
    function test_otherVenuesAreUnaffected() public {
        vm.txGasPrice(BASE_FEE + 100 gwei);
        (, uint256 expectedOut,) = _expect(venueB, pairB, true, true, AMOUNT);
        assertEq(_swapExactIn(taker, address(eur), address(usd), _request(venueB, pairB, AMOUNT), 0), expectedOut);
    }

    /// @dev One block ordered by priority fee. A sniper outbids A's re-quote to sell into its old bids first, and
    /// reverts; the post, sent above the cap, lands next; a taker at the cap fills after it, at the new mid.
    function test_aPostAboveTheCapCantBeOvertaken() public {
        vm.txGasPrice(BASE_FEE + CAP + 2);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, uint256(CAP) + 2, CAP));
        _swapExactIn(taker2, address(eur), address(usd), _request(venueA, pairA, AMOUNT), 0);

        vm.txGasPrice(BASE_FEE + CAP + 1);
        uint96 newMid = MID_A - 5e15;
        bytes32 word = _nextHot(venueA, pairA, _fields(newMid));
        vm.prank(updaterA);
        venueA.post(abi.encodePacked(pairA, word));

        vm.txGasPrice(BASE_FEE + CAP);
        vm.recordLogs();
        _swapExactIn(taker, address(eur), address(usd), _request(venueA, pairA, AMOUNT), 0);
        FillLog[] memory fills = _fillLogs();
        assertEq(fills.length, 1);
        assertEq(fills[0].makerMid, newMid);
        assertEq(fills[0].seq, HotWord.seq(word));
    }
}
