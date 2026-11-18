// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm, console } from "forge-std/Test.sol";

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { IVenueFactory } from "../../src/v2/interfaces/IVenueFactory.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";
import { Registry } from "../../src/v2/Registry.sol";
import { Settler } from "../../src/v2/Settler.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { MockTIP20V2 } from "../v2/mocks/MockTIP20V2.sol";
import { MockVirtualAddressRegistry } from "../v2/mocks/MockVirtualAddressRegistry.sol";
import { CoreDeploy } from "../v2/utils/CoreDeploy.sol";

/// @dev The gas cheatcode that replaced the deprecated `lastCallGas`. forge-std's `Vm` doesn't declare it yet.
interface IVmFrameGas {
    function lastFrameGas() external view returns (Vm.Gas memory gas);
}

/// @notice Transaction gas of propAMM v2 swaps under each access path, and of the venue's access calls, on Tempo's gas
/// schedule (TIP-1000 storage creation included). Each figure must stay within 2% of
/// the one the v2 guide records either way, so a cheaper path fails too and the table never goes stale; `-vv` logs them
/// to re-measure (for example after a Tempo hardfork):
/// `forge test --network tempo --match-path test/fork/VenueAccessGas.t.sol -vv`.
/// @dev Skipped without `--network tempo`, whose gas schedule the figures are for; the TIP-403 precompile's code is the
/// marker, though the venue never calls it. It is under `test/fork/`, so neither the
/// unit run nor `forge snapshot --check` includes it. Each figure is `lastFrameGas().gasTotalUsed` of one isolated
/// transaction (`isolate = true`), the 21,000 base included; tokens are mocks. A swap is one 100 EUR fill through the
/// Settler, exact input (EUR in) or exact output (EUR out), measured on its second run, with every slot it writes
/// already created. Each fill takes its 100 EUR off the pair's consumed depth and rewrites that slot (created by
/// `addPair`); the ladder's first level holds 100,000 EUR, so every measured fill prices on one level.
contract VenueAccessGasTest is Test {
    uint256 internal constant BPS = 10_000;
    /// @dev 2% either side of the recorded figure.
    uint256 internal constant TOLERANCE_BPS = 200;
    address internal constant TIP403_PRECOMPILE = 0x403c000000000000000000000000000000000000;
    uint64 internal constant HOME = 0;
    uint128 internal constant FILL = 100e6;
    /// @dev Tempo's per-transaction gas cap (TIP-1000).
    uint256 internal constant TX_GAS_CAP = 30_000_000;
    /// @dev The sponsor the tests register, and the id its takers trade under.
    uint64 internal constant SPONSOR = 7;
    /// @dev Historical solc-build allowance: the largest gap over `DeployV2`'s four transactions between Moderato's
    /// estimate and the test (Venue: 19,005,070 minus 17,796,258 on 2026-10-16). Retained as headroom, not a measured
    /// Solar estimate gap; estimate the actual deployment before broadcasting.
    uint256 internal constant MODERATO_ESTIMATE_GAP = 1_208_812;
    /// @dev Figures the v2 guide's gas tables (contracts/src/v2/README.md) record.
    uint256 internal constant CREATE_VENUE_GAS = 1_114_312;
    uint256 internal constant VENUE_DEPLOY_GAS = 12_967_040;
    uint256 internal constant FACTORY_DEPLOY_GAS = 978_110;
    uint256 internal constant IN_HOME_GAS = 106_442;
    uint256 internal constant IN_SPONSOR_GAS = 111_096;
    uint256 internal constant IN_HOME_DENIED_GAS = 108_625;
    uint256 internal constant IN_SPONSOR_DENIED_GAS = 113_279;
    uint256 internal constant IN_OPEN_GAS = 104_108;
    uint256 internal constant OUT_HOME_GAS = 111_848;
    uint256 internal constant OUT_SPONSOR_GAS = 116_502;
    uint256 internal constant OUT_HOME_DENIED_GAS = 114_031;
    uint256 internal constant OUT_SPONSOR_DENIED_GAS = 118_685;
    uint256 internal constant OUT_OPEN_GAS = 109_514;
    /// @dev The `Open` swaps again under a taker priority-fee cap of 0, which the test's transactions meet exactly: they
    /// pay no gas price, since a nonzero one would charge the taker Tempo's fee token, which the test doesn't hold.
    uint256 internal constant IN_OPEN_CAPPED_GAS = 104_171;
    uint256 internal constant OUT_OPEN_CAPPED_GAS = 109_640;
    /// @dev A one-pair `post` from the updater: without a refill bit, refilling both sides, and refilling one side
    /// after fills on both; and `addPair`, which creates four slots.
    uint256 internal constant POST_GAS = 36_385;
    uint256 internal constant POST_REFILL_BOTH_GAS = 43_207;
    uint256 internal constant POST_REFILL_ONE_GAS = 43_238;
    uint256 internal constant ADD_PAIR_GAS = 1_053_561;
    /// @dev `SetupDemoVenue.HOME_ALLOWED_CHUNK`: the accounts it sends per `setMembers`.
    uint256 internal constant HOME_ALLOWED_CHUNK = 50;
    /// @dev Figures behind `HOME_ALLOWED_CHUNK`, which the v2 guide also records: a chunk of new members and a full
    /// `MAX_BATCH` call of new members.
    uint256 internal constant CHUNK_GAS = 12_784_889;
    uint256 internal constant FULL_BATCH_GAS = 25_540_485;

    address internal maker = makeAddr("maker");
    address internal updater = makeAddr("updater");
    /// @dev The admin of sponsor `SPONSOR`.
    address internal partner = makeAddr("partner");
    /// @dev On the venue's home list.
    address internal taker = makeAddr("taker");
    /// @dev Only on sponsor `SPONSOR`'s list.
    address internal member = makeAddr("member");
    address internal denied = makeAddr("denied");
    /// @dev The TIP-1022 forwarding the mock tokens apply on every transfer, as in the other v2 suites. The venue
    /// resolves nothing.
    MockVirtualAddressRegistry internal resolver;
    Settler internal settler;
    VenueFactory internal factory;
    Venue internal venue;
    MockTIP20V2 internal eur;
    MockTIP20V2 internal usd;
    uint16 internal pairId;

    function setUp() external {
        if (TIP403_PRECOMPILE.code.length == 0) {
            vm.skip(true, "needs the TIP-403 precompile: run with --network tempo");
            return;
        }
        vm.warp(1_800_000_000);
        resolver = new MockVirtualAddressRegistry();
        (settler, factory) = CoreDeploy.core();
        eur = new MockTIP20V2("EURC", 6);
        usd = new MockTIP20V2("USDC", 6);
        eur.setResolver(resolver);
        usd.setResolver(resolver);

        venue = Venue(factory.createVenue(maker, "gas"));
        vm.startPrank(maker);
        venue.setUpdater(updater, true);
        pairId = venue.addPair(address(eur), address(usd), 1e6);
        venue.setShape(pairId, 0, _shape());
        venue.post(abi.encodePacked(pairId, _hot()));
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);
        venue.setMembers(pairId, HOME, _one(taker), true);
        venue.addSponsor(SPONSOR, partner);
        venue.setPairSponsor(pairId, SPONSOR, true);
        vm.stopPrank();
        vm.prank(partner);
        venue.setMembers(pairId, SPONSOR, _one(member), true);

        eur.mint(address(venue), 1_000_000e6);
        usd.mint(address(venue), 1_000_000e6);
        address[2] memory takers = [taker, member];
        for (uint256 i; i < takers.length; ++i) {
            // Both balance slots already exist, as they would for a funded account.
            eur.mint(takers[i], 1_000_000e6);
            usd.mint(takers[i], 1_000_000e6);
            vm.startPrank(takers[i]);
            eur.approve(address(settler), type(uint256).max);
            usd.approve(address(settler), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_swapGas() external {
        uint256 home = _swapIn(taker, HOME);
        _check("swapExactIn, Listed, home list, nothing denied", home, IN_HOME_GAS);
        _check("swapExactOut, Listed, home list, nothing denied", _swapOut(taker, HOME), OUT_HOME_GAS);
        uint256 viaSponsor = _swapIn(member, SPONSOR);
        _check("swapExactIn, Listed, sponsor list, nothing denied", viaSponsor, IN_SPONSOR_GAS);
        _check("swapExactOut, Listed, sponsor list, nothing denied", _swapOut(member, SPONSOR), OUT_SPONSOR_GAS);
        console.log("sponsor list over the home list", viaSponsor - home);

        vm.prank(updater);
        venue.setDenied(_one(denied), true);
        _check("swapExactIn, Listed, home list, one account denied", _swapIn(taker, HOME), IN_HOME_DENIED_GAS);
        _check("swapExactOut, Listed, home list, one account denied", _swapOut(taker, HOME), OUT_HOME_DENIED_GAS);
        _check("swapExactIn, Listed, sponsor list, one account denied", _swapIn(member, SPONSOR), IN_SPONSOR_DENIED_GAS);
        _check(
            "swapExactOut, Listed, sponsor list, one account denied", _swapOut(member, SPONSOR), OUT_SPONSOR_DENIED_GAS
        );
        vm.prank(maker);
        venue.setDenied(_one(denied), false);

        vm.startPrank(maker);
        venue.setHalted(true);
        venue.setPairAccess(pairId, IVenue.AccessMode.Open);
        venue.setHalted(false);
        vm.stopPrank();
        uint256 open = _swapIn(taker, HOME);
        _check("swapExactIn, Open, nothing denied", open, IN_OPEN_GAS);
        _check("swapExactOut, Open, nothing denied", _swapOut(taker, HOME), OUT_OPEN_GAS);
        console.log("home list over Open", home - open);

        // The cap shares the settler's slot, which every fill reads first, so it adds no storage read.
        vm.prank(maker);
        venue.setMaxTakerPriorityFee(0);
        uint256 capped = _swapIn(taker, HOME);
        _check("swapExactIn, Open, priority fee at the cap", capped, IN_OPEN_CAPPED_GAS);
        _check("swapExactOut, Open, priority fee at the cap", _swapOut(taker, HOME), OUT_OPEN_CAPPED_GAS);
        console.log("the cap over no cap, exact in", capped - open);
    }

    /// @dev A post without a refill bit never touches the consumption slot; a refill of both sides writes it without
    /// reading it, and a refill of one side reads and rewrites it. Each refill here follows fills on both sides, so the
    /// slot changes.
    function test_postGas() external {
        vm.prank(updater);
        venue.post(abi.encodePacked(pairId, _hotWith(3, 0)));
        _check("post, 1 pair (updater)", _lastGas(), POST_GAS);
        _swapIn(taker, HOME);
        _swapOut(taker, HOME);
        vm.prank(updater);
        venue.post(abi.encodePacked(pairId, _hotWith(4, HotWord.FLAG_REFILL_BIDS | HotWord.FLAG_REFILL_ASKS)));
        _check("post, 1 pair, refill both sides (updater)", _lastGas(), POST_REFILL_BOTH_GAS);
        _swapIn(taker, HOME);
        _swapOut(taker, HOME);
        vm.prank(updater);
        venue.post(abi.encodePacked(pairId, _hotWith(5, HotWord.FLAG_REFILL_BIDS)));
        _check("post, 1 pair, refill one side (updater)", _lastGas(), POST_REFILL_ONE_GAS);
        (uint128 bids, uint128 asks) = venue.consumed(pairId);
        assertEq(bids, 0);
        assertEq(asks, 2 * FILL);
    }

    /// @dev Two config slots, the hot word and the consumption slot: four new slots, about 250,000 gas each.
    function test_addPairGas() external {
        MockTIP20V2 chf = new MockTIP20V2("CHFC", 6);
        vm.prank(maker);
        venue.addPair(address(chf), address(usd), 1e6);
        _check("addPair", _lastGas(), ADD_PAIR_GAS);
    }

    /// @dev The 77-byte clone, its salt included, and its `initialize`, which writes the owner's and the settler's
    /// slots and nothing else: no sponsor and no list, and nothing in the factory.
    function test_createVenueGas() external {
        factory.createVenue(makeAddr("another"), "gas");
        _check("createVenue", _lastGas(), CREATE_VENUE_GAS);
    }

    /// @dev `SetupDemoVenue` sends `HOME_ALLOWED_CHUNK` accounts per `setMembers`. Each new member is a fresh slot, so
    /// a call's gas grows with its accounts, and Forge sends each at 130% of the estimate: a chunk fits Tempo's
    /// transaction cap there, and a full `MAX_BATCH` call of new members doesn't. A sponsor's list costs the same as the
    /// home list per member.
    function test_memberChunksFitTheTransactionCap() external {
        vm.prank(maker);
        venue.setMembers(pairId, HOME, _fresh("chunk0-", HOME_ALLOWED_CHUNK), true);
        uint256 chunk = _lastGas();
        _check("setMembers, a chunk of new members", chunk, CHUNK_GAS);
        assertLe(chunk * 130 / 100, TX_GAS_CAP, "a member chunk tops the transaction cap at Forge's gas limit");

        address[] memory batchAccounts = _fresh("full-", venue.MAX_BATCH());
        vm.prank(partner);
        venue.setMembers(pairId, SPONSOR, batchAccounts, true);
        uint256 batch = _lastGas();
        _check("setMembers, MAX_BATCH new members", batch, FULL_BATCH_GAS);
        assertGt(batch * 130 / 100, TX_GAS_CAP, "a full batch fits the cap at Forge's gas limit");
    }

    /// @dev Each of `DeployV2`'s four transactions, in its order, must fit Tempo's 30M transaction cap (TIP-1000) at
    /// Forge's gas limit, 130% of the node's estimate, or the deploy fails at that step. The largest is the `Venue`
    /// implementation's, which carries all of the venue code; the factory's carries none of it. Each figure here runs
    /// at most `MODERATO_ESTIMATE_GAP` below the Moderato estimate `docs/v2-deployment.md` records, so the cap check
    /// adds it back. The `Venue` and `VenueFactory` figures are pinned within 2% like the others, so a larger `Venue`
    /// fails here and the runbook's estimates get re-measured.
    function test_deployTransactionsFitTheTransactionCap() external {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        Venue implementation = new Venue(predicted);
        uint256 venueGas = _lastGas();
        _check("Venue implementation deployment", venueGas, VENUE_DEPLOY_GAS);
        _fitsTheCap("Venue implementation", venueGas);
        Settler newSettler = new Settler(implementation);
        _fitsTheCap("Settler", _lastGas());
        VenueFactory newFactory = new VenueFactory(implementation, address(newSettler));
        assertEq(address(newFactory), predicted);
        uint256 factoryGas = _lastGas();
        _check("VenueFactory deployment", factoryGas, FACTORY_DEPLOY_GAS);
        _fitsTheCap("VenueFactory", factoryGas);
        new Registry(IVenueFactory(address(newFactory)));
        _fitsTheCap("Registry", _lastGas());
    }

    /// @dev On its own: a slot cleared earlier in the same test makes a later slot creation read as refunded.
    function test_accessCallGas() external {
        vm.prank(maker);
        venue.setMembers(pairId, HOME, _one(makeAddr("new")), true);
        _check("setMembers, home list, 1 new", _lastGas(), 286_881);
        vm.prank(partner);
        venue.setMembers(pairId, SPONSOR, _one(makeAddr("new member")), true);
        _check("setMembers, sponsor list, 1 new", _lastGas(), 289_374);
        vm.prank(updater);
        venue.setDenied(_one(denied), true);
        _check("setDenied, 1 new (updater)", _lastGas(), 291_239);
        address another = makeAddr("another sponsor");
        vm.prank(maker);
        venue.addSponsor(SPONSOR + 1, another);
        _check("addSponsor (new slot)", _lastGas(), 283_581);
        vm.prank(maker);
        venue.setPairSponsor(pairId, SPONSOR + 1, true);
        _check("setPairSponsor, admit (new slot)", _lastGas(), 288_095);
        vm.prank(updater);
        venue.setPairSponsor(pairId, SPONSOR + 1, false);
        _check("setPairSponsor, remove (updater)", _lastGas(), 38_764);
        vm.prank(maker);
        venue.setPairSponsor(pairId, SPONSOR + 1, true);
        _check("setPairSponsor, re-admit (rewrites the kept slot)", _lastGas(), 38_795);
        vm.prank(updater);
        venue.setSponsorEnabled(SPONSOR + 1, false);
        _check("setSponsorEnabled(false) (updater)", _lastGas(), 36_215);
        vm.prank(maker);
        venue.setSponsorEnabled(SPONSOR + 1, true);
        _check("setSponsorEnabled(true)", _lastGas(), 34_032);
        vm.prank(maker);
        venue.resetSponsor(SPONSOR + 1, makeAddr("new key"));
        _check("resetSponsor", _lastGas(), 37_095);
        vm.prank(updater);
        venue.closePair(pairId);
        _check("closePair (updater)", _lastGas(), 35_985);
        vm.prank(maker);
        venue.setPairAccess(pairId, IVenue.AccessMode.Listed);
        _check("setPairAccess(Listed)", _lastGas(), 34_097);
        vm.prank(updater);
        venue.setMaxTakerPriorityFee(1 gwei);
        _check("setMaxTakerPriorityFee (updater)", _lastGas(), 35_510);
        vm.prank(updater);
        venue.enableTakerPriorityFeeCap();
        _check("enableTakerPriorityFeeCap (updater)", _lastGas(), 35_335);
    }

    /// @dev An exact-input swap's second run, so every slot it writes already exists. Each run takes 100 EUR off a
    /// first level that holds 100,000, so every run prices on that level.
    function _swapIn(address who, uint64 sponsorId) internal returns (uint256) {
        for (uint256 i; i < 2; ++i) {
            vm.prank(who);
            settler.swapExactIn(
                address(venue),
                pairId,
                address(eur),
                address(usd),
                FILL,
                0,
                sponsorId,
                uint40(block.timestamp + 30),
                "gas"
            );
        }
        return _lastGas();
    }

    /// @dev The same for exact output: 100 EUR out, USD in.
    function _swapOut(address who, uint64 sponsorId) internal returns (uint256) {
        for (uint256 i; i < 2; ++i) {
            vm.prank(who);
            settler.swapExactOut(
                address(venue),
                pairId,
                address(usd),
                address(eur),
                FILL,
                type(uint256).max,
                sponsorId,
                uint40(block.timestamp + 30),
                "gas"
            );
        }
        return _lastGas();
    }

    function _check(string memory label, uint256 used, uint256 recorded) internal pure {
        console.log(label, used);
        uint256 slack = recorded * TOLERANCE_BPS / BPS;
        assertGe(used, recorded - slack, string.concat(label, ": cheaper than the v2 guide records"));
        assertLe(used, recorded + slack, string.concat(label, ": dearer than the v2 guide records"));
    }

    function _fitsTheCap(string memory label, uint256 used) internal pure {
        console.log(
            string.concat(label, ": Forge's gas limit at the Moderato estimate"),
            (used + MODERATO_ESTIMATE_GAP) * 130 / 100
        );
        assertLe(
            (used + MODERATO_ESTIMATE_GAP) * 130 / 100,
            TX_GAS_CAP,
            string.concat(label, ": Forge's 130% gas limit tops the transaction cap")
        );
    }

    function _lastGas() internal view returns (uint256) {
        return IVmFrameGas(address(vm)).lastFrameGas().gasTotalUsed;
    }

    /// @dev `count` accounts no registry holds yet.
    function _fresh(string memory label, uint256 count) internal returns (address[] memory accounts) {
        accounts = new address[](count);
        for (uint256 i; i < count; ++i) {
            accounts[i] = makeAddr(string.concat(label, vm.toString(i)));
        }
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _shape() internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](3);
        uint16[] memory spreads = new uint16[](3);
        (sizes[0], sizes[1], sizes[2]) = (100_000, 200_000, 300_000);
        (spreads[0], spreads[1], spreads[2]) = (10, 20, 40);
        (words[0], words[1]) = ShapeWord.packSide(sizes, spreads);
        (words[2], words[3]) = (words[0], words[1]);
    }

    function _hot() internal view returns (bytes32) {
        return _hotWith(2, 0);
    }

    function _hotWith(uint32 seq, uint16 flags) internal view returns (bytes32) {
        return HotWord.pack(
            HotWord.Fields({
                mid: 1.085e18,
                bidWiden: 0,
                askWiden: 0,
                widthScale: 1000,
                depthScale: 1000,
                shapeId: 0,
                validUntil: uint40(block.timestamp + 600),
                seq: seq,
                flags: flags
            })
        );
    }
}
