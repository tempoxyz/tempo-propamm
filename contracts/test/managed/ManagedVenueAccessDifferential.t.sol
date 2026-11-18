// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";

import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { CoreDeploy } from "../v2/utils/CoreDeploy.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

/// @notice The v2 access differential: a v2 `Venue` and a `ManagedDirectPropAMM`, each with three pairs, run the same
/// random sequences of access calls from the same callers, and must agree after every call. Managed's access is
/// `Venue`'s, re-implemented (v2 is audit-locked), so the two must return or revert alike, emit the same access events,
/// and read equivalent `takerAccess` (skipping v2's priority-fee entry) for every pair, account and sponsor id; a swap
/// on the pool must be admitted or refused exactly as a `fill` on the venue is.
/// @dev The venue has no updater: administration on the shared surface is owner-only on both contracts, and
/// sponsor admins, pending admins and strangers are the same accounts. Each step is one call:
/// - `addSponsor`, `setSponsorEnabled`, `setPairSponsor`, `setMembers` (home or sponsor lists, with zero, the contract
///   itself, virtual addresses and over-long batches), `transferSponsorAdmin`, `cancelSponsorAdminTransfer`,
///   `acceptSponsorAdmin`, `resetSponsor`;
/// - `setDenied`, `setPairAccess`, `closePair`, `removePair`;
/// - halting (`setHalted`) against the pool's `pause` and `unpause`;
/// - a swap from a fuzzed account under a fuzzed sponsor id: a `fill` through the venue's settler, a `swapExactInput`
///   on the pool.
/// Reverts compare as bytes, with v2's `NotOwnerOrUpdater`, `NotHalted`, `VenueHalted` and `ZeroAddress` read as the
/// pool's `NotOwner`, `NotPaused`, `Paused` and `InvalidAddress`; events compare as topics and data, for
/// every access event the two share, with `HaltedSet` read as `PausedStateChanged`. The pool's oracles stay fresh at
/// a constant price, so leaving `Closed`, which on the pool re-validates the pair's oracle and anchors, never reverts
/// here; `ManagedDirectPropAMM.t.sol` covers its reverts.
contract ManagedVenueAccessDifferentialTest is Test {
    uint16 internal constant PAIRS = 3;
    uint256 internal constant STEPS = 24;
    uint256 internal constant OPS = 14;
    uint64 internal constant HOME = 0;
    uint64 internal constant S1 = 7;
    uint64 internal constant S2 = 9;
    uint64 internal constant S3 = 11;
    uint64 internal constant UNREGISTERED = 4242;
    uint128 internal constant FILL = 1e6;
    /// @dev The pool's oracle price, 1.00 with 8 decimals, and the venue's posted mid, 1.00 with 18.
    uint256 internal constant PRICE = 1e8;
    uint96 internal constant MID = 1e18;
    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant MAX_BATCH = 100;
    /// @dev Stands for the contract a call goes to: the venue in its call, the pool in the pool's.
    address internal constant SELF = address(0x5E1F);
    bytes32 internal constant CUSTOMER = bytes32("customer");

    address internal owner = makeAddr("owner");
    address internal outsider = makeAddr("outsider");
    address internal settler = makeAddr("settler");
    address internal adminA = makeAddr("adminA");
    address internal adminB = makeAddr("adminB");
    address internal candidate = makeAddr("candidate");
    address internal stranger = makeAddr("stranger");
    address internal taker = makeAddr("taker");
    address internal member = makeAddr("member");
    address internal virtualAccount = VirtualAddress.make(0x12345678, 1);

    Venue internal venue;
    ManagedDirectPropAMM internal pool;
    MockTIP20 internal quoteToken;
    MockTIP20[PAIRS] internal bases;
    /// @dev Every account the views and swaps are compared for, and the members and denials are drawn from.
    address[6] internal universe;
    uint64[5] internal ids;

    /// @dev Per op: calls both accepted and calls both refused, for `test_sequencesReachEveryOpAndOutcome`.
    uint256[OPS] internal accepted;
    uint256[OPS] internal refused;
    /// @dev Swaps by the `takerAccess` both read before them.
    uint256[9] internal swapsByAccess;
    uint256 internal fills;

    function setUp() external {
        vm.warp(START);
        universe = [taker, member, adminA, stranger, virtualAccount, candidate];
        ids = [HOME, S1, S2, S3, UNREGISTERED];
        quoteToken = new MockTIP20("USD", 6);
        MockOracle[PAIRS] memory oracles;
        for (uint256 k; k < PAIRS; ++k) {
            bases[k] = new MockTIP20(string.concat("B", vm.toString(k)), 6);
            oracles[k] = new MockOracle(8, PRICE, START);
        }
        VenueFactory factory = CoreDeploy.factoryWith(settler);
        venue = Venue(factory.createVenue(owner, bytes32("differential")));
        pool = new ManagedDirectPropAMM(owner, address(0));

        vm.startPrank(owner);
        for (uint256 k; k < PAIRS; ++k) {
            uint16 v = venue.addPair(address(bases[k]), address(quoteToken), 1e6);
            venue.setShape(v, 0, _shape());
            venue.post(abi.encodePacked(v, _hot()));
            uint16 m = pool.addPair(address(bases[k]), address(quoteToken), oracles[k], 90_000, 50);
            assertEq(v, m, "pair index");
        }
        // The venue starts active, the pool paused: line them up.
        pool.unpause();
        vm.stopPrank();

        for (uint256 k; k < PAIRS; ++k) {
            bases[k].mint(address(venue), 1e12);
            bases[k].mint(address(pool), 1e12);
        }
        quoteToken.mint(address(venue), 1e12);
        quoteToken.mint(address(pool), 1e12);
        for (uint256 i; i < universe.length; ++i) {
            for (uint256 k; k < PAIRS; ++k) {
                bases[k].mint(universe[i], 1e12);
                vm.prank(universe[i]);
                bases[k].approve(address(pool), type(uint256).max);
            }
        }

        // A starting state where every refusal is one step away: S1 (adminA) admitted on pairs 0 and 1 with a member,
        // S2 (adminB) registered and admitted nowhere, the taker on pair 0's home list, pairs 0 and 1 `Listed`.
        _both(owner, abi.encodeCall(IVenue.addSponsor, (S1, adminA)));
        _both(owner, abi.encodeCall(IVenue.addSponsor, (S2, adminB)));
        _both(owner, abi.encodeCall(IVenue.setPairSponsor, (0, S1, true)));
        _both(owner, abi.encodeCall(IVenue.setPairSponsor, (1, S1, true)));
        _both(owner, abi.encodeCall(IVenue.setPairAccess, (0, IVenue.AccessMode.Listed)));
        _both(owner, abi.encodeCall(IVenue.setPairAccess, (1, IVenue.AccessMode.Listed)));
        _both(owner, abi.encodeCall(IVenue.setMembers, (0, HOME, _one(taker), true)));
        _both(adminA, abi.encodeCall(IVenue.setMembers, (0, S1, _one(member), true)));
        _compareViews();
    }

    /// @dev One fuzzed sequence of `STEPS` calls.
    /// forge-config: ci.fuzz.runs = 256
    /// forge-config: coverage.fuzz.runs = 32
    function testFuzz_sequencesMatchTheVenue(uint256 seed) external {
        for (uint256 i; i < STEPS; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
            _compareViews();
        }
    }

    /// @dev Shows the differential isn't vacuous: 60 fixed sequences must accept and refuse every kind of call (where
    /// the kind can be refused), fill swaps, and refuse them for every reason `takerAccess` has.
    function test_sequencesReachEveryOpAndOutcome() external {
        // The counters live in storage, which each run's revert resets, so they are summed here first.
        uint256[OPS] memory accepts;
        uint256[OPS] memory refusals;
        uint256[9] memory byAccess;
        uint256 filled;
        for (uint256 run; run < 60; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 i; i < STEPS; ++i) {
                _step(uint256(keccak256(abi.encode("coverage", run, i))));
            }
            _compareViews();
            for (uint256 op; op < OPS; ++op) {
                accepts[op] += accepted[op];
                refusals[op] += refused[op];
            }
            for (uint256 a; a < 9; ++a) {
                byAccess[a] += swapsByAccess[a];
            }
            filled += fills;
            vm.revertToState(snapshot);
        }
        string[OPS] memory names = [
            "addSponsor",
            "setSponsorEnabled",
            "setPairSponsor",
            "setMembers",
            "transferSponsorAdmin",
            "cancelSponsorAdminTransfer",
            "acceptSponsorAdmin",
            "resetSponsor",
            "setDenied",
            "setPairAccess",
            "closePair",
            "halt / pause",
            "removePair",
            "swap"
        ];
        for (uint256 op; op < OPS; ++op) {
            emit log_named_uint(string.concat(names[op], ": accepted"), accepts[op]);
            emit log_named_uint(string.concat(names[op], ": refused"), refusals[op]);
            assertGt(accepts[op], 0, names[op]);
            assertGt(refusals[op], 0, names[op]);
        }
        for (uint256 a = uint256(IManagedDirectPropAMM.TakerAccess.Allowed); a < 9; ++a) {
            emit log_named_uint(string.concat("swaps with takerAccess ", vm.toString(a)), byAccess[a]);
            assertGt(byAccess[a], 0, "a TakerAccess value no swap met");
        }
        assertGt(filled, 0, "fills");
    }

    /// @dev Leaving `Closed` re-validates the pool's oracle, which the venue doesn't have.
    function test_knownDivergences() external {
        vm.warp(START + 90_001);
        vm.startPrank(owner);
        venue.setPairAccess(2, IVenue.AccessMode.Listed);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, START, 90_000));
        pool.setPairAccess(2, IManagedDirectPropAMM.AccessMode.Listed);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- one step

    function _step(uint256 r) internal {
        // Swaps are a fifth of the steps.
        uint256 op = r % (OPS + 4);
        if (op >= OPS) op = OPS - 1;
        uint16 p = uint16((r >> 8) % (PAIRS + 1));
        // Weighted toward the registered sponsors, so most calls can succeed.
        uint64 id = [S1, S2, S1, S2, S3, UNREGISTERED, HOME, HOME][(r >> 16) % 8];
        bool flag = (r >> 24) & 1 == 1;
        uint256 pick = r >> 32;
        bool ok;
        if (op == 0) {
            uint64 newId = [S1, S2, S3, HOME][(r >> 16) % 4];
            ok = _both(_caller(pick, owner), abi.encodeCall(IVenue.addSponsor, (newId, _adminCandidate(r >> 64))));
        } else if (op == 1) {
            ok = _both(_caller(pick, owner), abi.encodeCall(IVenue.setSponsorEnabled, (id, flag)));
        } else if (op == 2) {
            ok = _both(_caller(pick, owner), abi.encodeCall(IVenue.setPairSponsor, (p, id, flag)));
        } else if (op == 3) {
            address preferred = id == HOME ? owner : _sponsorAdmin(id);
            ok = _both(_caller(pick, preferred), abi.encodeCall(IVenue.setMembers, (p, id, _accounts(r >> 64), flag)));
        } else if (op == 4) {
            address next = _adminCandidate(r >> 72);
            ok = _both(_caller(pick, _sponsorAdmin(id)), abi.encodeCall(IVenue.transferSponsorAdmin, (id, next)));
        } else if (op == 5) {
            ok = _both(_caller(pick, _sponsorAdmin(id)), abi.encodeCall(IVenue.cancelSponsorAdminTransfer, (id)));
        } else if (op == 6) {
            // Mostly a sponsor with a handover pending, if there is one.
            if ((r >> 64) % 4 != 0) {
                for (uint256 i = 1; i < 4; ++i) {
                    if (venue.pendingSponsorAdmin(ids[i]) != address(0)) id = ids[i];
                }
            }
            address pending = venue.pendingSponsorAdmin(id);
            ok = _both(
                _caller(pick, pending == address(0) ? candidate : pending),
                abi.encodeCall(IVenue.acceptSponsorAdmin, (id))
            );
        } else if (op == 7) {
            ok = _both(_caller(pick, owner), abi.encodeCall(IVenue.resetSponsor, (id, _adminCandidate(r >> 64))));
        } else if (op == 8) {
            ok = _both(_caller(pick, owner), abi.encodeCall(IVenue.setDenied, (_accounts(r >> 64), flag)));
        } else if (op == 9) {
            ok = _setPairAccess(_caller(pick, owner), p, IVenue.AccessMode((r >> 64) % 4), (r >> 72) & 1 == 1);
        } else if (op == 10) {
            ok = _both(_caller(pick, owner), abi.encodeCall(IVenue.closePair, (p)));
        } else if (op == 11) {
            ok = _halt(_caller(pick, owner), flag);
        } else if (op == 12) {
            // Rarely, so most sequences keep their pairs; otherwise the owner reopens a pair.
            if ((r >> 64) % 4 != 0) {
                ok = _setPairAccess(_caller(pick, owner), p, IVenue.AccessMode.Listed, false);
                op = 9;
            } else {
                ok = _both(_caller(pick, owner), abi.encodeCall(IVenue.removePair, (p)));
            }
        } else {
            // Mostly the accounts the starting state lists, under the lists that hold them.
            uint256 who = (r >> 64) % 10;
            address account = who < 3 ? taker : who < 6 ? member : universe[who % universe.length];
            uint64 swapId = (r >> 72) % 3 == 0 ? id : who < 3 ? HOME : S1;
            ok = _swap(account, p, swapId);
        }
        if (ok) ++accepted[op];
        else ++refused[op];
    }

    /// @dev `setPairAccess`, optionally halted or paused around it (by the owner) so `Open` can be entered.
    function _setPairAccess(address caller, uint16 p, IVenue.AccessMode mode, bool pauseAround)
        internal
        returns (bool ok)
    {
        bool wasActive = !venue.halted();
        if (pauseAround && wasActive) _halt(owner, true);
        ok = _both(caller, abi.encodeCall(IVenue.setPairAccess, (p, mode)));
        if (pauseAround && wasActive) _halt(owner, false);
    }

    /// @dev The venue's `setHalted(halt)` against the pool's `pause()` or `unpause()`.
    function _halt(address caller, bool halt) internal returns (bool) {
        return _call(
            caller,
            abi.encodeCall(IVenue.setHalted, (halt)),
            halt ? abi.encodeCall(IManagedDirectPropAMM.pause, ()) : abi.encodeCall(IManagedDirectPropAMM.unpause, ())
        );
    }

    /// @dev A `fill` on the venue through its settler and a `swapExactInput` on the pool, by `account` under `id`:
    /// both fill, or both refuse with the same error, which is the one `takerAccess` names.
    function _swap(address account, uint16 p, uint64 id) internal returns (bool okV) {
        IManagedDirectPropAMM.TakerAccess access = pool.takerAccess(p, account, id);
        ++swapsByAccess[uint8(access)];
        assertEq(venue.takerAllowed(p, account, id), pool.takerAllowed(p, account, id), "takerAllowed");
        assertEq(pool.takerAllowed(p, account, id), access == IManagedDirectPropAMM.TakerAccess.Allowed);
        MockTIP20 base = bases[p < PAIRS ? p : 0];
        vm.prank(settler);
        bytes memory retV;
        (okV, retV) = address(venue)
            .call(
                abi.encodeCall(
                    IVenue.fill, (p, address(base), address(quoteToken), FILL, true, account, id, bytes32("ref"))
                )
            );
        vm.prank(account);
        (bool okM, bytes memory retM) = address(pool)
            .call(
                abi.encodeCall(
                    IManagedDirectPropAMM.swapExactInput,
                    (p, true, FILL, 0, id, CUSTOMER, bytes32("trade"), block.timestamp, PRICE, 0, 0)
                )
            );
        assertEq(okV, okM, "swap admission");
        if (!okV) assertEq(_mapError(retV), retM, "swap refusal");
        if (okV) {
            ++fills;
            assertTrue(!pool.paused(), "filled while paused");
            assertEq(uint8(access), uint8(IManagedDirectPropAMM.TakerAccess.Allowed), "filled without access");
        } else if (!pool.paused()) {
            assertEq(retM, _refusal(access, p, account, id), "refused with another reason than takerAccess");
        }
    }

    // ---------------------------------------------------------------- running a call on both

    /// @dev Runs one access call, whose ABI the two share, on both with `SELF` read as each contract's own address.
    function _both(address caller, bytes memory data) internal returns (bool) {
        return _call(caller, _bind(data, address(venue)), _bind(data, address(pool)));
    }

    /// @dev Runs `dataV` on the venue and `dataM` on the pool from `caller`, and requires the same outcome and the
    /// same shared access events.
    function _call(address caller, bytes memory dataV, bytes memory dataM) internal returns (bool okV) {
        vm.recordLogs();
        vm.prank(caller);
        bytes memory retV;
        (okV, retV) = address(venue).call(dataV);
        Vm.Log[] memory logsV = vm.getRecordedLogs();
        vm.recordLogs();
        vm.prank(caller);
        (bool okM, bytes memory retM) = address(pool).call(dataM);
        Vm.Log[] memory logsM = vm.getRecordedLogs();
        assertEq(okV, okM, "outcome");
        if (!okV) assertEq(_mapError(retV), retM, "revert");
        _compareEvents(logsV, logsM);
    }

    /// @dev `data` with every address word equal to `SELF` replaced by `target`. Every argument the calls take is a
    /// static word or an address array, so a word-by-word pass is exact.
    function _bind(bytes memory data, address target) internal pure returns (bytes memory bound) {
        bound = bytes.concat(data);
        for (uint256 offset = 4; offset + 32 <= bound.length; offset += 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(bound, 32), offset))
            }
            if (word == uint256(uint160(SELF))) {
                assembly ("memory-safe") {
                    mstore(add(add(bound, 32), offset), target)
                }
            }
        }
    }

    function _compareEvents(Vm.Log[] memory logsV, Vm.Log[] memory logsM) internal view {
        Vm.Log[] memory a = _sharedEvents(logsV, address(venue));
        Vm.Log[] memory b = _sharedEvents(logsM, address(pool));
        assertEq(a.length, b.length, "event count");
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i].topics, b[i].topics, "event topics");
            assertEq(a[i].data, b[i].data, "event data");
        }
    }

    /// @dev `emitter`'s logs among the access events the two contracts share, with `HaltedSet` read as
    /// `PausedStateChanged` (both carry one unindexed bool).
    function _sharedEvents(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log[] memory kept) {
        kept = new Vm.Log[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IVenue.HaltedSet.selector) {
                logs[i].topics[0] = IManagedDirectPropAMM.PausedStateChanged.selector;
            } else if (!_isShared(topic)) {
                continue;
            }
            kept[n++] = logs[i];
        }
        assembly ("memory-safe") {
            mstore(kept, n)
        }
    }

    function _isShared(bytes32 topic) internal pure returns (bool) {
        return topic == IVenue.PairAccessUpdated.selector || topic == IVenue.PairRemoved.selector
            || topic == IVenue.SponsorAdded.selector || topic == IVenue.SponsorEnabledSet.selector
            || topic == IVenue.PairSponsorSet.selector || topic == IVenue.MemberUpdated.selector
            || topic == IVenue.SponsorAdminTransferStarted.selector || topic == IVenue.SponsorAdminTransferred.selector
            || topic == IVenue.SponsorReset.selector || topic == IVenue.DenyUpdated.selector
            || topic == IManagedDirectPropAMM.PausedStateChanged.selector;
    }

    /// @dev A venue revert as the pool gives it: the role, halt and zero-address errors are named differently.
    function _mapError(bytes memory ret) internal pure returns (bytes memory) {
        if (ret.length != 4) return ret;
        bytes4 selector = bytes4(ret);
        if (selector == IVenue.NotOwnerOrUpdater.selector) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector);
        }
        if (selector == IVenue.NotHalted.selector) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.NotPaused.selector);
        }
        if (selector == IVenue.VenueHalted.selector) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.Paused.selector);
        }
        if (selector == IVenue.ZeroAddress.selector) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.InvalidAddress.selector);
        }
        return ret;
    }

    /// @dev The pool's swap error for a refusal.
    function _refusal(IManagedDirectPropAMM.TakerAccess access, uint16 p, address account, uint64 id)
        internal
        view
        returns (bytes memory)
    {
        if (access == IManagedDirectPropAMM.TakerAccess.UnknownPair) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        }
        if (access == IManagedDirectPropAMM.TakerAccess.Denied) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.TakerDenied.selector, account);
        }
        if (access == IManagedDirectPropAMM.TakerAccess.UnknownSponsor) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, id);
        }
        if (access == IManagedDirectPropAMM.TakerAccess.SponsorDisabled) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, id);
        }
        if (access == IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.SponsorNotAdmitted.selector, p, id);
        }
        return abi.encodeWithSelector(IManagedDirectPropAMM.TakerNotAllowed.selector, account);
    }

    // ---------------------------------------------------------------- the views

    /// @dev Every access view the two share, for every pair (and one unknown index), sponsor id and account.
    function _compareViews() internal view {
        assertEq(venue.halted(), pool.paused(), "halted / paused");
        assertEq(venue.deniedCount(), pool.deniedCount(), "deniedCount");
        assertEq(venue.pairCount(), pool.pairCount(), "pairCount");
        for (uint256 i = 1; i < ids.length; ++i) {
            (address adminV, bool enabledV, uint32 generationV) = venue.sponsor(ids[i]);
            (address adminM, bool enabledM, uint32 generationM) = pool.sponsor(ids[i]);
            assertEq(adminV, adminM, "sponsor admin");
            assertEq(enabledV, enabledM, "sponsor enabled");
            assertEq(generationV, generationM, "sponsor generation");
            assertEq(venue.pendingSponsorAdmin(ids[i]), pool.pendingSponsorAdmin(ids[i]), "pending admin");
        }
        for (uint256 w; w < universe.length; ++w) {
            assertEq(venue.denied(universe[w]), pool.denied(universe[w]), "denied");
        }
        for (uint16 p; p <= PAIRS; ++p) {
            assertEq(uint8(venue.pair(p).access), uint8(pool.pair(p).access), "pair mode");
            for (uint256 i; i < ids.length; ++i) {
                assertEq(venue.pairSponsor(p, ids[i]), pool.pairSponsor(p, ids[i]), "pairSponsor");
                for (uint256 w; w < universe.length; ++w) {
                    address account = universe[w];
                    assertEq(venue.isMember(p, ids[i], account), pool.isMember(p, ids[i], account), "isMember");
                    assertEq(
                        _managedAccess(venue.takerAccess(p, account, ids[i])),
                        uint8(pool.takerAccess(p, account, ids[i])),
                        "takerAccess"
                    );
                }
            }
        }
    }

    /// @dev v2 retains its priority-fee refusal; managed access omits that enum entry. The venue's cap stays unset.
    function _managedAccess(IVenue.TakerAccess access) internal pure returns (uint8) {
        assert(access != IVenue.TakerAccess.PriorityFeeTooHigh);
        uint8 value = uint8(access);
        return value > uint8(IVenue.TakerAccess.PriorityFeeTooHigh) ? value - 1 : value;
    }

    // ---------------------------------------------------------------- choices

    /// @dev Mostly the caller a call needs, otherwise any role or a stranger.
    function _caller(uint256 pick, address preferred) internal view returns (address) {
        uint256 c = pick % 10;
        if (c < 5 || preferred == address(0)) return preferred == address(0) ? owner : preferred;
        return [owner, outsider, adminA, candidate, stranger][c - 5];
    }

    function _sponsorAdmin(uint64 id) internal view returns (address admin) {
        (admin,,) = venue.sponsor(id);
    }

    /// @dev A new admin: mostly a real account, sometimes zero, the contract itself or a virtual address.
    function _adminCandidate(uint256 pick) internal view returns (address) {
        return [adminA, adminB, candidate, stranger, adminA, address(0), SELF, virtualAccount][pick % 8];
    }

    /// @dev One to three accounts from the universe, sometimes with zero or the contract itself among them, or rarely
    /// one more than `MAX_BATCH`.
    function _accounts(uint256 pick) internal view returns (address[] memory accounts) {
        if (pick % 32 == 0) {
            accounts = new address[](MAX_BATCH + 1);
            for (uint256 i; i < accounts.length; ++i) {
                accounts[i] = address(uint160(0x10000 + i));
            }
            return accounts;
        }
        accounts = new address[](1 + (pick >> 5) % 3);
        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = universe[(pick >> (8 + 8 * i)) % universe.length];
        }
        uint256 bad = (pick >> 40) % 12;
        if (bad == 0) accounts[accounts.length - 1] = address(0);
        else if (bad == 1) accounts[0] = SELF;
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    // ---------------------------------------------------------------- the venue's ladder

    /// @dev One level of 1,000,000 base units at 1 bp on each side: far more than the sequences' fills take.
    function _shape() internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](1);
        uint16[] memory spreads = new uint16[](1);
        sizes[0] = 1_000_000;
        spreads[0] = 10;
        (words[0],) = ShapeWord.packSide(sizes, spreads);
        words[2] = words[0];
    }

    function _hot() internal pure returns (bytes32) {
        return HotWord.pack(
            HotWord.Fields({
                mid: MID,
                bidWiden: 0,
                askWiden: 0,
                widthScale: 1000,
                depthScale: 1000,
                shapeId: 0,
                validUntil: uint40(START + 365 days),
                seq: 2,
                flags: 0
            })
        );
    }
}
