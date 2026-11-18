// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";

import { LadderMathHarness } from "./harness/LadderMathHarness.sol";

/// @notice Property tests for the curve libraries. Every price property is checked against an exact rational
/// reference computed here from the spec formulas: a side is expanded into levels of `depth` base units, each worth
/// `price` (quote units x 1e26) per base unit, so the value of any walk is an exact integer over 1e26. A fill walks
/// that book after the `consumed` base the side's earlier fills took, as the venue passes it.
contract LadderMathFuzzTest is Test {
    /// @dev Value numerators are quote units times this.
    uint256 internal constant ONE = 1e26;
    uint256 internal constant FACTOR_ONE = 1e8;

    uint8 internal constant OK = 0;
    uint8 internal constant DEPTH = 1;
    uint8 internal constant ZERO = 2;

    // Directions: taker sells base exact in, buys base exact out, pays quote exact in, wants quote exact out.
    uint256 internal constant SELL_BASE = 0;
    uint256 internal constant BUY_BASE = 1;
    uint256 internal constant PAY_QUOTE = 2;
    uint256 internal constant WANT_QUOTE = 3;

    error UnexpectedRevert(bytes err);

    struct Market {
        bytes32 hot;
        uint64 sizeUnit;
        uint256 w0;
        uint256 w1;
    }

    struct Fill {
        uint256 dir;
        uint256 amount;
        uint256 consumed;
    }

    struct Result {
        uint8 outcome;
        uint256 amountIn;
        uint256 amountOut;
        uint256 baseFilled;
    }

    /// @dev The levels a fill can walk, in order: `depth[i]` base units at `price[i]` per unit. Room for ten ladder
    /// levels.
    struct Book {
        uint256 n;
        uint256[11] depth;
        uint256[11] price;
    }

    LadderMathHarness internal harness;

    function setUp() public {
        harness = new LadderMathHarness();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Encodings
    // -----------------------------------------------------------------------------------------------------------------

    function testFuzz_hotWordPackUnpack(HotWord.Fields memory f) public pure {
        bytes32 w = HotWord.pack(f);
        HotWord.Fields memory g = HotWord.unpack(w);
        assertEq(abi.encode(g), abi.encode(f));
        assertEq(HotWord.mid(w), f.mid);
        assertEq(HotWord.bidWiden(w), f.bidWiden);
        assertEq(HotWord.askWiden(w), f.askWiden);
        assertEq(HotWord.widthScale(w), f.widthScale);
        assertEq(HotWord.depthScale(w), f.depthScale);
        assertEq(HotWord.shapeId(w), f.shapeId);
        assertEq(HotWord.validUntil(w), f.validUntil);
        assertEq(HotWord.seq(w), f.seq);
        assertEq(HotWord.flags(w), f.flags);
    }

    function testFuzz_hotWordUnpackPack(bytes32 w) public pure {
        // Every bit belongs to exactly one field.
        assertEq(HotWord.pack(HotWord.unpack(w)), w);
        uint256 u = uint256(w);
        assertEq(HotWord.mid(w), u & (2 ** 96 - 1));
        assertEq(HotWord.flags(w), u >> 240);
        // Flag bits 0-3 (bids off, asks off, refill bids, refill asks) are defined; bits 4-15 are reserved.
        assertEq(HotWord.isWellFormed(w), u & (2 ** 96 - 1) != 0 && u >> 244 == 0);
        assertEq(HotWord.sideOff(w, true), (u >> 240) & 1 == 1);
        assertEq(HotWord.sideOff(w, false), (u >> 241) & 1 == 1);
        assertEq(HotWord.flags(w) & HotWord.FLAG_REFILL_BIDS != 0, (u >> 242) & 1 == 1);
        assertEq(HotWord.flags(w) & HotWord.FLAG_REFILL_ASKS != 0, (u >> 243) & 1 == 1);
        // `withoutRefill` clears exactly the two refill bits.
        assertEq(uint256(HotWord.withoutRefill(w)), u & ~(uint256(3) << 242));
    }

    function testFuzz_shapeSidePackLevel(uint256 seed) public pure {
        uint256 n = seed % 11;
        uint32[] memory sizes = new uint32[](n);
        uint16[] memory spreads = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = _r(seed, i);
            sizes[i] = uint32(r);
            spreads[i] = uint16(r >> 32);
        }
        (uint256 w0, uint256 w1) = ShapeWord.packSide(sizes, spreads);
        assertEq(w0 & ShapeWord.RESERVED_MASK, 0);
        assertEq(w1 & ShapeWord.RESERVED_MASK, 0);
        for (uint256 i; i < ShapeWord.MAX_LEVELS; ++i) {
            (uint256 s, uint256 sp) = ShapeWord.level(w0, w1, i);
            assertEq(s, i < n ? sizes[i] : 0);
            assertEq(sp, i < n ? spreads[i] : 0);
        }
        // The venue loads the second word exactly when level 5 has size.
        assertEq(ShapeWord.continues(w0), n >= 5 && sizes[4] != 0, "continues");
    }

    /// @dev `check` returns 0 exactly for canonical shapes, and otherwise the first rule broken, bid side first.
    function testFuzz_checkAcceptsExactlyCanonical(uint256 seed, uint256 mutation) public view {
        uint256[4] memory words;
        (words[0], words[1]) = _side(_r(seed, 1));
        (words[2], words[3]) = _side(_r(seed, 2));
        assertEq(harness.check(words), 0, "canonical");
        assertEq(ShapeWord.continues(words[0]), _sideLevels(_r(seed, 1)) >= 5, "bid continues");
        assertEq(ShapeWord.continues(words[2]), _sideLevels(_r(seed, 2)) >= 5, "ask continues");
        assertTrue(ShapeWord.continues(words[0]) || words[1] == 0);
        assertTrue(ShapeWord.continues(words[2]) || words[3] == 0);

        uint256 mode = (mutation >> 8) % 6;
        uint256 r = _r(seed, mutation);
        if (mode < 4) {
            _mutate(words, mutation % 4, mode, r);
        } else if (mode == 5) {
            // One bid word and one ask word, so the order of reasons across the two sides decides the result.
            _mutate(words, mutation % 2, (r >> 248) % 4, r);
            uint256 r2 = _r(r, 1);
            _mutate(words, 2 + (mutation >> 1) % 2, (r2 >> 248) % 4, r2);
        }
        assertEq(harness.check(words), _reason(words), "mutated");
    }

    /// @dev The bid side is checked in full before the ask side: a non-canonical bid beats reserved ask bits.
    function test_reasonOrderAcrossSides() public view {
        uint256[4] memory words = [uint256(1) << 48, 0, uint256(1) << 241, 0];
        assertEq(harness.check(words), ShapeWord.REASON_NON_CANONICAL, "library");
        assertEq(_reason(words), ShapeWord.REASON_NON_CANONICAL, "reference");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Pricing against the exact reference
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The outcome matches the reference, and a filled taker never gets more than the curve's exact value.
    function testFuzz_takerNeverBeatsCurve(uint256 seed) public view {
        (Market memory m, Fill memory l) = _scenario(seed);
        Result memory r = _fill(m, l);
        assertEq(r.outcome, _expectedOutcome(m, l), "outcome");
        if (r.outcome != OK) return;
        Book memory b = _walk(m, l);
        if (l.dir == SELL_BASE) {
            assertEq(r.amountIn, l.amount);
            assertEq(r.baseFilled, l.amount);
            assertLe(r.amountOut * ONE, _value(b, 0, l.amount), "sold base for more than its value");
        } else if (l.dir == BUY_BASE) {
            assertEq(r.amountOut, l.amount);
            assertEq(r.baseFilled, l.amount);
            assertGe(r.amountIn * ONE, _value(b, 0, l.amount), "bought base for less than its value");
        } else if (l.dir == PAY_QUOTE) {
            assertEq(r.amountIn, l.amount);
            assertEq(r.baseFilled, r.amountOut);
            assertLe(_value(b, 0, r.amountOut), l.amount * ONE, "received more base than paid for");
        } else {
            assertEq(r.amountOut, l.amount);
            assertEq(r.baseFilled, r.amountIn);
            assertGe(_value(b, 0, r.amountIn), l.amount * ONE, "paid less base than the quote is worth");
        }
    }

    /// @dev The single rounding per fill is below one unit of the rounded token.
    function testFuzz_roundingBelowOneUnit(uint256 seed) public view {
        (Market memory m, Fill memory l) = _scenario(seed);
        Result memory r = _fill(m, l);
        if (r.outcome != OK) return;
        Book memory b = _walk(m, l);
        if (l.dir == SELL_BASE) {
            assertLt(_value(b, 0, l.amount) - r.amountOut * ONE, ONE, "quote out short by a unit");
        } else if (l.dir == BUY_BASE) {
            assertLt(r.amountIn * ONE - _value(b, 0, l.amount), ONE, "quote in over by a unit");
        } else if (l.dir == PAY_QUOTE) {
            // The dust can't buy one more base unit, whether or not the book has one.
            uint256 dust = l.amount * ONE - _value(b, 0, r.amountOut);
            if (r.amountOut < _left(b, 0)) {
                assertGt(_value(b, 0, r.amountOut + 1), l.amount * ONE, "one more base unit was affordable");
            } else {
                assertLt(dust, _lastPrice(b, 0), "dust buys a unit past the book");
            }
        } else {
            assertLt(_value(b, 0, r.amountIn - 1), l.amount * ONE, "one less base unit would do");
        }
    }

    /// @dev Pricing an exact-out result exact-in (and back) stays within the fill's rounding.
    function testFuzz_exactInExactOutConsistent(uint256 seed) public view {
        (Market memory m, Fill memory l) = _scenario(seed);
        Book memory b = _walk(m, l);
        Result memory r = _fill(m, l);
        if (r.outcome != OK || !_fits(r)) return;

        if (l.dir == BUY_BASE || l.dir == PAY_QUOTE) {
            // Buy `base` exact out for `q`, then pay `q` exact in: at least `base` again.
            uint256 base = r.amountOut;
            uint256 q = r.amountIn;
            if (l.dir == PAY_QUOTE) {
                Result memory cost = _fill(m, Fill(BUY_BASE, base, l.consumed));
                assertEq(cost.outcome, OK, "exact-out of an exact-in result");
                assertLe(cost.amountIn, q, "exact-out costs more than the exact-in paid");
                q = cost.amountIn;
            }
            Result memory back = _fill(m, Fill(PAY_QUOTE, q, l.consumed));
            if (back.outcome == DEPTH) {
                // Only when the round-up of the exact-out cost buys the rest of the book and a unit past it.
                uint256 left = _left(b, 0);
                assertLe(_value(b, 0, left) + _lastPrice(b, 0), q * ONE, "ran out of depth");
            } else {
                assertEq(back.outcome, OK, "exact-in of an exact-out cost");
                assertGe(back.amountOut, base, "exact-in of an exact-out cost buys less");
                assertLt(_value(b, 0, back.amountOut), _value(b, 0, base) + ONE);
            }
        } else {
            // Sell `base` exact in for `q`, then want `q` exact out: at most `base` again.
            uint256 base = r.amountIn;
            uint256 q = r.amountOut;
            if (l.dir == WANT_QUOTE) {
                Result memory proceeds = _fill(m, Fill(SELL_BASE, base, l.consumed));
                assertEq(proceeds.outcome, OK, "exact-in of an exact-out result");
                assertGe(proceeds.amountOut, q, "exact-in yields less than the exact-out wanted");
                q = proceeds.amountOut;
            }
            Result memory back = _fill(m, Fill(WANT_QUOTE, q, l.consumed));
            assertEq(back.outcome, OK, "exact-out of exact-in proceeds");
            assertLe(back.amountIn, base, "exact-out of exact-in proceeds needs more base");
        }
    }

    /// @dev More input never gives less output, and the taker's average price never improves with size (beyond the
    /// one-unit rounding of the smaller fill).
    function testFuzz_monotonicInSize(uint256 seed, uint256 extra) public view {
        (Market memory m, Fill memory small) = _scenario(seed);
        Fill memory big = Fill(small.dir, small.amount + 1 + extra % (small.amount + 1), small.consumed);
        if (big.amount > type(uint128).max) return;
        Result memory rs = _fill(m, small);
        Result memory rb = _fill(m, big);

        if (rb.outcome == OK) assertTrue(rs.outcome != DEPTH, "a smaller fill ran out of depth");
        if (rs.outcome == DEPTH) assertEq(rb.outcome, DEPTH, "a bigger fill found more depth");
        if (rs.outcome != OK || rb.outcome != OK || !_fits(rs) || !_fits(rb)) return;

        uint256 x = small.amount;
        uint256 y = big.amount;
        if (small.dir == SELL_BASE || small.dir == PAY_QUOTE) {
            // Exact in: output per unit of input can only fall.
            assertGe(rb.amountOut, rs.amountOut, "more input, less output");
            assertLt(rb.amountOut * x, (rs.amountOut + 1) * y, "average price improved with size");
        } else {
            // Exact out: input per unit of output can only rise.
            assertGe(rb.amountIn, rs.amountIn, "more output, less input");
            assertGt(rb.amountIn * x + y, rs.amountIn * y, "average price improved with size");
        }
    }

    /// @dev Two fills chained through the consumed offset (the second starts where the first left it) walk the same
    /// book as one fill of their total, and the split never does better for the taker: within each part's rounding,
    /// always toward the maker.
    function testFuzz_splitNeverBeatsOneFill(uint256 seed, uint256 cut) public view {
        (Market memory m, Fill memory whole) = _scenario(seed);
        if (whole.amount < 2) return;
        uint256 a = 1 + cut % (whole.amount - 1);
        Result memory rw = _fill(m, whole);
        Result memory r1 = _fill(m, Fill(whole.dir, a, whole.consumed));
        if (r1.outcome != OK) {
            // A part never needs more depth than the whole.
            if (r1.outcome == DEPTH) assertEq(rw.outcome, DEPTH, "part ran out of depth, whole did not");
            return;
        }
        Result memory r2 = _fill(m, Fill(whole.dir, whole.amount - a, whole.consumed + r1.baseFilled));
        // Paying quote, a first part that buys every unit left leaves the second an empty book, which always runs out
        // of depth, while the whole fills: its remainder past the last unit is below that unit's price, so the maker
        // keeps it as dust. The second part's quote is part of that dust (the first part paid at least the book's
        // value), so it could never have bought anything, and the split fills exactly the whole's base for less.
        if (rw.outcome == OK && whole.dir == PAY_QUOTE && r2.outcome == DEPTH) {
            Book memory b = _walk(m, whole);
            uint256 left = _left(b, 0);
            assertEq(r1.baseFilled, left, "second part ran out of depth with units left");
            assertEq(rw.baseFilled, left, "whole left units unbought");
            assertLt(whole.amount * ONE - _value(b, 0, left), _lastPrice(b, 0), "whole kept a unit's price as dust");
            return;
        }
        // Two exceptions, both from rounding: wanting quote, the first part's round-up can leave the second short
        // where the whole fills; paying quote, the dust each part keeps can let both fill where the whole can't.
        if (rw.outcome == OK && whole.dir != WANT_QUOTE) {
            assertTrue(r2.outcome != DEPTH, "second part ran out of depth, whole did not");
        }
        if (r2.outcome == OK && whole.dir != PAY_QUOTE) assertEq(rw.outcome, OK, "both parts filled, whole did not");
        if (rw.outcome != OK || r2.outcome != OK) return;

        uint256 base = r1.baseFilled + r2.baseFilled;
        if (whole.dir == SELL_BASE) {
            // The same base for at most the whole's quote, short by under one unit per extra rounding.
            assertEq(rw.baseFilled, base);
            assertLe(r1.amountOut + r2.amountOut, rw.amountOut, "split sold base for more");
            assertLe(rw.amountOut, r1.amountOut + r2.amountOut + 1);
        } else if (whole.dir == BUY_BASE) {
            assertEq(rw.baseFilled, base);
            assertGe(r1.amountIn + r2.amountIn, rw.amountIn, "split bought base for less");
            assertLe(r1.amountIn + r2.amountIn, rw.amountIn + 1);
        } else if (whole.dir == PAY_QUOTE) {
            // The same quote buys at most the whole's base.
            assertLe(base, rw.baseFilled, "split bought more base");
            assertLe(rw.baseFilled, base + 1);
        } else {
            // The same quote costs at least the whole's base; each part rounds its base up by less than one unit,
            // worth that unit's price.
            assertGe(base, rw.baseFilled, "split paid less base");
            Book memory b = _walk(m, whole);
            uint256 slack = _priceAt(b, r1.baseFilled - 1) + _priceAt(b, base - 1);
            assertLt(_value(b, 0, base), whole.amount * ONE + slack);
        }
    }

    /// @dev The fuzz counterexample the split property allows for: one ask unit left at 5 quote. Paying 8 buys it and
    /// the maker keeps 3 as dust, since 3 can't buy a unit. Split 5 + 3, the first part buys the unit for exactly 5 and
    /// the second walks an empty book, so it runs out of depth: the same base for less quote, never better.
    function test_splitPayingQuoteEmptiesTheBook() public view {
        uint32[] memory sizes = new uint32[](1);
        uint16[] memory spreads = new uint16[](1);
        sizes[0] = 48; // 48 x 714 / 1000 = 34 base units
        spreads[0] = 19;
        Market memory m;
        (m.w0, m.w1) = ShapeWord.packSide(sizes, spreads);
        m.sizeUnit = 1;
        m.hot = HotWord.pack(
            HotWord.Fields({
                mid: 5e18,
                bidWiden: 0,
                askWiden: 0,
                widthScale: 0,
                depthScale: 714,
                shapeId: 0,
                validUntil: 1,
                seq: 2,
                flags: 0
            })
        );
        // 33 of the 34 units already bought: one left, at 5 quote.
        Result memory whole = _fill(m, Fill(PAY_QUOTE, 8, 33));
        assertEq(abi.encode(whole), abi.encode(Result(OK, 8, 1, 1)), "whole");
        Result memory first = _fill(m, Fill(PAY_QUOTE, 5, 33));
        assertEq(abi.encode(first), abi.encode(Result(OK, 5, 1, 1)), "first part");
        assertEq(_fill(m, Fill(PAY_QUOTE, 3, 34)).outcome, DEPTH, "second part");
        // Every unit taken, or more: the side is exhausted for any amount.
        assertEq(_fill(m, Fill(BUY_BASE, 1, 34)).outcome, DEPTH, "exhausted side");
        assertEq(_fill(m, Fill(BUY_BASE, 1, type(uint128).max)).outcome, DEPTH, "past the depth");

        testFuzz_splitNeverBeatsOneFill(6601, 95);
    }

    /// @dev The walk from `consumed` equals a fresh walk of the book with its first `consumed` base units removed:
    /// the offset only shortens or skips levels, never changes a price.
    function testFuzz_consumedOffsetIsTheRemainingBook(uint256 seed) public view {
        (Market memory m, Fill memory l) = _scenario(seed);
        (uint256 size0,) = ShapeWord.level(m.w0, m.w1, 0);
        if (size0 == 0) return;
        // With sizeUnit 1 and depthScale 1000 raw sizes are base units, so taking `c` off the first raw level is the
        // same book as consuming `c` from it.
        HotWord.Fields memory f = HotWord.unpack(m.hot);
        f.depthScale = 1000;
        m.hot = HotWord.pack(f);
        m.sizeUnit = 1;
        uint256 c = l.consumed % size0;
        Market memory shorter =
            Market({ hot: m.hot, sizeUnit: 1, w0: (m.w0 & ~uint256(type(uint32).max)) | (size0 - c), w1: m.w1 });
        Result memory fromOffset = _fill(m, Fill(l.dir, l.amount, c));
        Result memory fresh = _fill(shorter, Fill(l.dir, l.amount, 0));
        assertEq(abi.encode(fromOffset), abi.encode(fresh), "offset differs from the shortened first level");
    }

    /// @dev Bid levels at or past a zero factor never fill; everything above them does, down to a factor of exactly 1
    /// (a price of mid x 1e-8). Asks never floor.
    function testFuzz_bidFloor(uint256 seed) public view {
        Floor memory fl = _floor(seed);
        _checkFloorBids(fl);
        _checkFloorAsks(fl);
    }

    /// @dev A bid-floor scenario: the ladder, its level count `n`, the index `k` of the first bid level at or past
    /// the floor, the mid, and whether the level above the floor sits at a factor of exactly 1. Held in memory and
    /// checked in separate functions, so each stays within the stack limit of every build, `--ir-minimum` included.
    struct Floor {
        Market m;
        uint256 n;
        uint256 k;
        uint256 mid;
        bool factorOne;
    }

    function _floor(uint256 seed) internal pure returns (Floor memory fl) {
        // One run in three puts the level just above the floor at a factor of exactly 1.
        fl.factorOne = _r(seed, 8) % 3 == 0;
        uint256 ws;
        uint256 widen;
        uint256 oneSpread;
        if (fl.factorOne) {
            (ws, widen, oneSpread) = _factorOne(_r(seed, 1));
        } else {
            ws = 1 + _r(seed, 1) % 65_535;
            widen = _r(seed, 2) % 65_536;
        }
        // The smallest raw spread whose offset reaches 100%.
        uint256 floorSpread = (FACTOR_ONE - widen * 1000 + ws - 1) / ws;
        fl.n = 2 + _r(seed, 3) % 9;
        fl.k = floorSpread > type(uint16).max ? fl.n : _r(seed, 4) % fl.n;
        if (fl.factorOne && fl.k == 0) fl.k = 1;

        uint32[] memory sizes = new uint32[](fl.n);
        uint16[] memory spreads = new uint16[](fl.n);
        uint256 spread;
        for (uint256 i; i < fl.n; ++i) {
            uint256 rand = _r(seed, 10 + i);
            sizes[i] = uint32(1 + rand % 1_000_000);
            if (i == fl.k) spread = floorSpread;
            uint256 cap =
                i < fl.k ? (floorSpread > type(uint16).max ? type(uint16).max : floorSpread - 1) : type(uint16).max;
            spread += (rand >> 64) % 3 == 0 ? 0 : (rand >> 128) % (cap - spread + 1);
            if (i == fl.k && (rand >> 192) % 2 == 0) spread = floorSpread; // often exactly at the floor
            if (fl.factorOne && i + 1 == fl.k) {
                // The largest spread below the floor, at offset 1e8 - 1. At least 1000 raw size keeps it nonempty.
                spread = oneSpread;
                sizes[i] = uint32(1000 + rand % 1_000_000);
            }
            spreads[i] = uint16(spread);
        }
        fl.mid = 1 + _r(seed, 6) % 1e24;
        (fl.m.w0, fl.m.w1) = ShapeWord.packSide(sizes, spreads);
        fl.m.sizeUnit = uint64(1 + _r(seed, 5) % 1e6);
        fl.m.hot = HotWord.pack(
            HotWord.Fields({
                mid: uint96(fl.mid),
                bidWiden: uint16(widen),
                askWiden: uint16(widen),
                widthScale: uint16(ws),
                depthScale: uint16(1 + _r(seed, 7) % 3000),
                shapeId: 0,
                validUntil: 1,
                seq: 2,
                flags: 0
            })
        );
    }

    /// @dev The bids fill down to the floor and not a unit past it, in both bid directions.
    function _checkFloorBids(Floor memory fl) internal view {
        Book memory bids = _book(fl.m, true);
        assertEq(bids.n, fl.k, "reference floor");
        uint256 fillable;
        for (uint256 i; i < fl.k; ++i) {
            fillable += bids.depth[i];
            assertGt(bids.price[i], 0);
        }
        if (fl.factorOne) {
            uint256 last = bids.depth[fl.k - 1];
            assertEq(bids.price[fl.k - 1], fl.mid, "reference factor one");
            assertGt(last, 0);
            // A fill on the factor-one level alone, the rest consumed, fills or rounds to nothing; it never finds the
            // ladder ended.
            Result memory one = _fill(fl.m, Fill(SELL_BASE, last, fillable - last));
            assertEq(one.outcome, last * fl.mid < ONE ? ZERO : OK, "factor one floored");
            if (one.outcome == OK) assertEq(one.amountOut, last * fl.mid / ONE, "factor one price");
        }
        Result memory r = _fill(fl.m, Fill(SELL_BASE, fillable + 1, 0));
        assertEq(r.outcome, DEPTH, "sold into the floor");
        // Consumed down to the floor: nothing past it fills.
        assertEq(_fill(fl.m, Fill(SELL_BASE, 1, fillable)).outcome, DEPTH, "sold past the floor from a consumed side");
        if (fillable > 0) {
            r = _fill(fl.m, Fill(SELL_BASE, fillable, 0));
            assertEq(r.outcome, _value(bids, 0, fillable) < ONE ? ZERO : OK, "fill down to the floor");
            uint256 v = _value(bids, 0, fillable);
            r = _fill(fl.m, Fill(WANT_QUOTE, v / ONE + 1, 0));
            assertEq(r.outcome, DEPTH, "wanted more quote than the floor allows");
        }
    }

    /// @dev The bid floor rejects an empty bid side; the asks still fill every level.
    function _checkFloorAsks(Floor memory fl) internal view {
        if (fl.k == 0) {
            Result memory p = _fill(fl.m, Fill(SELL_BASE, 1, 0));
            assertEq(p.outcome, DEPTH, "bid side floored");
        }
        Book memory asks = _book(fl.m, false);
        assertEq(asks.n, fl.n);
        uint256 total = _left(asks, 0);
        if (total > 0) assertEq(_fill(fl.m, Fill(BUY_BASE, total, 0)).outcome, OK, "asks floored");
    }

    /// @dev Max field values with any uint128 amount and any consumed offset never overflow: every fill fills or
    /// reverts with one of the two library errors, and the outcome matches the reference.
    function testFuzz_noOverflowAtMaxFields(uint256 seed, uint128 amount, uint128 consumed) public view {
        Market memory m;
        m.sizeUnit = type(uint64).max;
        uint32[] memory sizes = new uint32[](10);
        uint16[] memory spreads = new uint16[](10);
        uint256 zeroSpreads = _r(seed, 1) % 11;
        for (uint256 i; i < 10; ++i) {
            sizes[i] = type(uint32).max;
            spreads[i] = i < zeroSpreads ? 0 : type(uint16).max;
        }
        (m.w0, m.w1) = ShapeWord.packSide(sizes, spreads);
        m.hot = HotWord.pack(
            HotWord.Fields({
                mid: type(uint96).max - uint96(_r(seed, 2) % 1000),
                bidWiden: _r(seed, 3) % 2 == 0 ? 0 : type(uint16).max,
                askWiden: type(uint16).max,
                widthScale: type(uint16).max,
                depthScale: type(uint16).max,
                shapeId: type(uint8).max,
                validUntil: type(uint40).max,
                seq: type(uint32).max,
                flags: 0
            })
        );
        Fill memory l = Fill(_r(seed, 4) % 4, amount == 0 ? 1 : amount, _r(seed, 5) % 2 == 0 ? 0 : consumed);
        Result memory r = _fill(m, l);
        assertEq(r.outcome, _expectedOutcome(m, l), "outcome");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Reference model
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Expands the side a fill walks, straight from the spec: ask factor `1 + (spread * widthScale / 1000 +
    /// widen) / 1e5`, bid factor `1 - (...)` up to the first level at or past zero, depth
    /// `size * depthScale / 1000 * sizeUnit` floored per level.
    function _book(Market memory m, bool baseIn) internal pure returns (Book memory b) {
        uint256 hot = uint256(m.hot);
        uint256 mid = hot & (2 ** 96 - 1);
        uint256 widen = (hot >> (baseIn ? 96 : 112)) & 0xffff;
        uint256 ws = (hot >> 128) & 0xffff;
        uint256 ds = (hot >> 144) & 0xffff;
        for (uint256 i; i < 10; ++i) {
            uint256 slot = ((i < 5 ? m.w0 : m.w1) >> (48 * (i % 5))) & (2 ** 48 - 1);
            uint256 size = slot & (2 ** 32 - 1);
            if (size == 0) break;
            uint256 offset = (slot >> 32) * ws + widen * 1000;
            if (baseIn && offset >= FACTOR_ONE) break;
            b.depth[b.n] = size * ds * m.sizeUnit / 1000;
            b.price[b.n] = mid * (baseIn ? FACTOR_ONE - offset : FACTOR_ONE + offset);
            b.n += 1;
        }
    }

    /// @dev The book `l` walks: the side's levels after the first `l.consumed` base units.
    function _walk(Market memory m, Fill memory l) internal pure returns (Book memory w) {
        Book memory b = _book(m, _baseIn(l.dir));
        uint256 from = l.consumed;
        for (uint256 i; i < b.n; ++i) {
            uint256 d = b.depth[i];
            if (from >= d) {
                from -= d;
                continue;
            }
            w.depth[w.n] = d - from;
            w.price[w.n] = b.price[i];
            w.n += 1;
            from = 0;
        }
    }

    /// @dev Exact value of `base` units after skipping the first `from`. Reverts past the book.
    function _value(Book memory b, uint256 from, uint256 base) internal pure returns (uint256 v) {
        for (uint256 i; i < b.n && base > 0; ++i) {
            uint256 d = b.depth[i];
            if (from >= d) {
                from -= d;
                continue;
            }
            d -= from;
            from = 0;
            uint256 t = base < d ? base : d;
            v += t * b.price[i];
            base -= t;
        }
        require(base == 0, "reference: past depth");
    }

    /// @dev Base units left after skipping `from`.
    function _left(Book memory b, uint256 from) internal pure returns (uint256 total) {
        for (uint256 i; i < b.n; ++i) {
            total += b.depth[i];
        }
        total = total > from ? total - from : 0;
    }

    /// @dev Price of the deepest unit left after skipping `from`, or 0 when none is.
    function _lastPrice(Book memory b, uint256 from) internal pure returns (uint256 p) {
        uint256 end;
        for (uint256 i; i < b.n; ++i) {
            end += b.depth[i];
            if (b.depth[i] > 0 && end > from) p = b.price[i];
        }
    }

    /// @dev Price of the unit at position `pos` (0-based) of the book.
    function _priceAt(Book memory b, uint256 pos) internal pure returns (uint256) {
        for (uint256 i; i < b.n; ++i) {
            if (pos < b.depth[i]) return b.price[i];
            pos -= b.depth[i];
        }
        revert("reference: past depth");
    }

    function _expectedOutcome(Market memory m, Fill memory l) internal pure returns (uint8) {
        Book memory b = _walk(m, l);
        uint256 left = _left(b, 0);
        if (l.dir == SELL_BASE || l.dir == BUY_BASE) {
            if (l.amount > left) return DEPTH;
            uint256 v = _value(b, 0, l.amount);
            if (l.dir == SELL_BASE) return v < ONE ? ZERO : OK;
            return v == 0 ? ZERO : OK;
        }
        uint256 budget = l.amount * ONE;
        uint256 all = _value(b, 0, left);
        if (l.dir == WANT_QUOTE) return all < budget ? DEPTH : OK;
        if (left == 0) return DEPTH;
        if (all <= budget) return budget - all >= _lastPrice(b, 0) ? DEPTH : OK;
        return _value(b, 0, 1) > budget ? ZERO : OK;
    }

    /// @dev Independent `ShapeWord.check`: the whole bid side first, then the ask side.
    function _reason(uint256[4] memory words) internal pure returns (uint8 reason) {
        reason = _sideReason(words[0], words[1]);
        if (reason == 0) reason = _sideReason(words[2], words[3]);
    }

    /// @dev One side: reserved bits, then a decreasing spread among the levels before the first empty one, then
    /// anything but that prefix re-encoded.
    function _sideReason(uint256 w0, uint256 w1) internal pure returns (uint8) {
        if (w0 >> 240 != 0 || w1 >> 240 != 0) return ShapeWord.REASON_RESERVED_BITS;
        uint256 n;
        while (n < 10 && _slot(w0, w1, n) & (2 ** 32 - 1) != 0) {
            if (n > 0 && _slot(w0, w1, n) >> 32 < _slot(w0, w1, n - 1) >> 32) {
                return ShapeWord.REASON_SPREAD_DECREASES;
            }
            n += 1;
        }
        uint256 e0;
        uint256 e1;
        for (uint256 i; i < n; ++i) {
            if (i < 5) e0 |= _slot(w0, w1, i) << (48 * i);
            else e1 |= _slot(w0, w1, i) << (48 * (i - 5));
        }
        if (e0 != w0 || e1 != w1) return ShapeWord.REASON_NON_CANONICAL;
        return 0;
    }

    /// @dev One mutation of `words[w]`: flip a bit, overwrite a level slot, clear a level's size (a gap unless it was
    /// the last level), or replace the word.
    function _mutate(uint256[4] memory words, uint256 w, uint256 mode, uint256 r) internal pure {
        if (mode == 0) {
            words[w] ^= 1 << (r % 256);
        } else if (mode == 1) {
            uint256 j = r % 5;
            words[w] = (words[w] & ~(uint256(type(uint48).max) << (48 * j))) | (uint256(uint48(r >> 8)) << (48 * j));
        } else if (mode == 2) {
            words[w] &= ~(uint256(type(uint32).max) << (48 * (r % 5)));
        } else {
            words[w] = r;
        }
    }

    /// @dev A widthScale, widen and spread whose bid offset is exactly 1e8 - 1, so the level's factor is 1. The spread
    /// times widthScale must be 99,999,999 - 1000 x widen, which is 999 mod 1000: widthScale is 1 mod 1000 and the
    /// spread 999 mod 1000, stepped down in thousands (with widen up in widthScales) for variety.
    function _factorOne(uint256 r) internal pure returns (uint256 ws, uint256 widen, uint256 spread) {
        ws = 1 + 1000 * (1 + r % 65);
        uint256 most = (FACTOR_ONE - 1) / ws;
        if (most > type(uint16).max) most = type(uint16).max;
        spread = most - (most + 1) % 1000;
        widen = (FACTOR_ONE - 1 - spread * ws) / 1000;
        uint256 steps = (type(uint16).max - widen) / ws;
        if (steps > spread / 1000) steps = spread / 1000;
        uint256 t = (r >> 8) % (steps + 1);
        spread -= 1000 * t;
        widen += ws * t;
        assertEq(spread * ws + widen * 1000, FACTOR_ONE - 1, "factor one offset");
        assertLe(widen, type(uint16).max);
    }

    function _slot(uint256 w0, uint256 w1, uint256 i) internal pure returns (uint256) {
        return ((i < 5 ? w0 : w1) >> (48 * (i % 5))) & (2 ** 48 - 1);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Scenario generation
    // -----------------------------------------------------------------------------------------------------------------

    function _scenario(uint256 seed) internal pure returns (Market memory m, Fill memory l) {
        m = _market(seed);
        l.dir = _r(seed, 100) % 4;
        // A third of the fills start at the top of a fresh side, the rest some way down a consumed one, sometimes at
        // or past its depth.
        if (_r(seed, 101) % 3 != 0) l.consumed = _r(seed, 102) % (_left(_book(m, _baseIn(l.dir)), 0) + 2);
        Book memory b = _walk(m, l);
        uint256 left = _left(b, 0);
        uint256 cap = l.dir == SELL_BASE || l.dir == BUY_BASE ? left : _value(b, 0, left) / ONE + 1;
        cap = cap > type(uint128).max - 3 ? type(uint128).max : cap + 3;
        uint256 mode = _r(seed, 103) % 6;
        uint256 r = _r(seed, 104);
        if (mode == 0) l.amount = 1 + r % 5;
        else if (mode == 1) l.amount = 1 + r % cap;
        else if (mode == 2) l.amount = cap > 6 ? cap - r % 6 : cap;
        else if (mode == 3) l.amount = 1 + r % (1 + cap / 1000);
        else l.amount = _edgeAmount(b, 0, l.dir, r);
    }

    /// @dev An amount on a level edge of the book left after `consumed`. A base target gets the edge or one past it. A
    /// quote target gets the edge's value, or that plus one unit at the edge level's price or the next level's
    /// (the last level's own price past the end), rounded up to whole quote units. With a round mid the sum is often
    /// exact, and the remainder after the edge then ties a unit's price.
    function _edgeAmount(Book memory b, uint256 consumed, uint256 dir, uint256 r) internal pure returns (uint256) {
        // The nonempty levels left after `consumed`, in order.
        uint256[11] memory depth;
        uint256[11] memory price;
        uint256 count;
        for (uint256 i; i < b.n; ++i) {
            if (b.depth[i] > consumed) {
                depth[count] = b.depth[i] - consumed;
                price[count] = b.price[i];
                ++count;
                consumed = 0;
            } else {
                consumed -= b.depth[i];
            }
        }
        if (count == 0) return 1;
        uint256 k = r % count;
        uint256 edgeBase;
        uint256 edgeValue;
        for (uint256 i; i <= k; ++i) {
            edgeBase += depth[i];
            edgeValue += depth[i] * price[i];
        }
        uint256 amount;
        if (dir == SELL_BASE || dir == BUY_BASE) {
            amount = edgeBase + (r >> 8) % 2;
        } else {
            uint256 variant = (r >> 8) % 3;
            uint256 unit = variant == 1 || k + 1 == count ? price[k] : price[k + 1];
            uint256 v = variant == 0 ? edgeValue : edgeValue + unit;
            amount = v / ONE + (v % ONE == 0 ? 0 : 1);
        }
        if (amount == 0) return 1;
        return amount > type(uint128).max ? type(uint128).max : amount;
    }

    function _market(uint256 seed) internal pure returns (Market memory m) {
        (m.w0, m.w1) = _side(_r(seed, 1));
        uint256 r = _r(seed, 2);
        uint256 sizeMode = r % 4;
        m.sizeUnit = uint64(
            sizeMode == 0
                ? 1
                : sizeMode == 1 ? 1e6 : sizeMode == 2 ? 1 + (r >> 8) % 1e9 : 1 + (r >> 8) % type(uint64).max
        );
        HotWord.Fields memory f = HotWord.Fields({
            mid: uint96(_pickRange(_r(seed, 3), 0.9e18, 2e18, 1, 1e18, 1, type(uint96).max)),
            bidWiden: uint16(_pickRange(_r(seed, 4), 0, 0, 0, 100, 0, type(uint16).max)),
            askWiden: uint16(_pickRange(_r(seed, 5), 0, 0, 0, 100, 0, type(uint16).max)),
            widthScale: uint16(_pickRange(_r(seed, 6), 1000, 1000, 0, 3000, 0, type(uint16).max)),
            depthScale: uint16(_pickRange(_r(seed, 7), 1000, 1000, 1, 3000, 0, type(uint16).max)),
            shapeId: 0,
            validUntil: 1,
            seq: 2,
            flags: 0
        });
        // One market in three has a round mid (10^e or 5 x 10^e, mostly 0.1 to 50) and no widen, and two in three of
        // those no width either. Unit prices are then whole quote units or simple fractions, so a remainder can tie a
        // unit's price exactly, and with zero width every level has the same price.
        uint256 round = _r(seed, 8);
        if (round % 3 == 0) {
            uint256 e = (round >> 8) % 4 != 0 ? 17 + (round >> 16) % 3 : (round >> 16) % 29;
            f.mid = uint96((round >> 24) % 2 == 0 ? 10 ** e : 5 * 10 ** e);
            f.bidWiden = 0;
            f.askWiden = 0;
            if ((round >> 32) % 3 != 0) f.widthScale = 0;
        }
        m.hot = HotWord.pack(f);
    }

    /// @dev The number of levels `_side(seed)` builds.
    function _sideLevels(uint256 seed) internal pure returns (uint256) {
        return seed % 11;
    }

    /// @dev A random canonical side: 0-10 levels, sizes of three magnitudes, non-decreasing spreads.
    function _side(uint256 seed) internal pure returns (uint256 w0, uint256 w1) {
        uint256 n = _sideLevels(seed);
        uint32[] memory sizes = new uint32[](n);
        uint16[] memory spreads = new uint16[](n);
        uint256 spread = (seed >> 8) % 200;
        for (uint256 i; i < n; ++i) {
            uint256 r = _r(seed, i);
            uint256 step = r % 4;
            spread += step < 2 ? 0 : step == 2 ? (r >> 8) % 50 : (r >> 8) % 2000;
            if (spread > type(uint16).max) spread = type(uint16).max;
            uint256 magnitude = (r >> 32) % 3;
            sizes[i] = uint32(1 + (r >> 64) % (magnitude == 0 ? 100 : magnitude == 1 ? 1e6 : type(uint32).max));
            spreads[i] = uint16(spread);
        }
        (w0, w1) = ShapeWord.packSide(sizes, spreads);
    }

    /// @dev One of three ranges, chosen by the seed.
    function _pickRange(uint256 r, uint256 lo0, uint256 hi0, uint256 lo1, uint256 hi1, uint256 lo2, uint256 hi2)
        internal
        pure
        returns (uint256)
    {
        uint256 mode = r % 3;
        (uint256 lo, uint256 hi) = mode == 0 ? (lo0, hi0) : mode == 1 ? (lo1, hi1) : (lo2, hi2);
        return lo + (r >> 8) % (hi - lo + 1);
    }

    function _r(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// @dev Whether both amounts fit a uint128, as every venue fill must (the venue reverts `AmountOverflow`
    /// otherwise).
    function _fits(Result memory r) internal pure returns (bool) {
        return r.amountIn <= type(uint128).max && r.amountOut <= type(uint128).max;
    }

    function _baseIn(uint256 dir) internal pure returns (bool) {
        return dir == SELL_BASE || dir == WANT_QUOTE;
    }

    function _fill(Market memory m, Fill memory l) internal view returns (Result memory r) {
        bool exactIn = l.dir == SELL_BASE || l.dir == PAY_QUOTE;
        try harness.fillFrom(m.hot, m.sizeUnit, _baseIn(l.dir), m.w0, m.w1, exactIn, l.amount, l.consumed) returns (
            uint256 amountIn, uint256 amountOut, uint256 baseFilled
        ) {
            r = Result(OK, amountIn, amountOut, baseFilled);
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            if (selector == LadderMath.InsufficientDepth.selector) r.outcome = DEPTH;
            else if (selector == LadderMath.ZeroFill.selector) r.outcome = ZERO;
            else revert UnexpectedRevert(err);
        }
    }
}
