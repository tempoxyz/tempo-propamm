// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";

import { ManagedPoolAccess } from "../../script/managed/ManagedPoolAccess.s.sol";
import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockAddressRegistry } from "../mocks/MockAddressRegistry.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { CoreDeploy } from "../v2/utils/CoreDeploy.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

/// @dev Reads its inputs from storage instead of the process environment, which parallel tests share, answers
/// `eth_getLogs` from logs a test recorded, refusing ranges wider than `maxBlockRange` as the Tempo RPC does, and
/// records how the last change was sent.
contract ManagedPoolAccessHarness is ManagedPoolAccess {
    struct StoredLog {
        address emitter;
        bytes32[] topics;
        bytes data;
        uint64 blockNumber;
        bool removed;
    }

    bytes internal _encoded;
    StoredLog[] internal _logs;
    uint256 public maxBlockRange = type(uint256).max;
    uint256 public logQueries;
    uint256 public identityQueries;
    uint256 public identityLogs;
    uint256 public burnIdentityQuery;

    function setBurnIdentityQuery(uint256 query) external {
        burnIdentityQuery = query;
    }
    uint256 public headerQueries;
    uint256 public cleanupLogFault;
    uint256 public changedHeaderQuery;
    uint256 public afterSendFault;

    function setChangedHeaderQuery(uint256 query) external {
        changedHeaderQuery = query;
    }

    function setAfterSendFault(uint256 fault) external {
        afterSendFault = fault;
    }

    function setCleanupLogFault(uint256 fault) external {
        cleanupLogFault = fault;
    }

    function _canonicalBlockHash(uint256 number) internal override returns (bytes32) {
        ++headerQueries;
        if (headerQueries == changedHeaderQuery) return bytes32(uint256(1));
        return keccak256(abi.encode(number));
    }
    /// @dev The caller mode and `msg.sender` in force when the last change was sent.
    VmSafe.CallerMode public sentMode;
    address public sentFrom;
    uint256 public sentWarningCount;

    string internal _envPrefix = "MANAGED_ACCESS_LEGACY_";

    function setEnvPrefix(string memory prefix) external {
        _envPrefix = prefix;
    }

    function envKey(string memory key) external view returns (string memory) {
        return _envKey(key);
    }

    function _envKey(string memory key) internal view override returns (string memory) {
        return string.concat(_envPrefix, key);
    }

    function setInput(Config calldata config) external {
        _encoded = abi.encode(config);
    }

    function setMaxBlockRange(uint256 maxBlockRange_) external {
        maxBlockRange = maxBlockRange_;
    }

    /// @notice Stores `logs` as emitted in block `blockNumber`, after every log stored before.
    function addLogs(Vm.Log[] calldata logs, uint64 blockNumber) external {
        _addLogs(logs, blockNumber, false);
    }

    /// @notice Stores `logs` as `addLogs` does, flagged as removed by a reorg.
    function addRemovedLogs(Vm.Log[] calldata logs, uint64 blockNumber) external {
        _addLogs(logs, blockNumber, true);
    }

    /// @notice The number of recorded events the full CHECK replay must process.
    function recordedLogCount() external view returns (uint256) {
        return _logs.length;
    }

    /// @notice The last change's warnings.
    function warnings() external view returns (string[] memory) {
        return _warnings;
    }

    /// @notice What `check` says `account` is.
    function kind(address account) external view returns (string memory) {
        return _kind(account);
    }

    /// @notice Describes a role without treating its getters as verified custody.
    function named(address account) external view returns (string memory) {
        return _named(account);
    }

    /// @notice Seeds event-discovered sponsors for bounded reconciliation tests.
    function seedSponsors(IManagedDirectPropAMM pool, uint64[] memory ids) external {
        Replay storage r = _replay[0];
        for (uint256 i; i < ids.length; ++i) {
            uint64 id = ids[i];
            r.sponsorIds.push(id);
            (r.sponsors[id].admin, r.sponsors[id].enabled, r.sponsors[id].generation) = pool.sponsor(id);
        }
    }

    /// @notice Runs the production sponsor-reconciliation loop on seeded history.
    function checkSponsors(Config memory config) external {
        _checkReplayedSponsors(config, _replay[0]);
    }

    /// @notice Runs the nested per-pair reporting loop without its outer CHECK work.
    function reportSponsor(IManagedDirectPropAMM pool, uint64 id, uint16 pairs) external view {
        _reportSponsor(pool, id, pairs);
    }

    /// @notice Previews a batch through the production change predicate.
    function previewAccounts(Config memory config) external returns (uint256) {
        return _logAccountChange(config);
    }

    /// @notice Runs the real environment inputs, for the one test that sets the environment.
    function runEnv() external returns (bytes memory) {
        return _run(super._readConfig());
    }

    /// @notice The real environment reader, for the one test that sets the environment.
    function readEnvConfig() external view returns (Config memory) {
        return super._readConfig();
    }

    function _readConfig() internal view override returns (Config memory) {
        return abi.decode(_encoded, (Config));
    }

    function _send(address target, bytes memory data) internal override {
        (sentMode, sentFrom,) = vm.readCallers();
        sentWarningCount = _warnings.length;
        super._send(target, data);
        if (afterSendFault == 1) vm.roll(block.number + 1);
        if (afterSendFault == 2) {
            // An invalid post-call record must not be excused by the already-proved history.
            Config memory config = _readConfig();
            IManagedDirectPropAMM.Pair memory p;
            p.base = address(1);
            vm.mockCall(target, abi.encodeCall(IManagedDirectPropAMM.pair, (config.pairIndex)), abi.encode(p));
        }
    }

    function _addLogs(Vm.Log[] calldata logs, uint64 blockNumber, bool removed) internal {
        for (uint256 i; i < logs.length; ++i) {
            StoredLog storage stored = _logs.push();
            stored.emitter = logs[i].emitter;
            stored.topics = logs[i].topics;
            stored.data = logs[i].data;
            stored.blockNumber = blockNumber;
            stored.removed = removed;
        }
    }

    function _getLogs(uint256 fromBlock, uint256 toBlock, address emitter)
        internal
        virtual
        override
        returns (Vm.EthGetLogs[] memory logs)
    {
        return _fixtureLogs(fromBlock, toBlock, emitter, bytes32(0), 0);
    }

    function _getIdentityLogs(uint256 fromBlock, uint256 toBlock, address emitter, bytes32 kind, uint16 pairIndex)
        internal
        virtual
        override
        returns (Vm.EthGetLogs[] memory logs)
    {
        require(
            kind == IManagedDirectPropAMM.PairAdded.selector || kind == IManagedDirectPropAMM.OracleUpdated.selector
                || kind == IManagedDirectPropAMM.PairRemoved.selector,
            "identity query event"
        );
        if (burnIdentityQuery != 0 && gasleft() < REPLAY_GAS_RESERVE) {
            revert UnexpectedState("queried without reserve");
        }
        ++identityQueries;
        logs = _fixtureLogs(fromBlock, toBlock, emitter, kind, pairIndex);
        identityLogs += logs.length;
        if (identityQueries == burnIdentityQuery) {
            while (gasleft() > REPLAY_GAS_RESERVE - 100_000) { }
        }
    }

    function _fixtureLogs(uint256 fromBlock, uint256 toBlock, address emitter, bytes32 kind, uint16 pairIndex)
        internal
        returns (Vm.EthGetLogs[] memory logs)
    {
        ++logQueries;
        require(toBlock >= fromBlock && toBlock - fromBlock < maxBlockRange, "query exceeds max block range");
        uint256 count;
        bool[] memory matches = new bool[](_logs.length);
        for (uint256 i; i < _logs.length; ++i) {
            StoredLog storage stored = _logs[i];
            matches[i] = stored.emitter == emitter && stored.blockNumber >= fromBlock && stored.blockNumber <= toBlock
                && (kind == bytes32(0)
                    || (stored.topics.length >= 2
                        && stored.topics[0] == kind
                        && stored.topics[1] == bytes32(uint256(pairIndex))));
            if (matches[i]) ++count;
        }
        logs = new Vm.EthGetLogs[](count);
        uint256 n;
        for (uint256 i; i < _logs.length; ++i) {
            if (!matches[i]) continue;
            StoredLog storage stored = _logs[i];
            logs[n].emitter = stored.emitter;
            logs[n].topics = stored.topics;
            logs[n].data = stored.data;
            logs[n].blockNumber = stored.blockNumber;
            logs[n].logIndex = i;
            logs[n].blockHash = keccak256(abi.encode(uint256(stored.blockNumber)));
            logs[n].transactionHash = keccak256(abi.encode(i, stored.blockNumber));
            logs[n].removed = stored.removed;
            ++n;
        }
        if (cleanupLogFault != 0 && logs.length != 0) {
            if (cleanupLogFault == 1) logs[0].emitter = address(1);
            if (cleanupLogFault == 2) logs[0].removed = true;
            if (cleanupLogFault == 3) logs[0].blockNumber = 0;
            if (cleanupLogFault == 4) logs[0].blockHash = bytes32(uint256(1));
            if (cleanupLogFault == 5) logs[0].logIndex = 0;
            if (cleanupLogFault == 15) logs[0].topics[0] = keccak256("unrelated event");
            if (cleanupLogFault == 16 && logs.length > 1) {
                (logs[0], logs[1]) = (logs[1], logs[0]);
            }
            if (cleanupLogFault == 17 && kind == IManagedDirectPropAMM.OracleUpdated.selector) {
                logs[0].blockHash = bytes32(uint256(1));
            }
            if (cleanupLogFault == 18) logs[0].blockNumber = uint64(toBlock + 1);
            if (cleanupLogFault == 6) logs[0].topics = new bytes32[](0);
            if (cleanupLogFault == 7) logs[0].transactionHash = bytes32(0);
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics.length == 0) continue;
                if (logs[i].topics[0] == IManagedDirectPropAMM.PairAdded.selector) {
                    if (cleanupLogFault == 8) logs[i].data = hex"01";
                    if (cleanupLogFault == 9) logs[i].topics[1] = bytes32(uint256(999));
                    if (cleanupLogFault == 10) logs[i].topics[2] = bytes32(type(uint256).max);
                    if (cleanupLogFault == 11) logs[i].topics[1] = bytes32(type(uint256).max);
                }
                if (logs[i].topics[0] == IManagedDirectPropAMM.OracleUpdated.selector) {
                    if (cleanupLogFault == 12) logs[i].topics[2] = bytes32(uint256(1));
                    if (cleanupLogFault == 13) logs[i].data = abi.encode(uint256(256));
                    if (cleanupLogFault == 14) logs[i].topics[3] = bytes32(0);
                }
            }
        }
    }
}

/// @dev Measures fresh log allocations at the production chunk boundary, without retaining their pointers.
contract ManagedPoolAccessMemoryHarness is ManagedPoolAccessHarness {
    uint256 public firstMemory;
    uint256 public lastMemory;
    uint256 public peakMemory;
    uint256 public lateFault;

    function setLateFault(uint256 fault) external {
        lateFault = fault;
    }

    function resetMemoryMeasurements() external {
        firstMemory = 0;
        lastMemory = 0;
        peakMemory = 0;
    }

    /// @dev The unfreed control uses the same allocations but deliberately retains the advancing pointer.
    function unfreedControl(uint256 from, uint256 last, address emitter) external {
        for (; from <= last; ++from) {
            _getLogs(from, from, emitter);
        }
    }

    function _getIdentityLogs(uint256 from, uint256 last, address emitter, bytes32 kind, uint16 pairIndex)
        internal
        override
        returns (Vm.EthGetLogs[] memory logs)
    {
        if (kind == IManagedDirectPropAMM.PairAdded.selector) {
            uint256 start;
            assembly ("memory-safe") { start := mload(0x40) }
            if (firstMemory == 0) firstMemory = start;
            lastMemory = start;
        }
        logs = super._getIdentityLogs(from, last, emitter, kind, pairIndex);
        if (from == 43 && lateFault == 1 && logs.length != 0) logs[0].removed = true;
        if (from == 42 && lateFault == 2 && kind == IManagedDirectPropAMM.OracleUpdated.selector) {
            logs[0].topics[2] = bytes32(uint256(1));
        }
        uint256 end;
        assembly ("memory-safe") { end := mload(0x40) }
        if (end > peakMemory) peakMemory = end;
    }

    function _getLogs(uint256 from, uint256 last, address emitter)
        internal
        override
        returns (Vm.EthGetLogs[] memory logs)
    {
        uint256 start;
        assembly ("memory-safe") { start := mload(0x40) }
        if (firstMemory == 0) firstMemory = start;
        lastMemory = start;
        logs = super._getLogs(from, last, emitter);
        if (from == 41 && lateFault == 1) logs[0].removed = true;
        if (from == 42 && lateFault == 2) {
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics[0] == IManagedDirectPropAMM.OracleUpdated.selector) {
                    logs[i].topics[2] = bytes32(uint256(1));
                }
            }
        }
        uint256 end;
        assembly ("memory-safe") { end := mload(0x40) }
        if (end > peakMemory) peakMemory = end;
    }
}

/// @dev A sponsor admin contract with odd getters: `owner()` reverts, `getThreshold()` answers two words and
/// `getOwners()` a malformed array. CHECK must describe it, not abort.
contract OddAdmin {
    function owner() external pure returns (address) {
        revert("no owner");
    }

    function getThreshold() external pure returns (uint256, uint256) {
        return (1, 2);
    }

    function getOwners() external pure returns (bytes memory) {
        return hex"00";
    }
}

/// @dev A sponsor admin contract whose `getThreshold()` and `getOwners()` burn every unit of gas they get and whose
/// `owner()` answers 64 KiB. CHECK must still describe it and report drift.
contract GasBurningAdmin {
    function getThreshold() external view returns (uint256) {
        while (gasleft() > 1000) { }
        return 1;
    }

    function getOwners() external view returns (address[] memory) {
        while (gasleft() > 1000) { }
        return new address[](0);
    }

    function owner() external pure returns (address) {
        assembly {
            return(0, 65536)
        }
    }
}

/// @dev Consumes the entire bounded oracle probe without affecting pair registration.
contract GasBurningOracle is IPriceOracle {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestPrice() external pure returns (uint256, uint256) {
        assembly ("memory-safe") { invalid() }
    }
}

