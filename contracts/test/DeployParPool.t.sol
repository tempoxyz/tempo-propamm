// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";

import { DeployParPool, ITIP20TransferPolicy } from "../script/DeployParPool.s.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { DirectPropAMMRebalanceController } from "../src/DirectPropAMMRebalanceController.sol";
import { PushPriceOracle } from "../src/PushPriceOracle.sol";
import { TempoMainnet } from "../src/TempoMainnet.sol";
import { IAddressRegistry } from "../src/interfaces/IAddressRegistry.sol";
import { ITIP20 } from "../src/interfaces/ITIP20.sol";
import { ITIP403Registry } from "../src/interfaces/ITIP403Registry.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";
import { MockTIP403Registry } from "./v2/mocks/MockTIP403Registry.sol";

/// @dev EVM storage is isolated per test; process environment variables are not.
contract DeployParPoolHarness is DeployParPool {
    Config internal config;
    Vm.EthGetLogs[] internal _logs;
    bool internal failLogs;
    mapping(bytes32 => string) internal rpcResponses;

    bool internal interleave;

    function checkAncestry(uint256 height, bytes32 hash) external {
        _checkCreationAncestry(height, hash);
    }

    function checkAncestryMemory(uint256 height, bytes32 hash) external returns (uint256 growth) {
        // A caller-owned allocation must survive reclamation, including subsequent allocations.
        bytes memory sentinel = abi.encodePacked(hash, height, "caller-owned memory");
        bytes32 digest = keccak256(sentinel);
        uint256 before;
        assembly ("memory-safe") {
            before := mload(0x40)
        }
        _checkCreationAncestry(height, hash);
        assembly ("memory-safe") {
            growth := sub(mload(0x40), before)
        }
        bytes memory allocatedAfter = abi.encodePacked(height, hash, "reuse reclaimed memory");
        require(keccak256(sentinel) == digest, "caller memory corrupted");
        require(keccak256(allocatedAfter) == keccak256(abi.encodePacked(height, hash, "reuse reclaimed memory")));
    }

    function checkHistory(DirectPropAMM pool, uint256 height) external view {
        _checkPermissionHistory(pool, height);
    }

    function setInterleave() external {
        interleave = true;
    }

    function _initializeAnchors(DirectPropAMM pool) internal override {
        if (interleave) {
            // Exit the deployer's broadcast to model separately mined production-role transactions.
            vm.stopBroadcast();
            vm.warp(block.timestamp + 10);
            PushPriceOracle oracle = PushPriceOracle(address(pool.oracle()));
            vm.prank(config.oracleReporter);
            vm.expectRevert(PushPriceOracle.NotReporter.selector);
            oracle.pushPrice(105_000_000, block.timestamp);
            if (config.oracleOwner != config.deployer) {
                vm.prank(config.oracleOwner);
                vm.expectRevert(PushPriceOracle.NotOwner.selector);
                oracle.setReporter(config.oracleOwner);
                vm.prank(config.oracleOwner);
                vm.expectRevert(PushPriceOracle.NotPendingOwner.selector);
                oracle.acceptOwnership();
                vm.prank(config.oracleOwner);
                vm.expectRevert(PushPriceOracle.NotOwner.selector);
                oracle.transferOwnership(config.oracleOwner);
            }
            vm.startBroadcast(config.deployer);
        }
        super._initializeAnchors(pool);
    }

    function setRpcResponse(string calldata method, string calldata params, string calldata response) external {
        rpcResponses[keccak256(abi.encode(method, params))] = response;
    }

    function _rpc(string memory method, string memory params) internal view virtual override returns (string memory) {
        string memory response = rpcResponses[keccak256(abi.encode(method, params))];
        require(bytes(response).length != 0, "missing RPC fixture");
        return response;
    }

    function setFailLogs() external {
        failLogs = true;
    }

    function addLogs(Vm.Log[] calldata logs, uint64 blockNumber, bool removed) external {
        for (uint256 i; i < logs.length; ++i) {
            Vm.EthGetLogs storage entry = _logs.push();
            entry.emitter = logs[i].emitter;
            entry.topics = logs[i].topics;
            entry.data = logs[i].data;
            entry.blockNumber = blockNumber;
            entry.removed = removed;
        }
    }

    function _getLogs(uint256 fromBlock, uint256 toBlock, address emitter)
        internal
        view
        override
        returns (Vm.EthGetLogs[] memory logs)
    {
        require(!failLogs, "RPC unavailable");
        require(toBlock >= fromBlock && toBlock - fromBlock < 100_000, "query exceeds max block range");
        uint256 count;
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == emitter && _logs[i].blockNumber >= fromBlock && _logs[i].blockNumber <= toBlock) {
                ++count;
            }
        }
        logs = new Vm.EthGetLogs[](count);
        uint256 n;
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == emitter && _logs[i].blockNumber >= fromBlock && _logs[i].blockNumber <= toBlock) {
                logs[n++] = _logs[i];
            }
        }
    }

    function checkPostconditions(Deployment memory deployed, Config memory config_) external view {
        (, uint256 updatedAt) = deployed.oracle.latestPrice();
        Expected memory expected = Expected({
            tokenDecimals: deployed.pool.baseDecimals(),
            guardian: deployed.pool.guardian(),
            maxOracleAge: deployed.pool.maxOracleAge(),
            maxPriceDeviationBps: deployed.pool.maxPriceDeviationBps(),
            baseInventory: ITIP20(config_.baseToken).balanceOf(address(deployed.pool)),
            quoteInventory: ITIP20(config_.quoteToken).balanceOf(address(deployed.pool)),
            oracleUpdatedAt: updatedAt
        });
        _checkPool(deployed, config_, expected, false);
    }

    function setConfig(Config memory config_) external {
        config = config_;
    }

    function _readConfig() internal view override returns (Config memory) {
        return config;
    }
}

/// @dev Observe allocations inside the real loop, not only the pointer after it returns.
contract DeployParPoolMemoryHarness is DeployParPoolHarness {
    function _rpc(string memory method, string memory params) internal view override returns (string memory) {
        uint256 pointer;
        assembly ("memory-safe") {
            pointer := mload(0x40)
        }
        require(pointer < 8192, "ancestry loop memory exceeds fixed budget");
        return super._rpc(method, params);
    }
}

