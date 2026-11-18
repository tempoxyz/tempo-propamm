// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../src/v2/VenueFactory.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { CoreDeploy } from "../utils/CoreDeploy.sol";
import { Vectors } from "../utils/Vectors.sol";

/// @notice Replays the venue sections of the shared vectors (`contracts/test/vectors/propamm-v2-ladder.json`, or the
/// file `PROPAMM_VECTORS` names) through real venues: `quotes`, one pair's posts, quotes and fills in order, must get
/// the reference's amounts, reverts, consumption and inventory from `quote` and `fill`; `posts`, the batches both SDKs
/// pack, must store the reference's words and refill what it says. The TypeScript SDK replays the same sections against
/// the deployed core on a local Anvil (`sdk/ts/test/e2e/vectors.test.ts`).
/// @dev Each case gets its own venue, so its inventory is its own. The settler is a stand-in that moves the input into
/// the venue before `fill`, as the `Settler` does. Gas metering is paused: the cost is the JSON decoding.
contract VenueVectorsTest is Test {
    /// @dev Every step has every field; an op leaves the ones it doesn't use zero or empty. Field order must match
    /// `STEP_TYPE`.
    struct Step {
        string op;
        uint256 shapeId;
        uint256[] words;
        bytes32 word;
        bool accepted;
        bool baseIn;
        bool exactIn;
        uint256 amount;
        string expect;
        string[] args;
        uint256 amountIn;
        uint256 amountOut;
        uint256 baseFilled;
        uint256[] consumed;
        uint256[] inventory;
    }

    struct QuoteCase {
        string name;
        uint256 sizeUnit;
        uint256 timestamp;
        uint256[] inventory;
        Step[] steps;
    }

    struct PostVector {
        string name;
        string expect;
        bytes packed;
        uint256[][] posts;
        bytes32[] stored;
        uint256[] refills;
    }

    string internal constant QUOTE_CASE_TYPE = "QuoteCase(string name,uint256 sizeUnit,uint256 timestamp,uint256[] inventory,Step[] steps)"
        "Step(string op,uint256 shapeId,uint256[] words,bytes32 word,bool accepted,bool baseIn,bool exactIn,"
        "uint256 amount,string expect,string[] args,uint256 amountIn,uint256 amountOut,uint256 baseFilled,"
        "uint256[] consumed,uint256[] inventory)";
    string internal constant POST_TYPE =
        "PostVector(string name,string expect,bytes packed,uint256[][] posts,bytes32[] stored,uint256[] refills)";

    /// @dev Pairs a `posts` replay adds; batches that name a higher index are encoding-only.
    uint256 internal constant POST_PAIRS = 16;
    bytes32 internal constant REF = keccak256("vectors");

    address internal owner = makeAddr("owner");
    address internal settler = makeAddr("settler");
    address internal taker = makeAddr("taker");

    VenueFactory internal factory;
    MockTIP20V2 internal base;
    MockTIP20V2 internal quote;
    uint256 internal venues;

    function setUp() public {
        factory = CoreDeploy.factoryWith(settler);
        base = new MockTIP20V2("BASE", 6);
        quote = new MockTIP20V2("QUOTE", 6);
    }

    function test_quotes() public {
        vm.pauseGasMetering();
        QuoteCase[] memory cases =
            abi.decode(vm.parseJsonTypeArray(Vectors.json(), ".quotes", QUOTE_CASE_TYPE), (QuoteCase[]));
        uint256 fills;
        for (uint256 i; i < cases.length; ++i) {
            fills += _replay(cases[i]);
        }
        if (Vectors.committed()) {
            assertGe(cases.length, 10, "quote case count");
            assertGe(fills, 40, "fill count");
        }
    }

    function test_posts() public {
        vm.pauseGasMetering();
        PostVector[] memory posts =
            abi.decode(vm.parseJsonTypeArray(Vectors.json(), ".posts", POST_TYPE), (PostVector[]));
        uint256 replayed;
        for (uint256 i; i < posts.length; ++i) {
            if (_replayPost(posts[i])) ++replayed;
        }
        if (Vectors.committed()) assertGe(replayed, 6, "posts replayed");
    }

    /// @return fills The steps that filled.
    function _replay(QuoteCase memory c) internal returns (uint256 fills) {
        vm.warp(c.timestamp);
        Venue venue = _newVenue();
        vm.startPrank(owner);
        uint16 pairIndex = venue.addPair(address(base), address(quote), uint64(c.sizeUnit));
        venue.setHalted(true);
        venue.setPairAccess(pairIndex, IVenue.AccessMode.Open);
        venue.setHalted(false);
        vm.stopPrank();
        base.mint(address(venue), c.inventory[0]);
        quote.mint(address(venue), c.inventory[1]);

        for (uint256 j; j < c.steps.length; ++j) {
            Step memory s = c.steps[j];
            string memory label = string.concat(c.name, ": step ", vm.toString(j), " ", s.op);
            bytes32 op = keccak256(bytes(s.op));
            if (op == keccak256("setShape")) {
                assertEq(s.words.length, 4, label);
                vm.prank(owner);
                venue.setShape(pairIndex, uint8(s.shapeId), [s.words[0], s.words[1], s.words[2], s.words[3]]);
            } else if (op == keccak256("post")) {
                bytes32 before = venue.hotWord(pairIndex);
                vm.prank(owner);
                venue.post(abi.encodePacked(pairIndex, s.word));
                assertEq(venue.hotWord(pairIndex), s.accepted ? HotWord.withoutRefill(s.word) : before, label);
            } else if (op == keccak256("quote") || op == keccak256("fill")) {
                bool filled = _take(venue, pairIndex, s, op == keccak256("fill"), label);
                if (filled) ++fills;
            } else {
                revert(string.concat(label, ": unknown op"));
            }
            (uint128 bids, uint128 asks) = venue.consumed(pairIndex);
            assertEq(bids, s.consumed[0], string.concat(label, ": consumed bids"));
            assertEq(asks, s.consumed[1], string.concat(label, ": consumed asks"));
            assertEq(base.balanceOf(address(venue)), s.inventory[0], string.concat(label, ": base inventory"));
            assertEq(quote.balanceOf(address(venue)), s.inventory[1], string.concat(label, ": quote inventory"));
        }
    }

    /// @dev `quote` must match the step. A fill step then fills the same way, or reverts as `quote` did.
    function _take(Venue venue, uint16 pairIndex, Step memory s, bool isFill, string memory label)
        internal
        returns (bool filled)
    {
        (address tokenIn, address tokenOut) =
            s.baseIn ? (address(base), address(quote)) : (address(quote), address(base));
        assertLe(s.amount, type(uint128).max, label);
        uint128 amount = uint128(s.amount);
        bool ok = _eq(s.expect, "ok");
        try venue.quote(pairIndex, tokenIn, tokenOut, amount, s.exactIn) returns (uint128 amountIn, uint128 amountOut) {
            assertTrue(ok, string.concat(label, ": quoted, expected ", s.expect));
            assertEq(amountIn, s.amountIn, string.concat(label, ": quote amountIn"));
            assertEq(amountOut, s.amountOut, string.concat(label, ": quote amountOut"));
        } catch (bytes memory err) {
            assertEq(err, _revert(s), string.concat(label, ": quote revert"));
        }
        if (!isFill) return false;
        if (ok) MockTIP20V2(tokenIn).mint(address(venue), s.amountIn);
        vm.prank(settler);
        try venue.fill(pairIndex, tokenIn, tokenOut, amount, s.exactIn, taker, 0, REF) returns (
            uint128 amountIn, uint128 amountOut
        ) {
            assertTrue(ok, string.concat(label, ": filled, expected ", s.expect));
            assertEq(amountIn, s.amountIn, string.concat(label, ": fill amountIn"));
            assertEq(amountOut, s.amountOut, string.concat(label, ": fill amountOut"));
            filled = true;
        } catch (bytes memory err) {
            assertEq(err, _revert(s), string.concat(label, ": fill revert"));
        }
    }

    /// @return replayed False for a batch the SDKs refuse or one that names a pair past `POST_PAIRS`.
    function _replayPost(PostVector memory p) internal returns (bool replayed) {
        if (!_eq(p.expect, "ok")) return false;
        for (uint256 k; k < p.posts.length; ++k) {
            if (p.posts[k][0] >= POST_PAIRS) return false;
        }
        Venue venue = _newVenue();
        vm.startPrank(owner);
        for (uint256 i; i < POST_PAIRS; ++i) {
            venue.addPair(address(base), address(quote), 1);
        }
        vm.recordLogs();
        venue.post(p.packed);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 posted;
        uint256 refilled;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IVenue.Posted.selector) ++posted;
            if (logs[i].topics[0] == IVenue.Refilled.selector) {
                uint256 pairIndex = uint256(logs[i].topics[1]);
                (bool bids, bool asks) = abi.decode(logs[i].data, (bool, bool));
                uint256 k = _entry(p, pairIndex);
                assertEq(bids, p.refills[k] & HotWord.FLAG_REFILL_BIDS != 0, string.concat(p.name, ": refill bids"));
                assertEq(asks, p.refills[k] & HotWord.FLAG_REFILL_ASKS != 0, string.concat(p.name, ": refill asks"));
                ++refilled;
            }
        }
        uint256 refills;
        for (uint256 k; k < p.posts.length; ++k) {
            uint16 pairIndex = uint16(p.posts[k][0]);
            assertEq(venue.hotWord(pairIndex), p.stored[k], string.concat(p.name, ": stored word"));
            assertEq(HotWord.seq(p.stored[k]), p.posts[k][1], string.concat(p.name, ": sequence"));
            if (p.refills[k] != 0) ++refills;
        }
        assertEq(posted, p.posts.length, string.concat(p.name, ": Posted events"));
        assertEq(refilled, refills, string.concat(p.name, ": Refilled events"));
        return true;
    }

    function _entry(PostVector memory p, uint256 pairIndex) internal pure returns (uint256) {
        for (uint256 k; k < p.posts.length; ++k) {
            if (p.posts[k][0] == pairIndex) return k;
        }
        revert("Refilled for a pair the batch does not name");
    }

    /// @dev The revert data the step's error and arguments encode.
    function _revert(Step memory s) internal view returns (bytes memory) {
        bytes32 e = keccak256(bytes(s.expect));
        if (e == keccak256("ZeroAmount")) return abi.encodeWithSelector(IVenue.ZeroAmount.selector);
        if (e == keccak256("QuoteExpired")) {
            return abi.encodeWithSelector(IVenue.QuoteExpired.selector, uint40(vm.parseUint(s.args[0])));
        }
        if (e == keccak256("SideDisabled")) {
            return abi.encodeWithSelector(IVenue.SideDisabled.selector, vm.parseBool(s.args[0]));
        }
        if (e == keccak256("InsufficientDepth")) return abi.encodeWithSelector(IVenue.InsufficientDepth.selector);
        if (e == keccak256("ZeroFill")) return abi.encodeWithSelector(IVenue.ZeroFill.selector);
        if (e == keccak256("AmountOverflow")) return abi.encodeWithSelector(IVenue.AmountOverflow.selector);
        if (e == keccak256("InsufficientInventory")) {
            address token = _eq(s.args[0], "base") ? address(base) : address(quote);
            return abi.encodeWithSelector(
                IVenue.InsufficientInventory.selector, token, vm.parseUint(s.args[1]), vm.parseUint(s.args[2])
            );
        }
        revert(string.concat("no encoding for ", s.expect));
    }

    function _newVenue() internal returns (Venue) {
        return Venue(factory.createVenue(owner, bytes32(++venues)));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
