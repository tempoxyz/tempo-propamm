// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";
import { MockVirtualAddressRegistry } from "../../v2/mocks/MockVirtualAddressRegistry.sol";
import { VirtualAddress } from "../../v2/utils/VirtualAddress.sol";

/// @notice Drives a `ManagedDirectPropAMM` with up to five pairs over three tokens, each shared by two or more pairs,
/// through every access call from every role (with bad entries, unknown ids and unknown pairs), the pool-wide pause,
/// pair modes and removals, new pairs, risk settings and anchor resets on closed pairs, oracle moves and clock jumps,
/// swaps from fuzzed accounts under fuzzed sponsor ids and priority fees, and `fund` and `withdraw` (which pays no
/// TIP-1022 virtual address, whatever the registry says).
/// @dev Every call's outcome is predicted from ghost state that mirrors only the calls the handler saw accepted, never
/// from the pool's views, and is asserted exactly: the same success, or the same revert bytes. A swap's prediction
/// runs the managed access check on the ghost, then the oracle and deviation checks on the pair's own oracle
/// and ghost anchors; only the amounts come from the pool's `quote*For` views, whose pricing the v1 differential holds
/// to `DirectPropAMM`. Each fill must move exactly its amounts between the pool and its caller and nothing for anyone
/// else, and leave every other pair's anchors and every other route's credit as they were. Only the owner may change
/// pool emergency controls; sponsor admins retain their own list authority.
contract ManagedPoolHandler is Test {
    uint256 internal constant BASE_FEE = 7;
    uint16 public constant MAX_PAIRS = 5;
    uint256 public constant NPARTIES = 6;
    uint256 public constant NIDS = 5;
    uint64 internal constant HOME = 0;
    uint64 internal constant S1 = 7;
    uint64 internal constant S2 = 9;
    uint64 internal constant S3 = 11;
    uint64 internal constant UNREGISTERED = 4242;
    uint256 internal constant BPS = 10_000;
    bytes32 public constant CUSTOMER_A = bytes32("customer-a");
    bytes32 public constant CUSTOMER_B = bytes32("customer-b");

    ManagedDirectPropAMM public immutable pool;
    /// @dev The tokens' TIP-1022 resolver, not the pool's: it has none.
    MockVirtualAddressRegistry public immutable registry;
    address public immutable owner;
    address public immutable adminA;
    address public immutable adminB;
    address public immutable candidate;
    address public immutable stranger;
    address public immutable treasury;
    address public immutable master;
    /// @dev A virtual address registered to `master`, one registered to no one, and one whose master is the pool: the
    /// tokens forward a transfer to the first to `master`, but the pool pays none of them.
    address public immutable virtualRecipient;
    address public immutable unregisteredVirtual;
    address public immutable poolVirtual;

    MockTIP20[3] internal _tokens;
    MockTIP20 public immutable stray;
    MockOracle[3] internal _oracles;
    address[NPARTIES] internal _parties;
    uint64[NIDS] internal _ids;

    // ---------------------------------------------------------------- ghost state

    struct GhostPair {
        bool live;
        address base;
        address quote;
        MockOracle oracle;
        uint256 maxAge;
        uint256 deviationBps;
        uint256 scale;
        IManagedDirectPropAMM.AccessMode mode;
        uint256[2] anchors;
        uint256 maxObservedPrice;
    }

    mapping(uint16 pairIndex => GhostPair) internal _pairs;
    uint16 public ghostPairCount;
    bool public ghostPaused;
    mapping(address account => bool) public ghostDenied;
    mapping(uint64 sponsorId => address) public ghostAdmin;
    mapping(uint64 sponsorId => bool) public ghostEnabled;
    mapping(uint64 sponsorId => uint32) public ghostGeneration;
    mapping(uint64 sponsorId => address) public ghostPending;
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => bool)) public ghostAdmitted;
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => mapping(address account => uint32))) public ghostMember;
    mapping(address token => uint256) public ghostPoolBalance;
    mapping(address token => uint256) public ghostMinted;
    mapping(bytes32 routeKey => uint256) public ghostCredit;
    mapping(uint256 oracleIndex => uint256) internal _basePrice;

    // ---------------------------------------------------------------- coverage

    /// @dev Fills by the list they named, refusals by `TakerAccess` value, and swaps refused after access.
    uint256 public homeFills;
    uint256 public sponsorFills;
    uint256 public openFills;
    uint256[9] internal _refusals;
    uint256 public pricingRefusals;
    uint256 public inventoryRefusals;
    uint256 public pausedRefusals;
    /// @dev Per op: accepted and refused calls.
    uint256[20] internal _accepted;
    uint256[20] internal _refused;
    /// @dev Owner withdrawals refused because the recipient is a virtual address.
    uint256 public virtualRefusals;
    /// @dev Pairs that entered `Open` while the pool traded; must stay 0.
    uint256 public openedWhileActive;

    constructor(
        ManagedDirectPropAMM pool_,
        MockVirtualAddressRegistry registry_,
        address owner_,
        MockTIP20[3] memory tokens_,
        MockTIP20 stray_,
        MockOracle[3] memory oracles_,
        uint256[3] memory basePrices_
    ) {
        pool = pool_;
        registry = registry_;
        owner = owner_;
        adminA = makeAddr("adminA");
        adminB = makeAddr("adminB");
        candidate = makeAddr("candidate");
        stranger = makeAddr("stranger");
        treasury = makeAddr("treasury");
        master = makeAddr("bridgeMaster");
        virtualRecipient = VirtualAddress.make(0x0badf00d, 1);
        unregisteredVirtual = VirtualAddress.make(0x0000beef, 2);
        poolVirtual = VirtualAddress.make(0x00c0ffee, 3);
        _tokens = tokens_;
        stray = stray_;
        _oracles = oracles_;
        for (uint256 i; i < 3; ++i) {
            _basePrice[i] = basePrices_[i];
        }
        _parties = [makeAddr("t0"), makeAddr("t1"), makeAddr("t2"), makeAddr("t3"), adminA, stranger];
        _ids = [HOME, S1, S2, S3, UNREGISTERED];
    }

    /// @notice Called once by the test after it built the pool, so the ghost starts where the pool does.
    function seed(uint16 pairs, uint256[3] memory scales, uint256 maxAge, uint256 deviationBps) external {
        registry.setVirtual(virtualRecipient, master);
        registry.setVirtual(poolVirtual, address(pool));
        // Pair 0: A/Q on oracle 0; pair 1: B/Q on oracle 1; pair 2: A/B on oracle 2.
        uint8[2][3] memory combos = [[0, 2], [1, 2], [0, 1]];
        for (uint16 p; p < pairs; ++p) {
            GhostPair storage g = _pairs[p];
            g.live = true;
            g.base = address(_tokens[combos[p][0]]);
            g.quote = address(_tokens[combos[p][1]]);
            g.oracle = _oracles[p];
            g.maxAge = maxAge;
            g.deviationBps = deviationBps;
            g.scale = scales[p];
            g.mode = IManagedDirectPropAMM.AccessMode.Closed;
        }
        ghostPairCount = pairs;
        ghostPaused = true;
        for (uint256 t; t < 3; ++t) {
            address token = address(_tokens[t]);
            ghostPoolBalance[token] = MockTIP20(token).balanceOf(address(pool));
            ghostMinted[token] = ghostPoolBalance[token];
            for (uint256 i; i < NPARTIES; ++i) {
                _mint(MockTIP20(token), _parties[i], 1e30);
                vm.prank(_parties[i]);
                MockTIP20(token).approve(address(pool), type(uint256).max);
            }
            vm.prank(owner);
            MockTIP20(token).approve(address(pool), type(uint256).max);
        }
        vm.prank(owner);
        stray.approve(address(pool), type(uint256).max);
    }

    // =================================================================================================================
    // Handler calls
    // =================================================================================================================

    /// @notice A swap from a fuzzed party on a fuzzed pair (or an unknown index), under a fuzzed sponsor id and
    /// priority fee, either direction, exact in or exact out.
    function swap(
        uint256 fromSeed,
        uint256 pairSeed,
        uint256 idSeed,
        bool baseToQuote,
        bool exactInput,
        uint256 amountSeed
    ) public {
        address from = _parties[fromSeed % NPARTIES];
        uint16 p = uint16(pairSeed % (ghostPairCount + 1));
        uint64 id = [HOME, S1, HOME, S1, S2, S3, UNREGISTERED, S2][idSeed % 8];
        bytes32 customer =
            (amountSeed >> 200) % 24 == 0 ? bytes32(0) : (amountSeed >> 210) % 2 == 0 ? CUSTOMER_A : CUSTOMER_B;
        vm.fee(BASE_FEE);
        uint256[5] memory prices = [BASE_FEE, BASE_FEE, BASE_FEE - 2, BASE_FEE + 1, BASE_FEE + 3];
        vm.txGasPrice(prices[(fromSeed >> 8) % prices.length]);

        GhostPair storage g = _pairs[p];
        Trade memory t;
        t.from = from;
        t.p = p;
        t.id = id;
        t.customer = customer;
        t.baseToQuote = baseToQuote;
        t.exactInput = exactInput;
        t.tokenIn = MockTIP20(baseToQuote ? g.base : g.quote);
        t.tokenOut = MockTIP20(baseToQuote ? g.quote : g.base);
        if (g.live) {
            uint256 unit = 10 ** (exactInput ? t.tokenIn : t.tokenOut).decimals();
            t.amount = amountSeed % 32 == 0 ? 0 : 1 + amountSeed % (5_000 * unit);
            (t.price,) = g.oracle.latestPrice();
        } else {
            t.amount = 1 + amountSeed % 1e9;
        }
        bytes memory expected = _predictSwap(t);
        _runSwap(t, expected);
    }

    /// @notice An exact-input swap by a party the starting lists hold, under the list that holds it: t0 and t1 under
    /// the home list, t2 under S1. (Extra selectors, so swaps are a larger share of the campaign.)
    function swapListed(uint256 fromSeed, uint256 pairSeed, bool baseToQuote, uint256 amountSeed) external {
        uint256 who = fromSeed % 3;
        swap(who, pairSeed, who == 2 ? 1 : 0, baseToQuote, true, amountSeed);
    }

    /// @notice An exact-output swap, as `swapListed`.
    function swapListedExactOut(uint256 fromSeed, uint256 pairSeed, bool baseToQuote, uint256 amountSeed) external {
        uint256 who = fromSeed % 3;
        swap(who, pairSeed, who == 2 ? 1 : 0, baseToQuote, false, amountSeed);
    }

    /// @notice `setDenied` from a fuzzed caller on up to four parties (repeats allowed), sometimes with a bad entry.
    function setDenied(uint256 callerSeed, uint256 entrySeed, bool deny, uint256 badSeed) external {
        address caller = _caller(callerSeed, owner);
        address[] memory accounts = _partyBatch(entrySeed, badSeed);
        bytes memory expected;
        if (caller != owner) expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        if (expected.length == 0 && _hasBadEntry(accounts)) {
            expected = _err(IManagedDirectPropAMM.InvalidAddress.selector);
        }
        if (_run(0, caller, abi.encodeCall(IManagedDirectPropAMM.setDenied, (accounts, deny)), expected)) {
            for (uint256 i; i < accounts.length; ++i) {
                ghostDenied[accounts[i]] = deny;
            }
        }
    }

    /// @notice `setMembers` on a fuzzed pair and list from a fuzzed caller, mostly the list's own editor.
    function setMembers(
        uint256 pairSeed,
        uint256 idSeed,
        uint256 callerSeed,
        uint256 entrySeed,
        bool allowed,
        uint256 badSeed
    ) external {
        uint16 p = uint16(pairSeed % (ghostPairCount + 1));
        uint64 id = _ids[idSeed % NIDS];
        address caller = _caller(callerSeed, id == HOME ? owner : ghostAdmin[id]);
        address[] memory accounts = _partyBatch(entrySeed, badSeed);
        uint32 generation = 1;
        bytes memory expected;
        if (id == HOME) {
            if (caller != owner) expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else {
            if (caller != ghostAdmin[id]) {
                expected = abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, id);
            } else if (allowed && !ghostEnabled[id]) {
                expected = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, id);
            } else if (allowed && !ghostAdmitted[p][id]) {
                expected = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorNotAdmitted.selector, p, id);
            }
            generation = ghostGeneration[id];
        }
        if (expected.length == 0 && allowed && !_pairs[p].live) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        }
        if (expected.length == 0 && _hasBadEntry(accounts)) {
            expected = _err(IManagedDirectPropAMM.InvalidAddress.selector);
        }
        if (_run(1, caller, abi.encodeCall(IManagedDirectPropAMM.setMembers, (p, id, accounts, allowed)), expected)) {
            for (uint256 i; i < accounts.length; ++i) {
                ghostMember[p][id][accounts[i]] = allowed ? generation : 0;
            }
        }
    }

    /// @notice `addSponsor` from a fuzzed caller, under an id that may be taken or 0, with a fuzzed admin.
    function addSponsor(uint256 idSeed, uint256 adminSeed, uint256 callerSeed) external {
        uint64 id = [S1, S2, S3, HOME][idSeed % 4];
        address admin = _adminCandidate(adminSeed);
        address caller = _caller(callerSeed, owner);
        bytes memory expected;
        if (caller != owner) {
            expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else if (id == HOME || ghostAdmin[id] != address(0)) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorExists.selector, id);
        } else if (!_isAccount(admin)) {
            expected = _err(IManagedDirectPropAMM.InvalidAddress.selector);
        }
        if (_run(2, caller, abi.encodeCall(IManagedDirectPropAMM.addSponsor, (id, admin)), expected)) {
            ghostAdmin[id] = admin;
            ghostEnabled[id] = true;
            ghostGeneration[id] = 1;
        }
    }

    /// @notice `setSponsorEnabled`: owner only.
    function setSponsorEnabled(uint256 idSeed, bool enabled, uint256 callerSeed) external {
        uint64 id = _sponsorChoice(idSeed);
        address caller = _caller(callerSeed, owner);
        bytes memory expected = _ownerOnly(caller);
        if (expected.length == 0 && ghostAdmin[id] == address(0)) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, id);
        }
        if (_run(3, caller, abi.encodeCall(IManagedDirectPropAMM.setSponsorEnabled, (id, enabled)), expected)) {
            ghostEnabled[id] = enabled;
        }
    }

    /// @notice `setPairSponsor`: owner only; admission needs a live pair.
    function setPairSponsor(uint256 pairSeed, uint256 idSeed, bool admitted, uint256 callerSeed) external {
        uint16 p = uint16(pairSeed % (ghostPairCount + 1));
        uint64 id = _ids[idSeed % NIDS];
        address caller = _caller(callerSeed, owner);
        bytes memory expected = _ownerOnly(caller);
        if (expected.length == 0 && ghostAdmin[id] == address(0)) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, id);
        }
        if (expected.length == 0 && admitted && !_pairs[p].live) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        }
        if (_run(4, caller, abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (p, id, admitted)), expected)) {
            ghostAdmitted[p][id] = admitted;
        }
    }

    /// @notice `resetSponsor` (owner only): a new admin and generation, voiding every earlier listing at once.
    function resetSponsor(uint256 idSeed, uint256 adminSeed, uint256 callerSeed) external {
        uint64 id = _ids[idSeed % NIDS];
        address admin = _adminCandidate(adminSeed);
        address caller = _caller(callerSeed, owner);
        bytes memory expected;
        if (caller != owner) {
            expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else if (ghostAdmin[id] == address(0)) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, id);
        } else if (!_isAccount(admin)) {
            expected = _err(IManagedDirectPropAMM.InvalidAddress.selector);
        }
        if (_run(5, caller, abi.encodeCall(IManagedDirectPropAMM.resetSponsor, (id, admin)), expected)) {
            ghostAdmin[id] = admin;
            ghostGeneration[id] += 1;
            delete ghostPending[id];
            // Every earlier listing is void, on every pair, the moment the generation moves.
            for (uint16 p; p <= MAX_PAIRS; ++p) {
                for (uint256 i; i < NPARTIES; ++i) {
                    assertFalse(pool.isMember(p, id, _parties[i]), "a listing survived its sponsor's reset");
                }
            }
        }
    }

    /// @notice `transferSponsorAdmin` from a fuzzed caller, mostly the sponsor's admin.
    function transferSponsorAdmin(uint256 idSeed, uint256 adminSeed, uint256 callerSeed) external {
        uint64 id = _ids[idSeed % NIDS];
        address next = _adminCandidate(adminSeed);
        address caller = _caller(callerSeed, ghostAdmin[id]);
        bytes memory expected;
        if (caller != ghostAdmin[id]) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, id);
        } else if (!_isAccount(next)) {
            expected = _err(IManagedDirectPropAMM.InvalidAddress.selector);
        }
        if (_run(6, caller, abi.encodeCall(IManagedDirectPropAMM.transferSponsorAdmin, (id, next)), expected)) {
            ghostPending[id] = next;
        }
    }

    /// @notice `cancelSponsorAdminTransfer` from a fuzzed caller, mostly the current sponsor admin.
    function cancelSponsorAdminTransfer(uint256 idSeed, uint256 callerSeed) external {
        uint64 id = _ids[idSeed % NIDS];
        address caller = _caller(callerSeed, ghostAdmin[id]);
        bytes memory expected;
        if (caller != ghostAdmin[id]) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, id);
        }
        if (_run(7, caller, abi.encodeCall(IManagedDirectPropAMM.cancelSponsorAdminTransfer, (id)), expected)) {
            delete ghostPending[id];
        }
    }

    /// @notice `acceptSponsorAdmin` from a fuzzed caller, mostly the pending admin.
    function acceptSponsorAdmin(uint256 idSeed, uint256 callerSeed) external {
        uint64 id = _ids[idSeed % NIDS];
        if (idSeed % 4 != 0) {
            for (uint256 i = 1; i < 4; ++i) {
                if (ghostPending[_ids[i]] != address(0)) id = _ids[i];
            }
        }
        address caller = _caller(callerSeed, ghostPending[id]);
        bytes memory expected;
        if (caller != ghostPending[id]) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.NotPendingSponsorAdmin.selector, id);
        }
        if (_run(8, caller, abi.encodeCall(IManagedDirectPropAMM.acceptSponsorAdmin, (id)), expected)) {
            ghostAdmin[id] = caller;
            delete ghostPending[id];
        }
    }

    /// @notice `setPairAccess` (owner only), sometimes paused around it so `Open` can be entered. Leaving `Closed`
    /// runs `DirectPropAMM.unpause`'s oracle and anchor checks on the pair.
    function setPairAccess(uint256 pairSeed, uint256 modeSeed, uint256 callerSeed, bool pauseAround) external {
        uint16 p = uint16(pairSeed % (ghostPairCount + 1));
        IManagedDirectPropAMM.AccessMode mode = IManagedDirectPropAMM.AccessMode([2, 2, 3, 3, 1, 0][modeSeed % 6]);
        address caller = _caller(callerSeed, owner);
        // Mostly paused around an entry into `Open`, so the campaign trades `Open` pairs too.
        bool around =
            (pauseAround || modeSeed % 5 != 0) && !ghostPaused && mode == IManagedDirectPropAMM.AccessMode.Open;
        if (around) _pause(owner);
        GhostPair storage g = _pairs[p];
        IManagedDirectPropAMM.AccessMode old = g.mode;
        bytes memory expected;
        uint256 price;
        if (caller != owner) {
            expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else if (!g.live) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        } else if (mode != old) {
            if (mode == IManagedDirectPropAMM.AccessMode.None) {
                expected = _err(IManagedDirectPropAMM.InvalidAccessMode.selector);
            } else if (mode == IManagedDirectPropAMM.AccessMode.Open && !ghostPaused) {
                expected = _err(IManagedDirectPropAMM.NotPaused.selector);
            } else if (old == IManagedDirectPropAMM.AccessMode.Closed) {
                (expected, price) = _predictActivation(p);
            }
        }
        bool wasPaused = ghostPaused;
        if (_run(9, caller, abi.encodeCall(IManagedDirectPropAMM.setPairAccess, (p, mode)), expected)) {
            if (mode != old && old == IManagedDirectPropAMM.AccessMode.Closed) {
                if (g.anchors[1] == 0) g.anchors[1] = price;
                if (g.anchors[0] == 0) g.anchors[0] = price;
            }
            if (mode == IManagedDirectPropAMM.AccessMode.Open && old != mode && !wasPaused) ++openedWhileActive;
            g.mode = mode;
        }
        if (around) _unpause(owner);
    }

    /// @notice `closePair` from a fuzzed caller, mostly the owner.
    function closePair(uint256 pairSeed, uint256 callerSeed) external {
        uint16 p = uint16(pairSeed % (ghostPairCount + 1));
        address caller = _caller(callerSeed, owner);
        bytes memory expected;
        if (caller != owner) expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        else if (!_pairs[p].live) expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        if (_run(10, caller, abi.encodeCall(IManagedDirectPropAMM.closePair, (p)), expected)) {
            _pairs[p].mode = IManagedDirectPropAMM.AccessMode.Closed;
        }
    }

    /// @notice `pause` or `unpause` (owner only), from a fuzzed caller.
    function setPaused(bool paused, uint256 callerSeed) external {
        address caller = _caller(callerSeed, owner);
        if (paused) _pause(caller);
        else _unpause(caller);
    }

    /// @notice Moves a pair's oracle: within or past its deviation limit, stale, zero, from the future, or back.
    function moveOracle(uint256 pairSeed, uint256 kindSeed, uint256 bpsSeed) external {
        uint256 o = pairSeed % 3;
        MockOracle oracle = _oracles[o];
        uint256 base = _basePrice[o];
        uint256 kind = kindSeed % 10;
        // No `block.timestamp` local kept across a warp: none happens in this call.
        if (kind < 6) {
            int256 bps = int256(bpsSeed % 161) - 80;
            oracle.setPrice(uint256(int256(base) + int256(base) * bps / 10_000), block.timestamp);
        } else if (kind == 6) {
            if (block.timestamp > 200_000) oracle.setPrice(base, block.timestamp - 100_000);
        } else if (kind == 7) {
            oracle.setPrice(0, block.timestamp);
        } else if (kind == 8) {
            oracle.setPrice(base, block.timestamp + 1);
        } else {
            oracle.setPrice(base, block.timestamp);
        }
        ++_accepted[12];
    }

    /// @notice Moves the clock up to an hour.
    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + 1 + seconds_ % 3_600);
        ++_accepted[13];
    }

    /// @notice `fund` from a fuzzed caller, of a pair's token, a token no live pair uses, or zero.
    function fund(uint256 tokenSeed, uint256 amountSeed, uint256 callerSeed) external {
        MockTIP20 token = tokenSeed % 5 == 4 ? stray : _tokens[tokenSeed % 3];
        uint256 amount = amountSeed % 16 == 0 ? 0 : 1 + amountSeed % (1_000 * 10 ** token.decimals());
        address caller = _caller(callerSeed, owner);
        _mint(token, owner, amount);
        bytes memory expected;
        if (caller != owner) {
            expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else if (_livePairsUsing(address(token)) == 0) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedToken.selector, address(token));
        } else if (amount == 0) {
            expected = _err(IManagedDirectPropAMM.AmountIsZero.selector);
        }
        if (_run(
                14, caller, abi.encodeCall(IManagedDirectPropAMM.fund, (address(token), amount, bytes32("f"))), expected
            )) {
            ghostPoolBalance[address(token)] += amount;
        }
    }

    /// @notice `withdraw` from a fuzzed caller, of any token, to an account, a registered or unregistered virtual
    /// address, the pool, a virtual address the pool masters, or zero. Every virtual address reverts
    /// `VirtualRecipient`, registered or not; an account gets its exact credit.
    function withdraw(uint256 tokenSeed, uint256 recipientSeed, uint256 amountSeed, uint256 callerSeed) external {
        MockTIP20 token = _tokens[tokenSeed % 3];
        address recipient = [
            treasury,
            virtualRecipient,
            treasury,
            virtualRecipient,
            unregisteredVirtual,
            address(pool),
            poolVirtual,
            address(0)
        ][recipientSeed % 8];
        uint256 balance = token.balanceOf(address(pool));
        // Zero, more than the pool holds, nearly all of it (so later swaps run short), or up to 2,000 units.
        uint256 amount = amountSeed % 16 == 0
            ? 0
            : amountSeed % 8 == 1
                ? balance + 1
                : amountSeed % 8 < 4 && balance > 1
                    ? balance - 1 - (amountSeed >> 8) % (balance / 1_000 + 1)
                    : 1 + amountSeed % (2_000 * 10 ** token.decimals());
        address caller = _caller(callerSeed, owner);
        bool isVirtual = VirtualAddress.isVirtual(recipient);
        bytes memory expected;
        if (caller != owner) {
            expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else if (amount == 0) {
            expected = _err(IManagedDirectPropAMM.AmountIsZero.selector);
        } else if (recipient == address(0) || recipient == address(pool)) {
            expected = _err(IManagedDirectPropAMM.InvalidAddress.selector);
        } else if (isVirtual) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, recipient);
        } else if (amount > balance) {
            expected = abi.encodeWithSelector(
                IManagedDirectPropAMM.InsufficientInventory.selector, address(token), balance, amount
            );
        }
        uint256 recipientBefore = token.balanceOf(recipient);
        if (_run(
                15,
                caller,
                abi.encodeCall(IManagedDirectPropAMM.withdraw, (address(token), recipient, amount, bytes32("w"))),
                expected
            )) {
            ghostPoolBalance[address(token)] -= amount;
            assertEq(token.balanceOf(recipient), recipientBefore + amount, "the recipient wasn't paid exactly");
        } else if (isVirtual && caller == owner && amount != 0) {
            ++virtualRefusals;
        }
    }

    /// @notice `removePair` (owner only), rarely: most runs keep their pairs.
    function removePair(uint256 pairSeed, uint256 callerSeed) external {
        if (pairSeed % 6 != 0) return;
        uint16 p = uint16((pairSeed >> 8) % (ghostPairCount + 1));
        address caller = _caller(callerSeed, owner);
        bytes memory expected;
        if (caller != owner) expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        else if (!_pairs[p].live) expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        if (_run(16, caller, abi.encodeCall(IManagedDirectPropAMM.removePair, (p)), expected)) {
            GhostPair storage g = _pairs[p];
            g.live = false;
            g.mode = IManagedDirectPropAMM.AccessMode.None;
            g.anchors[0] = 0;
            g.anchors[1] = 0;
        }
    }

    /// @notice `addPair` (owner only) up to `MAX_PAIRS`: A/Q again on A/Q's oracle, so two pairs share one feed, or
    /// Q/A reversed on its own feed.
    function addPair(uint256 comboSeed, uint256 callerSeed) external {
        if (ghostPairCount >= MAX_PAIRS) return;
        bool shareFeed = comboSeed % 2 == 0;
        MockTIP20 base = shareFeed ? _tokens[0] : _tokens[2];
        MockTIP20 quote = shareFeed ? _tokens[2] : _tokens[0];
        // The reversed pair reuses oracle 2's 18-decimal feed: Q (6) / A (6) at 18 decimals, scale 1e18.
        MockOracle oracle = shareFeed ? _oracles[0] : _oracles[2];
        address caller = _caller(callerSeed, owner);
        bytes memory expected;
        if (caller != owner) expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        bytes memory data = abi.encodeCall(
            IManagedDirectPropAMM.addPair,
            (address(base), address(quote), oracle, _pairs[0].maxAge, _pairs[0].deviationBps)
        );
        if (_run(17, caller, data, expected)) {
            uint16 p = ghostPairCount++;
            GhostPair storage g = _pairs[p];
            g.live = true;
            g.base = address(base);
            g.quote = address(quote);
            g.oracle = oracle;
            g.maxAge = _pairs[0].maxAge;
            g.deviationBps = _pairs[0].deviationBps;
            g.scale = 10 ** (uint256(base.decimals()) + oracle.decimals() - quote.decimals());
            g.mode = IManagedDirectPropAMM.AccessMode.Closed;
        }
    }

    /// @notice `resetPriceAnchor` on a closed pair (owner only): v1's fresh read, no deviation check.
    function resetPriceAnchor(uint256 pairSeed, bool baseToQuote, uint256 callerSeed) external {
        uint16 p = uint16(pairSeed % (ghostPairCount + 1));
        address caller = _caller(callerSeed, owner);
        GhostPair storage g = _pairs[p];
        bytes memory expected;
        uint256 price;
        if (caller != owner) {
            expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else if (!g.live) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        } else if (g.mode != IManagedDirectPropAMM.AccessMode.Closed) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.PairNotClosed.selector, p);
        } else {
            (expected, price,) = _predictOracle(p);
        }
        if (_run(18, caller, abi.encodeCall(IManagedDirectPropAMM.resetPriceAnchor, (p, baseToQuote)), expected)) {
            g.anchors[baseToQuote ? 0 : 1] = price;
        }
    }

    /// @notice `setMaxPriceDeviationBps` on a closed pair (owner only).
    function setMaxPriceDeviationBps(uint256 pairSeed, uint256 bpsSeed, uint256 callerSeed) external {
        uint16 p = uint16(pairSeed % (ghostPairCount + 1));
        uint256 bps = [uint256(10), 50, 100, 10_001][bpsSeed % 4];
        address caller = _caller(callerSeed, owner);
        GhostPair storage g = _pairs[p];
        bytes memory expected;
        if (caller != owner) {
            expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        } else if (!g.live) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        } else if (g.mode != IManagedDirectPropAMM.AccessMode.Closed) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.PairNotClosed.selector, p);
        } else if (bps > BPS) {
            expected = abi.encodeWithSelector(IManagedDirectPropAMM.InvalidMaxPriceDeviationBps.selector, bps, BPS);
        }
        if (_run(19, caller, abi.encodeCall(IManagedDirectPropAMM.setMaxPriceDeviationBps, (p, bps)), expected)) {
            g.deviationBps = bps;
        }
    }

    // =================================================================================================================
    // Views for the invariants
    // =================================================================================================================

    function party(uint256 i) external view returns (address) {
        return _parties[i];
    }

    function sponsorId(uint256 i) external view returns (uint64) {
        return _ids[i];
    }

    function tokenAt(uint256 i) external view returns (MockTIP20) {
        return _tokens[i];
    }

    function ghostPair(uint16 p) external view returns (GhostPair memory) {
        return _pairs[p];
    }

    /// @notice The ghost's access check for (pair, account, sponsor), independent of priority fees.
    function expectedAccess(uint16 p, address account, uint64 id)
        public
        view
        returns (IManagedDirectPropAMM.TakerAccess)
    {
        return _modelAccess(p, account, id);
    }

    /// @notice What `quoteExactInput(p, taker, baseToQuote, ·)` must revert with, from the pair's own oracle and anchors, or
    /// empty when it prices.
    function expectedQuoteError(uint16 p, bool baseToQuote) external view returns (bytes memory err) {
        if (!_pairs[p].live) return abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, p);
        uint256 price;
        (err, price,) = _predictOracle(p);
        if (err.length == 0) err = _predictDeviation(p, baseToQuote, price);
    }

    function stats()
        external
        view
        returns (uint256[9] memory refusals, uint256[20] memory accepted, uint256[20] memory refused)
    {
        return (_refusals, _accepted, _refused);
    }

    // =================================================================================================================
    // Swaps
    // =================================================================================================================

    struct Trade {
        address from;
        uint16 p;
        uint64 id;
        bytes32 customer;
        bool baseToQuote;
        bool exactInput;
        uint256 amount;
        uint256 price;
        MockTIP20 tokenIn;
        MockTIP20 tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 creditAfter;
        IManagedDirectPropAMM.TakerAccess access;
    }

    /// @dev The swap's revert, in the pool's order, or empty for a fill (with `t`'s amounts filled in).
    function _predictSwap(Trade memory t) internal view returns (bytes memory) {
        if (ghostPaused) return _err(IManagedDirectPropAMM.Paused.selector);
        t.access = _modelAccess(t.p, t.from, t.id);
        if (t.access != IManagedDirectPropAMM.TakerAccess.Allowed) return _refusal(t.access, t.p, t.from, t.id);
        if (t.customer == bytes32(0)) return _err(IManagedDirectPropAMM.CustomerIdIsZero.selector);
        if (t.amount == 0) return _err(IManagedDirectPropAMM.AmountIsZero.selector);
        (bytes memory err, uint256 price,) = _predictOracle(t.p);
        if (err.length == 0) err = _predictDeviation(t.p, t.baseToQuote, price);
        if (err.length != 0) return err;
        if (t.exactInput) {
            t.amountIn = t.amount;
            (t.amountOut,,, t.creditAfter) = pool.quoteExactInputFor(t.p, t.from, t.customer, t.baseToQuote, t.amount);
            if (t.amountOut == 0) return _err(IManagedDirectPropAMM.AmountIsZero.selector);
        } else {
            t.amountOut = t.amount;
            (t.amountIn,,, t.creditAfter) = pool.quoteExactOutputFor(t.p, t.from, t.customer, t.baseToQuote, t.amount);
        }
        uint256 available = t.tokenOut.balanceOf(address(pool));
        if (t.amountOut > available) {
            return abi.encodeWithSelector(
                IManagedDirectPropAMM.InsufficientInventory.selector, address(t.tokenOut), available, t.amountOut
            );
        }
        return "";
    }

    function _runSwap(Trade memory t, bytes memory expected) internal {
        address[] memory holders = _holders();
        uint256[] memory inBefore = new uint256[](holders.length);
        uint256[] memory outBefore = new uint256[](holders.length);
        bool live = _pairs[t.p].live;
        for (uint256 i; live && i < holders.length; ++i) {
            inBefore[i] = t.tokenIn.balanceOf(holders[i]);
            outBefore[i] = t.tokenOut.balanceOf(holders[i]);
        }
        bytes memory data = t.exactInput
            ? abi.encodeCall(
                IManagedDirectPropAMM.swapExactInput,
                (t.p, t.baseToQuote, t.amount, 0, t.id, t.customer, bytes32("t"), block.timestamp, t.price, 0, 0)
            )
            : abi.encodeCall(
                IManagedDirectPropAMM.swapExactOutput,
                (
                    t.p,
                    t.baseToQuote,
                    t.amount,
                    type(uint256).max,
                    t.id,
                    t.customer,
                    bytes32("t"),
                    block.timestamp,
                    t.price,
                    0,
                    0
                )
            );
        vm.prank(t.from);
        (bool ok, bytes memory ret) = address(pool).call(data);
        if (expected.length != 0) {
            assertFalse(ok, "a swap the model refuses filled");
            assertEq(ret, expected, "the swap reverted with another error than the model's");
            if (ghostPaused) ++pausedRefusals;
            else if (t.access != IManagedDirectPropAMM.TakerAccess.Allowed) ++_refusals[uint8(t.access)];
            else if (bytes4(expected) == IManagedDirectPropAMM.InsufficientInventory.selector) ++inventoryRefusals;
            else ++pricingRefusals;
            for (uint256 i; live && i < holders.length; ++i) {
                assertEq(t.tokenIn.balanceOf(holders[i]), inBefore[i], "a refused swap moved tokens");
                assertEq(t.tokenOut.balanceOf(holders[i]), outBefore[i], "a refused swap moved tokens");
            }
            return;
        }
        assertTrue(ok, "a swap the model admits reverted");
        assertEq(abi.decode(ret, (uint256)), t.exactInput ? t.amountOut : t.amountIn, "swap result");
        // Exactly its amounts between the pool and its caller; nothing for anyone else.
        for (uint256 i; i < holders.length; ++i) {
            uint256 expectedIn = inBefore[i];
            uint256 expectedOut = outBefore[i];
            if (holders[i] == t.from) {
                expectedIn -= t.amountIn;
                expectedOut += t.amountOut;
            } else if (holders[i] == address(pool)) {
                expectedIn += t.amountIn;
                expectedOut -= t.amountOut;
            }
            assertEq(t.tokenIn.balanceOf(holders[i]), expectedIn, "input moved for someone other than the caller");
            assertEq(t.tokenOut.balanceOf(holders[i]), expectedOut, "output paid to someone other than the caller");
        }
        ghostPoolBalance[address(t.tokenIn)] += t.amountIn;
        ghostPoolBalance[address(t.tokenOut)] -= t.amountOut;
        GhostPair storage g = _pairs[t.p];
        g.anchors[t.baseToQuote ? 0 : 1] = t.price;
        if (t.price > g.maxObservedPrice) g.maxObservedPrice = t.price;
        ghostCredit[keccak256(abi.encode(t.p, t.from, t.customer))] = t.creditAfter;
        if (g.mode == IManagedDirectPropAMM.AccessMode.Open) ++openFills;
        else if (t.id == HOME) ++homeFills;
        else ++sponsorFills;
    }

    // =================================================================================================================
    // The model
    // =================================================================================================================

    /// @dev Managed access check, in its order, on the ghost.
    function _modelAccess(uint16 p, address account, uint64 id)
        internal
        view
        returns (IManagedDirectPropAMM.TakerAccess)
    {
        IManagedDirectPropAMM.AccessMode mode = _pairs[p].mode;
        if (mode == IManagedDirectPropAMM.AccessMode.None) return IManagedDirectPropAMM.TakerAccess.UnknownPair;
        if (mode == IManagedDirectPropAMM.AccessMode.Closed) return IManagedDirectPropAMM.TakerAccess.Closed;
        if (ghostDenied[account]) return IManagedDirectPropAMM.TakerAccess.Denied;
        if (mode == IManagedDirectPropAMM.AccessMode.Open) return IManagedDirectPropAMM.TakerAccess.Allowed;
        uint32 generation = 1;
        if (id != HOME) {
            if (ghostAdmin[id] == address(0)) return IManagedDirectPropAMM.TakerAccess.UnknownSponsor;
            if (!ghostEnabled[id]) return IManagedDirectPropAMM.TakerAccess.SponsorDisabled;
            if (!ghostAdmitted[p][id]) return IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted;
            generation = ghostGeneration[id];
        }
        return ghostMember[p][id][account] == generation
            ? IManagedDirectPropAMM.TakerAccess.Allowed
            : IManagedDirectPropAMM.TakerAccess.NotListed;
    }

    function _refusal(IManagedDirectPropAMM.TakerAccess access, uint16 p, address account, uint64 id)
        internal
        pure
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

    /// @dev `DirectPropAMM._readOracle` on the pair's own oracle.
    function _predictOracle(uint16 p) internal view returns (bytes memory err, uint256 price, uint256 updatedAt) {
        GhostPair storage g = _pairs[p];
        (price, updatedAt) = g.oracle.latestPrice();
        if (price == 0 || updatedAt == 0) {
            err = _err(IManagedDirectPropAMM.InvalidPrice.selector);
        } else if (updatedAt > block.timestamp) {
            err = abi.encodeWithSelector(
                IManagedDirectPropAMM.FutureOracleTimestamp.selector, updatedAt, block.timestamp
            );
        } else if (block.timestamp - updatedAt > g.maxAge) {
            err = abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, updatedAt, g.maxAge);
        }
    }

    /// @dev `DirectPropAMM._validatePriceDeviation` against the pair's own ghost anchor.
    function _predictDeviation(uint16 p, bool baseToQuote, uint256 price) internal view returns (bytes memory) {
        GhostPair storage g = _pairs[p];
        uint256 anchor = g.anchors[baseToQuote ? 0 : 1];
        if (anchor == 0) {
            return abi.encodeWithSelector(IManagedDirectPropAMM.PriceAnchorNotInitialized.selector, baseToQuote);
        }
        uint256 deviation = price > anchor ? price - anchor : anchor - price;
        if (deviation > Math.mulDiv(anchor, g.deviationBps, BPS)) {
            return abi.encodeWithSelector(
                IManagedDirectPropAMM.PriceDeviationExceeded.selector, baseToQuote, price, anchor, g.deviationBps
            );
        }
        return "";
    }

    /// @dev `DirectPropAMM.unpause`'s checks on the pair: one fresh read, then each direction's anchor is set if zero
    /// or validated.
    function _predictActivation(uint16 p) internal view returns (bytes memory err, uint256 price) {
        (err, price,) = _predictOracle(p);
        if (err.length != 0) return (err, price);
        GhostPair storage g = _pairs[p];
        if (g.anchors[0] != 0) err = _predictDeviation(p, true, price);
        if (err.length == 0 && g.anchors[1] != 0) err = _predictDeviation(p, false, price);
    }

    // =================================================================================================================
    // Running calls
    // =================================================================================================================

    /// @dev Runs `data` on the pool as `caller` and requires `expected`: success when empty, else those revert bytes.
    function _run(uint256 op, address caller, bytes memory data, bytes memory expected) internal returns (bool ok) {
        vm.prank(caller);
        bytes memory ret;
        (ok, ret) = address(pool).call(data);
        if (expected.length == 0) {
            if (!ok) assertEq(ret, bytes("<success>"), "a call the model accepts reverted");
            ++_accepted[op];
        } else {
            assertFalse(ok, "a call the model refuses succeeded");
            assertEq(ret, expected, "a call reverted with another error than the model's");
            ++_refused[op];
        }
    }

    function _pause(address caller) internal {
        bytes memory expected;
        if (caller != owner) expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        if (_run(11, caller, abi.encodeCall(IManagedDirectPropAMM.pause, ()), expected)) ghostPaused = true;
    }

    function _unpause(address caller) internal {
        bytes memory expected;
        if (caller != owner) expected = _err(IManagedDirectPropAMM.NotOwner.selector);
        if (_run(11, caller, abi.encodeCall(IManagedDirectPropAMM.unpause, ()), expected)) ghostPaused = false;
    }

    /// @dev Pool controls belong exclusively to the current owner.
    function _ownerOnly(address caller) internal view returns (bytes memory) {
        return caller == owner ? bytes("") : _err(IManagedDirectPropAMM.NotOwner.selector);
    }

    // =================================================================================================================
    // Choices and helpers
    // =================================================================================================================

    /// @dev Mostly the caller a call needs, otherwise any role or a stranger.
    function _caller(uint256 pick, address preferred) internal view returns (address) {
        uint256 c = pick % 10;
        if (c < 6 && preferred != address(0)) return preferred;
        return [owner, adminB, adminA, adminB, candidate, stranger, owner, candidate, adminA, stranger][c];
    }

    /// @dev Mostly a sponsor the setup or the campaign registers, sometimes S3, the unregistered id or the home list.
    function _sponsorChoice(uint256 pick) internal view returns (uint64) {
        return [S1, S2, S1, S2, S1, S3, UNREGISTERED, HOME][pick % 8];
    }

    function _adminCandidate(uint256 pick) internal view returns (address) {
        return [adminA, adminB, candidate, adminA, adminB, address(0), address(pool), virtualRecipient][pick % 8];
    }

    /// @dev Up to four parties, and sometimes zero or the pool among them.
    function _partyBatch(uint256 entrySeed, uint256 badSeed) internal view returns (address[] memory accounts) {
        // The low byte is the length; each further byte picks one party.
        uint256 length = (entrySeed & 0xff) % 5;
        accounts = new address[](length);
        for (uint256 i; i < length; ++i) {
            accounts[i] = _parties[((entrySeed >> (8 * (i + 1))) & 0xff) % NPARTIES];
        }
        if (length != 0 && badSeed % 6 == 0) {
            accounts[(badSeed >> 8) % length] = [address(0), address(pool)][(badSeed >> 16) % 2];
        }
    }

    function _hasBadEntry(address[] memory accounts) internal view returns (bool) {
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0) || accounts[i] == address(pool)) return true;
        }
        return false;
    }

    /// @dev An account a sponsor admin may be: not zero, the pool or a virtual address.
    function _isAccount(address account) internal view returns (bool) {
        return account != address(0) && account != address(pool) && !VirtualAddress.isVirtual(account);
    }

    function _livePairsUsing(address token_) internal view returns (uint256 count) {
        for (uint16 p; p < ghostPairCount; ++p) {
            if (_pairs[p].live && (_pairs[p].base == token_ || _pairs[p].quote == token_)) ++count;
        }
    }

    /// @dev Every account a token can reach here: the pool, its roles, every party, the treasury and the master.
    function _holders() internal view returns (address[] memory holders) {
        holders = new address[](NPARTIES + 6);
        for (uint256 i; i < NPARTIES; ++i) {
            holders[i] = _parties[i];
        }
        holders[NPARTIES] = address(pool);
        holders[NPARTIES + 1] = owner;
        holders[NPARTIES + 2] = treasury;
        holders[NPARTIES + 3] = master;
        holders[NPARTIES + 4] = adminB;
        holders[NPARTIES + 5] = candidate;
    }

    function allHolders() external view returns (address[] memory) {
        return _holders();
    }

    function _mint(MockTIP20 token_, address to, uint256 amount) internal {
        token_.mint(to, amount);
        ghostMinted[address(token_)] += amount;
    }

    function _err(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }
}

