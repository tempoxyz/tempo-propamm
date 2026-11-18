// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HotWord } from "./HotWord.sol";
import { ShapeWord } from "./ShapeWord.sol";

/// @notice Prices one fill against a stepped ladder. The TypeScript router must reproduce this bit for bit.
/// @dev Price factors are over `FACTOR_ONE = 1e8`, so one denominator `1e26` (1e18 mid x 1e8 factor) covers all cases:
/// - ask level i: `fA = 1e8 + spread_i * widthScale + askWiden * 1000`;
/// - bid level i: `fB = 1e8 - spread_i * widthScale - bidWiden * 1000`. At or past 0 the level and every deeper one
///   are unfillable (the bid floor);
/// - effective size: `e_i = floor(size_i * sizeUnit * depthScale / 1000)`, in base-token units.
///
/// A fill walks the ladder in order from `consumed` base units down: the venue stores, per pair and side, the base its
/// fills have taken since the maker last refilled that side, so each fill starts where the last one stopped and pays
/// the deeper levels' prices. The offset is in base units of the ladder now posted, whatever ladder the earlier fills
/// walked: it comes off the top of the current shape at the current `depthScale`. An offset at or past the side's depth
/// leaves nothing to fill, and the fill reverts `InsufficientDepth` like any fill larger than the book.
///
/// Exactly one rounding per fill, always toward the maker, by less than one unit of the rounded token. Every numerator
/// is accumulated across the levels before that one rounding:
///
/// | Taker                   | Result                                     | Rounding |
/// |-------------------------|--------------------------------------------|----------|
/// | sells base, exact in    | `quoteOut = floor(sum(b_i * mid * fB_i) / 1e26)` | floor |
/// | buys base, exact out    | `quoteIn = ceil(sum(b_i * mid * fA_i) / 1e26)`   | ceil  |
/// | pays quote, exact in    | `baseOut = full levels + floor(R / (mid * fA_k))` | floor |
/// | wants quote, exact out  | `baseIn = full levels + ceil(R / (mid * fB_k))`   | ceil  |
///
/// Here `b_i` is the base taken at each step of the book, in the ladder. In the last two rows `R` is what is left
/// of `amount * 1e26` after the full steps and `k` is the partial one. Paying quote exact-in stops as soon as the
/// remainder can't buy one more base unit; the maker keeps that dust. If it takes every step and the remainder could
/// still buy a unit at the last step's price, the fill needs more than the book holds and reverts `InsufficientDepth`.
/// A level whose effective size floors to 0 holds nothing and is skipped; it does not end the side.
/// `InsufficientDepth` takes precedence over `ZeroFill`.
///
/// Bounds: `e_i < 2^103`, `mid < 2^96`, `f <= 4,460,371,225`. Each level's numerator is below
/// 2^232, so the ten-level sum and checked uint256 math cannot overflow for a uint128 amount, and any `consumed`
/// offset only skips levels. A filled side's offset plus its `baseFilled` never exceeds the side's depth, which is
/// below 2^107.
/// Preconditions enforced by the venue: a canonical side, nonzero mid and amount, and amount below 2^128.
///
/// While the posted word and shape stay the same the book is fixed, and each fill moves the offset by exactly the base
/// it took, so fills chained through the offset walk the same book as one fill of their total: splitting an order
/// never beats sending it whole, and each part rounds toward the maker on its own.
library LadderMath {
    uint256 internal constant FACTOR_ONE = 1e8;
    uint256 internal constant DENOMINATOR = 1e26;
    uint256 internal constant SCALE_ONE = 1000;

    error InsufficientDepth();
    error ZeroFill();

    struct Curve {
        uint256 mid;
        /// @dev `bidWiden` on the bid side, `askWiden` on the ask side.
        uint256 widen;
        uint256 widthScale;
        uint256 depthScale;
        uint256 sizeUnit;
        /// @dev True when the taker sells base and walks the bids.
        bool bid;
    }

    function curve(bytes32 hot, uint64 sizeUnit, bool baseIn) internal pure returns (Curve memory c) {
        c.mid = HotWord.mid(hot);
        c.widen = baseIn ? HotWord.bidWiden(hot) : HotWord.askWiden(hot);
        c.widthScale = HotWord.widthScale(hot);
        c.depthScale = HotWord.depthScale(hot);
        c.sizeUnit = sizeUnit;
        c.bid = baseIn;
    }

    /// @notice A level's price factor over `FACTOR_ONE`, or 0 when a bid level is at or past the floor.
    function factor(Curve memory c, uint256 spread) internal pure returns (uint256) {
        uint256 offset = spread * c.widthScale + c.widen * SCALE_ONE;
        if (!c.bid) return FACTOR_ONE + offset;
        return offset >= FACTOR_ONE ? 0 : FACTOR_ONE - offset;
    }

    /// @notice Base units a level holds: `floor(rawSize * sizeUnit * depthScale / 1000)`, floored per level.
    function effectiveSize(Curve memory c, uint256 rawSize) internal pure returns (uint256) {
        return rawSize * c.sizeUnit * c.depthScale / SCALE_ONE;
    }

    /// @notice Prices one fill. `amount` is the input when `exactIn`, else the output. Reverts `InsufficientDepth`
    /// when the book left after `consumed` can't cover the fill and `ZeroFill` when either side of the result is 0.
    /// @param w0 The side's first word (levels 1-5).
    /// @param w1 The side's second word (levels 6-10); pass 0 when `ShapeWord.continues(w0)` is false.
    /// @param consumed Base the side's ladder has already given up; the walk starts after it.
    /// @return amountIn The taker's input.
    /// @return amountOut The taker's output.
    /// @return baseFilled Base moved on this side, which the venue adds to the side's `consumed`.
    function fill(Curve memory c, uint256 w0, uint256 w1, bool exactIn, uint256 amount, uint256 consumed)
        internal
        pure
        returns (uint256 amountIn, uint256 amountOut, uint256 baseFilled)
    {
        // Selling base exact-in and buying base exact-out both walk toward a base target; the other two walk toward
        // a quote target, held scaled by the denominator.
        bool baseTarget = c.bid == exactIn;
        uint256 remaining = baseTarget ? amount : amount * DENOMINATOR;
        uint256 numerator;
        bool done;

        for (uint256 i; i < ShapeWord.MAX_LEVELS; ++i) {
            (uint256 rawSize, uint256 spread) = ShapeWord.level(w0, w1, i);
            if (rawSize == 0) break;
            uint256 f = factor(c, spread);
            if (f == 0) break;

            // The levels the side's earlier fills took, and any empty level, hold nothing for this one.
            uint256 available = effectiveSize(c, rawSize);
            if (consumed >= available) {
                consumed -= available;
                continue;
            }
            available -= consumed;
            consumed = 0;

            uint256 unitPrice = c.mid * f;
            if (baseTarget) {
                uint256 take = available < remaining ? available : remaining;
                numerator += take * unitPrice;
                baseFilled += take;
                remaining -= take;
                if (remaining == 0) {
                    done = true;
                    break;
                }
            } else {
                uint256 value = available * unitPrice;
                if (c.bid) {
                    // Wants quote exact-out: the smallest base whose value covers the remaining quote.
                    if (value >= remaining) {
                        baseFilled += (remaining + unitPrice - 1) / unitPrice;
                        done = true;
                        break;
                    }
                    baseFilled += available;
                    remaining -= value;
                } else {
                    // Pays quote exact-in: the most base the remaining quote buys. Deeper asks are never cheaper, so
                    // once the remainder can't buy one unit here it can't buy one anywhere.
                    if (value > remaining) {
                        baseFilled += remaining / unitPrice;
                        done = true;
                        break;
                    }
                    baseFilled += available;
                    remaining -= value;
                    if (remaining < unitPrice) {
                        done = true;
                        break;
                    }
                }
            }
        }

        if (!done) revert InsufficientDepth();

        if (baseTarget) {
            if (c.bid) {
                amountIn = amount;
                amountOut = numerator / DENOMINATOR;
            } else {
                amountIn = (numerator + DENOMINATOR - 1) / DENOMINATOR;
                amountOut = amount;
            }
        } else if (c.bid) {
            amountIn = baseFilled;
            amountOut = amount;
        } else {
            amountIn = amount;
            amountOut = baseFilled;
        }
        if (amountIn == 0 || amountOut == 0) revert ZeroFill();
    }
}
