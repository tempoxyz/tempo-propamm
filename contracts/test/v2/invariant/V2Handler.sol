// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { ISettler } from "../../../src/v2/interfaces/ISettler.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { VenueHookFlags } from "../../../src/v2/interfaces/IVenueHook.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { LadderMath } from "../../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../../src/v2/libraries/ShapeWord.sol";
import { Settler } from "../../../src/v2/Settler.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../src/v2/VenueFactory.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";
import { MockVirtualAddressRegistry } from "../mocks/MockVirtualAddressRegistry.sol";
import { InventoryPath, InventoryPathOracle } from "../utils/InventoryPath.sol";
import { LadderPricer, ReserveHook } from "./InvariantSupport.sol";

/// @notice Everything the invariant suite deploys, handed to the handler.
struct System {
    /// @dev The TIP-1022 forwarding the tokens apply, as Tempo's TIP-20 does. The venues resolve nothing.
    MockVirtualAddressRegistry resolver;
    VenueFactory factory;
    Settler settler;
    ReserveHook hook;
    LadderPricer pricer;
    MockTIP20V2[3] tokens;
    Venue[3] venues;
    address[3] owners;
}

/// @notice The property each violation counter tracks.
enum Check {
    // Every fill is exactly what the posted ladder gives from the side's consumed depth (ghost re-pricing with
    // LadderMath), never better than the inventory-path price of the same base after that depth (an independent
    // reference) or the best level the depth leaves, and carries the posted mid and seq.
    Ladder,
    // Every venue ends a swap with exactly its prior balance plus its fills' input, minus their output and the
    // hook's take, plus the hook's pull; untouched tokens don't move.
    VenueBalance,
    // The hook's take on a fill is at most that fill's input, and only on a fill whose pair has the hook with
    // TAKE_INPUT, where the venue never refuses a take within the input.
    HookBudget,
    // The taker's `tokenOut` gain and `tokenIn` debit equal the amounts the swap returned: every output goes to the
    // caller.
    Payout,
    // No fill for a taker the venue's access rejects: a transaction over the venue's priority-fee cap, a closed pair,
    // a denied taker, an unregistered, disabled or unadmitted sponsor, or a list that doesn't hold the taker on the
    // pair.
    Auth,
    // Per pair, seq never decreases.
    Seq,
    // A swap or maker call reverts exactly when the ghost says it must, and only with a reason the ghost allows.
    Outcome,
    // The views a router reads (`takerAllowed`, `takerAccess`, `pair`, `hotWord`, `halted`, `hookLiquidity`)
    // agree with the ghost.
    Views,
    // Venue storage matches the ghost (hot words, shapes, access modes, sponsors, admissions, lists, denials, hooks,
    // halts, priority-fee caps).
    Ghost,
    // The Settler never holds a balance.
    Settler,
    // Custody moves (withdraw, fund) move exactly the requested amounts, and a swap moves the hook's balances by
    // exactly its pulls and takes.
    Custody,
    // `Venue.quote` returns what the ladder gives and reverts exactly when `fill` would for the same reason, counting
    // the hook's liquidity only with BEFORE_FILL.
    Quote,
    // Per pair and side, the consumed depth is the ghost's (the base of the side's fills since its last refill), never
    // decreases except on a refill the venue applied (`Refilled`), and a stale or rejected post refills nothing.
    Depth
}