/// @notice Stateful invariants for `ManagedDirectPropAMM`, over the handler above:
/// - the access state (modes, sponsors, admissions, members, generations, denials and the pause) is exactly
///   what the accepted calls left, and `takerAccess` is the ghost's check for every pair, account and sponsor id;
/// - a denial overrides every list and `Open`; a reset voids every earlier listing; `Open` is only ever entered while
///   the pool is paused; every emergency control is owner-only;
/// - inventory is conserved per token across every pair that shares it: the pool holds what it was funded and paid,
///   less what it paid out and withdrew, and no token appears or disappears among the holders;
/// - fills pay only their caller (the handler checks every holder on every fill);
/// - each pair's anchors move only by its own swaps, activation and resets, and each route's credit only by its own
///   swaps, staying below its pair's input-value modulus;
/// - a pair's quote follows its own oracle and anchors only (per-pair oracle isolation);
/// - `pairCount` only rises, a removed index stays `None` and all zero, and `tokenPairCount` counts the live pairs.
/// @dev Every invariant runs after every handler call, and the access one reads about 600 views, so the campaign runs
/// 64 sequences of 32 calls in both profiles (about 30 seconds), and 8 under `forge coverage` (the `coverage` profile),
/// where every call is instrumented and a full campaign takes about 7 minutes on a CI runner.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 32
/// forge-config: ci.invariant.runs = 64
/// forge-config: coverage.invariant.runs = 8
contract ManagedDirectPropAMMInvariantTest is StdInvariant, Test {
    uint256 internal constant MAX_AGE = 90_000;
    uint256 internal constant MAX_DEVIATION_BPS = 50;

    ManagedDirectPropAMM internal pool;
    ManagedPoolHandler internal handler;
    address internal owner = makeAddr("owner");

    function setUp() external {
        vm.warp(1_000_000);
        MockVirtualAddressRegistry registry = new MockVirtualAddressRegistry();
        MockTIP20[3] memory tokens = [new MockTIP20("A", 6), new MockTIP20("B", 18), new MockTIP20("Q", 6)];
        MockTIP20 stray = new MockTIP20("STRAY", 6);
        for (uint256 t; t < 3; ++t) {
            tokens[t].setResolver(registry);
        }
        stray.setResolver(registry);
        // A at 1.05 Q, B at 1.085 Q, and A at 0.9677 B with 18 decimals.
        uint256[3] memory prices = [uint256(105_000_000), uint256(108_500_000), uint256(967_741_935_483_870_967)];
        MockOracle[3] memory oracles = [
            new MockOracle(8, prices[0], block.timestamp),
            new MockOracle(8, prices[1], block.timestamp),
            new MockOracle(18, prices[2], block.timestamp)
        ];
        pool = new ManagedDirectPropAMM(owner, address(0));
        handler = new ManagedPoolHandler(pool, registry, owner, tokens, stray, oracles, prices);

        vm.startPrank(owner);
        pool.addPair(address(tokens[0]), address(tokens[2]), oracles[0], MAX_AGE, MAX_DEVIATION_BPS);
        pool.addPair(address(tokens[1]), address(tokens[2]), oracles[1], MAX_AGE, MAX_DEVIATION_BPS);
        pool.addPair(address(tokens[0]), address(tokens[1]), oracles[2], MAX_AGE, MAX_DEVIATION_BPS);
        vm.stopPrank();
        tokens[0].mint(address(pool), 100_000e6);
        tokens[1].mint(address(pool), 100_000e18);
        tokens[2].mint(address(pool), 100_000e6);
        handler.seed(3, [uint256(1e8), uint256(1e20), uint256(1e6)], MAX_AGE, MAX_DEVIATION_BPS);

        // Start where fills are one call away: every pair `Listed`, the pool active, t0 and t1 on every home list,
        // sponsor S1 (adminA) admitted on pairs 0 and 1 with t2 listed on both.
        handler.setPairAccess(0, 0, 0, false);
        handler.setPairAccess(1, 0, 0, false);
        handler.setPairAccess(2, 0, 0, false);
        handler.setPaused(false, 0);
        for (uint256 p; p < 3; ++p) {
            // Entry seed: two entries, parties 0 and 1.
            handler.setMembers(p, 0, 0, 2 | (0 << 8) | (1 << 16), true, 1);
        }
        handler.addSponsor(0, 0, 0);
        handler.setPairSponsor(0, 1, true, 0);
        handler.setPairSponsor(1, 1, true, 0);
        handler.setMembers(0, 1, 0, 1 | (2 << 8), true, 1);
        handler.setMembers(1, 1, 0, 1 | (2 << 8), true, 1);

        bytes4[] memory selectors = new bytes4[](23);
        selectors[0] = ManagedPoolHandler.swap.selector;
        selectors[1] = ManagedPoolHandler.swapListed.selector;
        selectors[2] = ManagedPoolHandler.swapListedExactOut.selector;
        selectors[3] = ManagedPoolHandler.setDenied.selector;
        selectors[4] = ManagedPoolHandler.setMembers.selector;
        selectors[5] = ManagedPoolHandler.addSponsor.selector;
        selectors[6] = ManagedPoolHandler.setSponsorEnabled.selector;
        selectors[7] = ManagedPoolHandler.setPairSponsor.selector;
        selectors[8] = ManagedPoolHandler.resetSponsor.selector;
        selectors[9] = ManagedPoolHandler.transferSponsorAdmin.selector;
        selectors[10] = ManagedPoolHandler.cancelSponsorAdminTransfer.selector;
        selectors[11] = ManagedPoolHandler.acceptSponsorAdmin.selector;
        selectors[12] = ManagedPoolHandler.setPairAccess.selector;
        selectors[13] = ManagedPoolHandler.closePair.selector;
        selectors[14] = ManagedPoolHandler.setPaused.selector;
        selectors[15] = ManagedPoolHandler.moveOracle.selector;
        selectors[16] = ManagedPoolHandler.fund.selector;
        selectors[17] = ManagedPoolHandler.withdraw.selector;
        selectors[18] = ManagedPoolHandler.removePair.selector;
        selectors[19] = ManagedPoolHandler.addPair.selector;
        selectors[20] = ManagedPoolHandler.warp.selector;
        selectors[21] = ManagedPoolHandler.resetPriceAnchor.selector;
        selectors[22] = ManagedPoolHandler.setMaxPriceDeviationBps.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// @notice Every access view is what the accepted calls left, and `takerAccess` is the ghost's check (independently of transaction
    /// priority fees) for every pair up to `MAX_PAIRS`, every party and every sponsor id; `takerAllowed` is exactly
    /// `takerAccess == Allowed`, and `None` is never an answer.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_accessIsWhatTheAcceptedCallsLeft() external view {
        assertEq(pool.paused(), handler.ghostPaused(), "paused");
        for (uint256 k = 1; k < handler.NIDS(); ++k) {
            uint64 id = handler.sponsorId(k);
            (address admin, bool enabled, uint32 generation) = pool.sponsor(id);
            assertEq(admin, handler.ghostAdmin(id), "sponsor admin");
            assertEq(enabled, handler.ghostEnabled(id), "sponsor switch");
            assertEq(generation, handler.ghostGeneration(id), "sponsor generation");
            assertEq(pool.pendingSponsorAdmin(id), handler.ghostPending(id), "pending admin");
        }
        // Every pair ever added and the next, unknown index.
        for (uint16 p; p <= handler.ghostPairCount(); ++p) {
            ManagedPoolHandler.GhostPair memory g = handler.ghostPair(p);
            assertEq(uint8(pool.pair(p).access), uint8(g.mode), "pair mode");
            for (uint256 k; k < handler.NIDS(); ++k) {
                uint64 id = handler.sponsorId(k);
                assertEq(pool.pairSponsor(p, id), g.live && (id == 0 || handler.ghostAdmitted(p, id)), "admission");
                uint32 generation = id == 0 ? 1 : handler.ghostGeneration(id);
                for (uint256 i; i < handler.NPARTIES(); ++i) {
                    address account = handler.party(i);
                    uint32 stored = handler.ghostMember(p, id, account);
                    assertEq(pool.isMember(p, id, account), g.live && stored != 0 && stored == generation, "member");
                    IManagedDirectPropAMM.TakerAccess access = pool.takerAccess(p, account, id);
                    assertTrue(access != IManagedDirectPropAMM.TakerAccess.None, "None answered");
                    assertEq(uint8(access), uint8(handler.expectedAccess(p, account, id)), "takerAccess");
                    assertEq(pool.takerAllowed(p, account, id), access == IManagedDirectPropAMM.TakerAccess.Allowed);
                }
            }
        }
    }

    /// @notice `deniedCount` is exactly the number of denied accounts (every account the handler can deny is a
    /// party), and a denied account is refused `Denied` on every live pair that isn't `Closed`, `Open` included, under
    /// every sponsor id, regardless of transaction priority fees.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_denialsAreCountedAndOverrideEverything() external view {
        uint256 count;
        for (uint256 i; i < handler.NPARTIES(); ++i) {
            address account = handler.party(i);
            bool isDenied = pool.denied(account);
            assertEq(isDenied, handler.ghostDenied(account), "denied");
            if (!isDenied) continue;
            ++count;
            for (uint16 p; p < pool.pairCount(); ++p) {
                IManagedDirectPropAMM.AccessMode mode = pool.pair(p).access;
                if (mode == IManagedDirectPropAMM.AccessMode.None || mode == IManagedDirectPropAMM.AccessMode.Closed) {
                    continue;
                }
                for (uint256 k; k < handler.NIDS(); ++k) {
                    assertEq(
                        uint8(pool.takerAccess(p, account, handler.sponsorId(k))),
                        uint8(IManagedDirectPropAMM.TakerAccess.Denied),
                        "a denied account is admitted"
                    );
                }
            }
        }
        assertEq(pool.deniedCount(), count, "deniedCount");
        assertFalse(pool.denied(address(0)), "zero denied");
        assertFalse(pool.denied(address(pool)), "pool denied");
    }

    /// @notice No pair entered `Open` while the pool traded.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_openNeedsThePause() external view {
        assertEq(handler.openedWhileActive(), 0, "a pair entered Open while the pool traded");
    }

    /// @notice Per token, across every pair that shares it: the pool holds its funding and swap inputs less its swap
    /// outputs and withdrawals, and the token's total over every holder is what was minted. No virtual address, and no
    /// virtual address's master, ever holds any: the pool pays none.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_inventoryIsConservedPerToken() external view {
        address[] memory holders = handler.allHolders();
        for (uint256 t; t < 3; ++t) {
            MockTIP20 token = handler.tokenAt(t);
            assertEq(token.balanceOf(address(pool)), handler.ghostPoolBalance(address(token)), "pool balance");
            uint256 total;
            for (uint256 i; i < holders.length; ++i) {
                total += token.balanceOf(holders[i]);
            }
            assertEq(total, handler.ghostMinted(address(token)), "tokens appeared or vanished");
            assertEq(token.balanceOf(handler.virtualRecipient()), 0, "a virtual address holds a balance");
            assertEq(token.balanceOf(handler.master()), 0, "a virtual address's master was paid");
        }
    }

    /// @notice Each pair's anchors are what its own swaps, activation and resets left; a removed pair's are zero.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_anchorsMoveOnlyOnTheirOwnPair() external view {
        for (uint16 p; p <= handler.MAX_PAIRS(); ++p) {
            ManagedPoolHandler.GhostPair memory g = handler.ghostPair(p);
            assertEq(pool.priceAnchor(p, true), g.anchors[0], "baseToQuote anchor");
            assertEq(pool.priceAnchor(p, false), g.anchors[1], "quoteToBase anchor");
        }
    }

    /// @notice Each route's credit is what its own last fill left, on its own pair, and stays below the pair's
    /// largest input-value denominator (its price scale or the largest price it filled at), as in
    /// `DirectPropAMMInvariant`.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_creditsStayOnTheirRouteAndBelowTheirModulus() external view {
        bytes32[2] memory customers = [handler.CUSTOMER_A(), handler.CUSTOMER_B()];
        for (uint16 p; p < handler.ghostPairCount(); ++p) {
            ManagedPoolHandler.GhostPair memory g = handler.ghostPair(p);
            uint256 modulus = g.scale > g.maxObservedPrice ? g.scale : g.maxObservedPrice;
            for (uint256 i; i < handler.NPARTIES(); ++i) {
                for (uint256 c; c < 2; ++c) {
                    bytes32 key = pool.roundingRouteKey(p, handler.party(i), customers[c]);
                    uint256 credit = pool.roundingCredit(key);
                    assertEq(credit, handler.ghostCredit(key), "a route's credit moved without its own fill");
                    assertLt(credit, modulus, "credit at or above its modulus");
                }
            }
        }
    }

    /// @notice Each live pair's quote reverts exactly as its own oracle and anchors say, and prices otherwise; one
    /// pair's broken or moved feed reaches no other pair that doesn't read it.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_quotesFollowTheirOwnOracle() external view {
        for (uint16 p; p <= handler.ghostPairCount(); ++p) {
            for (uint256 d; d < 2; ++d) {
                bool baseToQuote = d == 0;
                bytes memory expected = handler.expectedQuoteError(p, baseToQuote);
                (bool ok, bytes memory ret) = address(pool)
                    .staticcall(
                        abi.encodeCall(IManagedDirectPropAMM.quoteExactInput, (p, address(this), baseToQuote, 1e6))
                    );
                if (expected.length == 0) {
                    assertTrue(ok, "a quote its oracle allows reverted");
                } else {
                    assertFalse(ok, "a quote its oracle refuses priced");
                    assertEq(ret, expected, "a quote reverted for another pair's reason");
                }
            }
        }
    }

    /// @notice `pairCount` is the number of pairs ever added, a removed index reads all zero and `None`, a live one
    /// its own configuration, and `tokenPairCount` counts the live pairs that use each token.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_pairIndexesAreNeverReused() external view {
        uint16 count = pool.pairCount();
        assertEq(count, handler.ghostPairCount(), "pairCount");
        uint256[3] memory uses;
        for (uint16 p; p <= handler.MAX_PAIRS(); ++p) {
            ManagedPoolHandler.GhostPair memory g = handler.ghostPair(p);
            IManagedDirectPropAMM.Pair memory info = pool.pair(p);
            if (!g.live) {
                assertEq(info.base, address(0), "a removed or unknown pair has a base");
                assertEq(uint8(info.access), uint8(IManagedDirectPropAMM.AccessMode.None), "a removed pair isn't None");
                continue;
            }
            assertLt(p, count, "a live pair past pairCount");
            assertEq(info.base, g.base, "base");
            assertEq(info.quote, g.quote, "quote");
            assertEq(address(info.oracle), address(g.oracle), "oracle");
            assertEq(info.priceScale, g.scale, "price scale");
            assertEq(info.maxPriceDeviationBps, g.deviationBps, "deviation");
            for (uint256 t; t < 3; ++t) {
                address token = address(handler.tokenAt(t));
                if (g.base == token || g.quote == token) ++uses[t];
            }
        }
        for (uint256 t; t < 3; ++t) {
            assertEq(pool.tokenPairCount(address(handler.tokenAt(t))), uses[t], "tokenPairCount");
        }
    }

    /// @notice Shows the campaign isn't vacuous: 32 campaign-shaped runs of 64 random calls from the setUp state must
    /// reach every path the invariants lean on, with every invariant holding after every eighth run. The campaign
    /// itself checks them after every call; more here would take the test past its gas limit under `forge coverage`.
    function test_handlerCoverage() external {
        // The paths don't depend on the gas schedule, and on Tempo's (`--network tempo`, where the TIP-1022 registry
        // has code) 48 runs exceed a test's gas limit; the campaign itself runs there.
        if (address(0xfDC0000000000000000000000000000000000000).code.length != 0) {
            vm.skip(true, "runs without --network tempo");
            return;
        }
        uint256[7] memory total;
        // Inventory exhaustion needs a withdrawal followed by an otherwise executable swap. Random access,
        // oracle and pause changes can mask that refusal, so cover both swap forms from the known initial state
        // before the random sequences. Use the normal handler/model and restore the state, not a synthetic count.
        uint256 inventorySnapshot = vm.snapshotState();
        handler.withdraw(2, 0, 2, 0); // Owner withdraws all but one quote-token unit to the treasury.
        uint256 validCustomerAmount = (uint256(1) << 200) | 1; // Nonzero customer and at least two amount units.
        handler.swapListed(0, 0, true, validCustomerAmount);
        handler.swapListedExactOut(0, 0, true, validCustomerAmount);
        assertEq(handler.inventoryRefusals(), 2, "both swap forms must reach the inventory check");
        this.invariant_inventoryIsConservedPerToken();
        this.invariant_anchorsMoveOnlyOnTheirOwnPair();
        this.invariant_creditsStayOnTheirRouteAndBelowTheirModulus();
        total[4] = handler.inventoryRefusals();
        vm.revertToState(inventorySnapshot);
        uint256[9] memory refusals;
        uint256[20] memory accepted;
        uint256[20] memory refused;
        for (uint256 run; run < 32; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 i; i < 64; ++i) {
                _act(uint256(keccak256(abi.encode("coverage", run, i))));
            }
            if (run % 8 == 7) {
                this.invariant_accessIsWhatTheAcceptedCallsLeft();
                this.invariant_denialsAreCountedAndOverrideEverything();
                this.invariant_openNeedsThePause();
                this.invariant_inventoryIsConservedPerToken();
                this.invariant_anchorsMoveOnlyOnTheirOwnPair();
                this.invariant_creditsStayOnTheirRouteAndBelowTheirModulus();
                this.invariant_quotesFollowTheirOwnOracle();
                this.invariant_pairIndexesAreNeverReused();
            }
            uint256[7] memory counts = [
                handler.homeFills(),
                handler.sponsorFills(),
                handler.openFills(),
                handler.pricingRefusals(),
                handler.inventoryRefusals(),
                handler.pausedRefusals(),
                handler.virtualRefusals()
            ];
            for (uint256 k; k < 7; ++k) {
                total[k] += counts[k];
            }
            (uint256[9] memory r, uint256[20] memory a, uint256[20] memory f) = handler.stats();
            for (uint256 k; k < 9; ++k) {
                refusals[k] += r[k];
            }
            for (uint256 k; k < 20; ++k) {
                accepted[k] += a[k];
                refused[k] += f[k];
            }
            vm.revertToState(snapshot);
        }
        string[7] memory names = [
            "home-list fills",
            "sponsor fills",
            "Open fills",
            "swaps refused on pricing",
            "swaps refused on inventory",
            "swaps refused while paused",
            "withdrawals refused to a virtual address"
        ];
        for (uint256 k; k < names.length; ++k) {
            emit log_named_uint(names[k], total[k]);
            assertGt(total[k], 0, names[k]);
        }
        for (uint256 a = 2; a < 9; ++a) {
            emit log_named_uint(string.concat("swaps refused with takerAccess ", vm.toString(a)), refusals[a]);
            assertGt(refusals[a], 0, "a refusal no swap met");
        }
        // Every op the handler runs through `_run`: both accepted and refused, except where a refusal can't happen.
        string[20] memory ops = [
            "setDenied",
            "setMembers",
            "addSponsor",
            "setSponsorEnabled",
            "setPairSponsor",
            "resetSponsor",
            "transferSponsorAdmin",
            "cancelSponsorAdminTransfer",
            "acceptSponsorAdmin",
            "setPairAccess",
            "closePair",
            "pause / unpause",
            "moveOracle",
            "warp",
            "fund",
            "withdraw",
            "removePair",
            "addPair",
            "resetPriceAnchor",
            "setMaxPriceDeviationBps"
        ];
        for (uint256 k; k < ops.length; ++k) {
            emit log_named_uint(string.concat(ops[k], ": accepted"), accepted[k]);
            emit log_named_uint(string.concat(ops[k], ": refused"), refused[k]);
            assertGt(accepted[k], 0, ops[k]);
            if (k != 12 && k != 13) assertGt(refused[k], 0, ops[k]);
        }
    }

    /// @dev One handler call, weighted as the campaign's selectors are, with its arguments drawn from `seed`.
    function _act(uint256 seed) internal {
        uint256 a = uint256(keccak256(abi.encode(seed, 0)));
        uint256 b = uint256(keccak256(abi.encode(seed, 1)));
        uint256 c = uint256(keccak256(abi.encode(seed, 2)));
        uint256 d = uint256(keccak256(abi.encode(seed, 3)));
        uint256 action = seed % 23;
        if (action == 0) handler.swap(a, b, c, d & 1 == 0, d & 2 == 0, d >> 2);
        else if (action == 1) handler.swapListed(a, b, d & 1 == 0, d >> 2);
        else if (action == 2) handler.swapListedExactOut(a, b, d & 1 == 0, d >> 2);
        else if (action == 3) handler.setDenied(a, b, c & 1 == 0, d);
        else if (action == 4) handler.setMembers(a, b, c, d, c & 1 == 0, d >> 8);
        else if (action == 5) handler.addSponsor(a, b, c);
        else if (action == 6) handler.setSponsorEnabled(a, c & 1 == 0, b);
        else if (action == 7) handler.setPairSponsor(a, b, c & 1 == 0, d);
        else if (action == 8) handler.resetSponsor(a, b, c);
        else if (action == 9) handler.transferSponsorAdmin(a, b, c);
        else if (action == 10) handler.cancelSponsorAdminTransfer(a, b);
        else if (action == 11) handler.acceptSponsorAdmin(a, b);
        else if (action == 12) handler.setPairAccess(a, b, c, d & 1 == 0);
        else if (action == 13) handler.closePair(a, b);
        else if (action == 14) handler.setPaused(c & 1 == 0, b);
        else if (action == 15) handler.moveOracle(a, b, c);
        else if (action == 16) handler.fund(a, b, c);
        else if (action == 17) handler.withdraw(a, b, c, d);
        else if (action == 18) handler.removePair(a, b);
        else if (action == 19) handler.addPair(a, b);
        else if (action == 20) handler.warp(a);
        else if (action == 21) handler.resetPriceAnchor(a, c & 1 == 0, b);
        else handler.setMaxPriceDeviationBps(a, b, c);
    }
}
