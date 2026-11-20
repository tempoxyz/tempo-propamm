// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";

import { DeployManagedBufferHelpers } from "../../../script/managed/DeployManagedBufferHelpers.s.sol";
import { DeployManagedOracleAdapters } from "../../../script/managed/DeployManagedOracleAdapters.s.sol";
import { DeployManagedPool } from "../../../script/managed/DeployManagedPool.s.sol";
import { ManagedPoolAccess } from "../../../script/managed/ManagedPoolAccess.s.sol";
import { Chainlink18To8PriceOracleAdapter } from "../../../src/Chainlink18To8PriceOracleAdapter.sol";
import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { PoolFactory } from "../../../src/managed/PoolFactory.sol";
import { PushPriceOracle } from "../../../src/PushPriceOracle.sol";
import { TempoMainnet } from "../../../src/TempoMainnet.sol";
import { IManagedDirectPropAMM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IPriceOracle } from "../../../src/interfaces/IPriceOracle.sol";
import { ScriptFeed, ScriptUsdyWrapper } from "../utils/OracleSourceFixtures.sol";

interface ITIP20FactoryPrecompile {
    function createToken(
        string memory name,
        string memory symbol,
        string memory currency,
        address quoteToken,
        address admin,
        bytes32 salt
    ) external returns (address);
}

/// @notice What both runs need and no real deployment has: TIP-20s from the factory precompile and push oracles, made
/// in the simulation only, from a setup account that holds nothing.
abstract contract ManagedScriptFixtures is Script {
    address internal constant SETUP = 0x5E7c000000000000000000000000000000000001;
    address internal constant TIP20_FACTORY = 0x20Fc000000000000000000000000000000000000;

    function _fixtureToken(string memory symbol, uint256 salt) internal returns (address token) {
        vm.prank(SETUP);
        token = ITIP20FactoryPrecompile(TIP20_FACTORY)
            .createToken(symbol, symbol, "USD", TempoMainnet.PATH_USD, SETUP, bytes32(salt));
    }

    function _fixtureOracle(uint256 price) internal returns (address oracle) {
        vm.prank(SETUP);
        oracle = address(new PushPriceOracle(8, SETUP, SETUP, price, vm.getBlockTimestamp()));
    }
}

/// @notice CI's guard that `DeployManagedPool` runs as a Forge script, not only under `forge test`, which never applies
/// the rules Forge enforces only in `forge script` (no `address(this)` in a script contract, among others). Two pairs
/// on factory TIP-20s and pathUSD, with the precompiles `--network tempo` provides and no RPC, signer or `--broadcast`:
///
/// ```bash
/// forge script contracts/test/managed/script/ManagedPoolScriptsRun.s.sol:DeployManagedPoolRun --sig 'runWithPairs()' \
///   --network tempo --chain 42431 --sender 0x…
/// ```
///
/// On Moderato (`--chain 42431`) the sender owns the pool and the broadcast adds the pairs; on mainnet (`--chain
/// 4217`) another account owns it, so the pairs run as that owner in the simulation and print as Safe calldata.
contract DeployManagedPoolRun is DeployManagedPool, ManagedScriptFixtures {
    /// @dev Placeholder roles that hold no keys: the script never broadcasts here.
    address internal constant MAINNET_OWNER = 0x0000000000000000000000000000000000Ab0001;

    PairConfig[] internal _pairs;

    function runWithPairs() external returns (Deployment memory) {
        address prime = _fixtureToken("PRIME", 0xa1);
        address eurx = _fixtureToken("EURX", 0xa2);
        _pairs.push(PairConfig(prime, TempoMainnet.PATH_USD, _fixtureOracle(105_000_000), 1 days, 50));
        _pairs.push(PairConfig(eurx, TempoMainnet.PATH_USD, _fixtureOracle(108_500_000), 1 days, 50));
        return run();
    }

    function _readConfig() internal view override returns (Config memory config) {
        config.deployer = msg.sender;
        config.owner = block.chainid == TEMPO_MAINNET_CHAIN_ID ? MAINNET_OWNER : msg.sender;
        config.pairs = _pairs;
    }
}