/// @notice Drives the real v2 contracts (factory, three venues with two pairs each, the Settler and
/// sponsors each venue registers, switches and admits pair by pair, whose admin keys list their users and hand
/// their lists on, each pair's home list, and a reserve-backed hook on one pair) with random maker, taker, owner,
/// sponsor, hook, clock and access actions. It keeps ghost copies of every hot word, shape, access mode, sponsor (its
/// admin, pending admin, switch and generation), admission, member, denial, hook, halt and each side's consumed depth,
/// re-prices every fill with `LadderMath` from that depth, and records any property break in `violations`. The handler
/// never reverts: every call that may legitimately fail runs under try/catch and is checked against the ghost's
/// prediction.
/// @dev `isolate = true` runs each of the handler's external calls as its own transaction during the campaign. Each
/// fill starts where the side's earlier fills left its consumed depth, and posts refill one side, both or neither. It
/// extends `Test`, which also keeps this (oversized, never deployed) test helper out of `forge build --sizes`.
contract V2Handler is Test {
    uint256 internal constant EUR = 0;
    uint256 internal constant USD = 1;
    uint256 internal constant OUSD = 2;

    uint256 internal constant NV = 3;
    uint256 internal constant NP = 2;
    /// @dev Shape ids 0-2 are set by makers. Id 3 is never set, so posting it selects an empty ladder.
    uint256 internal constant NSHAPES = 4;
    uint256 internal constant NCHECKS = 13;
    /// @dev Venue 0's OUSD/USD pair, where the hook normally sits.
    uint16 internal constant HOOK_PAIR = 1;
    uint256 internal constant ONE = 1e6;
    uint256 internal constant FACTOR_ONE = 1e8;
    uint256 internal constant DENOMINATOR = 1e26;

    uint8 internal constant LOOSE = 0;
    uint8 internal constant EXACT = 1;
    uint8 internal constant TIGHT = 2;

    uint256 internal constant DRAW_EXACT_IN = 0;
    uint256 internal constant DRAW_EXACT_OUT = 1;
    uint256 internal constant DRAW_REPEAT = 2;
    uint256 internal constant DRAW_ACROSS = 3;
    uint256 internal constant DRAW_HOOKED = 4;

    /// @dev Sponsor ids: `FA` is registered on every venue, `FB` on venue 1 only, `FX` on none until the campaign
    /// registers it; `HOME` is each pair's home list.
    uint64 internal constant HOME = 0;
    uint64 internal constant FA = 7;
    uint64 internal constant FB = 9;
    uint64 internal constant FX = 11;

    uint8 internal constant UNKNOWN_VENUE = 1;
    uint8 internal constant ZERO_AMOUNT = 2;
    /// @dev Not a factory venue.
    address internal constant NOT_A_VENUE = address(0xBEEF);
    /// @dev `Venue.NO_PRIORITY_FEE_CAP`, and the cap venue 2 starts with.
    uint64 internal constant NO_CAP = type(uint64).max;
    uint64 internal constant BOOT_CAP = 1 gwei;
    /// @dev `Venue.DEFAULT_TAKER_PRIORITY_FEE_CAP`, which `enableTakerPriorityFeeCap` sets.
    uint64 internal constant DEFAULT_CAP = 10 gwei;

    uint8 internal constant ALL = VenueHookFlags.ALL;
    uint8 internal constant BEFORE = VenueHookFlags.BEFORE_FILL;
    uint8 internal constant TAKE = VenueHookFlags.TAKE_INPUT;

    struct PairGhost {
        address base;
        address quote;
        uint64 sizeUnit;
        IVenue.AccessMode access;
        bytes32 hot;
        address hook;
        uint8 hookFlags;
        uint96 anchor;
        // Base each side's ladder has given up since its last refill, as the venue must store it.
        uint256 consumedBids;
        uint256 consumedAsks;
    }

    struct Request {
        uint256 v;
        uint16 p;
        uint128 amount;
        // The sponsor the taker names for this fill.
        uint64 sponsorId;
        // 0, or a fill the Settler must reject: UNKNOWN_VENUE or ZERO_AMOUNT.
        uint8 fake;
        bool baseIn;
        bool priced;
        uint256 gIn;
        uint256 gOut;
        // The walked side's consumed depth the ghost priced from.
        uint256 offset;
    }

    struct Swap {
        bool exactIn;
        uint256 tokenIn;
        uint256 tokenOut;
        address taker;
        Request[1] fills;
        uint40 deadline;
        bytes32 ref;
        uint8 boundMode;
        uint256 bound;
        // The ghost's prediction: the first reason the swap must revert (0 for none), the fill it happens on, and
        // whether the venues' own balances cover every fill without the hook.
        bytes4 fail;
        uint256 failFill;
        bool atStart;
        bool inventoryClear;
        uint256 totalIn;
        uint256 totalOut;
    }

    struct Snapshot {
        uint256[3][3] venue;
        uint256 takerIn;
        uint256 takerOut;
        uint256 hookIn;
        uint256 hookOut;
    }

    /// @dev What the logs say about one swap, per fill and per venue.
    struct Fills {
        uint256 count;
        uint256[3] venueIn;
        uint256[3] venueOut;
        uint256[3] venueTake;
        uint256[3] venuePull;
        uint256 totalIn;
        uint256 totalOut;
        uint256 totalTake;
        uint256 totalPull;
    }

    System internal sys;
    /// @dev The independent inventory-path reference, behind external calls.
    InventoryPathOracle internal immutable PATH;
    PairGhost[NP][NV] internal ghost;
    uint256[4][NSHAPES][NP][NV] internal ghostShapes;
    bool[NV] internal ghostHalted;
    /// @dev Whether the venue's owner pointed it at another settler, so the real Settler can't fill it.
    bool[NV] internal settlerMoved;
    uint32[NP][NV] internal seenSeq;
    /// @dev Each side's consumed depth as `_end` last read it from the venue, and whether a `Refilled` the venue
    /// emitted since then cleared it.
    uint256[2][NP][NV] internal seenConsumed;
    bool[2][NP][NV] internal refilledSince;

    /// @dev A venue's record of one sponsor, as the ghost expects it.
    struct SponsorGhost {
        address admin;
        address pending;
        bool enabled;
        uint32 generation;
    }

    /// @dev Each venue's sponsors, per-pair admissions, per-pair lists (the generation each member was listed in; the
    /// home list's is always 1) and denials.
    mapping(uint256 v => mapping(uint64 sponsorId => SponsorGhost)) internal sponsorG;
    mapping(uint256 v => mapping(uint16 p => mapping(uint64 sponsorId => bool))) internal admittedG;
    mapping(uint256 v => mapping(uint16 p => mapping(uint64 sponsorId => mapping(address account => uint32)))) internal
        memberG;
    mapping(uint256 v => mapping(address account => bool)) internal deniedG;
    uint32[NV] internal deniedCountG;
    /// @dev Each venue's taker priority-fee cap (`NO_CAP` for none).
    uint64[NV] internal feeCapG;
    /// @dev The keys sponsor admins hand their lists between.
    address[3] internal sponsorKeys;

    address[3] internal takers;
    address[3] internal updaters;
    address internal alice;
    address internal bob;
    address internal stranger;
    address internal virtualAlice;
    address internal virtualGhost;
    address[] internal holderList;

    uint256 public time;
    uint256[3] internal mintedTotal;
    uint256[3] internal burnedTotal;
    uint256[NCHECKS] internal violationCount;
    string[NCHECKS] internal firstViolationOf;

    // Coverage counters, so the suite can show it isn't vacuous.
    uint256 public calls;
    uint256 public swaps;
    uint256 public filledSwaps;
    uint256 public filledFills;
    uint256 public exactOutSwaps;
    uint256 public hookPulls;
    uint256 public hookTakes;
    uint256 public refusedTakes;
    uint256 public authRejections;
    uint256 public deniedRejections;
    uint256 public sponsorRejections;
    uint256 public expiryRejections;
    uint256 public ladderRejections;
    uint256 public otherRejections;
    uint256 public inventoryRejections;
    uint256 public slippageRejections;
    uint256 public acceptedPosts;
    uint256 public skippedPosts;
    uint256 public rejectedPosts;
    uint256 public viewProbes;
    uint256 public quoteChecks;
    uint256 public handoffs;
    uint256 public refills;
    uint256 public deepFills;
    uint256 public feeRejections;

    constructor(System memory system) {
        sys = system;
        PATH = new InventoryPathOracle();
        for (uint256 i; i < 3; ++i) {
            takers[i] = makeAddr(string.concat("taker", vm.toString(i)));
            updaters[i] = makeAddr(string.concat("updater", vm.toString(i)));
            sponsorKeys[i] = makeAddr(string.concat("sponsorKey", vm.toString(i)));
        }
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        stranger = makeAddr("stranger");
        virtualAlice = _virtual(0x12345678, 0xA11CE);
        virtualGhost = _virtual(0x87654321, 0xDEAD);
        vm.label(virtualAlice, "virtualAlice");
        vm.label(virtualGhost, "virtualGhost");

        for (uint256 i; i < 3; ++i) {
            holderList.push(takers[i]);
            holderList.push(updaters[i]);
            holderList.push(system.owners[i]);
            holderList.push(address(system.venues[i]));
        }
        holderList.push(alice);
        holderList.push(bob);
        holderList.push(stranger);
        holderList.push(virtualAlice);
        holderList.push(virtualGhost);
        holderList.push(address(system.hook));
        holderList.push(address(system.settler));
        holderList.push(address(system.factory));
        for (uint256 i; i < 3; ++i) {
            holderList.push(sponsorKeys[i]);
        }
        holderList.push(address(this));
        for (uint256 v; v < NV; ++v) {
            feeCapG[v] = NO_CAP;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Adds the pairs, curves, inventory, hook reserve and memberships through the same owner, updater and
    /// admin calls the actions use, so the ghost starts in step with the chain.
    function bootstrap() external {
        time = block.timestamp;
        sys.resolver.setVirtual(virtualAlice, alice);
        sys.resolver.setVirtual(virtualGhost, address(0));

        _addPair(0, EUR, USD, 1e6, 1.085e18);
        _addPair(0, OUSD, USD, 1e6, 1e18);
        _addPair(1, EUR, USD, 1e5, 1.085e18);
        _addPair(1, USD, OUSD, 1e6, 1e18);
        _addPair(2, USD, EUR, 1e6, 0.92e18);
        _addPair(2, EUR, OUSD, 1e4, 1.085e18);

        for (uint256 v; v < NV; ++v) {
            vm.prank(sys.owners[v]);
            sys.venues[v].setUpdater(updaters[v], true);
            for (uint16 p; p < NP; ++p) {
                uint256 scale = ONE / ghost[v][p].sizeUnit;
                _bootShape(v, p, 0, _defaultShape(scale));
                _bootShape(v, p, 1, _flatShape(uint32(5000 * scale), 10));
                _bootShape(v, p, 2, _deepShape(scale));
                bytes32 word = HotWord.pack(
                    HotWord.Fields({
                        mid: ghost[v][p].anchor,
                        bidWiden: 0,
                        askWiden: 0,
                        widthScale: 1000,
                        depthScale: 1000,
                        shapeId: 0,
                        validUntil: uint40(time + 900),
                        seq: 2,
                        flags: 0
                    })
                );
                vm.prank(sys.owners[v]);
                sys.venues[v].post(abi.encodePacked(p, word));
                ghost[v][p].hot = word;
                seenSeq[v][p] = 2;
            }
            for (uint256 t; t < 3; ++t) {
                uint256 amount = v == 0 && t == OUSD ? 10 * ONE : 20_000 * ONE;
                _mint(t, sys.owners[v], amount);
                vm.prank(sys.owners[v]);
                sys.tokens[t].transferWithMemo(address(sys.venues[v]), amount, bytes32("fund"));
            }
        }

        // The hook backs venue 0's OUSD/USD pair from its own reserve of both tokens, with a refill, a take cap and
        // full flags.
        address owner0 = sys.owners[0];
        _mint(OUSD, address(sys.hook), 50_000 * ONE);
        _mint(USD, address(sys.hook), 50_000 * ONE);
        sys.hook.configure(100 * ONE, 2_000 * ONE);
        vm.prank(owner0);
        sys.venues[0].setPairHook(HOOK_PAIR, address(sys.hook), ALL);
        ghost[0][HOOK_PAIR].hook = address(sys.hook);
        ghost[0][HOOK_PAIR].hookFlags = ALL;

        // Access: pair 0 of each venue is `Listed`, pair 1 `Open`. Every venue lists a taker or two on pair 0's home
        // list and registers `FA` (key 0); venues 0 and 2 admit it on pair 0, where it lists two takers and alice.
        // Venue 1 registers `FB` (key 2) too and admits only it on pair 0, where it lists taker 0 and bob, so swaps
        // naming `FA` there meet an unadmitted sponsor. Venue 1 also denies a taker on its home list, so swaps meet a
        // denial from the start: each swap has one fill, so a denial the campaign makes later would rarely meet its
        // taker on its venue.
        _bootHome(0, takers[1]);
        _bootHome(0, alice);
        _bootHome(1, takers[0]);
        _bootHome(1, takers[2]);
        _bootHome(2, takers[2]);
        for (uint256 v; v < NV; ++v) {
            _bootSponsor(v, FA, sponsorKeys[0]);
        }
        _bootSponsor(1, FB, sponsorKeys[2]);
        _bootAdmit(0, FA);
        _bootAdmit(2, FA);
        _bootAdmit(1, FB);
        address[3] memory faMembers = [takers[0], takers[1], alice];
        for (uint256 i; i < faMembers.length; ++i) {
            _bootMember(0, FA, faMembers[i]);
            _bootMember(2, FA, faMembers[i]);
        }
        _bootMember(1, FB, takers[0]);
        _bootMember(1, FB, bob);
        _bootDeny(1, takers[2]);
        // Venue 2 caps the taker priority fee, so swaps whose drawn fee is above it meet `TakerPriorityFeeTooHigh`.
        vm.prank(sys.owners[2]);
        sys.venues[2].setMaxTakerPriorityFee(BOOT_CAP);
        feeCapG[2] = BOOT_CAP;
        for (uint256 v; v < NV; ++v) {
            _bootAccess(v, 0, IVenue.AccessMode.Listed);
            _bootAccess(v, 1, IVenue.AccessMode.Open);
        }

        for (uint256 i; i < 3; ++i) {
            for (uint256 t; t < 3; ++t) {
                vm.prank(takers[i]);
                sys.tokens[t].approve(address(sys.settler), type(uint256).max);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Taker actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Exact-in swap on a randomly selected pool.
    function swapExactIn(uint256 seed) external {
        _begin();
        _swap(seed, DRAW_EXACT_IN);
        _end();
    }

    /// @notice Exact-out swap on a randomly selected pool.
    function swapExactOut(uint256 seed) external {
        _begin();
        _swap(seed, DRAW_EXACT_OUT);
        _end();
    }

    /// @notice The same swap twice on the same pool: the second walks the ladder from where the first left the side's
    /// consumed depth, so it never prices better.
    function swapRepeated(uint256 seed) external {
        _begin();
        _swap(seed, DRAW_REPEAT);
        _swap(seed, DRAW_REPEAT);
        _end();
    }

    /// @notice Two independent swaps on randomly selected pools.
    function swapAcross(uint256 seed) external {
        _begin();
        _swap(seed, DRAW_ACROSS);
        _swap(_rand(seed, 1), DRAW_ACROSS);
        _end();
    }

    /// @notice A fill on venue 0's OUSD/USD pair, where the hook usually sits: buying past the venue's balance makes
    /// the hook pull from its reserve, and every fill lets it take some input back.
    function swapHooked(uint256 seed) external {
        _begin();
        _swap(seed, DRAW_HOOKED);
        _end();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Maker actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A batched `post` of 1-3 entries from the owner or the updater, with fresh, stale and occasionally
    /// malformed entries (zero mid, reserved flag, bad length, unknown pair) or an unauthorized caller, some carrying
    /// refill bits. `_end` checks the posted words and each side's consumed depth against the ghost: only an accepted
    /// entry's refill applies.
    function post(uint256 seed) external {
        _begin();
        uint256 v = seed % NV;
        uint256 kind = _rand(seed, 1) % 24;
        address poster = kind == 4 ? stranger : (_rand(seed, 2) % 2 == 0 ? sys.owners[v] : updaters[v]);
        bool malformed = kind < 5;
        uint256 n = 1 + _rand(seed, 3) % 3;

        bytes32[NP] memory next = [ghost[v][0].hot, ghost[v][1].hot];
        // Per pair, the refill flags of the entries `post` accepts.
        uint16[NP] memory refill;
        bytes memory packed;
        uint256 accepted;
        uint256 refilling;
        for (uint256 i; i < n; ++i) {
            uint256 r = _rand(seed, 10 + i);
            uint16 p = uint16(r % NP);
            bytes32 word = _randomHot(v, p, r, HotWord.seq(next[p]));
            bool last = i == n - 1;
            if (last && kind == 0) word = bytes32((uint256(word) >> 96) << 96);
            if (last && kind == 1) word |= bytes32(uint256(1) << (240 + 4 + (r >> 200) % 12));
            packed = abi.encodePacked(packed, last && kind == 3 ? uint16(NP + (r >> 210) % 100) : p, word);
            if (!malformed && HotWord.seq(word) > HotWord.seq(next[p])) {
                uint16 bits = HotWord.flags(word) & HotWord.FLAGS_REFILL;
                refill[p] |= bits;
                if (bits != 0) ++refilling;
                next[p] = HotWord.withoutRefill(word);
                ++accepted;
            }
        }
        if (kind == 2) packed = abi.encodePacked(packed, bytes1(0x01));

        vm.recordLogs();
        vm.prank(poster);
        try sys.venues[v].post(packed) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (malformed) {
                _violate(
                    Check.Outcome, string.concat("malformed or unauthorized post accepted, kind ", vm.toString(kind))
                );
                _end();
                return;
            }
            uint256 posted;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].topics.length == 0) continue;
                if (logs[j].topics[0] == IVenue.Posted.selector) ++posted;
            }
            if (posted != accepted) _violate(Check.Seq, "Posted events != entries with a higher seq");
            if (_countRefills(v, logs) != refilling) _violate(Check.Depth, "Refilled events != refilling entries");
            acceptedPosts += accepted;
            skippedPosts += n - accepted;
            for (uint16 p; p < NP; ++p) {
                ghost[v][p].hot = next[p];
                _applyRefill(v, p, refill[p]);
            }
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            bytes4 want = kind == 0 || kind == 1
                ? IVenue.InvalidHotWord.selector
                : kind == 2
                    ? IVenue.MalformedPost.selector
                    : kind == 3 ? IVenue.UnknownPair.selector : IVenue.NotOwnerOrUpdater.selector;
            if (!malformed) _violate(Check.Outcome, string.concat("valid post reverted ", _hex(sel)));
            else if (sel != want) _violate(Check.Outcome, string.concat("malformed post reverted with ", _hex(sel)));
            ++rejectedPosts;
        }
        _end();
    }

    /// @notice A maker's batched re-quote: the updater posts a fresh word for both of a venue's pairs in one batch,
    function postAll(uint256 seed) external {
        _begin();
        uint256 v = seed % NV;
        bytes memory packed;
        bytes32[NP] memory next;
        uint256 refilling;
        for (uint16 p; p < NP; ++p) {
            uint256 r = _rand(seed, 20 + p);
            // Force a fresh seq: bits 144-146 pick the seq step, and 2-7 are all fresh.
            r = (r & ~(uint256(7) << 144)) | ((2 + (r >> 144) % 6) << 144);
            next[p] = _randomHot(v, p, r, HotWord.seq(ghost[v][p].hot));
            if (HotWord.flags(next[p]) & HotWord.FLAGS_REFILL != 0) ++refilling;
            packed = abi.encodePacked(packed, p, next[p]);
        }
        vm.recordLogs();
        vm.prank(updaters[v]);
        try sys.venues[v].post(packed) {
            if (_countRefills(v, vm.getRecordedLogs()) != refilling) {
                _violate(Check.Depth, "Refilled events != refilling entries");
            }
            for (uint16 p; p < NP; ++p) {
                _applyRefill(v, p, HotWord.flags(next[p]) & HotWord.FLAGS_REFILL);
                ghost[v][p].hot = HotWord.withoutRefill(next[p]);
            }
            acceptedPosts += NP;
        } catch (bytes memory err) {
            _violate(Check.Outcome, string.concat("routine post reverted ", _hex(_selector(err))));
        }
        _end();
    }

    /// @notice Defines, redefines or deletes shape 0-2 of a pair, as the owner or updater; occasionally an invalid
    /// shape or an unauthorized caller, which must revert without changing anything.
    function setShape(uint256 seed) external {
        _begin();
        uint256 v = seed % NV;
        uint16 p = uint16(_rand(seed, 1) % NP);
        uint8 shapeId = uint8(_rand(seed, 2) % 3);
        uint256 kind = _rand(seed, 3) % 24;
        address setter = kind == 5 ? stranger : (_rand(seed, 4) % 2 == 0 ? sys.owners[v] : updaters[v]);
        uint256[4] memory words = _drawShape(seed, kind, ONE / ghost[v][p].sizeUnit);
        bool invalid = kind >= 2 && kind <= 5;

        vm.prank(setter);
        try sys.venues[v].setShape(p, shapeId, words) {
            if (invalid) {
                _violate(
                    Check.Outcome, string.concat("invalid or unauthorized shape accepted, kind ", vm.toString(kind))
                );
                _end();
                return;
            }
            _recordShape(v, p, shapeId, words);
        } catch (bytes memory err) {
            _checkShapeRevert(err, invalid, kind);
        }
        _end();
    }

    /// @dev The words `setShape` tries: all zero (a delete) for kinds 0-1, else two random sides, with one side
    /// broken for kinds 2-4 (a falling spread, an empty level with a spread, a reserved bit). Split out of `setShape`,
    /// like the two helpers below, to keep it within the stack limit of the unoptimized coverage build.
    function _drawShape(uint256 seed, uint256 kind, uint256 scale) internal pure returns (uint256[4] memory words) {
        if (kind >= 2) {
            (words[0], words[1]) = _randomSide(_rand(seed, 5), scale);
            (words[2], words[3]) = _randomSide(_rand(seed, 6), scale);
        }
        uint256 side = _rand(seed, 7) % 2 == 0 ? 0 : 2;
        if (kind == 2) (words[side], words[side + 1]) = _levels2(uint32(10 * scale), 50, uint32(10 * scale), 10);
        if (kind == 3) (words[side], words[side + 1]) = _levels2(0, 5, 0, 0);
        if (kind == 4) words[side] |= uint256(1) << (240 + _rand(seed, 8) % 16);
    }

    /// @dev Records an accepted shape in the ghost and requires the venue to store exactly those words.
    function _recordShape(uint256 v, uint16 p, uint8 shapeId, uint256[4] memory words) internal {
        ghostShapes[v][p][shapeId] = words;
        uint256[4] memory stored = sys.venues[v].shape(p, shapeId);
        for (uint256 i; i < 4; ++i) {
            if (stored[i] != words[i]) _violate(Check.Ghost, "stored shape differs from setShape");
        }
    }

    /// @dev A valid shape must not revert; an invalid one must revert with its own error.
    function _checkShapeRevert(bytes memory err, bool invalid, uint256 kind) internal {
        bytes4 sel = _selector(err);
        if (!invalid) {
            _violate(Check.Outcome, string.concat("valid shape reverted ", _hex(sel)));
        } else if (sel != (kind == 5 ? IVenue.NotOwnerOrUpdater.selector : IVenue.InvalidShape.selector)) {
            _violate(Check.Outcome, string.concat("invalid shape reverted with ", _hex(sel)));
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Owner actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The owner withdraws inventory (allowed while halted) or funds the venue from their own balance; the
    /// updater's withdrawal attempt, and a withdrawal to a virtual address the token forwards, must revert.
    function ownerInventory(uint256 seed) external {
        _begin();
        uint256 v = seed % NV;
        uint256 t = _rand(seed, 1) % 3;
        uint256 kind = _rand(seed, 2) % 8;
        uint256 r = _rand(seed, 3);
        Venue venue = sys.venues[v];
        MockTIP20V2 token = sys.tokens[t];
        address owner = sys.owners[v];
        uint256 held = token.balanceOf(address(venue));

        if (kind < 3) {
            // A virtual address's transfer is forwarded to alice, so its own balance never rises: the venue's
            // exact-credit check must revert the withdrawal and keep the inventory.
            uint256 pick = r % 8;
            address to = pick < 2 ? alice : pick == 2 ? virtualAlice : owner;
            uint256 amount = held == 0 ? 1 : (r >> 8) % 8 == 0 ? held : 1 + (r >> 16) % held;
            uint256 toBefore = token.balanceOf(to);
            vm.prank(owner);
            try venue.withdraw(address(token), to, amount, bytes32("withdraw")) {
                if (held == 0) _violate(Check.Custody, "withdraw beyond the balance succeeded");
                if (to == virtualAlice) _violate(Check.Custody, "withdraw to a virtual address succeeded");
                if (token.balanceOf(address(venue)) + amount != held || token.balanceOf(to) != toBefore + amount) {
                    _violate(Check.Custody, "withdraw moved a different amount");
                }
            } catch (bytes memory err) {
                bool forwarded = to == virtualAlice && _selector(err) == IVenue.BalanceDeltaMismatch.selector;
                if (held != 0 && !forwarded) {
                    _violate(Check.Outcome, string.concat("owner withdraw reverted ", _hex(_selector(err))));
                }
                if (token.balanceOf(address(venue)) != held) {
                    _violate(Check.Custody, "a reverted withdraw moved tokens");
                }
            }
        } else if (kind == 3) {
            if (held != 0) {
                vm.prank(updaters[v]);
                try venue.withdraw(address(token), updaters[v], 1, bytes32(0)) {
                    _violate(Check.Custody, "updater withdrew inventory");
                } catch (bytes memory err) {
                    if (_selector(err) != IVenue.NotOwner.selector) _violate(Check.Outcome, "updater withdraw reason");
                }
            }
        } else {
            uint256 amount = 1 + r % (20_000 * ONE);
            _mint(t, owner, amount);
            vm.prank(owner);
            token.transferWithMemo(address(venue), amount, bytes32("fund"));
            if (token.balanceOf(address(venue)) != held + amount) {
                _violate(Check.Custody, "fund moved a different amount");
            }
        }
        _end();
    }

    /// @notice Venue 0's owner installs, replaces or removes the hook (with every coherent flag set, and
    /// occasionally an incoherent one or an unauthorized caller), or changes its refill and take cap.
    function ownerHook(uint256 seed) external {
        _begin();
        uint256 r = _rand(seed, 2);
        if (_rand(seed, 1) % 10 < 6) _setHook(r);
        else _setHookConfig(r);
        _end();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Environment actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Shocks the hook: a reserve loss (clawed back), a gain, or its switches (pulls or takes off, a
    /// liquidity view that reads 0 or reverts).
    function shockHook(uint256 seed) external {
        _begin();
        uint256 kind = _rand(seed, 1) % 10;
        uint256 r = _rand(seed, 2);
        uint256 t = r % 2 == 0 ? OUSD : USD;
        if (kind < 3) {
            uint256 held = sys.tokens[t].balanceOf(address(sys.hook));
            uint256 loss = held == 0 ? 0 : (r >> 8) % (held / 2 + 1);
            sys.tokens[t].clawback(address(sys.hook), loss);
            burnedTotal[t] += loss;
        } else if (kind < 6) {
            _mint(t, address(sys.hook), (r >> 8) % (20_000 * ONE));
        } else {
            uint8[6] memory views = [0, 0, 0, 0, 1, 2];
            sys.hook.setSwitches((r >> 8) % 5 == 0, (r >> 16) % 5 == 0, views[(r >> 24) % 6]);
        }
        _end();
    }

    /// @notice Moves the clock, usually by under a minute, sometimes by up to an hour (past most `validUntil`s).
    function warp(uint256 seed) external {
        _begin();
        time += seed % 8 == 0 ? 600 + _rand(seed, 1) % 3400 : _rand(seed, 1) % 61;
        vm.warp(time);
        _end();
    }

    /// @notice Access changes: sponsor lists by their admins (and by keys that may not edit them), admin handovers,
    /// each pair's home list, the owner's and updaters' sponsor switches and admissions, resets and registrations,
    /// denials and lifts, each pair's access mode, `closePair`, the venue kill switch, the taker priority-fee cap and
    /// the venue's settler. Unauthorized and malformed attempts must revert with the predicted error.
    function setAccess(uint256 seed) external {
        _begin();
        uint256 kind = _rand(seed, 1) % 22;
        uint256 r = _rand(seed, 2);
        if (kind >= 20) _setFeeCap(r);
        else if (kind == 19) _setSettler(r);
        else if (kind < 3) _setMembership(r);
        else if (kind < 5) _handOff(r);
        else if (kind < 7) _setHome(r);
        // Switches are frequent enough that swaps meet a disabled or unadmitted sponsor, not only its restoration.
        else if (kind < 10) _setSponsorSwitch(r);
        else if (kind == 10) _resetOrAddSponsor(r);
        else if (kind < 13) _setDenied(r);
        else if (kind < 15) _setPairAccess(r);
        else if (kind == 15) _closePair(r);
        else _setHalted(r, kind);
        _end();
    }

    /// @notice Reads what a router reads, for a random venue pair, taker (zero and unknown included), sponsor id
    /// (unregistered, unadmitted and the home list included) and token, and checks it agrees with the ghost: the
    /// venue's `takerAccess` (the ghost's outcome) and `takerAllowed` (exactly `Allowed`), `pair`, `hotWord`, `halted`
    /// and `hookLiquidity`.
    function probeViews(uint256 seed) external {
        _begin();
        ++viewProbes;
        uint256 r = _rand(seed, 1);
        uint256 v = r % NV;
        uint16 p = uint16((r >> 4) % NP);
        address who = _probeTaker(r >> 8);
        uint64[5] memory pool = [HOME, FA, FB, FX, uint64(999)];
        uint64 id = pool[(r >> 16) % 5];
        address token = _probeToken(r >> 24);
        Venue venue = sys.venues[v];
        PairGhost storage g = ghost[v][p];
        _drawFee(r >> 40);

        IVenue.TakerAccess outcome = _accessOutcome(v, p, g.access, who, id);
        IVenue.TakerAccess answered = venue.takerAccess(p, who, id);
        if (answered == IVenue.TakerAccess.None) _violate(Check.Views, "takerAccess returned None");
        if (answered != outcome) _violate(Check.Views, "takerAccess differs from the ghost");
        if (venue.takerAllowed(p, who, id) != (outcome == IVenue.TakerAccess.Allowed)) {
            _violate(Check.Views, "takerAllowed differs from the ghost");
        }
        IVenue.Pair memory pair = venue.pair(p);
        if (
            pair.base != g.base || pair.quote != g.quote || pair.sizeUnit != g.sizeUnit || pair.access != g.access
                || pair.hook != g.hook || pair.hookFlags != g.hookFlags || venue.hotWord(p) != g.hot
                || venue.halted() != ghostHalted[v]
        ) _violate(Check.Views, "a venue view differs from the ghost");
        (uint128 bids, uint128 asks) = venue.consumed(p);
        if (bids != g.consumedBids || asks != g.consumedAsks) _violate(Check.Views, "consumed differs from the ghost");
        uint256 hookOut = g.hook == address(sys.hook) && g.hookFlags & BEFORE != 0 ? _hookLiquidity(token) : 0;
        if (venue.hookLiquidity(p, token) != hookOut) _violate(Check.Views, "hookLiquidity differs");
        _end();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views for the invariant test
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The coverage counters, in the order `V2InvariantTest.test_handlerCoverage` names them.
    function stats() external view returns (uint256[25] memory c) {
        c = [
            swaps,
            filledSwaps,
            filledFills,
            exactOutSwaps,
            hookPulls,
            hookTakes,
            refusedTakes,
            authRejections,
            deniedRejections,
            sponsorRejections,
            expiryRejections,
            ladderRejections,
            inventoryRejections,
            slippageRejections,
            otherRejections,
            acceptedPosts,
            skippedPosts,
            rejectedPosts,
            viewProbes,
            quoteChecks,
            handoffs,
            refills,
            deepFills,
            feeRejections,
            calls
        ];
    }

    function violations(Check check) external view returns (uint256) {
        return violationCount[uint256(check)];
    }

    /// @notice The first violation recorded for `check`, for the failure message.
    function firstViolation(Check check) external view returns (string memory) {
        return firstViolationOf[uint256(check)];
    }

    function totalViolations() external view returns (uint256 total) {
        for (uint256 i; i < NCHECKS; ++i) {
            total += violationCount[i];
        }
    }

    /// @notice Every address that can hold a token in this system.
    function holders() external view returns (address[] memory) {
        return holderList;
    }

    /// @notice What every holder together must hold of token `t`: all minted less all clawed back.
    function supply(uint256 t) external view returns (uint256) {
        return mintedTotal[t] - burnedTotal[t];
    }

    function ghostHot(uint256 v, uint16 p) external view returns (bytes32) {
        return ghost[v][p].hot;
    }

    /// @notice Each side's consumed depth as the ghost tracks it.
    function ghostConsumed(uint256 v, uint16 p) external view returns (uint256 bids, uint256 asks) {
        return (ghost[v][p].consumedBids, ghost[v][p].consumedAsks);
    }

    function ghostAccess(uint256 v, uint16 p) external view returns (IVenue.AccessMode) {
        return ghost[v][p].access;
    }

    /// @notice The venue's taker priority-fee cap as the ghost tracks it.
    function ghostFeeCap(uint256 v) external view returns (uint64) {
        return feeCapG[v];
    }

    /// @notice The ghost's count of the venue's denied accounts.
    function ghostDeniedCount(uint256 v) external view returns (uint32) {
        return deniedCountG[v];
    }

    /// @notice Whether the ghost has `account` denied on the venue.
    function ghostDenied(uint256 v, address account) external view returns (bool) {
        return deniedG[v][account];
    }

    /// @notice The ghost's record of `sponsorId` on the venue.
    function ghostSponsor(uint256 v, uint64 sponsorId)
        external
        view
        returns (address admin, address pending, bool enabled, uint32 generation)
    {
        SponsorGhost storage f = sponsorG[v][sponsorId];
        return (f.admin, f.pending, f.enabled, f.generation);
    }

    /// @notice Whether the ghost has the pair admitting `sponsorId` (always, for the home list).
    function ghostAdmitted(uint256 v, uint16 p, uint64 sponsorId) external view returns (bool) {
        return sponsorId == HOME || admittedG[v][p][sponsorId];
    }

    /// @notice Whether the ghost has `account` on `sponsorId`'s current list for the pair.
    function ghostMember(uint256 v, uint16 p, uint64 sponsorId, address account) external view returns (bool) {
        return _isMember(v, p, sponsorId, account);
    }

    /// @notice Every account the access actions deny or list, for the invariant's sweep.
    function accessAccounts() external view returns (address[5] memory accounts) {
        return [takers[0], takers[1], takers[2], alice, bob];
    }

    /// @notice Every sponsor id the actions register, switch, list or name in a swap.
    function accessSponsors() external pure returns (uint64[5] memory ids) {
        return [HOME, FA, FB, FX, uint64(999)];
    }

    function ghostHook(uint256 v, uint16 p) external view returns (address hook, uint8 flags) {
        return (ghost[v][p].hook, ghost[v][p].hookFlags);
    }

    function isHalted(uint256 v) external view returns (bool) {
        return ghostHalted[v];
    }

    function isSettlerMoved(uint256 v) external view returns (bool) {
        return settlerMoved[v];
    }

    /// @notice Whether the ghost has the pair admitting `taker` under `sponsorId`, as `takerAllowed` must answer.
    function ghostAdmits(uint256 v, uint16 p, address taker_, uint64 sponsorId) external view returns (bool) {
        return _accessOutcome(v, p, ghost[v][p].access, taker_, sponsorId) == IVenue.TakerAccess.Allowed;
    }

    /// @notice The ghost's outcome of the pair's access check for `taker` under `sponsorId`, as `takerAccess` must
    /// answer.
    function ghostTakerAccess(uint256 v, uint16 p, address taker_, uint64 sponsorId)
        external
        view
        returns (IVenue.TakerAccess)
    {
        return _accessOutcome(v, p, ghost[v][p].access, taker_, sponsorId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swap engine
    // ---------------------------------------------------------------------------------------------------------------

    function _swap(uint256 seed, uint256 mode) internal {
        _drawFee(_rand(seed, 7));
        Swap memory s = _drawSwap(seed, mode);
        _predict(s);
        _checkQuote(s);
        _fund(s);
        Snapshot memory pre = _snapshot(s);

        Request memory request = s.fills[0];
        address venue = request.fake == UNKNOWN_VENUE ? NOT_A_VENUE : address(sys.venues[request.v]);
        address tokenIn = address(sys.tokens[s.tokenIn]);
        address tokenOut = address(sys.tokens[s.tokenOut]);
        Settler settler = sys.settler;
        ++swaps;

        bool ok;
        uint256 result;
        bytes memory err;
        vm.recordLogs();
        vm.prank(s.taker);
        if (s.exactIn) {
            try settler.swapExactIn(
                venue, request.p, tokenIn, tokenOut, request.amount, s.bound, request.sponsorId, s.deadline, s.ref
            ) returns (
                uint256 amountOut
            ) {
                (ok, result) = (true, amountOut);
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try settler.swapExactOut(
                venue, request.p, tokenIn, tokenOut, request.amount, s.bound, request.sponsorId, s.deadline, s.ref
            ) returns (
                uint256 amountIn
            ) {
                (ok, result) = (true, amountIn);
            } catch (bytes memory e) {
                err = e;
            }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) _checkFilled(s, pre, logs, result);
        else _checkReverted(s, err);
    }

    function _drawSwap(uint256 seed, uint256 mode) internal view returns (Swap memory s) {
        uint256 r = _rand(seed, 0);
        uint256 cls = mode == DRAW_HOOKED ? 9 : r % 20;
        uint256 a = cls < 9 || cls >= 17 ? EUR : OUSD;
        uint256 b = cls < 17 ? USD : OUSD;
        if ((r >> 8) % 2 == 0) (s.tokenIn, s.tokenOut) = (a, b);
        else (s.tokenIn, s.tokenOut) = (b, a);
        s.exactIn = mode == DRAW_EXACT_IN ? true : mode == DRAW_EXACT_OUT ? false : (r >> 9) % 2 == 0;

        (uint256[6] memory cv, uint16[6] memory cp, uint256 nc) = _candidates(a, b);
        if (mode == DRAW_HOOKED) (cv[0], cp[0], nc) = (0, HOOK_PAIR, 1);
        _drawFills(s, seed, mode, r, cv, cp, nc);
        _drawParties(s, seed, r);
    }

    /// @dev Draws the swap's fills over the `nc` candidate venue pairs `(cv[i], cp[i])`. Split out of `_drawSwap`,
    /// like the helpers below, to keep each function within the stack limit of the unoptimized coverage build.
    function _drawFills(
        Swap memory s,
        uint256 seed,
        uint256 mode,
        uint256 r,
        uint256[6] memory cv,
        uint16[6] memory cp,
        uint256 nc
    ) internal view {
        uint256 pick = (r >> 24) % nc;
        Request memory fill = s.fills[0];
        (fill.v, fill.p) = (cv[pick], cp[pick]);
        uint256 ri = _rand(seed, 100);
        _drawFillAmount(s, fill, mode, ri);
        fill.sponsorId = _drawSponsor(fill.v, ri);
    }

    function _drawFillAmount(Swap memory s, Request memory fill, uint256 mode, uint256 ri) internal view {
        // Log-uniform sizes up to 1,000 tokens, sometimes up to a million, and sometimes about the venue's
        // own balance of the output token, to reach its inventory edge (and the hook's pull).
        uint256 digits = (ri >> 80) % 16 == 0 ? 1 + (ri >> 84) % 12 : 1 + (ri >> 84) % 9;
        fill.amount = uint128(1 + (ri >> 16) % (10 ** digits));
        if ((ri >> 88) % 6 == 0 || (mode == DRAW_HOOKED && (ri >> 88) % 2 == 0)) {
            uint256 held = sys.tokens[s.tokenOut].balanceOf(address(sys.venues[fill.v]));
            if (held > 1_000 * ONE) held = 1_000 * ONE;
            fill.amount = uint128(1 + held / 2 + (ri >> 96) % (held + 1));
        }
        uint256 twist = (ri >> 104) % 128;
        if (twist == 0) fill.fake = UNKNOWN_VENUE;
        else if (twist == 1) (fill.fake, fill.amount) = (ZERO_AMOUNT, 0);
    }

    /// @dev The sponsor a swap names: usually the home list (0) or the sponsor the venue admits on pair 0, sometimes
    /// one it registered but didn't admit, one it never registered, or an id nobody uses.
    function _drawSponsor(uint256 v, uint256 ri) internal pure returns (uint64) {
        uint256 k = (ri >> 112) % 10;
        if (k < 4) return HOME;
        if (k < 7) return v == 1 ? FB : FA;
        if (k == 7) return v == 1 ? FA : FB;
        if (k == 8) return FX;
        return (ri >> 124) % 2 == 0 ? 999 : type(uint64).max;
    }

    /// @dev Draws the taker, the deadline, the bound and the ref. Every swap pays its taker.
    function _drawParties(Swap memory s, uint256 seed, uint256 r) internal view {
        s.taker = takers[(r >> 32) % 3];
        s.deadline = (r >> 48) % 32 == 0 ? uint40(time - 1) : uint40(time + (r >> 56) % 600);
        uint256 bm = (r >> 64) % 8;
        s.boundMode = bm == 0 ? EXACT : bm == 1 ? TIGHT : LOOSE;
        s.bound = s.exactIn ? 0 : type(uint256).max;
        s.ref = keccak256(abi.encode("swap", seed));
    }

    /// @dev The ghost's prediction, in the order the Settler and the venue check things. A fill's first definite
    /// failure ends the walk; inventory is only predicted as "clearly covered by the venues' own balances".
    function _predict(Swap memory s) internal view {
        s.failFill = type(uint256).max;
        s.inventoryClear = true;
        // The Settler's own checks come first, in its order.
        s.atStart = true;
        if (s.deadline < time) {
            s.fail = ISettler.DeadlineExpired.selector;
            return;
        }
        s.atStart = false;
        uint256[NV] memory outLeft;
        for (uint256 v; v < NV; ++v) {
            outLeft[v] = sys.tokens[s.tokenOut].balanceOf(address(sys.venues[v]));
        }
        address tokenIn = address(sys.tokens[s.tokenIn]);
        for (uint256 i; i < s.fills.length; ++i) {
            Request memory fill = s.fills[i];
            PairGhost storage g = ghost[fill.v][fill.p];
            fill.baseIn = tokenIn == g.base;
            if (fill.fake != 0) {
                s.fail = fill.fake == UNKNOWN_VENUE ? ISettler.UnknownVenue.selector : ISettler.ZeroAmount.selector;
                s.failFill = i;
                return;
            }
            fill.offset = fill.baseIn ? g.consumedBids : g.consumedAsks;
            // `fill` checks its caller first; an exact-out fill's `quote` (which doesn't) runs before that.
            bytes4 f = settlerMoved[fill.v] && s.exactIn ? IVenue.NotSettler.selector : _gate(fill, g);
            if (f == 0) {
                (f, fill.gIn, fill.gOut,) = _ghostPrice(fill, s.exactIn);
                if (f == 0) {
                    fill.priced = true;
                }
            }
            if (fill.priced) {
                if (outLeft[fill.v] < fill.gOut) s.inventoryClear = false;
                outLeft[fill.v] = outLeft[fill.v] < fill.gOut ? 0 : outLeft[fill.v] - fill.gOut;
            }
            // An exact-out swap's `quote` checks the cap right after pricing, before `fill` checks its caller.
            if (f == 0 && !s.exactIn && _feeTooHigh(fill.v)) f = IVenue.TakerPriorityFeeTooHigh.selector;
            if (f == 0 && settlerMoved[fill.v]) f = IVenue.NotSettler.selector;
            if (f == 0) f = _accessFailure(fill.v, fill.p, g.access, s.taker, fill.sponsorId);
            if (f != 0) {
                (s.fail, s.failFill) = (f, i);
                return;
            }
            s.totalIn += fill.gIn;
            s.totalOut += fill.gOut;
        }
        if (s.boundMode == EXACT) {
            s.bound = s.exactIn ? s.totalOut : s.totalIn;
        } else if (s.boundMode == TIGHT) {
            s.bound = s.exactIn ? s.totalOut + 1 : s.totalIn - 1;
            s.fail = s.exactIn ? ISettler.InsufficientOutput.selector : ISettler.ExcessiveInput.selector;
        }
    }

    /// @dev `quote` on the swap's first fill, before the swap (so from the side's consumed depth now): it must return
    /// the ghost's price, or revert with the ghost's pricing reason, or `InsufficientInventory` when the venue's
    /// balance plus the hook's `availableLiquidity` (only with BEFORE_FILL) can't cover the output.
    function _checkQuote(Swap memory s) internal {
        Request memory fill = s.fills[0];
        if (fill.fake != 0) return;
        ++quoteChecks;
        PairGhost storage g = ghost[fill.v][fill.p];
        bool baseIn = address(sys.tokens[s.tokenIn]) == g.base;
        Request memory probe = Request({
            v: fill.v,
            p: fill.p,
            amount: fill.amount,
            sponsorId: fill.sponsorId,
            fake: 0,
            baseIn: baseIn,
            priced: false,
            gIn: 0,
            gOut: 0,
            offset: baseIn ? g.consumedBids : g.consumedAsks
        });
        bytes4 want = _gate(probe, g);
        if (want == 0) (want, probe.gIn, probe.gOut,) = _ghostPrice(probe, s.exactIn);
        // Right after pricing, where `fill`'s access check starts.
        if (want == 0 && _feeTooHigh(fill.v)) want = IVenue.TakerPriorityFeeTooHigh.selector;
        address venue = address(sys.venues[fill.v]);
        address tokenOut = address(sys.tokens[s.tokenOut]);
        if (want == 0) {
            uint256 held = MockTIP20V2(tokenOut).balanceOf(venue);
            uint256 extra = g.hook == address(sys.hook) && g.hookFlags & BEFORE != 0 ? _hookLiquidity(tokenOut) : 0;
            if (held + extra < probe.gOut) want = IVenue.InsufficientInventory.selector;
        }
        try IVenue(venue).quote(fill.p, address(sys.tokens[s.tokenIn]), tokenOut, fill.amount, s.exactIn) returns (
            uint128 amountIn, uint128 amountOut
        ) {
            if (want != 0 || amountIn != probe.gIn || amountOut != probe.gOut) {
                _violate(
                    Check.Quote,
                    string.concat("quote returned a fill the ghost rejects or prices differently, want ", _hex(want))
                );
            }
        } catch (bytes memory err) {
            if (_selector(err) != want) {
                _violate(Check.Quote, string.concat("quote reverted ", _hex(_selector(err)), " want ", _hex(want)));
            }
        }
    }

    /// @dev `LadderMath` on the ghost's posted word and shape for the fill's pair and side, from the side's consumed
    /// depth (`fill.offset`): the revert reason (0 when it prices), or the amounts and the base moved.
    function _ghostPrice(Request memory fill, bool exactIn)
        internal
        view
        returns (bytes4 f, uint256 amountIn, uint256 amountOut, uint256 baseFilled)
    {
        PairGhost storage g = ghost[fill.v][fill.p];
        try sys.pricer
            .price(
                g.hot,
                g.sizeUnit,
                fill.baseIn,
                ghostShapes[fill.v][fill.p][HotWord.shapeId(g.hot)],
                exactIn,
                fill.amount,
                fill.offset
            ) returns (
            uint256 aIn, uint256 aOut, uint256 base
        ) {
            if (aIn > type(uint128).max || aOut > type(uint128).max) f = IVenue.AmountOverflow.selector;
            else (amountIn, amountOut, baseFilled) = (aIn, aOut, base);
        } catch (bytes memory e) {
            f = _selector(e);
        }
    }

    /// @dev The checks `fill` (and `quote`) make before pricing: halt, expiry, depth and side.
    function _gate(Request memory fill, PairGhost storage g) internal view returns (bytes4) {
        if (ghostHalted[fill.v]) return IVenue.VenueHalted.selector;
        if (time > HotWord.validUntil(g.hot)) return IVenue.QuoteExpired.selector;
        if (HotWord.depthScale(g.hot) == 0 || HotWord.sideOff(g.hot, fill.baseIn)) return IVenue.SideDisabled.selector;
        return 0;
    }

    /// @dev Tops the taker up to what every fill up to the predicted failure pulls.
    function _fund(Swap memory s) internal {
        if (s.atStart) return;
        uint256 last = s.failFill < s.fills.length ? s.failFill : s.fills.length - 1;
        uint256 need;
        for (uint256 i; i <= last; ++i) {
            need += s.exactIn ? uint256(s.fills[i].amount) : s.fills[i].gIn;
        }
        uint256 held = sys.tokens[s.tokenIn].balanceOf(s.taker);
        if (held < need) _mint(s.tokenIn, s.taker, need - held);
    }

    function _snapshot(Swap memory s) internal view returns (Snapshot memory pre) {
        for (uint256 v; v < NV; ++v) {
            for (uint256 t; t < 3; ++t) {
                pre.venue[v][t] = sys.tokens[t].balanceOf(address(sys.venues[v]));
            }
        }
        pre.takerIn = sys.tokens[s.tokenIn].balanceOf(s.taker);
        pre.takerOut = sys.tokens[s.tokenOut].balanceOf(s.taker);
        pre.hookIn = sys.tokens[s.tokenIn].balanceOf(address(sys.hook));
        pre.hookOut = sys.tokens[s.tokenOut].balanceOf(address(sys.hook));
    }

    function _checkFilled(Swap memory s, Snapshot memory pre, Vm.Log[] memory logs, uint256 result) internal {
        ++filledSwaps;
        if (!s.exactIn) ++exactOutSwaps;
        if (s.fail != 0) {
            _violate(Check.Outcome, string.concat("swap filled although the ghost predicted ", _hex(s.fail)));
            if (_isAccessError(s.fail)) _violate(Check.Auth, "a swap the venue's access rejects filled");
        }

        Fills memory f = _parseFills(s, logs);
        if (f.count != s.fills.length) _violate(Check.Ladder, "Fill events != fills");

        // The Settler's return value, the taker's gain and the taker's debit all equal the fills.
        uint256 requested;
        for (uint256 i; i < s.fills.length; ++i) {
            requested += s.fills[i].amount;
        }
        if (s.exactIn) {
            if (result != f.totalOut) _violate(Check.Payout, "swapExactIn returned != sum of fill outputs");
            if (f.totalIn != requested) _violate(Check.Payout, "exact-in fills used != fill inputs");
        } else {
            if (result != f.totalIn) _violate(Check.Payout, "swapExactOut returned != sum of fill inputs");
            if (f.totalOut != requested) _violate(Check.Payout, "exact-out fills paid != fill outputs");
        }
        uint256 takerAfter = sys.tokens[s.tokenOut].balanceOf(s.taker);
        if (takerAfter != pre.takerOut + f.totalOut) _violate(Check.Payout, "taker gain != paid");
        if (pre.takerIn != sys.tokens[s.tokenIn].balanceOf(s.taker) + f.totalIn) {
            _violate(Check.Payout, "taker debit != used input");
        }

        // Each venue: exactly its prior balance, plus input, less output and the hook's take, plus the hook's pull.
        for (uint256 v; v < NV; ++v) {
            address venue = address(sys.venues[v]);
            for (uint256 t; t < 3; ++t) {
                uint256 held = sys.tokens[t].balanceOf(venue);
                bool okBalance;
                if (t == s.tokenIn) okBalance = held + f.venueTake[v] == pre.venue[v][t] + f.venueIn[v];
                else if (t == s.tokenOut) okBalance = held + f.venueOut[v] == pre.venue[v][t] + f.venuePull[v];
                else okBalance = held == pre.venue[v][t];
                if (!okBalance) {
                    _violate(
                        Check.VenueBalance,
                        string.concat("venue ", vm.toString(v), " token ", vm.toString(t), " balance off after a swap")
                    );
                }
            }
        }
        if (sys.tokens[s.tokenIn].balanceOf(address(sys.hook)) != pre.hookIn + f.totalTake) {
            _violate(Check.Custody, "hook tokenIn delta != its takes");
        }
        if (sys.tokens[s.tokenOut].balanceOf(address(sys.hook)) + f.totalPull != pre.hookOut) {
            _violate(Check.Custody, "hook tokenOut delta != its pulls");
        }
        _checkSettlerEmpty();

        filledFills += s.fills.length;
    }

    /// @dev Walks the swap's logs in order. A fill's hook pull (`Pulled`), take (`Took`) and refused take
    /// (`TakeRefused`) are emitted before its venue's `Fill`, so each is attributed to the next `Fill`. The balance
    /// checks in `_checkFilled` then confirm the attributed amounts really moved, on the venue and on the hook.
    function _parseFills(Swap memory s, Vm.Log[] memory logs) internal returns (Fills memory f) {
        uint256 pendingTake;
        uint256 pendingPull;
        bool refused;
        for (uint256 j; j < logs.length; ++j) {
            Vm.Log memory lg = logs[j];
            if (lg.topics.length == 0) continue;
            bytes32 topic = lg.topics[0];
            if (lg.emitter == address(sys.hook)) {
                address token = address(uint160(uint256(lg.topics[1])));
                if (topic == ReserveHook.Pulled.selector) {
                    if (token != address(sys.tokens[s.tokenOut])) _violate(Check.VenueBalance, "hook pulled tokenIn");
                    pendingPull += abi.decode(lg.data, (uint256));
                } else if (topic == ReserveHook.Took.selector) {
                    if (token != address(sys.tokens[s.tokenIn])) _violate(Check.HookBudget, "hook took tokenOut");
                    pendingTake += abi.decode(lg.data, (uint256));
                } else if (topic == ReserveHook.TakeRefused.selector) {
                    ++refusedTakes;
                    refused = true;
                }
            } else if (topic == IVenue.Fill.selector && _venueIndex(lg.emitter) < NV) {
                if (f.count >= s.fills.length) {
                    _violate(Check.Ladder, "more Fill events than fills");
                    break;
                }
                (uint256 amountIn, uint256 amountOut) =
                    _checkFillFill(s, f.count, lg, pendingTake, pendingPull, refused);
                uint256 v = s.fills[f.count].v;
                f.venueIn[v] += amountIn;
                f.venueOut[v] += amountOut;
                f.venueTake[v] += pendingTake;
                f.venuePull[v] += pendingPull;
                f.totalIn += amountIn;
                f.totalOut += amountOut;
                f.totalTake += pendingTake;
                f.totalPull += pendingPull;
                if (pendingTake != 0) ++hookTakes;
                if (pendingPull != 0) ++hookPulls;
                (pendingTake, pendingPull, refused) = (0, 0, false);
                ++f.count;
            }
        }
        if (pendingTake != 0 || pendingPull != 0 || refused) {
            _violate(Check.HookBudget, "hook moved funds outside any fill");
        }
    }

    function _checkFillFill(Swap memory s, uint256 i, Vm.Log memory lg, uint256 take, uint256 pull, bool refused)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        Request memory fill = s.fills[i];
        PairGhost storage g = ghost[fill.v][fill.p];
        if (
            lg.emitter != address(sys.venues[fill.v]) || uint256(lg.topics[1]) != fill.p
                || address(uint160(uint256(lg.topics[2]))) != s.taker || lg.topics[3] != s.ref
        ) _violate(Check.Ladder, string.concat("Fill event doesn't match fill ", vm.toString(i)));

        (uint64 sponsorId, bool baseIn, uint128 aIn, uint128 aOut, uint96 mid, uint32 seq) =
            abi.decode(lg.data, (uint64, bool, uint128, uint128, uint96, uint32));
        (amountIn, amountOut) = (aIn, aOut);
        if (sponsorId != fill.sponsorId) _violate(Check.Ladder, "Fill sponsorId differs from the swap's");

        // Ghost re-pricing: exactly what LadderMath gives on the posted curve from the side's consumed depth.
        if (!fill.priced || aIn != fill.gIn || aOut != fill.gOut || baseIn != fill.baseIn) {
            _violate(
                Check.Ladder,
                string.concat(
                    "fill differs from the posted ladder: got ",
                    vm.toString(uint256(aIn)),
                    "/",
                    vm.toString(uint256(aOut)),
                    " ghost ",
                    vm.toString(fill.gIn),
                    "/",
                    vm.toString(fill.gOut)
                )
            );
        }
        // Independent of LadderMath: a fill is never better for the taker than the best level the side's consumed
        // depth leaves, nor than the inventory-path price of its base after that depth.
        if (_beatsBestLevel(fill, g, aIn, aOut)) _violate(Check.Ladder, "fill beats the consumed-offset ladder");
        _checkPath(fill, g, s.exactIn, aIn, aOut);
        // The fill took its base off the side: the next fill on it starts that much deeper.
        if (fill.offset != 0) ++deepFills;
        if (baseIn) g.consumedBids += aIn;
        else g.consumedAsks += aOut;

        if (mid != HotWord.mid(g.hot) || seq != HotWord.seq(g.hot)) {
            _violate(Check.Ladder, "Fill mid or seq differs from the posted word");
        }

        if (_accessFailure(fill.v, fill.p, g.access, s.taker, fill.sponsorId) != 0) {
            _violate(Check.Auth, "filled for a taker the venue's access rejects");
        }

        if (take > aIn) _violate(Check.HookBudget, "hook took more than the fill's input");
        bool hooked = g.hook == address(sys.hook);
        bool window = hooked && g.hookFlags & TAKE != 0;
        if (take != 0 && !window) _violate(Check.HookBudget, "hook took input on a fill without a take window");
        // The hook asks for at most the fill's input, so only a pair without `TAKE_INPUT` may refuse it.
        if (refused && window) _violate(Check.HookBudget, "the venue refused a take within the fill's input");
        if (pull != 0 && !(hooked && g.hookFlags & BEFORE != 0)) {
            _violate(Check.VenueBalance, "hook pulled on a fill without BEFORE_FILL");
        }
    }

    /// @dev The fill against `InventoryPath`, written from the spec's words: the fill's base traded after the side's
    /// consumed depth. The taker never does better than the path's exact value, and a fill that targets base rounds it
    /// once, by less than one quote unit.
    function _checkPath(Request memory fill, PairGhost storage g, bool exactIn, uint256 aIn, uint256 aOut) internal {
        InventoryPath.Side memory side =
            PATH.side(g.hot, g.sizeUnit, ghostShapes[fill.v][fill.p][HotWord.shapeId(g.hot)], fill.baseIn);
        (bool ok, uint256 v) = PATH.valueFrom(side, fill.offset, fill.baseIn ? aIn : aOut);
        if (!ok) {
            _violate(Check.Ladder, "fill ran past the inventory path");
            return;
        }
        if (fill.baseIn) {
            if (aOut * DENOMINATOR > v) _violate(Check.Ladder, "sold base for more than the inventory path pays");
            if (exactIn && aOut != v / DENOMINATOR) {
                _violate(Check.Ladder, "sell exact-in isn't the path value floored");
            }
        } else {
            if (aIn * DENOMINATOR < v) _violate(Check.Ladder, "bought base for less than the inventory path costs");
            if (!exactIn && aIn != (v + DENOMINATOR - 1) / DENOMINATOR) {
                _violate(Check.Ladder, "buy exact-out isn't the path value ceiled");
            }
        }
    }

    /// @dev Whether a fill gave the taker more than the best price the side's consumed depth leaves allows: that of
    /// the inventory path's unit at position `fill.offset`. Selling base, more quote than `amountIn * price / 1e26`;
    /// buying base, paying less than `amountOut * price / 1e26`. A fill with no unit left at its offset beats it.
    function _beatsBestLevel(Request memory fill, PairGhost storage g, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (bool)
    {
        InventoryPath.Side memory side =
            PATH.side(g.hot, g.sizeUnit, ghostShapes[fill.v][fill.p][HotWord.shapeId(g.hot)], fill.baseIn);
        (bool ok, uint256 price) = PATH.priceAt(side, fill.offset);
        if (!ok) return true;
        if (fill.baseIn) return amountOut > Math.mulDiv(amountIn, price, DENOMINATOR);
        return amountIn < Math.mulDiv(amountOut, price, DENOMINATOR, Math.Rounding.Ceil);
    }

    function _checkReverted(Swap memory s, bytes memory err) internal {
        bytes4 sel = _selector(err);
        if (_isAccessError(sel)) {
            ++authRejections;
            if (sel == IVenue.TakerDenied.selector) ++deniedRejections;
            if (sel == IVenue.TakerPriorityFeeTooHigh.selector) ++feeRejections;
            if (
                sel == IVenue.UnknownSponsor.selector || sel == IVenue.SponsorDisabled.selector
                    || sel == IVenue.SponsorNotAdmitted.selector
            ) ++sponsorRejections;
        } else if (sel == IVenue.QuoteExpired.selector) {
            ++expiryRejections;
        } else if (sel == IVenue.InsufficientInventory.selector) {
            ++inventoryRejections;
        } else if (sel == ISettler.InsufficientOutput.selector || sel == ISettler.ExcessiveInput.selector) {
            ++slippageRejections;
        } else if (
            sel == LadderMath.InsufficientDepth.selector || sel == LadderMath.ZeroFill.selector
                || sel == IVenue.SideDisabled.selector
        ) {
            ++ladderRejections;
        } else {
            ++otherRejections;
        }

        bool allowed = s.fail != 0 && sel == s.fail;
        if (!s.atStart && !s.inventoryClear) allowed = allowed || sel == IVenue.InsufficientInventory.selector;
        if (!allowed) {
            _violate(
                Check.Outcome,
                string.concat(
                    "swap reverted with ",
                    _hex(sel),
                    ", ghost predicted ",
                    _hex(s.fail),
                    s.inventoryClear ? " with inventory covered" : " with inventory short"
                )
            );
        }
    }

    function _checkSettlerEmpty() internal {
        for (uint256 t; t < 3; ++t) {
            if (sys.tokens[t].balanceOf(address(sys.settler)) != 0) _violate(Check.Settler, "Settler holds a balance");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Owner and access internals
    // ---------------------------------------------------------------------------------------------------------------

    function _setHook(uint256 r) internal {
        uint16 p = r % 8 == 0 ? 0 : HOOK_PAIR;
        uint8[8] memory choices =
            [uint8(0), BEFORE, VenueHookFlags.AFTER_FILL, BEFORE | VenueHookFlags.AFTER_FILL, 6, ALL, ALL, ALL];
        uint8 flags = choices[(r >> 8) % 8];
        uint256 twist = (r >> 16) % 12;
        address caller = twist == 0 ? updaters[0] : sys.owners[0];
        if (twist == 1) flags = [TAKE, BEFORE | TAKE, 8][(r >> 24) % 3];
        address hook = flags == 0 ? address(0) : address(sys.hook);
        bool valid = twist > 1;

        vm.prank(caller);
        try sys.venues[0].setPairHook(p, hook, flags) {
            if (!valid) _violate(Check.Outcome, "incoherent or unauthorized setPairHook accepted");
            (ghost[0][p].hook, ghost[0][p].hookFlags) = (hook, flags);
        } catch (bytes memory err) {
            if (valid) _violate(Check.Outcome, string.concat("valid setPairHook reverted ", _hex(_selector(err))));
        }
    }

    function _setHookConfig(uint256 r) internal {
        uint256 refill = r % 4 == 0 ? 0 : (r >> 8) % (1_000 * ONE);
        uint256 maxTake = (r >> 72) % 4 == 0 ? 0 : 1 + (r >> 80) % (2_000 * ONE);
        sys.hook.configure(refill, maxTake);
    }

    /// @dev What the hook's `availableLiquidity` reports, or 0 when it reverts, as the venue counts it.
    function _hookLiquidity(address token) internal view returns (uint256) {
        try sys.hook.availableLiquidity(token) returns (uint256 liquidity) {
            return liquidity;
        } catch {
            return 0;
        }
    }

    /// @dev A key lists or delists an account on a sponsor's list for a pair: usually the sponsor's admin, sometimes a
    /// stranger, the venue's owner or another sponsor key, which must be refused (`NotSponsorAdmin`, an unregistered
    /// id's included). A listing also needs the sponsor enabled and admitted on the pair, and an account other than the
    /// venue.
    function _setMembership(uint256 r) internal {
        uint256 v = r % NV;
        uint16 p = uint16((r >> 4) % NP);
        uint64[3] memory ids = [FA, FB, FX];
        uint64 id = ids[(r >> 8) % 3];
        SponsorGhost storage f = sponsorG[v][id];
        uint256 twist = (r >> 16) % 12;
        address account = twist == 0 ? address(sys.venues[v]) : _member(r >> 24);
        bool allowed = (r >> 32) % 3 != 0;
        uint256 who = (r >> 40) % 10;
        address caller =
            who == 0 ? stranger : who == 1 ? sys.owners[v] : who == 2 ? sponsorKeys[(r >> 48) % 3] : f.admin;
        // An unregistered id has no admin; its "admin" draw is a key that isn't one.
        if (caller == address(0)) caller = sponsorKeys[1];
        bytes4 want;
        if (caller != f.admin) want = IVenue.NotSponsorAdmin.selector;
        else if (allowed && !f.enabled) want = IVenue.SponsorDisabled.selector;
        else if (allowed && !admittedG[v][p][id]) want = IVenue.SponsorNotAdmitted.selector;
        else if (twist == 0) want = IVenue.InvalidAddress.selector;
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(caller);
        try sys.venues[v].setMembers(p, id, accounts, allowed) {
            if (want != 0) _violate(Check.Outcome, string.concat("setMembers accepted, want ", _hex(want)));
            memberG[v][p][id][account] = allowed ? f.generation : 0;
        } catch (bytes memory err) {
            if (_selector(err) != want) {
                _violate(Check.Outcome, string.concat("setMembers reverted ", _hex(_selector(err))));
            }
        }
        if (sys.venues[v].isMember(p, id, account) != _isMember(v, p, id, account)) {
            _violate(Check.Ghost, "sponsor membership differs from the ghost");
        }
    }

    /// @dev A sponsor's admin hands its lists to another key, which accepts: on that venue only, and the lists keep
    /// admitting their members. A stranger can't start or cancel one, zero is never a nominee, and only the pending
    /// key accepts. Cancellation leaves the current admin and lists in place.
    function _handOff(uint256 r) internal {
        uint256 v = r % NV;
        uint64 id = (r >> 8) % 4 == 0 ? FB : FA;
        SponsorGhost storage f = sponsorG[v][id];
        address next = (r >> 48) % 8 == 0 ? address(0) : sponsorKeys[(r >> 16) % 3];
        bool byStranger = (r >> 24) % 8 == 0;
        address caller = byStranger || f.admin == address(0) ? stranger : f.admin;
        bytes4 want = caller != f.admin
            ? IVenue.NotSponsorAdmin.selector
            : next == address(0) ? IVenue.InvalidAddress.selector : bytes4(0);
        vm.prank(caller);
        try sys.venues[v].transferSponsorAdmin(id, next) {
            if (want != 0) _violate(Check.Outcome, string.concat("transferSponsorAdmin accepted, want ", _hex(want)));
            f.pending = next;
        } catch (bytes memory err) {
            if (want == 0 || _selector(err) != want) {
                _violate(Check.Outcome, string.concat("transferSponsorAdmin reverted ", _hex(_selector(err))));
            }
        }
        if ((r >> 56) % 3 == 0) {
            address canceller = (r >> 64) % 4 == 0 || f.admin == address(0) ? stranger : f.admin;
            vm.prank(canceller);
            try sys.venues[v].cancelSponsorAdminTransfer(id) {
                if (canceller != f.admin) {
                    _violate(Check.Outcome, "cancelSponsorAdminTransfer accepted from a non-admin");
                }
                f.pending = address(0);
            } catch (bytes memory err) {
                if (canceller == f.admin || _selector(err) != IVenue.NotSponsorAdmin.selector) {
                    _violate(Check.Outcome, string.concat("cancelSponsorAdminTransfer reverted ", _hex(_selector(err))));
                }
            }
        }
        address acceptor = (r >> 32) % 8 == 0 || next == address(0) ? stranger : next;
        vm.prank(acceptor);
        try sys.venues[v].acceptSponsorAdmin(id) {
            if (acceptor != f.pending || f.pending == address(0)) {
                _violate(Check.Outcome, "acceptSponsorAdmin accepted from a key that isn't pending");
            }
            f.admin = acceptor;
            f.pending = address(0);
            ++handoffs;
        } catch (bytes memory err) {
            if (
                (acceptor == f.pending && f.pending != address(0))
                    || _selector(err) != IVenue.NotPendingSponsorAdmin.selector
            ) {
                _violate(Check.Outcome, string.concat("acceptSponsorAdmin reverted ", _hex(_selector(err))));
            }
        }
        _checkSponsor(v, id);
    }

    /// @dev The venue's owner lists or delists an account on a pair's home list; an updater or a sponsor key
    /// (`NotOwner`) or the venue itself as the account (`InvalidAddress`) is refused. A TIP-1022 virtual address is
    /// accepted: the venue resolves nothing, and such an address never calls.
    function _setHome(uint256 r) internal {
        uint256 v = r % NV;
        uint16 p = uint16((r >> 4) % NP);
        uint256 twist = (r >> 8) % 10;
        address account = twist == 0 ? address(sys.venues[v]) : twist == 1 ? virtualAlice : _member(r >> 16);
        address caller = twist == 2 ? updaters[v] : twist == 3 ? sponsorKeys[0] : sys.owners[v];
        bool allowed = (r >> 24) % 3 != 0;
        bytes4 want = twist == 2 || twist == 3
            ? IVenue.NotOwner.selector
            : twist == 0 ? IVenue.InvalidAddress.selector : bytes4(0);
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(caller);
        try sys.venues[v].setMembers(p, HOME, accounts, allowed) {
            if (want != 0) _violate(Check.Outcome, string.concat("setMembers (home) accepted, want ", _hex(want)));
            memberG[v][p][HOME][account] = allowed ? 1 : 0;
        } catch (bytes memory err) {
            if (_selector(err) != want) {
                _violate(Check.Outcome, string.concat("setMembers (home) reverted ", _hex(_selector(err))));
            }
        }
        if (sys.venues[v].isMember(p, HOME, account) != _isMember(v, p, HOME, account)) {
            _violate(Check.Ghost, "home list membership differs from the ghost");
        }
    }

    /// @dev The owner switches a sponsor on or off and admits or removes it on a pair; an updater only narrows (and is
    /// refused the rest with `NotOwner`); a stranger or a sponsor key is refused both (`NotOwnerOrUpdater`). Both need a
    /// registered sponsor (`UnknownSponsor`, the home list's 0 included).
    function _setSponsorSwitch(uint256 r) internal {
        uint256 v = r % NV;
        uint16 p = uint16((r >> 4) % NP);
        uint64[4] memory ids = [FA, FB, FX, HOME];
        uint64 id = ids[(r >> 8) % 8 == 0 ? 3 : (r >> 12) % 3];
        bool on = (r >> 16) % 2 == 0;
        uint256 who = (r >> 24) % 8;
        address caller = who == 0 ? stranger : who == 1 ? sponsorKeys[0] : who < 4 ? updaters[v] : sys.owners[v];
        bool pairSwitch = (r >> 32) % 2 == 0;
        SponsorGhost storage f = sponsorG[v][id];
        bytes4 want;
        if (caller != sys.owners[v] && caller != updaters[v]) want = IVenue.NotOwnerOrUpdater.selector;
        else if (on && caller != sys.owners[v]) want = IVenue.NotOwner.selector;
        else if (f.admin == address(0)) want = IVenue.UnknownSponsor.selector;
        vm.prank(caller);
        if (pairSwitch) {
            try sys.venues[v].setPairSponsor(p, id, on) {
                if (want != 0) _violate(Check.Outcome, string.concat("setPairSponsor accepted, want ", _hex(want)));
                admittedG[v][p][id] = on;
            } catch (bytes memory err) {
                if (_selector(err) != want) {
                    _violate(Check.Outcome, string.concat("setPairSponsor reverted ", _hex(_selector(err))));
                }
            }
            if (id != HOME && sys.venues[v].pairSponsor(p, id) != admittedG[v][p][id]) {
                _violate(Check.Ghost, "admission differs from the ghost");
            }
        } else {
            try sys.venues[v].setSponsorEnabled(id, on) {
                if (want != 0) _violate(Check.Outcome, string.concat("setSponsorEnabled accepted, want ", _hex(want)));
                f.enabled = on;
            } catch (bytes memory err) {
                if (_selector(err) != want) {
                    _violate(Check.Outcome, string.concat("setSponsorEnabled reverted ", _hex(_selector(err))));
                }
            }
            _checkSponsor(v, id);
        }
    }

    /// @dev Rarely, the owner resets a sponsor to a new key with an empty list (an updater is refused, `NotOwner`),
    /// or registers `FX` (refused for a registered id or 0, `SponsorExists`).
    function _resetOrAddSponsor(uint256 r) internal {
        uint256 v = r % NV;
        address key = sponsorKeys[(r >> 8) % 3];
        address caller = (r >> 16) % 6 == 0 ? updaters[v] : sys.owners[v];
        if ((r >> 24) % 2 == 0) {
            uint64 id = (r >> 28) % 3 == 0 ? FB : FA;
            SponsorGhost storage f = sponsorG[v][id];
            bytes4 want = caller != sys.owners[v]
                ? IVenue.NotOwner.selector
                : f.admin == address(0) ? IVenue.UnknownSponsor.selector : bytes4(0);
            vm.prank(caller);
            try sys.venues[v].resetSponsor(id, key) {
                if (want != 0) _violate(Check.Outcome, string.concat("resetSponsor accepted, want ", _hex(want)));
                (f.admin, f.pending) = (key, address(0));
                ++f.generation;
            } catch (bytes memory err) {
                if (_selector(err) != want) {
                    _violate(Check.Outcome, string.concat("resetSponsor reverted ", _hex(_selector(err))));
                }
            }
            _checkSponsor(v, id);
        } else {
            uint64 id = (r >> 28) % 4 == 0 ? HOME : FX;
            SponsorGhost storage f = sponsorG[v][id];
            bytes4 want = caller != sys.owners[v]
                ? IVenue.NotOwner.selector
                : id == HOME || f.admin != address(0) ? IVenue.SponsorExists.selector : bytes4(0);
            vm.prank(caller);
            try sys.venues[v].addSponsor(id, key) {
                if (want != 0) _violate(Check.Outcome, string.concat("addSponsor accepted, want ", _hex(want)));
                (f.admin, f.enabled, f.generation) = (key, true, 1);
            } catch (bytes memory err) {
                if (_selector(err) != want) {
                    _violate(Check.Outcome, string.concat("addSponsor reverted ", _hex(_selector(err))));
                }
            }
            _checkSponsor(v, id);
        }
    }

    /// @dev The venue's record of the sponsor must be the ghost's.
    function _checkSponsor(uint256 v, uint64 id) internal {
        SponsorGhost storage f = sponsorG[v][id];
        (address admin, bool enabled, uint32 generation) = sys.venues[v].sponsor(id);
        if (
            admin != f.admin || enabled != f.enabled || generation != f.generation
                || sys.venues[v].pendingSponsorAdmin(id) != f.pending
        ) _violate(Check.Ghost, "sponsor differs from the ghost");
    }

    /// @dev The owner denies or lifts, an updater denies (and is refused a lift), a stranger is refused; the venue
    /// itself is refused as an account. `deniedCount` must stay the ghost's count.
    function _setDenied(uint256 r) internal {
        uint256 v = r % NV;
        uint256 twist = (r >> 8) % 12;
        address account = twist == 0 ? address(sys.venues[v]) : _member(r >> 16);
        bool deny = (r >> 24) % 2 == 0;
        uint256 who = (r >> 32) % 8;
        address caller = who == 0 ? stranger : who < 3 ? updaters[v] : sys.owners[v];
        bytes4 want = caller == stranger
            ? IVenue.NotOwnerOrUpdater.selector
            : !deny && caller != sys.owners[v]
                ? IVenue.NotOwner.selector
                : twist == 0 ? IVenue.InvalidAddress.selector : bytes4(0);
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(caller);
        try sys.venues[v].setDenied(accounts, deny) {
            if (want != 0) {
                _violate(Check.Outcome, string.concat("setDenied accepted, want ", _hex(want)));
            } else if (deniedG[v][account] != deny) {
                deniedG[v][account] = deny;
                if (deny) ++deniedCountG[v];
                else --deniedCountG[v];
            }
        } catch (bytes memory err) {
            if (_selector(err) != want) {
                _violate(Check.Outcome, string.concat("setDenied reverted ", _hex(_selector(err))));
            }
        }
        if (sys.venues[v].deniedCount() != deniedCountG[v]) {
            _violate(Check.Ghost, "deniedCount differs from the ghost");
        }
        if (sys.venues[v].denied(account) != deniedG[v][account]) {
            _violate(Check.Ghost, "denial differs from the ghost");
        }
    }

    /// @dev The owner sets a pair's mode: `Open` only while halted (`NotHalted`), never `None`; an updater is refused.
    function _setPairAccess(uint256 r) internal {
        uint256 v = r % NV;
        uint16 p = uint16((r >> 8) % NP);
        uint256 k = (r >> 16) % 10;
        IVenue.AccessMode mode = k < 4
            ? IVenue.AccessMode.Listed
            : k < 6 ? IVenue.AccessMode.Closed : k < 9 ? IVenue.AccessMode.Open : IVenue.AccessMode.None;
        bool byUpdater = (r >> 24) % 6 == 0;
        IVenue.AccessMode current = ghost[v][p].access;
        bytes4 want = byUpdater
            ? IVenue.NotOwner.selector
            : mode == current
                ? bytes4(0)
                : mode == IVenue.AccessMode.None
                    ? IVenue.InvalidAccessMode.selector
                    : mode == IVenue.AccessMode.Open && !ghostHalted[v] ? IVenue.NotHalted.selector : bytes4(0);
        vm.prank(byUpdater ? updaters[v] : sys.owners[v]);
        try sys.venues[v].setPairAccess(p, mode) {
            if (want != 0) _violate(Check.Outcome, string.concat("setPairAccess accepted, want ", _hex(want)));
            ghost[v][p].access = mode;
        } catch (bytes memory err) {
            if (_selector(err) != want) {
                _violate(Check.Outcome, string.concat("setPairAccess reverted ", _hex(_selector(err))));
            }
        }
    }

    function _closePair(uint256 r) internal {
        uint256 v = r % NV;
        uint16 p = uint16((r >> 8) % NP);
        vm.prank((r >> 16) % 2 == 0 ? updaters[v] : sys.owners[v]);
        try sys.venues[v].closePair(p) {
            ghost[v][p].access = IVenue.AccessMode.Closed;
        } catch (bytes memory err) {
            _violate(Check.Outcome, string.concat("closePair reverted ", _hex(_selector(err))));
        }
    }

    /// @dev The owner points the venue at another settler, or back at the real one; the updater can't.
    function _setSettler(uint256 r) internal {
        uint256 v = r % NV;
        bool byUpdater = (r >> 8) % 4 == 0;
        address target = settlerMoved[v] ? address(sys.settler) : NOT_A_VENUE;
        vm.prank(byUpdater ? updaters[v] : sys.owners[v]);
        try sys.venues[v].setSettler(target) {
            if (byUpdater) _violate(Check.Custody, "updater repointed the settler");
            settlerMoved[v] = !settlerMoved[v];
        } catch (bytes memory err) {
            if (!byUpdater || _selector(err) != IVenue.NotOwner.selector) {
                _violate(Check.Outcome, string.concat("setSettler reverted ", _hex(_selector(err))));
            }
        }
    }

    /// @dev The owner or an updater sets any taker priority-fee cap, raising, lowering or removing it, or enables the
    /// default (`enableTakerPriorityFeeCap`); anyone else is refused (`NotOwnerOrUpdater`). `maxTakerPriorityFee` must
    /// then read the ghost's cap.
    function _setFeeCap(uint256 r) internal {
        uint256 v = r % NV;
        uint256 who = (r >> 8) % 8;
        address caller = who == 0 ? stranger : who < 4 ? updaters[v] : sys.owners[v];
        uint256 kind = (r >> 16) % 5;
        uint64 cap = kind == 0 ? NO_CAP : kind == 4 ? DEFAULT_CAP : uint64((r >> 24) % 3) * 1 gwei;
        bytes memory data = kind == 4
            ? abi.encodeCall(IVenue.enableTakerPriorityFeeCap, ())
            : abi.encodeCall(IVenue.setMaxTakerPriorityFee, (cap));
        string memory name = kind == 4 ? "enableTakerPriorityFeeCap" : "setMaxTakerPriorityFee";
        bytes4 want = caller == stranger ? IVenue.NotOwnerOrUpdater.selector : bytes4(0);
        vm.prank(caller);
        (bool ok, bytes memory err) = address(sys.venues[v]).call(data);
        if (ok) {
            if (want != 0) {
                _violate(Check.Outcome, string.concat(name, " accepted, want ", _hex(want)));
            } else {
                feeCapG[v] = cap;
            }
        } else if (_selector(err) != want) {
            _violate(Check.Outcome, string.concat(name, " reverted ", _hex(_selector(err))));
        }
        if (sys.venues[v].maxTakerPriorityFee() != feeCapG[v]) _violate(Check.Ghost, "fee cap differs from the ghost");
    }

    function _setHalted(uint256 r, uint256 kind) internal {
        uint256 v = r % NV;
        bool halt = kind == 16;
        bool byUpdater = (r >> 8) % 4 == 0;
        vm.prank(byUpdater ? updaters[v] : sys.owners[v]);
        try sys.venues[v].setHalted(halt) {
            if (!halt && byUpdater) _violate(Check.Outcome, "updater unhalted a venue");
            ghostHalted[v] = halt;
        } catch (bytes memory err) {
            if (halt || !byUpdater || _selector(err) != IVenue.NotOwner.selector) {
                _violate(Check.Outcome, string.concat("setHalted reverted ", _hex(_selector(err))));
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Probes
    // ---------------------------------------------------------------------------------------------------------------

    function _matches(PairGhost storage g, address a, address b) internal view returns (bool) {
        return (g.base == a && g.quote == b) || (g.base == b && g.quote == a);
    }

    function _probeToken(uint256 r) internal view returns (address) {
        uint256 k = r % 5;
        return k < 3 ? address(sys.tokens[k]) : k == 3 ? address(sys.venues[0]) : address(uint160(r >> 8));
    }

    function _probeTaker(uint256 r) internal view returns (address) {
        uint256 k = r % 7;
        return k < 3 ? takers[k] : k == 3 ? alice : k == 4 ? bob : k == 5 ? address(0) : address(uint160(r >> 8));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ghost helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _begin() internal {
        ++calls;
        vm.warp(time);
    }

    /// @dev After every action: seq never decreases, every hot word is the last one the ghost accepted, and each
    /// side's consumed depth is the ghost's and fell only where the venue emitted a `Refilled` for it.
    function _end() internal {
        for (uint256 v; v < NV; ++v) {
            for (uint16 p; p < NP; ++p) {
                bytes32 word = sys.venues[v].hotWord(p);
                uint32 seq = HotWord.seq(word);
                if (seq < seenSeq[v][p]) _violate(Check.Seq, "a pair's seq decreased");
                seenSeq[v][p] = seq;
                if (word != ghost[v][p].hot) _violate(Check.Ghost, "hot word differs from the last accepted post");
                (uint128 bids, uint128 asks) = sys.venues[v].consumed(p);
                if (bids != ghost[v][p].consumedBids || asks != ghost[v][p].consumedAsks) {
                    _violate(Check.Depth, "consumed depth differs from the ghost");
                }
                uint256[2] memory now_ = [uint256(bids), uint256(asks)];
                for (uint256 side; side < 2; ++side) {
                    if (now_[side] < seenConsumed[v][p][side] && !refilledSince[v][p][side]) {
                        _violate(Check.Depth, "consumed depth fell without a refill");
                    }
                    seenConsumed[v][p][side] = now_[side];
                    refilledSince[v][p][side] = false;
                }
            }
        }
    }

    /// @dev The venue's `Refilled` events in `logs`, each recorded against the sides it names for `_end`'s check.
    function _countRefills(uint256 v, Vm.Log[] memory logs) internal returns (uint256 count) {
        for (uint256 j; j < logs.length; ++j) {
            Vm.Log memory lg = logs[j];
            if (lg.topics.length == 0 || lg.topics[0] != IVenue.Refilled.selector) continue;
            if (lg.emitter != address(sys.venues[v])) continue;
            uint256 p = uint256(lg.topics[1]);
            (bool bids, bool asks) = abi.decode(lg.data, (bool, bool));
            if (p < NP) {
                if (bids) refilledSince[v][p][0] = true;
                if (asks) refilledSince[v][p][1] = true;
            }
            ++count;
        }
    }

    /// @dev An accepted entry's refill bits: the sides they name start over from the ladder's first level.
    function _applyRefill(uint256 v, uint16 p, uint16 bits) internal {
        if (bits == 0) return;
        ++refills;
        if (bits & HotWord.FLAG_REFILL_BIDS != 0) ghost[v][p].consumedBids = 0;
        if (bits & HotWord.FLAG_REFILL_ASKS != 0) ghost[v][p].consumedAsks = 0;
    }

    function _addPair(uint256 v, uint256 base, uint256 quote, uint64 sizeUnit, uint96 anchor) internal {
        vm.prank(sys.owners[v]);
        uint16 p = sys.venues[v].addPair(address(sys.tokens[base]), address(sys.tokens[quote]), sizeUnit);
        PairGhost storage g = ghost[v][p];
        (g.base, g.quote, g.sizeUnit, g.access, g.hot, g.anchor) =
        (
            address(sys.tokens[base]),
            address(sys.tokens[quote]),
            sizeUnit,
            IVenue.AccessMode.Closed,
            HotWord.INITIAL,
            anchor
        );
        seenSeq[v][p] = 1;
    }

    function _bootSponsor(uint256 v, uint64 sponsorId, address admin) internal {
        vm.prank(sys.owners[v]);
        sys.venues[v].addSponsor(sponsorId, admin);
        sponsorG[v][sponsorId] = SponsorGhost({ admin: admin, pending: address(0), enabled: true, generation: 1 });
    }

    /// @dev Admits the sponsor on the venue's pair 0.
    function _bootAdmit(uint256 v, uint64 sponsorId) internal {
        vm.prank(sys.owners[v]);
        sys.venues[v].setPairSponsor(0, sponsorId, true);
        admittedG[v][0][sponsorId] = true;
    }

    /// @dev The sponsor's admin lists `account` on the venue's pair 0.
    function _bootMember(uint256 v, uint64 sponsorId, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(sponsorG[v][sponsorId].admin);
        sys.venues[v].setMembers(0, sponsorId, accounts, true);
        memberG[v][0][sponsorId][account] = sponsorG[v][sponsorId].generation;
    }

    function _bootDeny(uint256 v, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(sys.owners[v]);
        sys.venues[v].setDenied(accounts, true);
        deniedG[v][account] = true;
        ++deniedCountG[v];
    }

    /// @dev The owner lists `account` on the home list of the venue's pair 0.
    function _bootHome(uint256 v, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(sys.owners[v]);
        sys.venues[v].setMembers(0, HOME, accounts, true);
        memberG[v][0][HOME][account] = 1;
    }

    /// @dev Sets a pair's mode, halting around it for `Open`.
    function _bootAccess(uint256 v, uint16 p, IVenue.AccessMode mode) internal {
        vm.startPrank(sys.owners[v]);
        if (mode == IVenue.AccessMode.Open) sys.venues[v].setHalted(true);
        sys.venues[v].setPairAccess(p, mode);
        if (mode == IVenue.AccessMode.Open) sys.venues[v].setHalted(false);
        vm.stopPrank();
        ghost[v][p].access = mode;
    }

    function _bootShape(uint256 v, uint16 p, uint8 shapeId, uint256[4] memory words) internal {
        vm.prank(sys.owners[v]);
        sys.venues[v].setShape(p, shapeId, words);
        ghostShapes[v][p][shapeId] = words;
    }

    function _candidates(uint256 a, uint256 b)
        internal
        view
        returns (uint256[6] memory cv, uint16[6] memory cp, uint256 n)
    {
        for (uint256 v; v < NV; ++v) {
            for (uint16 p; p < NP; ++p) {
                if (_matches(ghost[v][p], address(sys.tokens[a]), address(sys.tokens[b]))) {
                    (cv[n], cp[n]) = (v, p);
                    ++n;
                }
            }
        }
    }

    /// @dev The venue's access check, from the ghost and the current transaction's fees, in the venue's order: a pair
    /// that isn't live (`None`), a priority fee above the venue's cap, a `Closed` pair, a denial, `Open`, then the
    /// list the swap names on the pair: the home list (0), or a sponsor that must be registered, enabled and admitted,
    /// and must hold the taker on its current list. Never `TakerAccess.None`, which the venue never returns either.
    function _accessOutcome(uint256 v, uint16 p, IVenue.AccessMode access, address taker_, uint64 sponsorId)
        internal
        view
        returns (IVenue.TakerAccess)
    {
        if (access == IVenue.AccessMode.None) return IVenue.TakerAccess.UnknownPair;
        if (_feeTooHigh(v)) return IVenue.TakerAccess.PriorityFeeTooHigh;
        if (access == IVenue.AccessMode.Closed) return IVenue.TakerAccess.Closed;
        if (deniedG[v][taker_]) return IVenue.TakerAccess.Denied;
        if (access == IVenue.AccessMode.Open) return IVenue.TakerAccess.Allowed;
        if (sponsorId != HOME) {
            SponsorGhost storage f = sponsorG[v][sponsorId];
            if (f.admin == address(0)) return IVenue.TakerAccess.UnknownSponsor;
            if (!f.enabled) return IVenue.TakerAccess.SponsorDisabled;
            if (!admittedG[v][p][sponsorId]) return IVenue.TakerAccess.SponsorNotAdmitted;
        }
        return _isMember(v, p, sponsorId, taker_) ? IVenue.TakerAccess.Allowed : IVenue.TakerAccess.NotListed;
    }

    /// @dev The error `fill` reverts with for the ghost's access outcome, or 0 when it admits the taker.
    function _accessFailure(uint256 v, uint16 p, IVenue.AccessMode access, address taker_, uint64 sponsorId)
        internal
        view
        returns (bytes4)
    {
        IVenue.TakerAccess outcome = _accessOutcome(v, p, access, taker_, sponsorId);
        if (outcome == IVenue.TakerAccess.Allowed) return 0;
        if (outcome == IVenue.TakerAccess.UnknownPair) return IVenue.UnknownPair.selector;
        if (outcome == IVenue.TakerAccess.PriorityFeeTooHigh) return IVenue.TakerPriorityFeeTooHigh.selector;
        if (outcome == IVenue.TakerAccess.Denied) return IVenue.TakerDenied.selector;
        if (outcome == IVenue.TakerAccess.UnknownSponsor) return IVenue.UnknownSponsor.selector;
        if (outcome == IVenue.TakerAccess.SponsorDisabled) return IVenue.SponsorDisabled.selector;
        if (outcome == IVenue.TakerAccess.SponsorNotAdmitted) return IVenue.SponsorNotAdmitted.selector;
        return IVenue.TakerNotAllowed.selector;
    }

    /// @dev Whether `account` is on the sponsor's current list for the pair: listed in its current generation (the
    /// home list's is always 1).
    function _isMember(uint256 v, uint16 p, uint64 sponsorId, address account) internal view returns (bool) {
        uint32 generation = sponsorId == HOME ? 1 : sponsorG[v][sponsorId].generation;
        return generation != 0 && memberG[v][p][sponsorId][account] == generation;
    }

    /// @dev Whether the venue has a taker priority-fee cap the current transaction's priority fee is above: its gas
    /// price less the base fee, 0 below the base fee.
    function _feeTooHigh(uint256 v) internal view returns (bool) {
        uint256 tip = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
        return feeCapG[v] != NO_CAP && tip > feeCapG[v];
    }

    /// @dev Sets this transaction's base fee and gas price: usually no priority fee, sometimes a gas price below the
    /// base fee, and sometimes a priority fee one wei below, at or one wei above a cap `_setFeeCap` sets (0, 1 or 2
    /// gwei, or the 10 gwei default).
    function _drawFee(uint256 r) internal {
        uint256 baseFee = (r & 3) * 0.3 gwei;
        vm.fee(baseFee);
        uint256 kind = (r >> 2) % 8;
        if (kind < 4) {
            vm.txGasPrice(baseFee);
        } else if (kind == 4) {
            vm.txGasPrice(baseFee / 2);
        } else {
            uint256 level = (r >> 5) % 4;
            uint256 tip = (level == 3 ? DEFAULT_CAP : level * 1 gwei) + (r >> 7) % 3;
            vm.txGasPrice(baseFee + (tip == 0 ? 0 : tip - 1));
        }
    }

    function _isAccessError(bytes4 sel) internal pure returns (bool) {
        return sel == IVenue.TakerPriorityFeeTooHigh.selector || sel == IVenue.TakerNotAllowed.selector
            || sel == IVenue.TakerDenied.selector || sel == IVenue.UnknownSponsor.selector
            || sel == IVenue.SponsorDisabled.selector || sel == IVenue.SponsorNotAdmitted.selector;
    }

    function _member(uint256 r) internal view returns (address) {
        uint256 k = r % 5;
        return k < 3 ? takers[k] : k == 3 ? alice : bob;
    }

    function _venueIndex(address account) internal view returns (uint256) {
        for (uint256 v; v < NV; ++v) {
            if (account == address(sys.venues[v])) return v;
        }
        return NV;
    }

    function _mint(uint256 t, address to, uint256 amount) internal {
        sys.tokens[t].mint(to, amount);
        mintedTotal[t] += amount;
    }

    function _violate(Check check, string memory what) internal {
        uint256 i = uint256(check);
        if (violationCount[i]++ == 0) firstViolationOf[i] = what;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Random curves
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A well-formed hot word for `post`: mid near the pair's anchor (rarely anywhere in uint96), random widen,
    /// width and depth (sometimes 0), shape 0-3, a TTL of 1-60 min (sometimes 0 or already past), a seq that is usually
    /// fresh and sometimes stale, occasionally a side switched off, and a refill of one side or both on about one word
    /// in three.
    function _randomHot(uint256 v, uint16 p, uint256 r, uint32 seq) internal view returns (bytes32) {
        HotWord.Fields memory f;
        uint256 anchor = ghost[v][p].anchor;
        f.mid = r % 64 == 0 ? uint96(1 + (r >> 8) % type(uint96).max) : uint96(anchor * (900 + (r >> 8) % 201) / 1000);
        f.bidWiden = uint16((r >> 40) % 100);
        f.askWiden = uint16((r >> 56) % 100);
        f.widthScale = uint16((r >> 72) % 3001);
        f.depthScale = (r >> 88) % 32 == 0 ? uint16(0) : uint16(1 + (r >> 96) % 3000);
        uint256 s = (r >> 112) % 20;
        f.shapeId = uint8(s < 10 ? 0 : s < 15 ? 1 : s < 19 ? 2 : 3);
        uint256 ttl = (r >> 120) % 32;
        f.validUntil = ttl < 2
            ? uint40(time - 1 - (r >> 124) % 100)
            : ttl == 2 ? uint40(time) : uint40(time + 60 + (r >> 128) % 3541);
        uint256 d = (r >> 144) % 8;
        f.seq = d == 0 ? seq : d == 1 ? seq - 1 : seq + uint32(d - 1);
        f.flags = (r >> 160) % 16 == 0 ? uint16(1 + (r >> 168) % 3) : uint16(0);
        if ((r >> 176) % 3 == 0) f.flags |= uint16(1 + (r >> 184) % 3) << 2;
        return HotWord.pack(f);
    }

    /// @dev A canonical side of 0-10 levels: sizes of 1-1000 whole tokens (rarely the uint32 maximum), spreads that
    /// never decrease and occasionally jump far enough to reach the bid floor.
    function _randomSide(uint256 r, uint256 scale) internal pure returns (uint256 w0, uint256 w1) {
        uint256 n = r % 11;
        uint32[] memory sizes = new uint32[](n);
        uint16[] memory spreads = new uint16[](n);
        uint256 spread = (r >> 8) % 20;
        for (uint256 i; i < n; ++i) {
            uint256 ri = uint256(keccak256(abi.encode(r, i)));
            sizes[i] = ri % 50 == 0 ? type(uint32).max : uint32((1 + (ri >> 8) % 1000) * scale);
            spread += (ri >> 32) % 30;
            if ((ri >> 64) % 40 == 0) spread += 20_000;
            if (spread > type(uint16).max) spread = type(uint16).max;
            spreads[i] = uint16(spread);
        }
        return ShapeWord.packSide(sizes, spreads);
    }

    function _defaultShape(uint256 scale) internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](6);
        uint16[] memory spreads = new uint16[](6);
        uint32[6] memory bidSizes = [uint32(100), 200, 300, 400, 500, 1000];
        uint16[6] memory bidSpreads = [uint16(2), 5, 10, 20, 40, 80];
        for (uint256 i; i < 6; ++i) {
            (sizes[i], spreads[i]) = (uint32(bidSizes[i] * scale), bidSpreads[i]);
        }
        (words[0], words[1]) = ShapeWord.packSide(sizes, spreads);

        sizes = new uint32[](7);
        spreads = new uint16[](7);
        uint32[7] memory askSizes = [uint32(50), 100, 150, 200, 300, 500, 1000];
        uint16[7] memory askSpreads = [uint16(1), 3, 6, 12, 25, 50, 100];
        for (uint256 i; i < 7; ++i) {
            (sizes[i], spreads[i]) = (uint32(askSizes[i] * scale), askSpreads[i]);
        }
        (words[2], words[3]) = ShapeWord.packSide(sizes, spreads);
    }

    /// @dev Ten levels a side, so both sides run into their second word.
    function _deepShape(uint256 scale) internal pure returns (uint256[4] memory words) {
        uint32[] memory sizes = new uint32[](10);
        uint16[] memory spreads = new uint16[](10);
        for (uint256 i; i < 10; ++i) {
            (sizes[i], spreads[i]) = (uint32((i + 1) * 100 * scale), uint16(4 * i * i));
        }
        (words[0], words[1]) = ShapeWord.packSide(sizes, spreads);
        (words[2], words[3]) = (words[0], words[1]);
    }

    function _flatShape(uint32 size, uint16 spread) internal pure returns (uint256[4] memory words) {
        (words[0], words[1]) = _levels2(size, spread, 0, 0);
        (words[2], words[3]) = (words[0], words[1]);
    }

    /// @dev A side of up to two raw levels, packed without validation (for invalid shapes too).
    function _levels2(uint32 size0, uint16 spread0, uint32 size1, uint16 spread1)
        internal
        pure
        returns (uint256 w0, uint256 w1)
    {
        w0 = uint256(size0) | (uint256(spread0) << 32) | (uint256(size1) << 48) | (uint256(spread1) << 80);
        w1 = 0;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Utilities
    // ---------------------------------------------------------------------------------------------------------------

    function _rand(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _selector(bytes memory err) internal pure returns (bytes4) {
        return err.length < 4 ? bytes4(0) : bytes4(err);
    }

    function _hex(bytes4 sel) internal pure returns (string memory) {
        return vm.toString(abi.encodePacked(sel));
    }

    /// @dev A TIP-1022 virtual address: 4 bytes, then ten 0xFD bytes, then a 6-byte id.
    function _virtual(uint32 prefix, uint48 id) internal pure returns (address) {
        return address(uint160((uint256(prefix) << 128) | (uint256(0xFDFDFDFDFDFDFDFDFDFD) << 48) | uint256(id)));
    }
}