/// @dev Bounds a nested reporting regression without creating thousands of pairs.
contract SlowAdmissions {
    function sponsor(uint64) external pure returns (address, bool, uint32) {
        return (address(1), true, 1);
    }

    function pendingSponsorAdmin(uint64) external pure returns (address) {
        return address(0);
    }

    function pairSponsor(uint16, uint64) external view returns (bool) {
        uint256 start = gasleft();
        while (start - gasleft() < 1_000_000) { }
        return true;
    }
}

/// @dev Answers like a Safe: `getThreshold()` and `getOwners()`.
contract SafeLike {
    address[] internal _owners;

    constructor(address[] memory owners_) {
        _owners = owners_;
    }

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }
}

/// @dev Answers `pairCount` and `MAX_BATCH` like a pool, and `tokenPairCount` with an overflowing count.
contract PoolLike {
    function pairCount() external pure returns (uint16) {
        return 1;
    }

    function MAX_BATCH() external pure returns (uint256) {
        return 100;
    }

    function tokenPairCount(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice `ManagedPoolAccess` against a two-pair `ManagedDirectPropAMM`: the calldata of each mode, the simulation
/// as the sender, the input checks and warnings, and `CHECK`'s findings, account reports and event replay.
/// @dev Runs on mock tokens, and under `forge test --network tempo` too; the script itself calls no precompile.
contract ManagedPoolAccessTest is Test {
    uint256 internal constant PRICE = 105_000_000;
    uint16 internal constant PAIR = 0;
    uint16 internal constant OTHER_PAIR = 1;
    uint64 internal constant HOME = 0;
    uint64 internal constant ALPHA = 7;
    uint64 internal constant BETA = 9;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal alpha = makeAddr("alpha");
    address internal beta = makeAddr("beta");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal virtualAccount = VirtualAddress.make(0x12345678, 1);

    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockTIP20 internal eurx;
    MockOracle internal oracle;
    ManagedDirectPropAMM internal pool;
    ManagedPoolAccessHarness internal script;

    function setUp() external {
        vm.warp(1_000_000);
        vm.roll(100);
        prime = new MockTIP20("PRIME", 6);
        pathUsd = new MockTIP20("pathUSD", 6);
        eurx = new MockTIP20("EURX", 18);
        oracle = new MockOracle(8, PRICE, block.timestamp);
        pool = _deploy();
        script = new ManagedPoolAccessHarness();
    }

    PoolFactory internal cloneFactory;

    function _recordClone() internal returns (ManagedDirectPropAMM fresh) {
        PoolFactory factory = new PoolFactory();
        cloneFactory = factory;
        vm.recordLogs();
        fresh = ManagedDirectPropAMM(factory.createPool(owner, bytes32(0)));
        script.addLogs(vm.getRecordedLogs(), 10);
    }

    function test_checkReplaysSettlerReplacements() external {
        ManagedDirectPropAMM fresh = _recordClone();
        ManagedPoolAccess.Config memory config = _check();
        config.pool = fresh;
        config.fromBlock = 10;
        config.expectedFactory = address(cloneFactory);
        assertEq(script.check(config).length, 0);
        address replacement = address(new OddAdmin());
        _recordAs(owner, 11, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setSettler, (replacement)));
        // A replacement the operator reviewed passes only when named.
        config.expectedSettler = replacement;
        assertEq(script.check(config).length, 0);
        vm.prank(owner);
        fresh.setSettler(alice);
        string[] memory findings = script.check(config);
        assertEq(findings.length, 2);
        assertEq(findings[0], "Settler is not the trusted settler: takers following the routing guide refuse this pool");
        assertEq(findings[1], "settler: the events disagree with the chain");
    }

    function test_checkReplaysRouterMembershipAcrossOwnerHandoffAndRevocation() external {
        ManagedPoolAccess.Config memory config = _membershipCheck();
        address router = address(new OddAdmin());
        _recordMember(config.pool, owner, HOME, router, true);
        _recordMember(config.pool, owner, HOME, router, true);
        _recordMember(config.pool, alpha, ALPHA, router, true);
        _recordAs(owner, 11, address(config.pool), abi.encodeCall(IManagedDirectPropAMM.transferOwnership, (alice)));
        _recordAs(alice, 11, address(config.pool), abi.encodeCall(IManagedDirectPropAMM.acceptOwnership, ()));
        assertEq(script.check(config).length, 0);
        assertTrue(config.pool.takerAllowed(PAIR, router, HOME));
        assertTrue(config.pool.takerAllowed(PAIR, router, ALPHA));
        _recordMember(config.pool, alice, HOME, router, false);
        assertEq(script.check(config).length, 0);
        assertFalse(config.pool.takerAllowed(PAIR, router, HOME));
        assertTrue(config.pool.takerAllowed(PAIR, router, ALPHA));
        _recordMember(config.pool, alpha, ALPHA, router, false);
        assertEq(script.check(config).length, 0);
        assertFalse(config.pool.takerAllowed(PAIR, router, ALPHA));
    }

    function test_checkFlagsRouterMembershipEventStateDrift() external {
        ManagedPoolAccess.Config memory config = _membershipCheck();
        address router = address(new OddAdmin());
        _recordMember(config.pool, owner, HOME, router, true);
        vm.prank(owner);
        config.pool.setMembers(PAIR, HOME, _one(router), false); // Omit the event deliberately.
        string[] memory findings = script.check(config);
        assertEq(findings.length, 1);
        assertEq(
            findings[0],
            string.concat("pair 0, the home list: the events disagree with the chain for ", vm.toString(router))
        );
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.CheckFailed.selector, 1));
        script.run();
    }

    function _membershipCheck() internal returns (ManagedPoolAccess.Config memory config) {
        config = _check();
        config.pool = _recordClone();
        config.fromBlock = 10;
        config.expectedFactory = address(cloneFactory);
        _recordAs(
            owner,
            11,
            address(config.pool),
            abi.encodeCall(
                IManagedDirectPropAMM.addPair,
                (address(prime), address(pathUsd), IPriceOracle(address(oracle)), 90_000, 50)
            )
        );
        _recordAs(owner, 11, address(config.pool), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        _recordAs(
            owner, 11, address(config.pool), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, ALPHA, true))
        );
        _recordAs(
            owner,
            11,
            address(config.pool),
            abi.encodeCall(IManagedDirectPropAMM.setPairAccess, (PAIR, IManagedDirectPropAMM.AccessMode.Listed))
        );
        config.expectedSponsorIds = new uint64[](1);
        config.expectedSponsorIds[0] = ALPHA;
        config.expectedSponsorAdmins = _one(alpha);
    }

    function _recordMember(IManagedDirectPropAMM target, address sender, uint64 sponsorId, address router, bool listed)
        internal
    {
        _recordAs(
            sender,
            11,
            address(target),
            abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, sponsorId, _one(router), listed))
        );
    }

    function test_checkCloneRequiresSettlerHistory() external {
        ManagedPoolAccess.Config memory config = _check();
        config.pool = _recordClone();
        config.expectedFactory = address(cloneFactory);
        string[] memory findings = script.check(config);
        assertEq(findings.length, 1);
        assertEq(findings[0], "Settler history not checked: set FROM_BLOCK to the pool's deployment block");
    }

    /// @dev A factory clone passes CHECK only from `EXPECTED_FACTORY`, proven by its `isPool`, with the settler takers
    /// approve: the default one unless `EXPECTED_SETTLER` names a reviewed replacement.
    function test_checkFlagsAnUntrustedSettler() external {
        ManagedPoolAccess.Config memory config = _check();
        config.pool = _recordClone();
        config.fromBlock = 10;
        string[] memory findings = script.check(config);
        assertEq(findings.length, 1);
        assertEq(findings[0], "Settler not authenticated: set EXPECTED_FACTORY to the PoolFactory takers trust");

        config.expectedFactory = address(new PoolFactory());
        findings = script.check(config);
        assertEq(findings.length, 1);
        assertEq(findings[0], "Pool's factory is not EXPECTED_FACTORY");

        config.expectedFactory = address(cloneFactory);
        assertEq(script.check(config).length, 0);
        address replacement = address(new OddAdmin());
        _recordAs(owner, 11, address(config.pool), abi.encodeCall(IManagedDirectPropAMM.setSettler, (replacement)));
        findings = script.check(config);
        assertEq(findings.length, 1);
        assertEq(findings[0], "Settler is not the trusted settler: takers following the routing guide refuse this pool");
        config.expectedSettler = replacement;
        assertEq(script.check(config).length, 0);
    }

    /// @dev Standalone creation cannot be proved. A settler or an expected factory adds settlement findings:
    /// no factory vouches for it and the default settler refuses it.
    function test_checkFlagsAStandalonePoolsSettler() external {
        ManagedPoolAccess.Config memory config = _check();
        assertEq(pool.factory(), address(0));
        assertEq(script.check(config).length, 1);
        PoolFactory factory = new PoolFactory();
        config.expectedFactory = address(factory);
        string[] memory findings = script.check(config);
        assertEq(findings.length, 2);
        assertEq(findings[0], "Pool's factory is not EXPECTED_FACTORY");
        config.expectedFactory = address(0);
        vm.prank(owner);
        pool.setSettler(alice);
        findings = script.check(config);
        assertEq(findings.length, 3);
        assertEq(findings[0], "Settler history not checked: set FROM_BLOCK to the pool's deployment block");
        assertEq(findings[1], "Settler not authenticated: set EXPECTED_FACTORY to the PoolFactory takers trust");
    }

    function test_checkSettlerInputsAreForCheckOnly() external {
        ManagedPoolAccess.Config memory config = _check();
        config.expectedSettler = alice;
        _reject(config, "EXPECTED_SETTLER needs EXPECTED_FACTORY");
        config = _accounts(ManagedPoolAccess.Mode.DENY, _one(alice));
        config.expectedFactory = alice;
        _reject(config, "EXPECTED_FACTORY is for CHECK");
    }

    function test_checkDoesNotTreatMissingOrMalformedRoutingViewsAsSafe() external {
        vm.mockCall(address(pool), abi.encodeCall(IManagedDirectPropAMM.factory, ()), bytes(""));
        assertEq(script.check(_check()).length, 1);
        vm.mockCall(address(pool), abi.encodeCall(IManagedDirectPropAMM.factory, ()), abi.encode(type(uint256).max));
        assertEq(script.check(_check()).length, 1);
    }

    function test_ownerCanReplaceSettlerWhileUnpaused() external {
        pool = _recordClone();
        vm.prank(owner);
        pool.unpause();
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.SET_SETTLER, _one(alice));
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.setSettler, (alice)));
        assertEq(pool.settler(), alice);
        assertFalse(pool.paused());
        _reject(config, "nothing to change");
    }

    function test_setSettlerRefusesVirtualAddressEvenWithCode() external {
        pool = _recordClone();
        address previous = pool.settler();
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.SET_SETTLER, _one(virtualAccount));
        _reject(config, "ACCOUNTS has a TIP-1022 virtual address, which can never call as settler");
        vm.etch(virtualAccount, hex"00");
        config.broadcast = true;
        _reject(config, "ACCOUNTS has a TIP-1022 virtual address, which can never call as settler");
        assertEq(pool.settler(), previous);
        assertEq(script.sentFrom(), address(0), "rejected before sending");
    }

    function test_setSettlerWarnsBeforeSendingCodelessAddress() external {
        pool = _recordClone();
        assertEq(alice.code.length, 0);
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.SET_SETTLER, _one(alice));
        config.broadcast = true;
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.setSettler, (alice)));
        assertEq(pool.settler(), alice, "intentional EOAs/future deployments remain allowed");
        assertEq(script.sentWarningCount(), 2, "both warnings precede broadcast");
        assertEq(script.warnings().length, 2);
        assertEq(
            script.warnings()[1],
            "Settler has no code: verify the address and chain; an EOA can spend inventory directly and a future"
            " deployment must be reviewed before use"
        );
    }

    function test_setSettlerCodeStillRequiresCustodyReviewAndWarningsReset() external {
        pool = _recordClone();
        _run(_accounts(ManagedPoolAccess.Mode.SET_SETTLER, _one(alice)));
        address replacement = address(new OddAdmin());
        assertEq(
            _run(_accounts(ManagedPoolAccess.Mode.SET_SETTLER, _one(replacement))),
            abi.encodeCall(IManagedDirectPropAMM.setSettler, (replacement))
        );
        assertEq(pool.settler(), replacement);
        assertEq(script.sentWarningCount(), 1);
        assertEq(script.warnings().length, 1, "previous no-code warning cleared");
        assertEq(
            script.warnings()[0],
            "Settler is custody-trusted: it can drain inventory without delivering input; review its authentication,"
            " prepayment checks and upgrade authority before submitting"
        );
    }

    function test_setSettlerRefusesUnrelatedInputsAndUnauthorizedCaller() external {
        pool = _recordClone();
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.SET_SETTLER, _two(alice, bob));
        _reject(config, "ACCOUNTS: exactly one settler");
        config.accounts = _one(alice);
        config.hasPairIndex = true;
        _reject(config, "PAIR_INDEX");
        config.hasPairIndex = false;
        config.caller = stranger;
        script.setInput(config);
        vm.expectRevert();
        script.run();
        assertNotEq(pool.settler(), alice);
    }

    // ---------------------------------------------------------------- lists and denials

    function test_listOnTheHomeListAsTheOwner() external {
        address[] memory accounts = _two(alice, bob);
        bytes memory expected = abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, HOME, accounts, true));
        vm.expectCall(address(pool), expected, 1);
        assertEq(_run(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, accounts)), expected);
        assertEq(script.sentFrom(), owner);
        assertTrue(pool.takerAllowed(PAIR, alice, HOME));
        assertTrue(pool.isMember(PAIR, HOME, bob));
        assertFalse(pool.isMember(OTHER_PAIR, HOME, bob), "lists are per pair");

        // Part of a batch may already be in place; the rest still changes.
        _run(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _two(alice, carol)));
        assertTrue(pool.isMember(PAIR, HOME, carol));
        assertEq(script.warnings().length, 0);
    }

    /// @dev Under a sponsor, the default sender is the sponsor's admin, and the owner can't edit its list.
    function test_listUnderASponsorAsItsAdmin() external {
        _addSponsor(ALPHA, alpha, PAIR);
        address[] memory accounts = _one(alice);
        assertEq(
            _run(_list(ManagedPoolAccess.Mode.LIST, PAIR, ALPHA, accounts)),
            abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, accounts, true))
        );
        assertEq(script.sentFrom(), alpha);
        assertTrue(pool.takerAllowed(PAIR, alice, ALPHA));

        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, ALPHA, accounts);
        config.caller = owner;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, ALPHA));
        config.caller = address(0);
        _run(config);
        assertFalse(pool.isMember(PAIR, ALPHA, alice));
    }

    /// @dev Regression, carried over from the TIP-403 access script this one replaced: `LIST` and `DENY` refuse a
    /// TIP-1022 virtual address, which never calls, so listing it admits nobody and denying it blocks nobody but makes
    /// every swap read the deny list. `DELIST` and `UNDENY` take one, to clean up what the pool accepted directly.
    function test_listAndDenyRefuseAVirtualAddress() external {
        _reject(
            _list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _two(alice, virtualAccount)),
            "ACCOUNTS has a TIP-1022 virtual address, which never calls: list its master"
        );
        _reject(
            _accounts(ManagedPoolAccess.Mode.DENY, _one(virtualAccount)),
            "ACCOUNTS has a TIP-1022 virtual address, which never calls: deny its master"
        );
        assertEq(pool.deniedCount(), 0, "no denial that blocks nobody");

        vm.startPrank(owner);
        pool.setDenied(_one(virtualAccount), true);
        pool.setMembers(PAIR, HOME, _one(virtualAccount), true);
        vm.stopPrank();
        _run(_accounts(ManagedPoolAccess.Mode.UNDENY, _one(virtualAccount)));
        _run(_list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _one(virtualAccount)));
        assertEq(pool.deniedCount(), 0);
        assertFalse(pool.isMember(PAIR, HOME, virtualAccount));
    }

    /// @dev On an `Open` pair everyone not denied is admitted, list or not, and a delisting from a sponsor leaves the
    /// home list: the script warns, and a denial is what stops the account.
    function test_delistWarnsAboutAnAccountThePairStillAdmits() external {
        _addSponsor(ALPHA, alpha, PAIR);
        vm.startPrank(owner);
        pool.setMembers(PAIR, HOME, _one(carol), true);
        vm.stopPrank();
        vm.prank(alpha);
        pool.setMembers(PAIR, ALPHA, _three(alice, bob, carol), true);

        _run(_list(ManagedPoolAccess.Mode.DELIST, PAIR, ALPHA, _one(carol)));
        string[] memory warnings = script.warnings();
        assertEq(warnings.length, 1);
        assertEq(warnings[0], string.concat(vm.toString(carol), " is still on pair 0's home list"));

        vm.startPrank(owner);
        pool.setDenied(_one(bob), true);
        pool.pause();
        pool.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Open);
        pool.unpause();
        vm.stopPrank();
        _run(_list(ManagedPoolAccess.Mode.DELIST, PAIR, ALPHA, _two(alice, bob)));
        warnings = script.warnings();
        assertEq(warnings.length, 2);
        assertEq(
            warnings[0], string.concat(vm.toString(alice), " is still admitted: pair 0 is Open; deny it (MODE=DENY)")
        );
        assertEq(
            warnings[1], string.concat(vm.toString(bob), " would be admitted once its denial is lifted: pair 0 is Open")
        );
        _run(_accounts(ManagedPoolAccess.Mode.DENY, _one(alice)));
        assertFalse(pool.takerAllowed(PAIR, alice, HOME));
    }

    function test_listWarnsAboutAListingThatAdmitsNobodyYet() external {
        vm.prank(owner);
        pool.closePair(PAIR);
        vm.prank(owner);
        pool.setDenied(_one(bob), true);
        _run(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _two(alice, bob)));
        string[] memory warnings = script.warnings();
        assertEq(warnings.length, 2);
        assertEq(warnings[0], "pair 0 is Closed: the listing admits nobody until the owner opens it");
        assertEq(warnings[1], string.concat(vm.toString(bob), " is denied: it trades nowhere"));
    }

    function test_denyAndUndenyOnlyAsOwner() external {
        address[] memory accounts = _two(alice, bob);
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.DENY, accounts);
        config.caller = owner;
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.setDenied, (accounts, true)));
        assertTrue(pool.denied(alice));
        assertEq(pool.deniedCount(), 2);

        config = _accounts(ManagedPoolAccess.Mode.UNDENY, _one(alice));
        config.caller = stranger;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
        config.caller = address(0);
        _run(config);
        assertFalse(pool.denied(alice));
        assertEq(pool.deniedCount(), 1);
    }

    // ---------------------------------------------------------------- sponsors

    /// @dev Every sponsor mode in order, each from its default sender or the owner, as the operator runs them.
    function test_sponsorLifecycle() external {
        ManagedPoolAccess.Config memory config = _sponsor(ManagedPoolAccess.Mode.ADD_SPONSOR, ALPHA, alpha);
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        assertEq(script.sentFrom(), owner);
        _assertSponsor(ALPHA, alpha, true, 1);

        config = _sponsor(ManagedPoolAccess.Mode.ADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        config.pairIndex = OTHER_PAIR;
        config.expectedBase = address(eurx);
        config.expectedOracle = address(pool.pair(OTHER_PAIR).oracle);
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (OTHER_PAIR, ALPHA, true)));
        assertTrue(pool.pairSponsor(OTHER_PAIR, ALPHA));
        assertFalse(pool.pairSponsor(PAIR, ALPHA));

        config = _sponsor(ManagedPoolAccess.Mode.DISABLE_SPONSOR, ALPHA, address(0));
        config.caller = owner;
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.setSponsorEnabled, (ALPHA, false)));
        _assertSponsor(ALPHA, alpha, false, 1);
        // Admitting a switched-off sponsor warns.
        config = _sponsor(ManagedPoolAccess.Mode.ADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        _run(config);
        assertEq(script.warnings().length, 2);
        assertEq(script.warnings()[1], "sponsor 7 is switched off: its users trade nowhere until ENABLE_SPONSOR");
        // An unrelated caller cannot widen access.
        config = _sponsor(ManagedPoolAccess.Mode.ENABLE_SPONSOR, ALPHA, address(0));
        config.caller = stranger;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
        config.caller = address(0);
        _run(config);
        _assertSponsor(ALPHA, alpha, true, 1);
        config = _sponsor(ManagedPoolAccess.Mode.UNADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        config.caller = owner;
        _run(config);
        assertFalse(pool.pairSponsor(PAIR, ALPHA));

        // Handover: propose, cancel, propose again, accept from the pending admin.
        config = _sponsor(ManagedPoolAccess.Mode.TRANSFER_SPONSOR_ADMIN, ALPHA, beta);
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.transferSponsorAdmin, (ALPHA, beta)));
        assertEq(script.sentFrom(), alpha);
        assertEq(pool.pendingSponsorAdmin(ALPHA), beta);
        config = _sponsor(ManagedPoolAccess.Mode.CANCEL_SPONSOR_ADMIN_TRANSFER, ALPHA, address(0));
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.cancelSponsorAdminTransfer, (ALPHA)));
        assertEq(pool.pendingSponsorAdmin(ALPHA), address(0));
        _reject(config, "nothing to change");
        _run(_sponsor(ManagedPoolAccess.Mode.TRANSFER_SPONSOR_ADMIN, ALPHA, beta));
        config = _sponsor(ManagedPoolAccess.Mode.ACCEPT_SPONSOR_ADMIN, ALPHA, address(0));
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.acceptSponsorAdmin, (ALPHA)));
        assertEq(script.sentFrom(), beta);
        _assertSponsor(ALPHA, beta, true, 1);
        // No pending admin: no default sender.
        _reject(config, "SPONSOR_ID has no pending admin");

        // A reset gives the id a new admin and voids every listing.
        config = _sponsor(ManagedPoolAccess.Mode.ADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        _run(config);
        vm.prank(beta);
        pool.setMembers(PAIR, ALPHA, _one(alice), true);
        assertTrue(pool.isMember(PAIR, ALPHA, alice));
        config = _sponsor(ManagedPoolAccess.Mode.RESET_SPONSOR, ALPHA, carol);
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.resetSponsor, (ALPHA, carol)));
        assertEq(script.warnings().length, 1);
        _assertSponsor(ALPHA, carol, true, 2);
        assertFalse(pool.isMember(PAIR, ALPHA, alice), "the reset voids the old listing");
    }

    // ---------------------------------------------------------------- pairs

    function test_firstOpeningReportsAnchorsAndWarnsBeforeSending() external {
        vm.startPrank(owner);
        uint16 pairIndex = pool.addPair(address(new MockTIP20("OTHER", 6)), address(pathUsd), oracle, 90_000, 50);
        vm.stopPrank();
        ManagedPoolAccess.Config memory config = _pairMode(ManagedPoolAccess.Mode.PAIR_ACCESS, pairIndex);
        config.access = IManagedDirectPropAMM.AccessMode.Listed;
        uint256 beforeReview = vm.snapshotState();
        // Report reads occur before and after the call, plus the warning probe and assertions below.
        vm.expectCall(address(pool), abi.encodeCall(IManagedDirectPropAMM.priceAnchor, (pairIndex, true)), 5);
        vm.expectCall(address(pool), abi.encodeCall(IManagedDirectPropAMM.priceAnchor, (pairIndex, false)), 4);
        bytes memory data = _run(config);
        assertEq(script.sentWarningCount(), 1, "initialization risk is surfaced before sending");
        assertEq(script.warnings().length, 1);
        assertEq(pool.priceAnchor(pairIndex, true), PRICE);
        assertEq(pool.priceAnchor(pairIndex, false), PRICE);

        // Printed calldata binds no price: replay against a fresh 2x observation still initializes both anchors.
        assertTrue(vm.revertToState(beforeReview));
        oracle.setPrice(2 * PRICE, vm.getBlockTimestamp());
        vm.prank(owner);
        (bool ok,) = address(pool).call(data);
        assertTrue(ok);
        assertEq(pool.priceAnchor(pairIndex, true), 2 * PRICE);
        assertEq(pool.priceAnchor(pairIndex, false), 2 * PRICE);
    }

    function test_pairAccessAndClosePair() external {
        ManagedPoolAccess.Config memory config = _pairMode(ManagedPoolAccess.Mode.CLOSE_PAIR, PAIR);
        config.caller = owner;
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.closePair, (PAIR)));
        assertEq(uint8(pool.pair(PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Closed));
        _reject(config, "nothing to change");

        // Reopening re-checks the pair's oracle: a stale one comes back with the pool's own error.
        config = _pairMode(ManagedPoolAccess.Mode.PAIR_ACCESS, PAIR);
        config.access = IManagedDirectPropAMM.AccessMode.Listed;
        vm.warp(1_000_000 + 90_001);
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, 1_000_000, 90_000));
        oracle.setPrice(PRICE, vm.getBlockTimestamp());
        assertEq(
            _run(config),
            abi.encodeCall(IManagedDirectPropAMM.setPairAccess, (PAIR, IManagedDirectPropAMM.AccessMode.Listed))
        );
        assertEq(uint8(pool.pair(PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Listed));
        assertEq(script.warnings().length, 0, "existing anchors do not initialize on reopening");

        // `Open` needs the pool paused, which the script checks before it runs anything.
        config.access = IManagedDirectPropAMM.AccessMode.Open;
        _reject(config, "ACCESS=open needs the pool paused: setPairAccess reverts NotPaused");
        vm.prank(owner);
        pool.pause();
        _run(config);
        assertEq(uint8(pool.pair(PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Open));
    }

    // ---------------------------------------------------------------- sending

    function test_broadcastSendsFromTheCaller() external {
        // Without `BROADCAST` the call only runs as the caller, under a prank.
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.DENY, _one(alice));
        config.caller = owner;
        _run(config);
        assertEq(uint8(script.sentMode()), uint8(VmSafe.CallerMode.Prank));
        assertEq(script.sentFrom(), owner);

        config.accounts = _one(bob);
        config.broadcast = true;
        script.setInput(config);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.DenyUpdated(bob, true, owner);
        script.run();
        assertEq(uint8(script.sentMode()), uint8(VmSafe.CallerMode.RecurrentBroadcast));
        assertEq(script.sentFrom(), owner);
        assertTrue(pool.denied(bob));
    }

    function test_poolErrorsComeBackFromTheSimulation() external {
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.DENY, _one(alice));
        config.caller = stranger;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
        config = _list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _one(alice));
        config.caller = stranger;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
        // An unknown pair or sponsor, and a registered id.
        _expectRun(
            _list(ManagedPoolAccess.Mode.LIST, 5, HOME, _one(alice)),
            abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, uint16(5))
        );
        config = _sponsor(ManagedPoolAccess.Mode.DISABLE_SPONSOR, BETA, address(0));
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, BETA));
        // A mode its sponsor's admin sends has no sender for an unregistered id.
        _reject(_list(ManagedPoolAccess.Mode.LIST, PAIR, BETA, _one(alice)), "SPONSOR_ID is not a registered sponsor");
        _reject(
            _sponsor(ManagedPoolAccess.Mode.TRANSFER_SPONSOR_ADMIN, BETA, beta),
            "SPONSOR_ID is not a registered sponsor"
        );
        _addSponsor(ALPHA, alpha, PAIR);
        _expectRun(
            _sponsor(ManagedPoolAccess.Mode.ADD_SPONSOR, ALPHA, beta),
            abi.encodeWithSelector(IManagedDirectPropAMM.SponsorExists.selector, ALPHA)
        );
        config = _sponsor(ManagedPoolAccess.Mode.ADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        config.pairIndex = 5;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, uint16(5)));
        // A switched-off sponsor can't list.
        vm.prank(owner);
        pool.setSponsorEnabled(ALPHA, false);
        _expectRun(
            _list(ManagedPoolAccess.Mode.LIST, PAIR, ALPHA, _one(alice)),
            abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, ALPHA)
        );
    }

    function test_refusesAChangeThatDidNotApply() external {
        // Each read after the call reports the state from before it.
        vm.mockCall(address(pool), abi.encodeCall(IManagedDirectPropAMM.denied, (alice)), abi.encode(false));
        _expectRun(
            _accounts(ManagedPoolAccess.Mode.DENY, _one(alice)),
            abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "denied")
        );
        vm.mockCall(
            address(pool), abi.encodeCall(IManagedDirectPropAMM.isMember, (PAIR, HOME, alice)), abi.encode(false)
        );
        _expectRun(
            _list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _one(alice)),
            abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "member")
        );
        vm.mockCall(
            address(pool), abi.encodeCall(IManagedDirectPropAMM.sponsor, (ALPHA)), abi.encode(address(0), false, 0)
        );
        _expectRun(
            _sponsor(ManagedPoolAccess.Mode.ADD_SPONSOR, ALPHA, alpha),
            abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "sponsor")
        );
        vm.clearMockedCalls();
    }

    // ---------------------------------------------------------------- input checks

    function test_refusesInputsThatDontFitTheMode() external {
        address[] memory none = new address[](0);
        address[] memory one = _one(alice);

        // PAIR_INDEX: only for the per-pair modes, and required there (0 is a real pair).
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, one);
        config.hasPairIndex = false;
        _reject(config, "PAIR_INDEX");
        config = _accounts(ManagedPoolAccess.Mode.DENY, one);
        config.hasPairIndex = true;
        _reject(config, "PAIR_INDEX");
        config = _sponsor(ManagedPoolAccess.Mode.ADMIT, ALPHA, address(0));
        _reject(config, "PAIR_INDEX");
        // SPONSOR_ID: nonzero for the sponsor modes, 0 or a sponsor for lists, unset otherwise.
        _reject(_sponsor(ManagedPoolAccess.Mode.ENABLE_SPONSOR, HOME, address(0)), "SPONSOR_ID");
        config = _accounts(ManagedPoolAccess.Mode.DENY, one);
        config.sponsorId = ALPHA;
        _reject(config, "SPONSOR_ID");
        config = _pairMode(ManagedPoolAccess.Mode.CLOSE_PAIR, PAIR);
        config.sponsorId = ALPHA;
        _reject(config, "SPONSOR_ID");
        // ACCOUNTS: required for list and deny changes, refused for the rest except CHECK.
        _reject(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, none), "ACCOUNTS");
        _reject(_accounts(ManagedPoolAccess.Mode.UNDENY, none), "ACCOUNTS");
        config = _sponsor(ManagedPoolAccess.Mode.ADD_SPONSOR, ALPHA, alpha);
        config.accounts = one;
        _reject(config, "ACCOUNTS");
        // SPONSOR_ADMIN: for ADD_SPONSOR, RESET_SPONSOR and TRANSFER_SPONSOR_ADMIN only.
        _reject(_sponsor(ManagedPoolAccess.Mode.ADD_SPONSOR, ALPHA, address(0)), "SPONSOR_ADMIN");
        _reject(_sponsor(ManagedPoolAccess.Mode.RESET_SPONSOR, ALPHA, address(0)), "SPONSOR_ADMIN");
        _reject(_sponsor(ManagedPoolAccess.Mode.TRANSFER_SPONSOR_ADMIN, ALPHA, address(0)), "SPONSOR_ADMIN");
        _reject(_sponsor(ManagedPoolAccess.Mode.ENABLE_SPONSOR, ALPHA, alpha), "SPONSOR_ADMIN");
        _reject(_sponsor(ManagedPoolAccess.Mode.ADD_SPONSOR, ALPHA, address(pool)), "SPONSOR_ADMIN is the pool");
        _reject(
            _sponsor(ManagedPoolAccess.Mode.RESET_SPONSOR, ALPHA, virtualAccount),
            "SPONSOR_ADMIN is a TIP-1022 virtual address, which can never call"
        );
        // ACCESS: for PAIR_ACCESS only, and required there.
        _reject(_pairMode(ManagedPoolAccess.Mode.PAIR_ACCESS, PAIR), "ACCESS");
        config = _pairMode(ManagedPoolAccess.Mode.CLOSE_PAIR, PAIR);
        config.access = IManagedDirectPropAMM.AccessMode.Listed;
        _reject(config, "ACCESS");

        // CHECK's inputs only for CHECK, and a change's sender inputs not for it.
        config = _accounts(ManagedPoolAccess.Mode.DENY, one);
        config.expectedSponsorIds = new uint64[](1);
        _reject(config, "EXPECTED_SPONSOR_* inputs are for CHECK");
        config = _accounts(ManagedPoolAccess.Mode.DENY, one);
        config.fromBlock = 1;
        _reject(config, "FROM_BLOCK is for CHECK");
        config = _accounts(ManagedPoolAccess.Mode.DENY, one);
        config.logBlockRange = 7;
        _reject(config, "LOG_BLOCK_RANGE is for CHECK");
        config = _check();
        config.caller = owner;
        _reject(config, "CALLER");
        config = _check();
        config.broadcast = true;
        _reject(config, "BROADCAST");
        _reject(_expecting(_single(ALPHA), new address[](0)), "EXPECTED_SPONSOR_* inputs need one entry per id");
        _reject(_expecting(_single(HOME), _one(alpha)), "EXPECTED_SPONSOR_IDS has 0, the home lists");
        _reject(_expecting(_single(ALPHA), _one(address(0))), "EXPECTED_SPONSOR_ADMINS");
        _reject(_expecting(_pair64(ALPHA, ALPHA), _two(alpha, alpha)), "EXPECTED_SPONSOR_IDS has a duplicate");
        config = _check();
        config.fromBlock = block.number + 1;
        _reject(config, "FROM_BLOCK");
        // A range without a start would be ignored, so it is refused.
        config = _check();
        config.logBlockRange = 5000;
        _reject(config, "LOG_BLOCK_RANGE needs FROM_BLOCK");
    }

    function test_refusesBadAccounts() external {
        _reject(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _one(address(0))), "ACCOUNTS has address(0)");
        _reject(_accounts(ManagedPoolAccess.Mode.DENY, _one(address(pool))), "ACCOUNTS has the pool");
        _reject(_list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _two(alice, alice)), "ACCOUNTS has a duplicate");
        // CHECK may report on the pool, but not on zero.
        ManagedPoolAccess.Config memory config = _check();
        config.accounts = _one(address(0));
        _reject(config, "ACCOUNTS has address(0)");
        config.accounts = _one(address(pool));
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.CheckFailed.selector, 1));
        script.run();

        // At most 50 accounts in every mode: a pool batch of 100 new accounts is over Tempo's cap at Forge's 130%.
        string memory tooMany = "ACCOUNTS has more than 50 accounts: split the batch";
        _reject(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _many(51)), tooMany);
        _reject(_accounts(ManagedPoolAccess.Mode.DENY, _many(51)), tooMany);
        config = _check();
        config.accounts = _many(51);
        _reject(config, tooMany);
        _run(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _many(50)));
        assertTrue(pool.isMember(PAIR, HOME, _many(50)[49]));
    }

    function test_refusesChangesThatChangeNothing() external {
        vm.prank(owner);
        pool.setMembers(PAIR, HOME, _one(alice), true);
        _reject(_list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _one(alice)), "nothing to change");
        _reject(_list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _one(bob)), "nothing to change");
        _reject(_accounts(ManagedPoolAccess.Mode.UNDENY, _one(alice)), "nothing to change");
        _addSponsor(ALPHA, alpha, PAIR);
        _reject(_list(ManagedPoolAccess.Mode.DELIST, PAIR, ALPHA, _one(bob)), "nothing to change");
        _reject(_sponsor(ManagedPoolAccess.Mode.ENABLE_SPONSOR, ALPHA, address(0)), "nothing to change");
        ManagedPoolAccess.Config memory config = _sponsor(ManagedPoolAccess.Mode.ADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        _reject(config, "nothing to change");
        config = _sponsor(ManagedPoolAccess.Mode.UNADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        config.pairIndex = OTHER_PAIR;
        config.expectedBase = address(eurx);
        config.expectedOracle = address(pool.pair(OTHER_PAIR).oracle);
        _reject(config, "nothing to change");
        config = _pairMode(ManagedPoolAccess.Mode.PAIR_ACCESS, PAIR);
        config.access = IManagedDirectPropAMM.AccessMode.Listed;
        _reject(config, "nothing to change");
    }

    /// @dev Raw probes with exact answers: an account without code, a `DirectPropAMM` (no `pairCount`), a v2 `Venue`
    /// (`pairCount` and `MAX_BATCH` as the pool's, but no `tokenPairCount`), and a contract that answers like a pool but with
    /// an invalid token pair count are refused by name in every mode.
    function test_refusesWhatIsNotAManagedPool() external {
        ManagedPoolAccess.Config memory config = _check();
        config.pool = IManagedDirectPropAMM(stranger);
        _reject(config, "POOL_ADDRESS has no code");
        config.pool = IManagedDirectPropAMM(
            address(new DirectPropAMM(prime, pathUsd, oracle, new MockAddressRegistry(), owner, stranger, 90_000, 50))
        );
        _reject(config, "POOL_ADDRESS is not a ManagedDirectPropAMM");
        address venue = CoreDeploy.factoryWith(makeAddr("settler")).createVenue(owner, bytes32("venue"));
        config.pool = IManagedDirectPropAMM(venue);
        _reject(config, "POOL_ADDRESS is not a ManagedDirectPropAMM");
        config = _accounts(ManagedPoolAccess.Mode.DENY, _one(alice));
        config.pool = IManagedDirectPropAMM(venue);
        _reject(config, "POOL_ADDRESS is not a ManagedDirectPropAMM");
        config.pool = IManagedDirectPropAMM(address(new PoolLike()));
        _reject(config, "POOL_ADDRESS is not a ManagedDirectPropAMM");
        // A pool answering a short word.
        config.pool = pool;
        vm.mockCall(address(pool), abi.encodeCall(IManagedDirectPropAMM.pairCount, ()), hex"01");
        _reject(config, "POOL_ADDRESS is not a ManagedDirectPropAMM");
        vm.clearMockedCalls();
        // A pool whose token pair count overflows the ABI type.
        vm.mockCall(
            address(pool),
            abi.encodeCall(IManagedDirectPropAMM.tokenPairCount, (address(0))),
            abi.encode(type(uint256).max)
        );
        _reject(config, "POOL_ADDRESS is not a ManagedDirectPropAMM");
        vm.clearMockedCalls();
    }

    function test_cleanupChunkMemoryIsBoundedWithLateIdentity() external {
        ManagedPoolAccessMemoryHarness measured = new ManagedPoolAccessMemoryHarness();
        script = measured;
        ManagedPoolAccess.Config memory config = _chunkMemoryHistory();
        _run(config);
        emit log_named_uint("cleanup first memory", measured.firstMemory());
        emit log_named_uint("cleanup last memory", measured.lastMemory());
        emit log_named_uint("cleanup peak memory", measured.peakMemory());
        assertEq(measured.lastMemory(), measured.firstMemory(), "each chunk reuses its temporary memory");
        assertLt(measured.peakMemory() - measured.firstMemory(), 32_768, "largest chunk, not cumulative logs");
        assertEq(script.logQueries(), 102);
        assertEq(script.headerQueries(), 6, "late oracle and removal retain canonical checks");
        measured.resetMemoryMeasurements();
        _run(config);
        assertEq(measured.lastMemory(), measured.firstMemory(), "repeated instance replays afresh");
        assertEq(script.logQueries(), 204);
        measured.setLateFault(1);
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "invalid cleanup log"));
        measured.setLateFault(2);
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "broken oracle history"));
        measured.setLateFault(0);
        measured.resetMemoryMeasurements();
        config.logBlockRange = 7;
        _run(config);
        assertEq(script.logQueries(), 219, "final partial range is replayed");
        assertEq(measured.lastMemory(), measured.firstMemory());
        assertLt(measured.peakMemory() - measured.firstMemory(), 65_536, "seven-block response bound");
        config.expectedOracle = address(oracle);
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "removed pair identity history")
        );
    }

    function test_checkChunkMemoryIsBoundedAndRetainsLateState() external {
        ManagedPoolAccessMemoryHarness measured = new ManagedPoolAccessMemoryHarness();
        script = measured;
        _chunkMemoryHistory();
        _recordAs(owner, 44, address(pool), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        _recordAs(alpha, 45, address(pool), abi.encodeCall(IManagedDirectPropAMM.transferSponsorAdmin, (ALPHA, beta)));
        _recordAs(beta, 46, address(pool), abi.encodeCall(IManagedDirectPropAMM.acceptSponsorAdmin, (ALPHA)));
        vm.roll(46);
        ManagedPoolAccess.Config memory config = _expecting(_single(ALPHA), _one(beta));
        config.fromBlock = 10;
        config.logBlockRange = 1;
        string[] memory findings = script.check(config);
        emit log_named_uint("CHECK first memory", measured.firstMemory());
        emit log_named_uint("CHECK last memory", measured.lastMemory());
        emit log_named_uint("CHECK peak memory", measured.peakMemory());
        assertEq(measured.lastMemory(), measured.firstMemory(), "CHECK reuses chunk memory");
        assertLt(measured.peakMemory() - measured.firstMemory(), 32_768);
        assertEq(findings.length, 1, "only standalone creation provenance finding");
        measured.resetMemoryMeasurements();
        assertEq(script.check(config), findings, "same instance returns the same complete report");
        assertEq(measured.lastMemory(), measured.firstMemory());
        vm.prank(owner);
        pool.setSponsorEnabled(ALPHA, false);
        findings = script.check(config);
        assertEq(findings.length, 3, "disabled sponsor, replay drift and standalone provenance");
        assertEq(findings[1], "sponsor 7: the events disagree with the chain");
    }

    function test_chunkMemoryUnfreedControlGrows() external {
        ManagedPoolAccessMemoryHarness measured = new ManagedPoolAccessMemoryHarness();
        script = measured;
        _chunkMemoryHistory();
        measured.unfreedControl(10, 43, address(pool));
        emit log_named_uint("unfreed first memory", measured.firstMemory());
        emit log_named_uint("unfreed last memory", measured.lastMemory());
        assertGt(measured.lastMemory() - measured.firstMemory(), 200_000, "control detects cumulative allocation");
    }

    /// @dev Real pool events put both an oracle change and removal after many non-identity chunks.
    function _chunkMemoryHistory() internal returns (ManagedPoolAccess.Config memory config) {
        pool = _recordDeployment(10);
        for (uint64 number = 11; number < 42; ++number) {
            _recordAs(
                owner,
                number,
                address(pool),
                abi.encodeCall(IManagedDirectPropAMM.setDenied, (_many(8), number % 2 == 0))
            );
        }
        _recordAs(owner, 42, address(pool), abi.encodeCall(IManagedDirectPropAMM.closePair, (PAIR)));
        MockOracle replacement = new MockOracle(8, PRICE, block.timestamp);
        _recordAs(owner, 42, address(pool), abi.encodeCall(IManagedDirectPropAMM.setOracle, (PAIR, replacement)));
        config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _one(alice));
        _recordAs(owner, 43, address(pool), abi.encodeCall(IManagedDirectPropAMM.removePair, (PAIR)));
        vm.roll(43);
        config.fromBlock = 10;
        config.logBlockRange = 1;
    }

    function test_cleanupQueriesOnlySelectedPairIdentityWhileCheckReadsAllLogs() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        _run(config);
        assertEq(script.logQueries(), 3);
        assertEq(script.identityQueries(), 3, "no unfiltered cleanup boundary");
        assertEq(script.identityLogs(), 3, "only selected pair addition, initial oracle and removal");
        assertGt(script.recordedLogCount(), 3, "fixture includes access events and another pair");
        ManagedPoolAccess.Config memory checkConfig = _check();
        checkConfig.fromBlock = 10;
        script.check(checkConfig);
        assertEq(script.logQueries(), 4, "CHECK still uses one unfiltered query");
        assertEq(script.identityQueries(), 3, "CHECK does not use cleanup filtering");
    }

    function test_cleanupFiltersNonzeroPairIndex() external {
        pool = _recordDeployment(10);
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, OTHER_PAIR, HOME, _one(alice));
        _recordAs(owner, 11, address(pool), abi.encodeCall(IManagedDirectPropAMM.closePair, (OTHER_PAIR)));
        _recordAs(owner, 12, address(pool), abi.encodeCall(IManagedDirectPropAMM.removePair, (OTHER_PAIR)));
        config.fromBlock = 10;
        _run(config);
        assertGt(OTHER_PAIR, 0);
        assertEq(script.identityLogs(), 3, "only the nonzero pair's identity");
        assertEq(script.identityQueries(), 3);
        assertEq(script.headerQueries(), 5);
        assertEq(pool.pair(PAIR).base, address(prime), "other pair remains live");
    }

    function test_cleanupReservesGasBeforeEachFilteredQueryAndAfterEmptyResponses() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        config.fromBlock = 13;
        vm.roll(20);
        for (uint256 query = 1; query <= 3; ++query) {
            script.setBurnIdentityQuery(query);
            script.setInput(config);
            vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.ReplayNeedsMoreGas.selector, 0));
            script.run{ gas: 32_000_000 }();
            assertEq(script.sentFrom(), address(0));
            assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
        }
    }

    function test_cleanupRejectsReorderedOracleStreamAndInconsistentHashes() external {
        pool = _recordDeployment(10);
        MockOracle replacement = new MockOracle(8, PRICE, block.timestamp);
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.closePair, (PAIR)));
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.setOracle, (PAIR, replacement)));
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _one(alice));
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.removePair, (PAIR)));
        config.fromBlock = 10;
        script.setCleanupLogFault(16);
        // A merge must not sort a backwards oracle stream into a valid chain.
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "broken oracle history"));
        script.setCleanupLogFault(17);
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "cleanup log block hash"));
        script.setCleanupLogFault(5);
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "invalid cleanup log"));
    }

    function test_cleanupRejectsFilteredLogOutsideRequestedRange() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        config.logBlockRange = 1;
        script.setCleanupLogFault(18);
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "invalid cleanup log"));
        assertEq(script.sentFrom(), address(0));
        assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
    }

    function test_cleanupEmptyLogRangesStopWithNamedGasRefusal() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        config.fromBlock = 13;
        config.logBlockRange = 1;
        vm.roll(1_000_000);
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.ReplayNeedsMoreGas.selector, 0));
        script.run{ gas: 32_000_000 }();
        assertEq(script.sentFrom(), address(0));
        assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
    }

    function test_cleanupEmptyRangesReportCumulativeProcessedLogs() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        config.logBlockRange = 1;
        vm.roll(1_000_000);
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.ReplayNeedsMoreGas.selector, 3));
        script.run{ gas: 32_000_000 }();
        assertEq(script.sentFrom(), address(0));
        assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
    }

    function test_cleanupIncludesFinalPartialRangeAfterEmptyRanges() external {
        pool = _recordDeployment(10);
        _retainedMemberSlot =
            _writtenSlot(abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, HOME, _one(alice), true)), owner);
        MockOracle replacement = new MockOracle(8, PRICE, block.timestamp);
        _recordAs(owner, 33, address(pool), abi.encodeCall(IManagedDirectPropAMM.closePair, (PAIR)));
        _recordAs(owner, 33, address(pool), abi.encodeCall(IManagedDirectPropAMM.setOracle, (PAIR, replacement)));
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _one(alice));
        _recordAs(owner, 33, address(pool), abi.encodeCall(IManagedDirectPropAMM.removePair, (PAIR)));
        config.fromBlock = 10;
        config.logBlockRange = 10;
        vm.roll(33);
        script.setMaxBlockRange(10);
        // The empty [20, 29] range must not skip the final [30, 33] oracle update and removal.
        _run(config);
        assertEq(script.logQueries(), 9);
        assertEq(script.headerQueries(), 5);
        assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(0));
        config.expectedOracle = address(oracle);
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "removed pair identity history")
        );
    }

    function test_removedPairCleanupReplaysOnceAndSkipsUnrelatedHeaders() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        // Unrelated access activity across many blocks must not multiply canonical-header RPC requests.
        for (uint64 number = 13; number < 77; ++number) {
            _recordAs(
                owner,
                number,
                address(pool),
                abi.encodeCall(IManagedDirectPropAMM.setDenied, (_one(bob), number % 2 == 0))
            );
        }
        _run(config);
        emit log_named_uint("log queries", script.logQueries());
        emit log_named_uint("header queries", script.headerQueries());
        assertEq(script.logQueries(), 3, "three filtered queries in one replay per run");
        assertEq(script.headerQueries(), 5, "two identity blocks and three head checks");
        _run(config);
        assertEq(script.logQueries(), 6, "a repeated call proves history again");
        assertEq(script.headerQueries(), 10, "no proof survives the call");
    }

    function test_removedPairCleanupSameBlockOrderAndOracleChain() external {
        pool = _recordDeployment(10);
        MockOracle replacement = new MockOracle(8, PRICE, block.timestamp);
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.closePair, (PAIR)));
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.setDenied, (_one(bob), true)));
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.setOracle, (PAIR, replacement)));
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.setDenied, (_one(bob), false)));
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _one(alice));
        _recordAs(owner, 10, address(pool), abi.encodeCall(IManagedDirectPropAMM.removePair, (PAIR)));
        config.fromBlock = 10;
        _run(config);
        assertEq(script.logQueries(), 3);
        assertEq(script.headerQueries(), 4, "one header for mixed same-block identity events");
        // A changed head and configuration must get a new proof, even on the same script instance.
        vm.roll(101);
        config.expectedOracle = address(oracle);
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "removed pair identity history")
        );
        config.expectedOracle = address(replacement);
        _run(config);
        assertEq(script.logQueries(), 6);
        assertEq(script.headerQueries(), 8);
        script.setCleanupLogFault(4);
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "cleanup log block hash"));
    }

    function test_removedPairCleanupRejectsHeadChangeDuringReplayAndAfterCall() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        for (uint256 query = 4; query <= 5; ++query) {
            script.setChangedHeaderQuery(query);
            _expectRun(
                config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "cleanup history reorg")
            );
            assertEq(script.sentFrom(), address(0));
            assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
        }
    }

    function test_removedPairCleanupRechecksSimulationBlockAndEmptyStateAfterCall() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        for (uint256 fault = 1; fault <= 2; ++fault) {
            script.setAfterSendFault(fault);
            _expectRun(
                config,
                abi.encodeWithSelector(
                    ManagedPoolAccess.UnexpectedState.selector,
                    fault == 1 ? "cleanup history reorg" : "removed pair state"
                )
            );
            vm.clearMockedCalls();
            assertEq(script.sentFrom(), address(0));
            assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
        }
    }

    function test_removedPairDelistClearsRetainedHomeListing() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        config.accounts = _two(alice, stranger);
        bytes32 slot = _retainedMemberSlot;
        assertEq(vm.load(address(pool), slot), bytes32(uint256(1)));
        _run(config);
        assertEq(vm.load(address(pool), slot), bytes32(0), "retained home entry cleared");
        assertFalse(pool.takerAllowed(PAIR, alice, HOME));
        assertEq(script.sentFrom(), owner);
        assertEq(script.sentWarningCount(), 2);
        assertTrue(_hasText(script.warnings()[0], "effective membership unchanged"));
        _run(config); // The public view cannot distinguish empty from retained: explicit cleanup is idempotent.
    }

    function test_removedPairDelistClearsSponsorAndResetEntries() external {
        for (uint256 reset; reset < 2; ++reset) {
            script = new ManagedPoolAccessHarness();
            ManagedPoolAccess.Config memory config = _removedCleanup(ALPHA, reset != 0);
            assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
            config.caller = reset == 0 ? owner : alpha;
            _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, ALPHA));
            config.caller = address(0);
            _run(config);
            assertEq(script.sentFrom(), reset == 0 ? alpha : carol);
            assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(0));
            assertFalse(pool.takerAllowed(PAIR, alice, ALPHA));
            _run(config);
        }
    }

    function test_removedPairUnadmitClearsRetainedAdmission() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(ALPHA, false);
        config.mode = ManagedPoolAccess.Mode.UNADMIT;
        config.accounts = new address[](0);
        config.caller = stranger;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
        config.caller = owner;
        assertEq(vm.load(address(pool), _retainedAdmissionSlot), bytes32(uint256(1)));
        _run(config);
        assertEq(vm.load(address(pool), _retainedAdmissionSlot), bytes32(uint256(2)), "retained admission removed");
        assertFalse(pool.pairSponsor(PAIR, ALPHA));
        assertEq(script.sentWarningCount(), 1);
        assertTrue(_hasText(script.warnings()[0], "effective access unchanged"));
        _run(config);
    }

    function test_removedPairCleanupUsesCurrentOwner() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        vm.prank(owner);
        pool.transferOwnership(bob);
        vm.prank(bob);
        pool.acceptOwnership();
        config.caller = owner;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotOwner.selector));
        config.caller = address(0);
        _run(config);
        assertEq(script.sentFrom(), bob);
        assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(0));
    }

    function test_removedPairCleanupRejectsMalformedOrNoncanonicalLogs() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        for (uint256 fault = 1; fault <= 15; ++fault) {
            script.setCleanupLogFault(fault);
            script.setInput(config);
            vm.expectRevert();
            script.run();
            assertEq(script.sentFrom(), address(0));
            assertEq(vm.load(address(pool), _retainedMemberSlot), bytes32(uint256(1)));
        }
    }

    function test_removedPairCleanupRequiresCompleteReviewedHistory() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        config.fromBlock = 0;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, PAIR));
        config.fromBlock = 11; // Misses PairAdded and the initial oracle.
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "incomplete pair identity")
        );
        config.fromBlock = 13; // Misses removal too.
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "removed pair identity history")
        );
        config.fromBlock = 10;
        config.expectedBase = address(eurx);
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "pair identity"));
        config.expectedBase = address(prime);
        config.expectedOracle = address(eurx);
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "removed pair identity history")
        );
        config.expectedOracle = address(oracle);
        config.pairIndex = pool.pairCount();
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, config.pairIndex));
        assertEq(script.sentFrom(), address(0));
    }

    function test_removedPairCleanupRejectsDuplicateLifecycle() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        Vm.Log[] memory duplicate = new Vm.Log[](1);
        duplicate[0].emitter = address(pool);
        duplicate[0].topics = new bytes32[](2);
        duplicate[0].topics[0] = IManagedDirectPropAMM.PairRemoved.selector;
        duplicate[0].topics[1] = bytes32(uint256(PAIR));
        script.addLogs(duplicate, 13);
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "identity event after removal")
        );
    }

    function test_removedPairCleanupBindsLastOracleAndDoesNotTouchLiveDuplicate() external {
        pool = _recordDeployment(10);
        MockOracle replacement = new MockOracle(8, PRICE, block.timestamp);
        _recordAs(owner, 11, address(pool), abi.encodeCall(IManagedDirectPropAMM.closePair, (PAIR)));
        _recordAs(owner, 11, address(pool), abi.encodeCall(IManagedDirectPropAMM.setOracle, (PAIR, replacement)));
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, HOME, _one(alice));
        _recordAs(owner, 12, address(pool), abi.encodeCall(IManagedDirectPropAMM.removePair, (PAIR)));
        config.fromBlock = 10;
        config.logBlockRange = 1;
        script.setMaxBlockRange(1);
        config.expectedOracle = address(oracle);
        _expectRun(
            config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "removed pair identity history")
        );
        config.expectedOracle = address(replacement);
        vm.startPrank(owner);
        uint16 live = pool.addPair(address(prime), address(pathUsd), replacement, 90_000, 50);
        pool.setMembers(live, HOME, _one(alice), true);
        vm.stopPrank();
        _run(config);
        assertTrue(pool.isMember(live, HOME, alice));
        config.pairIndex = live;
        _reject(config, "cleanup history requires a removed pair");
    }

    function test_removedPairHistoryCannotEnableOtherModes() external {
        ManagedPoolAccess.Config memory config = _removedCleanup(HOME, false);
        config.mode = ManagedPoolAccess.Mode.LIST;
        _reject(config, "FROM_BLOCK is for CHECK");
        config.mode = ManagedPoolAccess.Mode.ADMIT;
        config.accounts = new address[](0);
        config.sponsorId = ALPHA;
        _reject(config, "FROM_BLOCK is for CHECK");
        config.mode = ManagedPoolAccess.Mode.CLOSE_PAIR;
        config.sponsorId = 0;
        _reject(config, "FROM_BLOCK is for CHECK");
        config.fromBlock = 0;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, PAIR));
    }

    bytes32 internal _retainedMemberSlot;
    bytes32 internal _retainedAdmissionSlot;

    /// @dev Discover the actual slot written by the real method, never encode a storage-layout assumption.
    function _writtenSlot(bytes memory data, address caller) internal returns (bytes32 slot) {
        vm.record();
        vm.prank(caller);
        (bool ok,) = address(pool).call(data);
        assertTrue(ok);
        (, bytes32[] memory writes) = vm.accesses(address(pool));
        uint256 found;
        for (uint256 i; i < writes.length; ++i) {
            if (vm.load(address(pool), writes[i]) != bytes32(0)) {
                slot = writes[i];
                ++found;
            }
        }
        assertEq(found, 1, "exactly one nonzero access record written");
    }

    function _removedCleanup(uint64 sponsorId, bool reset) internal returns (ManagedPoolAccess.Config memory config) {
        pool = _recordDeployment(10);
        if (sponsorId != 0) {
            vm.prank(owner);
            pool.addSponsor(sponsorId, alpha);
            _retainedAdmissionSlot =
                _writtenSlot(abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, sponsorId, true)), owner);
        }
        _retainedMemberSlot = _writtenSlot(
            abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, sponsorId, _one(alice), true)),
            sponsorId == 0 ? owner : alpha
        );
        if (reset) {
            vm.prank(owner);
            pool.resetSponsor(sponsorId, carol);
        }
        config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, sponsorId, _one(alice));
        config.fromBlock = 10;
        _recordAs(owner, 12, address(pool), abi.encodeCall(IManagedDirectPropAMM.removePair, (PAIR)));
    }

    function test_delistClearsStaleResetMembershipWithoutChangingAccess() external {
        _addSponsor(ALPHA, alpha, PAIR);
        vm.prank(alpha);
        pool.setMembers(PAIR, ALPHA, _one(alice), true);
        vm.prank(owner);
        pool.resetSponsor(ALPHA, carol);
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, ALPHA, _one(alice));
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, _one(alice), false)));
        assertFalse(pool.isMember(PAIR, ALPHA, alice));
        assertEq(script.sentFrom(), carol);
        assertEq(script.sentWarningCount(), 1);
        assertTrue(_hasText(script.warnings()[0], "retained"));
        // The public view cannot distinguish a cleared or never-stored entry after a reset: cleanup is idempotent.
        _run(config);
        config.accounts = _one(stranger);
        _run(config); // Never stored, but safe to clear after a reset.
        config.caller = stranger;
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.NotSponsorAdmin.selector, ALPHA));
        config.caller = address(0);
        vm.prank(owner);
        pool.removePair(PAIR);
        _expectRun(config, abi.encodeWithSelector(IManagedDirectPropAMM.UnknownPair.selector, PAIR));
    }

    function test_delistMixedResetBatchPreviewsEveryCleanup() external {
        _addSponsor(ALPHA, alpha, PAIR);
        vm.prank(alpha);
        pool.setMembers(PAIR, ALPHA, _one(alice), true);
        vm.prank(owner);
        pool.resetSponsor(ALPHA, carol);
        vm.prank(carol);
        pool.setMembers(PAIR, ALPHA, _one(bob), true);
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.DELIST, PAIR, ALPHA, _two(alice, bob));
        assertEq(script.previewAccounts(config), 2, "both entries are submitted for cleanup");
        assertEq(_run(config), abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, _two(alice, bob), false)));
        assertEq(script.sentWarningCount(), 1);
        assertFalse(pool.isMember(PAIR, ALPHA, bob));
    }

    function test_sponsorReactivationWarnsBeforeSendingAndPreservesResetGenerations() external {
        _addSponsor(ALPHA, alpha, PAIR);
        vm.prank(alpha);
        pool.setMembers(PAIR, ALPHA, _one(alice), true);
        vm.prank(owner);
        pool.resetSponsor(ALPHA, carol);
        vm.prank(carol);
        pool.setMembers(PAIR, ALPHA, _one(bob), true);
        vm.prank(owner);
        pool.setSponsorEnabled(ALPHA, false);
        ManagedPoolAccess.Config memory config = _sponsor(ManagedPoolAccess.Mode.ENABLE_SPONSOR, ALPHA, address(0));
        _run(config);
        assertEq(script.sentWarningCount(), 1);
        assertTrue(_hasText(script.warnings()[0], "current-generation"));
        assertTrue(_hasText(script.warnings()[0], "MODE=CHECK"));
        assertFalse(pool.isMember(PAIR, ALPHA, alice));
        assertTrue(pool.isMember(PAIR, ALPHA, bob));
        vm.prank(owner);
        pool.setPairSponsor(PAIR, ALPHA, false);
        config = _sponsor(ManagedPoolAccess.Mode.ADMIT, ALPHA, address(0));
        config.hasPairIndex = true;
        _run(config);
        assertEq(script.sentWarningCount(), 1);
        assertTrue(_hasText(script.warnings()[0], "current-generation"));
        assertTrue(_hasText(script.warnings()[0], "FROM_BLOCK"));
        assertFalse(pool.isMember(PAIR, ALPHA, alice));
        assertTrue(pool.isMember(PAIR, ALPHA, bob));
    }

    function test_custodyGettersAreExplicitlyUnverifiedInNamedOutput() external {
        SafeLike fake = new SafeLike(_three(alice, bob, carol));
        assertTrue(_hasText(script.named(address(fake)), "self-reported Safe views (unverified)"));
        assertTrue(_hasText(script.named(address(pool)), "self-reported owner() (unverified)"));
    }

    function test_checkPairProbesStopWithNamedGasRefusal() external {
        GasBurningOracle burner = new GasBurningOracle();
        vm.startPrank(owner);
        for (uint16 i; i < 40; ++i) {
            pool.addPair(address(prime), address(pathUsd), IPriceOracle(address(burner)), 90_000, 50);
        }
        vm.stopPrank();
        ManagedPoolAccess.Config memory config = _check();
        vm.expectPartialRevert(ManagedPoolAccess.ReplayNeedsMoreGas.selector);
        script.check{ gas: 32_000_000 }(config);
        assertEq(script.check(config).length, 1);
    }

    function test_checkSponsorProbesStopWithNamedGasRefusal() external {
        GasBurningAdmin burner = new GasBurningAdmin();
        uint64[] memory ids = new uint64[](20);
        vm.startPrank(owner);
        for (uint64 i; i < ids.length; ++i) {
            ids[i] = i + 1;
            pool.addSponsor(ids[i], address(burner));
        }
        vm.stopPrank();
        script.seedSponsors(pool, ids);
        ManagedPoolAccess.Config memory config = _check();
        vm.expectPartialRevert(ManagedPoolAccess.ReplayNeedsMoreGas.selector);
        script.checkSponsors{ gas: 32_000_000 }(config);
        script.checkSponsors(config);
    }

    function test_nestedSponsorPairsStopWithNamedGasRefusal() external {
        SlowAdmissions slow = new SlowAdmissions();
        vm.expectPartialRevert(ManagedPoolAccess.ReplayNeedsMoreGas.selector);
        script.reportSponsor{ gas: 32_000_000 }(IManagedDirectPropAMM(address(slow)), ALPHA, 40);
        script.reportSponsor(IManagedDirectPropAMM(address(slow)), ALPHA, 40);
    }

    function _hasText(string memory value, string memory fragment) internal pure returns (bool) {
        return bytes(value).length >= bytes(fragment).length && _indexOf(bytes(value), bytes(fragment));
    }

    function _indexOf(bytes memory value, bytes memory fragment) internal pure returns (bool) {
        for (uint256 i; i + fragment.length <= value.length; ++i) {
            bool matches = true;
            for (uint256 j; j < fragment.length; ++j) {
                if (value[i + j] != fragment[j]) matches = false;
            }
            if (matches) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- check

    function test_checkStandaloneSponsorsAsExpectedStillFlagsUnprovedCreation() external {
        _addSponsor(ALPHA, alpha, PAIR);
        _addSponsor(BETA, beta, OTHER_PAIR);
        assertEq(script.check(_expecting(_pair64(ALPHA, BETA), _two(alpha, beta))).length, 1);
        script.setInput(_expecting(_pair64(ALPHA, BETA), _two(alpha, beta)));
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.CheckFailed.selector, 1));
        script.run();
    }

    function test_checkFlagsSponsorDrift() external {
        _addSponsor(ALPHA, alpha, PAIR);
        _addSponsor(BETA, beta, PAIR);
        vm.prank(alpha);
        pool.transferSponsorAdmin(ALPHA, carol);
        vm.prank(owner);
        pool.setSponsorEnabled(BETA, false);
        string[] memory findings = script.check(_expecting(_three64(ALPHA, BETA, 42), _three(alpha, stranger, alice)));
        assertEq(findings.length, 5);
        assertEq(
            findings[0],
            string.concat(
                "sponsor 7 has a pending admin handover to ", vm.toString(carol), ": accepting moves its lists"
            )
        );
        assertEq(
            findings[1], string.concat("sponsor 9's admin is ", vm.toString(beta), ", expected ", vm.toString(stranger))
        );
        assertEq(findings[2], "sponsor 9 is switched off: no swap under it fills");
        assertEq(findings[3], "expected sponsor 42 is not registered");
        script.setInput(_expecting(_three64(ALPHA, BETA, 42), _three(alpha, stranger, alice)));
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.CheckFailed.selector, 5));
        script.run();
    }

    /// @dev Regression: CHECK describes a sponsor admin whose getters revert or answer malformed data instead of
    /// aborting, and recognizes a Safe.
    function test_checkDescribesAnOddAdminWithoutAborting() external {
        OddAdmin odd = new OddAdmin();
        address[] memory owners = _three(alice, bob, carol);
        SafeLike safe = new SafeLike(owners);
        _addSponsor(ALPHA, address(odd), PAIR);
        _addSponsor(BETA, address(safe), PAIR);
        assertEq(script.kind(address(odd)), "contract");
        assertEq(script.kind(address(safe)), "self-reported Safe views (unverified), 2 of 3");
        assertEq(script.kind(alice), "no code");
        assertEq(script.kind(virtualAccount), "TIP-1022 virtual address: never calls");
        assertEq(
            script.kind(address(pool)),
            string.concat("self-reported owner() (unverified) ", vm.toString(owner)),
            "a pool's owner"
        );
        ManagedPoolAccess.Config memory config = _expecting(_pair64(ALPHA, BETA), _two(address(odd), address(safe)));
        config.accounts = _two(alice, virtualAccount);
        assertEq(script.check(config).length, 1);
    }

    /// @dev A sponsor admin that burns all the gas it gets, or answers a huge payload, reads as a plain contract: CHECK
    /// still describes it and reports the drift it was asked to find. Each probe gets `PROBE_GAS`.
    function test_checkSurvivesAGasBurningAdmin() external {
        GasBurningAdmin burner = new GasBurningAdmin();
        _addSponsor(ALPHA, address(burner), PAIR);
        _addSponsor(BETA, beta, PAIR);
        vm.prank(beta);
        pool.transferSponsorAdmin(BETA, address(burner));
        assertEq(script.kind(address(burner)), "contract");
        string[] memory findings = script.check(_expecting(_pair64(ALPHA, BETA), _two(alice, beta)));
        assertEq(findings.length, 3);
        assertEq(
            findings[0],
            string.concat("sponsor 7's admin is ", vm.toString(address(burner)), ", expected ", vm.toString(alice))
        );
        assertEq(
            findings[1],
            string.concat(
                "sponsor 9 has a pending admin handover to ",
                vm.toString(address(burner)),
                ": accepting moves its lists"
            )
        );
    }

    /// @dev With `FROM_BLOCK`, the replay rebuilds every sponsor, admission, list and denial from the pool's events,
    /// voids listings before a reset, flags a sponsor not expected, and matches the chain.
    function test_checkReplaysEventsAndFlagsAnUnexpectedSponsor() external {
        ManagedDirectPropAMM fresh = _recordDeployment(10);
        _recordAs(owner, 11, address(fresh), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        _recordAs(owner, 11, address(fresh), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (BETA, beta)));
        _recordAs(owner, 12, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, ALPHA, true)));
        _recordAs(owner, 12, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, BETA, true)));
        _recordAs(
            owner, 13, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, HOME, _one(carol), true))
        );
        _recordAs(
            alpha,
            13,
            address(fresh),
            abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, _two(alice, bob), true))
        );
        _recordAs(
            beta, 14, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, BETA, _one(alice), true))
        );
        // The reset voids alpha's two listings; its new admin re-lists bob.
        _recordAs(owner, 15, address(fresh), abi.encodeCall(IManagedDirectPropAMM.resetSponsor, (ALPHA, carol)));
        _recordAs(
            carol, 16, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, _one(bob), true))
        );
        _recordAs(
            owner, 16, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setDenied, (_two(alice, stranger), true))
        );
        _recordAs(owner, 17, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setDenied, (_one(stranger), false)));
        _recordAs(owner, 17, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, BETA, false)));

        ManagedPoolAccess.Config memory config = _expecting(_single(ALPHA), _one(carol));
        config.pool = fresh;
        config.fromBlock = 10;
        config.accounts = _two(alice, bob);
        // The replay checks every (pair, list, account) and denial it rebuilt against the chain: no state-drift finding means
        // it voided alpha's listings from before the reset and kept bob's after it, exactly as `isMember` does.
        // Standalone creation provenance is an additional finding, independent of sponsor state.
        string[] memory findings = script.check(config);
        assertEq(findings.length, 2);
        assertEq(findings[0], "sponsor 9 is registered but not in EXPECTED_SPONSOR_IDS");
        assertFalse(fresh.isMember(PAIR, ALPHA, alice));
        assertTrue(fresh.isMember(PAIR, ALPHA, bob));
    }

    /// @dev A removal keeps access records for a possible forensic replay, but the pool's views hide them. CHECK
    /// compares its replay to those views, so their retained events cannot be findings.
    function test_checkReplayHidesRetainedAdmissionAndListingOnRemovedPair() external {
        ManagedDirectPropAMM fresh = _recordDeployment(10);
        _recordAs(owner, 11, address(fresh), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        _recordAs(owner, 12, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, ALPHA, true)));
        _recordAs(
            alpha,
            13,
            address(fresh),
            abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, _one(alice), true))
        );
        _recordAs(owner, 14, address(fresh), abi.encodeCall(IManagedDirectPropAMM.removePair, (PAIR)));

        ManagedPoolAccess.Config memory config = _expecting(_single(ALPHA), _one(alpha));
        config.pool = fresh;
        config.fromBlock = 10;
        config.accounts = _one(alice);
        assertEq(script.check(config).length, 1);
    }

    /// @dev The removed-pair exception is narrow: a replay still reports a mismatched admission and listing on a live
    /// pair.
    function test_checkReplayStillFindsLiveAdmissionAndListingDrift() external {
        ManagedDirectPropAMM fresh = _recordDeployment(10);
        _recordAs(owner, 11, address(fresh), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        _recordAs(owner, 12, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, ALPHA, true)));
        _recordAs(
            alpha,
            13,
            address(fresh),
            abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, _one(alice), true))
        );

        vm.mockCall(address(fresh), abi.encodeCall(IManagedDirectPropAMM.pairSponsor, (PAIR, ALPHA)), abi.encode(false));
        vm.mockCall(
            address(fresh), abi.encodeCall(IManagedDirectPropAMM.isMember, (PAIR, ALPHA, alice)), abi.encode(false)
        );
        ManagedPoolAccess.Config memory config = _expecting(_single(ALPHA), _one(alpha));
        config.pool = fresh;
        config.fromBlock = 10;
        config.accounts = _one(alice);
        assertEq(script.check(config).length, 3);
    }

    /// @dev A history longer than the run's gas covers stops the replay with `ReplayNeedsMoreGas`, never a report on
    /// part of it; with the gas, the same history checks clean. 30 listings replay in about 4.5M gas on the EVM's
    /// schedule and 28M on Tempo's, where the replay's own storage pays TIP-1000's slot price, so a run given 32M gas,
    /// little more than `REPLAY_GAS_RESERVE`, stops early on either.
    function test_checkStopsAReplayItCannotFinish() external {
        ManagedDirectPropAMM fresh = _recordDeployment(10);
        _recordAs(owner, 11, address(fresh), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        _recordAs(owner, 12, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (PAIR, ALPHA, true)));
        for (uint256 b; b < 3; ++b) {
            address[] memory accounts = new address[](10);
            for (uint256 i; i < 10; ++i) {
                accounts[i] = address(uint160(uint256(keccak256(abi.encode("listing", b, i)))));
            }
            _recordAs(
                alpha,
                uint64(13 + b),
                address(fresh),
                abi.encodeCall(IManagedDirectPropAMM.setMembers, (PAIR, ALPHA, accounts, true))
            );
        }
        ManagedPoolAccess.Config memory config = _expecting(_single(ALPHA), _one(alpha));
        config.pool = fresh;
        config.fromBlock = 10;
        vm.expectPartialRevert(ManagedPoolAccess.ReplayNeedsMoreGas.selector);
        script.check{ gas: 32_000_000 }(config);
        assertEq(script.check(config).length, 1);
    }

    function test_checkFlagsEventsThatDisagreeWithTheChain() external {
        ManagedDirectPropAMM fresh = _recordDeployment(10);
        _recordAs(owner, 11, address(fresh), abi.encodeCall(IManagedDirectPropAMM.addSponsor, (ALPHA, alpha)));
        // These change the chain but are never recorded, or are recorded as removed by a reorg.
        vm.startPrank(owner);
        fresh.setMembers(PAIR, HOME, _one(alice), true);
        fresh.setDenied(_one(bob), true);
        vm.stopPrank();
        vm.recordLogs();
        vm.prank(alpha);
        fresh.transferSponsorAdmin(ALPHA, beta);
        vm.prank(beta);
        fresh.acceptSponsorAdmin(ALPHA);
        script.addRemovedLogs(vm.getRecordedLogs(), 12);

        ManagedPoolAccess.Config memory config = _expecting(_single(ALPHA), _one(beta));
        config.pool = fresh;
        config.fromBlock = 10;
        string[] memory findings = script.check(config);
        assertEq(findings.length, 3);
        assertEq(findings[0], "sponsor 7: the events disagree with the chain");
        assertEq(findings[1], "DenyUpdated events don't add up to deniedCount");

        // A range that starts after the deployment misses its events.
        config.fromBlock = 11;
        findings = script.check(config);
        assertEq(findings[0], "FROM_BLOCK is after the pool's deployment: the replay below misses earlier events");
        assertEq(findings[1], "PairAdded events don't add up to pairCount");
    }

    /// @dev Empty ranges still consume gas without advancing the replayed-event count.
    function test_checkEmptyLogRangesStopWithNamedGasRefusal() external {
        vm.roll(1_000_000);
        ManagedPoolAccess.Config memory config = _check();
        config.fromBlock = 1;
        config.logBlockRange = 1;
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.ReplayNeedsMoreGas.selector, 0));
        script.check{ gas: 32_000_000 }(config);
    }

    function test_checkReplayIncludesFinalPartialRangeAfterEmptyRanges() external {
        ManagedDirectPropAMM fresh = _recordDeployment(10);
        _recordAs(owner, 33, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setDenied, (_one(alice), true)));
        vm.roll(33);
        script.setMaxBlockRange(10);
        ManagedPoolAccess.Config memory config = _check();
        config.pool = fresh;
        config.fromBlock = 10;
        config.logBlockRange = 10;
        // [20, 29] has no events; the final shortened [30, 33] must still reconcile the denial.
        assertEq(script.check(config).length, 1);
        assertTrue(fresh.denied(alice));
    }

    function test_checkSplitsLogQueriesByRange() external {
        ManagedDirectPropAMM fresh = _recordDeployment(10);
        _recordAs(owner, 60, address(fresh), abi.encodeCall(IManagedDirectPropAMM.setDenied, (_one(alice), true)));
        script.setMaxBlockRange(10);
        ManagedPoolAccess.Config memory config = _check();
        config.pool = fresh;
        config.fromBlock = 10;
        vm.expectRevert(bytes("query exceeds max block range"));
        script.check(config);
        config.logBlockRange = 10;
        assertEq(script.check(config).length, 1);
    }

    function test_allPairModesRequireReviewedIdentityBeforeSending() external {
        ManagedPoolAccess.Mode[6] memory modes = [
            ManagedPoolAccess.Mode.LIST,
            ManagedPoolAccess.Mode.DELIST,
            ManagedPoolAccess.Mode.ADMIT,
            ManagedPoolAccess.Mode.UNADMIT,
            ManagedPoolAccess.Mode.PAIR_ACCESS,
            ManagedPoolAccess.Mode.CLOSE_PAIR
        ];
        for (uint256 i; i < modes.length; ++i) {
            ManagedPoolAccess.Config memory config = _pairMode(modes[i], PAIR);
            if (i < 2) config.accounts = _one(alice);
            if (i == 2 || i == 3) config.sponsorId = ALPHA;
            if (i == 4) config.access = IManagedDirectPropAMM.AccessMode.Open;
            config.expectedBase = address(eurx);
            _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "pair identity"));
            config.expectedBase = address(0);
            _reject(config, "EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE required for pair modes");
            config.expectedBase = address(prime);
            config.expectedQuote = address(0);
            _reject(config, "EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE required for pair modes");
            config.expectedQuote = address(eurx);
            _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "pair identity"));
            config.expectedQuote = address(pathUsd);
            config.expectedOracle = address(eurx);
            _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "pair identity"));
            config.expectedOracle = address(0);
            _reject(config, "EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE required for pair modes");
            assertEq(script.sentFrom(), address(0));
        }
    }

    function test_allPairModesRejectAmbiguousIdentityBeforeSending() external {
        vm.prank(owner);
        uint16 duplicate = pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        _rejectAmbiguousPairModes(PAIR);
        _rejectAmbiguousPairModes(duplicate);
        assertFalse(pool.isMember(PAIR, HOME, alice));
        assertFalse(pool.isMember(duplicate, HOME, alice));
    }

    function test_allPairModesWorkAfterDuplicateRemoval() external {
        vm.startPrank(owner);
        uint16 duplicate = pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        pool.removePair(duplicate);
        pool.addSponsor(ALPHA, alpha);
        pool.setPairSponsor(OTHER_PAIR, ALPHA, true);
        pool.setMembers(OTHER_PAIR, HOME, _one(alice), true);
        pool.pause();
        vm.stopPrank();
        ManagedPoolAccess.Mode[6] memory modes = [
            ManagedPoolAccess.Mode.LIST,
            ManagedPoolAccess.Mode.DELIST,
            ManagedPoolAccess.Mode.ADMIT,
            ManagedPoolAccess.Mode.UNADMIT,
            ManagedPoolAccess.Mode.PAIR_ACCESS,
            ManagedPoolAccess.Mode.CLOSE_PAIR
        ];
        for (uint256 i; i < modes.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            vm.startPrank(owner);
            if (i == 1) pool.setMembers(PAIR, HOME, _one(alice), true);
            if (i == 3) pool.setPairSponsor(PAIR, ALPHA, true);
            vm.stopPrank();
            bytes32 otherBefore = keccak256(abi.encode(pool.pair(OTHER_PAIR)));
            ManagedPoolAccess.Config memory config = _pairMode(modes[i], PAIR);
            if (i < 2) config.accounts = _one(alice);
            if (i == 2 || i == 3) config.sponsorId = ALPHA;
            if (i == 3 || i == 5) config.caller = owner;
            if (i == 4) config.access = IManagedDirectPropAMM.AccessMode.Open;
            _run(config);
            if (i < 2) assertEq(pool.isMember(PAIR, HOME, alice), i == 0);
            if (i == 2 || i == 3) assertEq(pool.pairSponsor(PAIR, ALPHA), i == 2);
            if (i == 4) assertEq(uint8(pool.pair(PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Open));
            if (i == 5) assertEq(uint8(pool.pair(PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Closed));
            assertEq(keccak256(abi.encode(pool.pair(OTHER_PAIR))), otherBefore);
            assertTrue(pool.isMember(OTHER_PAIR, HOME, alice));
            assertTrue(pool.pairSponsor(OTHER_PAIR, ALPHA));
            assertEq(uint8(pool.pair(duplicate).access), uint8(IManagedDirectPropAMM.AccessMode.None));
            assertFalse(pool.isMember(duplicate, HOME, alice));
            assertFalse(pool.pairSponsor(duplicate, ALPHA));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function _rejectAmbiguousPairModes(uint16 pairIndex) internal {
        ManagedPoolAccess.Mode[6] memory modes = [
            ManagedPoolAccess.Mode.LIST,
            ManagedPoolAccess.Mode.DELIST,
            ManagedPoolAccess.Mode.ADMIT,
            ManagedPoolAccess.Mode.UNADMIT,
            ManagedPoolAccess.Mode.PAIR_ACCESS,
            ManagedPoolAccess.Mode.CLOSE_PAIR
        ];
        for (uint256 i; i < modes.length; ++i) {
            ManagedPoolAccess.Config memory config = _pairMode(modes[i], pairIndex);
            if (i < 2) config.accounts = _one(alice);
            if (i == 2 || i == 3) config.sponsorId = ALPHA;
            if (i == 4) config.access = IManagedDirectPropAMM.AccessMode.Open;
            _expectRun(
                config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "ambiguous pair identity")
            );
            assertEq(script.sentFrom(), address(0));
        }
    }

    function test_nonPairModesRejectPairIdentity() external {
        ManagedPoolAccess.Config memory config = _accounts(ManagedPoolAccess.Mode.DENY, _one(alice));
        config.expectedBase = address(prime);
        _reject(config, "EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE are for pair modes");
        config.expectedBase = address(0);
        config.expectedQuote = address(pathUsd);
        _reject(config, "EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE are for pair modes");
        config.expectedQuote = address(0);
        config.expectedOracle = address(oracle);
        _reject(config, "EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE are for pair modes");
        assertFalse(pool.denied(alice));
        assertEq(script.sentFrom(), address(0));
    }

    function test_sameTokensDifferentOracleCannotBeConfused() external {
        vm.startPrank(owner);
        uint16 duplicate =
            pool.addPair(address(prime), address(pathUsd), new MockOracle(8, PRICE, block.timestamp), 90_000, 50);
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _one(alice));
        vm.stopPrank();
        config.pairIndex = duplicate;
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "pair identity"));
        assertFalse(pool.isMember(duplicate, HOME, alice));
    }

    function test_shiftedPairIndexCannotChangeAnotherPair() external {
        ManagedPoolAccess.Config memory config = _list(ManagedPoolAccess.Mode.LIST, PAIR, HOME, _one(alice));
        // The reviewed PRIME/pathUSD pair mined at a different index: index 1 is EURX/pathUSD.
        config.pairIndex = OTHER_PAIR;
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.UnexpectedState.selector, "pair identity"));
        script.run();
        assertFalse(pool.isMember(OTHER_PAIR, HOME, alice));
        assertFalse(pool.isMember(PAIR, HOME, alice));
    }

    function test_readsTheEnvironment() external {
        _setEnv("POOL_ADDRESS", vm.toString(address(pool)));
        _setEnv("MODE", "PAIR_ACCESS");
        _setEnv("PAIR_INDEX", "0");
        _setEnv("EXPECTED_BASE", vm.toString(address(prime)));
        _setEnv("EXPECTED_QUOTE", vm.toString(address(pathUsd)));
        _setEnv("EXPECTED_ORACLE", vm.toString(address(oracle)));
        _setEnv("SPONSOR_ID", "42");
        _setEnv("ACCOUNTS", string.concat(vm.toString(alice), ",", vm.toString(bob)));
        _setEnv("SPONSOR_ADMIN", vm.toString(alpha));
        _setEnv("ACCESS", "open");
        _setEnv("CALLER", vm.toString(owner));
        _setEnv("BROADCAST", "true");
        _setEnv("EXPECTED_SPONSOR_IDS", "7,9");
        _setEnv("EXPECTED_SPONSOR_ADMINS", string.concat(vm.toString(alpha), ",", vm.toString(beta)));
        _setEnv("FROM_BLOCK", "123");
        _setEnv("LOG_BLOCK_RANGE", "5000");
        _setEnv("EXPECTED_FACTORY", vm.toString(alpha));
        _setEnv("EXPECTED_SETTLER", vm.toString(beta));

        ManagedPoolAccess.Config memory c = script.readEnvConfig();
        assertEq(address(c.pool), address(pool));
        assertEq(uint8(c.mode), uint8(ManagedPoolAccess.Mode.PAIR_ACCESS));
        assertTrue(c.hasPairIndex);
        assertEq(c.pairIndex, 0);
        assertEq(c.sponsorId, 42);
        assertEq(c.accounts.length, 2);
        assertEq(c.sponsorAdmin, alpha);
        assertEq(uint8(c.access), uint8(IManagedDirectPropAMM.AccessMode.Open));
        assertEq(c.caller, owner);
        assertTrue(c.broadcast);
        assertEq(c.expectedSponsorIds[1], 9);
        assertEq(c.expectedSponsorAdmins[1], beta);
        assertEq(c.fromBlock, 123);
        assertEq(c.logBlockRange, 5000);
        assertEq(c.expectedFactory, alpha);
        assertEq(c.expectedSettler, beta);

        string[17] memory modes = [
            "CHECK",
            "LIST",
            "DELIST",
            "DENY",
            "UNDENY",
            "ADD_SPONSOR",
            "ENABLE_SPONSOR",
            "DISABLE_SPONSOR",
            "ADMIT",
            "UNADMIT",
            "RESET_SPONSOR",
            "TRANSFER_SPONSOR_ADMIN",
            "CANCEL_SPONSOR_ADMIN_TRANSFER",
            "ACCEPT_SPONSOR_ADMIN",
            "PAIR_ACCESS",
            "CLOSE_PAIR",
            "SET_SETTLER"
        ];
        for (uint8 i; i < modes.length; ++i) {
            _setEnv("MODE", modes[i]);
            assertEq(uint8(script.readEnvConfig().mode), i);
        }
        string[3] memory accessNames = ["closed", "listed", "open"];
        for (uint8 i; i < accessNames.length; ++i) {
            _setEnv("ACCESS", accessNames[i]);
            assertEq(uint8(script.readEnvConfig().access), i + 1);
        }
        _setEnv("ACCESS", "Open");
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.InvalidConfig.selector, "ACCESS"));
        script.readEnvConfig();
        _setEnv("ACCESS", "");
        _setEnv("MODE", "list");
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.InvalidConfig.selector, "MODE"));
        script.readEnvConfig();
        _setEnv("MODE", "CHECK");
        _setEnv("PAIR_INDEX", "65536");
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.InvalidConfig.selector, "PAIR_INDEX"));
        script.readEnvConfig();
        _setEnv("PAIR_INDEX", "");
        _setEnv("SPONSOR_ID", vm.toString(uint256(type(uint64).max) + 1));
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.InvalidConfig.selector, "SPONSOR_ID"));
        script.readEnvConfig();
        _setEnv("SPONSOR_ID", "");
        assertFalse(script.readEnvConfig().hasPairIndex, "an empty PAIR_INDEX is unset");
        assertEq(script.readEnvConfig().sponsorId, HOME, "an empty SPONSOR_ID selects the home list");

        // Exercise parsing through the real run, not the storage-config harness: a typo must never list or
        // delist on the home list instead of the intended sponsor. Keep every other input valid.
        _setEnv("PAIR_INDEX", "0");
        _setEnv("ACCOUNTS", vm.toString(alice));
        _setEnv("SPONSOR_ADMIN", vm.toString(address(0)));
        _setEnv("CALLER", vm.toString(address(0)));
        _setEnv("BROADCAST", "false");
        _setEnv("EXPECTED_SPONSOR_IDS", "");
        _setEnv("EXPECTED_SPONSOR_ADMINS", "");
        _setEnv("FROM_BLOCK", "0");
        _setEnv("LOG_BLOCK_RANGE", "0");
        _setEnv("EXPECTED_FACTORY", vm.toString(address(0)));
        _setEnv("EXPECTED_SETTLER", vm.toString(address(0)));
        _setEnv("MODE", "LIST");
        script.runEnv();
        assertTrue(pool.isMember(PAIR, HOME, alice));
        _setEnv("MODE", "DELIST");
        script.runEnv();
        assertFalse(pool.isMember(PAIR, HOME, alice));

        _addSponsor(ALPHA, alpha, PAIR);
        _setEnv("SPONSOR_ID", "7");
        _setEnv("MODE", "LIST");
        script.runEnv();
        assertTrue(pool.isMember(PAIR, ALPHA, alice));
        assertFalse(pool.isMember(PAIR, HOME, alice));
        _setEnv("MODE", "DELIST");
        script.runEnv();
        assertFalse(pool.isMember(PAIR, ALPHA, alice));

        string[5] memory badIds = ["7oops", "-1", "0xGG", "seven", "18446744073709551616"];
        for (uint256 i; i < badIds.length; ++i) {
            _setEnv("SPONSOR_ID", badIds[i]);
            _setEnv("MODE", "LIST");
            _rejectEnvWithoutWrites();
            assertFalse(pool.isMember(PAIR, HOME, alice));
            vm.prank(owner);
            pool.setMembers(PAIR, HOME, _one(alice), true);
            _setEnv("MODE", "DELIST");
            _rejectEnvWithoutWrites();
            assertTrue(pool.isMember(PAIR, HOME, alice));
            vm.prank(owner);
            pool.setMembers(PAIR, HOME, _one(alice), false);
        }
        _setEnv("SPONSOR_ID", "");
    }

    function test_optionalTypedEnvironmentDefaultsAndMalformedValues() external {
        script.setEnvPrefix("MANAGED_ACCESS_ABSENT_");
        _setEnv("POOL_ADDRESS", vm.toString(address(pool)));
        _setEnv("MODE", "CHECK");
        ManagedPoolAccess.Config memory c = script.readEnvConfig();
        assertEq(c.accounts.length, 0);
        assertEq(c.sponsorAdmin, address(0));
        assertEq(c.caller, address(0));
        assertFalse(c.broadcast);
        assertEq(c.expectedSponsorIds.length, 0);
        assertEq(c.expectedSponsorAdmins.length, 0);
        assertEq(c.fromBlock, 0);
        assertEq(c.logBlockRange, 0);
        assertEq(c.expectedFactory, address(0));
        assertEq(c.expectedSettler, address(0));

        string[10] memory fields = [
            "ACCOUNTS",
            "SPONSOR_ADMIN",
            "CALLER",
            "BROADCAST",
            "EXPECTED_SPONSOR_IDS",
            "EXPECTED_SPONSOR_ADMINS",
            "FROM_BLOCK",
            "LOG_BLOCK_RANGE",
            "EXPECTED_FACTORY",
            "EXPECTED_SETTLER"
        ];
        for (uint256 i; i < fields.length; ++i) {
            // Every case gets untouched keys; no unset emulation and no other test's environment is modified.
            script.setEnvPrefix(string.concat("MANAGED_ACCESS_MALFORMED_", vm.toString(i), "_"));
            _setEnv("POOL_ADDRESS", vm.toString(address(pool)));
            _setEnv("MODE", "LIST");
            _setEnv("PAIR_INDEX", "0");
            _setEnv("ACCOUNTS", vm.toString(alice));
            _setEnv("BROADCAST", "true");
            // For arrays, a valid first element must not conceal a malformed later element.
            string memory bad = "not-a-value";
            if (i == 0 || i == 5) bad = string.concat(vm.toString(alice), ",not-an-address");
            if (i == 4) bad = "7,not-an-id";
            _setEnv(fields[i], bad);
            vm.record();
            _rejectEnvWithoutWrites();
            (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(pool));
            assertEq(reads.length, 0, "malformed optional input must fail before pool probes/actions");
            assertEq(writes.length, 0, "malformed optional input must fail before writes");
            assertEq(script.sentFrom(), address(0));
        }

        // Strict uint array parsing still applies the narrower sponsor-id bound.
        script.setEnvPrefix("MANAGED_ACCESS_OVERFLOW_");
        _setEnv("POOL_ADDRESS", vm.toString(address(pool)));
        _setEnv("MODE", "CHECK");
        _setEnv("EXPECTED_SPONSOR_IDS", "7,18446744073709551616");
        vm.expectRevert(abi.encodeWithSelector(ManagedPoolAccess.InvalidConfig.selector, "EXPECTED_SPONSOR_IDS"));
        script.runEnv();
    }

    function _setEnv(string memory key, string memory value) internal {
        vm.setEnv(script.envKey(key), value);
    }

    function _rejectEnvWithoutWrites() internal {
        vm.recordLogs();
        vm.expectRevert();
        script.runEnv();
        assertEq(vm.getRecordedLogs().length, 0, "malformed input must not send any pool call");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Two pairs, PRIME/pathUSD and EURX/pathUSD, both `Listed`, the pool active.
    function _deploy() internal returns (ManagedDirectPropAMM fresh) {
        fresh = new ManagedDirectPropAMM(owner, address(0));
        vm.startPrank(owner);
        fresh.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        fresh.addPair(address(eurx), address(pathUsd), new MockOracle(8, PRICE, block.timestamp), 90_000, 50);
        fresh.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        fresh.setPairAccess(OTHER_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        fresh.unpause();
        vm.stopPrank();
    }

    /// @dev Deploys a pool like `_deploy` with its events recorded for the script's replay in `blockNumber`.
    function _recordDeployment(uint64 blockNumber) internal returns (ManagedDirectPropAMM fresh) {
        vm.recordLogs();
        fresh = _deploy();
        script.addLogs(vm.getRecordedLogs(), blockNumber);
    }

    function _recordAs(address sender, uint64 blockNumber, address target, bytes memory data) internal {
        vm.recordLogs();
        vm.prank(sender);
        (bool ok,) = target.call(data);
        assertTrue(ok, "recorded call");
        script.addLogs(vm.getRecordedLogs(), blockNumber);
    }

    /// @dev Registers `id` with `admin` and admits it on `pairIndex`, directly on the pool.
    function _addSponsor(uint64 id, address admin, uint16 pairIndex) internal {
        vm.startPrank(owner);
        pool.addSponsor(id, admin);
        pool.setPairSponsor(pairIndex, id, true);
        vm.stopPrank();
    }

    function _assertSponsor(uint64 id, address admin, bool enabled, uint32 generation) internal view {
        (address actualAdmin, bool actualEnabled, uint32 actualGeneration) = pool.sponsor(id);
        assertEq(actualAdmin, admin);
        assertEq(actualEnabled, enabled);
        assertEq(actualGeneration, generation);
    }

    function _config(ManagedPoolAccess.Mode mode) internal view returns (ManagedPoolAccess.Config memory config) {
        config.pool = pool;
        config.mode = mode;
    }

    function _check() internal view returns (ManagedPoolAccess.Config memory) {
        return _config(ManagedPoolAccess.Mode.CHECK);
    }

    function _list(ManagedPoolAccess.Mode mode, uint16 pairIndex, uint64 sponsorId, address[] memory accounts)
        internal
        view
        returns (ManagedPoolAccess.Config memory config)
    {
        config = _config(mode);
        config.hasPairIndex = true;
        config.pairIndex = pairIndex;
        config.expectedBase = pairIndex < pool.pairCount() ? pool.pair(pairIndex).base : address(prime);
        config.expectedQuote = address(pathUsd);
        config.expectedOracle = pairIndex < pool.pairCount() ? address(pool.pair(pairIndex).oracle) : address(oracle);
        config.sponsorId = sponsorId;
        config.accounts = accounts;
    }

    function _accounts(ManagedPoolAccess.Mode mode, address[] memory accounts)
        internal
        view
        returns (ManagedPoolAccess.Config memory config)
    {
        config = _config(mode);
        config.accounts = accounts;
    }

    function _sponsor(ManagedPoolAccess.Mode mode, uint64 sponsorId, address admin)
        internal
        view
        returns (ManagedPoolAccess.Config memory config)
    {
        config = _config(mode);
        config.sponsorId = sponsorId;
        config.sponsorAdmin = admin;
        if (mode == ManagedPoolAccess.Mode.ADMIT || mode == ManagedPoolAccess.Mode.UNADMIT) {
            config.expectedBase = address(prime);
            config.expectedQuote = address(pathUsd);
            config.expectedOracle = address(oracle);
        }
    }

    function _pairMode(ManagedPoolAccess.Mode mode, uint16 pairIndex)
        internal
        view
        returns (ManagedPoolAccess.Config memory config)
    {
        config = _config(mode);
        config.hasPairIndex = true;
        config.pairIndex = pairIndex;
        config.expectedBase = pairIndex < pool.pairCount() ? pool.pair(pairIndex).base : address(prime);
        config.expectedQuote = address(pathUsd);
        config.expectedOracle = pairIndex < pool.pairCount() ? address(pool.pair(pairIndex).oracle) : address(oracle);
    }

    function _expecting(uint64[] memory ids, address[] memory admins)
        internal
        view
        returns (ManagedPoolAccess.Config memory config)
    {
        config = _check();
        config.expectedSponsorIds = ids;
        config.expectedSponsorAdmins = admins;
    }

    function _run(ManagedPoolAccess.Config memory config) internal returns (bytes memory) {
        script.setInput(config);
        return script.run();
    }

    function _expectRun(ManagedPoolAccess.Config memory config, bytes memory revertData) internal {
        script.setInput(config);
        vm.expectRevert(revertData);
        script.run();
    }

    function _reject(ManagedPoolAccess.Config memory config, string memory field) internal {
        _expectRun(config, abi.encodeWithSelector(ManagedPoolAccess.InvalidConfig.selector, field));
    }

    function _single(uint64 id) internal pure returns (uint64[] memory ids) {
        ids = new uint64[](1);
        ids[0] = id;
    }

    function _pair64(uint64 first, uint64 second) internal pure returns (uint64[] memory ids) {
        ids = new uint64[](2);
        (ids[0], ids[1]) = (first, second);
    }

    function _three64(uint64 first, uint64 second, uint64 third) internal pure returns (uint64[] memory ids) {
        ids = new uint64[](3);
        (ids[0], ids[1], ids[2]) = (first, second, third);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _two(address first, address second) internal pure returns (address[] memory accounts) {
        accounts = new address[](2);
        (accounts[0], accounts[1]) = (first, second);
    }

    function _three(address first, address second, address third) internal pure returns (address[] memory accounts) {
        accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (first, second, third);
    }

    function _many(uint256 count) internal pure returns (address[] memory accounts) {
        accounts = new address[](count);
        for (uint256 i; i < count; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode("account", i)))));
        }
    }
}
