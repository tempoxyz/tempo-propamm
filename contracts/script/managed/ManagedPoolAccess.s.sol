// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";

import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IPoolFactory } from "../../src/managed/interfaces/IPoolFactory.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";

/// @dev Foundry 1.8.1 exposes raw JSON; the pinned forge-std Vm interface predates this cheatcode.
interface VmRpcJson {
    function rpcJson(string calldata method, string calldata params) external returns (string memory);
}

/// @notice Prepares one access change on a `ManagedDirectPropAMM` as Safe-ready calldata, or checks the pool's access
/// state. It reads no key and sends nothing by default: it runs the call as the account that will send it, checks the
/// result, and prints the target, value and calldata for that account's Safe or wallet to submit.
/// @dev The pool's access is v2 `Venue`'s: per-pair `Closed`/`Listed`/`Open` modes, a home list per pair (sponsor 0)
/// that only the owner edits, owner-registered sponsors whose admins list their own users pair by pair, and a pool-wide
/// deny list above every list and `Open`. Inputs:
/// - `POOL_ADDRESS`, and `MODE`, one of (the default sender in brackets):
///   - `LIST` or `DELIST` (the owner for sponsor 0, else the sponsor's admin): `setMembers(PAIR_INDEX, SPONSOR_ID,
///     ACCOUNTS, true or false)`. `SPONSOR_ID` defaults to 0, the pair's home list, only when unset or empty; malformed
///     ids revert. `DELIST` warns about an account the pair still admits (`Open`, or the home list under another
///     sponsor): only a denial blocks it under every list. After a sponsor reset, an already-ineffective entry may
///     still hold an old generation, so DELIST permits explicit idempotent cleanup and labels it as such;
///   - `DENY` or `UNDENY` (owner): `setDenied(ACCOUNTS, true or false)`, pool-wide;
///   - `ADD_SPONSOR` (owner): `addSponsor(SPONSOR_ID, SPONSOR_ADMIN)`;
///   - `ENABLE_SPONSOR` or `DISABLE_SPONSOR` (owner): `setSponsorEnabled(SPONSOR_ID, true or false)`;
///   - `ADMIT` or `UNADMIT` (owner): `setPairSponsor(PAIR_INDEX, SPONSOR_ID, true or false)`;
///   - `RESET_SPONSOR` (owner): `resetSponsor(SPONSOR_ID, SPONSOR_ADMIN)`, which voids every listing the sponsor made;
///   - `TRANSFER_SPONSOR_ADMIN` (the sponsor's admin): `transferSponsorAdmin(SPONSOR_ID, SPONSOR_ADMIN)`;
///   - `CANCEL_SPONSOR_ADMIN_TRANSFER` (the sponsor's admin): `cancelSponsorAdminTransfer(SPONSOR_ID)`;
///   - `ACCEPT_SPONSOR_ADMIN` (the pending admin): `acceptSponsorAdmin(SPONSOR_ID)`;
///   - `PAIR_ACCESS` (owner): `setPairAccess(PAIR_INDEX, ACCESS)`, with `ACCESS` one of `closed`, `listed` or `open`;
///     `open` needs the pool paused;
///   - `CLOSE_PAIR` (owner): `closePair(PAIR_INDEX)`;
///   - `SET_SETTLER` (owner): `setSettler(ACCOUNTS[0])`, exactly one non-virtual account; warns before sending that the
///     settler can drain inventory without input and needs independent review, even with code. Code-less EOAs or
///     future deployment addresses remain allowed, with an additional warning;
///   - `CHECK`: reports the access state (see `check`) and sends nothing.
/// - All pair modes require `EXPECTED_BASE`, `EXPECTED_QUOTE` and `EXPECTED_ORACLE`: reviewed addresses checked against the
///   live pair before any action. Removed pairs allow only DELIST/UNADMIT with FROM_BLOCK at or before their
///   PairAdded event; canonical history must prove the tokens and last oracle before removal. Mined events assign indexes.
/// - `ACCOUNTS`: comma-separated, at most `MAX_ACCOUNTS`; required for `LIST`, `DELIST`, `DENY`, `UNDENY` and `SET_SETTLER`,
///   optional for `CHECK`, which then reports each one's access on every live pair.
/// - Optional `CALLER`, the account that will send the call (default above). Owner-only modes require the current owner.
///   A call `CALLER` may not make reverts here with the pool's own error.
/// - Optional `BROADCAST` (default false): also send the call from `CALLER`. Forge signs it with its own signer for
///   `CALLER` (`--ledger`, `--account`, ...) and sends it only with `--broadcast`.
/// - Removed-pair cleanup requires `FROM_BLOCK` and optionally `LOG_BLOCK_RANGE`, replaying through the simulation
///   block. Use a fresh fork of a trusted canonical, complete RPC; this verifies identity, not code or creation provenance.
/// - `CHECK` only, all optional: `EXPECTED_SPONSOR_IDS` with `EXPECTED_SPONSOR_ADMINS`, comma-separated with one entry
///   per id: the sponsors the operator reviewed and each one's admin. `FROM_BLOCK`, a block at or before the pool's
///   deployment, to replay the pool's events: every sponsor, admission, list and denial. Routers are ordinary
///   members of these lists, not a separate authority. Standalone creation provenance is not proved, so CHECK
///   always flags its replay as incomplete; only an expected factory's clone proof authenticates empty initial state.
///   `EXPECTED_FACTORY`, the `PoolFactory` the operator trusts: a factory clone is a finding unless its `factory()` is
///   this one, the factory's `isPool` proves it, and its `settler()` is `EXPECTED_SETTLER` (default: the factory's
///   `defaultSettler()`), the settler takers approve; a clone checked without `EXPECTED_FACTORY` is a finding too.
///   `EXPECTED_SETTLER` only with `EXPECTED_FACTORY`, for a replacement settler the operator reviewed;
///   and `LOG_BLOCK_RANGE`, the blocks per `eth_getLogs` request (default 100,000, the Tempo RPC's limit), only with `FROM_BLOCK`. The replay
///   runs in one simulation, about 120,000 gas per listing event (800,000 under `--network tempo`, which CHECK doesn't
///   need): past about 8,000 (1,300) it reverts `ReplayNeedsMoreGas` under Foundry's default gas, and
///   `FOUNDRY_GAS_LIMIT=18446744073709551615` lifts the limit.
/// Refused before anything runs: an input that doesn't apply to `MODE`; a zero, duplicate or pool account; more than
/// `MAX_ACCOUNTS` accounts in any mode (a full pool batch of 100 new accounts measures about 25.6M gas, over Tempo's
/// 30M cap at Forge's 130% gas limit); a TIP-1022 virtual address in `LIST` or `DENY`, since it never calls, so the
/// listing admits nobody and the denial blocks nobody but makes every swap read the deny list (`DELIST` and `UNDENY`
/// take one, to clean up); a zero, pool or virtual `SPONSOR_ADMIN`; a change that changes nothing (except post-reset
/// DELIST or historically verified removed-pair cleanup); and a pool that doesn't answer as a `ManagedDirectPropAMM`. The script calls no precompile, so it
/// needs no `--network tempo`.
contract ManagedPoolAccess is Script {
    using Address for address;

    error CheckFailed(uint256 findings);
    error InvalidConfig(string field);
    /// @dev Replay stops before exhausting its simulation budget. The count is progress in the current loop; raise
    /// `FOUNDRY_GAS_LIMIT` and rerun the complete check.
    error ReplayNeedsMoreGas(uint256 entriesProcessed);
    error UnexpectedState(string field);

    enum Mode {
        CHECK,
        LIST,
        DELIST,
        DENY,
        UNDENY,
        ADD_SPONSOR,
        ENABLE_SPONSOR,
        DISABLE_SPONSOR,
        ADMIT,
        UNADMIT,
        RESET_SPONSOR,
        TRANSFER_SPONSOR_ADMIN,
        CANCEL_SPONSOR_ADMIN_TRANSFER,
        ACCEPT_SPONSOR_ADMIN,
        PAIR_ACCESS,
        CLOSE_PAIR,
        SET_SETTLER
    }

    struct Config {
        IManagedDirectPropAMM pool;
        Mode mode;
        /// @dev Whether `PAIR_INDEX` is set: 0 is a real pair.
        bool hasPairIndex;
        uint16 pairIndex;
        address expectedBase;
        address expectedQuote;
        address expectedOracle;
        /// @dev 0 when `SPONSOR_ID` is unset: the home list for `LIST` and `DELIST`.
        uint64 sponsorId;
        address[] accounts;
        /// @dev The admin `ADD_SPONSOR`, `RESET_SPONSOR` or `TRANSFER_SPONSOR_ADMIN` sets or proposes.
        address sponsorAdmin;
        /// @dev `None` when `ACCESS` is unset.
        IManagedDirectPropAMM.AccessMode access;
        /// @dev 0 when `CALLER` is unset: the mode's default sender.
        address caller;
        bool broadcast;
        uint64[] expectedSponsorIds;
        address[] expectedSponsorAdmins;
        /// @dev 0 when `FROM_BLOCK` is unset: no CHECK replay or removed-pair cleanup.
        uint256 fromBlock;
        /// @dev 0 when `LOG_BLOCK_RANGE` is unset: `DEFAULT_LOG_BLOCK_RANGE`.
        uint256 logBlockRange;
        /// @dev 0 when `EXPECTED_FACTORY` is unset: a factory clone's settler is unauthenticated, a finding.
        address expectedFactory;
        /// @dev 0 when `EXPECTED_SETTLER` is unset: the expected factory's `defaultSettler()`.
        address expectedSettler;
    }

    /// @dev Memory-only proof for one change; never reused across calls, configurations or simulation heads.
    struct CleanupProof {
        uint256 blockNumber;
        bytes32 blockHash;
    }

    /// @dev Identity only, not access-state reconstruction; the current pool authorizes every cleanup call.
    struct RemovedPairHistory {
        bool added;
        bool removed;
        address oracle;
        uint8 decimals;
        bool hasLog;
        uint256 blockNumber;
        uint256 logIndex;
        bytes32 blockHash;
        uint256 canonicalBlockNumber;
        bytes32 canonicalBlockHash;
    }

    /// @dev One sponsor as the replayed events built it.
    struct SponsorState {
        bool seen;
        address admin;
        bool enabled;
        uint32 generation;
    }

    /// @dev One (pair, sponsor, account) listing as the replayed events built it: the generation it was listed under,
    /// 0 when delisted.
    struct MemberState {
        uint16 pairIndex;
        uint64 sponsorId;
        address account;
        uint32 generation;
    }

    struct AdmissionState {
        uint16 pairIndex;
        uint64 sponsorId;
        bool admitted;
    }

    /// @dev The pool's state rebuilt from its events, in their order. Fresh for every replay.
    struct Replay {
        bool sawDeployment;
        uint256 pairsAdded;
        mapping(uint16 pairIndex => bool) removed;
        uint64[] sponsorIds;
        mapping(uint64 sponsorId => SponsorState) sponsors;
        bytes32[] admissionKeys;
        mapping(bytes32 key => AdmissionState) admissions;
        bytes32[] memberKeys;
        mapping(bytes32 key => MemberState) members;
        address[] denialKeys;
        mapping(address account => bool) denialSeen;
        mapping(address account => bool) denied;
        address settler;
        bool sawSettler;
    }

    /// @notice The most accounts one run takes, in every mode.
    uint256 public constant MAX_ACCOUNTS = 50;
    uint256 internal constant DEFAULT_LOG_BLOCK_RANGE = 100_000;
    /// @dev What the pool's `MAX_BATCH` must answer.
    uint256 internal constant POOL_MAX_BATCH = 100;
    /// @dev The gas and answer size every raw probe allows (`_probe`): a pool, admin or oracle that burns its gas or
    /// answers with a huge payload reads as no answer, so CHECK still reports drift. A Safe's `getOwners()` with up to
    /// 1,000 owners fits both.
    uint256 internal constant PROBE_GAS = 1_000_000;
    uint256 internal constant MAX_PROBE_ANSWER = 64 + 32 * 1000;
    /// @dev The simulation gas the replay keeps in hand for the checks after it. It replays the whole history in one
    /// run, about 120,000 gas per listing event (about 800,000 under `--network tempo`, where its own storage pays
    /// TIP-1000's slot price), so Foundry's default 1,073,741,824 covers about 8,000 (1,300); with less than this left
    /// it reverts `ReplayNeedsMoreGas` instead of running out partway.
    uint256 internal constant REPLAY_GAS_RESERVE = 30_000_000;

    /// @dev `check`'s findings and warnings, and a change's warnings. Script-local state, never broadcast.
    string[] internal _findings;
    string[] internal _warnings;
    /// @dev The sponsors `check` reports each account under: the expected ones, and with `FROM_BLOCK` every other.
    uint64[] internal _sponsorIds;
    uint256 internal _replays;
    mapping(uint256 replay => Replay) internal _replay;

    /// @notice Runs `MODE`: prints a change's calldata (and sends it with `BROADCAST`) and returns it, or runs `check`
    /// and reverts `CheckFailed` after its report when it has a finding.
    function run() external returns (bytes memory data) {
        return _run(_readConfig());
    }

    /// @dev `run` on `config`, so a wrapper can run several modes in one Forge script simulation
    /// (`contracts/test/managed/script/ManagedPoolScriptsRun.s.sol`).
    function _run(Config memory config) internal returns (bytes memory data) {
        _checkInputs(config);
        if (config.mode != Mode.CHECK) {
            _checkPool(config.pool);
            return _change(config);
        }
        uint256 findings = check(config).length;
        if (findings != 0) revert CheckFailed(findings);
    }

    /// @notice Reports the pool's roles, pause, denials and pairs, each expected sponsor, then each of
    /// `ACCOUNTS` on every live pair under the home list and every sponsor it knows, and returns the findings: an
    /// expected sponsor that isn't registered, has another admin, has a pending handover or is switched off, and with
    /// `FROM_BLOCK`, a sponsor that isn't expected, a range that misses the pool's deployment, or events that disagree
    /// with the chain. Also reports factory/settler, checks settlement authority and its event history
    /// (missing views or a pool with a settler without `FROM_BLOCK`). Standalone
    /// creation provenance is always a finding, not a certification of complete history. Never reverts on an odd account:
    /// admins and oracles are read with raw probes, each bounded in gas and answer size, so one that reverts, answers oddly or burns its gas reads as no answer.
    function check(Config memory config) public returns (string[] memory) {
        _checkPool(config.pool);
        delete _findings;
        delete _warnings;
        delete _sponsorIds;
        IManagedDirectPropAMM pool = config.pool;
        console2.log("Pool", address(pool));
        console2.log("Chain id", block.chainid);
        console2.log("Block", block.number);
        console2.log(string.concat("Owner ", _named(pool.owner())));
        address pendingOwner = pool.pendingOwner();
        if (pendingOwner != address(0)) {
            console2.log(
                string.concat("Pending owner (accepting moves every owner power to it) ", _named(pendingOwner))
            );
        }
        _reportSettlement(config);
        console2.log("Paused (no swap fills on any pair)", pool.paused());
        console2.log("Denied accounts", uint256(pool.deniedCount()));
        uint16 pairs = pool.pairCount();
        console2.log("Pairs ever added", uint256(pairs));
        for (uint16 i = 0; i < pairs; ++i) {
            _requireCheckGas(i);
            _reportPair(pool, i);
        }
        for (uint256 i = 0; i < config.expectedSponsorIds.length; ++i) {
            _requireCheckGas(i);
            _sponsorIds.push(config.expectedSponsorIds[i]);
            _checkExpectedSponsor(pool, config.expectedSponsorIds[i], config.expectedSponsorAdmins[i], pairs);
        }
        if (config.fromBlock != 0) {
            _checkHistory(config);
        } else {
            console2.log(
                "Unexpected sponsors, list sizes and denials: not enumerated. Set FROM_BLOCK to the pool's deployment"
                " block."
            );
        }
        for (uint256 i = 0; i < config.accounts.length; ++i) {
            _requireCheckGas(i);
            _reportAccount(pool, config.accounts[i], pairs);
        }
        // Matching runtime and view probes do not bind constructor execution: arbitrary initcode can return the
        // same standalone runtime with access storage pre-seeded and no events. Do not certify a complete replay.
        (bool factoryOk, uint256 factoryWord) =
            _probeWord(address(pool), abi.encodeCall(IManagedDirectPropAMM.factory, ()));
        if (factoryOk && factoryWord == 0) {
            _finding("Standalone creation provenance not authenticated: initial access state may be absent from events");
        }
        console2.log("Findings", _findings.length);
        return _findings;
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory c) {
        c.pool = IManagedDirectPropAMM(vm.envAddress(_envKey("POOL_ADDRESS")));
        c.mode = _parseMode(vm.envString(_envKey("MODE")));
        string memory pairIndex = vm.envOr(_envKey("PAIR_INDEX"), string(""));
        if (bytes(pairIndex).length != 0) {
            c.hasPairIndex = true;
            c.pairIndex = _uint16(vm.parseUint(pairIndex), "PAIR_INDEX");
        }
        c.expectedBase = vm.envOr(_envKey("EXPECTED_BASE"), address(0));
        c.expectedQuote = vm.envOr(_envKey("EXPECTED_QUOTE"), address(0));
        c.expectedOracle = vm.envOr(_envKey("EXPECTED_ORACLE"), address(0));
        // Only an omitted/empty id means the home list. A failed numeric parse must not retarget a sponsor edit.
        string memory sponsorId = vm.envOr(_envKey("SPONSOR_ID"), string(""));
        if (bytes(sponsorId).length != 0) {
            c.sponsorId = _uint64(vm.parseUint(sponsorId), "SPONSOR_ID");
        }
        c.accounts = vm.envExists(_envKey("ACCOUNTS")) ? vm.envAddress(_envKey("ACCOUNTS"), ",") : new address[](0);
        c.sponsorAdmin = vm.envExists(_envKey("SPONSOR_ADMIN")) ? vm.envAddress(_envKey("SPONSOR_ADMIN")) : address(0);
        c.access = _parseAccess(vm.envOr(_envKey("ACCESS"), string("")));
        c.caller = vm.envExists(_envKey("CALLER")) ? vm.envAddress(_envKey("CALLER")) : address(0);
        c.broadcast = vm.envExists(_envKey("BROADCAST")) ? vm.envBool(_envKey("BROADCAST")) : false;
        uint256[] memory ids = vm.envExists(_envKey("EXPECTED_SPONSOR_IDS"))
            ? vm.envUint(_envKey("EXPECTED_SPONSOR_IDS"), ",")
            : new uint256[](0);
        c.expectedSponsorIds = new uint64[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            c.expectedSponsorIds[i] = _uint64(ids[i], "EXPECTED_SPONSOR_IDS");
        }
        c.expectedSponsorAdmins = vm.envExists(_envKey("EXPECTED_SPONSOR_ADMINS"))
            ? vm.envAddress(_envKey("EXPECTED_SPONSOR_ADMINS"), ",")
            : new address[](0);
        c.fromBlock = vm.envExists(_envKey("FROM_BLOCK")) ? vm.envUint(_envKey("FROM_BLOCK")) : uint256(0);
        c.logBlockRange = vm.envExists(_envKey("LOG_BLOCK_RANGE")) ? vm.envUint(_envKey("LOG_BLOCK_RANGE")) : uint256(0);
        c.expectedFactory =
            vm.envExists(_envKey("EXPECTED_FACTORY")) ? vm.envAddress(_envKey("EXPECTED_FACTORY")) : address(0);
        c.expectedSettler =
            vm.envExists(_envKey("EXPECTED_SETTLER")) ? vm.envAddress(_envKey("EXPECTED_SETTLER")) : address(0);
    }

    /// @dev Lets parser tests isolate their environment keys from parallel suites.
    function _envKey(string memory key) internal view virtual returns (string memory) {
        return key;
    }

    /// @dev Sends `data` to `target` under the prank or broadcast `_change` set up. Test harnesses override this to see
    /// which one is active.
    function _send(address target, bytes memory data) internal virtual {
        target.functionCall(data);
    }

    /// @dev The RPC's `eth_getLogs` for every log `emitter` emitted in `[fromBlock, toBlock]`, in order. Test harnesses
    /// override this, since a test has no RPC.
    function _getLogs(uint256 fromBlock, uint256 toBlock, address emitter)
        internal
        virtual
        returns (Vm.EthGetLogs[] memory)
    {
        // One request per block range of the replay.
        // forge-lint: disable-next-line(calls-loop)
        return vm.eth_getLogs(fromBlock, toBlock, emitter, new bytes32[](0));
    }

    /// @dev Filter at the RPC boundary, before Foundry allocates and decodes unrelated pool activity.
    function _getIdentityLogs(uint256 fromBlock, uint256 toBlock, address emitter, bytes32 kind, uint16 pairIndex)
        internal
        virtual
        returns (Vm.EthGetLogs[] memory)
    {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = kind;
        topics[1] = bytes32(uint256(pairIndex));
        // One exact event/pair query per identity stream and block range.
        // forge-lint: disable-next-line(calls-loop)
        return vm.eth_getLogs(fromBlock, toBlock, emitter, topics);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Inputs
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Refuses an input `MODE` needs but lacks, or one that doesn't apply to it.
    function _checkInputs(Config memory config) internal view {
        Mode mode = config.mode;
        bool listMode = mode == Mode.LIST || mode == Mode.DELIST;
        bool usesPair = listMode || mode == Mode.ADMIT || mode == Mode.UNADMIT || mode == Mode.PAIR_ACCESS
            || mode == Mode.CLOSE_PAIR;
        bool needsAccounts = listMode || mode == Mode.DENY || mode == Mode.UNDENY || mode == Mode.SET_SETTLER;
        bool usesAdmin = mode == Mode.ADD_SPONSOR || mode == Mode.RESET_SPONSOR || mode == Mode.TRANSFER_SPONSOR_ADMIN;
        if (usesPair != config.hasPairIndex) revert InvalidConfig("PAIR_INDEX");
        if (_sponsorMode(mode) ? config.sponsorId == 0 : !listMode && config.sponsorId != 0) {
            revert InvalidConfig("SPONSOR_ID");
        }
        if (needsAccounts ? config.accounts.length == 0 : mode != Mode.CHECK && config.accounts.length != 0) {
            revert InvalidConfig("ACCOUNTS");
        }
        if (mode == Mode.SET_SETTLER && config.accounts.length != 1) {
            revert InvalidConfig("ACCOUNTS: exactly one settler");
        }
        if (config.accounts.length > MAX_ACCOUNTS) {
            revert InvalidConfig("ACCOUNTS has more than 50 accounts: split the batch");
        }
        if (usesAdmin ? config.sponsorAdmin == address(0) : config.sponsorAdmin != address(0)) {
            revert InvalidConfig("SPONSOR_ADMIN");
        }
        bool hasAccess = config.access != IManagedDirectPropAMM.AccessMode.None;
        if ((mode == Mode.PAIR_ACCESS) != hasAccess) revert InvalidConfig("ACCESS");
        _checkCheckInputs(config);
        _checkAccounts(config);
        if (
            !usesPair
                && (config.expectedBase != address(0)
                    || config.expectedQuote != address(0)
                    || config.expectedOracle != address(0))
        ) {
            revert InvalidConfig("EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE are for pair modes");
        }
        if (usesAdmin) {
            address admin = config.sponsorAdmin;
            if (admin == address(config.pool)) revert InvalidConfig("SPONSOR_ADMIN is the pool");
            if (_isVirtual(admin)) {
                revert InvalidConfig("SPONSOR_ADMIN is a TIP-1022 virtual address, which can never call");
            }
        }
    }

    /// @dev The modes that act on one registered sponsor, so need a nonzero `SPONSOR_ID`.
    function _sponsorMode(Mode mode) internal pure returns (bool) {
        return mode == Mode.ADD_SPONSOR || mode == Mode.ENABLE_SPONSOR || mode == Mode.DISABLE_SPONSOR
            || mode == Mode.ADMIT || mode == Mode.UNADMIT || mode == Mode.RESET_SPONSOR
            || mode == Mode.TRANSFER_SPONSOR_ADMIN || mode == Mode.CANCEL_SPONSOR_ADMIN_TRANSFER
            || mode == Mode.ACCEPT_SPONSOR_ADMIN;
    }

    /// @dev History inputs also serve removed-pair cleanup; other CHECK inputs never apply to changes.
    function _checkCheckInputs(Config memory config) internal view {
        uint64[] memory ids = config.expectedSponsorIds;
        if (config.mode != Mode.CHECK) {
            if (ids.length + config.expectedSponsorAdmins.length != 0) {
                revert InvalidConfig("EXPECTED_SPONSOR_* inputs are for CHECK");
            }
            bool cleanup = config.mode == Mode.DELIST || config.mode == Mode.UNADMIT;
            if (!cleanup && config.fromBlock != 0) revert InvalidConfig("FROM_BLOCK is for CHECK");
            if (!cleanup && config.logBlockRange != 0) revert InvalidConfig("LOG_BLOCK_RANGE is for CHECK");
            if (cleanup) {
                if (config.fromBlock > block.number) revert InvalidConfig("FROM_BLOCK");
                if (config.logBlockRange != 0 && config.fromBlock == 0) {
                    revert InvalidConfig("LOG_BLOCK_RANGE needs FROM_BLOCK");
                }
            }
            if (config.expectedFactory != address(0)) revert InvalidConfig("EXPECTED_FACTORY is for CHECK");
            if (config.expectedSettler != address(0)) revert InvalidConfig("EXPECTED_SETTLER is for CHECK");
            return;
        }
        if (config.expectedSettler != address(0) && config.expectedFactory == address(0)) {
            revert InvalidConfig("EXPECTED_SETTLER needs EXPECTED_FACTORY");
        }
        if (config.caller != address(0)) revert InvalidConfig("CALLER");
        if (config.broadcast) revert InvalidConfig("BROADCAST");
        if (config.expectedSponsorAdmins.length != ids.length) {
            revert InvalidConfig("EXPECTED_SPONSOR_* inputs need one entry per id");
        }
        // A check of operator input before anything runs: any bad entry stops the whole run.
        for (uint256 i = 0; i < ids.length; ++i) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (ids[i] == 0) revert InvalidConfig("EXPECTED_SPONSOR_IDS has 0, the home lists");
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (config.expectedSponsorAdmins[i] == address(0)) revert InvalidConfig("EXPECTED_SPONSOR_ADMINS");
            for (uint256 j = 0; j < i; ++j) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (ids[j] == ids[i]) revert InvalidConfig("EXPECTED_SPONSOR_IDS has a duplicate");
            }
        }
        if (config.fromBlock > block.number) revert InvalidConfig("FROM_BLOCK");
        // Without `FROM_BLOCK` there is no replay, so a range would be silently ignored.
        if (config.logBlockRange != 0 && config.fromBlock == 0) {
            revert InvalidConfig("LOG_BLOCK_RANGE needs FROM_BLOCK");
        }
    }

    /// @dev Refuses a zero or duplicate account; for a change the pool itself, which the pool refuses; and for a
    /// settler, listing or denial a TIP-1022 virtual address, which never calls: the swap checks its caller, so list or deny
    /// the master.
    function _checkAccounts(Config memory config) internal pure {
        address[] memory accounts = config.accounts;
        Mode mode = config.mode;
        // A check of operator input before anything runs: any bad entry stops the whole run.
        for (uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (account == address(0)) revert InvalidConfig("ACCOUNTS has address(0)");
            if (mode != Mode.CHECK && account == address(config.pool)) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert InvalidConfig("ACCOUNTS has the pool");
            }
            if (_isVirtual(account)) {
                if (mode == Mode.SET_SETTLER) {
                    // forge-lint: disable-next-line(require-revert-in-loop)
                    revert InvalidConfig("ACCOUNTS has a TIP-1022 virtual address, which can never call as settler");
                }
                if (mode == Mode.LIST) {
                    // forge-lint: disable-next-line(require-revert-in-loop)
                    revert InvalidConfig("ACCOUNTS has a TIP-1022 virtual address, which never calls: list its master");
                }
                if (mode == Mode.DENY) {
                    // forge-lint: disable-next-line(require-revert-in-loop)
                    revert InvalidConfig("ACCOUNTS has a TIP-1022 virtual address, which never calls: deny its master");
                }
            }
            for (uint256 j = 0; j < i; ++j) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (accounts[j] == account) revert InvalidConfig("ACCOUNTS has a duplicate");
            }
        }
    }

    /// @dev Rejects incompatible pool view shapes, not a proof of pool code or creation. Raw probes require exact
    /// 32-byte answers, so anything else is refused by name, never with whatever it returned: a `DirectPropAMM`, which has no `pairCount`,
    /// a v2 `Venue`, which answers `pairCount` and `MAX_BATCH` as the pool does but has no `tokenPairCount`, or a contract
    /// that answers oddly.
    function _checkPool(IManagedDirectPropAMM pool) internal view {
        address target = address(pool);
        if (target.code.length == 0) revert InvalidConfig("POOL_ADDRESS has no code");
        (bool ok, uint256 pairs) = _probeWord(target, abi.encodeCall(IManagedDirectPropAMM.pairCount, ()));
        (bool okBatch, uint256 maxBatch) = _probeWord(target, abi.encodeCall(IManagedDirectPropAMM.MAX_BATCH, ()));
        (bool okTokens, uint256 tokenPairs) =
            _probeWord(target, abi.encodeCall(IManagedDirectPropAMM.tokenPairCount, (address(0))));
        if (
            !ok || pairs > type(uint16).max || !okBatch || maxBatch != POOL_MAX_BATCH || !okTokens
                || tokenPairs > type(uint16).max
        ) revert InvalidConfig("POOL_ADDRESS is not a ManagedDirectPropAMM");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Changes
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Logs what the change does, refuses one that changes nothing, runs it as the caller (and sends it with
    /// `BROADCAST`), checks that it applied, warns about what it leaves in place, and prints the Safe transaction.
    function _change(Config memory config) internal returns (bytes memory data) {
        delete _warnings;
        IManagedDirectPropAMM pool = config.pool;
        CleanupProof memory proof;
        if (config.hasPairIndex) proof = _checkPairIdentity(config);
        address caller = config.caller == address(0) ? _defaultCaller(config) : config.caller;
        if (caller == address(0)) {
            // Only the sponsor-admin and pending-admin defaults can be missing.
            if (config.mode == Mode.ACCEPT_SPONSOR_ADMIN) revert InvalidConfig("SPONSOR_ID has no pending admin");
            revert InvalidConfig("SPONSOR_ID is not a registered sponsor");
        }
        data = _calldata(config);
        if (_logChange(config) == 0) revert InvalidConfig("nothing to change");
        // forge-lint: disable-next-line(unused-return)
        (,, uint32 generationBefore) = pool.sponsor(config.sponsorId);
        uint32 deniedBefore = pool.deniedCount();

        if (config.broadcast) {
            vm.startBroadcast(caller);
            _send(address(pool), data);
            vm.stopBroadcast();
        } else {
            vm.prank(caller);
            _send(address(pool), data);
        }
        _checkApplied(config, caller, generationBefore, proof);
        _warnAfter(config, deniedBefore);

        console2.log("Safe transaction");
        console2.log("  chain id", block.chainid);
        console2.log(string.concat("  from ", Strings.toChecksumHexString(caller), " ", _roleOf(config, caller)));
        console2.log("  to", address(pool));
        console2.log("  value 0");
        console2.log("  data");
        console2.logBytes(data);
        if (!config.broadcast) console2.log("Not sent. Submit to, value and data from the sender above.");
        if (_warnings.length != 0) console2.log("Warnings above", _warnings.length);
    }

    /// @dev The account that sends the mode's call: the sponsor's admin for its lists and handover, the pending admin
    /// for an acceptance, and the owner for everything else. 0 when that account doesn't exist.
    function _defaultCaller(Config memory config) internal view returns (address) {
        Mode mode = config.mode;
        IManagedDirectPropAMM pool = config.pool;
        if (mode == Mode.ACCEPT_SPONSOR_ADMIN) return pool.pendingSponsorAdmin(config.sponsorId);
        bool adminMode = mode == Mode.TRANSFER_SPONSOR_ADMIN || mode == Mode.CANCEL_SPONSOR_ADMIN_TRANSFER
            || ((mode == Mode.LIST || mode == Mode.DELIST) && config.sponsorId != 0);
        if (!adminMode) return pool.owner();
        // forge-lint: disable-next-line(unused-return)
        (address admin,,) = pool.sponsor(config.sponsorId);
        return admin;
    }

    function _calldata(Config memory config) internal pure returns (bytes memory) {
        Mode mode = config.mode;
        uint64 id = config.sponsorId;
        if (mode == Mode.LIST || mode == Mode.DELIST) {
            return abi.encodeCall(
                IManagedDirectPropAMM.setMembers, (config.pairIndex, id, config.accounts, mode == Mode.LIST)
            );
        }
        if (mode == Mode.DENY || mode == Mode.UNDENY) {
            return abi.encodeCall(IManagedDirectPropAMM.setDenied, (config.accounts, mode == Mode.DENY));
        }
        if (mode == Mode.ADD_SPONSOR) {
            return abi.encodeCall(IManagedDirectPropAMM.addSponsor, (id, config.sponsorAdmin));
        }
        if (mode == Mode.ENABLE_SPONSOR || mode == Mode.DISABLE_SPONSOR) {
            return abi.encodeCall(IManagedDirectPropAMM.setSponsorEnabled, (id, mode == Mode.ENABLE_SPONSOR));
        }
        if (mode == Mode.ADMIT || mode == Mode.UNADMIT) {
            return abi.encodeCall(IManagedDirectPropAMM.setPairSponsor, (config.pairIndex, id, mode == Mode.ADMIT));
        }
        if (mode == Mode.RESET_SPONSOR) {
            return abi.encodeCall(IManagedDirectPropAMM.resetSponsor, (id, config.sponsorAdmin));
        }
        if (mode == Mode.TRANSFER_SPONSOR_ADMIN) {
            return abi.encodeCall(IManagedDirectPropAMM.transferSponsorAdmin, (id, config.sponsorAdmin));
        }
        if (mode == Mode.CANCEL_SPONSOR_ADMIN_TRANSFER) {
            return abi.encodeCall(IManagedDirectPropAMM.cancelSponsorAdminTransfer, (id));
        }
        if (mode == Mode.ACCEPT_SPONSOR_ADMIN) return abi.encodeCall(IManagedDirectPropAMM.acceptSponsorAdmin, (id));
        if (mode == Mode.PAIR_ACCESS) {
            return abi.encodeCall(IManagedDirectPropAMM.setPairAccess, (config.pairIndex, config.access));
        }
        if (mode == Mode.SET_SETTLER) {
            return abi.encodeCall(IManagedDirectPropAMM.setSettler, (config.accounts[0]));
        }
        return abi.encodeCall(IManagedDirectPropAMM.closePair, (config.pairIndex));
    }

    /// @dev Logs the change and returns how many entries it changes. A call the pool will refuse (an unknown pair or
    /// sponsor, a registered id) counts as a change, so the simulation reverts with the pool's own error.
    function _logChange(Config memory config) internal returns (uint256 changes) {
        Mode mode = config.mode;
        if (mode == Mode.SET_SETTLER) {
            console2.log("Replace trusted settler with", config.accounts[0]);
            _warning(
                "Settler is custody-trusted: it can drain inventory without delivering input; review its authentication,"
                " prepayment checks and upgrade authority before submitting"
            );
            // Code is not a trust proof. Preserve intentional EOAs and future deployment addresses, but never
            // present either as a reviewed settler or silently endorse a mistyped address.
            if (config.accounts[0].code.length == 0) {
                _warning(
                    "Settler has no code: verify the address and chain; an EOA can spend inventory directly and a future"
                    " deployment must be reviewed before use"
                );
            }
            return config.pool.settler() != config.accounts[0] ? 1 : 0;
        }
        if (mode == Mode.LIST || mode == Mode.DELIST || mode == Mode.DENY || mode == Mode.UNDENY) {
            return _logAccountChange(config);
        }
        if (mode == Mode.PAIR_ACCESS || mode == Mode.CLOSE_PAIR) return _logPairChange(config);
        IManagedDirectPropAMM pool = config.pool;
        uint64 id = config.sponsorId;
        string memory name = string.concat("sponsor ", Strings.toString(id));
        (address admin, bool enabled, uint32 generation) = pool.sponsor(id);
        address pending = pool.pendingSponsorAdmin(id);
        if (mode == Mode.ADD_SPONSOR) {
            console2.log(string.concat("Register ", name, " with admin ", _named(config.sponsorAdmin)));
            console2.log("  It starts enabled and admitted on no pair: ADMIT it on each pair its users trade.");
            return 1;
        }
        if (admin == address(0)) return 1;
        if (mode == Mode.ENABLE_SPONSOR || mode == Mode.DISABLE_SPONSOR) {
            bool target = mode == Mode.ENABLE_SPONSOR;
            if (enabled == target) return 0;
            console2.log(string.concat(target ? "Switch on " : "Switch off (its lists are kept) ", name));
            if (target) {
                _warning(
                    "Enabling restores retained current-generation listings on every admitted pair when other access"
                    " gates permit; run MODE=CHECK with FROM_BLOCK to review members before sending"
                );
            }
            return 1;
        }
        if (mode == Mode.ADMIT || mode == Mode.UNADMIT) {
            bool target = mode == Mode.ADMIT;
            if (!target && pool.pair(config.pairIndex).access == IManagedDirectPropAMM.AccessMode.None) {
                _warning("Clear retained admission if any (removed pair; effective access unchanged)");
                return 1;
            }
            if (pool.pairSponsor(config.pairIndex, id) == target) return 0;
            console2.log(
                string.concat(
                    target ? "Admit " : "Remove (its list there is kept) ",
                    name,
                    target ? " on pair " : " from pair ",
                    Strings.toString(config.pairIndex)
                )
            );
            if (target) {
                _warning(
                    "Admission restores retained current-generation listings on this pair when other access gates"
                    " permit; run MODE=CHECK with FROM_BLOCK to review members before sending"
                );
                if (!enabled) {
                    _warning(string.concat(name, " is switched off: its users trade nowhere until ENABLE_SPONSOR"));
                }
            }
            return 1;
        }
        if (mode == Mode.RESET_SPONSOR) {
            console2.log(string.concat("Reset ", name, ": admin ", _named(admin), " -> ", _named(config.sponsorAdmin)));
            console2.log(
                string.concat(
                    "  generation ", Strings.toString(generation), " -> ", Strings.toString(uint256(generation) + 1)
                )
            );
            _warning(
                string.concat(
                    "every listing ", name, " made on any pair stops admitting anyone; its new admin re-lists"
                )
            );
            return 1;
        }
        if (mode == Mode.TRANSFER_SPONSOR_ADMIN) {
            if (pending == config.sponsorAdmin) return 0;
            console2.log(string.concat("Propose ", _named(config.sponsorAdmin), " as ", name, "'s admin"));
            console2.log("  It must accept (ACCEPT_SPONSOR_ADMIN); until then the current admin keeps the lists.");
            return 1;
        }
        if (mode == Mode.CANCEL_SPONSOR_ADMIN_TRANSFER) {
            if (pending == address(0)) return 0;
            console2.log(string.concat("Cancel ", name, "'s pending handover to ", _named(pending)));
            return 1;
        }
        console2.log(string.concat(_named(pending), " takes over ", name, "'s lists from ", _named(admin)));
        return 1;
    }

    /// @dev Counts effective changes and explicit reset/removed-pair cleanups; hidden retained state and an empty
    /// slot read alike, so cleanup never claims a storage change it cannot prove.
    function _logAccountChange(Config memory config) internal returns (uint256 changes) {
        Mode mode = config.mode;
        bool deny = mode == Mode.DENY || mode == Mode.UNDENY;
        bool target = mode == Mode.LIST || mode == Mode.DENY;
        bool cleanup = mode == Mode.DELIST && config.sponsorId != 0;
        if (cleanup) {
            (,, uint32 generation) = config.pool.sponsor(config.sponsorId);
            cleanup = generation > 1;
        }
        if (mode == Mode.DELIST && config.pool.pair(config.pairIndex).access == IManagedDirectPropAMM.AccessMode.None) {
            cleanup = true;
        }
        if (deny) {
            console2.log(target ? "Deny, pool-wide" : "Lift denials, pool-wide");
        } else {
            console2.log(
                string.concat(
                    target ? "List on pair " : "Delist from pair ",
                    Strings.toString(config.pairIndex),
                    " under ",
                    _listName(config.sponsorId)
                )
            );
        }
        for (uint256 i = 0; i < config.accounts.length; ++i) {
            address account = config.accounts[i];
            bool current = deny ? _denied(config.pool, account) : _isMember(config, account);
            if (cleanup && !current) {
                ++changes;
                _warning(
                    string.concat(
                        Strings.toChecksumHexString(account),
                        ": clear retained listing if any (effective membership unchanged)"
                    )
                );
                continue;
            }
            if (current != target) ++changes;
            string memory result = current == target
                ? "no change"
                : (target ? (deny ? "denied" : "listed") : (deny ? "lifted" : "delisted"));
            console2.log(string.concat("  ", Strings.toChecksumHexString(account), ": ", result));
        }
    }

    function _logPairChange(Config memory config) internal returns (uint256) {
        IManagedDirectPropAMM pool = config.pool;
        IManagedDirectPropAMM.AccessMode current = pool.pair(config.pairIndex).access;
        IManagedDirectPropAMM.AccessMode target =
            config.mode == Mode.CLOSE_PAIR ? IManagedDirectPropAMM.AccessMode.Closed : config.access;
        if (current == IManagedDirectPropAMM.AccessMode.None) return 1;
        if (current == target) return 0;
        if (target == IManagedDirectPropAMM.AccessMode.Open && !pool.paused()) {
            revert InvalidConfig("ACCESS=open needs the pool paused: setPairAccess reverts NotPaused");
        }
        console2.log(
            string.concat(
                "Pair ", Strings.toString(config.pairIndex), ": ", _accessName(current), " -> ", _accessName(target)
            )
        );
        if (current == IManagedDirectPropAMM.AccessMode.Closed) {
            console2.log(
                "  Leaving Closed requires a fresh oracle price; deviation is checked only against nonzero anchors."
            );
            if (pool.priceAnchor(config.pairIndex, true) == 0 || pool.priceAnchor(config.pairIndex, false) == 0) {
                _warning(
                    "A zero directional anchor is initialized from the execution-time oracle price, without a deviation"
                    " or expected-price bound. The mined call re-derives it; simulation does not bind that price."
                    " After inclusion run MODE=CHECK and compare both anchors (or PriceAnchorUpdated events) with"
                    " the reviewed observation before allowing swaps"
                );
            }
        }
        console2.log("  Before call (review observation, not a mined-price guarantee)");
        _reportPair(pool, config.pairIndex);
        return 1;
    }

    /// @dev Pair tokens are immutable and indexes are never reused. Bind the operator's reviewed identity,
    /// not the provisional position of an addPair call in a deployment simulation.
    function _checkPairIdentity(Config memory config) internal returns (CleanupProof memory proof) {
        if (
            config.expectedBase == address(0) || config.expectedQuote == address(0)
                || config.expectedOracle == address(0)
        ) {
            revert InvalidConfig("EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE required for pair modes");
        }
        IManagedDirectPropAMM.Pair memory p = config.pool.pair(config.pairIndex);
        if (p.access == IManagedDirectPropAMM.AccessMode.None) {
            _checkRemovedPairState(config, p);
            return _checkRemovedPairHistory(config);
        }
        if (config.fromBlock != 0 || config.logBlockRange != 0) {
            revert InvalidConfig("cleanup history requires a removed pair");
        }
        if (
            p.base != config.expectedBase || p.quote != config.expectedQuote
                || address(p.oracle) != config.expectedOracle
        ) {
            revert UnexpectedState("pair identity");
        }
        // Live actions require uniqueness among live pairs; historical cleanup binds one mined index.
        uint16 count = config.pool.pairCount();
        for (uint16 i; i < count; ++i) {
            if (i == config.pairIndex) continue;
            IManagedDirectPropAMM.Pair memory other = config.pool.pair(i);
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (
                other.access != IManagedDirectPropAMM.AccessMode.None && other.base == p.base && other.quote == p.quote
                    && address(other.oracle) == address(p.oracle)
            ) {
                revert UnexpectedState("ambiguous pair identity");
            }
        }
        console2.log("Reviewed pair index", config.pairIndex);
        console2.log("  base", p.base);
        console2.log("  quote", p.quote);
        console2.log("  oracle", address(p.oracle));
    }

    /// @dev Re-read the removed record after the call without repeating its immutable identity history.
    function _checkRemovedPairState(Config memory config, IManagedDirectPropAMM.Pair memory p) internal view {
        if (
            (config.mode != Mode.DELIST && config.mode != Mode.UNADMIT) || config.fromBlock == 0
                || config.pairIndex >= config.pool.pairCount()
        ) revert IManagedDirectPropAMM.UnknownPair(config.pairIndex);
        IManagedDirectPropAMM.Pair memory empty;
        if (keccak256(abi.encode(p)) != keccak256(abi.encode(empty))) revert UnexpectedState("removed pair state");
    }

    /// @dev Trusts the selected RPC's canonical history, never a supplied event file or a guessed storage layout.
    /// Block hashes bind the logs to that history; a changed simulation head aborts the proof.
    function _canonicalBlockHash(uint256 number) internal virtual returns (bytes32 hash) {
        string memory answer = VmRpcJson(address(vm))
            .rpcJson("eth_getBlockByNumber", string.concat("[\"", _blockQuantity(number), "\",false]"));
        hash = vm.parseJsonBytes32(answer, ".hash");
        if (hash == bytes32(0)) revert UnexpectedState("missing canonical block");
    }

    /// @dev RPC quantities omit the leading zero nibble that byte-oriented hex encoders retain.
    function _blockQuantity(uint256 number) internal pure returns (string memory) {
        bytes memory padded = bytes(Strings.toHexString(number));
        if (padded[2] != "0") return string(padded);
        bytes memory quantity = new bytes(padded.length - 1);
        quantity[0] = "0";
        quantity[1] = "x";
        for (uint256 i = 2; i < quantity.length; ++i) {
            quantity[i] = padded[i + 1];
        }
        return string(quantity);
    }

    function _checkRemovedPairHistory(Config memory config) internal returns (CleanupProof memory proof) {
        uint256 last = block.number;
        proof = CleanupProof({ blockNumber: last, blockHash: _canonicalBlockHash(last) });
        RemovedPairHistory memory history;
        uint256 replayed;
        // Only value fields survive each chunk, in history/proof/config allocated before this checkpoint.
        // No log, topic, data or RPC-answer pointer escapes the iteration.
        uint256 checkpoint;
        assembly ("memory-safe") { checkpoint := mload(0x40) }
        uint256 range = config.logBlockRange == 0 ? DEFAULT_LOG_BLOCK_RANGE : config.logBlockRange;
        for (uint256 from = config.fromBlock; from <= last;) {
            uint256 end = range - 1 > last - from ? last : from + range - 1;
            replayed = _replayIdentityRange(config, history, from, end, replayed);
            assembly ("memory-safe") { mstore(0x40, checkpoint) }
            if (end == last) break;
            from = end + 1;
        }
        if (!history.removed || history.oracle != config.expectedOracle) {
            revert UnexpectedState("removed pair identity history");
        }
        _checkCleanupHead(proof);
        console2.log("Reviewed removed pair index", config.pairIndex);
        console2.log("  base", config.expectedBase);
        console2.log("  quote", config.expectedQuote);
        console2.log("  oracle at removal", config.expectedOracle);
    }

    /// @dev Merge stream heads only: never sort a provider's stream into validity. The global order check also
    /// rejects any backwards step within a stream, duplicate position, or inconsistent same-block hash.
    function _replayIdentityRange(
        Config memory config,
        RemovedPairHistory memory history,
        uint256 from,
        uint256 end,
        uint256 replayed
    ) internal returns (uint256) {
        bytes32[3] memory kinds = [
            IManagedDirectPropAMM.PairAdded.selector,
            IManagedDirectPropAMM.OracleUpdated.selector,
            IManagedDirectPropAMM.PairRemoved.selector
        ];
        Vm.EthGetLogs[][3] memory streams;
        for (uint256 i; i < streams.length; ++i) {
            // Empty responses still spend gas; reserve before every query, not only before processing entries.
            _requireCheckGas(replayed);
            streams[i] = _getIdentityLogs(from, end, address(config.pool), kinds[i], config.pairIndex);
        }
        uint256[3] memory cursors;
        while (true) {
            _requireCheckGas(replayed);
            uint256 selected = streams.length;
            for (uint256 i; i < streams.length; ++i) {
                if (cursors[i] == streams[i].length) continue;
                if (selected == streams.length) {
                    selected = i;
                    continue;
                }
                Vm.EthGetLogs memory candidate = streams[i][cursors[i]];
                Vm.EthGetLogs memory first = streams[selected][cursors[selected]];
                if (
                    candidate.blockNumber < first.blockNumber
                        || (candidate.blockNumber == first.blockNumber && candidate.logIndex < first.logIndex)
                ) selected = i;
            }
            if (selected == streams.length) break;
            Vm.EthGetLogs memory entry = streams[selected][cursors[selected]++];
            // An RPC filter is not evidence that the returned log actually matches it.
            if (
                entry.topics.length < 2 || entry.topics[0] != kinds[selected]
                    || entry.topics[1] != bytes32(uint256(config.pairIndex))
            ) revert UnexpectedState("off-filter cleanup log");
            _checkCleanupLog(config, history, entry, from, end);
            _applyPairIdentity(config, history, entry);
            ++replayed;
        }
        return replayed;
    }

    function _checkCleanupHead(CleanupProof memory proof) internal {
        if (block.number != proof.blockNumber || _canonicalBlockHash(proof.blockNumber) != proof.blockHash) {
            revert UnexpectedState("cleanup history reorg");
        }
    }

    /// @dev Every returned identity log must be well formed and strictly ordered across streams and ranges.
    function _checkCleanupLog(
        Config memory config,
        RemovedPairHistory memory history,
        Vm.EthGetLogs memory entry,
        uint256 from,
        uint256 end
    ) internal pure {
        if (
            entry.emitter != address(config.pool) || entry.removed || entry.topics.length == 0
                || entry.blockNumber < from || entry.blockNumber > end || entry.transactionHash == bytes32(0)
                || entry.blockHash == bytes32(0)
                || (history.hasLog
                    && (entry.blockNumber < history.blockNumber
                        || (entry.blockNumber == history.blockNumber && entry.logIndex <= history.logIndex)))
        ) revert UnexpectedState("invalid cleanup log");
        if (!history.hasLog || entry.blockNumber != history.blockNumber) {
            history.blockHash = entry.blockHash;
        }
        if (entry.blockHash != history.blockHash) revert UnexpectedState("cleanup log block hash");
        history.hasLog = true;
        history.blockNumber = entry.blockNumber;
        history.logIndex = entry.logIndex;
    }

    /// @dev Tokens never change; the oracle chain begins at zero and ends at the unique removal.
    function _applyPairIdentity(Config memory config, RemovedPairHistory memory history, Vm.EthGetLogs memory entry)
        internal
    {
        bytes32[] memory topics = entry.topics;
        bytes32 kind = topics[0];
        bool added = kind == IManagedDirectPropAMM.PairAdded.selector;
        bool oracle = kind == IManagedDirectPropAMM.OracleUpdated.selector;
        bool removed = kind == IManagedDirectPropAMM.PairRemoved.selector;
        if (!added && !oracle && !removed) revert UnexpectedState("off-filter cleanup log");
        if (
            topics.length != (removed ? 2 : 4) || entry.data.length != (oracle ? 32 : 0)
                || uint256(topics[1]) > type(uint16).max
        ) revert UnexpectedState("malformed pair identity log");
        if (uint256(topics[1]) != config.pairIndex) revert UnexpectedState("off-filter cleanup log");
        // Only identity events contribute to this proof; unrelated activity must not incur header RPC calls.
        if (history.canonicalBlockHash == bytes32(0) || history.canonicalBlockNumber != entry.blockNumber) {
            history.canonicalBlockNumber = entry.blockNumber;
            history.canonicalBlockHash = _canonicalBlockHash(entry.blockNumber);
        }
        if (entry.blockHash != history.canonicalBlockHash) revert UnexpectedState("cleanup log block hash");
        if (history.removed) revert UnexpectedState("identity event after removal");
        if (removed) {
            if (!history.added || history.oracle == address(0)) revert UnexpectedState("incomplete pair identity");
            history.removed = true;
            return;
        }
        if (uint256(topics[2]) > type(uint160).max || uint256(topics[3]) > type(uint160).max) {
            revert UnexpectedState("malformed pair identity address");
        }
        address first = address(uint160(uint256(topics[2])));
        address second = address(uint160(uint256(topics[3])));
        if (added) {
            if (history.added || first != config.expectedBase || second != config.expectedQuote) {
                revert UnexpectedState("pair identity");
            }
            history.added = true;
            return;
        }
        uint256 decimals = abi.decode(entry.data, (uint256));
        if (
            !history.added || first != history.oracle || second == address(0) || decimals > type(uint8).max
                || (history.oracle != address(0) && decimals != history.decimals)
        ) revert UnexpectedState("broken oracle history");
        // The bound above makes the conversion exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        history.decimals = uint8(decimals);
        history.oracle = second;
    }

    /// @dev Reverts unless the state reads as the change intended.
    function _checkApplied(Config memory config, address caller, uint32 generationBefore, CleanupProof memory proof)
        internal
    {
        Mode mode = config.mode;
        IManagedDirectPropAMM pool = config.pool;
        if (config.hasPairIndex) {
            if (proof.blockHash == bytes32(0)) {
                _checkPairIdentity(config);
            } else {
                _checkRemovedPairState(config, pool.pair(config.pairIndex));
                _checkCleanupHead(proof);
            }
        }
        if (mode == Mode.SET_SETTLER) {
            if (pool.settler() != config.accounts[0]) revert UnexpectedState("settler");
            return;
        }
        uint64 id = config.sponsorId;
        if (mode == Mode.LIST || mode == Mode.DELIST || mode == Mode.DENY || mode == Mode.UNDENY) {
            bool deny = mode == Mode.DENY || mode == Mode.UNDENY;
            bool target = mode == Mode.LIST || mode == Mode.DENY;
            // Read-only checks of the batch this run applied.
            for (uint256 i = 0; i < config.accounts.length; ++i) {
                address account = config.accounts[i];
                bool current = deny ? _denied(pool, account) : _isMember(config, account);
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (current != target) revert UnexpectedState(deny ? "denied" : "member");
            }
            return;
        }
        if (mode == Mode.PAIR_ACCESS || mode == Mode.CLOSE_PAIR) {
            IManagedDirectPropAMM.AccessMode target =
                mode == Mode.CLOSE_PAIR ? IManagedDirectPropAMM.AccessMode.Closed : config.access;
            if (pool.pair(config.pairIndex).access != target) revert UnexpectedState("pair access");
            console2.log("  After call (simulation state, not a post-inclusion CHECK)");
            _reportPair(pool, config.pairIndex);
            return;
        }
        if (mode == Mode.ADMIT || mode == Mode.UNADMIT) {
            if (pool.pairSponsor(config.pairIndex, id) != (mode == Mode.ADMIT)) revert UnexpectedState("admission");
            return;
        }
        (address admin, bool enabled, uint32 generation) = pool.sponsor(id);
        address pending = pool.pendingSponsorAdmin(id);
        if (mode == Mode.ADD_SPONSOR) {
            if (admin != config.sponsorAdmin || !enabled || generation != 1) revert UnexpectedState("sponsor");
        } else if (mode == Mode.ENABLE_SPONSOR || mode == Mode.DISABLE_SPONSOR) {
            if (enabled != (mode == Mode.ENABLE_SPONSOR)) revert UnexpectedState("enabled");
        } else if (mode == Mode.RESET_SPONSOR) {
            if (admin != config.sponsorAdmin || generation != uint256(generationBefore) + 1 || pending != address(0)) {
                revert UnexpectedState("reset");
            }
        } else if (mode == Mode.TRANSFER_SPONSOR_ADMIN) {
            if (pending != config.sponsorAdmin) revert UnexpectedState("pending admin");
        } else if (mode == Mode.CANCEL_SPONSOR_ADMIN_TRANSFER) {
            if (pending != address(0)) revert UnexpectedState("pending admin");
        } else if (admin != caller || pending != address(0)) {
            revert UnexpectedState("admin");
        }
    }

    /// @dev Warns about what a change leaves in place: an account a delisting leaves admitted, a listing that admits
    /// nobody yet, and a first denial, which makes every swap read the deny list.
    function _warnAfter(Config memory config, uint32 deniedBefore) internal {
        Mode mode = config.mode;
        IManagedDirectPropAMM pool = config.pool;
        if (mode == Mode.DENY && deniedBefore == 0) {
            console2.log("Every swap now reads the deny list (about 2,200 gas) while any account is denied.");
        }
        if (mode != Mode.LIST && mode != Mode.DELIST) return;
        IManagedDirectPropAMM.AccessMode access = pool.pair(config.pairIndex).access;
        string memory pairName = string.concat("pair ", Strings.toString(config.pairIndex));
        if (mode == Mode.LIST) {
            if (access == IManagedDirectPropAMM.AccessMode.Closed) {
                _warning(string.concat(pairName, " is Closed: the listing admits nobody until the owner opens it"));
            } else if (access == IManagedDirectPropAMM.AccessMode.Open) {
                _warning(string.concat(pairName, " is Open: it already admits everyone not denied"));
            }
            for (uint256 i = 0; i < config.accounts.length; ++i) {
                address account = config.accounts[i];
                if (_denied(pool, account)) {
                    _warning(string.concat(Strings.toChecksumHexString(account), " is denied: it trades nowhere"));
                }
            }
            return;
        }
        console2.log(
            "Other sponsors' lists are not checked: only a denial (MODE=DENY) blocks an account under every list."
        );
        // One report per account of the operator's batch.
        for (uint256 i = 0; i < config.accounts.length; ++i) {
            address account = config.accounts[i];
            string memory name = Strings.toChecksumHexString(account);
            bool isDenied = _denied(pool, account);
            if (access == IManagedDirectPropAMM.AccessMode.Open) {
                _warning(
                    isDenied
                        ? string.concat(name, " would be admitted once its denial is lifted: ", pairName, " is Open")
                        : string.concat(name, " is still admitted: ", pairName, " is Open; deny it (MODE=DENY)")
                );
            } else if (config.sponsorId != 0 && !isDenied && _onHomeList(config, account)) {
                _warning(string.concat(name, " is still on ", pairName, "'s home list"));
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Check
    // ---------------------------------------------------------------------------------------------------------------

    function _reportPair(IManagedDirectPropAMM pool, uint16 pairIndex) internal view {
        // One report per pair the pool ever added.
        // forge-lint: disable-next-line(calls-loop)
        IManagedDirectPropAMM.Pair memory info = pool.pair(pairIndex);
        string memory name = string.concat("Pair ", Strings.toString(pairIndex));
        if (info.access == IManagedDirectPropAMM.AccessMode.None) {
            console2.log(string.concat(name, ": removed"));
            return;
        }
        console2.log(string.concat(name, ": ", _accessName(info.access)));
        console2.log("  base", info.base);
        console2.log("  quote", info.quote);
        console2.log("  oracle", address(info.oracle));
        console2.log("  max oracle age (s) / deviation (bps)", info.maxOracleAge, info.maxPriceDeviationBps);
        // forge-lint: disable-next-line(calls-loop)
        uint256 baseAnchor = pool.priceAnchor(pairIndex, true);
        // forge-lint: disable-next-line(calls-loop)
        uint256 quoteAnchor = pool.priceAnchor(pairIndex, false);
        console2.log("  anchors base->quote / quote->base", baseAnchor, quoteAnchor);
        (bool ok, uint256 price, uint256 updatedAt) = _latestPrice(address(info.oracle));
        if (!ok) {
            console2.log(string.concat("  WARNING: the oracle doesn't answer latestPrice(): ", name, " can't trade"));
        } else if (price == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > info.maxOracleAge) {
            console2.log(string.concat("  WARNING: the oracle is not fresh: swaps on ", name, " revert"));
            console2.log("  price / updatedAt", price, updatedAt);
        } else {
            console2.log("  oracle price / age (s)", price, block.timestamp - updatedAt);
        }
    }

    /// @dev Logs an expected sponsor and flags one that isn't registered, has another admin, has a pending handover or
    /// is switched off.
    function _checkExpectedSponsor(IManagedDirectPropAMM pool, uint64 id, address expectedAdmin, uint16 pairs)
        internal
    {
        // Called once per expected sponsor.
        // forge-lint: disable-next-line(calls-loop, unused-return)
        (address admin, bool enabled,) = pool.sponsor(id);
        string memory name = string.concat("sponsor ", Strings.toString(id));
        if (admin == address(0)) {
            _finding(string.concat("expected ", name, " is not registered"));
            return;
        }
        _reportSponsor(pool, id, pairs);
        if (admin != expectedAdmin) {
            _finding(
                string.concat(
                    name,
                    "'s admin is ",
                    Strings.toChecksumHexString(admin),
                    ", expected ",
                    Strings.toChecksumHexString(expectedAdmin)
                )
            );
        }
        // forge-lint: disable-next-line(calls-loop)
        address pending = pool.pendingSponsorAdmin(id);
        if (pending != address(0)) {
            _finding(
                string.concat(
                    name,
                    " has a pending admin handover to ",
                    Strings.toChecksumHexString(pending),
                    ": accepting moves its lists"
                )
            );
        }
        if (!enabled) _finding(string.concat(name, " is switched off: no swap under it fills"));
    }

    function _reportSponsor(IManagedDirectPropAMM pool, uint64 id, uint16 pairs) internal view {
        // forge-lint: disable-start(calls-loop)
        (address admin, bool enabled, uint32 generation) = pool.sponsor(id);
        console2.log(string.concat("Sponsor ", Strings.toString(id), ", admin ", _named(admin)));
        address pending = pool.pendingSponsorAdmin(id);
        if (pending != address(0)) console2.log(string.concat("  pending admin ", _named(pending)));
        console2.log("  enabled", enabled);
        console2.log("  generation", uint256(generation));
        string memory admitted = "";
        for (uint16 i = 0; i < pairs; ++i) {
            _requireCheckGas(i);
            if (pool.pairSponsor(i, id)) admitted = string.concat(admitted, " ", Strings.toString(i));
        }
        // forge-lint: disable-end(calls-loop)
        console2.log(string.concat("  admitted on pairs:", bytes(admitted).length == 0 ? " none" : admitted));
    }

    /// @dev Logs `takerAccess` for `account` on every live pair, under the home list and every sponsor `check` knows.
    function _reportAccount(IManagedDirectPropAMM pool, address account, uint16 pairs) internal view {
        console2.log("Account", account);
        if (_isVirtual(account)) {
            console2.log(
                "  TIP-1022 virtual address: it never calls, so no list admits it and no denial blocks it; list or"
                " deny its master"
            );
        }
        console2.log("  denied", _denied(pool, account));
        // forge-lint: disable-start(calls-loop)
        for (uint16 i = 0; i < pairs; ++i) {
            _requireCheckGas(i);
            if (pool.pair(i).access == IManagedDirectPropAMM.AccessMode.None) continue;
            string memory line =
                string.concat("  pair ", Strings.toString(i), ": home list ", _reason(pool.takerAccess(i, account, 0)));
            for (uint256 j = 0; j < _sponsorIds.length; ++j) {
                _requireCheckGas(j);
                uint64 id = _sponsorIds[j];
                line = string.concat(
                    line, ", sponsor ", Strings.toString(id), " ", _reason(pool.takerAccess(i, account, id))
                );
            }
            console2.log(line);
        }
        // forge-lint: disable-end(calls-loop)
    }

    /// @dev Replays every pool event from `FROM_BLOCK` on, in order, and checks the result against the chain: the
    /// pairs, every sponsor (flagging one that isn't expected), every admission, every list at its sponsor's current
    /// generation (a reset voids earlier listings), every denial, including ordinary router memberships. A complete
    /// reconstruction additionally requires authenticated creation: standalone initcode can seed unlogged state,
    /// which CHECK flags even when the events and views it could discover agree.
    function _checkHistory(Config memory config) internal {
        IManagedDirectPropAMM pool = config.pool;
        Replay storage r = _replay[++_replays];
        uint256 last = block.number;
        uint256 range = config.logBlockRange == 0 ? DEFAULT_LOG_BLOCK_RANGE : config.logBlockRange;
        uint256 replayed;
        // Replay values and discovered keys are copied to storage; only chunk-local allocations are reclaimed.
        uint256 checkpoint;
        assembly ("memory-safe") { checkpoint := mload(0x40) }
        for (uint256 from = config.fromBlock; from <= last; from += range) {
            _requireCheckGas(replayed);
            uint256 end = from + range - 1;
            Vm.EthGetLogs[] memory logs = _getLogs(from, end < last ? end : last, address(pool));
            for (uint256 i = 0; i < logs.length; ++i) {
                _requireCheckGas(replayed);
                if (!logs[i].removed && logs[i].topics.length != 0) _apply(r, logs[i]);
                ++replayed;
            }
            assembly ("memory-safe") { mstore(0x40, checkpoint) }
        }
        if (!r.sawDeployment) {
            _finding("FROM_BLOCK is after the pool's deployment: the replay below misses earlier events");
        }
        _checkReplayedPairs(pool, r);
        _checkReplayedSponsors(config, r);
        _checkReplayedAdmissions(pool, r);
        _checkReplayedMembers(pool, r);
        _checkReplayedDenials(pool, r);
        _checkReplayedSettler(pool, r);
    }

    /// @dev Applies one pool event to the replay. Events the access state doesn't depend on are skipped.
    function _apply(Replay storage r, Vm.EthGetLogs memory log) internal {
        bytes32 topic0 = log.topics[0];
        bytes32[] memory t = log.topics;
        if (topic0 == IManagedDirectPropAMM.OwnershipTransferred.selector) {
            // The constructor's `OwnershipTransferred(0, owner)`.
            if (t[1] == bytes32(0)) r.sawDeployment = true;
        } else if (topic0 == IManagedDirectPropAMM.PairAdded.selector) {
            ++r.pairsAdded;
        } else if (topic0 == IManagedDirectPropAMM.PairRemoved.selector) {
            r.removed[_u16(t[1])] = true;
        } else if (topic0 == IManagedDirectPropAMM.SponsorAdded.selector) {
            SponsorState storage s = _replaySponsor(r, _u64(t[1]));
            (s.admin, s.enabled, s.generation) = (_addr(t[2]), true, 1);
        } else if (topic0 == IManagedDirectPropAMM.SponsorEnabledSet.selector) {
            _replaySponsor(r, _u64(t[1])).enabled = abi.decode(log.data, (bool));
        } else if (topic0 == IManagedDirectPropAMM.SponsorAdminTransferred.selector) {
            _replaySponsor(r, _u64(t[1])).admin = _addr(t[3]);
        } else if (topic0 == IManagedDirectPropAMM.SponsorReset.selector) {
            SponsorState storage s = _replaySponsor(r, _u64(t[1]));
            (s.admin, s.generation) = (_addr(t[3]), abi.decode(log.data, (uint32)));
        } else if (topic0 == IManagedDirectPropAMM.PairSponsorSet.selector) {
            (uint16 pairIndex, uint64 id) = (_u16(t[1]), _u64(t[2]));
            bytes32 key = keccak256(abi.encode(pairIndex, id));
            AdmissionState storage a = r.admissions[key];
            // A pair admits only a registered sponsor, never 0, so a zero id marks an entry not seen yet.
            if (a.sponsorId == 0) r.admissionKeys.push(key);
            (a.pairIndex, a.sponsorId, a.admitted) = (pairIndex, id, abi.decode(log.data, (bool)));
        } else if (topic0 == IManagedDirectPropAMM.MemberUpdated.selector) {
            (uint16 pairIndex, uint64 id, address account) = (_u16(t[1]), _u64(t[2]), _addr(t[3]));
            bytes32 key = keccak256(abi.encode(pairIndex, id, account));
            MemberState storage m = r.members[key];
            if (m.account == address(0)) r.memberKeys.push(key);
            bool allowed = abi.decode(log.data, (bool));
            uint32 generation = id == 0 ? 1 : r.sponsors[id].generation;
            (m.pairIndex, m.sponsorId, m.account, m.generation) = (pairIndex, id, account, allowed ? generation : 0);
        } else if (topic0 == IManagedDirectPropAMM.SettlerSet.selector) {
            r.settler = _addr(t[1]);
            r.sawSettler = true;
        } else if (topic0 == IManagedDirectPropAMM.DenyUpdated.selector) {
            address account = _addr(t[1]);
            if (!r.denialSeen[account]) {
                r.denialSeen[account] = true;
                r.denialKeys.push(account);
            }
            r.denied[account] = abi.decode(log.data, (bool));
        }
    }

    function _replaySponsor(Replay storage r, uint64 id) internal returns (SponsorState storage s) {
        s = r.sponsors[id];
        if (!s.seen) {
            s.seen = true;
            r.sponsorIds.push(id);
        }
    }

    function _checkReplayedPairs(IManagedDirectPropAMM pool, Replay storage r) internal {
        uint16 pairs = pool.pairCount();
        if (r.pairsAdded != pairs) _finding("PairAdded events don't add up to pairCount");
        for (uint16 i = 0; i < pairs && i < r.pairsAdded; ++i) {
            _requireCheckGas(i);
            // forge-lint: disable-next-line(calls-loop)
            bool removed = pool.pair(i).access == IManagedDirectPropAMM.AccessMode.None;
            if (removed != r.removed[i]) {
                _finding(string.concat("pair ", Strings.toString(i), ": PairRemoved events disagree with the chain"));
            }
        }
    }

    /// @dev Checks each sponsor the events registered against the chain, flags one not in `EXPECTED_SPONSOR_IDS`
    /// (reporting it and adding it to the account reports), and an expected one the chain has but the events don't.
    function _checkReplayedSponsors(Config memory config, Replay storage r) internal {
        IManagedDirectPropAMM pool = config.pool;
        uint16 pairs = pool.pairCount();
        console2.log("Sponsors in events", r.sponsorIds.length);
        for (uint256 i = 0; i < r.sponsorIds.length; ++i) {
            _requireCheckGas(i);
            uint64 id = r.sponsorIds[i];
            SponsorState storage s = r.sponsors[id];
            string memory name = string.concat("sponsor ", Strings.toString(id));
            // forge-lint: disable-next-line(calls-loop)
            (address admin, bool enabled, uint32 generation) = pool.sponsor(id);
            if (admin != s.admin || enabled != s.enabled || generation != s.generation) {
                _finding(string.concat(name, ": the events disagree with the chain"));
            }
            if (!_contains(config.expectedSponsorIds, id)) {
                _finding(string.concat(name, " is registered but not in EXPECTED_SPONSOR_IDS"));
                _sponsorIds.push(id);
                _reportSponsor(pool, id, pairs);
            }
        }
        for (uint256 i = 0; i < config.expectedSponsorIds.length; ++i) {
            _requireCheckGas(i);
            uint64 id = config.expectedSponsorIds[i];
            // forge-lint: disable-next-line(calls-loop, unused-return)
            (address admin,,) = pool.sponsor(id);
            if (admin != address(0) && !r.sponsors[id].seen) {
                _finding(string.concat("sponsor ", Strings.toString(id), " has no SponsorAdded event in the range"));
            }
        }
    }

    function _checkReplayedAdmissions(IManagedDirectPropAMM pool, Replay storage r) internal {
        for (uint256 i = 0; i < r.admissionKeys.length; ++i) {
            _requireCheckGas(i);
            AdmissionState storage a = r.admissions[r.admissionKeys[i]];
            // A removal retains its admission slot but the view deliberately hides it, as it does the home list.
            bool admitted = a.admitted && !r.removed[a.pairIndex];
            // forge-lint: disable-next-line(calls-loop)
            if (pool.pairSponsor(a.pairIndex, a.sponsorId) != admitted) {
                _finding(
                    string.concat(
                        "sponsor ",
                        Strings.toString(a.sponsorId),
                        " on pair ",
                        Strings.toString(a.pairIndex),
                        ": PairSponsorSet events disagree with the chain"
                    )
                );
            }
        }
    }

    /// @dev Counts each (pair, sponsor) list's members at the sponsor's current generation, logs them, and checks each
    /// account the events name against `isMember`.
    function _checkReplayedMembers(IManagedDirectPropAMM pool, Replay storage r) internal {
        uint256 listed = 0;
        console2.log("Listings in events (pair, list, account), current generation only:");
        for (uint256 i = 0; i < r.memberKeys.length; ++i) {
            // Each listing is compared with the chain, so a long history needs gas here too.
            _requireCheckGas(i);
            MemberState storage m = r.members[r.memberKeys[i]];
            uint32 current = m.sponsorId == 0 ? 1 : r.sponsors[m.sponsorId].generation;
            // A removal retains member slots, but isMember reports false before reading either list.
            bool on = !r.removed[m.pairIndex] && m.generation != 0 && m.generation == current;
            if (on) {
                ++listed;
                console2.log(
                    string.concat(
                        "  pair ",
                        Strings.toString(m.pairIndex),
                        ", ",
                        _listName(m.sponsorId),
                        ": ",
                        Strings.toChecksumHexString(m.account)
                    )
                );
            }
            // forge-lint: disable-next-line(calls-loop)
            if (pool.isMember(m.pairIndex, m.sponsorId, m.account) != on) {
                _finding(
                    string.concat(
                        "pair ",
                        Strings.toString(m.pairIndex),
                        ", ",
                        _listName(m.sponsorId),
                        ": the events disagree with the chain for ",
                        Strings.toChecksumHexString(m.account)
                    )
                );
            }
        }
        console2.log("Listings in events", listed);
    }

    function _checkReplayedDenials(IManagedDirectPropAMM pool, Replay storage r) internal {
        uint256 denials = 0;
        for (uint256 i = 0; i < r.denialKeys.length; ++i) {
            _requireCheckGas(i);
            address account = r.denialKeys[i];
            bool on = r.denied[account];
            if (on) {
                ++denials;
                console2.log("  denied", account);
            }
            if (_denied(pool, account) != on) {
                _finding(
                    string.concat(
                        "deny list: the events disagree with the chain for ", Strings.toChecksumHexString(account)
                    )
                );
            }
        }
        console2.log("Denied accounts in events", denials);
        if (denials != pool.deniedCount()) _finding("DenyUpdated events don't add up to deniedCount");
    }

    /// @dev Older pools lack these views. Never turn a failed probe into a claim that settlement authority is absent.
    function _reportSettlement(Config memory config) internal {
        address target = address(config.pool);
        (bool factoryOk, uint256 factoryWord) = _probeWord(target, abi.encodeCall(IManagedDirectPropAMM.factory, ()));
        (bool settlerOk, uint256 settlerWord) = _probeWord(target, abi.encodeCall(IManagedDirectPropAMM.settler, ()));
        if (!factoryOk || !settlerOk || factoryWord > type(uint160).max || settlerWord > type(uint160).max) {
            _finding("Factory/settler views unavailable or malformed: routing authority could not be checked");
            return;
        }
        // Both words were checked as canonical addresses above.
        // forge-lint: disable-next-line(unsafe-typecast)
        console2.log("Factory", address(uint160(factoryWord)));
        // forge-lint: disable-next-line(unsafe-typecast)
        console2.log("Owner-chosen settler", address(uint160(settlerWord)));
        if (factoryWord != 0 && settlerWord == 0) _finding("Factory pool has no settler");
        if (settlerWord != 0 && config.fromBlock == 0) {
            _finding("Settler history not checked: set FROM_BLOCK to the pool's deployment block");
        }
        // A standalone pool (factory 0) can still be given a settler by its owner, and the default settler refuses it, so
        // any settler there is custody-trusted code nobody vouched for. A standalone pool with no settler and no
        // expected factory skips this settlement check, but CHECK still flags its unproved creation provenance.
        if (factoryWord != 0 || settlerWord != 0 || config.expectedFactory != address(0)) {
            // forge-lint: disable-next-line(unsafe-typecast)
            _checkSettlerTrust(config, address(uint160(factoryWord)), address(uint160(settlerWord)));
        }
    }

    /// @dev A factory clone's settler is custody-trusted code the owner can replace at any time, and the routing guide
    /// tells takers to refuse a pool whose `settler()` isn't the one they trust. So CHECK passes a clone only from the
    /// factory the operator expects, proven by that factory's `isPool`, with the settler takers approve. A standalone pool
    /// with a settler, or one checked against an `EXPECTED_FACTORY`, fails the same checks.
    function _checkSettlerTrust(Config memory config, address factory, address settler) internal {
        address expectedFactory = config.expectedFactory;
        if (expectedFactory == address(0)) {
            _finding("Settler not authenticated: set EXPECTED_FACTORY to the PoolFactory takers trust");
            return;
        }
        if (factory != expectedFactory) {
            _finding("Pool's factory is not EXPECTED_FACTORY");
            return;
        }
        (bool provenOk, uint256 proven) =
            _probeWord(expectedFactory, abi.encodeCall(IPoolFactory.isPool, (address(config.pool))));
        if (!provenOk || proven != 1) {
            _finding("EXPECTED_FACTORY does not prove this pool (isPool)");
            return;
        }
        address expectedSettler = config.expectedSettler;
        if (expectedSettler == address(0)) {
            (bool ok, uint256 word) = _probeWord(expectedFactory, abi.encodeCall(IPoolFactory.defaultSettler, ()));
            if (!ok || word == 0 || word > type(uint160).max) {
                _finding("EXPECTED_FACTORY's defaultSettler unavailable or malformed");
                return;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            expectedSettler = address(uint160(word));
        }
        console2.log("Trusted settler", expectedSettler);
        if (settler != expectedSettler) {
            _finding("Settler is not the trusted settler: takers following the routing guide refuse this pool");
        }
    }

    function _checkReplayedSettler(IManagedDirectPropAMM pool, Replay storage r) internal {
        (bool ok, uint256 word) = _probeWord(address(pool), abi.encodeCall(IManagedDirectPropAMM.settler, ()));
        if (!ok || word > type(uint160).max) {
            _finding("Settler view unavailable or malformed");
        } else if (word != uint256(uint160(r.settler)) || (word != 0 && !r.sawSettler)) {
            _finding("settler: the events disagree with the chain");
        }
    }

    function _finding(string memory text) internal {
        console2.log(string.concat("FINDING: ", text));
        _findings.push(text);
    }

    function _warning(string memory text) internal {
        console2.log(string.concat("WARNING: ", text));
        _warnings.push(text);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reads, probes and names
    // ---------------------------------------------------------------------------------------------------------------

    function _isMember(Config memory config, address account) internal view returns (bool) {
        // Called per account of the operator's batch.
        // forge-lint: disable-next-line(calls-loop)
        return config.pool.isMember(config.pairIndex, config.sponsorId, account);
    }

    function _onHomeList(Config memory config, address account) internal view returns (bool) {
        // Called per account of the operator's batch.
        // forge-lint: disable-next-line(calls-loop)
        return config.pool.isMember(config.pairIndex, 0, account);
    }

    function _denied(IManagedDirectPropAMM pool, address account) internal view returns (bool) {
        // Called per account of the operator's batch or of the replayed events.
        // forge-lint: disable-next-line(calls-loop)
        return pool.denied(account);
    }

    /// @dev Keep enough for a named refusal and the next bounded probe group, including both sponsor admin probes.
    function _requireCheckGas(uint256 processed) internal view {
        // Refusing the entire report is intentional: partial replay must never look like a completed check.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (gasleft() < REPLAY_GAS_RESERVE) revert ReplayNeedsMoreGas(processed);
    }

    /// @dev A static call with at most `PROBE_GAS` gas whose answer is copied only when it is at most
    /// `MAX_PROBE_ANSWER` bytes: a target that reverts, runs out of that gas or answers more reads as
    /// `success == false`, so no account the pool names can abort CHECK by burning gas or returning a huge payload.
    function _probe(address target, bytes memory data) internal view returns (bool success, bytes memory answer) {
        uint256 gasLimit = PROBE_GAS;
        uint256 size;
        assembly ("memory-safe") {
            success := staticcall(gasLimit, target, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
        }
        if (!success || size > MAX_PROBE_ANSWER) return (false, answer);
        answer = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(answer, 32), 0, size)
        }
    }

    /// @dev A raw call returning exactly one word, so a target that lacks the function or answers oddly reads as
    /// `ok == false` instead of reverting.
    function _probeWord(address target, bytes memory data) internal view returns (bool ok, uint256 word) {
        (bool success, bytes memory answer) = _probe(target, data);
        if (!success || answer.length != 32) return (false, 0);
        return (true, abi.decode(answer, (uint256)));
    }

    function _latestPrice(address oracle) internal view returns (bool ok, uint256 price, uint256 updatedAt) {
        (bool success, bytes memory answer) = _probe(oracle, abi.encodeCall(IPriceOracle.latestPrice, ()));
        if (!success || answer.length != 64) return (false, 0, 0);
        (price, updatedAt) = abi.decode(answer, (uint256, uint256));
        ok = true;
    }

    /// @dev Role descriptions are self-reported getter answers, never verification of Safe provenance, signing
    /// thresholds, owner authority or upgrade controls. Raw probes bound gas and answer size only.
    function _named(address account) internal view returns (string memory) {
        return string.concat(Strings.toChecksumHexString(account), " (", _kind(account), ")");
    }

    function _kind(address account) internal view returns (string memory) {
        if (account == address(0)) return "none";
        if (_isVirtual(account)) return "TIP-1022 virtual address: never calls";
        if (account.code.length == 0) return "no code";
        (bool hasThreshold, uint256 threshold) = _probeWord(account, abi.encodeWithSignature("getThreshold()"));
        uint256 owners = _safeOwnerCount(account);
        if (hasThreshold && owners != type(uint256).max && threshold != 0 && threshold <= owners) {
            return string.concat(
                "self-reported Safe views (unverified), ", Strings.toString(threshold), " of ", Strings.toString(owners)
            );
        }
        (bool hasOwner, uint256 ownerWord) = _probeWord(account, abi.encodeWithSignature("owner()"));
        if (hasOwner && ownerWord <= type(uint160).max) {
            // Bounded just above.
            // forge-lint: disable-next-line(unsafe-typecast)
            address ownerAddress = address(uint160(ownerWord));
            return string.concat("self-reported owner() (unverified) ", Strings.toChecksumHexString(ownerAddress));
        }
        return "contract";
    }

    /// @dev The length of a Safe's `getOwners()` answer, or `type(uint256).max` when the answer isn't one well-formed
    /// `address[]` (offset 32, then a length and that many words).
    function _safeOwnerCount(address account) internal view returns (uint256) {
        (bool success, bytes memory answer) = _probe(account, abi.encodeWithSignature("getOwners()"));
        if (!success || answer.length < 64) return type(uint256).max;
        (uint256 offset, uint256 count) = abi.decode(answer, (uint256, uint256));
        if (offset != 32 || count > 1000 || answer.length != 64 + 32 * count) return type(uint256).max;
        return count;
    }

    function _roleOf(Config memory config, address account) internal view returns (string memory) {
        IManagedDirectPropAMM pool = config.pool;
        if (account == pool.owner()) return "(owner)";
        // forge-lint: disable-next-line(unused-return)
        (address admin,,) = pool.sponsor(config.sponsorId);
        if (config.sponsorId != 0 && account == admin) return "(sponsor admin)";
        return "(no pool role)";
    }

    /// @dev Bytes 4 to 13 of `account` all `0xFD`: a TIP-1022 virtual address, which the address registry forwards and
    /// which never sends a transaction.
    function _isVirtual(address account) internal pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == 0xFDFDFDFDFDFDFDFDFDFD;
    }

    function _contains(uint64[] memory ids, uint64 id) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    function _listName(uint64 sponsorId) internal pure returns (string memory) {
        return sponsorId == 0 ? "the home list" : string.concat("sponsor ", Strings.toString(sponsorId));
    }

    function _parseMode(string memory value) internal pure returns (Mode) {
        string[17] memory names = [
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
        for (uint256 i = 0; i < names.length; ++i) {
            // `i` indexes the seventeen names, which list `Mode`'s members in order.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (Strings.equal(value, names[i])) return Mode(uint8(i));
        }
        revert InvalidConfig("MODE");
    }

    /// @dev `closed`, `listed` or `open`; empty reads `None` (unset).
    function _parseAccess(string memory value) internal pure returns (IManagedDirectPropAMM.AccessMode) {
        if (bytes(value).length == 0) return IManagedDirectPropAMM.AccessMode.None;
        if (Strings.equal(value, "closed")) return IManagedDirectPropAMM.AccessMode.Closed;
        if (Strings.equal(value, "listed")) return IManagedDirectPropAMM.AccessMode.Listed;
        if (Strings.equal(value, "open")) return IManagedDirectPropAMM.AccessMode.Open;
        revert InvalidConfig("ACCESS");
    }

    function _accessName(IManagedDirectPropAMM.AccessMode mode) internal pure returns (string memory) {
        if (mode == IManagedDirectPropAMM.AccessMode.Listed) return "Listed";
        if (mode == IManagedDirectPropAMM.AccessMode.Open) return "Open (anyone not denied may trade)";
        return mode == IManagedDirectPropAMM.AccessMode.Closed ? "Closed" : "None";
    }

    /// @dev The `TakerAccess` name, as `IManagedDirectPropAMM` spells it.
    function _reason(IManagedDirectPropAMM.TakerAccess access) internal pure returns (string memory) {
        string[9] memory names = [
            "None",
            "Allowed",
            "UnknownPair",
            "Closed",
            "Denied",
            "UnknownSponsor",
            "SponsorDisabled",
            "SponsorNotAdmitted",
            "NotListed"
        ];
        return names[uint8(access)];
    }

    function _u16(bytes32 topic) internal pure returns (uint16) {
        // An indexed `uint16` topic, as the pool emits it.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(uint256(topic));
    }

    function _u64(bytes32 topic) internal pure returns (uint64) {
        // An indexed `uint64` topic, as the pool emits it.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(uint256(topic));
    }

    function _addr(bytes32 topic) internal pure returns (address) {
        // An indexed `address` topic, as the pool emits it.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(topic)));
    }

    function _uint16(uint256 value, string memory field) internal pure returns (uint16) {
        if (value > type(uint16).max) revert InvalidConfig(field);
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    function _uint64(uint256 value, string memory field) internal pure returns (uint64) {
        // Called per entry while reading a list; one bad entry rejects them all.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (value > type(uint64).max) revert InvalidConfig(field);
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }
}
