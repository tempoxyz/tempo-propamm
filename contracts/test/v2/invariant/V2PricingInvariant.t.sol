// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { InventoryPath } from "../utils/InventoryPath.sol";
import { VenueFixture } from "../utils/VenueFixture.sol";

/// @notice Independently prices all four modes against the posted inventory path, then checks real fills.
contract V2PricingHandler is Test {
    uint256 internal constant DENOMINATOR = 1e26;

    Venue public immutable venue;
    MockTIP20V2 public immutable base;
    MockTIP20V2 public immutable quoteToken;
    address public immutable owner;
    address public immutable settler;
    uint16 public immutable pairIndex;

    uint256[4] public successfulModes;
    uint256 public deepFills;
    uint256 public mintedBase;
    uint256 public mintedQuote;

    constructor(Venue venue_, MockTIP20V2 base_, MockTIP20V2 quote_, address owner_, address settler_, uint16 pair_) {
        venue = venue_;
        base = base_;
        quoteToken = quote_;
        owner = owner_;
        settler = settler_;
        pairIndex = pair_;
    }

    /// @notice Reprice and refill the maker's posted book between sequences of depth-consuming trades.
    function post(uint256 seed) external {
        HotWord.Fields memory fields = HotWord.Fields({
            mid: uint96(1e18 + seed % 5e16),
            bidWiden: uint16((seed >> 32) % 100),
            askWiden: uint16((seed >> 48) % 100),
            widthScale: uint16(500 + (seed >> 64) % 1000),
            depthScale: uint16(500 + (seed >> 80) % 1000),
            shapeId: 0,
            validUntil: uint40(block.timestamp + 60),
            seq: uint32(uint256(venue.hotWord(pairIndex)) >> 208) + 1,
            flags: HotWord.FLAG_REFILL_BIDS | HotWord.FLAG_REFILL_ASKS
        });
        vm.prank(owner);
        venue.post(abi.encodePacked(pairIndex, HotWord.pack(fields)));
    }

    /// @notice Direction `baseIn`, exactness `exactIn`; checks quote and fill at the side's current consumed offset.
    function swap(bool baseIn, bool exactIn, uint256 seed) external {
        uint256 mode = (baseIn ? 0 : 2) + (exactIn ? 0 : 1);
        uint256 amount = 1_000_000 + seed % 29_000_000;
        bytes32 hot = venue.hotWord(pairIndex);
        uint256[4] memory words = venue.shape(pairIndex, uint8(uint256(hot) >> 160));
        InventoryPath.Side memory side = InventoryPath.side(hot, venue.pair(pairIndex).sizeUnit, words, baseIn);
        (uint128 bids, uint128 asks) = venue.consumed(pairIndex);
        uint256 offset = baseIn ? bids : asks;
        uint256 available;
        for (uint256 i; i < side.n; ++i) {
            available += side.depth[i];
        }
        if (available <= offset + 30_000_000) return;
        (bool hasDepth, uint256 totalValue) = InventoryPath.valueFrom(side, offset, available - offset);
        assertTrue(hasDepth);
        if (baseIn != exactIn && amount * DENOMINATOR >= totalValue) return;

        // Binary search the independently decoded stepped path for the inverse quote-target modes.
        uint256 baseFilled = baseIn == exactIn ? amount : _inverse(side, offset, amount, baseIn);
        (bool ok, uint256 value) = InventoryPath.valueFrom(side, offset, baseFilled);
        assertTrue(ok, "reference path ran out");
        uint256 expectedIn = baseIn ? baseFilled : exactIn ? amount : _ceil(value, DENOMINATOR);
        uint256 expectedOut = baseIn ? exactIn ? value / DENOMINATOR : amount : baseFilled;
        assertGt(expectedIn, 0, "input rounded to zero");
        assertGt(expectedOut, 0, "output rounded to zero");

        MockTIP20V2 input = baseIn ? base : quoteToken;
        MockTIP20V2 output = baseIn ? quoteToken : base;
        (uint128 quotedIn, uint128 quotedOut) =
            venue.quote(pairIndex, address(input), address(output), uint128(amount), exactIn);
        assertEq(quotedIn, expectedIn, "quote differs from independent path");
        assertEq(quotedOut, expectedOut, "quote differs from independent path");

        uint256 beforePoolInput = input.balanceOf(address(venue));
        uint256 beforePoolOutput = output.balanceOf(address(venue));
        uint256 beforeTakerOutput = output.balanceOf(address(this));
        input.mint(address(venue), expectedIn);
        if (baseIn) mintedBase += expectedIn;
        else mintedQuote += expectedIn;
        vm.prank(settler);
        (uint128 filledIn, uint128 filledOut) = venue.fill(
            pairIndex, address(input), address(output), uint128(amount), exactIn, address(this), 0, bytes32(seed)
        );
        assertEq(filledIn, expectedIn, "fill input differs from independent path");
        assertEq(filledOut, expectedOut, "fill output differs from independent path");
        assertEq(input.balanceOf(address(venue)), beforePoolInput + expectedIn);
        assertEq(output.balanceOf(address(venue)), beforePoolOutput - expectedOut);
        assertEq(output.balanceOf(address(this)), beforeTakerOutput + expectedOut);
        (bids, asks) = venue.consumed(pairIndex);
        assertEq(baseIn ? bids : asks, offset + baseFilled, "fill consumed different depth");
        if (offset != 0) ++deepFills;
        ++successfulModes[mode];
    }

    /// @dev Bids: smallest base whose exact value covers quote out. Asks: largest base quote in affords.
    function _inverse(InventoryPath.Side memory side, uint256 offset, uint256 quoteAmount, bool baseIn)
        internal
        pure
        returns (uint256)
    {
        uint256 depth;
        for (uint256 i; i < side.n; ++i) {
            depth += side.depth[i];
        }
        uint256 low;
        uint256 high = depth - offset;
        uint256 target = quoteAmount * DENOMINATOR;
        while (low < high) {
            uint256 middle = low + (high - low + (baseIn ? 0 : 1)) / 2;
            (, uint256 value) = InventoryPath.valueFrom(side, offset, middle);
            if (baseIn) {
                if (value >= target) high = middle;
                else low = middle + 1;
            } else if (value <= target) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        return low;
    }

    function _ceil(uint256 n, uint256 d) internal pure returns (uint256) {
        return (n + d - 1) / d;
    }
}

contract V2PricingInvariantTest is StdInvariant, VenueFixture {
    V2PricingHandler internal pricing;

    function setUp() public override {
        super.setUp();
        pricing = new V2PricingHandler(venue, eur, usd, owner, settler, pairId);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = pricing.post.selector;
        selectors[1] = pricing.swap.selector;
        targetSelector(FuzzSelector({ addr: address(pricing), selectors: selectors }));
        targetContract(address(pricing));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_independentPathPricesEverySuccessfulFill() external view {
        assertEq(eur.balanceOf(address(venue)) + eur.balanceOf(address(pricing)), INVENTORY + pricing.mintedBase());
        assertEq(usd.balanceOf(address(venue)) + usd.balanceOf(address(pricing)), INVENTORY + pricing.mintedQuote());
    }

    function test_allFourModesAndConsumedDepth() external {
        pricing.swap(true, true, 100);
        pricing.swap(true, false, 100);
        pricing.swap(false, true, 100);
        pricing.swap(false, false, 100);
        pricing.swap(true, true, 100);
        for (uint256 i; i < 4; ++i) {
            assertGt(pricing.successfulModes(i), 0);
        }
        assertGt(pricing.deepFills(), 0);
    }
}
