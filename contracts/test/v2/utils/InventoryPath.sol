// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice An independent reference for trading base units down a posted ladder, from its first level or after the
/// base earlier fills consumed.
/// @dev Prices are quote units times 1e26 per base unit. Hot words and shapes are decoded directly from their
/// bit layouts, independently of `LadderMath`, `HotWord` and `ShapeWord`.
library InventoryPath {
    uint256 internal constant ONE = 1e26;
    uint256 internal constant FACTOR_ONE = 1e8;

    /// @dev One side as `n` levels of `depth[i]` base units at `price[i]`, cut at the bid floor.
    struct Side {
        uint256 n;
        uint256[10] depth;
        uint256[10] price;
    }

    /// @notice The side a taker walks: the bids when it sells base (`baseIn`), else the asks.
    function side(bytes32 hot, uint256 sizeUnit, uint256[4] memory words, bool baseIn)
        internal
        pure
        returns (Side memory s)
    {
        uint256 h = uint256(hot);
        uint256 mid = h & (2 ** 96 - 1);
        uint256 widen = (h >> (baseIn ? 96 : 112)) & 0xffff;
        uint256 widthScale = (h >> 128) & 0xffff;
        uint256 depthScale = (h >> 144) & 0xffff;
        uint256 w0 = baseIn ? words[0] : words[2];
        uint256 w1 = baseIn ? words[1] : words[3];
        for (uint256 i; i < 10; ++i) {
            uint256 slot = ((i < 5 ? w0 : w1) >> (48 * (i % 5))) & (2 ** 48 - 1);
            uint256 size = slot & (2 ** 32 - 1);
            if (size == 0) break;
            uint256 offset = (slot >> 32) * widthScale + widen * 1000;
            if (baseIn && offset >= FACTOR_ONE) break;
            s.depth[s.n] = size * sizeUnit * depthScale / 1000;
            s.price[s.n] = mid * (baseIn ? FACTOR_ONE - offset : FACTOR_ONE + offset);
            s.n += 1;
        }
    }

    /// @notice Exact value of `base` units from the first level, or `ok = false` beyond the posted depth.
    function value(Side memory s, uint256 base) internal pure returns (bool ok, uint256 v) {
        return valueFrom(s, 0, base);
    }

    /// @notice Exact value of the `base` units after the first `from`, or `ok = false` beyond the posted depth.
    function valueFrom(Side memory s, uint256 from, uint256 base) internal pure returns (bool ok, uint256 v) {
        uint256 left = base;
        for (uint256 i; i < s.n && left != 0; ++i) {
            uint256 depth = s.depth[i];
            if (from >= depth) {
                from -= depth;
                continue;
            }
            depth -= from;
            from = 0;
            uint256 take = left < depth ? left : depth;
            v += take * s.price[i];
            left -= take;
        }
        ok = left == 0;
    }

    /// @notice The price of the unit at position `pos` (0-based), or `ok = false` when the side holds no such unit.
    function priceAt(Side memory s, uint256 pos) internal pure returns (bool ok, uint256 price) {
        for (uint256 i; i < s.n; ++i) {
            if (pos < s.depth[i]) return (true, s.price[i]);
            pos -= s.depth[i];
        }
    }
}

/// @notice `InventoryPath` behind external calls. Its walks are large enough that inlining them into a suite with
/// many locals of its own can run out of stack under via_ir, as `LadderOracle` does for `LadderMath`.
contract InventoryPathOracle {
    function side(bytes32 hot, uint256 sizeUnit, uint256[4] calldata words, bool baseIn)
        external
        pure
        returns (InventoryPath.Side memory)
    {
        return InventoryPath.side(hot, sizeUnit, words, baseIn);
    }

    function value(InventoryPath.Side calldata s, uint256 base) external pure returns (bool ok, uint256 v) {
        return InventoryPath.value(s, base);
    }

    function valueFrom(InventoryPath.Side calldata s, uint256 from, uint256 base)
        external
        pure
        returns (bool ok, uint256 v)
    {
        return InventoryPath.valueFrom(s, from, base);
    }

    function priceAt(InventoryPath.Side calldata s, uint256 pos) external pure returns (bool ok, uint256 price) {
        return InventoryPath.priceAt(s, pos);
    }
}
