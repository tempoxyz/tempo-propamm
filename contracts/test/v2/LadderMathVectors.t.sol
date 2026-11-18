// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";

import { LadderMathHarness } from "./harness/LadderMathHarness.sol";
import { Vectors } from "./utils/Vectors.sol";

/// @notice Replays the shared vectors that `test/vectors/ladder-reference.mjs` generates from an independent BigInt
/// model of the ladder math and the hot-word and shape encodings. The Rust and TypeScript SDKs replay the same file
/// (`sdk/rust/tests/vectors.rs`, `sdk/ts/test/vectors.test.ts`), and `integration/VenueVectors.t.sol` its venue sections. With
/// `PROPAMM_VECTORS` set, every test here replays that file instead: a seeded random set from `test/vectors/fuzz.mjs`.
/// @dev Gas metering is paused in every test here: the cost is almost all JSON decoding and grows with the file, so a
/// metered entry would churn the gas snapshot on every vector change without tracking anything. `LadderMath.t.sol`
/// meters the pricing itself.
contract LadderMathVectorsTest is Test {
    /// @dev Field order must match `VECTOR_TYPE`.
    struct Vector {
        string name;
        string direction;
        bool baseIn;
        bool exactIn;
        bytes32 hot;
        uint256 mid;
        uint256 widen;
        uint256 widthScale;
        uint256 depthScale;
        uint256 sizeUnit;
        uint256 w0;
        uint256 w1;
        uint256 amount;
        uint256 consumed;
        string expect;
        uint256 amountIn;
        uint256 amountOut;
        uint256 baseFilled;
    }

    /// @dev One order sent as parts chained through `consumed`, and one fill of what the parts traded.
    struct VectorSplit {
        string name;
        uint256 whole;
        uint256[] parts;
    }

    struct ShapeCheck {
        string name;
        uint256[] words;
        uint256 reason;
    }

    string internal constant VECTOR_TYPE = "Vector(string name,string direction,bool baseIn,bool exactIn,bytes32 hot,"
        "uint256 mid,uint256 widen,uint256 widthScale,uint256 depthScale,uint256 sizeUnit,uint256 w0,uint256 w1,"
        "uint256 amount,uint256 consumed,string expect,uint256 amountIn,uint256 amountOut,uint256 baseFilled)";
    string internal constant SPLIT_TYPE = "VectorSplit(string name,uint256 whole,uint256[] parts)";
    string internal constant SHAPE_CHECK_TYPE = "ShapeCheck(string name,uint256[] words,uint256 reason)";

    /// @dev Every field, the packed word, the word `post` stores and whether `post` accepts it.
    struct HotWordVector {
        string name;
        uint256 mid;
        uint256 bidWiden;
        uint256 askWiden;
        uint256 widthScale;
        uint256 depthScale;
        uint256 shapeId;
        uint256 validUntil;
        uint256 seq;
        uint256 flags;
        bytes32 word;
        bytes32 stored;
        bool wellFormed;
    }

    /// @dev Two canonical ladders and their four words.
    struct ShapeVector {
        string name;
        uint256[] bidSizes;
        uint256[] bidSpreads;
        uint256[] askSizes;
        uint256[] askSpreads;
        uint256[] words;
    }

    string internal constant HOT_WORD_TYPE = "HotWordVector(string name,uint256 mid,uint256 bidWiden,uint256 askWiden,"
        "uint256 widthScale,uint256 depthScale,uint256 shapeId,uint256 validUntil,uint256 seq,uint256 flags,bytes32 word,"
        "bytes32 stored,bool wellFormed)";
    string internal constant SHAPE_TYPE = "ShapeVector(string name,uint256[] bidSizes,uint256[] bidSpreads,"
        "uint256[] askSizes,uint256[] askSpreads,uint256[] words)";

    LadderMathHarness internal harness;

    function setUp() public {
        harness = new LadderMathHarness();
    }

    function test_vectors() public {
        vm.pauseGasMetering();
        Vector[] memory vs = abi.decode(vm.parseJsonTypeArray(_json(), ".vectors", VECTOR_TYPE), (Vector[]));
        bool committed = Vectors.committed();
        if (committed) assertGe(vs.length, 300, "vector count");

        // [direction][ok, InsufficientDepth, ZeroFill], and the same for vectors that start from consumed depth.
        uint256[3][4] memory seen;
        uint256[3][4] memory seenConsumed;
        for (uint256 i; i < vs.length; ++i) {
            uint256 outcome = _run(vs[i]);
            seen[_direction(vs[i])][outcome] += 1;
            if (vs[i].consumed != 0) seenConsumed[_direction(vs[i])][outcome] += 1;
        }
        if (!committed) return;
        for (uint256 d; d < 4; ++d) {
            assertGt(seen[d][0], 0, "every direction has fills");
            assertGt(seen[d][1], 0, "every direction has InsufficientDepth");
            assertGt(seenConsumed[d][0], 0, "every direction fills from consumed depth");
            assertGt(seenConsumed[d][1], 0, "every direction exhausts consumed depth");
        }
        assertGt(seen[0][2] + seen[2][2], 0, "exact-in ZeroFill covered");
    }

    /// @dev Each split's parts chain through `consumed` (each starts where the filled ones before it left the side,
    /// and a part that reverts trades nothing) and together never beat one fill of what they traded from the same
    /// offset: exact in, no more output for the same input; exact out, no less input for the same output.
    function test_splitsNeverBeatOneFill() public {
        vm.pauseGasMetering();
        string memory json = _json();
        Vector[] memory vs = abi.decode(vm.parseJsonTypeArray(json, ".vectors", VECTOR_TYPE), (Vector[]));
        VectorSplit[] memory splits = abi.decode(vm.parseJsonTypeArray(json, ".splits", SPLIT_TYPE), (VectorSplit[]));
        bool committed = Vectors.committed();
        if (committed) assertGe(splits.length, 40, "split count");
        uint256 dust;
        for (uint256 i; i < splits.length; ++i) {
            VectorSplit memory sp = splits[i];
            Vector memory whole = vs[sp.whole];
            assertEq(whole.expect, "ok", sp.name);
            uint256 consumed = whole.consumed;
            uint256 traded;
            uint256 paid;
            uint256 received;
            for (uint256 k; k < sp.parts.length; ++k) {
                Vector memory part = vs[sp.parts[k]];
                assertEq(part.consumed, consumed, string.concat(sp.name, ": part starts where the last stopped"));
                assertEq(part.direction, whole.direction, sp.name);
                assertEq(part.hot, whole.hot, sp.name);
                if (!_eq(part.expect, "ok")) {
                    ++dust;
                    continue;
                }
                consumed += part.baseFilled;
                traded += part.amount;
                paid += part.amountIn;
                received += part.amountOut;
            }
            assertEq(whole.amount, traded, sp.name);
            if (whole.exactIn) assertLe(received, whole.amountOut, string.concat(sp.name, ": split paid out more"));
            else assertGe(paid, whole.amountIn, string.concat(sp.name, ": split cost less"));
        }
        if (committed) assertGt(dust, 0, "dust parts covered");
    }

    function test_companionVector() public {
        vm.pauseGasMetering();
        vm.skip(!Vectors.committed());
        Vector memory v = abi.decode(vm.parseJsonType(_json(), ".vectors[0]", VECTOR_TYPE), (Vector));
        assertEq(v.name, "companion: buy 1 EUR exact out at 1.085217");
        assertEq(v.mid, 1.085e18);
        assertEq(v.amountIn, 1_085_217);
        assertEq(v.amountOut, 1e6);
        _run(v);
    }

    function test_shapeChecks() public {
        vm.pauseGasMetering();
        ShapeCheck[] memory cs =
            abi.decode(vm.parseJsonTypeArray(_json(), ".shapeChecks", SHAPE_CHECK_TYPE), (ShapeCheck[]));
        bool committed = Vectors.committed();
        if (committed) assertGe(cs.length, 20, "shape check count");
        uint256[4] memory reasons;
        for (uint256 i; i < cs.length; ++i) {
            ShapeCheck memory c = cs[i];
            assertEq(c.words.length, 4, c.name);
            uint256[4] memory words = [c.words[0], c.words[1], c.words[2], c.words[3]];
            assertEq(harness.check(words), c.reason, c.name);
            reasons[c.reason] += 1;
        }
        if (!committed) return;
        for (uint256 r; r < 4; ++r) {
            assertGt(reasons[r], 0, "every reason covered");
        }
    }

    /// @dev `HotWord.unpack` reads every field the reference packed and `pack` rebuilds the word, and `isWellFormed`,
    /// `withoutRefill` and `sideOff` agree with it.
    function test_hotWords() public {
        vm.pauseGasMetering();
        HotWordVector[] memory hs =
            abi.decode(vm.parseJsonTypeArray(_json(), ".hotWords", HOT_WORD_TYPE), (HotWordVector[]));
        bool committed = Vectors.committed();
        if (committed) assertGe(hs.length, 50, "hot word count");
        uint256[2] memory wellFormed;
        for (uint256 i; i < hs.length; ++i) {
            HotWordVector memory h = hs[i];
            HotWord.Fields memory f = HotWord.unpack(h.word);
            assertEq(f.mid, h.mid, string.concat(h.name, ": mid"));
            assertEq(f.bidWiden, h.bidWiden, string.concat(h.name, ": bidWiden"));
            assertEq(f.askWiden, h.askWiden, string.concat(h.name, ": askWiden"));
            assertEq(f.widthScale, h.widthScale, string.concat(h.name, ": widthScale"));
            assertEq(f.depthScale, h.depthScale, string.concat(h.name, ": depthScale"));
            assertEq(f.shapeId, h.shapeId, string.concat(h.name, ": shapeId"));
            assertEq(f.validUntil, h.validUntil, string.concat(h.name, ": validUntil"));
            assertEq(f.seq, h.seq, string.concat(h.name, ": seq"));
            assertEq(f.flags, h.flags, string.concat(h.name, ": flags"));
            assertEq(HotWord.pack(f), h.word, h.name);
            assertEq(HotWord.isWellFormed(h.word), h.wellFormed, string.concat(h.name, ": isWellFormed"));
            assertEq(HotWord.withoutRefill(h.word), h.stored, string.concat(h.name, ": withoutRefill"));
            assertEq(HotWord.sideOff(h.word, true), h.flags & HotWord.FLAG_BIDS_OFF != 0, h.name);
            assertEq(HotWord.sideOff(h.word, false), h.flags & HotWord.FLAG_ASKS_OFF != 0, h.name);
            wellFormed[h.wellFormed ? 1 : 0] += 1;
        }
        if (committed) {
            assertGt(wellFormed[0], 0, "malformed words covered");
            assertGt(wellFormed[1], 0, "well-formed words covered");
        }
    }

    /// @dev `ShapeWord.packSide` encodes both ladders into the reference's words, which `ShapeWord.check` accepts.
    function test_shapes() public {
        vm.pauseGasMetering();
        ShapeVector[] memory ss = abi.decode(vm.parseJsonTypeArray(_json(), ".shapes", SHAPE_TYPE), (ShapeVector[]));
        if (Vectors.committed()) assertGe(ss.length, 20, "shape count");
        for (uint256 i; i < ss.length; ++i) {
            ShapeVector memory s = ss[i];
            assertEq(s.words.length, 4, s.name);
            uint256[4] memory words;
            (words[0], words[1]) = ShapeWord.packSide(_sizes(s.bidSizes), _spreads(s.bidSpreads));
            (words[2], words[3]) = ShapeWord.packSide(_sizes(s.askSizes), _spreads(s.askSpreads));
            for (uint256 w; w < 4; ++w) {
                assertEq(words[w], s.words[w], string.concat(s.name, ": word ", vm.toString(w)));
            }
            assertEq(harness.check(words), 0, s.name);
        }
    }

    /// @dev The selector the reference builds `post` calldata with, which both SDKs' calldata starts with.
    function test_postSelector() public {
        vm.pauseGasMetering();
        assertEq(bytes4(vm.parseJsonBytes(_json(), ".postSelector")), IVenue.post.selector);
    }

    function _sizes(uint256[] memory raw) internal pure returns (uint32[] memory out) {
        out = new uint32[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            assertLe(raw[i], type(uint32).max, "size");
            out[i] = uint32(raw[i]);
        }
    }

    function _spreads(uint256[] memory raw) internal pure returns (uint16[] memory out) {
        out = new uint16[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            assertLe(raw[i], type(uint16).max, "spread");
            out[i] = uint16(raw[i]);
        }
    }

    /// @return outcome 0 for a fill, 1 for `InsufficientDepth`, 2 for `ZeroFill`.
    function _run(Vector memory v) internal view returns (uint256 outcome) {
        // The vector's readable fields must be what the hot word encodes.
        bytes32 hot = v.hot;
        assertEq(HotWord.mid(hot), v.mid, v.name);
        assertEq(v.baseIn ? HotWord.bidWiden(hot) : HotWord.askWiden(hot), v.widen, v.name);
        assertEq(HotWord.widthScale(hot), v.widthScale, v.name);
        assertEq(HotWord.depthScale(hot), v.depthScale, v.name);
        assertTrue(HotWord.isWellFormed(hot), v.name);
        assertLe(v.sizeUnit, type(uint64).max, v.name);
        assertLe(v.amount, type(uint128).max, v.name);
        // The venue passes w1 only when the side continues, and every vector side is canonical.
        if (!ShapeWord.continues(v.w0)) assertEq(v.w1, 0, v.name);
        assertEq(ShapeWord.checkSide(v.w0, v.w1), 0, v.name);

        try harness.fillFrom(hot, uint64(v.sizeUnit), v.baseIn, v.w0, v.w1, v.exactIn, v.amount, v.consumed) returns (
            uint256 amountIn, uint256 amountOut, uint256 baseFilled
        ) {
            assertEq(v.expect, "ok", v.name);
            assertEq(amountIn, v.amountIn, string.concat(v.name, ": amountIn"));
            assertEq(amountOut, v.amountOut, string.concat(v.name, ": amountOut"));
            assertEq(baseFilled, v.baseFilled, string.concat(v.name, ": baseFilled"));
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            if (selector == LadderMath.InsufficientDepth.selector) {
                assertEq(v.expect, "InsufficientDepth", v.name);
                outcome = 1;
            } else if (selector == LadderMath.ZeroFill.selector) {
                assertEq(v.expect, "ZeroFill", v.name);
                outcome = 2;
            } else {
                revert(string.concat(v.name, ": unexpected revert"));
            }
        }
    }

    function _direction(Vector memory v) internal pure returns (uint256) {
        if (v.baseIn) return v.exactIn ? 0 : 3;
        return v.exactIn ? 2 : 1;
    }

    function _json() internal view returns (string memory) {
        return Vectors.json();
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
