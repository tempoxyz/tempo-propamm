// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The per-pair hot word: one slot, rewritten on every quote update. Packed least-significant bit first:
///
/// | Field        | Bits    | Meaning                                                         |
/// |--------------|---------|-----------------------------------------------------------------|
/// | `mid`        | 0-95    | Quote per 1 base, 18 dp. Never 0 once posted                    |
/// | `bidWiden`   | 96-111  | Extra spread on every bid level, 0.1 bp                         |
/// | `askWiden`   | 112-127 | Extra spread on every ask level, 0.1 bp                         |
/// | `widthScale` | 128-143 | Multiplier on ladder spreads, 1/1000 (1000 = 1x)                |
/// | `depthScale` | 144-159 | Multiplier on ladder sizes, 1/1000 (0 = no size)                |
/// | `shapeId`    | 160-167 | Active shape, 0-255                                             |
/// | `validUntil` | 168-207 | Unix seconds; the pair fills while `block.timestamp <= validUntil` |
/// | `seq`        | 208-239 | Rises on post; owner may reset to 1 while halted                 |
/// | `flags`      | 240-255 | Bit 0: bids off. Bit 1: asks off. Bit 2: refill bids. Bit 3: refill asks. 4-15: 0 |
///
/// The refill bits are actions, not state: `post` applies them to the pair's consumed depth (see `Venue.post`) and
/// stores the word without them.
library HotWord {
    /// @notice Every field of a hot word, unpacked. An off-chain helper, with `pack` and `unpack`, for scripts and
    /// tests: no contract in `src` uses them.
    struct Fields {
        uint96 mid;
        uint16 bidWiden;
        uint16 askWiden;
        uint16 widthScale;
        uint16 depthScale;
        uint8 shapeId;
        uint40 validUntil;
        uint32 seq;
        uint16 flags;
    }

    uint16 internal constant FLAG_BIDS_OFF = 1;
    uint16 internal constant FLAG_ASKS_OFF = 2;
    /// @dev When `post` accepts the word, the side's consumed base resets to 0, so its whole ladder is offered again.
    /// `post` stores and emits the word with both refill bits cleared, so a refill acts once: re-posting the stored
    /// word with a higher `seq` refills nothing.
    uint16 internal constant FLAG_REFILL_BIDS = 4;
    uint16 internal constant FLAG_REFILL_ASKS = 8;
    uint16 internal constant FLAGS_REFILL = FLAG_REFILL_BIDS | FLAG_REFILL_ASKS;
    uint16 internal constant FLAGS_MASK = 15;

    /// @dev The hot word `addPair` and `resetHotWord` store: `seq = 1`, everything else 0; unfillable until posted.
    bytes32 internal constant INITIAL = bytes32(uint256(1) << 208);

    function mid(bytes32 w) internal pure returns (uint96) {
        return uint96(uint256(w));
    }

    function bidWiden(bytes32 w) internal pure returns (uint16) {
        return uint16(uint256(w) >> 96);
    }

    function askWiden(bytes32 w) internal pure returns (uint16) {
        return uint16(uint256(w) >> 112);
    }

    function widthScale(bytes32 w) internal pure returns (uint16) {
        return uint16(uint256(w) >> 128);
    }

    function depthScale(bytes32 w) internal pure returns (uint16) {
        return uint16(uint256(w) >> 144);
    }

    function shapeId(bytes32 w) internal pure returns (uint8) {
        return uint8(uint256(w) >> 160);
    }

    function validUntil(bytes32 w) internal pure returns (uint40) {
        return uint40(uint256(w) >> 168);
    }

    function seq(bytes32 w) internal pure returns (uint32) {
        return uint32(uint256(w) >> 208);
    }

    function flags(bytes32 w) internal pure returns (uint16) {
        return uint16(uint256(w) >> 240);
    }

    /// @notice Whether the side a taker walks is switched off. `baseIn` (taker sells base) walks the bids.
    function sideOff(bytes32 w, bool baseIn) internal pure returns (bool) {
        return flags(w) & (baseIn ? FLAG_BIDS_OFF : FLAG_ASKS_OFF) != 0;
    }

    /// @notice `w` with both refill bits cleared: the word `post` stores and emits.
    function withoutRefill(bytes32 w) internal pure returns (bytes32) {
        return w & ~bytes32(uint256(FLAGS_REFILL) << 240);
    }

    /// @notice Well-formed for `post`: a nonzero mid and no reserved flag bits.
    function isWellFormed(bytes32 w) internal pure returns (bool) {
        return mid(w) != 0 && flags(w) & ~FLAGS_MASK == 0;
    }

    /// @notice Packs `f` into a hot word. An off-chain helper for scripts and tests: no contract in `src` calls it.
    function pack(Fields memory f) internal pure returns (bytes32) {
        return bytes32(
            uint256(f.mid) | (uint256(f.bidWiden) << 96) | (uint256(f.askWiden) << 112) | (uint256(f.widthScale) << 128)
                | (uint256(f.depthScale) << 144) | (uint256(f.shapeId) << 160) | (uint256(f.validUntil) << 168)
                | (uint256(f.seq) << 208) | (uint256(f.flags) << 240)
        );
    }

    /// @notice Unpacks every field of `w`. An off-chain helper for scripts and tests: no contract in `src` calls it.
    function unpack(bytes32 w) internal pure returns (Fields memory f) {
        f.mid = mid(w);
        f.bidWiden = bidWiden(w);
        f.askWiden = askWiden(w);
        f.widthScale = widthScale(w);
        f.depthScale = depthScale(w);
        f.shapeId = shapeId(w);
        f.validUntil = validUntil(w);
        f.seq = seq(w);
        f.flags = flags(w);
    }
}
