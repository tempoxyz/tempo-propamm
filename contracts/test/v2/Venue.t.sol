// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { ITIP20 } from "../../src/interfaces/ITIP20.sol";
import { ITIP20Factory } from "../../src/interfaces/ITIP20Factory.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { VenueHookFlags } from "../../src/v2/interfaces/IVenueHook.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";
import { MockGuardedTIP20 } from "./mocks/MockGuardedTIP20.sol";
import { MockSilentTIP20 } from "./mocks/MockSilentTIP20.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { MockVenueHook } from "./mocks/MockVenueHook.sol";
import { SequenceSettler } from "./mocks/SequenceSettler.sol";
import { VenueFixture } from "./utils/VenueFixture.sol";
import { VirtualAddress } from "./utils/VirtualAddress.sol";

contract VenueTest is VenueFixture {
    uint96 internal constant BAND_MIN = 1.08e18;
    uint96 internal constant BAND_MAX = 1.09e18;
    address internal constant TIP20_FACTORY = 0x20Fc000000000000000000000000000000000000;

    /// @dev The second pair's base, from `_secondPair`.
    MockTIP20V2 internal gbpToken;

    // ---------------------------------------------------------------------------------------------------------------
    // Initialization and views
    // ---------------------------------------------------------------------------------------------------------------

    function test_initialState() public view {
        assertEq(venue.owner(), owner);
        assertEq(venue.settler(), settler);
        assertEq(venue.pendingOwner(), address(0));
        assertEq(venue.factory(), address(factory));
        assertFalse(venue.halted());
        assertTrue(venue.isUpdater(updater));
        assertFalse(venue.isUpdater(stranger));
        assertEq(venue.pairCount(), 1);
        assertEq(venue.HOOK_VIEW_GAS(), 1_500_000);

        IVenue.Pair memory p = venue.pair(pairId);
        assertEq(p.base, address(eur));
        assertEq(p.quote, address(usd));
        assertEq(p.sizeUnit, UNIT);
        assertEq(uint8(p.access), uint8(IVenue.AccessMode.Open));
        assertEq(p.hook, address(0));
        assertEq(p.hookFlags, 0);
        assertEq(venue.hotWord(pairId), _hot(2));
        uint256[4] memory words = venue.shape(pairId, 0);
        uint256[4] memory expected = _defaultShape();
        for (uint256 i; i < 4; ++i) {
            assertEq(words[i], expected[i]);
        }
        (uint96 minMid, uint96 maxMid) = venue.midBand(pairId);
        assertEq(minMid, 0);
        assertEq(maxMid, 0);
        assertEq(_bandedPairs(), 0);
        assertEq(venue.MAX_BATCH(), 100);
        assertEq(venue.deniedCount(), 0);
        assertEq(venue.maxTakerPriorityFee(), venue.NO_PRIORITY_FEE_CAP(), "no priority-fee cap");
        // No sponsor is registered and no one is listed.
        (address admin, bool enabled, uint32 generation) = venue.sponsor(1);
        assertEq(admin, address(0));
        assertFalse(enabled);
        assertEq(generation, 0);
        assertFalse(venue.isMember(pairId, HOME, taker));
        assertTrue(venue.pairSponsor(pairId, HOME), "every live pair admits the home list");
        assertFalse(venue.pairSponsor(pairId, 1));
    }

    function test_initialize_onlyFactory() public {
        vm.expectRevert(IVenue.NotFactory.selector);
        vm.prank(stranger);
        venue.initialize(stranger, stranger);
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert(IVenue.AlreadyInitialized.selector);
        vm.prank(address(factory));
        venue.initialize(stranger, stranger);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // addPair
    // ---------------------------------------------------------------------------------------------------------------

    function test_addPair_storesConfigAndInitialHotWord() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairAdded(1, address(gbp), address(usd), 5e5);
        vm.recordLogs();
        vm.prank(owner);
        uint16 index = venue.addPair(address(gbp), address(usd), 5e5);
        // `PairAdded` alone records the new pair, `Closed`.
        assertEq(vm.getRecordedLogs().length, 1);

        assertEq(index, 1);
        assertEq(venue.pairCount(), 2);
        IVenue.Pair memory p = venue.pair(index);
        assertEq(p.base, address(gbp));
        assertEq(p.quote, address(usd));
        assertEq(p.sizeUnit, 5e5);
        // A new pair starts closed: nobody can trade it until the owner opens it.
        assertEq(uint8(p.access), uint8(IVenue.AccessMode.Closed));
        assertFalse(venue.takerAllowed(index, taker, HOME));
        assertEq(venue.hotWord(index), HotWord.INITIAL);
        assertEq(HotWord.seq(venue.hotWord(index)), 1);
        assertEq(HotWord.validUntil(venue.hotWord(index)), 0);
    }

    function test_addPair_newPairCantFillUntilPosted() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        vm.startPrank(owner);
        uint16 index = venue.addPair(address(gbp), address(usd), UNIT);
        venue.setShape(index, 0, _defaultShape());
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        vm.expectRevert(abi.encodeWithSelector(IVenue.QuoteExpired.selector, uint40(0)));
        venue.quote(index, address(gbp), address(usd), 1e6, true);
    }

    function test_addPair_rejectsBadTokens() public {
        MockTIP20V2 other = new MockTIP20V2("X", 6);
        vm.startPrank(owner);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        venue.addPair(address(0), address(usd), UNIT);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        venue.addPair(address(other), address(0), UNIT);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        venue.addPair(address(usd), address(usd), UNIT);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        venue.addPair(makeAddr("eoa"), address(usd), UNIT);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        venue.addPair(address(other), makeAddr("eoa"), UNIT);
        vm.stopPrank();
    }

    /// @dev `decimals()` and code do not prove a token implements Tempo's memo-bearing transfer paths. The generic
    /// factory double recognizes only explicit TIP-20 mocks, matching the production factory's fail-closed admission.
    function test_addPair_rejectsPlainAndUninitializedTip20ShapedTokens() public {
        PlainDecimalsToken plain = new PlainDecimalsToken();
        UninitializedTIP20 uninitialized = new UninitializedTIP20();
        // Tempo's native factory test double uses a selector reply for the explicit mock-token fixture. These exact
        // replies retain the production factory's refusal for the two non-mock token shapes in this regression.
        vm.mockCall(TIP20_FACTORY, abi.encodeCall(ITIP20Factory.isTIP20, (address(plain))), abi.encode(false));
        vm.mockCall(TIP20_FACTORY, abi.encodeCall(ITIP20Factory.isTIP20, (address(uninitialized))), abi.encode(false));
        vm.startPrank(owner);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        venue.addPair(address(plain), address(usd), UNIT);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        venue.addPair(address(uninitialized), address(usd), UNIT);
        vm.stopPrank();
    }

    /// @dev The factory gate accepts only canonical ABI true. A short, extra-word, noncanonical or reverting reply
    /// must fail closed before `addPair` asks the token for decimals.
    function test_addPair_rejectsMalformedFactoryReplies() public {
        _assertFactoryReplyRejected("");
        _assertFactoryReplyRejected(new bytes(31));
        _assertFactoryReplyRejected(abi.encode(true, true));
        _assertFactoryReplyRejected(abi.encode(uint256(2)));

        MockTIP20V2 reverting = new MockTIP20V2("REVERT", 6);
        vm.mockCallRevert(TIP20_FACTORY, abi.encodeCall(ITIP20Factory.isTIP20, (address(reverting))), hex"");
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        vm.prank(owner);
        venue.addPair(address(reverting), address(usd), UNIT);
    }

    function _assertFactoryReplyRejected(bytes memory reply) internal {
        MockTIP20V2 malformed = new MockTIP20V2("MALFORMED", 6);
        vm.mockCall(TIP20_FACTORY, abi.encodeCall(ITIP20Factory.isTIP20, (address(malformed))), reply);
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        vm.prank(owner);
        venue.addPair(address(malformed), address(usd), UNIT);
    }

    function test_addPair_rejectsUnequalDecimals() public {
        MockTIP20V2 wide = new MockTIP20V2("W", 18);
        vm.expectRevert(abi.encodeWithSelector(IVenue.DecimalsMismatch.selector, uint8(18), uint8(6)));
        vm.prank(owner);
        venue.addPair(address(wide), address(usd), UNIT);
    }

    function test_addPair_rejectsZeroSizeUnit() public {
        vm.expectRevert(IVenue.InvalidSizeUnit.selector);
        vm.prank(owner);
        venue.addPair(address(usd), address(eur), 0);
    }

    function test_addPair_capsAt65535Pairs() public {
        uint256 word = uint256(vm.load(address(venue), bytes32(SLOT_OWNER)));
        word = (word & ~(uint256(type(uint16).max) << 160)) | (uint256(65_534) << 160);
        vm.store(address(venue), bytes32(SLOT_OWNER), bytes32(word));
        assertEq(venue.pairCount(), 65_534);
        assertEq(venue.owner(), owner);

        vm.prank(owner);
        uint16 last = venue.addPair(address(usd), address(eur), UNIT);
        assertEq(last, 65_534);
        assertEq(venue.pairCount(), 65_535);

        vm.expectRevert(IVenue.PairLimitReached.selector);
        vm.prank(owner);
        venue.addPair(address(usd), address(eur), UNIT);
    }

    function test_addPair_onlyOwner() public {
        address[3] memory callers = [updater, settler, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(callers[i]);
            venue.addPair(address(usd), address(eur), UNIT);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // removePair
    // ---------------------------------------------------------------------------------------------------------------

    function test_removePair_clearsConfigHotWordAndHookButKeepsShapes() public {
        // Install a hook first, so every slot removePair must clear starts nonzero.
        MockVenueHook hook = new MockVenueHook(venue, VenueHookFlags.ALL);
        vm.prank(owner);
        venue.setPairHook(pairId, address(hook), VenueHookFlags.ALL);
        (bytes32 first, bytes32 second) = _pairSlots(pairId);
        bytes32 hookSlot = _mappingSlot(pairId, SLOT_HOOKS);
        assertEq(vm.load(address(venue), hookSlot), bytes32(uint256(uint160(address(hook)))));
        assertTrue(vm.load(address(venue), first) != bytes32(0));
        assertTrue(vm.load(address(venue), second) != bytes32(0));
        assertTrue(vm.load(address(venue), _mappingSlot(pairId, SLOT_HOT)) != bytes32(0));
        _fill(pairId, false, false, 30e6);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairRemoved(pairId);
        vm.prank(owner);
        venue.removePair(pairId);

        assertEq(vm.load(address(venue), first), bytes32(0));
        assertEq(vm.load(address(venue), second), bytes32(0));
        assertEq(vm.load(address(venue), _mappingSlot(pairId, SLOT_HOT)), bytes32(0));
        assertEq(vm.load(address(venue), hookSlot), bytes32(0));

        IVenue.Pair memory p = venue.pair(pairId);
        assertEq(p.base, address(0));
        assertEq(p.quote, address(0));
        assertEq(p.sizeUnit, 0);
        assertEq(uint8(p.access), uint8(IVenue.AccessMode.None));
        assertFalse(venue.takerAllowed(pairId, taker, HOME));
        assertEq(p.hook, address(0));
        assertEq(p.hookFlags, 0);
        assertEq(venue.hotWord(pairId), bytes32(0));
        assertEq(venue.pairCount(), 1);
        assertEq(venue.shape(pairId, 0)[2], _defaultShape()[2]);
    }

    function test_removePair_indexNeverReused() public {
        vm.startPrank(owner);
        venue.removePair(pairId);
        uint16 next = venue.addPair(address(eur), address(usd), UNIT);
        vm.stopPrank();
        assertEq(next, pairId + 1);
        assertEq(venue.pairCount(), 2);
        assertEq(venue.pair(pairId).base, address(0));
    }

    function test_removePair_blocksEveryPairOperation() public {
        vm.prank(owner);
        venue.removePair(pairId);
        bytes memory unknown = abi.encodeWithSelector(IVenue.UnknownPair.selector, pairId);

        eur.mint(address(venue), 1e6);
        _expectFillRevert(unknown, pairId, true, true, 1e6);
        vm.expectRevert(unknown);
        venue.quote(pairId, address(eur), address(usd), 1e6, true);

        bytes memory entry = _entry(pairId, _hot(3));
        vm.startPrank(owner);
        vm.expectRevert(unknown);
        venue.post(entry);
        vm.expectRevert(unknown);
        venue.removePair(pairId);
        vm.expectRevert(unknown);
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);
        vm.expectRevert(unknown);
        venue.closePair(pairId);
        vm.expectRevert(unknown);
        venue.setPairHook(pairId, address(0), 0);
        vm.stopPrank();
        assertEq(venue.hookLiquidity(pairId, address(usd)), 0);
    }

    function test_removePair_onlyOwnerAndKnownPair() public {
        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(updater);
        venue.removePair(pairId);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(7)));
        vm.prank(owner);
        venue.removePair(7);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Access mode and kill switches (the access lists are in VenueAccess.t.sol)
    // ---------------------------------------------------------------------------------------------------------------

    function test_setPairAccess() public {
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairAccessUpdated(pairId, IVenue.AccessMode.Open, IVenue.AccessMode.Listed);
        vm.prank(owner);
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);
        assertEq(uint8(venue.pair(pairId).access), uint8(IVenue.AccessMode.Listed));

        vm.startPrank(owner);
        vm.expectRevert(IVenue.InvalidAccessMode.selector);
        venue.setPairAccess(pairId, IVenue.AccessMode.None);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(3)));
        venue.setPairAccess(3, IVenue.AccessMode.Listed);
        vm.stopPrank();

        address[3] memory callers = [updater, settler, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(callers[i]);
            venue.setPairAccess(pairId, IVenue.AccessMode.Closed);
        }
    }

    function test_setPairAccess_openNeedsHalt() public {
        vm.prank(owner);
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);
        vm.expectRevert(IVenue.NotHalted.selector);
        vm.prank(owner);
        venue.setPairAccess(pairId, IVenue.AccessMode.Open);

        vm.startPrank(owner);
        venue.setHalted(true);
        venue.setPairAccess(pairId, IVenue.AccessMode.Open);
        venue.setHalted(false);
        // Re-setting the current mode changes nothing, so it needs no halt, and it still emits.
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairAccessUpdated(pairId, IVenue.AccessMode.Open, IVenue.AccessMode.Open);
        venue.setPairAccess(pairId, IVenue.AccessMode.Open);
        // Listed and Closed need no halt.
        venue.setPairAccess(pairId, IVenue.AccessMode.Closed);
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);
        vm.stopPrank();
    }

    function test_closePair_updaterClosesOnlyOwnerReopens() public {
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairAccessUpdated(pairId, IVenue.AccessMode.Open, IVenue.AccessMode.Closed);
        vm.prank(updater);
        venue.closePair(pairId);
        assertEq(uint8(venue.pair(pairId).access), uint8(IVenue.AccessMode.Closed));

        eur.mint(address(venue), 1e6);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker), pairId, true, true, 1e6);

        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(updater);
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);

        _setAccess(pairId, IVenue.AccessMode.Open);
        _fill(pairId, true, true, 1e6);

        // Closing a closed pair changes nothing but still emits, so an emergency call is always confirmed.
        vm.startPrank(owner);
        venue.closePair(pairId);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.PairAccessUpdated(pairId, IVenue.AccessMode.Closed, IVenue.AccessMode.Closed);
        venue.closePair(pairId);
        vm.stopPrank();
        assertEq(uint8(venue.pair(pairId).access), uint8(IVenue.AccessMode.Closed));
    }

    function test_closePair_rejectsStrangerAndSettler() public {
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        vm.prank(stranger);
        venue.closePair(pairId);
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        vm.prank(settler);
        venue.closePair(pairId);
    }

    function test_setHalted_authority() public {
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.HaltedSet(true);
        vm.prank(updater);
        venue.setHalted(true);
        assertTrue(venue.halted());

        vm.recordLogs();
        vm.prank(updater);
        venue.setHalted(true);
        assertEq(vm.getRecordedLogs().length, 0, "an authorized no-op halt emits nothing");

        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(updater);
        venue.setHalted(false);

        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        vm.prank(stranger);
        venue.setHalted(true);
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        vm.prank(settler);
        venue.setHalted(true);
        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(stranger);
        venue.setHalted(false);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.HaltedSet(false);
        vm.prank(owner);
        venue.setHalted(false);
        assertFalse(venue.halted());

        vm.recordLogs();
        vm.prank(owner);
        venue.setHalted(false);
        assertEq(vm.getRecordedLogs().length, 0, "an authorized no-op resume emits nothing");

        vm.prank(owner);
        venue.setHalted(true);
        assertTrue(venue.halted());
        // The halt flag shares a slot with the owner and pair count.
        assertEq(venue.owner(), owner);
        assertEq(venue.pairCount(), 1);
    }

    function test_halted_blocksFillAndQuoteButNotWithdraw() public {
        vm.prank(updater);
        venue.setHalted(true);

        eur.mint(address(venue), 1e6);
        _expectFillRevert(abi.encodeWithSelector(IVenue.VenueHalted.selector), pairId, true, true, 1e6);
        vm.expectRevert(IVenue.VenueHalted.selector);
        venue.quote(pairId, address(eur), address(usd), 1e6, true);

        vm.prank(owner);
        venue.withdraw(address(usd), owner, 5e6, bytes32("w"));
        assertEq(usd.balanceOf(owner), 5e6);

        vm.prank(owner);
        venue.setHalted(false);
        _fill(pairId, true, true, 1e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------------------------------------------------

    function test_setUpdater() public {
        address hot = makeAddr("hot");
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.UpdaterSet(hot, true);
        vm.prank(owner);
        venue.setUpdater(hot, true);
        assertTrue(venue.isUpdater(hot));
        _postAs(hot, pairId, _hot(3));

        vm.recordLogs();
        vm.prank(owner);
        venue.setUpdater(hot, true);
        assertEq(vm.getRecordedLogs().length, 0, "an authorized no-op approval emits nothing");

        vm.prank(owner);
        venue.setUpdater(hot, false);
        assertFalse(venue.isUpdater(hot));

        vm.recordLogs();
        vm.prank(owner);
        venue.setUpdater(hot, false);
        assertEq(vm.getRecordedLogs().length, 0, "an authorized no-op revocation emits nothing");
        bytes memory entry = _entry(pairId, _hot(4));
        vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
        vm.prank(hot);
        venue.post(entry);

        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(updater);
        venue.setUpdater(stranger, true);
    }

    function test_setSettler() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.SettlerSet(next);
        vm.prank(owner);
        venue.setSettler(next);
        assertEq(venue.settler(), next);

        eur.mint(address(venue), 1e6);
        _expectFillRevert(abi.encodeWithSelector(IVenue.NotSettler.selector), pairId, true, true, 1e6);
        vm.prank(next);
        venue.fill(pairId, address(eur), address(usd), 1e6, true, taker, HOME, REF);

        vm.expectRevert(IVenue.ZeroAddress.selector);
        vm.prank(owner);
        venue.setSettler(address(0));
        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(updater);
        venue.setSettler(updater);
    }

    function test_fill_onlySettler() public {
        eur.mint(address(venue), 1e6);
        address[4] memory callers = [owner, updater, taker, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotSettler.selector);
            vm.prank(callers[i]);
            venue.fill(pairId, address(eur), address(usd), 1e6, true, taker, HOME, REF);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // withdraw
    // ---------------------------------------------------------------------------------------------------------------

    function test_withdraw() public {
        address to = makeAddr("treasury");
        // The memo reaches the token transfer, not just the event.
        vm.expectCall(address(usd), abi.encodeCall(ITIP20.transferWithMemo, (to, 123e6, bytes32("memo"))), 1);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.Withdrawn(address(usd), to, 123e6, bytes32("memo"));
        vm.prank(owner);
        venue.withdraw(address(usd), to, 123e6, bytes32("memo"));
        assertEq(usd.balanceOf(to), 123e6);
        assertEq(usd.balanceOf(address(venue)), INVENTORY - 123e6);
    }

    function test_withdraw_anyTokenTheVenueHolds() public {
        MockTIP20V2 stray = new MockTIP20V2("STRAY", 6);
        stray.mint(address(venue), 7);
        vm.prank(owner);
        venue.withdraw(address(stray), owner, 7, bytes32(0));
        assertEq(stray.balanceOf(owner), 7);
    }

    function test_withdraw_rejectsZeroRecipientAndAmount() public {
        vm.startPrank(owner);
        vm.expectRevert(IVenue.ZeroAddress.selector);
        venue.withdraw(address(usd), address(0), 1, bytes32(0));
        vm.expectRevert(IVenue.ZeroAmount.selector);
        venue.withdraw(address(usd), owner, 0, bytes32(0));
        vm.stopPrank();
    }

    function test_withdraw_onlyOwner() public {
        address[3] memory callers = [updater, settler, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(callers[i]);
            venue.withdraw(address(usd), callers[i], 1, bytes32(0));
        }
    }

    function test_withdraw_requiresExactVenueDelta() public {
        MockSilentTIP20 silent = new MockSilentTIP20("SIL", 6);
        silent.mint(address(venue), 10);
        silent.setSilent(true);
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(silent), address(venue), 10, 0)
        );
        vm.prank(owner);
        venue.withdraw(address(silent), owner, 10, bytes32(0));
    }

    function test_withdraw_rejectsOverDebit() public {
        // A sender-paid fee: the venue loses more than it sent.
        MockSilentTIP20 skew = new MockSilentTIP20("SKEW", 6);
        skew.mint(address(venue), 20);
        skew.setSkew(3, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(skew), address(venue), 10, 13)
        );
        vm.prank(owner);
        venue.withdraw(address(skew), owner, 10, bytes32(0));
    }

    /// @dev On Tempo a receiver's TIP-1028 policy doesn't revert a blocked transfer: it parks the funds in the
    /// ReceivePolicyGuard under a receipt that, with the default originator recovery, only the originator can claim,
    /// and the originator here is the venue, which has no call that could. So the withdrawal must revert instead, for a
    /// sender policy and a token filter alike.
    function test_withdraw_receivePolicyBlockReverts() public {
        MockGuardedTIP20 guarded = new MockGuardedTIP20("GEUR");
        guarded.mint(address(venue), 1_000e6);
        address exchange = makeAddr("exchangeDeposit");
        bytes memory blocked =
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(guarded), exchange, 400e6, 0);

        // A sender whitelist without the venue, with the default (originator) recovery.
        vm.prank(exchange);
        guarded.setReceivePolicy(true, true, address(0));
        vm.expectRevert(blocked);
        vm.prank(owner);
        venue.withdraw(address(guarded), exchange, 400e6, bytes32("payout"));

        // A token filter that accepts only other tokens.
        vm.prank(exchange);
        guarded.setReceivePolicy(false, false, address(0));
        vm.expectRevert(blocked);
        vm.prank(owner);
        venue.withdraw(address(guarded), exchange, 400e6, bytes32("payout"));
        assertEq(guarded.balanceOf(address(venue)), 1_000e6);
        assertEq(guarded.balanceOf(guarded.GUARD()), 0);
        assertEq(guarded.receiptCount(), 0);

        // Once the receiver accepts the venue as a sender, the withdrawal lands.
        vm.startPrank(exchange);
        guarded.setReceivePolicy(true, true, address(0));
        guarded.setSenderListed(address(venue), true);
        vm.stopPrank();
        vm.prank(owner);
        venue.withdraw(address(guarded), exchange, 400e6, bytes32("payout"));
        assertEq(guarded.balanceOf(exchange), 400e6);
        assertEq(guarded.balanceOf(address(venue)), 600e6);
    }

    function test_withdraw_redirectReverts() public {
        address to = makeAddr("treasury");
        usd.setRedirectRecipient(makeAddr("escrow"));
        vm.expectRevert(abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(usd), to, 1e6, 0));
        vm.prank(owner);
        venue.withdraw(address(usd), to, 1e6, bytes32(0));
    }

    function test_withdraw_rejectsRecipientOverCredit() public {
        // The venue's delta is exact, but the recipient is credited more than the amount.
        MockSilentTIP20 skew = new MockSilentTIP20("SKEW", 6);
        skew.mint(address(venue), 20);
        skew.setSkew(0, 3);
        vm.expectRevert(abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(skew), owner, 10, 13));
        vm.prank(owner);
        venue.withdraw(address(skew), owner, 10, bytes32(0));
    }

    /// @dev The venue pays `to` as given, with no TIP-1022 resolution. A token that forwards the transfer to a virtual
    /// address's master leaves `to`'s balance unchanged, so the exact-credit check reverts the withdrawal: the master
    /// is paid nothing, nothing is stranded at the virtual address and the venue keeps its inventory.
    function test_withdraw_virtualRecipientReverts() public {
        address virtualAddress = VirtualAddress.make(0x12345678, 0xAA);
        address master = makeAddr("master");
        resolver.setResolution(virtualAddress, master);
        uint256 inventory = usd.balanceOf(address(venue));
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(usd), virtualAddress, 5e6, 0)
        );
        vm.prank(owner);
        venue.withdraw(address(usd), virtualAddress, 5e6, bytes32("m"));
        assertEq(usd.balanceOf(address(venue)), inventory);
        assertEq(usd.balanceOf(master), 0);
        assertEq(usd.balanceOf(virtualAddress), 0);
        // The master itself is paid as usual.
        vm.prank(owner);
        venue.withdraw(address(usd), master, 5e6, bytes32("m"));
        assertEq(usd.balanceOf(master), 5e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ownership
    // ---------------------------------------------------------------------------------------------------------------

    function test_ownership_twoStep() public {
        address next = makeAddr("nextOwner");

        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(updater);
        venue.transferOwnership(next);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.OwnershipTransferStarted(owner, next);
        vm.prank(owner);
        venue.transferOwnership(next);
        assertEq(venue.pendingOwner(), next);
        assertEq(venue.owner(), owner);

        vm.expectRevert(IVenue.NotPendingOwner.selector);
        vm.prank(stranger);
        venue.acceptOwnership();
        vm.expectRevert(IVenue.NotPendingOwner.selector);
        vm.prank(owner);
        venue.acceptOwnership();

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.OwnershipTransferred(owner, next);
        vm.prank(next);
        venue.acceptOwnership();
        assertEq(venue.owner(), next);
        assertEq(venue.pendingOwner(), address(0));

        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(owner);
        venue.withdraw(address(usd), owner, 1, bytes32(0));
        vm.prank(next);
        venue.withdraw(address(usd), next, 1, bytes32(0));

        vm.expectRevert(IVenue.NotPendingOwner.selector);
        vm.prank(next);
        venue.acceptOwnership();
    }

    function test_ownership_pendingOwnerCanBeReplaced() public {
        address first = makeAddr("first");
        address second = makeAddr("second");
        vm.startPrank(owner);
        venue.transferOwnership(first);
        venue.transferOwnership(second);
        vm.stopPrank();
        vm.expectRevert(IVenue.NotPendingOwner.selector);
        vm.prank(first);
        venue.acceptOwnership();
        vm.prank(second);
        venue.acceptOwnership();
        assertEq(venue.owner(), second);
    }

    function test_ownership_pendingOwnerCanBeCancelled() public {
        address nominee = makeAddr("nominee");
        address next = makeAddr("nextOwner");
        vm.prank(owner);
        venue.transferOwnership(nominee);

        vm.expectRevert(IVenue.ZeroAddress.selector);
        vm.prank(owner);
        venue.transferOwnership(address(0));
        assertEq(venue.pendingOwner(), nominee, "a rejected nomination preserves the pending transfer");

        address[3] memory notOwner = [nominee, updater, stranger];
        for (uint256 i; i < notOwner.length; ++i) {
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(notOwner[i]);
            venue.cancelOwnershipTransfer();
            assertEq(venue.pendingOwner(), nominee);
        }

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.OwnershipTransferStarted(owner, address(0));
        vm.prank(owner);
        venue.cancelOwnershipTransfer();
        assertEq(venue.owner(), owner, "cancellation keeps the owner");
        assertEq(venue.pendingOwner(), address(0), "cancellation clears the nominee");

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.OwnershipTransferStarted(owner, address(0));
        vm.prank(owner);
        venue.cancelOwnershipTransfer();

        vm.expectRevert(IVenue.NotPendingOwner.selector);
        vm.prank(nominee);
        venue.acceptOwnership();
        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(nominee);
        venue.setSettler(nominee);

        vm.prank(owner);
        venue.transferOwnership(next);
        vm.prank(next);
        venue.acceptOwnership();
        assertEq(venue.owner(), next, "the owner can start a later transfer");
        assertEq(venue.pendingOwner(), address(0));
        vm.prank(next);
        venue.transferOwnership(nominee);
        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(owner);
        venue.cancelOwnershipTransfer();
        assertEq(venue.pendingOwner(), nominee, "the former owner cannot cancel a new handover");
        vm.prank(next);
        venue.cancelOwnershipTransfer();
        assertEq(venue.pendingOwner(), address(0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // post
    // ---------------------------------------------------------------------------------------------------------------

    function test_post_lengthMustBeANonzeroMultipleOf34() public {
        uint256[5] memory lengths = [uint256(0), 1, 33, 35, 67];
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory packed = new bytes(lengths[i]);
            vm.expectRevert(abi.encodeWithSelector(IVenue.MalformedPost.selector, lengths[i]));
            vm.prank(owner);
            venue.post(packed);
        }
    }

    function test_post_storesAndEmits() public {
        bytes32 word = _hot(3);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.Posted(pairId, word);
        _postAs(updater, pairId, word);
        assertEq(venue.hotWord(pairId), word);
    }

    function test_post_staleSeqIsSkippedWithNoWriteOrEvent() public {
        bytes32 current = venue.hotWord(pairId);
        HotWord.Fields memory f = _fields(2);
        f.mid = MID + 1;
        bytes32 sameSeq = HotWord.pack(f);
        f.seq = 1;
        bytes32 lowerSeq = HotWord.pack(f);

        vm.record();
        vm.recordLogs();
        vm.prank(owner);
        venue.post(bytes.concat(_entry(pairId, sameSeq), _entry(pairId, lowerSeq)));
        assertEq(_storageWrites(address(venue)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(venue.hotWord(pairId), current);
    }

    function test_post_rejectsZeroMid() public {
        HotWord.Fields memory f = _fields(3);
        f.mid = 0;
        bytes memory entry = _entry(pairId, HotWord.pack(f));
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHotWord.selector, pairId));
        vm.prank(owner);
        venue.post(entry);
    }

    function test_post_rejectsReservedFlags() public {
        // Bits 2 and 3 refill; bit 4 and all higher bits are reserved.
        for (uint256 bit = 4; bit < 16; ++bit) {
            HotWord.Fields memory f = _fields(3);
            f.flags = uint16(1 << bit);
            bytes memory entry = _entry(pairId, HotWord.pack(f));
            vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHotWord.selector, pairId));
            vm.prank(owner);
            venue.post(entry);
        }
        HotWord.Fields memory g = _fields(3);
        g.flags = HotWord.FLAG_BIDS_OFF | HotWord.FLAG_ASKS_OFF;
        _post(pairId, HotWord.pack(g));
        assertEq(HotWord.flags(venue.hotWord(pairId)), 3);
        // The refill bits are accepted and applied, never stored.
        g.seq = 4;
        g.flags = HotWord.FLAGS_MASK;
        _post(pairId, HotWord.pack(g));
        assertEq(HotWord.flags(venue.hotWord(pairId)), 3);
    }

    function test_post_rejectsUnknownPair() public {
        bytes memory entry = _entry(5, _hot(3));
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(5)));
        vm.prank(owner);
        venue.post(entry);
    }

    function test_post_multiPairBatch() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        MockTIP20V2 chf = new MockTIP20V2("CHFC", 6);
        vm.startPrank(owner);
        uint16 p1 = venue.addPair(address(gbp), address(usd), UNIT);
        uint16 p2 = venue.addPair(address(chf), address(usd), UNIT);
        vm.stopPrank();

        bytes32 w0 = _hot(3);
        bytes32 w1 = _hot(9);
        bytes32 stale = _hot(1); // p2 is still at seq 1
        vm.recordLogs();
        vm.prank(updater);
        venue.post(bytes.concat(_entry(p1, w1), _entry(pairId, w0), _entry(p2, stale)));

        assertEq(venue.hotWord(pairId), w0);
        assertEq(venue.hotWord(p1), w1);
        assertEq(venue.hotWord(p2), HotWord.INITIAL);
        assertEq(vm.getRecordedLogs().length, 2);
    }

    function test_post_samePairTwiceInOneBatch() public {
        bytes32 first = _hot(5);
        bytes32 second = _hot(6);
        bytes32 third = _hot(4);
        vm.recordLogs();
        vm.prank(owner);
        venue.post(bytes.concat(_entry(pairId, first), _entry(pairId, second), _entry(pairId, third)));
        assertEq(venue.hotWord(pairId), second);
        assertEq(vm.getRecordedLogs().length, 2);
    }

    function test_post_badEntryRevertsTheWholeBatch() public {
        bytes32 before = venue.hotWord(pairId);
        HotWord.Fields memory f = _fields(3);
        f.mid = 0;
        bytes memory packed = bytes.concat(_entry(pairId, _hot(3)), _entry(pairId, HotWord.pack(f)));
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidHotWord.selector, pairId));
        vm.prank(owner);
        venue.post(packed);

        packed = bytes.concat(_entry(pairId, _hot(3)), _entry(9, _hot(3)));
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(9)));
        vm.prank(owner);
        venue.post(packed);
        assertEq(venue.hotWord(pairId), before);
    }

    function test_post_saturatedSeqCanAlsoRecoverByReplacingThePair() public {
        // A rogue updater posts the last seq with no expiry.
        HotWord.Fields memory f = _fields(type(uint32).max);
        f.validUntil = type(uint40).max;
        bytes32 frozen = HotWord.pack(f);
        _postAs(updater, pairId, frozen);
        vm.prank(owner);
        venue.setUpdater(updater, false);

        // Nobody can post past it, the owner included: seq is strictly increasing.
        vm.recordLogs();
        _postAs(owner, pairId, _hot(type(uint32).max));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(venue.hotWord(pairId), frozen);

        // The owner's levers stop it at once: closePair blocks fills, setHalted blocks fills and quotes.
        vm.prank(owner);
        venue.closePair(pairId);
        eur.mint(address(venue), 1e6);
        _expectFillRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker), pairId, true, true, 1e6);
        vm.prank(owner);
        venue.setHalted(true);
        vm.expectRevert(IVenue.VenueHalted.selector);
        venue.quote(pairId, address(eur), address(usd), 1e6, true);

        // Removing and re-adding remains an alternative to the owner-only reset: a fresh pair at seq 1.
        vm.startPrank(owner);
        venue.removePair(pairId);
        uint16 fresh = venue.addPair(address(eur), address(usd), UNIT);
        venue.setShape(fresh, 0, _defaultShape());
        venue.setHalted(false);
        vm.stopPrank();
        assertEq(venue.hotWord(fresh), HotWord.INITIAL);
        _post(fresh, _hot(2));
        assertEq(venue.hotWord(fresh), _hot(2));
        venue.quote(fresh, address(eur), address(usd), 1e6, true);
    }

    function test_post_auth() public {
        _postAs(owner, pairId, _hot(3));
        _postAs(updater, pairId, _hot(4));
        bytes memory entry = _entry(pairId, _hot(5));
        address[3] memory callers = [settler, taker, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
            vm.prank(callers[i]);
            venue.post(entry);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Mid band
    // ---------------------------------------------------------------------------------------------------------------

    function test_setMidBand_setsEmitsAndClears() public {
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.MidBandSet(pairId, BAND_MIN, BAND_MAX);
        vm.prank(owner);
        venue.setMidBand(pairId, BAND_MIN, BAND_MAX);
        _assertBand(pairId, BAND_MIN, BAND_MAX);

        // A point band is allowed.
        vm.prank(owner);
        venue.setMidBand(pairId, MID, MID);
        _assertBand(pairId, MID, MID);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.MidBandSet(pairId, 0, 0);
        vm.prank(owner);
        venue.setMidBand(pairId, 0, 0);
        _assertBand(pairId, 0, 0);
    }

    function test_setMidBand_rejectsAnIncoherentBand() public {
        uint96[2][4] memory bad = [
            [uint96(0), BAND_MAX], // an open floor: (0, 0) is the only band with a zero bound
            [BAND_MIN, uint96(0)],
            [BAND_MAX, BAND_MIN],
            [BAND_MIN + 1, BAND_MIN]
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IVenue.InvalidMidBand.selector);
            vm.prank(owner);
            venue.setMidBand(pairId, bad[i][0], bad[i][1]);
        }
        _assertBand(pairId, 0, 0);
        assertEq(_bandedPairs(), 0);
    }

    /// @dev Only the owner sets bands: the updater, whose posts the band bounds, can't.
    function test_setMidBand_auth() public {
        address[4] memory callers = [updater, settler, taker, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(callers[i]);
            venue.setMidBand(pairId, BAND_MIN, BAND_MAX);
            vm.expectRevert(IVenue.NotOwner.selector);
            vm.prank(callers[i]);
            venue.setMidBand(pairId, 0, 0);
        }
        _assertBand(pairId, 0, 0);

        // The pair must exist, and a removed pair counts as unknown.
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(7)));
        venue.setMidBand(7, BAND_MIN, BAND_MAX);
        venue.removePair(pairId);
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, pairId));
        venue.setMidBand(pairId, BAND_MIN, BAND_MAX);
        vm.stopPrank();
    }

    function test_post_updaterMidAtTheBandEdges() public {
        vm.prank(owner);
        venue.setMidBand(pairId, BAND_MIN, BAND_MAX);

        _postMidAs(updater, BAND_MIN);
        assertEq(HotWord.mid(venue.hotWord(pairId)), BAND_MIN);
        _postMidAs(updater, BAND_MAX);
        assertEq(HotWord.mid(venue.hotWord(pairId)), BAND_MAX);

        bytes32 before = venue.hotWord(pairId);
        _expectMidOutOfBand(BAND_MIN - 1);
        _expectMidOutOfBand(BAND_MAX + 1);
        _expectMidOutOfBand(1);
        _expectMidOutOfBand(type(uint96).max);
        assertEq(venue.hotWord(pairId), before);
    }

    /// @dev An out-of-band entry reverts the whole batch, including entries for other pairs and in-band entries.
    function test_post_outOfBandEntryRevertsTheWholeBatch() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        vm.startPrank(owner);
        uint16 other = venue.addPair(address(gbp), address(usd), UNIT);
        venue.setMidBand(pairId, BAND_MIN, BAND_MAX);
        vm.stopPrank();
        bytes32 before = venue.hotWord(pairId);

        // An in-band entry, then an out-of-band one at the seq after it.
        HotWord.Fields memory f = _fields(_nextSeq(pairId) + 1);
        f.mid = BAND_MAX + 1;
        bytes memory packed = bytes.concat(
            _entry(other, _hot(5)), _entry(pairId, _hot(_nextSeq(pairId))), _entry(pairId, HotWord.pack(f))
        );
        vm.expectRevert(abi.encodeWithSelector(IVenue.MidOutOfBand.selector, pairId, BAND_MAX + 1));
        vm.prank(updater);
        venue.post(packed);
        assertEq(venue.hotWord(pairId), before);
        assertEq(venue.hotWord(other), HotWord.INITIAL);
    }

    /// @dev A stale entry is skipped before the band is looked at, whatever its mid: no revert, write or event.
    function test_post_staleOutOfBandEntryIsSkipped() public {
        vm.prank(owner);
        venue.setMidBand(pairId, BAND_MIN, BAND_MAX);
        bytes32 current = venue.hotWord(pairId);
        HotWord.Fields memory f = _fields(HotWord.seq(current));
        f.mid = 1;
        bytes memory sameSeq = _entry(pairId, HotWord.pack(f));
        f.seq = 1;
        f.mid = type(uint96).max;

        vm.record();
        vm.recordLogs();
        vm.prank(updater);
        venue.post(bytes.concat(sameSeq, _entry(pairId, HotWord.pack(f))));
        assertEq(_storageWrites(address(venue)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(venue.hotWord(pairId), current);
    }

    /// @dev The band bounds the updater key, not the owner key.
    function test_post_ownerIsNotBandChecked() public {
        vm.prank(owner);
        venue.setMidBand(pairId, BAND_MIN, BAND_MAX);
        _postMidAs(owner, 1);
        assertEq(HotWord.mid(venue.hotWord(pairId)), 1);
        _postMidAs(owner, type(uint96).max);
        assertEq(HotWord.mid(venue.hotWord(pairId)), type(uint96).max);
    }

    /// @dev A band binds only its own pair; a pair without one still takes any mid from the updater.
    function test_post_bandBindsOnlyItsPair() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        vm.startPrank(owner);
        uint16 other = venue.addPair(address(gbp), address(usd), UNIT);
        venue.setMidBand(other, BAND_MIN, BAND_MAX);
        vm.stopPrank();
        _postMidAs(updater, 1);
        assertEq(HotWord.mid(venue.hotWord(pairId)), 1);
    }

    /// @dev Tightening a band doesn't touch the live hot word: the owner halts or reposts afterwards.
    function test_setMidBand_doesNotRecheckTheLiveHotWord() public {
        bytes32 live = venue.hotWord(pairId);
        vm.prank(owner);
        venue.setMidBand(pairId, MID + 1, MID + 2);
        assertEq(venue.hotWord(pairId), live);
        (, uint128 out) = venue.quote(pairId, address(eur), address(usd), 1e6, true);
        assertGt(out, 0);
    }

    function testFuzz_post_updaterMidAcceptedExactlyInsideTheBand(uint96 minMid, uint96 maxMid, uint96 mid) public {
        minMid = uint96(bound(minMid, 1, type(uint96).max));
        maxMid = uint96(bound(maxMid, minMid, type(uint96).max));
        mid = uint96(bound(mid, 1, type(uint96).max));
        vm.prank(owner);
        venue.setMidBand(pairId, minMid, maxMid);
        if (mid < minMid || mid > maxMid) {
            _expectMidOutOfBand(mid);
        } else {
            _postMidAs(updater, mid);
            assertEq(HotWord.mid(venue.hotWord(pairId)), mid);
        }
    }

    /// @dev The counter tracks pairs with a band through set, update, clear and `removePair`, which also clears the
    /// band itself. It never double counts or underflows.
    function test_midBand_counterBookkeeping() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        MockTIP20V2 chf = new MockTIP20V2("CHFC", 6);
        vm.startPrank(owner);
        uint16 b = venue.addPair(address(gbp), address(usd), UNIT);
        uint16 c = venue.addPair(address(chf), address(usd), UNIT);

        venue.setMidBand(pairId, BAND_MIN, BAND_MAX);
        assertEq(_bandedPairs(), 1);
        venue.setMidBand(pairId, BAND_MIN - 1, BAND_MAX + 1); // an update, not a new band
        assertEq(_bandedPairs(), 1);
        venue.setMidBand(b, 1, 2);
        assertEq(_bandedPairs(), 2);
        venue.setMidBand(pairId, 0, 0);
        assertEq(_bandedPairs(), 1);
        venue.setMidBand(pairId, 0, 0); // clearing a clear band
        assertEq(_bandedPairs(), 1);

        // Removing an unbanded pair leaves the count alone; removing a banded pair clears its band.
        venue.removePair(c);
        assertEq(_bandedPairs(), 1);
        venue.removePair(b);
        assertEq(_bandedPairs(), 0);
        vm.stopPrank();
        _assertBand(b, 0, 0);
        assertEq(vm.load(address(venue), _midBandSlot(b)), bytes32(0));

        // With the count back at 0, `removePair` of an unbanded pair doesn't underflow.
        vm.prank(owner);
        venue.removePair(pairId);
        assertEq(_bandedPairs(), 0);
        // The counter shares slot 0 without disturbing its neighbours.
        assertEq(venue.owner(), owner);
        assertEq(venue.pairCount(), 3);
        assertFalse(venue.halted());
    }

    /// @dev Without bands `post` never reads a band slot. Once some pair has a band, an updater's entry reads its own
    /// pair's band (which also shows the access recording works), and the owner's entries still read none.
    function test_midBand_postReadsBandsOnlyWhileOneExists() public {
        MockTIP20V2 gbp = new MockTIP20V2("GBPC", 6);
        vm.prank(owner);
        uint16 other = venue.addPair(address(gbp), address(usd), UNIT);

        assertFalse(_postReadsBandSlot(updater));
        vm.startPrank(owner);
        venue.setMidBand(other, 1, type(uint96).max);
        venue.setMidBand(other, 0, 0);
        vm.stopPrank();
        assertFalse(_postReadsBandSlot(updater));

        vm.prank(owner);
        venue.setMidBand(other, 1, type(uint96).max);
        assertTrue(_postReadsBandSlot(updater));
        assertFalse(_postReadsBandSlot(owner));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // setShape
    // ---------------------------------------------------------------------------------------------------------------

    function test_setShape_validation() public {
        uint256[4] memory words = _defaultShape();
        words[3] |= uint256(1) << 250;
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidShape.selector, ShapeWord.REASON_RESERVED_BITS));
        vm.prank(owner);
        venue.setShape(pairId, 1, words);

        words = _defaultShape();
        words[1] = 1; // a bid level after the bid side ended
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidShape.selector, ShapeWord.REASON_NON_CANONICAL));
        vm.prank(owner);
        venue.setShape(pairId, 1, words);

        uint32[] memory sizes = new uint32[](2);
        uint16[] memory spreads = new uint16[](2);
        (sizes[0], sizes[1]) = (1, 1);
        (spreads[0], spreads[1]) = (20, 10);
        words = _defaultShape();
        (words[2], words[3]) = ShapeWord.packSide(sizes, spreads);
        vm.expectRevert(abi.encodeWithSelector(IVenue.InvalidShape.selector, ShapeWord.REASON_SPREAD_DECREASES));
        vm.prank(owner);
        venue.setShape(pairId, 1, words);
    }

    function test_setShape_definesAndEmits() public {
        uint256[4] memory words = _flatShape(10, 30);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.ShapeSet(pairId, 200, words);
        vm.prank(updater);
        venue.setShape(pairId, 200, words);
        uint256[4] memory stored = venue.shape(pairId, 200);
        for (uint256 i; i < 4; ++i) {
            assertEq(stored[i], words[i]);
            assertEq(uint256(vm.load(address(venue), _shapeSlot(pairId, 200, i))), words[i]);
        }
    }

    function test_setShape_deleteClearsEverySlot() public {
        uint256[4] memory zero;
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.ShapeSet(pairId, 0, zero);
        vm.prank(owner);
        venue.setShape(pairId, 0, zero);
        for (uint256 i; i < 4; ++i) {
            assertEq(vm.load(address(venue), _shapeSlot(pairId, 0, i)), bytes32(0));
        }
        // A deleted active shape fills nothing: it fails safe.
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        venue.quote(pairId, address(eur), address(usd), 1, true);
    }

    function test_setShape_writesOnlyChangedWords() public {
        uint256[4] memory words = _defaultShape();
        words[0] = _flatShape(10, 30)[0];

        vm.record();
        vm.prank(owner);
        venue.setShape(pairId, 0, words);
        (, bytes32[] memory writes) = vm.accesses(address(venue));
        assertEq(writes.length, 1);
        assertEq(writes[0], _shapeSlot(pairId, 0, 0));

        vm.record();
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.ShapeSet(pairId, 0, words);
        vm.prank(owner);
        venue.setShape(pairId, 0, words);
        assertEq(_storageWrites(address(venue)), 0);
    }

    function test_setShape_activeShapeRepricesImmediately() public {
        (uint128 before,) = venue.quote(pairId, address(usd), address(eur), 1e6, false);
        uint256[4] memory words = _defaultShape();
        words[2] = _flatShape(500, 100)[2];
        words[3] = 0;
        vm.prank(updater);
        venue.setShape(pairId, 0, words);
        (uint128 afterShape,) = venue.quote(pairId, address(usd), address(eur), 1e6, false);
        assertGt(afterShape, before);
        (uint256 expectedIn,,) = _expect(pairId, false, false, 1e6);
        assertEq(afterShape, expectedIn);
    }

    function test_setShape_postSwitchesShapeAndUndefinedShapeFillsNothing() public {
        vm.prank(owner);
        venue.setShape(pairId, 7, _flatShape(1000, 200));
        HotWord.Fields memory f = _fields(0);
        f.shapeId = 7;
        _postFields(pairId, f);
        (uint128 amountIn,) = venue.quote(pairId, address(usd), address(eur), 1e6, false);
        (uint256 expectedIn,,) = _expect(pairId, false, false, 1e6);
        assertEq(amountIn, expectedIn);

        f.shapeId = 8;
        _postFields(pairId, f);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        venue.quote(pairId, address(usd), address(eur), 1, false);
    }

    function test_setShape_removedPairAllowsOnlyDeletion() public {
        vm.startPrank(owner);
        venue.setShape(pairId, 3, _flatShape(1, 1));
        venue.removePair(pairId);

        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, pairId));
        venue.setShape(pairId, 3, _flatShape(2, 2));

        uint256[4] memory zero;
        venue.setShape(pairId, 3, zero);
        venue.setShape(pairId, 0, zero);
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            assertEq(venue.shape(pairId, 3)[i], 0);
            assertEq(venue.shape(pairId, 0)[i], 0);
        }
    }

    function test_setShape_unknownPairAndAuth() public {
        uint256[4] memory zero;
        vm.expectRevert(abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(1)));
        vm.prank(owner);
        venue.setShape(1, 0, zero);

        address[2] memory callers = [settler, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IVenue.NotOwnerOrUpdater.selector);
            vm.prank(callers[i]);
            venue.setShape(pairId, 0, zero);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // fill and quote
    // ---------------------------------------------------------------------------------------------------------------

    function test_fill_sellBaseExactIn() public {
        _checkFill(true, true, 250e6);
    }

    function test_fill_sellBaseExactOut() public {
        _checkFill(true, false, 400e6);
    }

    function test_fill_buyBaseExactIn() public {
        _checkFill(false, true, 300e6);
    }

    function test_fill_buyBaseExactOut() public {
        _checkFill(false, false, 420e6);
    }

    /// @dev Pins `Fill`'s ABI for indexers: three indexed topics and six data words, with no `source` field (RFQ is out
    /// of scope for this release, so every fill is a resting one).
    function test_fill_eventAbi() public {
        assertEq(
            IVenue.Fill.selector,
            keccak256("Fill(uint16,address,bytes32,uint64,bool,uint128,uint128,uint96,uint32)"),
            "Fill topic0"
        );
        vm.recordLogs();
        (uint128 amountIn, uint128 amountOut) = _fill(pairId, true, true, 1e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fills;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(venue) || logs[i].topics[0] != IVenue.Fill.selector) continue;
            ++fills;
            assertEq(logs[i].topics.length, 4, "topics");
            assertEq(logs[i].data.length, 6 * 32, "data words");
            bytes32 hot = venue.hotWord(pairId);
            assertEq(
                logs[i].data, abi.encode(HOME, true, amountIn, amountOut, HotWord.mid(hot), HotWord.seq(hot)), "data"
            );
        }
        assertEq(fills, 1, "one Fill");
    }

    function test_fill_handVectors() public {
        // Ask L1 at 0.5 bp: 1 EUR costs ceil(1.085 * 1.00005) = 1.085055 USD.
        (uint128 amountIn, uint128 amountOut) = _fill(pairId, false, false, 1e6);
        assertEq(amountIn, 1_085_055);
        assertEq(amountOut, 1e6);
        // Bid L1 at 1 bp: the sell nets out the 1 EUR buy at the first bid level, 1.084891 = floor(1.085 * 0.9999).
        (amountIn, amountOut) = _fill(pairId, true, true, 1e6);
        assertEq(amountIn, 1e6);
        assertEq(amountOut, 1_084_891);
    }

    function test_fill_scalarsReshapeTheLadder() public {
        HotWord.Fields memory f = _fields(0);
        f.bidWiden = 7;
        f.askWiden = 11;
        f.widthScale = 1500;
        f.depthScale = 500;
        _postFields(pairId, f);
        _checkFill(true, true, 150e6);
        _checkFill(false, false, 200e6);
        // depthScale 500 halves the ask: 225 EUR is all of it.
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        venue.quote(pairId, address(usd), address(eur), 225e6 + 1, false);
    }

    function test_fill_tokenMismatch() public {
        MockTIP20V2 other = new MockTIP20V2("X", 6);
        address[2][6] memory cases = [
            [address(eur), address(eur)],
            [address(usd), address(usd)],
            [address(eur), address(other)],
            [address(other), address(usd)],
            [address(usd), address(other)],
            [address(other), address(eur)]
        ];
        for (uint256 i; i < cases.length; ++i) {
            bytes memory err = abi.encodeWithSelector(IVenue.TokenMismatch.selector, cases[i][0], cases[i][1]);
            vm.expectRevert(err);
            venue.quote(pairId, cases[i][0], cases[i][1], 1e6, true);
            vm.expectRevert(err);
            vm.prank(settler);
            venue.fill(pairId, cases[i][0], cases[i][1], 1e6, true, taker, HOME, REF);
        }
    }

    function test_fill_zeroAmount() public {
        _expectFillRevert(abi.encodeWithSelector(IVenue.ZeroAmount.selector), pairId, true, true, 0);
        vm.expectRevert(IVenue.ZeroAmount.selector);
        venue.quote(pairId, address(usd), address(eur), 0, false);
    }

    function test_fill_validUntilIsInclusive() public {
        uint40 validUntil = HotWord.validUntil(venue.hotWord(pairId));
        vm.warp(validUntil);
        _fill(pairId, true, true, 1e6);
        venue.quote(pairId, address(eur), address(usd), 1e6, true);

        vm.warp(uint256(validUntil) + 1);
        bytes memory err = abi.encodeWithSelector(IVenue.QuoteExpired.selector, validUntil);
        vm.expectRevert(err);
        venue.quote(pairId, address(eur), address(usd), 1e6, true);
        eur.mint(address(venue), 1e6);
        _expectFillRevert(err, pairId, true, true, 1e6);
    }

    function test_fill_depthScaleZeroDisablesBothSides() public {
        HotWord.Fields memory f = _fields(0);
        f.depthScale = 0;
        _postFields(pairId, f);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SideDisabled.selector, true));
        venue.quote(pairId, address(eur), address(usd), 1e6, true);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SideDisabled.selector, false));
        venue.quote(pairId, address(usd), address(eur), 1e6, true);
        eur.mint(address(venue), 1e6);
        _expectFillRevert(abi.encodeWithSelector(IVenue.SideDisabled.selector, true), pairId, true, true, 1e6);
    }

    function test_fill_sideFlags() public {
        HotWord.Fields memory f = _fields(0);
        f.flags = HotWord.FLAG_BIDS_OFF;
        _postFields(pairId, f);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SideDisabled.selector, true));
        venue.quote(pairId, address(eur), address(usd), 1e6, true);
        _fill(pairId, false, true, 1e6);

        f.flags = HotWord.FLAG_ASKS_OFF;
        _postFields(pairId, f);
        vm.expectRevert(abi.encodeWithSelector(IVenue.SideDisabled.selector, false));
        venue.quote(pairId, address(usd), address(eur), 1e6, false);
        usd.mint(address(venue), 1e6);
        _expectFillRevert(abi.encodeWithSelector(IVenue.SideDisabled.selector, false), pairId, false, true, 1e6);
        _fill(pairId, true, true, 1e6);
    }

    function test_fill_beyondDepthAndZeroFill() public {
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        venue.quote(pairId, address(eur), address(usd), 600e6 + 1, true);
        vm.expectRevert(LadderMath.InsufficientDepth.selector);
        venue.quote(pairId, address(usd), address(eur), 450e6 + 1, false);
        // Selling one base unit rounds down to zero quote at a sub-1 mid.
        HotWord.Fields memory f = _fields(0);
        f.mid = 0.5e18;
        _postFields(pairId, f);
        vm.expectRevert(LadderMath.ZeroFill.selector);
        venue.quote(pairId, address(eur), address(usd), 1, true);
        eur.mint(address(venue), 1);
        _expectFillRevert(abi.encodeWithSelector(LadderMath.ZeroFill.selector), pairId, true, true, 1);
    }

    function test_quote_amountOverflow() public {
        (MockTIP20V2 big, uint16 index) = _bigPair();
        // About 2^96 base at a mid near 2^96 / 1e18 is about 2^132 quote.
        vm.expectRevert(IVenue.AmountOverflow.selector);
        venue.quote(index, address(big), address(usd), uint128(1) << 95, true);
    }

    function test_quote_amountInOverflow() public {
        (MockTIP20V2 big, uint16 index) = _bigPair();
        uint128 amount = uint128(1) << 95;
        // Buying 2^95 base exact-out costs about 2^131 quote. The venue holds the base, so without the check the
        // truncated input would quote and fill.
        big.mint(address(venue), amount);
        (uint256 expectedIn, uint256 expectedOut,) = _expect(index, false, false, amount);
        assertEq(expectedOut, amount);
        assertGt(expectedIn, type(uint128).max);

        vm.expectRevert(IVenue.AmountOverflow.selector);
        venue.quote(index, address(usd), address(big), amount, false);
        vm.expectRevert(IVenue.AmountOverflow.selector);
        vm.prank(settler);
        venue.fill(index, address(usd), address(big), amount, false, taker, HOME, REF);
    }

    function test_fill_inventoryShortfall() public {
        vm.prank(owner);
        venue.withdraw(address(usd), owner, INVENTORY - 1e6, bytes32(0));
        (uint256 expectedIn, uint256 expectedOut,) = _expect(pairId, true, true, 2e6);
        bytes memory err = abi.encodeWithSelector(IVenue.InsufficientInventory.selector, address(usd), 1e6, expectedOut);
        vm.expectRevert(err);
        venue.quote(pairId, address(eur), address(usd), 2e6, true);
        eur.mint(address(venue), expectedIn);
        _expectFillRevert(err, pairId, true, true, 2e6);
        // A smaller fill the inventory covers still fills.
        _fill(pairId, true, true, 9e5);
    }

    function testFuzz_quotePredictsFillAndMatchesLadderMath(bool baseIn, bool exactIn, uint128 amount) public {
        amount = uint128(bound(amount, 1, 800e6));
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        bytes32 hot = venue.hotWord(pairId);
        uint256[4] memory words = venue.shape(pairId, 0);
        try oracle.fill(hot, UNIT, baseIn, words, exactIn, amount, _consumed(pairId, baseIn)) returns (
            uint256 eIn, uint256 eOut, uint256
        ) {
            (uint128 qIn, uint128 qOut) = venue.quote(pairId, tokenIn, tokenOut, amount, exactIn);
            assertEq(qIn, eIn);
            assertEq(qOut, eOut);
            (uint128 fIn, uint128 fOut) = _fill(pairId, baseIn, exactIn, amount);
            assertEq(fIn, qIn);
            assertEq(fOut, qOut);
        } catch (bytes memory err) {
            vm.expectRevert(err);
            venue.quote(pairId, tokenIn, tokenOut, amount, exactIn);
            _expectFillRevert(err, pairId, baseIn, exactIn, amount);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Open pairs and self-only fills (the access lists are in VenueAccess.t.sol)
    // ---------------------------------------------------------------------------------------------------------------

    function test_open_admitsAnyoneUnderAnySponsorId() public {
        _fillFor(stranger, HOME);
        _fillFor(makeAddr("anyone"), 77);
        _fillFor(taker, type(uint64).max);
    }

    /// @dev `Open` reads neither the named sponsor's slot nor its list, even for a sponsor that is registered.
    function test_open_readsNoList() public {
        vm.prank(owner);
        venue.addSponsor(5, stranger);
        bytes32 sponsorSlot = keccak256(abi.encode(uint64(5), SLOT_SPONSORS));
        bytes32 memberSlot = keccak256(
            abi.encode(taker, keccak256(abi.encode(uint64(5), keccak256(abi.encode(pairId, SLOT_MEMBERS)))))
        );
        bytes32 admittedSlot = keccak256(abi.encode(uint64(5), keccak256(abi.encode(pairId, SLOT_ADMITTED))));
        vm.record();
        _fillFor(taker, 5);
        (bytes32[] memory reads,) = vm.accesses(address(venue));
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(reads[i] != sponsorSlot && reads[i] != memberSlot && reads[i] != admittedSlot, "no list read");
        }
    }

    function test_closed_rejectsEveryoneButQuoteSkipsAccess() public {
        vm.prank(owner);
        venue.closePair(pairId);
        eur.mint(address(venue), 1e6);
        _expectFillFor(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker), taker, HOME);
        // quote skips the access check.
        venue.quote(pairId, address(eur), address(usd), 1e6, true);
    }

    /// @dev The output goes to the taker itself, with the swap's ref as memo.
    function test_fill_paysTheTaker() public {
        (, uint256 expectedOut,) = _expect(pairId, true, true, 1e6);
        eur.mint(address(venue), 1e6);
        uint256 before = usd.balanceOf(taker);
        vm.expectCall(address(usd), abi.encodeCall(ITIP20.transferWithMemo, (taker, expectedOut, REF)), 1);
        vm.prank(settler);
        (, uint128 amountOut) = venue.fill(pairId, address(eur), address(usd), 1e6, true, taker, HOME, REF);
        assertEq(amountOut, expectedOut);
        assertEq(usd.balanceOf(taker), before + expectedOut);
    }

    /// @dev A settler always passes its caller. One that passed a TIP-1022 virtual address would see the payout
    /// forwarded to the master, so the taker's exact-credit check reverts the fill.
    function test_fill_virtualTakerFailsTheCreditCheck() public {
        address virtualAddress = VirtualAddress.make(0x12345678, 0xAA);
        address master = makeAddr("master");
        resolver.setResolution(virtualAddress, master);
        (, uint256 expectedOut,) = _expect(pairId, true, true, 1e6);
        eur.mint(address(venue), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(usd), virtualAddress, expectedOut, 0)
        );
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), 1e6, true, virtualAddress, HOME, REF);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Exact balance deltas
    // ---------------------------------------------------------------------------------------------------------------

    function test_delta_feeOnTransferReverts() public {
        usd.setFeeBps(10);
        (uint256 expectedIn, uint256 expectedOut,) = _expect(pairId, true, true, 1e6);
        uint256 received = expectedOut - expectedOut * 10 / 10_000;
        eur.mint(address(venue), expectedIn);
        _expectFillRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(usd), taker, expectedOut, received),
            pairId,
            true,
            true,
            1e6
        );
    }

    function test_delta_receivePolicyRedirectReverts() public {
        usd.setRedirectRecipient(makeAddr("escrow"));
        (, uint256 expectedOut,) = _expect(pairId, true, true, 1e6);
        eur.mint(address(venue), 1e6);
        _expectFillRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(usd), taker, expectedOut, 0),
            pairId,
            true,
            true,
            1e6
        );
    }

    /// @dev The same with a receive policy as Tempo applies it: the venue, not the Settler or the taker, is the TIP-1028
    /// sender of every payout, so a taker with a sender whitelist must list each venue it buys from.
    function test_delta_receivePolicyBlockOnPayoutReverts() public {
        MockGuardedTIP20 guarded = new MockGuardedTIP20("GUSD");
        vm.startPrank(owner);
        uint16 index = venue.addPair(address(eur), address(guarded), UNIT);
        venue.setShape(index, 0, _defaultShape());
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        _post(index, _hot(2));
        guarded.mint(address(venue), INVENTORY);
        vm.startPrank(taker);
        guarded.setReceivePolicy(true, true, address(0));
        guarded.setSenderListed(settler, true);
        guarded.setSenderListed(taker, true);
        vm.stopPrank();

        (uint256 expectedIn, uint256 expectedOut,) = _expect(index, true, true, 1e6);
        eur.mint(address(venue), expectedIn);
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.BalanceDeltaMismatch.selector, address(guarded), taker, expectedOut, 0)
        );
        vm.prank(settler);
        venue.fill(index, address(eur), address(guarded), 1e6, true, taker, HOME, REF);

        vm.prank(taker);
        guarded.setSenderListed(address(venue), true);
        vm.prank(settler);
        venue.fill(index, address(eur), address(guarded), 1e6, true, taker, HOME, REF);
        assertEq(guarded.balanceOf(taker), expectedOut);
        assertEq(guarded.balanceOf(guarded.GUARD()), 0);
    }

    function test_delta_returnFalseDoesNotAffectVenuePushes() public {
        // The venue only pushes with `transferWithMemo` and checks balances, so a token whose `transferFromWithMemo`
        // returns false (the settler's concern) changes nothing here.
        eur.setReturnFalse(true);
        usd.setReturnFalse(true);
        _fill(pairId, true, true, 1e6);
        _fill(pairId, false, false, 1e6);
        vm.prank(owner);
        venue.withdraw(address(usd), owner, 1e6, bytes32(0));
        assertEq(usd.balanceOf(owner), 1e6);
    }

    function test_delta_silentTransferReverts() public {
        (MockSilentTIP20 silent, uint16 index) = _skewQuotePair();
        silent.setSilent(true);

        (uint256 expectedIn, uint256 expectedOut,) = _expect(index, true, true, 1e6);
        eur.mint(address(venue), expectedIn);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVenue.BalanceDeltaMismatch.selector, address(silent), address(venue), expectedOut, 0
            )
        );
        vm.prank(settler);
        venue.fill(index, address(eur), address(silent), 1e6, true, taker, HOME, REF);
    }

    function test_delta_venueOverDebitReverts() public {
        // A sender-paid fee: the taker gets exactly the amount, but the venue loses more.
        (MockSilentTIP20 skew, uint16 index) = _skewQuotePair();
        skew.setSkew(7, 0);

        (uint256 expectedIn, uint256 expectedOut,) = _expect(index, true, true, 1e6);
        eur.mint(address(venue), expectedIn);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVenue.BalanceDeltaMismatch.selector, address(skew), address(venue), expectedOut, expectedOut + 7
            )
        );
        vm.prank(settler);
        venue.fill(index, address(eur), address(skew), 1e6, true, taker, HOME, REF);
    }

    function test_delta_takerOverCreditReverts() public {
        // The venue's delta is exact, but the taker is credited more than the amount.
        (MockSilentTIP20 skew, uint16 index) = _skewQuotePair();
        skew.setSkew(0, 7);

        (uint256 expectedIn, uint256 expectedOut,) = _expect(index, true, true, 1e6);
        eur.mint(address(venue), expectedIn);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVenue.BalanceDeltaMismatch.selector, address(skew), taker, expectedOut, expectedOut + 7
            )
        );
        vm.prank(settler);
        venue.fill(index, address(eur), address(skew), 1e6, true, taker, HOME, REF);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev One `_checkFill` run's tokens, expected amounts and balances before the fill. A struct in memory keeps
    /// the helper within the stack limit of the unoptimized coverage build.
    struct FillCheck {
        address tokenIn;
        address tokenOut;
        uint256 expectedIn;
        uint256 expectedOut;
        uint256 venueIn;
        uint256 venueOut;
        uint256 takerOut;
    }

    function _checkFill(bool baseIn, bool exactIn, uint128 amount) internal {
        FillCheck memory c = _checkQuote(baseIn, exactIn, amount);

        MockTIP20V2(c.tokenIn).mint(address(venue), c.expectedIn);
        c.venueIn = MockTIP20V2(c.tokenIn).balanceOf(address(venue));
        c.venueOut = MockTIP20V2(c.tokenOut).balanceOf(address(venue));
        c.takerOut = MockTIP20V2(c.tokenOut).balanceOf(taker);
        _expectFillEffects(c, baseIn);

        vm.prank(settler);
        (uint128 amountIn, uint128 amountOut) =
            venue.fill(pairId, c.tokenIn, c.tokenOut, amount, exactIn, taker, HOME, REF);

        assertEq(amountIn, c.expectedIn, "fill in");
        assertEq(amountOut, c.expectedOut, "fill out");
        assertEq(exactIn ? amountIn : amountOut, amount);
        assertEq(MockTIP20V2(c.tokenIn).balanceOf(address(venue)), c.venueIn);
        assertEq(MockTIP20V2(c.tokenOut).balanceOf(address(venue)), c.venueOut - c.expectedOut);
        assertEq(MockTIP20V2(c.tokenOut).balanceOf(taker), c.takerOut + c.expectedOut);
    }

    /// @dev Requires `quote` to match `LadderMath` for the fill, and returns the tokens and expected amounts.
    function _checkQuote(bool baseIn, bool exactIn, uint128 amount) internal view returns (FillCheck memory c) {
        (c.tokenIn, c.tokenOut) = _tokens(baseIn);
        (c.expectedIn, c.expectedOut,) = _expect(pairId, baseIn, exactIn, amount);
        (uint128 quotedIn, uint128 quotedOut) = venue.quote(pairId, c.tokenIn, c.tokenOut, amount, exactIn);
        assertEq(quotedIn, c.expectedIn, "quote in");
        assertEq(quotedOut, c.expectedOut, "quote out");
    }

    /// @dev Expects the fill's one payout transfer and its `Fill` event.
    function _expectFillEffects(FillCheck memory c, bool baseIn) internal {
        bytes32 hot = venue.hotWord(pairId);
        vm.expectCall(c.tokenOut, abi.encodeCall(ITIP20.transferWithMemo, (taker, c.expectedOut, REF)), 1);
        vm.expectEmit(true, true, true, true, address(venue));
        emit IVenue.Fill(
            pairId,
            taker,
            REF,
            HOME,
            baseIn,
            uint128(c.expectedIn),
            uint128(c.expectedOut),
            HotWord.mid(hot),
            HotWord.seq(hot)
        );
    }

    /// @dev A live EUR/SKEW pair whose quote token can skew its transfers, stocked with inventory.
    function _skewQuotePair() internal returns (MockSilentTIP20 skew, uint16 index) {
        skew = new MockSilentTIP20("SKEW", 6);
        vm.startPrank(owner);
        index = venue.addPair(address(eur), address(skew), UNIT);
        venue.setShape(index, 0, _defaultShape());
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        _post(index, _hot(2));
        skew.mint(address(venue), INVENTORY);
    }

    /// @dev A pair at the encoding's limits: sizeUnit and level size at their maximum and mid near 2^96.
    function _bigPair() internal returns (MockTIP20V2 big, uint16 index) {
        big = new MockTIP20V2("BIG", 6);
        vm.startPrank(owner);
        index = venue.addPair(address(big), address(usd), type(uint64).max);
        venue.setShape(index, 0, _flatShape(type(uint32).max, 0));
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        HotWord.Fields memory f = _fields(0);
        f.mid = type(uint96).max;
        _postFields(index, f);
    }

    function _expectFillRevert(bytes memory err, uint16 pairIndex, bool baseIn, bool exactIn, uint128 amount) internal {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        vm.expectRevert(err);
        vm.prank(settler);
        venue.fill(pairIndex, tokenIn, tokenOut, amount, exactIn, taker, HOME, REF);
    }

    /// @dev Fills 1 EUR for `taker_` under `sponsorId` and requires the output to reach `taker_`.
    function _fillFor(address taker_, uint64 sponsorId) internal {
        eur.mint(address(venue), 1e6);
        uint256 before = usd.balanceOf(taker_);
        vm.prank(settler);
        (, uint128 amountOut) = venue.fill(pairId, address(eur), address(usd), 1e6, true, taker_, sponsorId, REF);
        assertEq(usd.balanceOf(taker_), before + amountOut);
    }

    function _expectFillFor(bytes memory err, address taker_, uint64 sponsorId) internal {
        vm.expectRevert(err);
        vm.prank(settler);
        venue.fill(pairId, address(eur), address(usd), 1e6, true, taker_, sponsorId, REF);
    }

    function _postAs(address caller, uint16 pairIndex, bytes32 word) internal {
        vm.prank(caller);
        venue.post(_entry(pairIndex, word));
    }

    /// @dev Posts the default hot word with `mid` and the pair's next `seq`.
    function _postMidAs(address caller, uint96 mid) internal {
        HotWord.Fields memory f = _fields(_nextSeq(pairId));
        f.mid = mid;
        _postAs(caller, pairId, HotWord.pack(f));
    }

    function _expectMidOutOfBand(uint96 mid) internal {
        HotWord.Fields memory f = _fields(_nextSeq(pairId));
        f.mid = mid;
        bytes memory entry = _entry(pairId, HotWord.pack(f));
        vm.expectRevert(abi.encodeWithSelector(IVenue.MidOutOfBand.selector, pairId, mid));
        vm.prank(updater);
        venue.post(entry);
    }

    function _assertBand(uint16 pairIndex, uint96 minMid, uint96 maxMid) internal view {
        (uint96 storedMin, uint96 storedMax) = venue.midBand(pairIndex);
        assertEq(storedMin, minMid, "minMid");
        assertEq(storedMax, maxMid, "maxMid");
    }

    /// @dev Whether `caller`'s `post` of the pair's next hot word reads the pair's band slot.
    function _postReadsBandSlot(address caller) internal returns (bool) {
        bytes memory entry = _entry(pairId, _hot(_nextSeq(pairId)));
        vm.record();
        vm.prank(caller);
        venue.post(entry);
        (bytes32[] memory reads,) = vm.accesses(address(venue));
        assertGt(reads.length, 0, "accesses recorded");
        bytes32 slot = _midBandSlot(pairId);
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i] == slot) return true;
        }
        return false;
    }

    /// @dev A live GBP/USD pair with the default shape and inventory.
    function _secondPair() internal returns (uint16 index) {
        gbpToken = new MockTIP20V2("GBPC", 6);
        vm.startPrank(owner);
        index = venue.addPair(address(gbpToken), address(usd), UNIT);
        venue.setShape(index, 0, _defaultShape());
        vm.stopPrank();
        _setAccess(index, IVenue.AccessMode.Open);
        _post(index, _hot(2));
        gbpToken.mint(address(venue), INVENTORY);
    }

    /// @dev The default hot word with the pair's next `seq`, no expiry, so a test can warp far ahead.
    function _postLong(uint16 pairIndex) internal {
        HotWord.Fields memory f = _fields(0);
        f.validUntil = type(uint40).max;
        _postFields(pairIndex, f);
    }

    /// @dev Quote per base unit times 1e26 at an ask or bid spread (0.1 bp) of the default hot word.
    function _askUnit(uint256 spread) internal pure returns (uint256) {
        return uint256(MID) * (1e8 + spread * 1000);
    }

    function _bidUnit(uint256 spread) internal pure returns (uint256) {
        return uint256(MID) * (1e8 - spread * 1000);
    }

    function _ceil(uint256 numerator) internal pure returns (uint256) {
        return (numerator + 1e26 - 1) / 1e26;
    }

    function _sequencer() internal returns (SequenceSettler seq) {
        seq = new SequenceSettler(venue, taker, HOME);
        vm.prank(owner);
        venue.setSettler(address(seq));
        eur.mint(address(seq), INVENTORY);
        usd.mint(address(seq), INVENTORY);
    }

    function _op(bool quoteOnly, bool baseIn, bool exactIn, uint128 amount)
        internal
        view
        returns (SequenceSettler.Op memory)
    {
        (address tokenIn, address tokenOut) = _tokens(baseIn);
        return SequenceSettler.Op({
            quoteOnly: quoteOnly,
            pairIndex: pairId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amount: amount,
            exactIn: exactIn
        });
    }
}

/// @dev Deliberately exposes only ERC-20's decimal metadata.
contract PlainDecimalsToken {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @dev Looks like a memo-bearing token but was never initialized by the test factory.
contract UninitializedTIP20 {
    function decimals() external pure returns (uint8) {
        return 6;
    }

    function transferWithMemo(address, uint256, bytes32) external { }
}
