// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";
import { Settler } from "../../src/v2/Settler.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { MockTIP20V2 } from "./mocks/MockTIP20V2.sol";
import { CoreDeploy } from "./utils/CoreDeploy.sol";

/// @notice `takerAccess` against real swaps through the Settler. For every outcome of the venue's access check, the
/// view returns it, `takerAllowed` is true exactly for `Allowed`, and an exact-input and an exact-output swap in the
/// same state both fill (`Allowed`) or both revert with the error `fill` gives for that refusal. Where several
/// refusals apply at once, the view reports the one the swap reverts with. Across random access states, the view
/// matches an independent model of the check, `takerAllowed == (takerAccess == Allowed)`, and swaps agree. The taker
/// priority-fee cap is part of the check (`PriorityFeeTooHigh`), so the tests that reach it set the transaction's gas
/// price and base fee (`vm.txGasPrice`, `vm.fee`) and read the views in the transaction that pays them. The fees are
/// a few wei: under `--network tempo` every transaction pays its fee in pathUSD, which the test's accounts don't hold,
/// and a few wei per gas rounds to no fee at all. `TakerPriorityFee.t.sol` covers realistic fees.
/// @dev The venue calls nothing for access, so the suite runs the same with or without `--network tempo`; CI runs it
/// both ways, as it does every `*VenueAccess*` suite.
contract VenueAccessReasonsTest is Test {
    uint64 internal constant UNIT = 1e6;
    uint96 internal constant MID = 1.085e18;
    /// @dev Each swap's base amount: 1 EUR in (exact input) or out (exact output).
    uint128 internal constant AMOUNT = 1e6;
    bytes32 internal constant REF = keccak256("access reasons");
    /// @dev The `sponsorId` that names the venue's home list.
    uint64 internal constant HOME = 0;
    /// @dev Registered in `setUp`, with admin `alpha`, and admitted on `pairId`.
    uint64 internal constant ALPHA = 7;
    /// @dev Registered by the tests that need it, with admin `beta`.
    uint64 internal constant BETA = 9;
    /// @dev Never registered.
    uint64 internal constant UNREGISTERED = 42;
    /// @dev How many `TakerAccess` values there are, `None` included.
    uint256 internal constant OUTCOMES = 10;
    /// @dev The base fee the cap tests run under, and the cap they set, in wei (see the contract's notes).
    uint256 internal constant BASE_FEE = 7;
    uint64 internal constant CAP = 2;

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal alpha = makeAddr("alpha");
    address internal beta = makeAddr("beta");
    /// @dev On `pairId`'s home list.
    address internal taker = makeAddr("taker");
    /// @dev On `ALPHA`'s list for `pairId`.
    address internal member = makeAddr("member");
    /// @dev On no list.
    address internal stranger = makeAddr("stranger");
    /// @dev Denied by the tests that need a nonzero `deniedCount` without denying the account that swaps.
    address internal bystander = makeAddr("bystander");

    Settler internal settler;
    VenueFactory internal factory;
    Venue internal venue;
    MockTIP20V2 internal eur;
    MockTIP20V2 internal usd;
    uint16 internal pairId;

    /// @dev The fuzz test's model of the venue's access state, kept beside the calls it makes.
    struct Model {
        IVenue.AccessMode mode;
        bool removed;
        bool betaRegistered;
        mapping(address account => bool) denied;
        mapping(uint64 sponsorId => bool) disabled;
        mapping(uint64 sponsorId => bool) admitted;
        mapping(uint64 sponsorId => uint32) generation;
        mapping(uint64 sponsorId => mapping(address account => uint32)) listedIn;
        // The taker priority-fee cap, as the venue holds it (`NO_PRIORITY_FEE_CAP` for none).
        uint64 feeCap;
    }

    Model internal model;

    function setUp() external {
        vm.warp(1_800_000_000);
        (settler, factory) = CoreDeploy.core();
        venue = Venue(factory.createVenue(owner, "access reasons"));
        eur = new MockTIP20V2("EURC", 6);
        usd = new MockTIP20V2("USDC", 6);
        pairId = _livePair();
        _setMode(pairId, IVenue.AccessMode.Listed);
        vm.startPrank(owner);
        venue.setUpdater(updater, true);
        venue.addSponsor(ALPHA, alpha);
        venue.setPairSponsor(pairId, ALPHA, true);
        venue.setMembers(pairId, HOME, _one(taker), true);
        vm.stopPrank();
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(member), true);

        model.mode = IVenue.AccessMode.Listed;
        model.admitted[ALPHA] = true;
        model.generation[HOME] = 1;
        model.generation[ALPHA] = 1;
        model.listedIn[HOME][taker] = 1;
        model.listedIn[ALPHA][member] = 1;
        model.feeCap = type(uint64).max;
    }

    // ---------------------------------------------------------------- each outcome, with its fill error

    /// @dev `TakerAccess` is `None` at 0, then one value per outcome of the check. A new one needs its own test here
    /// and an error mapping in `_fillError`.
    function test_outcomesAreNoneThenAllowedThenEachRefusalInFillOrder() external pure {
        assertEq(uint256(type(IVenue.TakerAccess).max) + 1, OUTCOMES);
        assertEq(uint256(IVenue.TakerAccess.None), 0);
        assertEq(uint256(IVenue.TakerAccess.Allowed), 1);
        assertEq(uint256(IVenue.TakerAccess.UnknownPair), 2);
        assertEq(uint256(IVenue.TakerAccess.PriorityFeeTooHigh), 3);
        assertEq(uint256(IVenue.TakerAccess.Closed), 4);
        assertEq(uint256(IVenue.TakerAccess.Denied), 5);
        assertEq(uint256(IVenue.TakerAccess.UnknownSponsor), 6);
        assertEq(uint256(IVenue.TakerAccess.SponsorDisabled), 7);
        assertEq(uint256(IVenue.TakerAccess.SponsorNotAdmitted), 8);
        assertEq(uint256(IVenue.TakerAccess.NotListed), 9);
    }

    /// @dev Zero never reads as `Allowed`. A zero word, which a missing record or a call whose return a caller doesn't
    /// check decodes to, is `None`, and the view never returns `None`.
    function test_zeroIsNeverAllowed() external {
        assertTrue(uint8(IVenue.TakerAccess.Allowed) != 0, "Allowed is not 0");
        IVenue.TakerAccess zero = abi.decode(new bytes(32), (IVenue.TakerAccess));
        assertEq(uint256(zero), uint256(IVenue.TakerAccess.None), "32 zero bytes decode as None");
        assertTrue(zero != IVenue.TakerAccess.Allowed, "32 zero bytes are not Allowed");

        // A call to an account without code succeeds and returns nothing, so a caller that reads its return word
        // without checking the size reads 0: `None`, not `Allowed`.
        address noCode = makeAddr("no code");
        bytes memory data = abi.encodeCall(IVenue.takerAccess, (pairId, taker, HOME));
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0x00, 0)
            ok := staticcall(gas(), noCode, add(data, 0x20), mload(data), 0x00, 0x20)
            word := mload(0x00)
        }
        assertTrue(ok, "a call to an account without code succeeds");
        assertEq(word, uint256(IVenue.TakerAccess.None), "and its unchecked return reads None");

        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
        _check(pairId + 1, taker, HOME, IVenue.TakerAccess.UnknownPair);
    }

    function test_allowed_homeListSponsorListAndOpen() external {
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
        _expect(pairId, member, ALPHA, IVenue.TakerAccess.Allowed, "");
        // A denial elsewhere makes the check read the taker's deny slot, which admits it.
        _deny(bystander, true);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
        _expect(pairId, member, ALPHA, IVenue.TakerAccess.Allowed, "");
        // `Open` admits everyone not denied, whatever the id.
        _setMode(pairId, IVenue.AccessMode.Open);
        _expect(pairId, stranger, HOME, IVenue.TakerAccess.Allowed, "");
        _expect(pairId, stranger, UNREGISTERED, IVenue.TakerAccess.Allowed, "");
        _expect(pairId, member, type(uint64).max, IVenue.TakerAccess.Allowed, "");
    }

    /// @dev An index never added and a removed pair both read `None`; `fill` reverts `UnknownPair` while pricing,
    /// before its access check, and so does the exact-output swap's `quote`.
    function test_unknownPair() external {
        _expect(
            77,
            taker,
            HOME,
            IVenue.TakerAccess.UnknownPair,
            abi.encodeWithSelector(IVenue.UnknownPair.selector, uint16(77))
        );
        vm.prank(owner);
        venue.removePair(pairId);
        bytes memory err = abi.encodeWithSelector(IVenue.UnknownPair.selector, pairId);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.UnknownPair, err);
        _expect(pairId, member, ALPHA, IVenue.TakerAccess.UnknownPair, err);
        assertFalse(venue.pairSponsor(pairId, ALPHA), "removed pairs report no admission");
    }

    /// @dev A transaction whose priority fee is above the venue's cap, whoever the taker and whatever the id, on
    /// `Listed` and `Open` pairs: both swaps revert `TakerPriorityFeeTooHigh`, the exact-output one from its `quote`.
    /// At the cap, below the base fee and with no gas price at all (an `eth_call` without fee fields), the check
    /// admits again.
    function test_priorityFeeTooHigh() external {
        vm.fee(BASE_FEE);
        _setCap(owner, CAP);
        _setFee(BASE_FEE + CAP + 1);
        bytes memory err = abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, uint256(CAP) + 1, CAP);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.PriorityFeeTooHigh, err);
        _expect(pairId, member, ALPHA, IVenue.TakerAccess.PriorityFeeTooHigh, err);
        _setMode(pairId, IVenue.AccessMode.Open);
        _expect(pairId, stranger, UNREGISTERED, IVenue.TakerAccess.PriorityFeeTooHigh, err);
        _setFee(BASE_FEE + 13);
        _check(pairId, taker, HOME, IVenue.TakerAccess.PriorityFeeTooHigh);

        _setFee(BASE_FEE + CAP);
        _expect(pairId, stranger, UNREGISTERED, IVenue.TakerAccess.Allowed, "");
        _setFee(BASE_FEE - 1);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
        _setFee(0);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
        // An updater lowers the cap to 0: only a transaction paying no priority fee fills.
        _setCap(updater, 0);
        _setFee(BASE_FEE + 1);
        _expect(
            pairId,
            taker,
            HOME,
            IVenue.TakerAccess.PriorityFeeTooHigh,
            abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, uint256(1), uint64(0))
        );
        _setFee(BASE_FEE);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
        // Removed, no fee is too high.
        _setCap(owner, type(uint64).max);
        _setFee(BASE_FEE + 13);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
    }

    function test_closed() external {
        vm.prank(updater);
        venue.closePair(pairId);
        _expect(
            pairId,
            taker,
            HOME,
            IVenue.TakerAccess.Closed,
            abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker)
        );
        _expect(
            pairId,
            member,
            ALPHA,
            IVenue.TakerAccess.Closed,
            abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member)
        );
        // A pair `addPair` just made starts `Closed`.
        uint16 fresh = _livePair();
        _expect(
            fresh,
            taker,
            HOME,
            IVenue.TakerAccess.Closed,
            abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker)
        );
    }

    function test_denied() external {
        _deny(taker, true);
        bytes memory err = abi.encodeWithSelector(IVenue.TakerDenied.selector, taker);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Denied, err);
        _setMode(pairId, IVenue.AccessMode.Open);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Denied, err);
        _expect(pairId, taker, UNREGISTERED, IVenue.TakerAccess.Denied, err);
        // Lifting it admits the taker again.
        _deny(taker, false);
        _expect(pairId, taker, HOME, IVenue.TakerAccess.Allowed, "");
    }

    function test_unknownSponsor() external {
        _expect(
            pairId,
            member,
            UNREGISTERED,
            IVenue.TakerAccess.UnknownSponsor,
            abi.encodeWithSelector(IVenue.UnknownSponsor.selector, UNREGISTERED)
        );
        _expect(
            pairId,
            member,
            type(uint64).max,
            IVenue.TakerAccess.UnknownSponsor,
            abi.encodeWithSelector(IVenue.UnknownSponsor.selector, type(uint64).max)
        );
    }

    function test_sponsorDisabled() external {
        vm.prank(updater);
        venue.setSponsorEnabled(ALPHA, false);
        _expect(
            pairId,
            member,
            ALPHA,
            IVenue.TakerAccess.SponsorDisabled,
            abi.encodeWithSelector(IVenue.SponsorDisabled.selector, ALPHA)
        );
        vm.prank(owner);
        venue.setSponsorEnabled(ALPHA, true);
        _expect(pairId, member, ALPHA, IVenue.TakerAccess.Allowed, "");
    }

    /// @dev Removed from the pair, and registered but never admitted there.
    function test_sponsorNotAdmitted() external {
        vm.prank(updater);
        venue.setPairSponsor(pairId, ALPHA, false);
        _expect(
            pairId,
            member,
            ALPHA,
            IVenue.TakerAccess.SponsorNotAdmitted,
            abi.encodeWithSelector(IVenue.SponsorNotAdmitted.selector, pairId, ALPHA)
        );
        vm.prank(owner);
        venue.addSponsor(BETA, beta);
        _expect(
            pairId,
            member,
            BETA,
            IVenue.TakerAccess.SponsorNotAdmitted,
            abi.encodeWithSelector(IVenue.SponsorNotAdmitted.selector, pairId, BETA)
        );
    }

    /// @dev Unlisted on the home list or a sponsor's list, listed on another list than the one named, listed on
    /// another pair, delisted, and listed before a reset.
    function test_notListed() external {
        _expect(
            pairId,
            stranger,
            HOME,
            IVenue.TakerAccess.NotListed,
            abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, stranger)
        );
        _expect(
            pairId,
            stranger,
            ALPHA,
            IVenue.TakerAccess.NotListed,
            abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, stranger)
        );
        bytes memory memberErr = abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, member);
        _expect(pairId, member, HOME, IVenue.TakerAccess.NotListed, memberErr);
        _expect(
            pairId,
            taker,
            ALPHA,
            IVenue.TakerAccess.NotListed,
            abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, taker)
        );

        uint16 second = _livePair();
        _setMode(second, IVenue.AccessMode.Listed);
        vm.prank(owner);
        venue.setPairSponsor(second, ALPHA, true);
        _expect(second, member, ALPHA, IVenue.TakerAccess.NotListed, memberErr);

        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(member), false);
        _expect(pairId, member, ALPHA, IVenue.TakerAccess.NotListed, memberErr);
        vm.prank(alpha);
        venue.setMembers(pairId, ALPHA, _one(member), true);
        vm.prank(owner);
        venue.resetSponsor(ALPHA, beta);
        assertTrue(venue.pairSponsor(pairId, ALPHA), "a reset keeps the admission");
        _expect(pairId, member, ALPHA, IVenue.TakerAccess.NotListed, memberErr);
    }

    // ---------------------------------------------------------------- several refusals at once

    /// @dev Each step leaves every later refusal in place, so the view must name the first one `fill` checks: an
    /// unknown pair, then the priority fee, then `Closed`, the deny list, and on a `Listed` pair the sponsor's
    /// registration, switch and admission, then the member.
    function test_precedenceFollowsFillOrder() external {
        vm.fee(BASE_FEE);
        _setCap(owner, CAP);
        vm.startPrank(owner);
        venue.addSponsor(BETA, beta);
        venue.setPairSponsor(pairId, BETA, true);
        vm.stopPrank();
        vm.prank(beta);
        venue.setMembers(pairId, BETA, _one(stranger), true);
        vm.startPrank(updater);
        venue.setPairSponsor(pairId, BETA, false);
        venue.setSponsorEnabled(BETA, false);
        vm.stopPrank();
        _deny(member, true);

        // A removed pair outranks everything: the member is denied, the sponsor is unregistered, and the fee is over
        // the cap.
        uint16 removed = _livePair();
        _setMode(removed, IVenue.AccessMode.Listed);
        vm.prank(owner);
        venue.removePair(removed);
        _setFee(BASE_FEE + CAP + 1);
        _check(removed, member, UNREGISTERED, IVenue.TakerAccess.UnknownPair);
        // The fee outranks `Closed`, the denial and every sponsor refusal.
        vm.prank(updater);
        venue.closePair(pairId);
        _check(pairId, member, UNREGISTERED, IVenue.TakerAccess.PriorityFeeTooHigh);
        _check(pairId, stranger, BETA, IVenue.TakerAccess.PriorityFeeTooHigh);
        // `Closed` outranks the denial and every sponsor refusal.
        _setFee(BASE_FEE + CAP);
        _check(pairId, member, UNREGISTERED, IVenue.TakerAccess.Closed);
        _check(pairId, stranger, BETA, IVenue.TakerAccess.Closed);
        // The denial outranks every sponsor refusal and the list, and holds on `Open`.
        _setMode(pairId, IVenue.AccessMode.Listed);
        _check(pairId, member, UNREGISTERED, IVenue.TakerAccess.Denied);
        _check(pairId, member, BETA, IVenue.TakerAccess.Denied);
        _check(pairId, member, HOME, IVenue.TakerAccess.Denied);
        _check(pairId, member, ALPHA, IVenue.TakerAccess.Denied);
        // An unregistered sponsor outranks the list.
        _check(pairId, stranger, UNREGISTERED, IVenue.TakerAccess.UnknownSponsor);
        // A switched-off sponsor outranks its admission: `BETA` is off and removed, though it lists the stranger.
        _check(pairId, stranger, BETA, IVenue.TakerAccess.SponsorDisabled);
        _check(pairId, taker, BETA, IVenue.TakerAccess.SponsorDisabled);
        // Switched on, the removal outranks the list in both directions.
        vm.prank(owner);
        venue.setSponsorEnabled(BETA, true);
        _check(pairId, stranger, BETA, IVenue.TakerAccess.SponsorNotAdmitted);
        _check(pairId, taker, BETA, IVenue.TakerAccess.SponsorNotAdmitted);
        // Readmitted, only the list is left: it holds the stranger and not the taker.
        vm.prank(owner);
        venue.setPairSponsor(pairId, BETA, true);
        _check(pairId, stranger, BETA, IVenue.TakerAccess.Allowed);
        _check(pairId, taker, BETA, IVenue.TakerAccess.NotListed);
        // `Open` skips every sponsor refusal and the list, but not the denial.
        vm.prank(updater);
        venue.setSponsorEnabled(BETA, false);
        _setMode(pairId, IVenue.AccessMode.Open);
        _check(pairId, taker, BETA, IVenue.TakerAccess.Allowed);
        _check(pairId, taker, UNREGISTERED, IVenue.TakerAccess.Allowed);
        _check(pairId, member, ALPHA, IVenue.TakerAccess.Denied);
    }

    // ---------------------------------------------------------------- random states

    /// @dev Up to 12 random owner, updater and sponsor-admin calls over the pair's mode, the deny list, sponsor
    /// registration, switches, admissions and resets, both sponsors' and the home list's members, the taker
    /// priority-fee cap and the pair's removal, then a random base fee and gas price around the cap; then, for three
    /// accounts and four ids, the view must match the model and `takerAllowed` must be `takerAccess == Allowed`, and
    /// two swaps through the Settler must fill or revert as the view says.
    function testFuzz_takerAllowedIsTakerAccessAllowed(uint256 seed) external {
        uint256 steps = 1 + seed % 12;
        for (uint256 i; i < steps; ++i) {
            _act(uint256(keccak256(abi.encode(seed, i))));
        }
        _drawFee(uint256(keccak256(abi.encode(seed, "fee"))));
        address[3] memory who = [taker, member, stranger];
        uint64[4] memory ids = [HOME, ALPHA, BETA, UNREGISTERED];
        for (uint256 w; w < who.length; ++w) {
            for (uint256 i; i < ids.length; ++i) {
                IVenue.TakerAccess outcome = venue.takerAccess(pairId, who[w], ids[i]);
                assertTrue(outcome != IVenue.TakerAccess.None, "takerAccess never returns None");
                assertEq(
                    uint256(venue.takerAccess(pairId + 1, who[w], ids[i])),
                    uint256(IVenue.TakerAccess.UnknownPair),
                    "a pair never added is UnknownPair, not None"
                );
                assertEq(uint256(outcome), uint256(_modelAccess(who[w], ids[i])), "takerAccess matches the model");
                assertEq(
                    venue.takerAllowed(pairId, who[w], ids[i]),
                    outcome == IVenue.TakerAccess.Allowed,
                    "takerAllowed is takerAccess == Allowed"
                );
            }
        }
        for (uint256 k; k < 2; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, "swap", k)));
            address account = who[r % who.length];
            uint64 id = ids[(r >> 8) % ids.length];
            IVenue.TakerAccess outcome = venue.takerAccess(pairId, account, id);
            _assertSwaps(pairId, account, id, _fillError(outcome, pairId, account, id));
        }
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Requires `takerAccess` to be `expected`, `takerAllowed` to be true exactly for `Allowed`, and both swaps
    /// to fill (`err` empty) or revert with `err`.
    function _expect(uint16 pairIndex, address who, uint64 sponsorId, IVenue.TakerAccess expected, bytes memory err)
        internal
    {
        assertEq(uint256(venue.takerAccess(pairIndex, who, sponsorId)), uint256(expected), "takerAccess");
        assertEq(venue.takerAllowed(pairIndex, who, sponsorId), expected == IVenue.TakerAccess.Allowed, "takerAllowed");
        assertEq(err.length == 0, expected == IVenue.TakerAccess.Allowed, "only Allowed fills");
        _assertSwaps(pairIndex, who, sponsorId, err);
    }

    /// @dev `_expect` with the error the tests above pin for each outcome.
    function _check(uint16 pairIndex, address who, uint64 sponsorId, IVenue.TakerAccess expected) internal {
        _expect(pairIndex, who, sponsorId, expected, _fillError(expected, pairIndex, who, sponsorId));
    }

    /// @dev The error `fill` gives for each refusal, as the single-outcome tests pin it; empty for `Allowed`.
    function _fillError(IVenue.TakerAccess outcome, uint16 pairIndex, address who, uint64 sponsorId)
        internal
        view
        returns (bytes memory)
    {
        if (outcome == IVenue.TakerAccess.Allowed) return "";
        if (outcome == IVenue.TakerAccess.UnknownPair) {
            return abi.encodeWithSelector(IVenue.UnknownPair.selector, pairIndex);
        }
        if (outcome == IVenue.TakerAccess.PriorityFeeTooHigh) {
            return abi.encodeWithSelector(IVenue.TakerPriorityFeeTooHigh.selector, _tip(), venue.maxTakerPriorityFee());
        }
        if (outcome == IVenue.TakerAccess.Denied) return abi.encodeWithSelector(IVenue.TakerDenied.selector, who);
        if (outcome == IVenue.TakerAccess.UnknownSponsor) {
            return abi.encodeWithSelector(IVenue.UnknownSponsor.selector, sponsorId);
        }
        if (outcome == IVenue.TakerAccess.SponsorDisabled) {
            return abi.encodeWithSelector(IVenue.SponsorDisabled.selector, sponsorId);
        }
        if (outcome == IVenue.TakerAccess.SponsorNotAdmitted) {
            return abi.encodeWithSelector(IVenue.SponsorNotAdmitted.selector, pairIndex, sponsorId);
        }
        // `Closed` and `NotListed`.
        return abi.encodeWithSelector(IVenue.TakerNotAllowed.selector, who);
    }

    /// @dev An exact-input swap of `AMOUNT` EUR in, then an exact-output swap of `AMOUNT` EUR out, through the Settler
    /// as `who` under `sponsorId`: both fill and pay `who` when `err` is empty, and both revert with `err` otherwise.
    function _assertSwaps(uint16 pairIndex, address who, uint64 sponsorId, bytes memory err) internal {
        eur.mint(who, 10 * AMOUNT);
        usd.mint(who, 10 * AMOUNT);
        vm.startPrank(who);
        eur.approve(address(settler), type(uint256).max);
        usd.approve(address(settler), type(uint256).max);
        vm.stopPrank();
        uint40 deadline = uint40(block.timestamp + 30);
        bool fills = err.length == 0;
        uint256 before = usd.balanceOf(who);
        if (!fills) vm.expectRevert(err);
        vm.prank(who);
        uint256 amountOut = settler.swapExactIn(
            address(venue), pairIndex, address(eur), address(usd), AMOUNT, 0, sponsorId, deadline, REF
        );
        if (fills) {
            assertGt(amountOut, 0, "the exact-input swap fills");
            assertEq(usd.balanceOf(who), before + amountOut, "the exact-input swap pays the taker");
        }
        before = eur.balanceOf(who);
        if (!fills) vm.expectRevert(err);
        vm.prank(who);
        settler.swapExactOut(
            address(venue), pairIndex, address(usd), address(eur), AMOUNT, type(uint256).max, sponsorId, deadline, REF
        );
        if (fills) assertEq(eur.balanceOf(who), before + AMOUNT, "the exact-output swap pays the taker");
    }

    /// @dev One random access call, applied to the venue and to `model`. Calls that would revert are skipped, so the
    /// model only follows calls that happened.
    function _act(uint256 r) internal {
        uint256 kind = r % 10;
        r >>= 8;
        address account = _account(r);
        uint64 id = (r >> 8) & 1 == 0 ? ALPHA : BETA;
        bool flag = (r >> 9) & 1 == 0;
        bool registered = id == ALPHA || model.betaRegistered;
        if (kind == 0) {
            IVenue.AccessMode mode = IVenue.AccessMode(1 + (r >> 10) % 3);
            if (model.removed) return;
            _setMode(pairId, mode);
            model.mode = mode;
        } else if (kind == 1) {
            _deny(account, flag);
            model.denied[account] = flag;
        } else if (kind == 2) {
            if (model.betaRegistered) return;
            vm.prank(owner);
            venue.addSponsor(BETA, beta);
            model.betaRegistered = true;
            model.generation[BETA] = 1;
        } else if (kind == 3) {
            if (!registered) return;
            vm.prank(flag ? owner : updater);
            venue.setSponsorEnabled(id, flag);
            model.disabled[id] = !flag;
        } else if (kind == 4) {
            if (!registered || (flag && model.removed)) return;
            vm.prank(flag ? owner : updater);
            venue.setPairSponsor(pairId, id, flag);
            model.admitted[id] = flag;
        } else if (kind == 5) {
            if (!registered) return;
            vm.prank(owner);
            venue.resetSponsor(id, id == ALPHA ? alpha : beta);
            ++model.generation[id];
        } else if (kind == 6 || kind == 7) {
            // A sponsor's admin edits its own list; the owner edits the home list.
            uint64 list = kind == 6 ? HOME : id;
            if (list != HOME && !registered) return;
            if (flag && (model.removed || (list != HOME && (model.disabled[list] || !model.admitted[list])))) return;
            vm.prank(list == HOME ? owner : list == ALPHA ? alpha : beta);
            venue.setMembers(pairId, list, _one(account), flag);
            model.listedIn[list][account] = flag ? model.generation[list] : 0;
        } else if (kind == 9) {
            // The owner or an updater sets any cap, or removes it.
            uint64 cap = (r >> 10) % 4 == 0 ? type(uint64).max : uint64((r >> 12) % 3);
            _setCap(flag ? owner : updater, cap);
            model.feeCap = cap;
        } else if (r % 4 == 0 && !model.removed) {
            // Rarely, the pair goes: removed pairs refuse everyone.
            vm.prank(owner);
            venue.removePair(pairId);
            model.removed = true;
        }
    }

    /// @dev The access check, from `model` and the transaction's fees, in the order `IVenue.TakerAccess` documents.
    function _modelAccess(address who, uint64 sponsorId) internal view returns (IVenue.TakerAccess) {
        if (model.removed) return IVenue.TakerAccess.UnknownPair;
        if (model.feeCap != type(uint64).max && _tip() > model.feeCap) return IVenue.TakerAccess.PriorityFeeTooHigh;
        if (model.mode == IVenue.AccessMode.Closed) return IVenue.TakerAccess.Closed;
        if (model.denied[who]) return IVenue.TakerAccess.Denied;
        if (model.mode == IVenue.AccessMode.Open) return IVenue.TakerAccess.Allowed;
        if (sponsorId != HOME) {
            bool registered = sponsorId == ALPHA || (sponsorId == BETA && model.betaRegistered);
            if (!registered) return IVenue.TakerAccess.UnknownSponsor;
            if (model.disabled[sponsorId]) return IVenue.TakerAccess.SponsorDisabled;
            if (!model.admitted[sponsorId]) return IVenue.TakerAccess.SponsorNotAdmitted;
        }
        uint32 listed = model.listedIn[sponsorId][who];
        return listed != 0 && listed == model.generation[sponsorId]
            ? IVenue.TakerAccess.Allowed
            : IVenue.TakerAccess.NotListed;
    }

    /// @dev The accounts the fuzz test lists and denies: the three it probes, and one it never probes.
    function _account(uint256 r) internal view returns (address) {
        uint256 k = r % 4;
        return k == 0 ? taker : k == 1 ? member : k == 2 ? stranger : bystander;
    }

    /// @dev A new EUR/USD pair with a deep flat ladder, a long-lived hot word and inventory. It starts `Closed`.
    function _livePair() internal returns (uint16 index) {
        uint32[] memory sizes = new uint32[](1);
        uint16[] memory spreads = new uint16[](1);
        (sizes[0], spreads[0]) = (1_000_000, 10);
        uint256[4] memory words;
        (words[0],) = ShapeWord.packSide(sizes, spreads);
        words[2] = words[0];
        vm.startPrank(owner);
        index = venue.addPair(address(eur), address(usd), UNIT);
        venue.setShape(index, 0, words);
        venue.post(
            abi.encodePacked(
                index,
                HotWord.pack(
                    HotWord.Fields({
                        mid: MID,
                        bidWiden: 0,
                        askWiden: 0,
                        widthScale: 1000,
                        depthScale: 1000,
                        shapeId: 0,
                        validUntil: uint40(block.timestamp + 30 days),
                        seq: 2,
                        flags: 0
                    })
                )
            )
        );
        vm.stopPrank();
        eur.mint(address(venue), 1_000_000e6);
        usd.mint(address(venue), 1_000_000e6);
    }

    /// @dev Sets the pair's mode as the owner, halting around a switch to `Open` and unhalting after it.
    function _setMode(uint16 pairIndex, IVenue.AccessMode mode) internal {
        vm.startPrank(owner);
        if (mode == IVenue.AccessMode.Open) venue.setHalted(true);
        venue.setPairAccess(pairIndex, mode);
        if (mode == IVenue.AccessMode.Open) venue.setHalted(false);
        vm.stopPrank();
    }

    /// @dev Sets the taker priority-fee cap as `caller`.
    function _setCap(address caller, uint64 cap) internal {
        vm.prank(caller);
        venue.setMaxTakerPriorityFee(cap);
    }

    /// @dev Sets the gas price every later call in the test pays, the views' and the swaps' alike.
    function _setFee(uint256 gasPrice) internal {
        vm.txGasPrice(gasPrice);
    }

    /// @dev A random base fee and gas price, in wei: no gas price (an `eth_call` without fee fields), one below the
    /// base fee, or a priority fee of 0 to 3 wei, so at, below and above every cap `_act` draws (0, 1 or 2 wei).
    function _drawFee(uint256 r) internal {
        uint256 baseFee = (r & 3) * 3;
        vm.fee(baseFee);
        uint256 kind = (r >> 2) % 8;
        if (kind == 0) return _setFee(0);
        if (kind == 1) return _setFee(baseFee / 2);
        _setFee(baseFee + (r >> 5) % 4);
    }

    /// @dev The transaction's priority fee per gas, as the venue reads it: 0 for a gas price below the base fee.
    function _tip() internal view returns (uint256) {
        return tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
    }

    /// @dev Denies as an updater, lifts as the owner.
    function _deny(address account, bool deny) internal {
        vm.prank(deny ? updater : owner);
        venue.setDenied(_one(account), deny);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