/// @notice CI's guard that `ManagedPoolAccess` runs as a Forge script: one pool (made in the simulation), then a
/// sponsor's whole life, lists, a denial and the pair's modes, each mode as an operator runs it, from its default
/// sender or the owner, and a `CHECK` that must report only unproved standalone creation:
///
/// ```bash
/// forge script contracts/test/managed/script/ManagedPoolScriptsRun.s.sol:ManagedPoolAccessRun --sig 'runModes()' \
///   --network tempo --chain 42431 --sender 0x…
/// ```
contract ManagedPoolAccessRun is ManagedPoolAccess, ManagedScriptFixtures {
    address internal constant OWNER = 0x0000000000000000000000000000000000aB0011;
    address internal constant SPONSOR_ADMIN = 0x0000000000000000000000000000000000ab0013;
    address internal constant NEXT_SPONSOR_ADMIN = 0x0000000000000000000000000000000000aB0014;
    address internal constant ALICE = 0x0000000000000000000000000000000000Ab0021;
    address internal constant BOB = 0x0000000000000000000000000000000000aB0022;
    address internal constant CAROL = 0x0000000000000000000000000000000000Ab0023;
    uint64 internal constant SPONSOR = 7;

    IManagedDirectPropAMM internal _pool;
    Vm.Log[] internal _cleanupHistory;

    function runModes() external {
        address prime = _fixtureToken("PRIME", 0xb1);
        address oracle = _fixtureOracle(105_000_000);
        vm.roll(1);
        vm.recordLogs();
        vm.startPrank(OWNER);
        ManagedDirectPropAMM pool = new ManagedDirectPropAMM(OWNER, address(0));
        pool.addPair(prime, TempoMainnet.PATH_USD, IPriceOracle(oracle), 1 days, 50);
        pool.unpause();
        vm.stopPrank();
        _pool = IManagedDirectPropAMM(address(pool));

        Config memory c = _sponsorConfig(Mode.ADD_SPONSOR, SPONSOR_ADMIN);
        _run(c);
        c = _pairConfig(Mode.ADMIT);
        c.sponsorId = SPONSOR;
        _run(c);
        c = _pairConfig(Mode.LIST);
        c.sponsorId = SPONSOR;
        c.accounts = _one(ALICE);
        _run(c);
        c = _pairConfig(Mode.LIST);
        c.accounts = _one(BOB);
        _run(c);
        c = _config(Mode.DENY);
        c.accounts = _one(CAROL);
        c.caller = OWNER;
        _run(c);
        c = _pairConfig(Mode.PAIR_ACCESS);
        c.access = IManagedDirectPropAMM.AccessMode.Listed;
        _run(c);
        c = _pairConfig(Mode.CLOSE_PAIR);
        c.caller = OWNER;
        _run(c);
        c = _pairConfig(Mode.PAIR_ACCESS);
        c.access = IManagedDirectPropAMM.AccessMode.Listed;
        _run(c);
        _run(_sponsorConfig(Mode.TRANSFER_SPONSOR_ADMIN, NEXT_SPONSOR_ADMIN));
        _run(_sponsorConfig(Mode.ACCEPT_SPONSOR_ADMIN, address(0)));

        c = _config(Mode.CHECK);
        c.expectedSponsorIds = new uint64[](1);
        c.expectedSponsorIds[0] = SPONSOR;
        c.expectedSponsorAdmins = _one(NEXT_SPONSOR_ADMIN);
        c.accounts = new address[](3);
        (c.accounts[0], c.accounts[1], c.accounts[2]) = (ALICE, BOB, CAROL);
        string[] memory findings = check(c);
        if (
            findings.length != 1
                || keccak256(bytes(findings[0]))
                    != keccak256(
                        bytes(
                            "Standalone creation provenance not authenticated: initial access state may be absent from events"
                        )
                    )
        ) revert UnexpectedState("standalone provenance finding");
        if (!_pool.takerAllowed(0, ALICE, SPONSOR) || !_pool.takerAllowed(0, BOB, 0) || _pool.takerAllowed(0, CAROL, 0))
        {
            revert UnexpectedState("access after the run");
        }
        // Exercise removed-pair cleanup with mined-identity events from the same simulation, never a live chain.
        c = _pairConfig(Mode.DELIST);
        c.fromBlock = 1;
        c.accounts = _one(BOB);
        vm.prank(OWNER);
        pool.removePair(0);
        Vm.Log[] memory history = vm.getRecordedLogs();
        for (uint256 i; i < history.length; ++i) {
            if (history[i].emitter == address(pool)) _cleanupHistory.push(history[i]);
        }
        _run(c);
        c.accounts = _one(ALICE);
        c.sponsorId = SPONSOR;
        _run(c);
        c.mode = Mode.UNADMIT;
        c.accounts = new address[](0);
        c.caller = OWNER;
        _run(c);
        _run(c); // Repeated cleanup remains explicit and grants no access.
        if (_cleanupQueries != 12 || _cleanupHeaders != 16) revert UnexpectedState("cleanup replay count");
        if (pool.takerAllowed(0, ALICE, SPONSOR) || pool.takerAllowed(0, BOB, 0)) {
            revert UnexpectedState("removed pair access");
        }
    }

    uint256 internal _cleanupQueries;
    uint256 internal _cleanupHeaders;

    function _canonicalBlockHash(uint256 number) internal override returns (bytes32) {
        ++_cleanupHeaders;
        return keccak256(abi.encode(number));
    }

    function _getIdentityLogs(uint256 fromBlock, uint256 toBlock, address emitter, bytes32 kind, uint16 pairIndex)
        internal
        override
        returns (Vm.EthGetLogs[] memory logs)
    {
        ++_cleanupQueries;
        if (fromBlock > 1 || toBlock < 1) return new Vm.EthGetLogs[](0);
        uint256 count;
        for (uint256 i; i < _cleanupHistory.length; ++i) {
            Vm.Log storage entry = _cleanupHistory[i];
            if (
                entry.emitter == emitter && entry.topics.length >= 2 && entry.topics[0] == kind
                    && entry.topics[1] == bytes32(uint256(pairIndex))
            ) ++count;
        }
        logs = new Vm.EthGetLogs[](count);
        uint256 n;
        for (uint256 i; i < _cleanupHistory.length; ++i) {
            Vm.Log storage entry = _cleanupHistory[i];
            if (
                entry.emitter != emitter || entry.topics.length < 2 || entry.topics[0] != kind
                    || entry.topics[1] != bytes32(uint256(pairIndex))
            ) continue;
            logs[n].emitter = entry.emitter;
            logs[n].topics = entry.topics;
            logs[n].data = entry.data;
            logs[n].blockNumber = 1;
            logs[n].blockHash = keccak256(abi.encode(uint256(1)));
            logs[n].logIndex = i;
            logs[n].transactionHash = keccak256(abi.encode(i));
            ++n;
        }
    }

    function _config(Mode mode) internal view returns (Config memory c) {
        c.pool = _pool;
        c.mode = mode;
    }

    function _pairConfig(Mode mode) internal view returns (Config memory c) {
        c = _config(mode);
        c.hasPairIndex = true;
        c.expectedBase = _pool.pair(0).base;
        c.expectedQuote = _pool.pair(0).quote;
        c.expectedOracle = address(_pool.pair(0).oracle);
    }

    function _sponsorConfig(Mode mode, address admin) internal view returns (Config memory c) {
        c = _config(mode);
        c.sponsorId = SPONSOR;
        c.sponsorAdmin = admin;
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}

/// @notice Simulates CHECK's authoritative event replay for ordinary home/sponsor router memberships,
/// ownership handoff and revocation. No RPC or broadcast is used.
contract ManagedPoolRouterReplayRun is ManagedPoolAccess, ManagedScriptFixtures {
    address internal constant OWNER = 0x0000000000000000000000000000000000aB0011;
    address internal constant NEXT_OWNER = 0x0000000000000000000000000000000000aB0014;
    address internal constant SPONSOR_ADMIN = 0x0000000000000000000000000000000000ab0013;
    uint64 internal constant SPONSOR = 7;
    Vm.Log[] internal _history;

    function runReplay() external {
        vm.roll(1);
        uint256 fromBlock = block.number;
        address prime = _fixtureToken("PRIME", 0xc1);
        address oracle = _fixtureOracle(105_000_000);
        PoolFactory factory = new PoolFactory();
        // Router code is irrelevant to membership; CHECK never invokes router methods.
        address router = address(new PushPriceOracle(8, OWNER, OWNER, 100_000_000, block.timestamp));
        address[] memory accounts = new address[](1);
        accounts[0] = router;
        vm.recordLogs();
        IManagedDirectPropAMM pool = IManagedDirectPropAMM(factory.createPool(OWNER, bytes32(0)));
        vm.startPrank(OWNER);
        pool.addPair(prime, TempoMainnet.PATH_USD, IPriceOracle(oracle), 1 days, 50);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        pool.setMembers(0, 0, accounts, true);
        pool.setMembers(0, 0, accounts, true);
        pool.addSponsor(SPONSOR, SPONSOR_ADMIN);
        pool.setPairSponsor(0, SPONSOR, true);
        pool.transferOwnership(NEXT_OWNER);
        vm.stopPrank();
        vm.prank(SPONSOR_ADMIN);
        pool.setMembers(0, SPONSOR, accounts, true);
        vm.prank(NEXT_OWNER);
        pool.acceptOwnership();
        _saveLogs();
        Config memory c;
        c.pool = pool;
        c.fromBlock = fromBlock;
        c.expectedFactory = address(factory);
        c.expectedSponsorIds = new uint64[](1);
        c.expectedSponsorIds[0] = SPONSOR;
        c.expectedSponsorAdmins = new address[](1);
        c.expectedSponsorAdmins[0] = SPONSOR_ADMIN;
        c.accounts = accounts;
        _run(c);
        if (!pool.takerAllowed(0, router, 0) || !pool.takerAllowed(0, router, SPONSOR)) {
            revert UnexpectedState("router memberships after ownership handoff");
        }

        vm.recordLogs();
        vm.prank(NEXT_OWNER);
        pool.setMembers(0, 0, accounts, false);
        _saveLogs();
        _run(c);
        if (pool.takerAllowed(0, router, 0) || !pool.takerAllowed(0, router, SPONSOR)) {
            revert UnexpectedState("home membership revoked independently");
        }
        vm.recordLogs();
        vm.prank(SPONSOR_ADMIN);
        pool.setMembers(0, SPONSOR, accounts, false);
        _saveLogs();
        _run(c);
        if (pool.takerAllowed(0, router, SPONSOR)) revert UnexpectedState("sponsor membership revoked");
    }

    function _saveLogs() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            _history.push(logs[i]);
        }
    }

    function _getLogs(uint256 fromBlock, uint256 toBlock, address emitter)
        internal
        view
        override
        returns (Vm.EthGetLogs[] memory logs)
    {
        // All fixture events occur in this simulation's single block. Filter by emitter just like eth_getLogs.
        if (block.number < fromBlock || block.number > toBlock) return new Vm.EthGetLogs[](0);
        uint256 count;
        for (uint256 i; i < _history.length; ++i) {
            if (_history[i].emitter == emitter) ++count;
        }
        logs = new Vm.EthGetLogs[](count);
        uint256 n;
        for (uint256 i; i < _history.length; ++i) {
            Vm.Log storage entry = _history[i];
            if (entry.emitter != emitter) continue;
            logs[n].emitter = entry.emitter;
            logs[n].topics = entry.topics;
            logs[n].data = entry.data;
            logs[n].blockNumber = 1;
            logs[n].logIndex = i;
            ++n;
        }
    }
}

