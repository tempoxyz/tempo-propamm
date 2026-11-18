// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { LadderOracle } from "../../utils/LadderOracle.sol";

import { SwapParams } from "../../utils/SwapParams.sol";

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { IVenue } from "../../../../src/v2/interfaces/IVenue.sol";
import { IVenueFactory } from "../../../../src/v2/interfaces/IVenueFactory.sol";
import { HotWord } from "../../../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../../../src/v2/libraries/ShapeWord.sol";
import { Registry } from "../../../../src/v2/Registry.sol";
import { Settler } from "../../../../src/v2/Settler.sol";
import { Venue } from "../../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../../src/v2/VenueFactory.sol";
import { MockAddressRegistry } from "../../../mocks/MockAddressRegistry.sol";
import { MockTIP20V2 } from "../../mocks/MockTIP20V2.sol";
import { CoreDeploy } from "../../utils/CoreDeploy.sol";

/// @dev The gas cheatcode that replaced the deprecated `lastCallGas`. forge-std's `Vm` doesn't declare it yet.
interface IVmFrameGas {
    function lastFrameGas() external view returns (Vm.Gas memory gas);
}

/// @notice The whole v2 stack with real contracts, in the deploy script's order (`CoreDeploy`): the `Venue`
/// implementation against the factory's predicted address, the Settler against the implementation and the factory,
/// then a Registry sidecar. Three makers each run one venue clone with one live EUR/USD pair;
/// venue A is registered for discovery:
///
/// | Venue | Mid    | Both sides                                         |
/// |-------|--------|----------------------------------------------------|
/// | A     | 1.0850 | 100 / 200 / 300 EUR at 1 / 2 / 4 bp                |
/// | B     | 1.0851 | six levels of 150 EUR at 0.5 / 0.8 / 1.2 / 1.6 / 2.5 / 4 bp |
/// | C     | 1.0849 | one level of 500 EUR at 1.5 bp                     |
///
/// Pairs start `Open` (permissionless); the access suites move them to `Listed`, under the venue's home list or a
/// sponsor (`SPONSOR`, administered by `sponsorOps`) that the venue registers and admits on the pair and that lists its
/// own customers there. A swap pays its taker. Every token forwards transfers to TIP-1022
/// virtual addresses through the shared `MockAddressRegistry`, like the TIP-20 precompile; the venues resolve nothing.
abstract contract IntegrationFixture is Test {
    uint64 internal constant UNIT = 1e6;
    uint40 internal constant TTL = 60;
    uint40 internal constant DEADLINE = 30;
    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant INVENTORY = 100_000e6;
    uint256 internal constant FUNDS = 1_000_000e6;
    bytes32 internal constant REF = keccak256("integration-quote");
    /// @dev The `sponsorId` that names a venue's home list.
    uint64 internal constant HOME = 0;
    /// @dev The sponsor every venue registers under the same id when it serves it.
    uint64 internal constant SPONSOR = 7;

    uint96 internal constant MID_A = 1.085e18;
    uint96 internal constant MID_B = 1.0851e18;
    uint96 internal constant MID_C = 1.0849e18;

    struct FillLog {
        address venue;
        uint16 pairIndex;
        address taker;
        bytes32 ref;
        uint64 sponsorId;
        bool baseIn;
        uint128 amountIn;
        uint128 amountOut;
        uint96 makerMid;
        uint32 seq;
    }

    address internal tempoOps = makeAddr("tempoOps");
    address internal makerA = makeAddr("makerA");
    address internal makerB = makeAddr("makerB");
    address internal makerC = makeAddr("makerC");
    address internal updaterA = makeAddr("updaterA");
    address internal updaterB = makeAddr("updaterB");
    address internal updaterC = makeAddr("updaterC");
    address internal taker = makeAddr("taker");
    /// @dev A second funded taker.
    address internal taker2 = makeAddr("taker2");
    address internal stranger = makeAddr("stranger");
    /// @dev The key that lists `SPONSOR`'s customers on every venue that registers it.
    address internal sponsorOps = makeAddr("sponsorOps");

    MockAddressRegistry internal resolver;
    Settler internal settler;
    VenueFactory internal factory;
    Registry internal discovery;
    LadderOracle internal oracle;

    MockTIP20V2 internal eur;
    MockTIP20V2 internal usd;
    MockTIP20V2 internal gbp;

    Venue internal venueA;
    Venue internal venueB;
    Venue internal venueC;
    uint16 internal pairA;
    uint16 internal pairB;
    uint16 internal pairC;

    function setUp() public virtual {
        vm.warp(START);
        resolver = new MockAddressRegistry();
        // One deployment from this contract, as `new LadderOracle()` was, so every later address stays put.
        oracle = new LadderOracle();
        eur = _token("EURC");
        usd = _token("USDC");
        gbp = _token("GBPC");

        _deployCore();

        (venueA, pairA) = _createMaker(makerA, updaterA, "A", _shapeA(), MID_A);
        (venueB, pairB) = _createMaker(makerB, updaterB, "B", _shapeB(), MID_B);
        (venueC, pairC) = _createMaker(makerC, updaterC, "C", _flatShape(500, 15), MID_C);

        vm.startPrank(tempoOps);
        discovery.register(address(venueA));
        vm.stopPrank();

        _fund(taker);
        _fund(taker2);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The deploy-script order (`CoreDeploy`): the `Venue` implementation against the address the factory will
    /// get, the Settler against the implementation, then the factory with the Settler as every venue's default. No
    /// admin and no circular dependency.
    function _deployCore() internal {
        (settler, factory) = CoreDeploy.core();

        discovery = new Registry(IVenueFactory(address(factory)));
    }

    function _token(string memory symbol) internal returns (MockTIP20V2 token) {
        token = new MockTIP20V2(symbol, 6);
        token.setResolver(resolver);
    }

    /// @dev A maker creates its own venue (the factory is permissionless), adds EUR/USD, appoints an updater, defines
    /// shape 0, posts, funds both tokens and opens the pair (`Open`).
    function _createMaker(address maker, address updater, bytes32 salt, uint256[4] memory words, uint96 mid)
        internal
        returns (Venue venue, uint16 pairIndex)
    {
        vm.startPrank(maker);
        venue = Venue(factory.createVenue(maker, salt));
        venue.setUpdater(updater, true);
        pairIndex = venue.addPair(address(eur), address(usd), UNIT);
        vm.stopPrank();
        _setShape(venue, pairIndex, 0, words);
        _post(venue, pairIndex, _fields(mid));
        eur.mint(address(venue), INVENTORY);
        usd.mint(address(venue), INVENTORY);
        _setAccess(venue, pairIndex, IVenue.AccessMode.Open);
    }

    /// @dev Sets the pair's mode as the venue's owner. `Open` needs a halted venue, so this halts around it and
    /// restores the venue's halt state after.
    function _setAccess(Venue venue, uint16 pairIndex, IVenue.AccessMode mode) internal {
        bool wasHalted = venue.halted();
        vm.startPrank(venue.owner());
        if (mode == IVenue.AccessMode.Open && !wasHalted) venue.setHalted(true);
        venue.setPairAccess(pairIndex, mode);
        if (mode == IVenue.AccessMode.Open && !wasHalted) venue.setHalted(false);
        vm.stopPrank();
    }

    /// @dev Moves the pair to `Listed` and lists `accounts` on the pair's home list.
    function _listHome(Venue venue, uint16 pairIndex, address[] memory accounts) internal {
        _setAccess(venue, pairIndex, IVenue.AccessMode.Listed);
        vm.prank(venue.owner());
        venue.setMembers(pairIndex, HOME, accounts, true);
    }

    /// @dev The owner of `venue` registers `SPONSOR` (once) and admits it on the pair.
    function _admitSponsor(Venue venue, uint16 pairIndex) internal {
        (address admin,,) = venue.sponsor(SPONSOR);
        vm.startPrank(venue.owner());
        if (admin == address(0)) venue.addSponsor(SPONSOR, sponsorOps);
        venue.setPairSponsor(pairIndex, SPONSOR, true);
        vm.stopPrank();
    }

    /// @dev `SPONSOR` lists or delists `accounts` on the venue's pair, from its own key.
    function _listSponsor(Venue venue, uint16 pairIndex, address[] memory accounts, bool allowed) internal {
        vm.prank(sponsorOps);
        venue.setMembers(pairIndex, SPONSOR, accounts, allowed);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _fund(address account) internal {
        eur.mint(account, FUNDS);
        usd.mint(account, FUNDS);
        gbp.mint(account, FUNDS);
        vm.startPrank(account);
        eur.approve(address(settler), type(uint256).max);
        usd.approve(address(settler), type(uint256).max);
        gbp.approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Curves
    // ---------------------------------------------------------------------------------------------------------------

    function _shapeA() internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](3);
        uint16[] memory spreads = new uint16[](3);
        (sizes[0], sizes[1], sizes[2]) = (100, 200, 300);
        (spreads[0], spreads[1], spreads[2]) = (10, 20, 40);
        (words[0], words[1]) = ShapeWord.packSide(sizes, spreads);
        (words[2], words[3]) = (words[0], words[1]);
    }

    /// @dev Six levels, so each side spills into its second word.
    function _shapeB() internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](6);
        uint16[] memory spreads = new uint16[](6);
        uint16[6] memory steps = [uint16(5), 8, 12, 16, 25, 40];
        for (uint256 i; i < 6; ++i) {
            sizes[i] = 150;
            spreads[i] = steps[i];
        }
        (words[0], words[1]) = ShapeWord.packSide(sizes, spreads);
        (words[2], words[3]) = (words[0], words[1]);
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

    /// @dev Ten levels a side, so every word of the shape is nonzero; `bump` shifts every size.
    function _fullShape(uint32 bump) internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](10);
        uint16[] memory spreads = new uint16[](10);
        for (uint256 i; i < 10; ++i) {
            sizes[i] = uint32(100 + 10 * i) + bump;
            spreads[i] = uint16(5 * (i + 1));
        }
        (words[0], words[1]) = ShapeWord.packSide(sizes, spreads);
        (words[2], words[3]) = (words[0], words[1]);
    }

    function _fields(uint96 mid) internal view returns (HotWord.Fields memory) {
        return HotWord.Fields({
            mid: mid,
            bidWiden: 0,
            askWiden: 0,
            widthScale: 1000,
            depthScale: 1000,
            shapeId: 0,
            validUntil: uint40(block.timestamp) + TTL,
            seq: 0,
            flags: 0
        });
    }

    /// @dev The packed hot word for `f`, with the pair's next `seq`.
    function _nextHot(Venue venue, uint16 pairIndex, HotWord.Fields memory f) internal view returns (bytes32) {
        f.seq = HotWord.seq(venue.hotWord(pairIndex)) + 1;
        return HotWord.pack(f);
    }

    /// @dev Posts as the venue's owner, which every maker may do alongside its updater key.
    function _post(Venue venue, uint16 pairIndex, HotWord.Fields memory f) internal {
        bytes32 word = _nextHot(venue, pairIndex, f);
        vm.prank(venue.owner());
        venue.post(abi.encodePacked(pairIndex, word));
    }

    function _setShape(Venue venue, uint16 pairIndex, uint8 shapeId, uint256[4] memory words) internal {
        vm.prank(venue.owner());
        venue.setShape(pairIndex, shapeId, words);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Expectations
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The posted ladder from the side's consumed depth, as the next fill walks it.
    function _expect(Venue venue, uint16 pairIndex, bool baseIn, bool exactIn, uint256 amount)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 baseFilled)
    {
        return _expectHot(venue, pairIndex, venue.hotWord(pairIndex), baseIn, exactIn, amount);
    }

    /// @dev The posted ladder with `hot` in place of the pair's live hot word, from the side's consumed depth.
    function _expectHot(Venue venue, uint16 pairIndex, bytes32 hot, bool baseIn, bool exactIn, uint256 amount)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 baseFilled)
    {
        (LadderMath.Curve memory c, uint256 w0, uint256 w1) = _side(venue, pairIndex, hot, baseIn);
        return oracle.fill(c, w0, w1, exactIn, amount, _consumed(venue, pairIndex, baseIn));
    }

    /// @dev The base the side a fill walks has given up: the bids when the taker sells base.
    function _consumed(Venue venue, uint16 pairIndex, bool baseIn) internal view returns (uint256) {
        (uint128 bids, uint128 asks) = venue.consumed(pairIndex);
        return baseIn ? bids : asks;
    }

    /// @dev The curve and side words `fill` would use under `hot`.
    function _side(Venue venue, uint16 pairIndex, bytes32 hot, bool baseIn)
        internal
        view
        returns (LadderMath.Curve memory c, uint256 w0, uint256 w1)
    {
        uint256[4] memory words = venue.shape(pairIndex, HotWord.shapeId(hot));
        w0 = baseIn ? words[0] : words[2];
        w1 = ShapeWord.continues(w0) ? (baseIn ? words[1] : words[3]) : 0;
        c = LadderMath.curve(hot, venue.pair(pairIndex).sizeUnit, baseIn);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------------------------

    function _deadline() internal view returns (uint40) {
        return uint40(block.timestamp) + DEADLINE;
    }

    /// @dev A swap under the venue's home list (`sponsorId` 0), which an `Open` pair ignores.
    function _request(Venue venue, uint16 pairIndex, uint256 amount) internal pure returns (SwapParams memory) {
        return _requestUnder(venue, pairIndex, amount, HOME);
    }

    function _requestUnder(Venue venue, uint16 pairIndex, uint256 amount, uint64 sponsorId)
        internal
        pure
        returns (SwapParams memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        return
            SwapParams({ venue: address(venue), pairIndex: pairIndex, amount: uint128(amount), sponsorId: sponsorId });
    }

    /// @dev `from` swaps for itself: the output goes to `from`.
    function _swapExactIn(address from, address tokenIn, address tokenOut, SwapParams memory fills, uint256 minOut)
        internal
        returns (uint256)
    {
        vm.prank(from);
        return settler.swapExactIn(
            fills.venue, fills.pairIndex, tokenIn, tokenOut, fills.amount, minOut, fills.sponsorId, _deadline(), REF
        );
    }

    function _swapExactOut(address from, address tokenIn, address tokenOut, SwapParams memory fills, uint256 maxIn)
        internal
        returns (uint256)
    {
        vm.prank(from);
        return settler.swapExactOut(
            fills.venue, fills.pairIndex, tokenIn, tokenOut, fills.amount, maxIn, fills.sponsorId, _deadline(), REF
        );
    }

    /// @dev The `Fill` events recorded since `vm.recordLogs()`, in emission order.
    function _fillLogs() internal view returns (FillLog[] memory fills) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == IVenue.Fill.selector) ++count;
        }
        fills = new FillLog[](count);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.topics.length != 4 || log.topics[0] != IVenue.Fill.selector) continue;
            FillLog memory f = fills[n++];
            f.venue = log.emitter;
            f.pairIndex = uint16(uint256(log.topics[1]));
            f.taker = address(uint160(uint256(log.topics[2])));
            f.ref = log.topics[3];
            (f.sponsorId, f.baseIn, f.amountIn, f.amountOut, f.makerMid, f.seq) =
                abi.decode(log.data, (uint64, bool, uint128, uint128, uint96, uint32));
        }
    }

    /// @dev EUR and USD balances of both takers, the three venues and the Settler.
    function _balances() internal view returns (uint256[12] memory b) {
        address[6] memory accounts =
            [taker, taker2, address(venueA), address(venueB), address(venueC), address(settler)];
        for (uint256 i; i < 6; ++i) {
            b[2 * i] = eur.balanceOf(accounts[i]);
            b[2 * i + 1] = usd.balanceOf(accounts[i]);
        }
    }

    function _assertUnchanged(uint256[12] memory before) internal view {
        uint256[12] memory current = _balances();
        for (uint256 i; i < 12; ++i) {
            assertEq(current[i], before[i], "balance moved");
        }
    }

    /// @dev Gas of the last top-level call, which `isolate = true` runs as its own transaction: intrinsic gas
    /// included, refunds not deducted.
    function _lastTxGas() internal view returns (uint256 used, int64 refunded) {
        Vm.Gas memory g = IVmFrameGas(address(vm)).lastFrameGas();
        return (g.gasTotalUsed, g.gasRefunded);
    }
}
