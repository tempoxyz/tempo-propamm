// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapParams } from "./utils/SwapParams.sol";

import { Test, Vm } from "forge-std/Test.sol";

import { DeployV2 } from "../../script/v2/DeployV2.s.sol";
import { SetupDemoVenue } from "../../script/v2/SetupDemoVenue.s.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { IVenueFactory } from "../../src/v2/interfaces/IVenueFactory.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";
import { DeployV2Harness } from "./harness/DeployV2Harness.sol";
import { SetupDemoVenueHarness } from "./harness/SetupDemoVenueHarness.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { TIP20FactoryMock } from "./utils/TIP20FactoryMock.sol";
import { VirtualAddress } from "./utils/VirtualAddress.sol";

/// @notice Runs `DeployV2` and then `SetupDemoVenue` in-process against mock tokens, and trades on the resulting demo
/// venue through the deployed Settler.
contract SetupDemoVenueTest is Test {
    uint256 internal constant MODERATO = 42431;
    uint64 internal constant UNIT = 1e6;
    uint96 internal constant MID = 1.085e18;
    uint96 internal constant MID_MIN = 1.08e18;
    uint96 internal constant MID_MAX = 1.09e18;
    string internal constant BID = "100000:20,200000:40";
    string internal constant ASK = "100000:20, 200000:40 ,500000:80";
    /// @dev The id the demo venue registers `sponsor` under, as it would on every venue that serves it.
    uint64 internal constant SPONSOR_ID = 7;
    uint64 internal constant HOME = 0;

    DeployV2.Deployment internal core;
    SetupDemoVenueHarness internal demo;
    MockTIP20V2 internal eur;
    MockTIP20V2 internal usd;
    MockTIP20V2 internal ousd;

    /// @dev The admin key of the sponsor the demo venue registers under `SPONSOR_ID`.
    address internal sponsor = makeAddr("sponsor");
    address internal maker = makeAddr("maker");
    address internal hotKey = makeAddr("hotKey");
    address internal taker = makeAddr("taker");

    function setUp() public {
        vm.chainId(MODERATO);
        vm.warp(1_800_000_000);
        TIP20FactoryMock.install(vm);
        DeployV2Harness deployment = new DeployV2Harness();
        deployment.setInput(DeployV2.Config({ deployer: makeAddr("deployer"), registryAdmin: address(0) }));
        core = deployment.run();

        eur = new MockTIP20V2("EURC", 6);
        usd = new MockTIP20V2("USDC", 6);
        ousd = new MockTIP20V2("OUSD", 6);
        demo = new SetupDemoVenueHarness();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------------------------------

    function test_createsTheVenueWithItsPairsShapeAndHotWord() external {
        SetupDemoVenue.Config memory config = _config();
        SetupDemoVenue.Setup memory s = _run(config);
        IVenue venue = s.venue;

        assertEq(address(venue), core.factory.predictVenue(maker, config.salt));
        assertTrue(core.factory.isVenue(address(venue)));
        assertEq(venue.owner(), maker);
        assertEq(venue.settler(), address(core.settler));
        assertTrue(venue.isUpdater(hotKey));
        assertEq(venue.pairCount(), 2);
        _assertPair(venue.pair(0), address(eur), address(usd), UNIT, IVenue.AccessMode.Listed);
        _assertPair(venue.pair(1), address(ousd), address(usd), 2 * UNIT, IVenue.AccessMode.Open);
        // The Open pair needed a halt, which the script lifted again.
        assertFalse(venue.halted());
        // The sponsor is registered to its admin, on, and admitted on the Listed pair only. Without `HOME_ALLOWED` no
        // one is listed.
        (address admin, bool enabled, uint32 generation) = venue.sponsor(SPONSOR_ID);
        assertEq(admin, sponsor);
        assertTrue(enabled);
        assertEq(generation, 1);
        assertTrue(venue.pairSponsor(0, SPONSOR_ID));
        assertFalse(venue.pairSponsor(1, SPONSOR_ID));
        assertFalse(venue.isMember(0, HOME, taker));
        // The script installs no hook.
        assertEq(venue.pair(0).hook, address(0));
        assertEq(venue.pair(1).hook, address(0));

        uint256[4] memory expected = _expectedShape();
        uint256[4] memory stored = venue.shape(0, 3);
        for (uint256 i; i < 4; ++i) {
            assertEq(stored[i], expected[i]);
            assertEq(s.shape[i], expected[i]);
        }

        HotWord.Fields memory hot = HotWord.unpack(venue.hotWord(0));
        assertEq(venue.hotWord(0), s.hotWord);
        assertEq(hot.mid, MID);
        assertEq(hot.bidWiden, 4);
        assertEq(hot.askWiden, 6);
        assertEq(hot.widthScale, 1000);
        assertEq(hot.depthScale, 500);
        assertEq(hot.shapeId, 3);
        assertEq(hot.validUntil, block.timestamp + 600);
        assertEq(hot.seq, 2);
        assertEq(hot.flags, 0);
        // Only the quoted pair is posted.
        assertEq(venue.hotWord(1), HotWord.INITIAL);
    }

    function test_demoVenueTradesThroughTheDeployedCoreOnceSponsorListsTaker() external {
        IVenue venue = _run(_config()).venue;
        eur.mint(address(venue), 1_000_000e6);
        usd.mint(address(venue), 1_000_000e6);

        // The sponsor lists its own user; the maker never does.
        vm.prank(sponsor);
        venue.setMembers(0, SPONSOR_ID, _one(taker), true);

        assertEq(uint8(venue.pair(0).access), uint8(IVenue.AccessMode.Listed));
        assertTrue(venue.takerAllowed(0, taker, SPONSOR_ID));
        assertFalse(venue.takerAllowed(0, taker, HOME), "not on the home list");

        uint128 amountIn = 1000e6;
        (, uint128 quoted) = venue.quote(0, address(usd), address(eur), amountIn, true);
        assertGt(quoted, 0);
        usd.mint(taker, amountIn);
        SwapParams memory fills =
            SwapParams({ venue: address(venue), pairIndex: 0, amount: amountIn, sponsorId: SPONSOR_ID });
        vm.startPrank(taker);
        usd.approve(address(core.settler), amountIn);
        uint256 out = core.settler
            .swapExactIn(
                fills.venue,
                fills.pairIndex,
                address(usd),
                address(eur),
                fills.amount,
                quoted,
                fills.sponsorId,
                uint40(block.timestamp),
                "demo"
            );
        vm.stopPrank();
        assertEq(out, quoted);
        assertEq(eur.balanceOf(taker), quoted);

        // A taker the sponsor hasn't listed can't trade the pair.
        address stranger = makeAddr("stranger");
        usd.mint(stranger, amountIn);
        vm.startPrank(stranger);
        usd.approve(address(core.settler), amountIn);
        vm.expectRevert(abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, stranger));
        core.settler
            .swapExactIn(
                fills.venue,
                fills.pairIndex,
                address(usd),
                address(eur),
                fills.amount,
                0,
                fills.sponsorId,
                uint40(block.timestamp),
                "demo"
            );
        vm.stopPrank();
    }

    /// @dev `HOME_ALLOWED` goes on the home list of every `listed` pair, under which a taker trades as sponsor 0.
    function test_seedsTheHomeList() external {
        SetupDemoVenue.Config memory config = _config();
        config.homeAllowed = new address[](2);
        (config.homeAllowed[0], config.homeAllowed[1]) = (taker, makeAddr("second"));
        IVenue venue = _run(config).venue;
        assertTrue(venue.isMember(0, HOME, taker));
        assertFalse(venue.isMember(1, HOME, taker), "only listed pairs");
        assertTrue(venue.takerAllowed(0, taker, HOME));
        assertFalse(venue.takerAllowed(0, makeAddr("third"), HOME));
        assertFalse(venue.takerAllowed(0, taker, SPONSOR_ID), "the sponsor hasn't listed it");
    }

    /// @dev A full `HOME_ALLOWED` (`MAX_BATCH`) goes out as two `setMembers` calls of 50 accounts per `listed` pair,
    /// each well under Tempo's 30M transaction cap with Forge's 130% gas limit, where one call of 100 would top it.
    function test_seedsAFullHomeListInChunksOfFifty() external {
        SetupDemoVenue.Config memory config = _config();
        config.homeAllowed = new address[](100);
        address[] memory first = new address[](50);
        address[] memory second = new address[](50);
        for (uint256 i; i < 100; ++i) {
            address account = makeAddr(string.concat("home", vm.toString(i)));
            config.homeAllowed[i] = account;
            if (i < 50) first[i] = account;
            else second[i - 50] = account;
        }
        address predicted = core.factory.predictVenue(maker, config.salt);
        vm.expectCall(predicted, abi.encodeWithSelector(IVenue.setMembers.selector), 2);
        vm.expectCall(predicted, abi.encodeCall(IVenue.setMembers, (0, HOME, first, true)), 1);
        vm.expectCall(predicted, abi.encodeCall(IVenue.setMembers, (0, HOME, second, true)), 1);
        IVenue venue = _run(config).venue;
        for (uint256 i; i < 100; ++i) {
            assertTrue(venue.isMember(0, HOME, config.homeAllowed[i]));
        }
    }

    /// @dev No `HOME_ALLOWED`, no `setMembers` call: a sponsor lists its own users.
    function test_sendsNoSetMembersWithoutHomeAccounts() external {
        SetupDemoVenue.Config memory config = _config();
        vm.expectCall(
            core.factory.predictVenue(maker, config.salt), abi.encodeWithSelector(IVenue.setMembers.selector), 0
        );
        _run(config);
    }

    /// @dev Each pair opens last, after its band, the approvals and the first word, and the halt the Open
    /// pair needs brackets only the access calls.
    function test_opensEachPairLast() external {
        vm.recordLogs();
        IVenue venue = _run(_config()).venue;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool opened;
        bool halted;
        uint256 accessCalls;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(venue)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IVenue.PairAccessUpdated.selector) {
                // `addPair` emits only `PairAdded`, so every mode change is one of the script's access calls, which
                // follow everything else.
                opened = true;
                ++accessCalls;
                assertTrue(
                    halted || uint256(logs[i].topics[3]) != uint256(IVenue.AccessMode.Open), "Open needs the halt"
                );
            } else if (topic == IVenue.HaltedSet.selector) {
                halted = abi.decode(logs[i].data, (bool));
            } else if (
                topic == IVenue.Posted.selector || topic == IVenue.ShapeSet.selector
                    || topic == IVenue.SponsorAdded.selector || topic == IVenue.PairSponsorSet.selector
                    || topic == IVenue.UpdaterSet.selector
            ) {
                assertFalse(opened, "configuration lands before any pair opens");
            }
        }
        assertEq(accessCalls, 2);
        assertFalse(halted);
    }

    /// @dev Each band goes on right after its pair, before `setUpdater`, so the hot key never exists while a banded
    /// pair is unbanded; the venue then refuses the hot key's out-of-band posts.
    function test_bandsEachPairBeforeTheUpdaterExists() external {
        SetupDemoVenue.Config memory config = _config();
        (config.pairs[0].minMid, config.pairs[0].maxMid) = (MID_MIN, MID_MAX);
        (config.pairs[1].minMid, config.pairs[1].maxMid) = (0.99e18, 1.01e18);
        vm.recordLogs();
        IVenue venue = _run(config).venue;

        (uint96 minMid, uint96 maxMid) = venue.midBand(0);
        assertEq(minMid, MID_MIN);
        assertEq(maxMid, MID_MAX);
        (minMid, maxMid) = venue.midBand(1);
        assertEq(minMid, 0.99e18);
        assertEq(maxMid, 1.01e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 bands;
        bool updaterSet;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(venue)) continue;
            if (logs[i].topics[0] == IVenue.MidBandSet.selector) {
                assertFalse(updaterSet, "every band is set before the updater");
                ++bands;
            } else if (logs[i].topics[0] == IVenue.UpdaterSet.selector) {
                updaterSet = true;
            }
        }
        assertEq(bands, 2);
        assertTrue(updaterSet);

        HotWord.Fields memory f = HotWord.unpack(venue.hotWord(0));
        f.mid = MID_MAX + 1;
        f.seq += 1;
        vm.prank(hotKey);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MidOutOfBand.selector, uint16(0), MID_MAX + 1));
        venue.post(abi.encodePacked(uint16(0), HotWord.pack(f)));
    }

    /// @dev Without band inputs no pair gets a band, as before.
    function test_leavesPairsUnbandedByDefault() external {
        IVenue venue = _run(_config()).venue;
        for (uint16 i; i < 2; ++i) {
            (uint96 minMid, uint96 maxMid) = venue.midBand(i);
            assertEq(minMid, 0);
            assertEq(maxMid, 0);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Compact shape parsing
    // ---------------------------------------------------------------------------------------------------------------

    function test_parseSideMatchesShapeWordEncoding() external view {
        uint256[4] memory expected = _expectedShape();
        (uint256 w0, uint256 w1) = demo.parseSide(BID, "SHAPE_BID");
        assertEq(w0, expected[0]);
        assertEq(w1, expected[1]);
        (w0, w1) = demo.parseSide(ASK, "SHAPE_ASK");
        assertEq(w0, expected[2]);
        assertEq(w1, expected[3]);
        (w0, w1) = demo.parseSide("", "SHAPE_ASK");
        assertEq(w0, 0);
        assertEq(w1, 0);

        // Ten levels spill into the second word.
        (w0, w1) = demo.parseSide("1:1,2:2,3:3,4:4,5:5,6:6,7:7,8:8,9:9,10:10", "SHAPE_BID");
        assertTrue(ShapeWord.continues(w0));
        (uint256 size, uint256 spread) = ShapeWord.level(w0, w1, 9);
        assertEq(size, 10);
        assertEq(spread, 10);
    }

    function test_parseSideRejectsMalformedLevels() external {
        _rejectSide("100", "level is not size:spread");
        _rejectSide("100:1:2", "level is not size:spread");
        _rejectSide("0:10", "size must be 1..2^32-1");
        _rejectSide("4294967296:10", "size must be 1..2^32-1");
        _rejectSide("100:65536", "spread must be 0..65535");
        _rejectSide("1:1,1:1,1:1,1:1,1:1,1:1,1:1,1:1,1:1,1:1,1:1", "more than 10 levels");
        _rejectSide("100:20,100:10", "spreads must not decrease");
        vm.expectRevert();
        demo.parseSide("abc:10", "SHAPE_BID");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fail-closed inputs
    // ---------------------------------------------------------------------------------------------------------------

    function test_rejectsAnyChainButModerato() external {
        demo.setInput(_config());
        vm.chainId(4217);
        vm.expectRevert(abi.encodeWithSelector(SetupDemoVenue.UnexpectedChain.selector, uint256(4217)));
        demo.run();
    }

    function test_rejectsAnExistingVenue() external {
        SetupDemoVenue.Config memory config = _config();
        address venue = address(_run(config).venue);
        vm.expectRevert(abi.encodeWithSelector(SetupDemoVenue.VenueExists.selector, venue));
        demo.run();

        config.salt = "second";
        assertTrue(address(_run(config).venue) != venue);
    }

    function test_rejectsInvalidPairs() external {
        SetupDemoVenue.Config memory config = _config();
        config.pairs = new SetupDemoVenue.PairInput[](0);
        _reject(config, "PAIR_BASES");

        config = _config();
        config.pairs[1].base = makeAddr("noCode");
        _reject(config, "PAIR tokens");
        config.pairs[1].base = address(usd);
        _reject(config, "PAIR tokens");
        config.pairs[1].base = address(0);
        _reject(config, "PAIR tokens");

        config = _config();
        config.pairs[1].base = address(new MockTIP20V2("WETH", 18));
        _reject(config, "PAIR decimals");

        config = _config();
        config.pairs[1].sizeUnit = 0;
        _reject(config, "PAIR_SIZE_UNITS");

        // A closed pair is left as `addPair` made it.
        config = _config();
        config.pairs[1].access = IVenue.AccessMode.Closed;
        assertEq(uint8(_run(config).venue.pair(1).access), uint8(IVenue.AccessMode.Closed));
    }

    function test_parseAccessIsStrict() external view {
        assertEq(uint8(demo.parseAccess("closed")), uint8(IVenue.AccessMode.Closed));
        assertEq(uint8(demo.parseAccess(" listed ")), uint8(IVenue.AccessMode.Listed));
        assertEq(uint8(demo.parseAccess("open")), uint8(IVenue.AccessMode.Open));
    }

    function test_parseAccessRejectsAnythingElse() external {
        string[4] memory bad = ["", "Open", "1", "whitelist"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    SetupDemoVenue.InvalidConfig.selector, "PAIR_ACCESS must be closed, listed or open"
                )
            );
            demo.parseAccess(bad[i]);
        }
    }

    /// @dev `setMembers`'s and `addSponsor`'s rules, checked before anything is sent.
    function test_rejectsInvalidAccessInputs() external {
        SetupDemoVenue.Config memory config = _config();
        config.homeAllowed = new address[](1);
        config.homeAllowed[0] = address(0);
        _reject(config, "HOME_ALLOWED");
        config.homeAllowed[0] = core.factory.predictVenue(maker, config.salt);
        _reject(config, "HOME_ALLOWED");
        config.homeAllowed = new address[](101);
        _reject(config, "HOME_ALLOWED");

        config = _config();
        config.sponsorIds[0] = HOME;
        _reject(config, "SPONSOR_IDS has 0, the home list");
        config = _config();
        config.sponsorAdmins[0] = address(0);
        _reject(config, "SPONSOR_ADMINS");
        config.sponsorAdmins[0] = core.factory.predictVenue(maker, config.salt);
        _reject(config, "SPONSOR_ADMINS");
        // A TIP-1022 virtual address never sends a call, so it could never list the sponsor's users.
        config.sponsorAdmins[0] = VirtualAddress.make(0x12345678, 1);
        _reject(config, "SPONSOR_ADMINS");
    }

    function test_rejectsVirtualHomeAllowedBeforeCreatingVenue() external {
        SetupDemoVenue.Config memory config = _config();
        config.homeAllowed = _one(VirtualAddress.make(0x12345678, 1));
        _reject(config, "HOME_ALLOWED");
        assertEq(core.factory.predictVenue(maker, config.salt).code.length, 0);
    }

    function test_rejectsVirtualUpdaterBeforeCreatingVenue() external {
        SetupDemoVenue.Config memory config = _config();
        config.updater = VirtualAddress.make(0x87654321, 2);
        _reject(config, "UPDATER");
        assertEq(core.factory.predictVenue(maker, config.salt).code.length, 0);
    }

    function test_allowsNoUpdater() external {
        SetupDemoVenue.Config memory config = _config();
        config.updater = address(0);
        IVenue venue = _run(config).venue;
        assertFalse(venue.isUpdater(address(0)));
        assertFalse(venue.isUpdater(hotKey));
    }

    /// @dev Each sponsor is registered under its own id to the admin at the same index, and admitted on every
    /// `listed` pair, with nothing on its lists.
    function test_registersEachSponsorWithItsAdmin() external {
        address partner = makeAddr("partner");
        SetupDemoVenue.Config memory config = _config();
        config.sponsorIds = new uint64[](2);
        (config.sponsorIds[0], config.sponsorIds[1]) = (SPONSOR_ID + 1, SPONSOR_ID);
        config.sponsorAdmins = new address[](2);
        (config.sponsorAdmins[0], config.sponsorAdmins[1]) = (partner, sponsor);
        IVenue venue = _run(config).venue;

        (address admin,,) = venue.sponsor(SPONSOR_ID + 1);
        assertEq(admin, partner);
        (admin,,) = venue.sponsor(SPONSOR_ID);
        assertEq(admin, sponsor);
        assertTrue(venue.pairSponsor(0, SPONSOR_ID + 1));
        assertTrue(venue.pairSponsor(0, SPONSOR_ID));
        assertFalse(venue.pairSponsor(1, SPONSOR_ID + 1), "the Open pair admits no sponsor");
        assertFalse(venue.takerAllowed(0, taker, SPONSOR_ID), "registered, admitted, but no one listed");
    }

    /// @dev `SPONSOR_ADMINS` has exactly one entry per id, and no id repeats.
    function test_rejectsInvalidSponsorLists() external {
        string memory perId = "SPONSOR_ADMINS needs one entry per SPONSOR_IDS id";
        SetupDemoVenue.Config memory config = _config();
        config.sponsorAdmins = new address[](0);
        _reject(config, perId);
        config.sponsorAdmins = new address[](2);
        (config.sponsorAdmins[0], config.sponsorAdmins[1]) = (sponsor, sponsor);
        _reject(config, perId);
        config.sponsorIds = new uint64[](0);
        config.sponsorAdmins = new address[](1);
        config.sponsorAdmins[0] = sponsor;
        _reject(config, perId);

        config.sponsorIds = new uint64[](2);
        (config.sponsorIds[0], config.sponsorIds[1]) = (SPONSOR_ID, SPONSOR_ID);
        config.sponsorAdmins = new address[](2);
        (config.sponsorAdmins[0], config.sponsorAdmins[1]) = (sponsor, makeAddr("partner"));
        _reject(config, "SPONSOR_IDS has a duplicate");
    }

    /// @dev A band follows `setMidBand`'s rule, and the first hot word, which the owner posts unchecked, must respect
    /// the quoted pair's band.
    function test_rejectsInvalidMidBands() external {
        uint96[2][3] memory invalid = [[uint96(2), uint96(1)], [uint96(0), uint96(1)], [uint96(1), uint96(0)]];
        for (uint256 i; i < invalid.length; ++i) {
            SetupDemoVenue.Config memory config = _config();
            (config.pairs[1].minMid, config.pairs[1].maxMid) = (invalid[i][0], invalid[i][1]);
            _reject(config, "PAIR_MID_MINS and PAIR_MID_MAXS");
        }

        SetupDemoVenue.Config memory c = _config();
        (c.pairs[0].minMid, c.pairs[0].maxMid) = (MID + 1, MID_MAX);
        _reject(c, "MID is outside QUOTED_PAIR's mid band");
        (c.pairs[0].minMid, c.pairs[0].maxMid) = (MID_MIN, MID - 1);
        _reject(c, "MID is outside QUOTED_PAIR's mid band");

        // A band of exactly MID, and a one-point band on the other pair, are fine.
        (c.pairs[0].minMid, c.pairs[0].maxMid) = (MID, MID);
        (c.pairs[1].minMid, c.pairs[1].maxMid) = (1, 1);
        (uint96 minMid, uint96 maxMid) = _run(c).venue.midBand(0);
        assertEq(minMid, MID);
        assertEq(maxMid, MID);
    }

    function test_rejectsInvalidQuoteInputs() external {
        SetupDemoVenue.Config memory config = _config();
        config.quotedPair = 2;
        _reject(config, "QUOTED_PAIR");

        config = _config();
        config.shapeBid = "";
        config.shapeAsk = "";
        _reject(config, "SHAPE_BID and SHAPE_ASK are both empty");

        config = _config();
        config.shapeAsk = "100:20,100:10";
        demo.setInput(config);
        vm.expectRevert(
            abi.encodeWithSelector(SetupDemoVenue.InvalidShapeSide.selector, "SHAPE_ASK", "spreads must not decrease")
        );
        demo.run();

        config = _config();
        config.mid = 0;
        _reject(config, "MID");

        config = _config();
        config.validFor = 0;
        _reject(config, "VALID_FOR");

        // One-sided shapes are fine.
        config = _config();
        config.shapeBid = "";
        SetupDemoVenue.Setup memory s = _run(config);
        assertEq(s.venue.shape(0, 3)[0], 0);
        assertEq(s.venue.shape(0, 3)[2], _expectedShape()[2]);
    }

    function test_rejectsInvalidFactoryAndOwnerInputs() external {
        SetupDemoVenue.Config memory config = _config();
        config.owner = address(0);
        _reject(config, "OWNER");

        config = _config();
        config.factory = IVenueFactory(makeAddr("noFactory"));
        _reject(config, "VENUE_FACTORY");
    }

    /// @dev The only test that reads the process environment; no other test touches these names.
    function test_readsTheEnvironment() external {
        vm.setEnv("VENUE_FACTORY", vm.toString(address(core.factory)));
        vm.setEnv("OWNER", vm.toString(maker));
        vm.setEnv("VENUE_SALT", vm.toString(bytes32(uint256(7))));
        vm.setEnv("UPDATER", vm.toString(hotKey));
        vm.setEnv("PAIR_BASES", string.concat(vm.toString(address(eur)), ",", vm.toString(address(ousd))));
        vm.setEnv("PAIR_QUOTES", string.concat(vm.toString(address(usd)), ",", vm.toString(address(usd))));
        vm.setEnv("PAIR_SIZE_UNITS", "1000000,2000000");
        vm.setEnv("PAIR_ACCESS", "listed, open");
        vm.setEnv("SPONSOR_IDS", vm.toString(uint256(SPONSOR_ID)));
        vm.setEnv("SPONSOR_ADMINS", vm.toString(sponsor));
        vm.setEnv("HOME_ALLOWED", string.concat(vm.toString(taker), ",", vm.toString(hotKey)));
        vm.setEnv("QUOTED_PAIR", "1");
        vm.setEnv("SHAPE_ID", "3");
        vm.setEnv("SHAPE_BID", BID);
        vm.setEnv("SHAPE_ASK", "");
        vm.setEnv("MID", "1.085e18");

        SetupDemoVenue.Config memory c = demo.readEnvConfig();
        assertEq(address(c.factory), address(core.factory));
        assertEq(c.owner, maker);
        assertEq(c.salt, bytes32(uint256(7)));
        assertEq(c.updater, hotKey);
        assertEq(c.pairs.length, 2);
        _assertInput(c.pairs[0], address(eur), address(usd), UNIT, IVenue.AccessMode.Listed);
        _assertInput(c.pairs[1], address(ousd), address(usd), 2 * UNIT, IVenue.AccessMode.Open);
        assertEq(c.sponsorIds.length, 1);
        assertEq(c.sponsorIds[0], SPONSOR_ID);
        assertEq(c.sponsorAdmins.length, 1);
        assertEq(c.sponsorAdmins[0], sponsor);
        assertEq(c.homeAllowed.length, 2);
        assertEq(c.homeAllowed[1], hotKey);
        assertEq(c.quotedPair, 1);
        assertEq(c.shapeId, 3);
        assertEq(c.shapeBid, BID);
        assertEq(c.shapeAsk, "");
        assertEq(c.mid, MID);
        // Truly omitted bands remain optional.
        if (!vm.envExists("PAIR_MID_MINS") && !vm.envExists("PAIR_MID_MAXS")) {
            assertEq(c.pairs[0].minMid, 0);
            assertEq(c.pairs[0].maxMid, 0);
            assertEq(c.pairs[1].minMid, 0);
            assertEq(c.pairs[1].maxMid, 0);
        }
        // Optional inputs this test leaves unset take their documented defaults.
        if (!vm.envExists("WIDTH_SCALE")) assertEq(c.widthScale, 1000);
        if (!vm.envExists("DEPTH_SCALE")) assertEq(c.depthScale, 1000);
        if (!vm.envExists("VALID_FOR")) assertEq(c.validFor, 3600);
        if (!vm.envExists("BID_WIDEN")) assertEq(c.bidWiden, 0);

        vm.setEnv("PAIR_SIZE_UNITS", "1000000");
        vm.expectRevert(
            abi.encodeWithSelector(SetupDemoVenue.InvalidConfig.selector, "PAIR_* lists must have equal lengths")
        );
        demo.readEnvConfig();
        vm.setEnv("PAIR_SIZE_UNITS", "1000000,2000000");

        vm.setEnv("MID", vm.toString(uint256(type(uint96).max) + 1));
        vm.expectRevert(abi.encodeWithSelector(SetupDemoVenue.InvalidConfig.selector, "MID"));
        demo.readEnvConfig();
        vm.setEnv("MID", "1.085e18");

        // Exercise the actual entry point: malformed bands must stop before creating a venue with an updater.
        SetupDemoVenue envDemo = new SetupDemoVenue();
        vm.setEnv("PAIR_MID_MINS", "not-a-price,0");
        vm.setEnv("PAIR_MID_MAXS", "also-not-a-price,0");
        vm.expectRevert();
        envDemo.run();
        assertEq(core.factory.predictVenue(maker, bytes32(uint256(7))).code.length, 0);

        // Keep every environment regression in this test: Foundry tests share the process environment.
        // Malformed nonempty bands must never become omitted bands, even when both lists are malformed.
        _rejectEnvMidBands("not-a-price,0", "also-not-a-price,0");
        _rejectEnvMidBands("1.08e18,0,", "1.09e18,0,");
        _rejectEnvMidBands("1.08e18,,0", "1.09e18,,0");
        _rejectEnvMidBands("not-a-price,0", "1.09e18,0");
        _rejectEnvMidBands("1.08e18,0", "not-a-price,0");
        _rejectEnvMidBands("not-a-price,0", "");
        _rejectEnvMidBands("", "not-a-price,0");
        _rejectEnvMidBands("1.08e18,0", "");
        _rejectEnvMidBands("", "1.09e18,0");

        // Explicitly empty, like omitted, keeps the existing optional-band API.
        vm.setEnv("PAIR_MID_MINS", "");
        vm.setEnv("PAIR_MID_MAXS", "");
        SetupDemoVenue.Config memory unbanded = demo.readEnvConfig();
        assertEq(unbanded.pairs[0].minMid, 0);
        assertEq(unbanded.pairs[0].maxMid, 0);
        assertEq(unbanded.pairs[1].minMid, 0);
        assertEq(unbanded.pairs[1].maxMid, 0);
        assertEq(unbanded.updater, hotKey);

        // Each nonempty band list needs one entry per pair.
        vm.setEnv("PAIR_MID_MINS", "1.08e18,0");
        vm.setEnv("PAIR_MID_MAXS", "1.09e18,0");
        c = demo.readEnvConfig();
        assertEq(c.pairs[0].minMid, 1.08e18);
        assertEq(c.pairs[0].maxMid, 1.09e18);
        assertEq(c.pairs[1].minMid, 0);
        assertEq(c.pairs[1].maxMid, 0);

        vm.setEnv("PAIR_MID_MAXS", "1.09e18");
        vm.expectRevert(
            abi.encodeWithSelector(
                SetupDemoVenue.InvalidConfig.selector, "PAIR_MID_* lists must be unset or have one entry per pair"
            )
        );
        demo.readEnvConfig();

        vm.setEnv("PAIR_MID_MAXS", string.concat(vm.toString(uint256(type(uint96).max) + 1), ",0"));
        vm.expectRevert(abi.encodeWithSelector(SetupDemoVenue.InvalidConfig.selector, "PAIR_MID_MAXS"));
        demo.readEnvConfig();
        vm.setEnv("PAIR_MID_MAXS", "1.09e18,0");
        _checkScalarEnvironment();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Two pairs: EURC/USDC `Listed` (quoted, shape 3) with the sponsor (`SPONSOR_ID`) registered and admitted, and
    /// OUSD/USDC `Open` to everyone.
    function _config() internal view returns (SetupDemoVenue.Config memory c) {
        c.factory = core.factory;
        c.owner = maker;
        c.salt = "demo";
        c.updater = hotKey;
        c.pairs = new SetupDemoVenue.PairInput[](2);
        c.pairs[0] = SetupDemoVenue.PairInput({
            base: address(eur),
            quote: address(usd),
            sizeUnit: UNIT,
            access: IVenue.AccessMode.Listed,
            minMid: 0,
            maxMid: 0
        });
        c.pairs[1] = SetupDemoVenue.PairInput({
            base: address(ousd),
            quote: address(usd),
            sizeUnit: 2 * UNIT,
            access: IVenue.AccessMode.Open,
            minMid: 0,
            maxMid: 0
        });
        c.sponsorIds = new uint64[](1);
        c.sponsorIds[0] = SPONSOR_ID;
        c.sponsorAdmins = new address[](1);
        c.sponsorAdmins[0] = sponsor;
        c.quotedPair = 0;
        c.shapeId = 3;
        c.shapeBid = BID;
        c.shapeAsk = ASK;
        c.mid = MID;
        c.bidWiden = 4;
        c.askWiden = 6;
        c.widthScale = 1000;
        c.depthScale = 500;
        c.validFor = 600;
    }

    function _expectedShape() internal pure returns (uint256[4] memory words) {
        uint32[] memory bidSizes = new uint32[](2);
        uint16[] memory bidSpreads = new uint16[](2);
        (bidSizes[0], bidSizes[1]) = (100_000, 200_000);
        (bidSpreads[0], bidSpreads[1]) = (20, 40);
        (words[0], words[1]) = ShapeWord.packSide(bidSizes, bidSpreads);
        uint32[] memory askSizes = new uint32[](3);
        uint16[] memory askSpreads = new uint16[](3);
        (askSizes[0], askSizes[1], askSizes[2]) = (100_000, 200_000, 500_000);
        (askSpreads[0], askSpreads[1], askSpreads[2]) = (20, 40, 80);
        (words[2], words[3]) = ShapeWord.packSide(askSizes, askSpreads);
    }

    function _run(SetupDemoVenue.Config memory config) internal returns (SetupDemoVenue.Setup memory) {
        demo.setInput(config);
        return demo.run();
    }

    function _reject(SetupDemoVenue.Config memory config, string memory reason) internal {
        demo.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(SetupDemoVenue.InvalidConfig.selector, reason));
        demo.run();
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _checkScalarEnvironment() internal {
        string[7] memory fields =
            ["QUOTED_PAIR", "SHAPE_ID", "BID_WIDEN", "ASK_WIDEN", "WIDTH_SCALE", "DEPTH_SCALE", "VALID_FOR"];
        string[3] memory malformed =
            ["not-a-number", "-1", "115792089237316195423570985008687907853269984665640564039457584007913129639936"];
        for (uint256 i = 0; i < fields.length; ++i) {
            string memory previous = vm.envOr(fields[i], string(""));
            for (uint256 j = 0; j < malformed.length; ++j) {
                vm.setEnv(fields[i], malformed[j]);
                vm.expectRevert();
                demo.readEnvConfig();
            }
            vm.setEnv(fields[i], previous);
        }
        vm.setEnv("VENUE_SALT", "not-a-salt");
        vm.expectRevert();
        demo.readEnvConfig();

        // The real entry point also refuses malformed scalars before creating a venue.
        SetupDemoVenue envDemo = new SetupDemoVenue();
        vm.setEnv("VENUE_SALT", vm.toString(bytes32(uint256(7))));
        vm.setEnv("VALID_FOR", "1h");
        vm.expectRevert();
        envDemo.run();
        assertEq(core.factory.predictVenue(maker, bytes32(uint256(7))).code.length, 0);

        // Explicitly empty scalar inputs retain their documented defaults.
        for (uint256 i = 0; i < fields.length; ++i) {
            vm.setEnv(fields[i], "");
        }
        vm.setEnv("VENUE_SALT", "");
        SetupDemoVenue.Config memory c = demo.readEnvConfig();
        assertEq(c.salt, bytes32(0));
        assertEq(c.quotedPair, 0);
        assertEq(c.shapeId, 0);
        assertEq(c.bidWiden, 0);
        assertEq(c.askWiden, 0);
        assertEq(c.widthScale, 1000);
        assertEq(c.depthScale, 1000);
        assertEq(c.validFor, 3600);

        // Valid explicit scalars are preserved, not replaced by defaults.
        vm.setEnv("VENUE_SALT", vm.toString(bytes32(uint256(9))));
        vm.setEnv("QUOTED_PAIR", "1");
        vm.setEnv("SHAPE_ID", "4");
        vm.setEnv("BID_WIDEN", "12");
        vm.setEnv("ASK_WIDEN", "13");
        vm.setEnv("WIDTH_SCALE", "900");
        vm.setEnv("DEPTH_SCALE", "1100");
        vm.setEnv("VALID_FOR", "7200");
        c = demo.readEnvConfig();
        assertEq(c.salt, bytes32(uint256(9)));
        assertEq(c.quotedPair, 1);
        assertEq(c.shapeId, 4);
        assertEq(c.bidWiden, 12);
        assertEq(c.askWiden, 13);
        assertEq(c.widthScale, 900);
        assertEq(c.depthScale, 1100);
        assertEq(c.validFor, 7200);
    }

    function _rejectEnvMidBands(string memory mins, string memory maxs) internal {
        vm.setEnv("PAIR_MID_MINS", mins);
        vm.setEnv("PAIR_MID_MAXS", maxs);
        vm.expectRevert();
        demo.readEnvConfig();
    }

    function _rejectSide(string memory spec, string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(SetupDemoVenue.InvalidShapeSide.selector, "SHAPE_BID", reason));
        demo.parseSide(spec, "SHAPE_BID");
    }

    function _assertPair(IVenue.Pair memory p, address base, address quote, uint64 sizeUnit, IVenue.AccessMode access)
        internal
        pure
    {
        assertEq(p.base, base);
        assertEq(p.quote, quote);
        assertEq(p.sizeUnit, sizeUnit);
        assertEq(uint8(p.access), uint8(access));
    }

    function _assertInput(
        SetupDemoVenue.PairInput memory p,
        address base,
        address quote,
        uint64 sizeUnit,
        IVenue.AccessMode access
    ) internal pure {
        assertEq(p.base, base);
        assertEq(p.quote, quote);
        assertEq(p.sizeUnit, sizeUnit);
        assertEq(uint8(p.access), uint8(access));
    }
}