/// @notice CI's guard that `DeployManagedOracleAdapters` runs as a Forge script: one adapter of each kind over a feed
/// and a wrapper made in the simulation, the 8-decimal one held to an existing adapter of the same feed, then
/// `verify` over the adapters the run made. On mainnet
/// the wrapper's code sits at Ondo's canonical address, the only USDY source the script takes there:
///
/// ```bash
/// forge script contracts/test/managed/script/ManagedPoolScriptsRun.s.sol:DeployManagedOracleAdaptersRun \
///   --sig 'runAdapters()' --network tempo --chain 4217 --sender 0x…
/// ```
contract DeployManagedOracleAdaptersRun is DeployManagedOracleAdapters, ManagedScriptFixtures {
    string internal constant DESCRIPTION = "PRIME / USD";

    AdapterConfig[] internal _adapters;
    address[] internal _mined;

    function runAdapters() external returns (address[] memory adapters) {
        vm.startPrank(SETUP);
        ScriptFeed feed = new ScriptFeed(18, DESCRIPTION, 1_052_345_678_912_345_678, vm.getBlockTimestamp());
        address replaced = address(new Chainlink18To8PriceOracleAdapter(feed));
        address wrapper = address(new ScriptUsdyWrapper());
        vm.stopPrank();
        if (block.chainid == TEMPO_MAINNET_CHAIN_ID) {
            vm.etch(TempoMainnet.USDY_ORACLE_WRAPPER, wrapper.code);
            wrapper = TempoMainnet.USDY_ORACLE_WRAPPER;
        }
        _adapters.push(AdapterConfig(Kind.Chainlink, address(feed), DESCRIPTION, 18, 1 days, replaced));
        _adapters.push(AdapterConfig(Kind.Chainlink18To8, address(feed), DESCRIPTION, 8, 1 days, replaced));
        _adapters.push(AdapterConfig(Kind.OndoUsdy, wrapper, "-", 18, 1 hours, address(0)));
        adapters = run();
        if (adapters.length != 3) revert UnexpectedDeploymentState("adapter count");
        // `verify` holds the adapters the run made to the same inputs, as it does the mined ones after inclusion.
        _mined = adapters;
        if (verify().length != 3) revert UnexpectedDeploymentState("verified count");
    }

    function _readConfig() internal view override returns (Config memory config) {
        config.deployer = msg.sender;
        config.adapters = _adapters;
    }

    function _readAdapters() internal view override returns (address[] memory) {
        return _mined;
    }
}

