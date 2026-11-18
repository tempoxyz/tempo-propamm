// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { MockVirtualAddressRegistry } from "../mocks/MockVirtualAddressRegistry.sol";
import { CoreDeploy } from "../utils/CoreDeploy.sol";
import { LadderPricer, ReserveHook } from "./InvariantSupport.sol";
import { Check, System, V2Handler } from "./V2Handler.sol";

/// @notice Stateful invariants for propAMM v2 over the real contracts: the factory, three venues with two pairs each
/// (EUR/USD on all three in both orientations, OUSD/USD on two, EUR/OUSD on one), each pair's home list, sponsors the
/// venues register, switch and admit pair by pair, whose admin keys list their users and hand their lists between
/// keys, the Settler, and a reserve-backed hook that pulls and takes on venue 0's OUSD/USD
/// pair. `V2Handler` documents the actions and records every per-swap property as it goes; each
/// invariant below reads one of those records or checks global state directly.
contract V2InvariantTest is StdInvariant, Test {
    uint256 internal constant NV = 3;
    uint16 internal constant NP = 2;

    V2Handler internal handler;
    System internal sys;

    function setUp() public {
        vm.warp(1_800_000_000);
        System memory s;
        s.resolver = new MockVirtualAddressRegistry();
        string[3] memory symbols = ["EURC", "USDC", "OUSD"];
        for (uint256 i; i < 3; ++i) {
            s.tokens[i] = new MockTIP20V2(symbols[i], 6);
            s.tokens[i].setResolver(s.resolver);
        }

        // `DeployV2`'s order: the implementation against the factory's predicted address, the Settler, the factory.
        (s.settler, s.factory) = CoreDeploy.core();

        for (uint256 v; v < NV; ++v) {
            s.owners[v] = makeAddr(string.concat("owner", vm.toString(v)));
            s.venues[v] = Venue(s.factory.createVenue(s.owners[v], bytes32(v)));
        }
        s.hook = new ReserveHook(IVenue(address(s.venues[0])));
        s.pricer = new LadderPricer();
        sys = s;

        handler = new V2Handler(s);
        handler.bootstrap();

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = V2Handler.swapExactIn.selector;
        selectors[1] = V2Handler.swapExactOut.selector;
        selectors[2] = V2Handler.swapRepeated.selector;
        selectors[3] = V2Handler.swapAcross.selector;
        selectors[4] = V2Handler.post.selector;
        selectors[5] = V2Handler.setShape.selector;
        selectors[6] = V2Handler.ownerInventory.selector;
        selectors[7] = V2Handler.ownerHook.selector;
        selectors[8] = V2Handler.shockHook.selector;
        selectors[9] = V2Handler.warp.selector;
        selectors[10] = V2Handler.setAccess.selector;
        selectors[11] = V2Handler.probeViews.selector;
        selectors[12] = V2Handler.postAll.selector;
        selectors[13] = V2Handler.swapHooked.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Per token, every holder together holds exactly what was minted less what was clawed back from the
    /// hook: swaps, pulls, takes, withdrawals and funding only move tokens between known holders.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_tokenConservation() public view {
        address[] memory holders = handler.holders();
        for (uint256 t; t < 3; ++t) {
            uint256 held;
            for (uint256 i; i < holders.length; ++i) {
                held += sys.tokens[t].balanceOf(holders[i]);
            }
            assertEq(held, handler.supply(t), string.concat("conservation of token ", vm.toString(t)));
        }
    }

    /// @notice The Settler never holds a balance, after any call.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_settlerHoldsNothing() public view {
        for (uint256 t; t < 3; ++t) {
            assertEq(sys.tokens[t].balanceOf(address(sys.settler)), 0, "Settler balance");
        }
        _assertClean(Check.Settler);
    }

    /// @notice No fill pays a taker more than the ladder posted at the time allows from the side's consumed depth:
    /// each fill equals a ghost LadderMath re-pricing of the posted hot word and shape from that depth, never beats the
    /// inventory-path price of the same base after it, from an independent reference (and a base-target fill rounds
    /// that price exactly once), and never beats the best level the depth leaves.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_fillsMatchPostedLadder() public view {
        _assertClean(Check.Ladder);
    }

    /// @notice A venue ends every swap with its prior balance plus its fills' input, less their output and the hook's
    /// take, plus the hook's pull, and every other token untouched.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_venueKeepsBalance() public view {
        _assertClean(Check.VenueBalance);
    }

    /// @notice Per pair, seq never decreases, and stale batch entries write nothing and emit nothing.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_seqMonotonic() public view {
        for (uint256 v; v < NV; ++v) {
            for (uint16 p; p < NP; ++p) {
                assertEq(sys.venues[v].hotWord(p), handler.ghostHot(v, p), "hot word != last accepted post");
                assertGe(HotWord.seq(sys.venues[v].hotWord(p)), 2, "seq below the bootstrap post");
            }
        }
        _assertClean(Check.Seq);
    }

    /// @notice The hook's take on a fill is at most that fill's input, only on a fill whose pair has the hook with
    /// TAKE_INPUT, where the venue never refuses a take within the input, and a swap moves the hook's balances by
    /// exactly its pulls and takes.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_hookTakeWithinBudget() public view {
        _assertClean(Check.HookBudget);
        _assertClean(Check.Custody);
    }

    /// @notice Every swap pays its caller: the taker's `tokenOut` gain equals the amounts the swap returned, and so
    /// does its `tokenIn` debit.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_takerIsPaidWhatTheSwapReturned() public view {
        _assertClean(Check.Payout);
    }

    /// @notice The views a router reads agree with the ghost: each venue's `takerAccess` and `takerAllowed` for every
    /// pair, every account the actions touch and every sponsor id they use (unregistered and unadmitted ones included),
    /// under the ghost's priority-fee cap and the fees of the call that reads them.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_viewsMatchGhost() public view {
        address[5] memory accounts = handler.accessAccounts();
        uint64[5] memory ids = handler.accessSponsors();
        for (uint256 v; v < NV; ++v) {
            for (uint16 p; p < NP; ++p) {
                for (uint256 i; i < accounts.length; ++i) {
                    for (uint256 j; j < ids.length; ++j) {
                        IVenue.TakerAccess outcome = sys.venues[v].takerAccess(p, accounts[i], ids[j]);
                        assertTrue(outcome != IVenue.TakerAccess.None, "takerAccess never returns None");
                        assertEq(
                            uint256(outcome),
                            uint256(handler.ghostTakerAccess(v, p, accounts[i], ids[j])),
                            "takerAccess"
                        );
                        assertEq(
                            sys.venues[v].takerAllowed(p, accounts[i], ids[j]),
                            handler.ghostAdmits(v, p, accounts[i], ids[j]),
                            "takerAllowed"
                        );
                    }
                }
            }
        }
        _assertClean(Check.Views);
    }

    /// @notice `Venue.quote` predicts `fill`: the ghost's price, the ghost's revert reason, or `InsufficientInventory`
    /// exactly when the venue's balance plus the hook's reported liquidity (BEFORE_FILL only) can't cover the output.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_quotePredictsFill() public view {
        _assertClean(Check.Quote);
    }

    /// @notice Fills take depth off the ladder and only the maker gives it back: per pair and side, the venue's
    /// consumed depth is the base of the side's fills since its last applied refill, it never falls except on a
    /// `Refilled` the venue emitted for that side, and a stale or rejected post refills nothing.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_consumedDepthFallsOnlyOnRefill() public view {
        for (uint256 v; v < NV; ++v) {
            for (uint16 p; p < NP; ++p) {
                (uint128 bids, uint128 asks) = sys.venues[v].consumed(p);
                (uint256 ghostBids, uint256 ghostAsks) = handler.ghostConsumed(v, p);
                assertEq(bids, ghostBids, "consumed bids");
                assertEq(asks, ghostAsks, "consumed asks");
            }
        }
        _assertClean(Check.Depth);
    }

    /// @notice No taker that the venue's access rejects ever fills: a closed pair, a denied taker (whatever any list
    /// says, on `Open` pairs too), an unregistered, disabled or unadmitted sponsor, or a list that doesn't hold the
    /// taker on the pair.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_unauthorizedNeverFills() public view {
        _assertClean(Check.Auth);
    }

    /// @notice Each venue's `deniedCount` equals the number of accounts it denies, and its denials, priority-fee cap,
    /// sponsors (admin, pending admin, switch and generation), admissions and lists on every pair are the ghost's.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_accessStateMatchesGhost() public view {
        address[5] memory accounts = handler.accessAccounts();
        uint64[5] memory ids = handler.accessSponsors();
        for (uint256 v; v < NV; ++v) {
            Venue venue = sys.venues[v];
            uint32 counted;
            for (uint256 i; i < accounts.length; ++i) {
                bool denied = venue.denied(accounts[i]);
                assertEq(denied, handler.ghostDenied(v, accounts[i]), "denial");
                if (denied) ++counted;
            }
            assertEq(venue.deniedCount(), counted, "deniedCount is the number of denied accounts");
            assertEq(venue.deniedCount(), handler.ghostDeniedCount(v), "deniedCount");
            assertEq(venue.maxTakerPriorityFee(), handler.ghostFeeCap(v), "taker priority-fee cap");
            for (uint256 i; i < ids.length; ++i) {
                _assertSponsor(v, ids[i]);
            }
        }
        _assertClean(Check.Ghost);
    }

    /// @notice Every swap and maker call reverts exactly when the ghost says it must, and only with a reason the
    /// ghost allows; venue access modes, hooks and halts match the ghost.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_outcomesMatchGhost() public view {
        for (uint256 v; v < NV; ++v) {
            assertEq(sys.venues[v].halted(), handler.isHalted(v), "halted");
            assertEq(sys.venues[v].settler() == address(sys.settler), !handler.isSettlerMoved(v), "settler");
            for (uint16 p; p < NP; ++p) {
                IVenue.Pair memory pair = sys.venues[v].pair(p);
                (address hook, uint8 flags) = handler.ghostHook(v, p);
                assertEq(uint8(pair.access), uint8(handler.ghostAccess(v, p)), "access mode");
                assertEq(pair.hook, hook, "hook");
                assertEq(pair.hookFlags, flags, "hook flags");
            }
        }
        _assertClean(Check.Outcome);
        _assertClean(Check.Ghost);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Coverage
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Shows the handler isn't vacuous. Replays campaign-shaped runs (32 random actions from the bootstrap
    /// state, 24 times) and requires every path the invariants lean on to be reached: fills of every kind (exact in
    /// and out, repeated fills, several venues, hook pulls, takes and refused takes, fills from consumed depth),
    /// refills, every rejection the ghost predicts (denials, sponsor switches and the priority-fee cap among them),
    /// stale and malformed posts, quote checks and view probes, with no violation.
    function test_handlerCoverage() public {
        uint256[25] memory total;
        for (uint256 run; run < 24; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 i; i < 32; ++i) {
                _act(uint256(keccak256(abi.encode("coverage", run, i))));
            }
            uint256[25] memory counts = handler.stats();
            for (uint256 k; k < 25; ++k) {
                total[k] += counts[k];
            }
            for (uint256 c; c <= uint256(type(Check).max); ++c) {
                assertEq(handler.violations(Check(c)), 0, handler.firstViolation(Check(c)));
            }
            vm.revertToState(snapshot);
        }
        string[25] memory names = [
            "swaps",
            "filled swaps",
            "filled fills",
            "exact-out swaps filled",
            "hook pulls",
            "hook takes",
            "refused takes",
            "access rejections",
            "denied rejections",
            "sponsor rejections",
            "expiry rejections",
            "ladder rejections",
            "inventory rejections",
            "slippage rejections",
            "other rejections",
            "accepted posts",
            "skipped posts",
            "rejected posts",
            "view probes",
            "quote checks",
            "sponsor handoffs",
            "refills",
            "fills from consumed depth",
            "priority-fee rejections",
            "calls"
        ];
        for (uint256 k; k < names.length; ++k) {
            emit log_named_uint(names[k], total[k]);
            assertGt(total[k], 0, names[k]);
        }
    }

    /// @dev One handler action, uniform over the campaign's selectors.
    function _act(uint256 seed) internal {
        uint256 action = seed % 14;
        if (action == 0) handler.swapExactIn(seed);
        else if (action == 1) handler.swapExactOut(seed);
        else if (action == 2) handler.swapRepeated(seed);
        else if (action == 3) handler.swapAcross(seed);
        else if (action == 4) handler.swapHooked(seed);
        else if (action == 5) handler.post(seed);
        else if (action == 6) handler.postAll(seed);
        else if (action == 7) handler.setShape(seed);
        else if (action == 8) handler.ownerInventory(seed);
        else if (action == 9) handler.ownerHook(seed);
        else if (action == 10) handler.shockHook(seed);
        else if (action == 11) handler.warp(seed);
        else if (action == 12) handler.setAccess(seed);
        else handler.probeViews(seed);
    }

    /// @dev The venue's record of one sponsor id, and its admissions and lists on every pair, are the ghost's.
    function _assertSponsor(uint256 v, uint64 id) internal view {
        Venue venue = sys.venues[v];
        (address admin, bool enabled, uint32 generation) = venue.sponsor(id);
        (address ghostAdmin, address ghostPending, bool ghostEnabled, uint32 ghostGeneration) =
            handler.ghostSponsor(v, id);
        assertEq(admin, ghostAdmin, "sponsor admin");
        assertEq(enabled, ghostEnabled, "sponsor switch");
        assertEq(generation, ghostGeneration, "sponsor generation");
        assertEq(venue.pendingSponsorAdmin(id), ghostPending, "pending sponsor admin");
        address[5] memory accounts = handler.accessAccounts();
        for (uint16 p; p < NP; ++p) {
            assertEq(venue.pairSponsor(p, id), handler.ghostAdmitted(v, p, id), "admission");
            for (uint256 i; i < accounts.length; ++i) {
                assertEq(venue.isMember(p, id, accounts[i]), handler.ghostMember(v, p, id, accounts[i]), "member");
            }
        }
    }

    function _assertClean(Check check) internal view {
        assertEq(handler.violations(check), 0, handler.firstViolation(check));
    }
}
