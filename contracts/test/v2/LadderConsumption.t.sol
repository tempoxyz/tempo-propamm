// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../src/v2/libraries/LadderMath.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { SequenceSettler } from "./mocks/SequenceSettler.sol";
import { VenueFixture } from "./utils/VenueFixture.sol";

/// @notice Fills take depth off the ladder like orders off a book, and only the maker's refill gives it back. The
/// fixture's bids hold 600 EUR (100 / 200 / 300 at 1 / 2 / 4 bp) and its asks 450 (five levels of 50 at 0.5-2.5 bp,
/// then 100 at 3 bp and 100 at 4 bp).
contract LadderConsumptionTest is VenueFixture {
    /// @dev `_consumption`, after `_members`, from `forge inspect Venue storageLayout`.
    uint256 internal constant SLOT_CONSUMPTION = 14;
    /// @dev The slot's `live` flag, after the two uint120 sides.
    uint256 internal constant LIVE = uint256(1) << 240;
    uint256 internal constant BID_DEPTH = 600e6;
    uint256 internal constant ASK_DEPTH = 450e6;
    uint16 internal constant REFILL_BOTH = HotWord.FLAG_REFILL_BIDS | HotWord.FLAG_REFILL_ASKS;

    /// @dev One part of a split order and what it traded.
    struct SplitResult {
        uint256 traded;
        uint256 paid;
        uint256 received;
        uint256 filled;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Splitting an order
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev One order split into 2-8 fills, back to back in one block or one per block, never does better than the
    /// order sent whole from the same consumed depth: exact in, the parts pay out at most what one fill of the same
    /// input would; exact out, they cost at least what one fill of the same output would. Parts can be dust: a part
    /// that rounds to nothing reverts `ZeroFill` and trades nothing, so the comparison is with one fill of what the
    /// parts did trade.
    function testFuzz_splitOrderNeverBeatsOneFill(
        bool baseIn,
        bool exactIn,
        uint128 amount,
        uint128 pre,
        uint8 parts,
        uint8 mode
    ) public {
        parts = uint8(bound(parts, 2, 8));
        // Totals the side covers whole: up to ~590 of the 600 EUR of bids, ~440 of the 450 EUR of asks.
        uint256 cap = exactIn ? (baseIn ? 400e6 : 260e6) : (baseIn ? 430e6 : 240e6);
        amount = uint128(bound(amount, parts, cap));
        // The side may already be part consumed, by up to 180 EUR.
        pre = uint128(bound(pre, 0, 180e6));
        if (pre >= 1e6) _fill(pairId, baseIn, true, baseIn ? pre : pre * 11 / 10);
        uint256 start = _consumed(pairId, baseIn);

        uint256 snapshot = vm.snapshotState();
        SplitResult memory s = _runSplit(baseIn, exactIn, amount, parts, mode);
        uint256 splitConsumed = _consumed(pairId, baseIn);
        assertEq(splitConsumed, start + s.filled, "the parts consumed their base");
        vm.revertToState(snapshot);
        if (s.traded == 0) return;

        (uint128 wholeIn, uint128 wholeOut) = _fill(pairId, baseIn, exactIn, uint128(s.traded));
        uint256 wholeBase = baseIn ? wholeIn : wholeOut;
        assertEq(_consumed(pairId, baseIn), start + wholeBase, "the whole consumed its base");
        if (exactIn) {
            assertEq(s.paid, wholeIn);
            assertLe(s.received, wholeOut, "split paid out more than the whole");
            // Selling base exact in, each part floors once: the split loses under one unit per extra part.
            if (baseIn) assertLe(wholeOut, s.received + parts, "split lost more than its rounding");
            if (baseIn) assertEq(s.filled, wholeBase);
            else assertLe(s.filled, wholeBase, "split bought more base");
        } else {
            assertEq(s.received, wholeOut);
            assertGe(s.paid, wholeIn, "split cost less than the whole");
            if (!baseIn) assertLe(s.paid, wholeIn + parts, "split paid more than its rounding");
            if (!baseIn) assertEq(s.filled, wholeBase);
            else assertGe(s.filled, wholeBase, "split sold less base");
        }
    }

    /// @dev Tiny swaps never sneak a better price: a 120-unit order sent as 50 dust swaps of 1-3 units does no better
    /// than one fill of what they traded, exact in and exact out, buying and selling. Paying 1 quote unit buys no
    /// base, so that dust reverts `ZeroFill` and trades nothing.
    function test_dustSwapsNeverBeatOneFill() public {
        for (uint256 dir; dir < 4; ++dir) {
            bool baseIn = dir < 2;
            bool exactIn = dir % 2 == 0;
            uint256 snapshot = vm.snapshotState();
            SplitResult memory s = _runSplit(baseIn, exactIn, 120, 50, 1);
            vm.revertToState(snapshot);
            if (s.traded == 0) continue;
            (uint128 wholeIn, uint128 wholeOut) = _fill(pairId, baseIn, exactIn, uint128(s.traded));
            if (exactIn) assertLe(s.received, wholeOut, "dust paid out more");
            else assertGe(s.paid, wholeIn, "dust cost less");
            vm.revertToState(snapshot);
        }
    }

    /// @dev The same split inside one transaction, through a settler that quotes and fills each part back to back:
    /// every exact-out part's fill matches its quote, each part starts where the last stopped and pays a deeper level,
    /// and together they cost at least one fill of the total.
    function test_splitInOneTransactionWalksTheLadderDown() public {
        (uint256 wholeIn,,) = _expect(pairId, false, false, 300e6);
        SequenceSettler seq = _sequenceSettler();
        SequenceSettler.Op[] memory ops = new SequenceSettler.Op[](4);
        ops[0] = SequenceSettler.Op(true, pairId, address(usd), address(eur), 100e6, false);
        for (uint256 i = 1; i < ops.length; ++i) {
            ops[i] = SequenceSettler.Op(false, pairId, address(usd), address(eur), 100e6, false);
        }
        SequenceSettler.Result[] memory results = seq.run(ops);
        assertEq(results[1].amountIn, results[0].amountIn, "the quote the first part filled at");
        uint256 paid;
        for (uint256 i = 1; i < results.length; ++i) {
            assertEq(results[i].amountOut, 100e6);
            if (i > 1) assertGt(results[i].amountIn, results[i - 1].amountIn, "each part pays a deeper level");
            paid += results[i].amountIn;
        }
        assertGe(paid, wholeIn, "split cost less than the whole");
        assertLe(paid, wholeIn + 2, "split paid more than its rounding");
        (, uint128 asks) = venue.consumed(pairId);
        assertEq(asks, 300e6);
        assertEq(eur.balanceOf(taker), 300e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // What moves the consumed depth
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A fill adds its base to its own side: the bids lose what takers sell, the asks what they buy.
    function test_fillsConsumeTheirOwnSide() public {
        _fill(pairId, true, true, 150e6);
        _assertConsumed(150e6, 0);
        // Wanting quote exact out consumes the base it takes in.
        (uint128 baseIn,) = _fill(pairId, true, false, 50e6);
        _assertConsumed(150e6 + uint256(baseIn), 0);
        // Paying quote exact in consumes the base it buys; buying exact out the base it asks for.
        (, uint128 baseOut) = _fill(pairId, false, true, 30e6);
        _fill(pairId, false, false, 20e6);
        _assertConsumed(150e6 + uint256(baseIn), uint256(baseOut) + 20e6);
    }

    /// @dev Each fill starts where the last stopped: selling 150 EUR takes all of bid level 1 and half of level 2, so
    /// the next 150 EUR takes the rest of level 2 at its price.
    function test_laterFillsStartDeeper() public {
        (, uint128 first) = _fill(pairId, true, true, 150e6);
        assertEq(first, (100e6 * uint256(MID) * (1e8 - 10_000) + 50e6 * uint256(MID) * (1e8 - 20_000)) / 1e26);
        (, uint128 second) = _fill(pairId, true, true, 150e6);
        assertEq(second, 150e6 * uint256(MID) * (1e8 - 20_000) / 1e26, "level 2 only");
        assertLt(second, first);
    }

    /// @dev Opposite trades take from the other side and give nothing back: after selling 300 EUR into the bids,
    /// buying 100 EUR consumes the asks and leaves the bids 300 EUR down.
    function test_oppositeTradesDoNotReplenish() public {
        _fill(pairId, true, true, 300e6);
        (uint256 freshAsk,,) = _expectFresh(pairId, false, false, 100e6);
        (uint128 paid,) = _fill(pairId, false, false, 100e6);
        assertEq(paid, freshAsk, "the asks were untouched");
        _assertConsumed(300e6, 100e6);
        // The bids still start 300 EUR down: level 3's price.
        (, uint128 out) = _fill(pairId, true, true, 100e6);
        assertEq(out, 100e6 * uint256(MID) * (1e8 - 40_000) / 1e26);
        _assertConsumed(400e6, 100e6);
        // Round trips only ever deepen both sides.
        for (uint256 i; i < 3; ++i) {
            _fill(pairId, false, true, 50e6);
            _fill(pairId, true, true, 50e6);
        }
        (uint128 bids, uint128 asks) = venue.consumed(pairId);
        assertEq(bids, 550e6);
        assertGt(asks, 100e6);
    }

    /// @dev A post without a refill bit moves the price, the spreads or the shape and keeps the consumption, which
    /// comes off the top of whatever ladder is now active.
    function test_consumptionPersistsAcrossPostsAndShapes() public {
        _fill(pairId, true, true, 150e6);
        HotWord.Fields memory f = _fields(_nextSeq(pairId));
        f.mid = MID + 1e15;
        f.widthScale = 1500;
        _post(pairId, HotWord.pack(f));
        _assertConsumed(150e6, 0);
        // The next sell starts 150 EUR down the new ladder: level 2, at the new mid and width.
        (, uint128 out) = _fill(pairId, true, true, 150e6);
        assertEq(out, 150e6 * uint256(MID + 1e15) * (1e8 - 20 * 1500) / 1e26);
        _assertConsumed(300e6, 0);

        // A new shape keeps it too: one 1,000 EUR level at 1 bp, 300 EUR of it already gone.
        vm.prank(updater);
        venue.setShape(pairId, 0, _flatShape(1000, 10));
        _assertConsumed(300e6, 0);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        venue.quote(pairId, address(eur), address(usd), 700e6 + 1, true);
        (, out) = _fill(pairId, true, true, 700e6);
        assertEq(out, 700e6 * uint256(MID + 1e15) * (1e8 - 10 * 1500) / 1e26);
    }

    /// @dev The offset is in base units of the ladder posted now, so a depth change moves where it lands: 120 EUR into
    /// the bids sits 20 EUR into level 2, and at twice the depth 120 EUR into level 1's 200.
    function test_consumptionIsInBaseUnitsOfTheLadderNowPosted() public {
        _fill(pairId, true, true, 120e6);
        HotWord.Fields memory f = _fields(_nextSeq(pairId));
        f.depthScale = 2000;
        _post(pairId, HotWord.pack(f));
        (, uint128 out) = _fill(pairId, true, true, 80e6);
        assertEq(out, 80e6 * uint256(MID) * (1e8 - 10_000) / 1e26, "the rest of the doubled level 1");
        _assertConsumed(200e6, 0);
        // At half the depth (50 / 100 / 150) the same 200 EUR is past levels 1 and 2.
        f = _fields(_nextSeq(pairId));
        f.depthScale = 500;
        _post(pairId, HotWord.pack(f));
        (, out) = _fill(pairId, true, true, 50e6);
        assertEq(out, 50e6 * uint256(MID) * (1e8 - 40_000) / 1e26, "level 3");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Refills
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A post with both refill bits clears both sides: the next fills price from the first level again. The
    /// word is stored and emitted without the bits, and `Refilled` follows `Posted`.
    function test_refillPostRestoresTheFullLadder() public {
        (, uint256 freshBid,) = _expectFresh(pairId, true, true, 200e6);
        (uint256 freshAsk,,) = _expectFresh(pairId, false, false, 200e6);
        _fill(pairId, true, true, 250e6);
        _fill(pairId, false, false, 120e6);

        uint32 next = _nextSeq(pairId);
        HotWord.Fields memory f = _fields(next);
        f.flags = REFILL_BOTH;
        bytes32 stored = _hot(next);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.Posted(pairId, stored);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.Refilled(pairId, true, true);
        _post(pairId, HotWord.pack(f));
        assertEq(venue.hotWord(pairId), stored, "the refill bits are never stored");
        _assertConsumed(0, 0);

        (, uint128 bidOut) = _fill(pairId, true, true, 200e6);
        (uint128 askIn,) = _fill(pairId, false, false, 200e6);
        assertEq(bidOut, freshBid);
        assertEq(askIn, freshAsk);
    }

    /// @dev Each refill bit clears its own side only.
    function test_refillOneSideKeepsTheOther() public {
        _fill(pairId, true, true, 250e6);
        _fill(pairId, false, false, 120e6);
        _postFlags(HotWord.FLAG_REFILL_BIDS);
        _assertConsumed(0, 120e6);
        _fill(pairId, true, true, 10e6);
        _postFlags(HotWord.FLAG_REFILL_ASKS);
        _assertConsumed(10e6, 0);
        // Refill bits combine with the side-off bits: the asks refilled and switched off.
        _postFlags(HotWord.FLAG_REFILL_ASKS | HotWord.FLAG_ASKS_OFF);
        assertEq(HotWord.flags(venue.hotWord(pairId)), HotWord.FLAG_ASKS_OFF);
        _assertConsumed(10e6, 0);
    }

    /// @dev `post` skips an entry whose seq isn't above the stored one, and a skipped refill applies nothing; so does
    /// a refill in a batch that reverts.
    function test_staleOrRejectedRefillChangesNothing() public {
        _fill(pairId, true, true, 250e6);
        _fill(pairId, false, false, 120e6);
        uint32 stored = HotWord.seq(venue.hotWord(pairId));
        HotWord.Fields memory f = _fields(stored);
        f.flags = REFILL_BOTH;
        bytes32 sameSeq = HotWord.pack(f);
        f.seq = stored - 1;
        bytes32 lowerSeq = HotWord.pack(f);

        vm.record();
        vm.recordLogs();
        vm.prank(owner);
        venue.post(bytes.concat(_entry(pairId, sameSeq), _entry(pairId, lowerSeq)));
        assertEq(_storageWrites(address(venue)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        _assertConsumed(250e6, 120e6);

        f.seq = stored + 1;
        HotWord.Fields memory bad = _fields(stored + 2);
        bad.mid = 0;
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHotWord.selector, pairId));
        vm.prank(owner);
        venue.post(bytes.concat(_entry(pairId, HotWord.pack(f)), _entry(pairId, HotWord.pack(bad))));
        _assertConsumed(250e6, 120e6);
    }

    /// @dev A refill acts once: re-posting the stored word, the usual way to bump `seq`, refills nothing.
    function test_copyingTheStoredWordForwardRefillsNothing() public {
        _postFlags(REFILL_BOTH);
        _fill(pairId, true, true, 100e6);
        bytes32 word = venue.hotWord(pairId);
        HotWord.Fields memory f = HotWord.unpack(word);
        f.seq += 1;
        vm.recordLogs();
        _post(pairId, HotWord.pack(f));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IVenue.Posted.selector);
        _assertConsumed(100e6, 0);
    }

    /// @dev The updater refills as the owner does: refilling is a quote, and a quote with a higher `depthScale` could
    /// already offer that depth.
    function test_updaterRefills() public {
        _fill(pairId, true, true, 100e6);
        HotWord.Fields memory f = _fields(_nextSeq(pairId));
        f.flags = HotWord.FLAG_REFILL_BIDS;
        vm.prank(updater);
        venue.post(_entry(pairId, HotWord.pack(f)));
        _assertConsumed(0, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Exhaustion and inventory
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A side consumed to its depth fills nothing, exactly as an over-depth fill on a fresh side reverts
    /// (`InsufficientDepth`, quote and fill alike, in every direction), and moves nothing; the other side still fills,
    /// and a refill brings it back.
    function test_exhaustedSideRevertsUntilRefilled() public {
        // An over-depth fill on a fresh side: reverts, consumes nothing.
        _expectDepthRevert(true, true, uint128(BID_DEPTH + 1));
        _assertConsumed(0, 0);

        _fill(pairId, true, true, uint128(BID_DEPTH));
        _assertConsumed(BID_DEPTH, 0);
        _expectDepthRevert(true, true, 1);
        _expectDepthRevert(true, false, 1);
        _assertConsumed(BID_DEPTH, 0);
        // The asks are untouched and fill to their own depth, then run out too.
        _fill(pairId, false, false, uint128(ASK_DEPTH));
        _expectDepthRevert(false, false, 1);
        _expectDepthRevert(false, true, 2e6);
        _assertConsumed(BID_DEPTH, ASK_DEPTH);

        _postFlags(HotWord.FLAG_REFILL_BIDS);
        _fill(pairId, true, true, 1e6);
        _expectDepthRevert(false, false, 1);
    }

    /// @dev A shallower ladder posted under a deeper consumption exhausts the side at once, and a deeper one later
    /// offers only what lies past the offset.
    function test_consumptionPastAShallowerLadderExhaustsTheSide() public {
        _fill(pairId, true, true, 500e6);
        HotWord.Fields memory f = _fields(_nextSeq(pairId));
        f.depthScale = 500; // 300 EUR of bids, below the 500 consumed
        _post(pairId, HotWord.pack(f));
        _expectDepthRevert(true, true, 1);
        f = _fields(_nextSeq(pairId));
        f.depthScale = 2000; // 1,200 EUR of bids: 700 past the offset
        _post(pairId, HotWord.pack(f));
        _expectDepthRevert(true, true, 700e6 + 1);
        _fill(pairId, true, true, 700e6);
        _assertConsumed(BID_DEPTH * 2, 0);
    }

    /// @dev Inventory still bounds every payout: with 200 EUR left in the venue, buying it takes 200 of the asks' 450,
    /// and the next unit fails on inventory, not depth.
    function test_inventoryStillLimitsFills() public {
        vm.prank(owner);
        venue.withdraw(address(eur), owner, INVENTORY - 200e6, REF);
        _fill(pairId, false, false, 200e6);
        _assertConsumed(0, 200e6);
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.InsufficientInventory.selector, address(eur), uint256(0), uint256(1e6))
        );
        venue.quote(pairId, address(usd), address(eur), 1e6, false);
        usd.mint(address(venue), 2e6);
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.InsufficientInventory.selector, address(eur), uint256(0), uint256(1e6))
        );
        vm.prank(settler);
        venue.fill(pairId, address(usd), address(eur), 1e6, false, taker, HOME, REF);
        _assertConsumed(0, 200e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Quote parity
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev From any consumed depth, `quote` returns what `fill` then does, or reverts as it does, and both match
    /// `LadderMath` from the stored offset.
    function testFuzz_quoteMatchesFillFromConsumedDepth(bool baseIn, bool exactIn, uint128 pre, uint128 amount) public {
        pre = uint128(bound(pre, 0, baseIn ? BID_DEPTH : ASK_DEPTH));
        if (pre != 0) _fill(pairId, baseIn, baseIn, pre);
        amount = uint128(bound(amount, 1, 700e6));
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        bytes32 hot = venue.hotWord(pairId);
        uint256[4] memory words = venue.shape(pairId, 0);
        uint256 offset = _consumed(pairId, baseIn);
        assertEq(offset, pre);
        try oracle.fill(hot, UNIT, baseIn, words, exactIn, amount, offset) returns (
            uint256 eIn, uint256 eOut, uint256 base
        ) {
            (uint128 qIn, uint128 qOut) = venue.quote(pairId, tokenIn, tokenOut, amount, exactIn);
            assertEq(qIn, eIn);
            assertEq(qOut, eOut);
            (uint128 fIn, uint128 fOut) = _fill(pairId, baseIn, exactIn, amount);
            assertEq(fIn, qIn);
            assertEq(fOut, qOut);
            assertEq(_consumed(pairId, baseIn), offset + base);
        } catch (bytes memory err) {
            vm.expectRevert(err);
            venue.quote(pairId, tokenIn, tokenOut, amount, exactIn);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `addPair` creates the pair's consumption slot nonzero; fills and refills rewrite it, never clearing it, so
    /// no fill or refill ever pays for a new slot; `removePair` deletes it.
    function test_consumptionSlotStaysNonzeroForThePairsLife() public {
        bytes32 slot = _mappingSlot(pairId, SLOT_CONSUMPTION);
        assertEq(uint256(vm.load(address(venue), slot)), LIVE, "addPair");
        _fill(pairId, true, true, 7e6);
        _fill(pairId, false, false, 3e6);
        assertEq(uint256(vm.load(address(venue), slot)), LIVE | (3e6 << 120) | 7e6, "bids low, asks high");
        _postFlags(REFILL_BOTH);
        assertEq(uint256(vm.load(address(venue), slot)), LIVE, "a refill keeps the slot nonzero");
        _fill(pairId, true, true, 7e6);
        _postFlags(HotWord.FLAG_REFILL_BIDS);
        assertEq(uint256(vm.load(address(venue), slot)), LIVE, "a one-side refill too");
        vm.prank(owner);
        venue.removePair(pairId);
        assertEq(uint256(vm.load(address(venue), slot)), 0, "removePair");
        (uint128 bids, uint128 asks) = venue.consumed(pairId);
        assertEq(bids + asks, 0);
    }

    /// @dev A fill writes the consumption slot once; a post without a refill bit neither reads nor writes it.
    function test_onlyFillsAndRefillsTouchTheSlot() public {
        bytes32 slot = _mappingSlot(pairId, SLOT_CONSUMPTION);
        eur.mint(address(venue), 1e6);
        vm.record();
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), 1e6, true, taker, HOME, REF);
        (, bytes32[] memory writes) = vm.accesses(address(venue));
        uint256 slotWrites;
        for (uint256 i; i < writes.length; ++i) {
            if (writes[i] == slot) ++slotWrites;
        }
        assertEq(slotWrites, 1, "one write per fill");

        vm.record();
        _post(pairId, _hot(_nextSeq(pairId)));
        (bytes32[] memory reads, bytes32[] memory postWrites) = vm.accesses(address(venue));
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(reads[i] != slot, "post read the consumption slot");
        }
        for (uint256 i; i < postWrites.length; ++i) {
            assertTrue(postWrites[i] != slot, "post wrote the consumption slot");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Sends `total` as `parts` fills on one side: equal parts (mode 0), dust then the rest (mode 1), or uneven
    /// parts (mode 2); with mode bit 7 set, one block and one second apart. A part that reverts trades nothing.
    function _runSplit(bool baseIn, bool exactIn, uint256 total, uint256 parts, uint8 mode)
        internal
        returns (SplitResult memory s)
    {
        uint256 left = total;
        for (uint256 i; i < parts; ++i) {
            uint256 part;
            if (i == parts - 1) part = left;
            else if (mode % 3 == 0) part = total / parts;
            else if (mode % 3 == 1) part = 1 + i % 3;
            else part = 1 + uint256(keccak256(abi.encode(mode, i))) % (left - (parts - 1 - i));
            if (part > left - (parts - 1 - i)) part = left - (parts - 1 - i);
            left -= part;
            if (mode >= 128 && i != 0) {
                vm.roll(block.number + 1);
                vm.warp(START + i);
            }
            (bool ok, uint128 paid, uint128 received) = _tryFill(baseIn, exactIn, uint128(part));
            if (!ok) continue;
            s.traded += part;
            s.paid += paid;
            s.received += received;
            s.filled += baseIn ? paid : received;
        }
    }

    /// @dev `_fill`, except a part the ladder rounds to nothing reverts and is reported, not raised.
    function _tryFill(bool baseIn, bool exactIn, uint128 amount)
        internal
        returns (bool ok, uint128 amountIn, uint128 amountOut)
    {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        try venue.quote(pairId, tokenIn, tokenOut, amount, exactIn) returns (uint128 qIn, uint128 qOut) {
            MockTIP20V2(tokenIn).mint(address(venue), qIn);
            vm.prank(settler);
            (amountIn, amountOut) = venue.fill(pairId, tokenIn, tokenOut, amount, exactIn, taker, HOME, REF);
            assertEq(amountIn, qIn, "fill matches its quote");
            assertEq(amountOut, qOut, "fill matches its quote");
            ok = true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), LadderMath.ZeroFill.selector, "a part may only round to nothing");
        }
    }

    function _postFlags(uint16 flags) internal {
        HotWord.Fields memory f = _fields(_nextSeq(pairId));
        f.flags = flags;
        _post(pairId, HotWord.pack(f));
    }

    function _assertConsumed(uint256 bids, uint256 asks) internal view {
        (uint128 storedBids, uint128 storedAsks) = venue.consumed(pairId);
        assertEq(storedBids, bids, "consumed bids");
        assertEq(storedAsks, asks, "consumed asks");
    }

    /// @dev Both `quote` and `fill` revert `InsufficientDepth`, and the fill moves nothing.
    function _expectDepthRevert(bool baseIn, bool exactIn, uint128 amount) internal {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        venue.quote(pairId, tokenIn, tokenOut, amount, exactIn);
        MockTIP20V2(tokenIn).mint(address(venue), exactIn ? amount : 1e6);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        vm.prank(settler);
        venue.fill(pairId, tokenIn, tokenOut, amount, exactIn, taker, HOME, REF);
    }

    function _sequenceSettler() internal returns (SequenceSettler seq) {
        seq = new SequenceSettler(IVenue(address(venue)), taker, HOME);
        vm.prank(owner);
        venue.setSettler(address(seq));
        usd.mint(address(seq), INVENTORY);
        eur.mint(address(seq), INVENTORY);
    }
}