/// @dev A constructor may write mappings without emitting their permission events, then return
/// byte-for-byte genuine runtime (including metadata and immutable values). Runtime identity does not prove state.
contract HiddenPermissionParPool {
    // DirectPropAMM's storage order, omitting its immutables. An explicit return from a derived constructor
    // triggers solc's immutable-initialization diagnostic, so this adversarial initcode seeds storage itself.
    address internal oracle;
    uint16 internal maxPriceDeviationBps;
    uint80 internal maxOracleAge;
    uint256 internal baseToQuotePriceAnchor;
    uint256 internal quoteToBasePriceAnchor;
    address internal owner;
    address internal pendingOwner;
    address internal guardian;
    bool internal paused;
    mapping(address => bool) internal takerAllowed;
    mapping(address => bool) internal recipientAllowed;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(DirectPropAMM referencePool, address hidden) {
        oracle = address(referencePool.oracle());
        maxPriceDeviationBps = uint16(referencePool.maxPriceDeviationBps());
        maxOracleAge = uint80(referencePool.maxOracleAge());
        owner = referencePool.owner();
        guardian = referencePool.guardian();
        paused = true;
        emit OwnershipTransferred(address(0), owner);
        takerAllowed[hidden] = true;
        recipientAllowed[hidden] = true;
        bytes memory runtime = address(referencePool).code;
        assembly ("memory-safe") {
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

contract DeployParPoolTest is Test {
    // via_ir may re-read block.timestamp after a warp, so timestamps derive from this constant.
    uint256 internal constant DEPLOYED_AT = 1_800_000_000;
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PAR = 1e8;
    uint256 internal constant SEED = 10 * UNIT;
    uint64 internal constant BLACKLIST_POLICY = 2;
    bytes32 internal constant CREATION_TX = keccak256("pool creation transaction");
    bytes32 internal constant CREATION_BLOCK_HASH = keccak256("canonical creation block");
    // Raw JSON values, with empty strings representing missing fields. All fixtures are per-test EVM state.
    string[12] internal creationTransaction;
    string[12] internal creationReceipt;
    uint256 internal creationBlock;
    bytes32 internal constant CUSTOMER_ID = keccak256("customer");

    DeployParPoolHarness internal deploymentScript;
    MockTIP403Registry internal tip403 = MockTIP403Registry(TempoMainnet.TIP403_REGISTRY);
    MockTIP20 internal base;
    MockTIP20 internal quote;

    address internal deployer = makeAddr("deployer");
    address internal controllerOwner = makeAddr("controllerOwner");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal baseLiquidation = makeAddr("baseLiquidationAddress");
    address internal quoteLiquidation = makeAddr("quoteLiquidationAddress");
    address internal oracleOwner = makeAddr("oracleOwner");
    address internal reporter = makeAddr("reporter");
    address internal router = makeAddr("earnRouter");

    function setUp() external {
        vm.chainId(TempoMainnet.CHAIN_ID);
        vm.warp(DEPLOYED_AT);
        vm.etch(TempoMainnet.ADDRESS_REGISTRY, address(new MockAddressRegistry()).code);
        base = _newToken("BASE", 6);
        quote = _newToken("QUOTE", 6);

        // Policy 2 is both tokens' blacklist; the etched registry starts with no storage, so seed its id counter.
        vm.etch(TempoMainnet.TIP403_REGISTRY, address(new MockTIP403Registry()).code);
        vm.store(TempoMainnet.TIP403_REGISTRY, bytes32(0), bytes32(uint256(2)));
        assertEq(tip403.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST), BLACKLIST_POLICY);

        base.mint(deployer, 100 * UNIT);
        quote.mint(deployer, 100 * UNIT);
        deploymentScript = new DeployParPoolHarness();
        deploymentScript.setConfig(_config(deployer));
    }

    function test_allRejectsExternalOracleOwnerBeforeBroadcast() external {
        DeployParPool.Config memory config = _config(deployer);
        config.oracleOwner = oracleOwner;
        _reject(config, "external oracle owner requires STAGE=pool then acceptance");
    }

    function test_controllerRequiresAcceptedOracleRoles() external {
        deploymentScript.setConfig(_poolConfig());
        vm.recordLogs();
        DeployParPool.Deployment memory staged = deploymentScript.run();
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        _creationFixture(staged.pool, vm.getNonce(deployer) - 1, _canonicalInput(staged.pool));
        _rejectPool(address(staged.pool), "oracle roles");
        // The bootstrap owner can overwrite both the nomination and reporter until acceptance.
        vm.prank(deployer);
        staged.oracle.transferOwnership(reporter);
        _rejectPool(address(staged.pool), "oracle roles");
    }

    function test_controllerRejectsOracleRoleMismatchAndPendingNomination() external {
        DeployParPool.Deployment memory staged = _deployPoolStage();
        DeployParPool.Config memory config = _controllerConfig(address(staged.pool), deployer);
        config.oracleOwner = deployer;
        _rejectPool(config, "oracle roles");
        config = _controllerConfig(address(staged.pool), deployer);
        config.oracleReporter = deployer;
        _rejectPool(config, "oracle roles");
        vm.prank(oracleOwner);
        staged.oracle.transferOwnership(reporter);
        _rejectPool(address(staged.pool), "oracle roles");
    }

    function test_controllerPostconditionsRecheckOracleRoles() external {
        DeployParPool.Deployment memory staged = _deployPoolStage();
        DeployParPool.Config memory config = _controllerConfig(address(staged.pool), deployer);
        deploymentScript.setConfig(config);
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        deploymentScript.checkPostconditions(deployed, config);
        config.oracleOwner = deployer;
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedDeploymentState.selector, "oracle roles"));
        deploymentScript.checkPostconditions(deployed, config);
        config.oracleOwner = oracleOwner;
        vm.prank(oracleOwner);
        deployed.oracle.setReporter(deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedDeploymentState.selector, "oracle roles"));
        deploymentScript.checkPostconditions(deployed, config);
        vm.startPrank(oracleOwner);
        deployed.oracle.setReporter(reporter);
        deployed.oracle.transferOwnership(reporter);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedDeploymentState.selector, "oracle roles"));
        deploymentScript.checkPostconditions(deployed, config);
    }

    function test_controllerRejectsMissingOracleRoleInputs() external {
        DeployParPool.Deployment memory staged = _deployPoolStage();
        DeployParPool.Config memory config = _controllerConfig(address(staged.pool), deployer);
        config.oracleOwner = address(0);
        deploymentScript.setConfig(config);
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, "ORACLE_OWNER_ADDRESS"));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
        config.oracleOwner = oracleOwner;
        config.oracleReporter = address(0);
        deploymentScript.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, "ORACLE_REPORTER_ADDRESS"));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
    }

    function test_controllerStageRejectsPriorUnknownPermissions() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        address stranger = makeAddr("prior-router");
        vm.recordLogs();
        vm.startPrank(deployer);
        deployed.pool.setTakerAllowed(stranger, true);
        deployed.pool.setRecipientAllowed(stranger, true);
        vm.stopPrank();
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        _rejectPool(address(deployed.pool), "existing permissions");
    }

    function test_controllerStageRejectsPriorTakerOnly() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        vm.recordLogs();
        vm.prank(deployer);
        deployed.pool.setTakerAllowed(makeAddr("prior-taker"), true);
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        _rejectPool(address(deployed.pool), "existing permissions");
    }

    function test_controllerStageRejectsPriorRecipientOnlyAcrossLogPages() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        vm.roll(creationBlock + 200_000);
        vm.recordLogs();
        vm.prank(deployer);
        deployed.pool.setRecipientAllowed(makeAddr("prior-recipient"), true);
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "existing permissions"));
        deploymentScript.checkHistory(deployed.pool, creationBlock);
    }

    function test_controllerStageAcceptsRevokedPermissions() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        address stranger = makeAddr("revoked-router");
        vm.recordLogs();
        vm.startPrank(deployer);
        deployed.pool.setTakerAllowed(stranger, true);
        deployed.pool.setRecipientAllowed(stranger, true);
        deployed.pool.setTakerAllowed(stranger, false);
        deployed.pool.setRecipientAllowed(stranger, false);
        vm.stopPrank();
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        deploymentScript.setConfig(_controllerConfig(address(deployed.pool), deployer));
        DeployParPool.Deployment memory handover = deploymentScript.run();
        assertTrue(handover.ownershipAccepted);
        assertFalse(deployed.pool.takerAllowed(stranger));
        assertFalse(deployed.pool.recipientAllowed(stranger));
    }

    function test_controllerStageRejectsHistoryStartingAfterDeployment() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        vm.roll(creationBlock + 1);
        DeployParPool.Config memory config = _controllerConfig(address(deployed.pool), deployer);
        config.poolDeploymentBlock = block.number;
        _rejectPool(config, "creation block");
    }

    function test_controllerStageRejectsFutureDeploymentBlock() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        DeployParPool.Config memory config = _controllerConfig(address(deployed.pool), deployer);
        config.poolDeploymentBlock = block.number + 1;
        deploymentScript.setConfig(config);
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, "POOL_DEPLOYMENT_BLOCK"));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(deployed.pool.owner(), deployer);
        assertEq(deployed.pool.pendingOwner(), address(0));
    }

    function test_controllerStageRejectsUnavailableLogs() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        deploymentScript.setFailLogs();
        deploymentScript.setConfig(_controllerConfig(address(deployed.pool), deployer));
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert("RPC unavailable");
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(deployed.pool.owner(), deployer);
        assertEq(deployed.pool.pendingOwner(), address(0));
    }

    function test_controllerStageRejectsRemovedDeploymentLog() external {
        // Store only a removed constructor event, not an authoritative deployment history.
        deploymentScript.setConfig(_poolConfig());
        vm.recordLogs();
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), true);
        vm.prank(oracleOwner);
        deployed.oracle.acceptOwnership();
        _creationFixture(deployed.pool, vm.getNonce(deployer) - 1, _canonicalInput(deployed.pool));
        _rejectPool(address(deployed.pool), "incomplete permission history");
    }

    function test_controllerStageRejectsConstructorHiddenPermissionsWithGenuineRuntime() external {
        DirectPropAMM genuine = _deployPoolStage().pool;
        uint64 nonce = vm.getNonce(deployer);
        vm.recordLogs();
        vm.prank(deployer);
        DirectPropAMM malicious = DirectPropAMM(address(new HiddenPermissionParPool(genuine, router)));
        vm.prank(deployer);
        malicious.unpause();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("TakerPermissionUpdated(address,bool)"));
            assertTrue(logs[i].topics[0] != keccak256("RecipientPermissionUpdated(address,bool)"));
        }
        deploymentScript.addLogs(logs, uint64(block.number), false);
        assertEq(address(malicious).code, address(genuine).code);
        assertTrue(malicious.takerAllowed(router));
        assertTrue(malicious.recipientAllowed(router));
        assertFalse(genuine.takerAllowed(router));
        assertFalse(genuine.recipientAllowed(router));

        // The hidden permissions really authorize a swap, not just getters on a lookalike contract.
        quote.mint(address(malicious), UNIT);
        _approveAndMint(router, malicious);
        assertEq(_swapAtPar(malicious, true, UNIT), UNIT);
        bytes memory maliciousInput =
            bytes.concat(type(HiddenPermissionParPool).creationCode, abi.encode(genuine, router));
        _creationFixture(malicious, nonce, maliciousInput);
        _rejectPool(address(malicious), "creation input");
    }

    function test_controllerStageRequiresCreationTransactionHash() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        DeployParPool.Config memory config = _controllerConfig(address(pool), deployer);
        config.poolCreationTx = bytes32(0);
        deploymentScript.setConfig(config);
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, "POOL_CREATION_TX"));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(pool.owner(), deployer);
        assertEq(pool.pendingOwner(), address(0));
    }

    function test_controllerStageAcceptsLegacyCreation() external {
        _acceptCreationEnvelope('"0x0"');
    }

    function test_controllerStageAcceptsAccessListCreation() external {
        _acceptCreationEnvelope('"0x1"');
    }

    function test_controllerStageAcceptsDynamicFeeCreation() external {
        _acceptCreationEnvelope('"0x2"');
    }

    function test_controllerStageAcceptsSingleProtocolNonceTempoCreation() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        _tempoFixture(pool);
        deploymentScript.setConfig(_controllerConfig(address(pool), deployer));
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertTrue(deployed.ownershipAccepted);
        assertEq(pool.owner(), address(deployed.controller));
    }

    function test_controllerStageRejectsWrongCreationTransactionFields() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        string[9] memory fields =
            ["hash", "from", "nonce", "to", "value", "chainId", "type", "blockHash", "blockNumber"];
        string[9] memory values = [
            _q(vm.toString(bytes32(uint256(123)))),
            _q(vm.toString(router)),
            '"0xffff"',
            _q(vm.toString(address(pool))),
            '"0x1"',
            '"0x1"',
            '"0x4"',
            _q(vm.toString(bytes32(uint256(123)))),
            _q(_quantity(creationBlock + 1))
        ];
        for (uint256 i; i < fields.length; ++i) {
            _setTransaction(_transaction(fields[i], values[i]));
            _rejectPool(address(pool), i >= 7 ? "creation block" : "creation transaction");
        }
    }

    function test_controllerStageRejectsFailedOrWrongCreationReceipt() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        string[7] memory fields =
            ["transactionHash", "contractAddress", "from", "to", "status", "blockHash", "blockNumber"];
        string[7] memory values = [
            _q(vm.toString(bytes32(uint256(123)))),
            _q(vm.toString(router)),
            _q(vm.toString(router)),
            _q(vm.toString(address(pool))),
            '"0x0"',
            _q(vm.toString(bytes32(0))),
            _q(_quantity(creationBlock + 1))
        ];
        for (uint256 i; i < fields.length; ++i) {
            _setReceipt(_receipt(fields[i], values[i]));
            // Receipt block identity is checked separately from its successful CREATE fields.
            _rejectPool(address(pool), i >= 5 ? "creation block" : "creation receipt");
        }
    }

    function test_controllerStageRejectsUnavailableCreationRPC() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        _setTransaction("");
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("", ""));
        _setReceipt("");
        _rejectMalformedEvidence(pool);
    }

    function test_controllerStageRejectsMissingMalformedOrPendingEvidence() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        string[4] memory invalid = ["null", "{}", "{", "[]"];
        for (uint256 i; i < invalid.length; ++i) {
            _setTransaction(invalid[i]);
            _rejectMalformedEvidence(pool);
        }
        _setTransaction(_transaction("", ""));
        for (uint256 i; i < invalid.length; ++i) {
            _setReceipt(invalid[i]);
            _rejectMalformedEvidence(pool);
        }
        _setReceipt(_receipt("", ""));
        _setTransaction(_transaction("blockHash", "null"));
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("blockNumber", "null"));
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("chainId", ""));
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("to", ""));
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("nonce", '"not-a-quantity"'));
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("", ""));
        _setReceipt(_receipt("status", ""));
        _rejectMalformedEvidence(pool);
        _setReceipt(_receipt("to", ""));
        _rejectMalformedEvidence(pool);
    }

    function test_controllerStageRejectsReorgedOrMissingCanonicalBlock() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        string[5] memory invalid = [
            "null",
            "{}",
            "{",
            string.concat('{"number":', _q(_quantity(creationBlock)), ',"hash":', _q(vm.toString(bytes32(0))), "}"),
            string.concat(
                '{"number":', _q(_quantity(creationBlock)), ',"hash":', _q(vm.toString(keccak256("reorg"))), "}"
            )
        ];
        for (uint256 i; i < invalid.length; ++i) {
            deploymentScript.setRpcResponse("eth_getBlockByNumber", _blockParams(), invalid[i]);
            _rejectMalformedEvidence(pool);
        }
    }

    function test_controllerStageRejectsDivergentCreationHistory() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        // All transaction, receipt and numbered-header replies still agree with one another.
        _setHistoryHash(creationBlock, keccak256("inspected fork history"));
        // Even a BLOCKHASH result agreeing with the divergent RPC must not override trusted state.
        vm.setBlockhash(creationBlock, CREATION_BLOCK_HASH);
        _rejectPool(address(pool), "creation ancestry");
    }

    function test_controllerStageRejectsUnanchoredCurrentCreationBlock() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        vm.roll(creationBlock);
        _rejectPool(address(pool), "creation ancestry");
    }

    function test_controllerStageRejectsHiddenPermissionsWithDivergentCanonicalEvidence() external {
        DirectPropAMM genuine = _deployPoolStage().pool;
        address hidden = makeAddr("hidden divergent taker");
        uint64 nonce = vm.getNonce(deployer);
        vm.recordLogs();
        vm.prank(deployer);
        DirectPropAMM malicious = DirectPropAMM(address(new HiddenPermissionParPool(genuine, hidden)));
        vm.prank(deployer);
        malicious.unpause();
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        _creationFixture(malicious, nonce, _canonicalInput(malicious));
        _setHistoryHash(creationBlock, keccak256("real malicious creation block"));
        _rejectPool(address(malicious), "creation ancestry");
        assertTrue(malicious.takerAllowed(hidden));
        assertTrue(malicious.recipientAllowed(hidden));
    }

    function test_creationAncestryAcceptsLastHistoryBoundary() external {
        vm.roll(10000);
        _setHistoryHash(1809, CREATION_BLOCK_HASH);
        deploymentScript.checkAncestry(1809, CREATION_BLOCK_HASH);
    }

    function test_creationAncestryRejectsMissingOldHeader() external {
        vm.roll(10000);
        _setHistoryHash(1809, CREATION_BLOCK_HASH);
        vm.expectRevert("missing RPC fixture");
        deploymentScript.checkAncestry(1, CREATION_BLOCK_HASH);
    }

    function test_creationAncestryRejectsAuthenticatedMalformedHeader() external {
        bytes[5] memory malformed =
            [bytes(hex"80"), bytes(hex"e1a0"), bytes(hex"c180"), bytes(hex"c1f8"), bytes(hex"c0")];
        vm.roll(10000);
        for (uint256 i; i < malformed.length; ++i) {
            bytes32 hash = keccak256(malformed[i]);
            _setHistoryHash(1809, hash);
            deploymentScript.setRpcResponse(
                "debug_getRawHeader", string.concat('["', vm.toString(hash), '"]'), _q(vm.toString(malformed[i]))
            );
            vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation header"));
            deploymentScript.checkAncestry(1, CREATION_BLOCK_HASH);
        }
    }

    function test_creationAncestryRejectsMissingMalformedOrRevertingHistoryState() external {
        vm.roll(10000);
        address history = address(0x0000F90827F1C53a10cb7A02335B175320002935);
        // No contract or mocked result: an empty successful call is not evidence.
        vm.etch(history, hex"");
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation ancestry"));
        deploymentScript.checkAncestry(9999, CREATION_BLOCK_HASH);
        vm.mockCall(history, abi.encode(uint256(9999)), new bytes(31));
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation ancestry"));
        deploymentScript.checkAncestry(9999, CREATION_BLOCK_HASH);
        vm.mockCall(history, abi.encode(uint256(9999)), new bytes(33));
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation ancestry"));
        deploymentScript.checkAncestry(9999, CREATION_BLOCK_HASH);
        vm.mockCallRevert(history, abi.encode(uint256(9999)), hex"01");
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation ancestry"));
        deploymentScript.checkAncestry(9999, CREATION_BLOCK_HASH);
    }

    function test_creationAncestryAcceptsOldAuthenticatedHistory() external {
        _oldAncestry(false);
    }

    function test_creationAncestryAcceptsTempoThreeScalarWrapper() external {
        // Mainnet-shaped scalar encodings: general gas 30M (4 bytes), shared gas zero, millis 217 (1 byte).
        // TempoHeader at tempo commit 2d12f29a99ba8388de4eaa0ae2c1ad2e20cb55be has these three fields.
        _checkRawAncestry(abi.encodePacked(hex"ea8401c9c3808081d9e1a0", CREATION_BLOCK_HASH));
    }

    function test_creationAncestryAcceptsTempoTrailingConsensusContext() external {
        // Optional consensus_context follows the inner header, never precedes it.
        _checkRawAncestry(
            abi.encodePacked(hex"f84f8401c9c3808081d9e1a0", CREATION_BLOCK_HASH, hex"e4010201a0", keccak256("proposer"))
        );
    }

    function test_creationAncestryRejectsTempoFourScalarWrapper() external {
        // The former synthetic fixture was not a TempoHeader: an extra scalar cannot shift the inner header.
        _setRawAncestry(abi.encodePacked(hex"e680808080e1a0", CREATION_BLOCK_HASH));
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation header"));
        deploymentScript.checkAncestry(1808, CREATION_BLOCK_HASH);
    }

    function test_creationAncestryRejectsTempoMalformedWrapperBounds() external {
        bytes[3] memory malformed = [
            // The purported inner list is one byte too short to contain its parentHash item.
            abi.encodePacked(hex"ea8401c9c3808081d9e0a0", CREATION_BLOCK_HASH),
            // A scalar cannot itself be a list.
            abi.encodePacked(hex"e5c08080e1a0", CREATION_BLOCK_HASH),
            // A declared scalar length cannot consume bytes past the authenticated outer list.
            bytes(hex"c3840102")
        ];
        for (uint256 i; i < malformed.length; ++i) {
            _setRawAncestry(malformed[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation header"));
            deploymentScript.checkAncestry(1808, CREATION_BLOCK_HASH);
        }
    }

    function _checkRawAncestry(bytes memory raw) internal {
        _setRawAncestry(raw);
        deploymentScript.checkAncestry(1808, CREATION_BLOCK_HASH);
    }

    function _setRawAncestry(bytes memory raw) internal {
        bytes32 hash = keccak256(raw);
        deploymentScript.setRpcResponse(
            "debug_getRawHeader", string.concat('["', vm.toString(hash), '"]'), _q(vm.toString(raw))
        );
        vm.roll(10000);
        _setHistoryHash(1809, hash);
    }

    function test_creationAncestryRejectsOldDivergentHistory() external {
        _oldAncestry(true);
    }

    function test_creationAncestryMemoryIsBoundedAcrossManyLinks() external {
        // Exercise the real loop, JSON decoding and all three header layouts without any network RPC.
        deploymentScript = new DeployParPoolMemoryHarness();
        uint256 height = _ancestryFixture(1024);
        uint256 growth = deploymentScript.checkAncestryMemory(height, CREATION_BLOCK_HASH);
        emit log_named_uint("ancestry retained memory bytes (1024 links)", growth);
        assertLt(growth, 4096, "ancestry memory must not grow with the number of links");
    }

    function _oldAncestry(bool divergent) internal {
        uint256 height = _ancestryFixture(257);
        if (divergent) {
            vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation ancestry"));
        }
        deploymentScript.checkAncestry(height, divergent ? keccak256("different history") : CREATION_BLOCK_HASH);
    }

    function _ancestryFixture(uint256 links) internal returns (uint256 height) {
        height = 100;
        bytes32 hash = CREATION_BLOCK_HASH;
        for (uint256 i = height + 1; i <= height + links; ++i) {
            // Cycle Ethereum, Tempo before consensus_context, and Tempo with its optional trailing context.
            bytes memory raw;
            if (i % 3 == 0) raw = abi.encodePacked(hex"e1a0", hash);
            else if (i % 3 == 1) raw = abi.encodePacked(hex"e5808080e1a0", hash);
            else raw = abi.encodePacked(hex"f84a808080e1a0", hash, hex"e4010201a0", keccak256("proposer"));
            bytes32 next = keccak256(raw);
            deploymentScript.setRpcResponse(
                "debug_getRawHeader", string.concat('["', vm.toString(next), '"]'), _q(vm.toString(raw))
            );
            hash = next;
        }
        vm.roll(height + 8191 + links);
        _setHistoryHash(height + links, hash);
    }

    function test_creationAncestryRejectsForgedRawHeader() external {
        vm.roll(10000);
        bytes32 anchor = keccak256("anchored header");
        _setHistoryHash(1809, anchor);
        deploymentScript.setRpcResponse(
            "debug_getRawHeader", string.concat('["', vm.toString(anchor), '"]'), _q("0xe1a0")
        );
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation header hash"));
        deploymentScript.checkAncestry(1, CREATION_BLOCK_HASH);
    }

    function test_creationAncestryRejectsUnavailableAnchorAndExcessiveWalk() external {
        vm.roll(10000);
        _setHistoryHash(1809, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation ancestry"));
        deploymentScript.checkAncestry(1, CREATION_BLOCK_HASH);
        vm.roll(1_008_193);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "creation ancestry limit"));
        deploymentScript.checkAncestry(1, CREATION_BLOCK_HASH);
    }

    function test_controllerStageRejectsTempoBatchOrNonProtocolNonce() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        _tempoFixture(pool);
        string memory call = _tempoCall(pool);
        _setTransaction(_transaction("calls", string.concat("[", call, ",", call, "]")));
        _rejectPool(address(pool), "creation transaction");
        _setTransaction(_transaction("calls", "[]"));
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("calls", ""));
        _rejectMalformedEvidence(pool);
        _setTransaction(_transaction("nonceKey", '"0x1"'));
        _rejectPool(address(pool), "creation transaction");
        _setTransaction(_transaction("nonceKey", ""));
        _rejectMalformedEvidence(pool);
        _setTransaction(
            _transaction(
                "calls",
                string.concat(
                    '[{"to":',
                    _q(vm.toString(router)),
                    ',"value":"0x0","input":',
                    _q(vm.toString(_canonicalInput(pool))),
                    "}]"
                )
            )
        );
        _rejectPool(address(pool), "creation transaction");
        _setTransaction(
            _transaction(
                "calls",
                string.concat('[{"to":null,"value":"0x1","input":', _q(vm.toString(_canonicalInput(pool))), "}]")
            )
        );
        _rejectPool(address(pool), "creation transaction");
        _setTransaction(_transaction("calls", '[{"to":null,"value":"0x0","input":"0x00"}]'));
        _rejectPool(address(pool), "creation input");
    }

    function test_controllerStageRejectsConstructorArgumentsAndMetadataMismatch() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        bytes memory input = _canonicalInput(pool);
        // Change only the guardian constructor argument, keeping the code and every other argument intact.
        uint256 guardianLastByte = type(DirectPropAMM).creationCode.length + 6 * 32 - 1;
        input[guardianLastByte] = bytes1(uint8(input[guardianLastByte]) ^ 1);
        _setTransaction(_transaction("input", _q(vm.toString(input))));
        _rejectPool(address(pool), "creation input");
        input = _canonicalInput(pool);
        // The final byte before CBOR's two-byte length belongs to the compiler-version metadata.
        uint256 metadataByte = type(DirectPropAMM).creationCode.length - 3;
        input[metadataByte] = bytes1(uint8(input[metadataByte]) ^ 1);
        _setTransaction(_transaction("input", _q(vm.toString(input))));
        _rejectPool(address(pool), "creation input");
        _setTransaction(_transaction("input", '"0x"'));
        _rejectPool(address(pool), "creation input");
    }

    function _acceptCreationEnvelope(string memory envelope) internal {
        DirectPropAMM pool = _deployPoolStage().pool;
        _setTransaction(_transaction("type", envelope));
        deploymentScript.setConfig(_controllerConfig(address(pool), deployer));
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertTrue(deployed.ownershipAccepted);
        assertEq(pool.owner(), address(deployed.controller));
    }

    /// @dev Parsing/RPC errors also fail closed before broadcasting, even when they originate in a cheatcode.
    function _rejectMalformedEvidence(DirectPropAMM pool) internal {
        uint64 nonce = vm.getNonce(deployer);
        address owner = pool.owner();
        address pendingOwner = pool.pendingOwner();
        deploymentScript.setConfig(_controllerConfig(address(pool), deployer));
        vm.expectRevert();
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(pool.owner(), owner);
        assertEq(pool.pendingOwner(), pendingOwner);
    }

    function test_productionRolesCannotInterleaveBeforeAnchorCapturePool() external {
        deploymentScript.setConfig(_poolConfig());
        deploymentScript.setInterleave();
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertEq(deployed.pool.baseToQuotePriceAnchor(), PAR);
        assertEq(deployed.pool.quoteToBasePriceAnchor(), PAR);
    }

    function test_productionRolesCannotInterleaveBeforeAnchorCaptureAll() external {
        deploymentScript.setInterleave();
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertEq(deployed.pool.baseToQuotePriceAnchor(), PAR);
        assertEq(deployed.pool.quoteToBasePriceAnchor(), PAR);
        assertEq(deployed.pool.owner(), address(deployed.controller));
    }

    function test_oracleHandoverRequiresAcceptanceAndRevokesBootstrapRoles() external {
        deploymentScript.setConfig(_poolConfig());
        vm.recordLogs();
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        _creationFixture(deployed.pool, vm.getNonce(deployer) - 1, _canonicalInput(deployed.pool));
        PushPriceOracle oracle = deployed.oracle;
        assertEq(oracle.owner(), deployer);
        assertEq(oracle.pendingOwner(), oracleOwner);
        assertEq(oracle.reporter(), reporter);
        vm.prank(reporter);
        vm.expectRevert(PushPriceOracle.NotPendingOwner.selector);
        oracle.acceptOwnership();
        vm.prank(oracleOwner);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), oracleOwner);
        assertEq(oracle.pendingOwner(), address(0));
        vm.warp(DEPLOYED_AT + 20);
        vm.prank(deployer);
        vm.expectRevert(PushPriceOracle.NotReporter.selector);
        oracle.pushPrice(PAR, DEPLOYED_AT + 20);
        vm.prank(deployer);
        vm.expectRevert(PushPriceOracle.NotOwner.selector);
        oracle.setReporter(deployer);
        vm.prank(deployer);
        vm.expectRevert(PushPriceOracle.NotOwner.selector);
        oracle.transferOwnership(deployer);
        vm.prank(reporter);
        oracle.pushPrice(PAR, DEPLOYED_AT + 20);
        deploymentScript.setConfig(_controllerConfig(address(deployed.pool), deployer));
        deployed = deploymentScript.run();
        vm.prank(deployer);
        deployed.controller.execute(abi.encodeCall(DirectPropAMM.pause, ()));
        vm.prank(deployer);
        deployed.controller.execute(abi.encodeCall(DirectPropAMM.unpause, ()));
        assertEq(deployed.pool.baseToQuotePriceAnchor(), PAR);
        assertEq(deployed.pool.quoteToBasePriceAnchor(), PAR);
    }

    function test_oracleRolesMayRemainWithDeployer() external {
        DeployParPool.Config memory config = _poolConfig();
        config.oracleOwner = deployer;
        config.oracleReporter = deployer;
        deploymentScript.setConfig(config);
        PushPriceOracle oracle = deploymentScript.run().oracle;
        assertEq(oracle.owner(), deployer);
        assertEq(oracle.pendingOwner(), address(0));
        assertEq(oracle.reporter(), deployer);
    }

    function test_oracleOwnerAndReporterMayBeSameExternalAccount() external {
        DeployParPool.Config memory config = _poolConfig();
        config.oracleReporter = oracleOwner;
        deploymentScript.setConfig(config);
        deploymentScript.setInterleave();
        PushPriceOracle oracle = deploymentScript.run().oracle;
        assertEq(oracle.reporter(), oracleOwner);
        vm.prank(oracleOwner);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), oracleOwner);
        assertEq(oracle.pendingOwner(), address(0));
    }

    function test_fullSequenceWithDeployerAsControllerOwner() external {
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        // Only the oracle, pool and controller creations advance the nonce in a test broadcast.
        assertEq(vm.getNonce(deployer), 3);
        assertTrue(deployed.ownershipAccepted);
        DirectPropAMM pool = deployed.pool;
        DirectPropAMMRebalanceController controller = deployed.controller;
        PushPriceOracle oracle = deployed.oracle;

        assertEq(pool.owner(), address(controller));
        assertEq(pool.pendingOwner(), address(0));
        assertEq(pool.guardian(), guardian);
        assertFalse(pool.paused());
        assertEq(address(pool.baseToken()), address(base));
        assertEq(address(pool.quoteToken()), address(quote));
        assertEq(address(pool.oracle()), address(oracle));
        assertEq(pool.priceScale(), PAR);
        assertEq(pool.maxOracleAge(), 30 days);
        assertEq(pool.maxPriceDeviationBps(), 0);
        assertEq(pool.baseToQuotePriceAnchor(), PAR);
        assertEq(pool.quoteToBasePriceAnchor(), PAR);
        assertEq(base.balanceOf(address(pool)), SEED);
        assertEq(quote.balanceOf(address(pool)), SEED);
        assertEq(base.balanceOf(deployer), 90 * UNIT);
        assertEq(quote.balanceOf(deployer), 90 * UNIT);
        (uint256 price, uint256 updatedAt) = oracle.latestPrice();
        assertEq(price, PAR);
        assertEq(updatedAt, DEPLOYED_AT);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.owner(), deployer);
        assertEq(oracle.pendingOwner(), address(0));
        assertEq(oracle.reporter(), reporter);
        assertEq(controller.owner(), deployer);
        assertEq(controller.keeper(), keeper);
        assertEq(controller.liquidationAddress(address(base)), baseLiquidation);
        assertEq(controller.liquidationAddress(address(quote)), quoteLiquidation);
        assertEq(controller.tokens().length, 2);

        // The deployer keeps no direct pool authority; it acts only as the controller owner.
        vm.startPrank(deployer);
        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        pool.setTakerAllowed(router, true);
        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        pool.withdraw(address(base), deployer, 1, bytes32(0));
        vm.stopPrank();

        // Nothing trades until a router is admitted through the controller.
        _approveAndMint(router, pool);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.TakerNotAllowed.selector, router));
        _swapAtPar(pool, true, UNIT);
        _admitRouter(controller, deployer);

        // Par both ways, exactly as SingleZoneEarnRouter calls it: zero tolerance at 10 ** decimals.
        assertEq(_swapAtPar(pool, true, 3 * UNIT), 3 * UNIT);
        assertEq(_swapAtPar(pool, false, 2 * UNIT), 2 * UNIT);
        assertEq(base.balanceOf(address(pool)), SEED + 3 * UNIT - 2 * UNIT);
        assertEq(quote.balanceOf(address(pool)), SEED - 3 * UNIT + 2 * UNIT);

        // The keeper sends inventory only to the fixed liquidation addresses and leaves the pool active.
        vm.prank(keeper);
        controller.rebalance(address(base), 4 * UNIT);
        vm.prank(keeper);
        controller.rebalance(address(quote), 1 * UNIT);
        assertEq(base.balanceOf(baseLiquidation), 4 * UNIT);
        assertEq(quote.balanceOf(quoteLiquidation), 1 * UNIT);
        assertEq(base.balanceOf(address(pool)), SEED + UNIT - 4 * UNIT);
        assertEq(quote.balanceOf(address(pool)), SEED - UNIT - 1 * UNIT);
        assertFalse(pool.paused());
        assertEq(_swapAtPar(pool, true, UNIT), UNIT);

        // The guardian still pauses, and a paused pool blocks the keeper.
        vm.prank(guardian);
        pool.pause();
        vm.prank(keeper);
        vm.expectRevert(DirectPropAMMRebalanceController.PoolPaused.selector);
        controller.rebalance(address(base), UNIT);
    }

    function test_controllerOwnerAcceptsLaterWhenNotTheDeployer() external {
        deploymentScript.setConfig(_config(controllerOwner));
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertEq(vm.getNonce(deployer), 3);
        assertFalse(deployed.ownershipAccepted);
        assertEq(deployed.pool.owner(), deployer);
        assertEq(deployed.pool.pendingOwner(), address(deployed.controller));
        assertFalse(deployed.pool.paused());

        // Until acceptance the keeper cannot rebalance, because the controller is not yet the owner.
        vm.prank(keeper);
        vm.expectRevert(DirectPropAMM.NotGuardianOrOwner.selector);
        deployed.controller.rebalance(address(base), UNIT);

        // The call the script logs for the controller owner.
        vm.prank(controllerOwner);
        deployed.controller.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));
        assertEq(deployed.pool.owner(), address(deployed.controller));
        assertEq(deployed.pool.pendingOwner(), address(0));

        _approveAndMint(router, deployed.pool);
        _admitRouter(deployed.controller, controllerOwner);
        assertEq(_swapAtPar(deployed.pool, false, UNIT), UNIT);
        vm.prank(keeper);
        deployed.controller.rebalance(address(base), UNIT);
        assertEq(base.balanceOf(baseLiquidation), UNIT);
    }

    function test_unfundedDeploymentStillActivatesAtPar() external {
        DeployParPool.Config memory config = _config(deployer);
        config.initialBaseAmount = 0;
        config.initialQuoteAmount = 0;
        deploymentScript.setConfig(config);
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertEq(vm.getNonce(deployer), 3);
        assertFalse(deployed.pool.paused());
        assertEq(base.balanceOf(address(deployed.pool)), 0);
        assertEq(quote.balanceOf(address(deployed.pool)), 0);
        assertEq(deployed.pool.owner(), address(deployed.controller));
    }

    function test_parOracleFailsClosedOnStalenessAndOffParPrices() external {
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        DirectPropAMM pool = deployed.pool;
        _approveAndMint(router, pool);
        _admitRouter(deployed.controller, deployer);

        // Past maxOracleAge, both swaps and keeper rebalances stop until the reporter re-attests par.
        vm.warp(DEPLOYED_AT + 30 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.StaleOraclePrice.selector, DEPLOYED_AT, 30 days));
        _swapAtPar(pool, true, UNIT);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.StaleOraclePrice.selector, DEPLOYED_AT, 30 days));
        deployed.controller.rebalance(address(base), UNIT);

        vm.prank(reporter);
        deployed.oracle.pushPrice(PAR, DEPLOYED_AT + 30 days + 1);
        assertEq(_swapAtPar(pool, true, UNIT), UNIT);
        // The oracle rejects a repeated timestamp.
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushPriceOracle.TimestampNotIncreasing.selector, DEPLOYED_AT + 30 days + 1, DEPLOYED_AT + 30 days + 1
            )
        );
        deployed.oracle.pushPrice(PAR, DEPLOYED_AT + 30 days + 1);

        // With zero deviation, any off-par push halts trading and rebalancing instead of moving the price.
        vm.warp(DEPLOYED_AT + 30 days + 2);
        vm.prank(reporter);
        deployed.oracle.pushPrice(PAR + 1, DEPLOYED_AT + 30 days + 2);
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.PriceDeviationExceeded.selector, true, PAR + 1, PAR, uint256(0))
        );
        vm.prank(router);
        pool.swapExactInput(true, UNIT, 0, router, CUSTOMER_ID, bytes32(0), block.timestamp, PAR + 1, 0, 0);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.PriceDeviationExceeded.selector, true, PAR + 1, PAR, uint256(0))
        );
        deployed.controller.rebalance(address(base), UNIT);
    }

    function test_poolStageLeavesDeployerOwnedActivePoolWithoutController() external {
        DeployParPool.Deployment memory deployed = _deployPoolStage();
        // Only the oracle and pool creations advance the nonce in a test broadcast.
        assertEq(vm.getNonce(deployer), 2);
        assertEq(address(deployed.controller), address(0));
        assertFalse(deployed.ownershipAccepted);
        DirectPropAMM pool = deployed.pool;
        assertEq(pool.owner(), deployer);
        assertEq(pool.pendingOwner(), address(0));
        assertEq(pool.guardian(), guardian);
        assertEq(address(pool.oracle()), address(deployed.oracle));
        assertFalse(pool.paused());
        assertEq(pool.baseToQuotePriceAnchor(), PAR);
        assertEq(pool.quoteToBasePriceAnchor(), PAR);
        assertEq(base.balanceOf(address(pool)), SEED);
        assertEq(quote.balanceOf(address(pool)), SEED);
        (uint256 price, uint256 updatedAt) = deployed.oracle.latestPrice();
        assertEq(price, PAR);
        assertEq(updatedAt, DEPLOYED_AT);

        // No taker is admitted, so the active pool cannot trade before the controller stage.
        _approveAndMint(router, pool);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.TakerNotAllowed.selector, router));
        _swapAtPar(pool, true, UNIT);
    }

    function test_stagedDeploymentHandsPoolToController() external {
        DeployParPool.Deployment memory staged = _deployPoolStage();
        DirectPropAMM pool = staged.pool;

        // Bridge creates the liquidation addresses for the pool while time passes, within maxOracleAge.
        vm.warp(DEPLOYED_AT + 1 days);
        DeployParPool.Config memory config = _controllerConfig(address(pool), deployer);
        config.oracle = address(staged.oracle);
        deploymentScript.setConfig(config);
        DeployParPool.Deployment memory deployed = deploymentScript.run();

        assertEq(vm.getNonce(deployer), 3);
        assertEq(address(deployed.pool), address(pool));
        assertEq(address(deployed.oracle), address(staged.oracle));
        assertTrue(deployed.ownershipAccepted);
        DirectPropAMMRebalanceController controller = deployed.controller;
        assertEq(pool.owner(), address(controller));
        assertEq(pool.pendingOwner(), address(0));
        assertEq(pool.guardian(), guardian);
        assertFalse(pool.paused());
        assertEq(base.balanceOf(address(pool)), SEED);
        assertEq(quote.balanceOf(address(pool)), SEED);
        assertEq(address(controller.pool()), address(pool));
        assertEq(controller.owner(), deployer);
        assertEq(controller.keeper(), keeper);
        assertEq(controller.liquidationAddress(address(base)), baseLiquidation);
        assertEq(controller.liquidationAddress(address(quote)), quoteLiquidation);

        vm.prank(deployer);
        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        pool.setTakerAllowed(router, true);

        _approveAndMint(router, pool);
        _admitRouter(controller, deployer);
        assertEq(_swapAtPar(pool, true, 3 * UNIT), 3 * UNIT);
        assertEq(_swapAtPar(pool, false, 2 * UNIT), 2 * UNIT);
        vm.prank(keeper);
        controller.rebalance(address(base), 4 * UNIT);
        vm.prank(keeper);
        controller.rebalance(address(quote), 1 * UNIT);
        assertEq(base.balanceOf(baseLiquidation), 4 * UNIT);
        assertEq(quote.balanceOf(quoteLiquidation), 1 * UNIT);
        assertFalse(pool.paused());
    }

    function test_controllerStageLeavesAcceptanceToSeparateOwner() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        deploymentScript.setConfig(_controllerConfig(address(pool), controllerOwner));
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertFalse(deployed.ownershipAccepted);
        assertEq(pool.owner(), deployer);
        assertEq(pool.pendingOwner(), address(deployed.controller));

        vm.prank(controllerOwner);
        deployed.controller.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));
        assertEq(pool.owner(), address(deployed.controller));
    }

    function test_stageInputsMustMatchStage() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        DeployParPool.Config memory config = _poolConfig();
        config.pool = address(pool);
        uint64 nonce = vm.getNonce(deployer);
        deploymentScript.setConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, "POOL_ADDRESS is only for STAGE=controller")
        );
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);

        deploymentScript.setConfig(_controllerConfig(address(0), deployer));
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, "POOL_ADDRESS"));
        deploymentScript.run();
        _rejectPool(makeAddr("notAPool"), "no code");

        config = _controllerConfig(address(pool), deployer);
        config.oracle = makeAddr("otherOracle");
        deploymentScript.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, "oracle"));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
    }

    function test_controllerStageRejectsWrongTokens() external {
        // The pair reversed: QUOTE base and BASE quote, otherwise a valid deployer-owned par pool.
        vm.startPrank(deployer);
        PushPriceOracle oracle = new PushPriceOracle(8, oracleOwner, reporter, PAR, DEPLOYED_AT);
        DirectPropAMM reversed = new DirectPropAMM(
            ITIP20(address(quote)),
            ITIP20(address(base)),
            oracle,
            IAddressRegistry(TempoMainnet.ADDRESS_REGISTRY),
            deployer,
            guardian,
            30 days,
            0
        );
        reversed.unpause();
        vm.stopPrank();
        _rejectPool(address(reversed), "tokens");

        // A pool of the pair, but the stage names it the other way round, or names another token.
        DirectPropAMM pool = _deployPoolStage().pool;
        DeployParPool.Config memory config = _controllerConfig(address(pool), deployer);
        (config.baseToken, config.quoteToken) = (address(quote), address(base));
        (config.baseSymbol, config.quoteSymbol) = ("QUOTE", "BASE");
        _rejectPool(config, "tokens");
        config = _controllerConfig(address(pool), deployer);
        config.quoteToken = address(_newToken("OTHER", 6));
        config.quoteSymbol = "OTHER";
        _rejectPool(config, "tokens");
    }

    function test_controllerStageRejectsWrongOwner() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        address other = makeAddr("otherOwner");
        vm.prank(deployer);
        pool.transferOwnership(other);
        vm.prank(other);
        pool.acceptOwnership();
        _rejectPool(address(pool), "owner");
    }

    function test_controllerStageRejectsOffParOrStaleOracle() external {
        DeployParPool.Deployment memory staged = _deployPoolStage();
        vm.warp(DEPLOYED_AT + 1);
        vm.prank(reporter);
        staged.oracle.pushPrice(PAR + 1, DEPLOYED_AT + 1);
        _rejectPool(address(staged.pool), "oracle not at par");

        vm.warp(DEPLOYED_AT + 2);
        vm.prank(reporter);
        staged.oracle.pushPrice(PAR, DEPLOYED_AT + 2);
        vm.warp(DEPLOYED_AT + 2 + 30 days + 1);
        _rejectPool(address(staged.pool), "oracle stale");
    }

    function test_controllerStageRejectsPausedPool() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        vm.prank(guardian);
        pool.pause();
        _rejectPool(address(pool), "paused");
    }

    function test_rejectsWrongChain() external {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedChain.selector, uint256(1)));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_rejectsMissingOrAliasedRoles() external {
        DeployParPool.Config memory config = _config(deployer);
        config.deployer = address(0);
        _reject(config, "DEPLOYER_ADDRESS");
        config = _config(deployer);
        config.controllerOwner = address(0);
        _reject(config, "CONTROLLER_OWNER_ADDRESS");
        config = _config(deployer);
        config.keeper = address(0);
        _reject(config, "KEEPER_ADDRESS");
        config = _config(deployer);
        config.guardian = address(0);
        _reject(config, "GUARDIAN_ADDRESS");
        config = _config(deployer);
        config.oracleOwner = address(0);
        _reject(config, "ORACLE_OWNER_ADDRESS");
        config = _config(deployer);
        config.oracleReporter = address(0);
        _reject(config, "ORACLE_REPORTER_ADDRESS");

        MockAddressRegistry(TempoMainnet.ADDRESS_REGISTRY).setResolution(keeper, makeAddr("master"));
        _reject(_config(deployer), "KEEPER_ADDRESS");
    }

    function test_rejectsEarnRouterBaseSenderPolicy() external {
        _rejectRouterPolicy(address(base), true);
    }

    function test_rejectsEarnRouterBaseRecipientPolicy() external {
        _rejectRouterPolicy(address(base), false);
    }

    function test_rejectsEarnRouterQuoteSenderPolicy() external {
        _rejectRouterPolicy(address(quote), true);
    }

    function test_rejectsEarnRouterQuoteRecipientPolicy() external {
        _rejectRouterPolicy(address(quote), false);
    }

    function test_controllerStageRejectsBlockedEarnRouterBeforeHandoff() external {
        DirectPropAMM pool = _deployPoolStage().pool;
        tip403.modifyPolicyBlacklist(BLACKLIST_POLICY, router, true);
        deploymentScript.setConfig(_controllerConfig(address(pool), deployer));
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, "EARN_ROUTER_ADDRESS transfer policy")
        );
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(pool.owner(), deployer);
        assertEq(pool.pendingOwner(), address(0));
    }

    function test_rejectsAliasedEarnRouter() external {
        MockAddressRegistry(TempoMainnet.ADDRESS_REGISTRY).setResolution(router, makeAddr("routerMaster"));
        _reject(_config(deployer), "EARN_ROUTER_ADDRESS");
    }

    function test_omittedEarnRouterNeedsNoPolicyApproval() external {
        tip403.modifyPolicyBlacklist(BLACKLIST_POLICY, router, true);
        DeployParPool.Config memory config = _config(deployer);
        config.earnRouter = address(0);
        deploymentScript.setConfig(config);
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertFalse(deployed.pool.takerAllowed(router));
        assertFalse(deployed.pool.recipientAllowed(router));
    }

    function test_allowedEarnRouterIsNotAutomaticallyAdmitted() external {
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertFalse(deployed.pool.takerAllowed(router));
        assertFalse(deployed.pool.recipientAllowed(router));
    }

    function test_rejectsInvalidLiquidationAddresses() external {
        DeployParPool.Config memory config = _config(deployer);
        config.baseLiquidationAddress = address(0);
        _reject(config, "BASE_LIQUIDATION_ADDRESS");
        config = _config(deployer);
        config.quoteLiquidationAddress = address(0);
        _reject(config, "QUOTE_LIQUIDATION_ADDRESS");
        config = _config(deployer);
        config.quoteLiquidationAddress = baseLiquidation;
        _reject(config, "liquidation addresses must differ");

        tip403.setBlacklisted(BLACKLIST_POLICY, baseLiquidation, true);
        _reject(_config(deployer), "BASE_LIQUIDATION_ADDRESS");
        tip403.setBlacklisted(BLACKLIST_POLICY, baseLiquidation, false);
        tip403.setBlacklisted(BLACKLIST_POLICY, quoteLiquidation, true);
        _reject(_config(deployer), "QUOTE_LIQUIDATION_ADDRESS");
    }

    function test_rejectsInvalidRiskLimitsAndFunding() external {
        DeployParPool.Config memory config = _config(deployer);
        config.maxOracleAge = 0;
        _reject(config, "MAX_ORACLE_AGE");
        config.maxOracleAge = 365 days + 1;
        _reject(config, "MAX_ORACLE_AGE");
        config = _config(deployer);
        config.maxPriceDeviationBps = 101;
        _reject(config, "MAX_PRICE_DEVIATION_BPS");
        config = _config(deployer);
        config.initialBaseAmount = 1000 * UNIT + 1;
        _reject(config, "INITIAL_BASE_AMOUNT");
        config = _config(deployer);
        config.initialQuoteAmount = 1000 * UNIT + 1;
        _reject(config, "INITIAL_QUOTE_AMOUNT");
        config = _config(deployer);
        config.initialQuoteAmount = 101 * UNIT;
        _reject(config, "deployer balance");

        tip403.setBlacklisted(BLACKLIST_POLICY, deployer, true);
        _reject(_config(deployer), "deployer transfer policy");
    }

    function test_acceptsLongestOracleAgeAndSmallDeviation() external {
        DeployParPool.Config memory config = _config(deployer);
        config.maxOracleAge = 365 days;
        config.maxPriceDeviationBps = 100;
        deploymentScript.setConfig(config);
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        assertEq(deployed.pool.maxOracleAge(), 365 days);
        assertEq(deployed.pool.maxPriceDeviationBps(), 100);
    }

    function test_rejectsUnexpectedTokens() external {
        vm.mockCall(address(quote), abi.encodeCall(ITIP20.decimals, ()), abi.encode(uint8(18)));
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedToken.selector, address(quote)));
        deploymentScript.run();
        vm.clearMockedCalls();
        _mockPolicy();
        vm.mockCall(address(base), abi.encodeCall(ITIP20.symbol, ()), abi.encode("WRONG"));
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedToken.selector, address(base)));
        deploymentScript.run();
        vm.clearMockedCalls();
        _mockPolicy();

        // The expected symbols are inputs: a token that answers another symbol than the configured one is refused.
        DeployParPool.Config memory config = _config(deployer);
        config.quoteSymbol = "BASE";
        deploymentScript.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedToken.selector, address(quote)));
        deploymentScript.run();
        // A real token of other decimals, with its own symbol, is refused for the unequal units.
        config = _config(deployer);
        config.quoteToken = address(_newToken("WIDE", 18));
        config.quoteSymbol = "WIDE";
        deploymentScript.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.UnexpectedToken.selector, config.quoteToken));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_rejectsMissingOrRepeatedTokens() external {
        DeployParPool.Config memory config = _config(deployer);
        config.baseToken = address(0);
        _reject(config, "BASE_TOKEN");
        config = _config(deployer);
        config.quoteToken = address(0);
        _reject(config, "QUOTE_TOKEN");
        config = _config(deployer);
        config.baseSymbol = "";
        _reject(config, "BASE_TOKEN_SYMBOL");
        config = _config(deployer);
        config.quoteSymbol = "";
        _reject(config, "QUOTE_TOKEN_SYMBOL");
        config = _config(deployer);
        config.quoteToken = address(base);
        config.quoteSymbol = "BASE";
        _reject(config, "BASE_TOKEN and QUOTE_TOKEN must differ");

        // The controller stage reads and checks the tokens too.
        config = _controllerConfig(makeAddr("pool"), deployer);
        config.quoteToken = address(0);
        _reject(config, "QUOTE_TOKEN");
    }

    /// @dev Par needs equal decimals, not 6: the pool's price scale stays `1e8`, swaps stay 1:1 in raw units, and the
    /// funding cap is 1,000 whole tokens in the tokens' own decimals.
    function test_deploysParPoolForTokensOfOtherEqualDecimals() external {
        uint256 unit = 1e18;
        MockTIP20 wideBase = _newToken("WBASE", 18);
        MockTIP20 wideQuote = _newToken("WQUOTE", 18);
        wideBase.mint(deployer, 2000 * unit);
        wideQuote.mint(deployer, 2000 * unit);
        DeployParPool.Config memory config = _config(deployer);
        (config.baseToken, config.quoteToken) = (address(wideBase), address(wideQuote));
        (config.baseSymbol, config.quoteSymbol) = ("WBASE", "WQUOTE");
        config.initialBaseAmount = 1000 * unit + 1;
        config.initialQuoteAmount = 10 * unit;
        _reject(config, "INITIAL_BASE_AMOUNT");

        config.initialBaseAmount = 1000 * unit;
        deploymentScript.setConfig(config);
        DeployParPool.Deployment memory deployed = deploymentScript.run();
        DirectPropAMM pool = deployed.pool;
        assertTrue(deployed.ownershipAccepted);
        assertEq(address(pool.baseToken()), address(wideBase));
        assertEq(address(pool.quoteToken()), address(wideQuote));
        assertEq(pool.baseDecimals(), 18);
        assertEq(pool.quoteDecimals(), 18);
        assertEq(pool.priceScale(), PAR);
        assertEq(wideBase.balanceOf(address(pool)), 1000 * unit);
        assertEq(wideQuote.balanceOf(address(pool)), 10 * unit);
        assertEq(deployed.controller.liquidationAddress(address(wideBase)), baseLiquidation);
        assertEq(deployed.controller.liquidationAddress(address(wideQuote)), quoteLiquidation);

        wideBase.mint(router, 5 * unit);
        vm.prank(router);
        wideBase.approve(address(pool), type(uint256).max);
        _admitRouter(deployed.controller, deployer);
        assertEq(_swapAtPar(pool, true, 5 * unit), 5 * unit);
        assertEq(wideQuote.balanceOf(router), 5 * unit);
        vm.prank(keeper);
        deployed.controller.rebalance(address(wideBase), 5 * unit);
        assertEq(wideBase.balanceOf(baseLiquidation), 5 * unit);
    }

    /// @dev The single-run (`all`) configuration.
    function _config(address controllerOwner_) internal view returns (DeployParPool.Config memory) {
        return DeployParPool.Config({
            stage: DeployParPool.Stage.All,
            deployer: deployer,
            baseToken: address(base),
            quoteToken: address(quote),
            baseSymbol: "BASE",
            quoteSymbol: "QUOTE",
            guardian: guardian,
            oracleOwner: deployer,
            oracleReporter: reporter,
            maxOracleAge: 30 days,
            maxPriceDeviationBps: 0,
            initialBaseAmount: SEED,
            initialQuoteAmount: SEED,
            pool: address(0),
            poolDeploymentBlock: 0,
            poolCreationTx: bytes32(0),
            oracle: address(0),
            controllerOwner: controllerOwner_,
            keeper: keeper,
            baseLiquidationAddress: baseLiquidation,
            quoteLiquidationAddress: quoteLiquidation,
            earnRouter: router
        });
    }

    /// @dev Stage 1 reads no controller inputs, so they stay zero, as `_readConfig` leaves them.
    function _poolConfig() internal view returns (DeployParPool.Config memory config) {
        config = _config(address(0));
        config.stage = DeployParPool.Stage.Pool;
        config.oracleOwner = oracleOwner;
        config.keeper = address(0);
        config.baseLiquidationAddress = address(0);
        config.quoteLiquidationAddress = address(0);
        config.earnRouter = address(0);
    }

    /// @dev Stage 2 requires expected oracle roles, but reads no guardian, risk or funding inputs.
    function _controllerConfig(address pool, address controllerOwner_)
        internal
        view
        returns (DeployParPool.Config memory config)
    {
        config = _config(controllerOwner_);
        config.stage = DeployParPool.Stage.Controller;
        config.pool = pool;
        config.poolDeploymentBlock = creationBlock;
        config.poolCreationTx = CREATION_TX;
        config.guardian = address(0);
        config.oracleOwner = oracleOwner;
        config.maxOracleAge = 0;
        config.initialBaseAmount = 0;
        config.initialQuoteAmount = 0;
    }

    function _deployPoolStage() internal returns (DeployParPool.Deployment memory deployed) {
        deploymentScript.setConfig(_poolConfig());
        vm.recordLogs();
        deployed = deploymentScript.run();
        deploymentScript.addLogs(vm.getRecordedLogs(), uint64(block.number), false);
        vm.prank(oracleOwner);
        deployed.oracle.acceptOwnership();
        _creationFixture(deployed.pool, vm.getNonce(deployer) - 1, _canonicalInput(deployed.pool));
    }

    function _canonicalInput(DirectPropAMM pool) internal view returns (bytes memory) {
        return bytes.concat(
            type(DirectPropAMM).creationCode,
            abi.encode(
                address(base),
                address(quote),
                pool.oracle(),
                TempoMainnet.ADDRESS_REGISTRY,
                deployer,
                pool.guardian(),
                pool.maxOracleAge(),
                pool.maxPriceDeviationBps()
            )
        );
    }

    function _setHistoryHash(uint256 height, bytes32 hash) internal {
        vm.mockCall(address(0x0000F90827F1C53a10cb7A02335B175320002935), abi.encode(height), abi.encode(hash));
    }

    function _creationFixture(DirectPropAMM pool, uint64 nonce, bytes memory input) internal {
        assertEq(vm.computeCreateAddress(deployer, nonce), address(pool));
        creationBlock = block.number;
        creationTransaction = [
            '"0x2"',
            _q(_quantity(block.chainid)),
            _q(vm.toString(CREATION_TX)),
            _q(vm.toString(deployer)),
            _q(_quantity(nonce)),
            "null",
            '"0x0"',
            _q(vm.toString(CREATION_BLOCK_HASH)),
            _q(_quantity(creationBlock)),
            _q(vm.toString(input)),
            "",
            ""
        ];
        creationReceipt = [
            _q(vm.toString(CREATION_TX)),
            _q(vm.toString(address(pool))),
            _q(vm.toString(deployer)),
            "null",
            '"0x1"',
            _q(vm.toString(CREATION_BLOCK_HASH)),
            _q(_quantity(creationBlock)),
            "",
            "",
            "",
            "",
            ""
        ];
        vm.roll(creationBlock + 1);
        _setHistoryHash(creationBlock, CREATION_BLOCK_HASH);
        _setTransaction(_transaction("", ""));
        _setReceipt(_receipt("", ""));
        deploymentScript.setRpcResponse(
            "eth_getBlockByNumber",
            _blockParams(),
            string.concat(
                '{"number":', _q(_quantity(creationBlock)), ',"hash":', _q(vm.toString(CREATION_BLOCK_HASH)), "}"
            )
        );
    }

    function _tempoFixture(DirectPropAMM pool) internal {
        creationTransaction[0] = '"0x76"';
        // Tempo carries CREATE in calls[0], not the legacy top-level to/value/input fields.
        creationTransaction[5] = "";
        creationTransaction[6] = "";
        creationTransaction[9] = "";
        creationTransaction[10] = '"0x0"';
        creationTransaction[11] = string.concat("[", _tempoCall(pool), "]");
        _setTransaction(_transaction("", ""));
    }

    function _tempoCall(DirectPropAMM pool) internal view returns (string memory) {
        return string.concat('{"to":null,"value":"0x0","input":', _q(vm.toString(_canonicalInput(pool))), "}");
    }

    function _transaction(string memory field, string memory value) internal view returns (string memory) {
        string[12] memory names = [
            "type",
            "chainId",
            "hash",
            "from",
            "nonce",
            "to",
            "value",
            "blockHash",
            "blockNumber",
            "input",
            "nonceKey",
            "calls"
        ];
        return _json(names, creationTransaction, field, value);
    }

    function _receipt(string memory field, string memory value) internal view returns (string memory) {
        string[12] memory names = [
            "transactionHash", "contractAddress", "from", "to", "status", "blockHash", "blockNumber", "", "", "", "", ""
        ];
        return _json(names, creationReceipt, field, value);
    }

    function _json(string[12] memory names, string[12] memory values, string memory field, string memory value)
        internal
        pure
        returns (string memory result)
    {
        result = "{";
        for (uint256 i; i < names.length; ++i) {
            if (bytes(names[i]).length == 0) continue;
            string memory current = keccak256(bytes(names[i])) == keccak256(bytes(field)) ? value : values[i];
            if (bytes(current).length == 0) continue;
            result = string.concat(result, bytes(result).length > 1 ? "," : "", _q(names[i]), ":", current);
        }
        return string.concat(result, "}");
    }

    function _blockParams() internal view returns (string memory) {
        return string.concat("[", _q(_quantity(creationBlock)), ",false]");
    }

    /// @dev JSON-RPC quantities use minimal, hex-prefixed encoding, unlike vm.toString(uint256).
    function _quantity(uint256 value) internal pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        uint256 length = 1;
        for (uint256 remaining = value >> 4; remaining != 0; remaining >>= 4) {
            ++length;
        }
        bytes memory result = new bytes(length + 2);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = length + 1; i > 1; --i) {
            result[i] = digits[value & 15];
            value >>= 4;
        }
        return string(result);
    }

    function _q(string memory value) internal pure returns (string memory) {
        return string.concat('"', value, '"');
    }

    function _setTransaction(string memory transaction) internal {
        deploymentScript.setRpcResponse(
            "eth_getTransactionByHash", string.concat("[", _q(vm.toString(CREATION_TX)), "]"), transaction
        );
    }

    function _setReceipt(string memory receipt) internal {
        deploymentScript.setRpcResponse(
            "eth_getTransactionReceipt", string.concat("[", _q(vm.toString(CREATION_TX)), "]"), receipt
        );
    }

    function _rejectRouterPolicy(address token, bool sender) internal {
        uint64 blacklist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
        tip403.modifyPolicyBlacklist(blacklist, router, true);
        uint64 policy = tip403.createCompoundPolicy(sender ? blacklist : 1, sender ? 1 : blacklist);
        vm.mockCall(token, abi.encodeCall(ITIP20TransferPolicy.transferPolicyId, ()), abi.encode(policy));
        assertEq(tip403.isAuthorizedSender(policy, router), !sender);
        assertEq(tip403.isAuthorizedRecipient(policy, router), sender);
        _reject(_config(deployer), "EARN_ROUTER_ADDRESS transfer policy");
    }

    function _reject(DeployParPool.Config memory config, string memory reason) internal {
        deploymentScript.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidConfig.selector, reason));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function _rejectPool(address pool, string memory reason) internal {
        _rejectPool(_controllerConfig(pool, deployer), reason);
    }

    function _rejectPool(DeployParPool.Config memory config, string memory reason) internal {
        uint64 nonce = vm.getNonce(deployer);
        bool isPool = config.pool.code.length != 0;
        address priorOwner = isPool ? DirectPropAMM(config.pool).owner() : address(0);
        address priorPendingOwner = isPool ? DirectPropAMM(config.pool).pendingOwner() : address(0);
        deploymentScript.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(DeployParPool.InvalidPool.selector, reason));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
        if (isPool) {
            assertEq(DirectPropAMM(config.pool).owner(), priorOwner);
            assertEq(DirectPropAMM(config.pool).pendingOwner(), priorPendingOwner);
        }
    }

    function _admitRouter(DirectPropAMMRebalanceController controller, address owner) internal {
        vm.startPrank(owner);
        controller.execute(abi.encodeCall(DirectPropAMM.setTakerAllowed, (router, true)));
        controller.execute(abi.encodeCall(DirectPropAMM.setRecipientAllowed, (router, true)));
        vm.stopPrank();
    }

    function _approveAndMint(address account, DirectPropAMM pool) internal {
        base.mint(account, 10 * UNIT);
        quote.mint(account, 10 * UNIT);
        vm.startPrank(account);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _swapAtPar(DirectPropAMM pool, bool baseToQuote, uint256 amount) internal returns (uint256) {
        vm.prank(router);
        return
            pool.swapExactInput(
                baseToQuote, amount, amount, router, CUSTOMER_ID, bytes32(0), block.timestamp, PAR, 0, 0
            );
    }

    /// @dev A mock TIP-20 under the blacklist policy.
    function _newToken(string memory symbol, uint8 decimals) internal returns (MockTIP20 token) {
        token = new MockTIP20(symbol, decimals);
        _mockPolicy(address(token));
    }

    function _mockPolicy() internal {
        _mockPolicy(address(base));
        _mockPolicy(address(quote));
    }

    function _mockPolicy(address token) internal {
        vm.mockCall(
            token, abi.encodeCall(ITIP20TransferPolicy.transferPolicyId, ()), abi.encode(uint64(BLACKLIST_POLICY))
        );
    }
}
