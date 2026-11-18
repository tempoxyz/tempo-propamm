// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice A shape is four words: bid levels 1-5, bid levels 6-10, ask levels 1-5, ask levels 6-10. Within a word,
/// level j (0-4) sits at bits 48j to 48j+47: a 32-bit size in the low bits, then a 16-bit spread (0.1 bp units).
/// Bits 240-255 must be 0.
/// @dev One canonical encoding per ladder, so the router and the chain can never disagree about a shape:
/// - a side ends at its first level with size 0, and every deeper level on that side must be all zero;
/// - within a side, raw spreads never decrease from one level to the next.
library ShapeWord {
    uint256 internal constant LEVELS_PER_WORD = 5;
    uint256 internal constant LEVEL_BITS = 48;
    uint256 internal constant MAX_LEVELS = 10;
    uint256 internal constant RESERVED_MASK = uint256(type(uint16).max) << 240;

    /// @dev `InvalidShape` reasons.
    uint8 internal constant REASON_RESERVED_BITS = 1;
    uint8 internal constant REASON_NON_CANONICAL = 2;
    uint8 internal constant REASON_SPREAD_DECREASES = 3;

    function size(uint256 word, uint256 j) internal pure returns (uint256) {
        return uint32(word >> (LEVEL_BITS * j));
    }

    function spread(uint256 word, uint256 j) internal pure returns (uint256) {
        return uint16(word >> (LEVEL_BITS * j + 32));
    }

    /// @notice Level `i` (0-9) of a side given its two words.
    function level(uint256 w0, uint256 w1, uint256 i) internal pure returns (uint256 levelSize, uint256 levelSpread) {
        uint256 word = i < LEVELS_PER_WORD ? w0 : w1;
        uint256 j = i < LEVELS_PER_WORD ? i : i - LEVELS_PER_WORD;
        return (size(word, j), spread(word, j));
    }

    /// @notice Whether a side continues into its second word: canonical encoding means the second word is nonzero
    /// only when level 5 (index 4) has size.
    function continues(uint256 w0) internal pure returns (bool) {
        return size(w0, LEVELS_PER_WORD - 1) != 0;
    }

    /// @notice 0 when the side is valid, else an `InvalidShape` reason.
    function checkSide(uint256 w0, uint256 w1) internal pure returns (uint8) {
        if (w0 & RESERVED_MASK != 0 || w1 & RESERVED_MASK != 0) return REASON_RESERVED_BITS;
        bool ended;
        uint256 lastSpread;
        for (uint256 i; i < MAX_LEVELS; ++i) {
            (uint256 s, uint256 sp) = level(w0, w1, i);
            if (ended) {
                if (s != 0 || sp != 0) return REASON_NON_CANONICAL;
            } else if (s == 0) {
                if (sp != 0) return REASON_NON_CANONICAL;
                ended = true;
            } else {
                if (sp < lastSpread) return REASON_SPREAD_DECREASES;
                lastSpread = sp;
            }
        }
        return 0;
    }

    /// @notice 0 when all four words form a valid shape, else an `InvalidShape` reason.
    function check(uint256[4] memory words) internal pure returns (uint8 reason) {
        reason = checkSide(words[0], words[1]);
        if (reason == 0) reason = checkSide(words[2], words[3]);
    }

    /// @notice Encodes one side. Arrays may be shorter than 10; missing levels are empty. An off-chain helper for
    /// scripts and tests: no contract in `src` calls it.
    function packSide(uint32[] memory sizes, uint16[] memory spreads) internal pure returns (uint256 w0, uint256 w1) {
        require(sizes.length == spreads.length && sizes.length <= MAX_LEVELS, "ShapeWord: bad side");
        for (uint256 i; i < sizes.length; ++i) {
            uint256 packed = uint256(sizes[i]) | (uint256(spreads[i]) << 32);
            if (i < LEVELS_PER_WORD) w0 |= packed << (LEVEL_BITS * i);
            else w1 |= packed << (LEVEL_BITS * (i - LEVELS_PER_WORD));
        }
    }
}
