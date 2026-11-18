// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapParams } from "../utils/SwapParams.sol";

import { VmSafe } from "forge-std/Vm.sol";

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { VenueHookFlags } from "../../../src/v2/interfaces/IVenueHook.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { NoopHook } from "./utils/Actors.sol";
import { IntegrationFixture } from "./utils/IntegrationFixture.sol";

/// @notice Deterministic gas benchmarks on the real stack. Each `test_gas_*` makes exactly one measured top-level call;
/// with `isolate = true` that call is its own transaction, so every account and slot it touches starts cold and the
/// figure includes the 21,000 intrinsic gas and calldata, like a real transaction. Refunds are not deducted.
///
/// Standard EVM (Cancun) pricing: Tempo's TIP-1000 storage-creation surcharge is not modelled, and the tokens are the
/// Solidity TIP-20 mock, not the precompile (every mock transfer also reads its test switches and calls the
/// address-registry mock that models TIP-1022 forwarding). Only `addPair` and the access calls create storage slots
/// (`addPair` four, the pair's consumption slot among them): in every swap the taker already holds both tokens,
/// allowances are standing, venues hold both tokens, and the fill rewrites its pair's consumption slot. A swap pays its
/// taker. Pairs are `Open` unless a test says otherwise; the access benchmarks put venue
/// B's pair in `Listed` mode under its home list or under a sponsor's list.
///
/// The ceilings allow at most about 15% over the Solar measurements (rounded up to 500 gas); tighter existing
/// limits stay intact. They catch regressions rather than pin exact numbers. They apply
/// to `forge test` and `forge snapshot`, not to the unoptimized `forge coverage` build or a `--network tempo` run.
contract GasIntegrationTest is IntegrationFixture {
    /// @dev The TIP-403 registry precompile, which only `--network tempo` provides.
    address internal constant TIP403_PRECOMPILE = 0x403c000000000000000000000000000000000000;
    uint256 internal constant CREATE_VENUE_CEILING = 135_000;

    uint16[6] internal quotedPairs;
    uint16 internal hookedPair;

    function setUp() public override {
        super.setUp();

        // A quotes six pairs: EUR/USD plus five more against USD.
        quotedPairs[0] = pairA;
        string[5] memory symbols = ["GBPC", "JPYC", "MXNC", "CHFC", "CADC"];
        for (uint256 i; i < 5; ++i) {
            MockTIP20V2 base = i == 0 ? gbp : _token(symbols[i]);
            vm.prank(makerA);
            uint16 p = venueA.addPair(address(base), address(usd), UNIT);
            _setAccess(venueA, p, IVenue.AccessMode.Open);
            _setShape(venueA, p, 0, _shapeA());
            _post(venueA, p, _fields(MID_A));
            quotedPairs[i + 1] = p;
        }
        // Shape 1 on EUR/USD, fully populated, for the in-place redefinition.
        _setShape(venueA, pairA, 1, _fullShape(0));

        // A second EUR/USD pair on A behind a hook that does nothing.
        NoopHook noop = new NoopHook();
        vm.startPrank(makerA);
        hookedPair = venueA.addPair(address(eur), address(usd), UNIT);
        venueA.setShape(hookedPair, 0, _shapeA());
        venueA.setPairHook(hookedPair, address(noop), VenueHookFlags.ALL);
        vm.stopPrank();
        _setAccess(venueA, hookedPair, IVenue.AccessMode.Open);
        _post(venueA, hookedPair, _fields(MID_A));
    }

    function _measure(string memory label, uint256 ceiling) internal {
        (uint256 used, int64 refunded) = _lastTxGas();
        emit log_named_uint(string.concat("gas: ", label), used);
        emit log_named_int(string.concat("refund: ", label), refunded);
        // The ceilings are for the optimized build under standard EVM pricing. `forge coverage --ir-minimum` compiles
        // with almost no optimization, so there they would only measure the coverage build; under `--network tempo`
        // (where the TIP-403 precompile exists) TIP-1000 prices every new slot at about 250k, and
        // `test/fork/VenueAccessGas.t.sol` holds those figures.
        bool tempo = TIP403_PRECOMPILE.code.length != 0;
        if (!vm.isContext(VmSafe.ForgeContext.Coverage) && !tempo) assertLe(used, ceiling, label);
    }

    function _updaterPostGas(uint16 pairIndex) internal returns (uint256 used) {
        bytes memory packed = abi.encodePacked(pairIndex, _nextHot(venueA, pairIndex, _fields(MID_A + 1e12)));
        vm.prank(updaterA);
        venueA.post(packed);
        (used,) = _lastTxGas();
    }

    function _selfSwapExactIn(address tokenIn, address tokenOut, SwapParams memory fills) internal {
        vm.prank(taker);
        settler.swapExactIn(
            fills.venue, fills.pairIndex, tokenIn, tokenOut, fills.amount, 0, fills.sponsorId, _deadline(), REF
        );
    }

    /// @dev A fill on each side of venue A's EUR/USD pair, so both sides have consumed depth to refill.
    function _consumeBothSides() internal {
        _selfSwapExactIn(address(eur), address(usd), _request(venueA, pairA, 50e6));
        _selfSwapExactIn(address(usd), address(eur), _request(venueA, pairA, 50e6));
    }

    function _refillHot(uint16 flags) internal view returns (bytes32) {
        HotWord.Fields memory f = _fields(MID_A + 1e12);
        f.flags = flags;
        return _nextHot(venueA, pairA, f);
    }

    /// @dev A cold read costs 2,100, so `slack` rules one out. Like the ceilings, it is for the optimized build:
    /// `forge coverage --ir-minimum` reads the slot again.
    function _assertNoExtraRead(string memory label, uint256 capped, uint256 uncapped, uint256 slack) internal {
        emit log_named_uint(string.concat("gas: ", label), capped - uncapped);
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) assertLt(capped, uncapped + slack, label);
    }

    /// @dev One 100 EUR swap on venue A, from the same state either way, with a 1 gwei priority fee and, when
    /// `capped`, a 1 gwei cap.
    function _priorityFeeSwapGas(bool capped, bool exactIn) internal returns (uint256 used) {
        uint256 snapshot = vm.snapshotState();
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
        if (capped) {
            vm.prank(makerA);
            venueA.setMaxTakerPriorityFee(1 gwei);
        }
        SwapParams memory fills = _request(venueA, pairA, 100e6);
        vm.prank(taker);
        if (exactIn) {
            settler.swapExactIn(
                fills.venue, fills.pairIndex, address(eur), address(usd), fills.amount, 0, HOME, _deadline(), REF
            );
        } else {
            settler.swapExactOut(
                fills.venue,
                fills.pairIndex,
                address(usd),
                address(eur),
                fills.amount,
                type(uint256).max,
                HOME,
                _deadline(),
                REF
            );
        }
        (used,) = _lastTxGas();
        if (!capped) vm.revertToState(snapshot);
    }

    /// @dev Venue B's pair in `Listed` mode, the taker on B's home list and on `SPONSOR`'s list there.
    function _listB() internal {
        _listHome(venueB, pairB, _one(taker));
        _admitSponsor(venueB, pairB);
        _listSponsor(venueB, pairB, _one(taker), true);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Maker updates
    // ---------------------------------------------------------------------------------------------------------------

    function test_gas_post_onePair() public {
        bytes memory packed = abi.encodePacked(pairA, _nextHot(venueA, pairA, _fields(MID_A + 1e12)));
        vm.prank(updaterA);
        venueA.post(packed);
        _measure("post, 1 pair", 42_000);
    }

    function test_gas_post_sixPairs() public {
        bytes memory packed;
        for (uint256 i; i < 6; ++i) {
            uint16 p = quotedPairs[i];
            packed = bytes.concat(packed, abi.encodePacked(p, _nextHot(venueA, p, _fields(MID_A + 1e12))));
        }
        vm.prank(updaterA);
        venueA.post(packed);
        _measure("post, 6 pairs", 83_500);
    }

    /// @dev Mid bands add no storage read to a venue without one: an updater's one-pair `post` costs exactly the same
    /// before any band was set as after the last one is cleared, since the banded-pair count shares the slot the role
    /// check reads. A band on another of the venue's pairs makes the same `post` read this pair's band, one cold slot.
    ///
    /// Against the code before mid bands (d412e20) an unbanded `post` is not free, only cheap: 36,894 gas became
    /// 36,972 for one pair (+78) and 72,554 became 72,772 for six (+218), the cost of deriving the band flag in the
    /// role check and testing it once per entry. That is accepted; the snapshot's `test_gas_post_*` entries pin it.
    function test_gas_post_midBandsAddNoReadUntilSet() public {
        uint16 other = quotedPairs[1];
        uint256 noBands = _updaterPostGas(pairA);
        _measure("post, 1 pair, no bands", 42_000);
        vm.startPrank(makerA);
        venueA.setMidBand(other, 1, type(uint96).max);
        venueA.setMidBand(other, 0, 0);
        vm.stopPrank();
        assertEq(_updaterPostGas(pairA), noBands, "no bands, after one was cleared");

        vm.prank(makerA);
        venueA.setMidBand(other, 1, type(uint96).max);
        uint256 bandElsewhere = _updaterPostGas(pairA);
        emit log_named_uint("gas: post, 1 pair, a band on another pair", bandElsewhere);
        assertGt(bandElsewhere, noBands + 2_100, "a band on another pair: one cold read");
    }

    /// @dev A new pair: two config slots, the hot word and the consumption slot are created (20,000 each here;
    /// TIP-1000 charges about 250,000 each on Tempo), plus the token checks. It starts `Closed`.
    function test_gas_addPair() public {
        MockTIP20V2 chf = _token("CHF2");
        vm.prank(makerA);
        venueA.addPair(address(chf), address(usd), UNIT);
        _measure("addPair", 150_000);
    }

    /// @dev A one-pair `post` that refills both sides after fills on both: one write to the consumption slot, no read.
    function test_gas_post_refillBothSides() public {
        _consumeBothSides();
        bytes memory packed = abi.encodePacked(pairA, _refillHot(HotWord.FLAG_REFILL_BIDS | HotWord.FLAG_REFILL_ASKS));
        vm.prank(updaterA);
        venueA.post(packed);
        _measure("post, 1 pair, refill both sides", 50_000);
    }

    /// @dev Refilling one side reads the consumption slot and rewrites it with the other side kept.
    function test_gas_post_refillOneSide() public {
        _consumeBothSides();
        bytes memory packed = abi.encodePacked(pairA, _refillHot(HotWord.FLAG_REFILL_BIDS));
        vm.prank(updaterA);
        venueA.post(packed);
        _measure("post, 1 pair, refill one side", 50_000);
    }

    /// @dev The clone and `initialize`, which writes the owner's and the settler's slots: no sponsor, no list, nothing
    /// in the factory.
    function test_gas_createVenue() public {
        factory.createVenue(makeAddr("makerN"), "N");
        _measure("createVenue", CREATE_VENUE_CEILING);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Access calls
    // ---------------------------------------------------------------------------------------------------------------

    function test_gas_setPairAccess_listed() public {
        vm.prank(makerB);
        venueB.setPairAccess(pairB, IVenue.AccessMode.Listed);
        _measure("setPairAccess(Listed)", 39_500);
    }

    /// @dev One new member on a pair's home list: one new slot.
    function test_gas_setMembers_homeList_oneNew() public {
        vm.prank(makerB);
        venueB.setMembers(pairB, HOME, _one(stranger), true);
        _measure("setMembers, home list, 1 new", 63_000);
    }

    /// @dev One new member on a sponsor's list: the sponsor's slot and the pair's admission are read, one new slot.
    function test_gas_setMembers_sponsor_oneNew() public {
        _admitSponsor(venueB, pairB);
        vm.prank(sponsorOps);
        venueB.setMembers(pairB, SPONSOR, _one(stranger), true);
        _measure("setMembers, sponsor list, 1 new", 66_000);
    }

    function test_gas_addSponsor() public {
        vm.prank(makerB);
        venueB.addSponsor(SPONSOR, sponsorOps);
        _measure("addSponsor (new slot)", 59_500);
    }

    function test_gas_setPairSponsor_admit() public {
        vm.prank(makerB);
        venueB.addSponsor(SPONSOR, sponsorOps);
        vm.prank(makerB);
        venueB.setPairSponsor(pairB, SPONSOR, true);
        _measure("setPairSponsor, admit (new slot)", 64_500);
    }

    function test_gas_setDenied_oneNew() public {
        vm.prank(updaterB);
        venueB.setDenied(_one(stranger), true);
        _measure("setDenied, 1 new (updater)", 68_000);
    }

    /// @dev An updater setting the venue's taker priority-fee cap: one rewrite of the settler's slot.
    function test_gas_setMaxTakerPriorityFee() public {
        vm.prank(updaterA);
        venueA.setMaxTakerPriorityFee(1 gwei);
        _measure("setMaxTakerPriorityFee (updater)", 41_000);
    }

    /// @dev An updater enabling the default cap: the same one rewrite of the settler's slot.
    function test_gas_enableTakerPriorityFeeCap() public {
        vm.prank(updaterA);
        venueA.enableTakerPriorityFeeCap();
        _measure("enableTakerPriorityFeeCap (updater)", 41_000);
    }

    /// @dev Redefines a live ten-level shape in place: all four words change, none is created or cleared.
    function test_gas_setShape_oneShape() public {
        uint256[4] memory words = _fullShape(7);
        vm.prank(updaterA);
        venueA.setShape(pairA, 1, words);
        _measure("setShape, one shape", 73_000);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------------------------

    function test_gas_swapExactIn_singleSwap() public {
        _selfSwapExactIn(address(eur), address(usd), _request(venueA, pairA, 100e6));
        _measure("swapExactIn, 1 fill", 122_500);
    }

    function test_gas_swapExactOut_singleSwap() public {
        SwapParams memory fills = _request(venueA, pairA, 100e6);
        vm.prank(taker);
        settler.swapExactOut(
            fills.venue,
            fills.pairIndex,
            address(usd),
            address(eur),
            fills.amount,
            type(uint256).max,
            fills.sponsorId,
            _deadline(),
            REF
        );
        _measure("swapExactOut, 1 fill", 129_000);
    }

    /// @dev The access benchmarks share venue B's pair, so they differ only in the access check: `Open` reads no list,
    /// the home list reads one member slot, and a sponsor's list also reads the sponsor's slot and the pair's
    /// admission.
    function test_gas_swapExactIn_venueB_open() public {
        _selfSwapExactIn(address(eur), address(usd), _request(venueB, pairB, 100e6));
        _measure("swapExactIn, 1 fill, Open", 125_000);
    }

    function test_gas_swapExactIn_venueB_homeList() public {
        _listB();
        _selfSwapExactIn(address(eur), address(usd), _request(venueB, pairB, 100e6));
        _measure("swapExactIn, 1 fill, Listed, home list", 128_000);
    }

    function test_gas_swapExactIn_venueB_sponsorList() public {
        _listB();
        _selfSwapExactIn(address(eur), address(usd), _requestUnder(venueB, pairB, 100e6, SPONSOR));
        _measure("swapExactIn, 1 fill, Listed, sponsor list", 133_000);
    }

    /// @dev A nonzero `deniedCount` makes every fill read the taker's deny slot, one cold read.
    function test_gas_swapExactIn_venueB_homeListOneDenied() public {
        _listB();
        vm.prank(makerB);
        venueB.setDenied(_one(stranger), true);
        _selfSwapExactIn(address(eur), address(usd), _request(venueB, pairB, 100e6));
        _measure("swapExactIn, 1 fill, Listed, home list, one account denied", 130_500);
    }

    /// @dev The priority-fee cap shares the settler's slot, which every fill reads first, so a capped swap reads no
    /// other slot: the check is 63 gas of opcodes in the Solar build over the same swap without a cap, well under one cold read
    /// (2,100). The transaction's priority fee is at the cap.
    function test_gas_swapExactIn_underPriorityFeeCap() public {
        uint256 uncapped = _priorityFeeSwapGas(false, true);
        _priorityFeeSwapGas(true, true);
        _measure("swapExactIn, 1 fill, priority fee at the cap", 123_000);
        (uint256 capped,) = _lastTxGas();
        _assertNoExtraRead("swapExactIn, the cap over no cap", capped, uncapped, 250);
    }

    /// @dev Exact out checks the cap twice, in `quote` and in `fill`, both against the slot they read anyway.
    function test_gas_swapExactOut_underPriorityFeeCap() public {
        uint256 uncapped = _priorityFeeSwapGas(false, false);
        _priorityFeeSwapGas(true, false);
        _measure("swapExactOut, 1 fill, priority fee at the cap", 129_000);
        (uint256 capped,) = _lastTxGas();
        _assertNoExtraRead("swapExactOut, the cap over no cap", capped, uncapped, 500);
    }

    function test_gas_swapExactIn_hookedNoopFill() public {
        _selfSwapExactIn(address(eur), address(usd), _request(venueA, hookedPair, 100e6));
        _measure("swapExactIn, hooked no-op fill", 135_500);
    }
}
