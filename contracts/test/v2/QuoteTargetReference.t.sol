// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { InventoryPath } from "./utils/InventoryPath.sol";
import { VenueFixture } from "./utils/VenueFixture.sol";

/// @notice Quote-target venue fills checked against the independent inventory-path reference. Unlike the venue's
/// level-by-level fill algorithm, this model searches for the base quantity whose exact rational value bounds the
/// requested quote. This pins the two modes the invariant campaign otherwise checks only for favorable pricing.
contract QuoteTargetReferenceTest is VenueFixture {
    uint256 internal constant ONE = 1e26;

    /// @dev Earlier fills can leave a partial first level or advance into the second shape word on the ask side.
    function testFuzz_quoteTargetMatchesIndependentReference(bool baseIn, uint128 prior, uint128 quoteAmount) public {
        prior = uint128(bound(prior, 0, 280e6));
        quoteAmount = uint128(bound(quoteAmount, 1e6, 80e6));
        if (prior != 0) _fill(pairId, baseIn, baseIn, prior);

        uint256 consumed = _consumed(pairId, baseIn);
        bytes32 hot = venue.hotWord(pairId);
        uint256[4] memory words = venue.shape(pairId, HotWord.shapeId(hot));
        InventoryPath.Side memory side = InventoryPath.side(hot, UNIT, words, baseIn);
        uint256 expectedBase = _referenceBase(side, consumed, quoteAmount * ONE, baseIn);
        (address tokenIn, address tokenOut) = _tokens(baseIn);

        (uint128 quotedIn, uint128 quotedOut) = venue.quote(pairId, tokenIn, tokenOut, quoteAmount, !baseIn);
        (uint128 filledIn, uint128 filledOut) = _fill(pairId, baseIn, !baseIn, quoteAmount);
        assertEq(filledIn, quotedIn, "fill input differs from quote");
        assertEq(filledOut, quotedOut, "fill output differs from quote");
        assertEq(baseIn ? filledIn : filledOut, expectedBase, "quote-target base differs from reference");
        assertEq(baseIn ? filledOut : filledIn, quoteAmount, "requested quote amount");
        assertEq(_consumed(pairId, baseIn), consumed + expectedBase, "consumed base");
    }

    /// @dev Independent of LadderMath: quote exact-out needs the least base with value >= target; quote exact-in
    /// buys the most base with value <= budget. The first and last levels also cover a partial consumed offset.
    function _referenceBase(InventoryPath.Side memory side, uint256 consumed, uint256 target, bool baseIn)
        internal
        pure
        returns (uint256)
    {
        uint256 total;
        for (uint256 i; i < side.n; ++i) {
            total += side.depth[i];
        }
        uint256 low;
        uint256 high = total - consumed;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            (, uint256 value) = InventoryPath.valueFrom(side, consumed, mid);
            if (baseIn ? value >= target : value > target) high = mid;
            else low = mid + 1;
        }
        // For an exact-in buy, `low` is the first unaffordable base amount, unless the book ends first.
        return baseIn ? low : low - 1;
    }
}