/// @dev A contract account standing in for a BoringVault: the helper script only needs it to have code.
contract FixtureVault {
    function name() external pure returns (string memory) {
        return "vault";
    }
}

/// @dev A Veda Teller as the helper script reads it: the BoringVault it serves and its Accountant.
contract FixtureTeller {
    address public vault;
    address public accountant = address(0xACC0);

    constructor(address vault_) {
        vault = vault_;
    }
}

/// @notice CI's guard that `DeployManagedBufferHelpers` runs as a Forge script: one pool and pair (made in the
/// simulation) that admits a vault, then the vault's helper, which must deploy without a warning:
///
/// ```bash
/// forge script contracts/test/managed/script/ManagedPoolScriptsRun.s.sol:DeployManagedBufferHelpersRun \
///   --sig 'runHelpers()' --network tempo --chain 42431 --sender 0x…
/// ```
contract DeployManagedBufferHelpersRun is DeployManagedBufferHelpers, ManagedScriptFixtures {
    address internal constant OWNER = 0x0000000000000000000000000000000000ab0031;

    IManagedDirectPropAMM internal _pool;
    HelperConfig[] internal _helpers;

    function runHelpers() external returns (address[] memory helpers) {
        address prime = _fixtureToken("PRIME", 0xc1);
        address oracle = _fixtureOracle(105_000_000);
        address[] memory vaults = new address[](1);
        vm.startPrank(OWNER);
        vaults[0] = address(new FixtureVault());
        address teller = address(new FixtureTeller(vaults[0]));
        ManagedDirectPropAMM pool = new ManagedDirectPropAMM(OWNER, address(0));
        pool.addPair(prime, TempoMainnet.PATH_USD, IPriceOracle(oracle), 1 days, 50);
        pool.setMembers(0, 0, vaults, true);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        // A pool deploys paused, which the helper script warns about.
        pool.unpause();
        vm.stopPrank();
        _pool = IManagedDirectPropAMM(address(pool));
        _helpers.push(
            HelperConfig({
                vault: vaults[0],
                teller: teller,
                pairIndex: 0,
                expectedBase: prime,
                expectedQuote: TempoMainnet.PATH_USD,
                expectedOracle: oracle,
                sponsorId: 0,
                customerId: keccak256("ci"),
                slippageBps: 50,
                replaced: address(0)
            })
        );
        helpers = run();
        if (helpers.length != 1 || _warnings.length != 0) revert UnexpectedDeploymentState("helpers or warnings");
    }

    function _readConfig() internal view override returns (Config memory config) {
        config.deployer = msg.sender;
        config.pool = _pool;
        config.helpers = _helpers;
    }
}
