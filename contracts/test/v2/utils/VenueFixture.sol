// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { ShapeWord } from "../../../src/v2/libraries/ShapeWord.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../src/v2/VenueFactory.sol";
import { MockAddressRegistry } from "../../mocks/MockAddressRegistry.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { CoreDeploy } from "./CoreDeploy.sol";
import { LadderMathOracle } from "./LadderMathOracle.sol";

/// @notice Shared setup for the venue suites: a mock address registry and tokens, a factory, one venue owned by `owner` with
/// an updater, and one live pair (EUR/USD, `Open`) with a seven-level ask and a three-level bid. Fills pay the taker.
abstract contract VenueFixture is Test {
    /// @dev The fixture's clock at setup. Tests count from it rather than from a `block.timestamp` local, which via_ir
    /// may re-read after a `vm.warp`.
    uint256 internal constant START = 1_800_000_000;
    uint64 internal constant UNIT = 1e6;
    uint96 internal constant MID = 1.085e18;
    uint256 internal constant INVENTORY = 10_000e6;
    uint40 internal constant TTL = 60;
    bytes32 internal constant REF = keccak256("ref");
    /// @dev The `sponsorId` that names the venue's home list.
    uint64 internal constant HOME = 0;

    // Storage slots, from `forge inspect Venue storageLayout`.
    uint256 internal constant SLOT_OWNER = 0;
    /// @dev `settler`, then every other venue-wide word a fill reads: `halted` and the deny count.
    uint256 internal constant SLOT_SETTLER = 1;
    uint256 internal constant SLOT_PAIRS = 4;
    uint256 internal constant SLOT_HOOKS = 5;
    uint256 internal constant SLOT_HOT = 6;
    uint256 internal constant SLOT_SHAPES = 7;
    uint256 internal constant SLOT_MID_BANDS = 8;
    uint256 internal constant SLOT_DENIED = 9;
    uint256 internal constant SLOT_SPONSORS = 10;
    uint256 internal constant SLOT_PENDING_SPONSOR_ADMIN = 11;
    uint256 internal constant SLOT_ADMITTED = 12;
    uint256 internal constant SLOT_MEMBERS = 13;
    /// @dev The banded-pair counter sits in slot 0 after `owner` and `pairCount`.
    uint256 internal constant BANDED_PAIRS_SHIFT = 176;

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal settler = makeAddr("settler");
    address internal taker = makeAddr("taker");
    address internal stranger = makeAddr("stranger");

    /// @dev The TIP-1022 resolution the mock tokens apply to every transfer, as Tempo's TIP-20 forwards a transfer to a
    /// virtual address on to its master. The venue resolves nothing.
    MockAddressRegistry internal resolver;
    VenueFactory internal factory;
    Venue internal venue;
    MockTIP20V2 internal eur;
    MockTIP20V2 internal usd;
    LadderMathOracle internal oracle;
    uint16 internal pairId;

    function setUp() public virtual {
        vm.warp(START);
        resolver = new MockAddressRegistry();
        factory = CoreDeploy.factoryWith(settler);
        venue = Venue(factory.createVenue(owner, bytes32("maker")));
        oracle = new LadderMathOracle();

        eur = new MockTIP20V2("EURC", 6);
        usd = new MockTIP20V2("USDC", 6);
        eur.setResolver(resolver);
        usd.setResolver(resolver);

        vm.startPrank(owner);
        venue.setUpdater(updater, true);
        pairId = venue.addPair(address(eur), address(usd), UNIT);
        venue.setShape(pairId, 0, _defaultShape());
        vm.stopPrank();
        _setAccess(pairId, IVenue.AccessMode.Open);
        _post(pairId, _hot(2));

        eur.mint(address(venue), INVENTORY);
        usd.mint(address(venue), INVENTORY);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Access
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Sets the pair's mode as the owner. `Open` needs a halted venue, so this halts around it and restores the
    /// venue's halt state after.
    function _setAccess(uint16 pairIndex, IVenue.AccessMode mode) internal {
        bool wasHalted = venue.halted();
        vm.startPrank(venue.owner());
        if (mode == IVenue.AccessMode.Open && !wasHalted) venue.setHalted(true);
        venue.setPairAccess(pairIndex, mode);
        if (mode == IVenue.AccessMode.Open && !wasHalted) venue.setHalted(false);
        vm.stopPrank();
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Curves
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Bid: 100 / 200 / 300 at 1 / 2 / 4 bp. Ask: five levels of 50 at 0.5-2.5 bp, then 100 at 3 bp and 100 at
    /// 4 bp, so the ask spills into its second word.
    function _defaultShape() internal pure returns (uint256[4] memory words) {
        uint32[] memory bidSizes = new uint32[](3);
        uint16[] memory bidSpreads = new uint16[](3);
        (bidSizes[0], bidSizes[1], bidSizes[2]) = (100, 200, 300);
        (bidSpreads[0], bidSpreads[1], bidSpreads[2]) = (10, 20, 40);
        (words[0], words[1]) = ShapeWord.packSide(bidSizes, bidSpreads);

        uint32[] memory askSizes = new uint32[](7);
        uint16[] memory askSpreads = new uint16[](7);
        for (uint256 i; i < 5; ++i) {
            askSizes[i] = 50;
            askSpreads[i] = uint16(5 * (i + 1));
        }
        (askSizes[5], askSizes[6]) = (100, 100);
        (askSpreads[5], askSpreads[6]) = (30, 40);
        (words[2], words[3]) = ShapeWord.packSide(askSizes, askSpreads);
    }

    /// @dev One level of `size` at `spread` on both sides.
    function _flatShape(uint32 size, uint16 spread) internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](1);
        uint16[] memory spreads = new uint16[](1);
        sizes[0] = size;
        spreads[0] = spread;
        (words[0],) = ShapeWord.packSide(sizes, spreads);
        words[2] = words[0];
    }

    function _fields(uint32 seq) internal view returns (HotWord.Fields memory) {
        return HotWord.Fields({
            mid: MID,
            bidWiden: 0,
            askWiden: 0,
            widthScale: 1000,
            depthScale: 1000,
            shapeId: 0,
            validUntil: uint40(block.timestamp) + TTL,
            seq: seq,
            flags: 0
        });
    }

    function _hot(uint32 seq) internal view returns (bytes32) {
        return HotWord.pack(_fields(seq));
    }

    function _nextSeq(uint16 pairIndex) internal view returns (uint32) {
        return HotWord.seq(venue.hotWord(pairIndex)) + 1;
    }

    function _entry(uint16 pairIndex, bytes32 word) internal pure returns (bytes memory) {
        return abi.encodePacked(pairIndex, word);
    }

    function _post(uint16 pairIndex, bytes32 word) internal {
        vm.prank(owner);
        venue.post(_entry(pairIndex, word));
    }

    function _postFields(uint16 pairIndex, HotWord.Fields memory f) internal {
        f.seq = _nextSeq(pairIndex);
        _post(pairIndex, HotWord.pack(f));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pricing and fills
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The posted ladder from the side's consumed depth, as the next fill walks it.
    function _expect(uint16 pairIndex, bool baseIn, bool exactIn, uint256 amount)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 baseFilled)
    {
        bytes32 hot = venue.hotWord(pairIndex);
        uint256[4] memory words = venue.shape(pairIndex, HotWord.shapeId(hot));
        return oracle.fill(
            hot, venue.pair(pairIndex).sizeUnit, baseIn, words, exactIn, amount, _consumed(pairIndex, baseIn)
        );
    }

    /// @dev The posted ladder from the first level, as a fresh (or refilled) side gives it.
    function _expectFresh(uint16 pairIndex, bool baseIn, bool exactIn, uint256 amount)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 baseFilled)
    {
        bytes32 hot = venue.hotWord(pairIndex);
        uint256[4] memory words = venue.shape(pairIndex, HotWord.shapeId(hot));
        return oracle.fill(hot, venue.pair(pairIndex).sizeUnit, baseIn, words, exactIn, amount, 0);
    }

    /// @dev The base the side a fill walks has given up: the bids when the taker sells base.
    function _consumed(uint16 pairIndex, bool baseIn) internal view returns (uint256) {
        (uint128 bids, uint128 asks) = venue.consumed(pairIndex);
        return baseIn ? bids : asks;
    }

    function _tokens(bool baseIn) internal view returns (address tokenIn, address tokenOut) {
        return baseIn ? (address(eur), address(usd)) : (address(usd), address(eur));
    }

    /// @dev Moves the input into the venue the way the settler does, then fills as the settler.
    function _fill(uint16 pairIndex, bool baseIn, bool exactIn, uint128 amount)
        internal
        returns (uint128 amountIn, uint128 amountOut)
    {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        uint128 input = amount;
        if (!exactIn) (input,) = venue.quote(pairIndex, tokenIn, tokenOut, amount, false);
        MockTIP20V2(tokenIn).mint(address(venue), input);
        vm.prank(settler);
        return venue.fill(pairIndex, tokenIn, tokenOut, amount, exactIn, taker, HOME, REF);
    }

    function _fillCall(uint16 pairIndex, bool baseIn, bool exactIn, uint128 amount)
        internal
        view
        returns (bytes memory)
    {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        return abi.encodeCall(IVenue.fill, (pairIndex, tokenIn, tokenOut, amount, exactIn, taker, HOME, REF));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------------------------

    function _mappingSlot(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _pairSlots(uint16 pairIndex) internal pure returns (bytes32 first, bytes32 second) {
        first = _mappingSlot(pairIndex, SLOT_PAIRS);
        second = bytes32(uint256(first) + 1);
    }

    function _shapeSlot(uint16 pairIndex, uint8 shapeId, uint256 word) internal pure returns (bytes32) {
        return _mappingSlot((uint256(pairIndex) << 10) | (uint256(shapeId) << 2) | word, SLOT_SHAPES);
    }

    /// @dev The venue's private count of pairs with a mid band.
    function _bandedPairs() internal view returns (uint256) {
        return (uint256(vm.load(address(venue), bytes32(SLOT_OWNER))) >> BANDED_PAIRS_SHIFT) & type(uint16).max;
    }

    function _midBandSlot(uint16 pairIndex) internal pure returns (bytes32) {
        return _mappingSlot(pairIndex, SLOT_MID_BANDS);
    }

    function _storageWrites(address target) internal view returns (uint256) {
        (, bytes32[] memory writes) = vm.accesses(target);
        return writes.length;
    }
}
