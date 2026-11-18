// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";

import { LadderMathHarness } from "./harness/LadderMathHarness.sol";

contract LadderMathTest is Test {
    uint64 internal constant UNIT = 1e6; // 1 EUR per size step
    uint96 internal constant MID = 1.085e18;

    LadderMathHarness internal harness;

    function setUp() public {
        harness = new LadderMathHarness();
    }

    function test_hotWordRoundTrips() public pure {
        HotWord.Fields memory f = HotWord.Fields({
            mid: type(uint96).max,
            bidWiden: 1,
            askWiden: 2,
            widthScale: 3,
            depthScale: 4,
            shapeId: 5,
            validUntil: type(uint40).max,
            seq: type(uint32).max,
            flags: HotWord.FLAG_ASKS_OFF
        });
        bytes32 w = HotWord.pack(f);
        HotWord.Fields memory g = HotWord.unpack(w);
        assertEq(g.mid, f.mid);
        assertEq(g.bidWiden, 1);
        assertEq(g.askWiden, 2);
        assertEq(g.widthScale, 3);
        assertEq(g.depthScale, 4);
        assertEq(g.shapeId, 5);
        assertEq(g.validUntil, f.validUntil);
        assertEq(g.seq, f.seq);
        assertEq(g.flags, HotWord.FLAG_ASKS_OFF);
        assertTrue(HotWord.sideOff(w, false));
        assertFalse(HotWord.sideOff(w, true));
        assertEq(HotWord.seq(HotWord.INITIAL), 1);
    }

    /// @dev Companion-page vector: mid 1.0850, ask L1 50k at 2 bp prices 1 EUR at 1.085217 USD.
    function test_askLevelOnePrice() public view {
        (uint256 w0,) = _side(_one(50_000), _one16(20));
        (uint256 amountIn, uint256 amountOut, uint256 baseFilled) =
            harness.fill(_hot(0, 0), UNIT, false, w0, 0, false, 1e6);
        assertEq(amountIn, 1_085_217);
        assertEq(amountOut, 1e6);
        assertEq(baseFilled, 1e6);
    }

    function test_bidExactInFloorsAndExactOutCeils() public view {
        (uint256 w0,) = _side(_one(50_000), _one16(20));
        // Bid factor 0.9998: 1 EUR sells for 1.084783 USD exactly, 3 base units for 3.254349 -> floor 3.
        (, uint256 quoteOut,) = harness.fill(_hot(0, 0), UNIT, true, w0, 0, true, 3);
        assertEq(quoteOut, 3);
        // Wanting 4 quote units needs ceil(4 / 1.084783) = 4 base units.
        (uint256 baseIn,,) = harness.fill(_hot(0, 0), UNIT, true, w0, 0, false, 4);
        assertEq(baseIn, 4);
    }

    /// @dev The rounding bound is under one unit of the rounded token, not one base unit. With a cheap base (1 USD =
    /// 16,000 IDR, mid 6.25e13, both 6 decimals) the two quote-rounded directions round by up to 15,999 base units'
    /// worth; the two base-rounded directions stay within one base unit.
    function test_roundingIsUnderOneUnitOfTheRoundedToken() public view {
        (uint256 w0,) = _side(_one(1_000_000), _one16(0));
        bytes32 hot = _hotMid(6.25e13);
        // Selling 31,999 base exact-in is worth 1.9999375 quote units, floored to 1.
        (, uint256 quoteOut,) = harness.fill(hot, UNIT, true, w0, 0, true, 31_999);
        assertEq(quoteOut, 1);
        // Buying 16,001 base exact-out costs 1.0000625 quote units, ceiled to 2.
        (uint256 quoteIn,,) = harness.fill(hot, UNIT, false, w0, 0, false, 16_001);
        assertEq(quoteIn, 2);
        // Paying 3 quote exact-in and wanting 1 quote exact-out come out exact in base.
        (, uint256 baseOut,) = harness.fill(hot, UNIT, false, w0, 0, true, 3);
        assertEq(baseOut, 48_000);
        (uint256 baseIn,,) = harness.fill(hot, UNIT, true, w0, 0, false, 1);
        assertEq(baseIn, 16_000);
    }

    function test_walksAcrossLevelsAndWords() public view {
        uint32[] memory sizes = new uint32[](7);
        uint16[] memory spreads = new uint16[](7);
        for (uint256 i; i < 7; ++i) {
            sizes[i] = 10;
            spreads[i] = uint16(10 * (i + 1));
        }
        (uint256 w0, uint256 w1) = ShapeWord.packSide(sizes, spreads);
        assertTrue(ShapeWord.continues(w0));
        // 65 EUR: six full levels (60) and 5 of the seventh.
        (uint256 amountIn,, uint256 baseFilled) = harness.fill(_hot(0, 0), UNIT, false, w0, w1, false, 65e6);
        assertEq(baseFilled, 65e6);
        uint256 numerator;
        for (uint256 i; i < 6; ++i) {
            numerator += 10e6 * uint256(MID) * (1e8 + 10 * (i + 1) * 1000);
        }
        numerator += 5e6 * uint256(MID) * (1e8 + 70 * 1000);
        assertEq(amountIn, (numerator + 1e26 - 1) / 1e26);
    }

    /// @dev A consumed offset starts the walk deeper: one unit at 0 bp, then one at 1%. From a fresh side 1 EUR costs
    /// the first level; with it consumed, the second; with both consumed the side is exhausted, as past its depth.
    function test_consumedOffsetStartsDeeper() public {
        (uint256 w0,) = _side(_two(1, 1), _two16(0, 100));
        (uint256 fresh,,) = harness.fillFrom(_hot(0, 0), UNIT, false, w0, 0, false, 1e6, 0);
        (uint256 deeper,,) = harness.fillFrom(_hot(0, 0), UNIT, false, w0, 0, false, 1e6, 1e6);
        assertEq(fresh, (1e6 * uint256(MID) * 1e8 + 1e26 - 1) / 1e26);
        assertEq(deeper, (1e6 * uint256(MID) * (1e8 + 100_000) + 1e26 - 1) / 1e26);
        // Half of level 1 consumed: the other half there, then half of level 2, rounded once.
        (uint256 straddle,,) = harness.fillFrom(_hot(0, 0), UNIT, false, w0, 0, false, 1e6, 0.5e6);
        uint256 numerator = 0.5e6 * uint256(MID) * 1e8 + 0.5e6 * uint256(MID) * (1e8 + 100_000);
        assertEq(straddle, (numerator + 1e26 - 1) / 1e26);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fillFrom(_hot(0, 0), UNIT, false, w0, 0, false, 1, 2e6);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fillFrom(_hot(0, 0), UNIT, false, w0, 0, false, 1, type(uint256).max);
        // `fill` is the walk from 0.
        (uint256 viaFill,,) = harness.fill(_hot(0, 0), UNIT, false, w0, 0, false, 1e6);
        assertEq(viaFill, fresh);
    }

    /// @dev Two fills chained through the offset walk the same book as one, each rounding once toward the maker: two
    /// halves of a 1.5 EUR buy straddling the level edge cost at least the whole, and at most one unit more.
    function test_chainedFillsCostAtLeastTheWhole() public view {
        (uint256 w0,) = _side(_two(1, 1), _two16(0, 100));
        bytes32 hot = _hotMid(1_000_000_700_000_000_000);
        (uint256 whole,,) = harness.fillFrom(hot, UNIT, false, w0, 0, false, 1.5e6, 0);
        (uint256 first,, uint256 base) = harness.fillFrom(hot, UNIT, false, w0, 0, false, 0.75e6, 0);
        (uint256 second,,) = harness.fillFrom(hot, UNIT, false, w0, 0, false, 0.75e6, base);
        assertGe(first + second, whole);
        assertLe(first + second, whole + 1);
        assertGt(second, first, "the second half pays the deeper level");
    }

    function test_revertsBeyondDepthAndOnZeroFill() public {
        (uint256 w0,) = _side(_one(1), _one16(0));
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fill(_hot(0, 0), UNIT, false, w0, 0, false, 1e6 + 1);
        // Selling 0.5 units' worth rounds to 0 quote.
        vm.expectRevert(LadderMath.ZeroFill.selector);
        harness.fill(_hotMid(0.5e18), UNIT, true, w0, 0, true, 1);
    }

    function test_bidFloorEndsTheLadder() public {
        uint32[] memory sizes = new uint32[](2);
        uint16[] memory spreads = new uint16[](2);
        sizes[0] = 1;
        sizes[1] = 1;
        spreads[0] = 0;
        spreads[1] = 60_000;
        (uint256 w0,) = ShapeWord.packSide(sizes, spreads);
        // widthScale 2000 pushes level 2 to 120,000 x 0.1 bp = 120%, past the floor.
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fill(_hot(2000, 0), UNIT, true, w0, 0, true, 1e6 + 1);
    }

    /// @dev At par with no spread one base unit costs exactly one quote unit, so after a full level the remainder can
    /// tie the unit price. The taker gets that unit from the next level; past the last level the fill needs more depth
    /// than the ladder holds, since the maker would otherwise keep a whole unit's worth of dust.
    function test_payQuoteRemainderOfExactlyOneUnit() public {
        bytes32 par = _hotWith(1e18, 1000, 0);
        (uint256 two,) = _side(_two(1, 1), _two16(0, 0));
        (uint256 amountIn, uint256 amountOut, uint256 baseFilled) = harness.fill(par, 1, false, two, 0, true, 2);
        assertEq(amountIn, 2);
        assertEq(amountOut, 2);
        assertEq(baseFilled, 2);

        (uint256 one,) = _side(_one(1), _one16(0));
        (, amountOut,) = harness.fill(par, 1, false, one, 0, true, 1);
        assertEq(amountOut, 1);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fill(par, 1, false, one, 0, true, 2);

        // 200k EUR flat at 1.0: paying 200,000.000001 USD is one unit more than the level holds.
        (uint256 flat,) = _side(_one(200_000), _one16(0));
        (, amountOut,) = harness.fill(par, UNIT, false, flat, 0, true, 200_000e6);
        assertEq(amountOut, 200_000e6);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fill(par, UNIT, false, flat, 0, true, 200_000e6 + 1);
    }

    /// @dev A bid level at offset 1e8 - 1 has factor 1 (a price of mid x 1e-8) and still fills; at offset 1e8 it is
    /// the floor.
    function test_bidFloorFactorOneStillFills() public {
        // Level 2: spread 9,999 x widthScale 10,001 = 99,999,999, holding 1e8 EUR worth 1,085,000 USD at factor 1.
        (uint256 w0,) = _side(_two(1, 100_000_000), _two16(0, 9_999));
        bytes32 hot = _hotWith(MID, 10_001, 0);
        uint256 depth = 1e6 + 1e14;
        (uint256 amountIn, uint256 amountOut,) = harness.fill(hot, UNIT, true, w0, 0, true, depth);
        assertEq(amountIn, depth);
        assertEq(amountOut, 2_170_000);
        (amountIn,,) = harness.fill(hot, UNIT, true, w0, 0, false, 2_170_000);
        assertEq(amountIn, depth);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fill(hot, UNIT, true, w0, 0, true, depth + 1);

        // Level 2: spread 10,000 x widthScale 10,000 = exactly 1e8, so the bids end after level 1.
        (w0,) = _side(_two(1, 100_000_000), _two16(0, 10_000));
        hot = _hotWith(MID, 10_000, 0);
        (, amountOut,) = harness.fill(hot, UNIT, true, w0, 0, true, 1e6);
        assertEq(amountOut, 1_085_000);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fill(hot, UNIT, true, w0, 0, true, 1e6 + 1);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        harness.fill(hot, UNIT, true, w0, 0, false, 1_085_001);
    }

    function test_shapeChecks() public view {
        uint256[4] memory words;
        assertEq(harness.check(words), 0);
        words[1] = 1; // a level in the second word after an empty first word
        assertEq(harness.check(words), ShapeWord.REASON_NON_CANONICAL);
        words[1] = 0;
        words[0] = 1 | (uint256(1) << 240);
        assertEq(harness.check(words), ShapeWord.REASON_RESERVED_BITS);
        uint32[] memory sizes = new uint32[](2);
        uint16[] memory spreads = new uint16[](2);
        sizes[0] = 1;
        sizes[1] = 1;
        spreads[0] = 5;
        spreads[1] = 4;
        (words[0], words[1]) = ShapeWord.packSide(sizes, spreads);
        assertEq(harness.check(words), ShapeWord.REASON_SPREAD_DECREASES);
    }

    function _hot(uint16 widthScale, uint16 widen) internal pure returns (bytes32) {
        return HotWord.pack(
            HotWord.Fields({
                mid: MID,
                bidWiden: widen,
                askWiden: widen,
                widthScale: widthScale == 0 ? 1000 : widthScale,
                depthScale: 1000,
                shapeId: 0,
                validUntil: type(uint40).max,
                seq: 2,
                flags: 0
            })
        );
    }

    /// @dev Like `_hot`, with the mid given and `widthScale` taken as is (0 means zero width).
    function _hotWith(uint96 mid, uint16 widthScale, uint16 widen) internal pure returns (bytes32) {
        HotWord.Fields memory f = HotWord.unpack(_hot(0, widen));
        f.mid = mid;
        f.widthScale = widthScale;
        return HotWord.pack(f);
    }

    function _hotMid(uint96 mid) internal pure returns (bytes32) {
        HotWord.Fields memory f = HotWord.unpack(_hot(0, 0));
        f.mid = mid;
        return HotWord.pack(f);
    }

    function _side(uint32[] memory sizes, uint16[] memory spreads) internal pure returns (uint256, uint256) {
        return ShapeWord.packSide(sizes, spreads);
    }

    function _one(uint32 v) internal pure returns (uint32[] memory a) {
        a = new uint32[](1);
        a[0] = v;
    }

    function _one16(uint16 v) internal pure returns (uint16[] memory a) {
        a = new uint16[](1);
        a[0] = v;
    }

    function _three(uint32 v0, uint32 v1, uint32 v2) internal pure returns (uint32[] memory a) {
        a = new uint32[](3);
        (a[0], a[1], a[2]) = (v0, v1, v2);
    }

    function _three16(uint16 v0, uint16 v1, uint16 v2) internal pure returns (uint16[] memory a) {
        a = new uint16[](3);
        (a[0], a[1], a[2]) = (v0, v1, v2);
    }

    function _two(uint32 v0, uint32 v1) internal pure returns (uint32[] memory a) {
        a = new uint32[](2);
        a[0] = v0;
        a[1] = v1;
    }

    function _two16(uint16 v0, uint16 v1) internal pure returns (uint16[] memory a) {
        a = new uint16[](2);
        a[0] = v0;
        a[1] = v1;
    }
}
