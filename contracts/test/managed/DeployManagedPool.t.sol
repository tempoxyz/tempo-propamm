// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DeployManagedPool } from "../../script/managed/DeployManagedPool.s.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { TempoMainnet } from "../../src/TempoMainnet.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { ITIP403Registry } from "../../src/interfaces/ITIP403Registry.sol";
import { ITIP403Precompile } from "../v2/mocks/ITIP403Precompile.sol";
import { MockTIP403Registry } from "../v2/mocks/MockTIP403Registry.sol";
import { ITIP20Factory } from "../../src/interfaces/ITIP20Factory.sol";
import { TIP20FactoryMock } from "../v2/utils/TIP20FactoryMock.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

/// @dev Reads its inputs from storage instead of the process environment, which parallel tests share, and probes the
/// TIP-20 a test names for Tempo's precompiles.
contract DeployManagedPoolHarness is DeployManagedPool {
    bytes internal _encoded;
    address internal _probe;

    function answersDecimals(address target) external view returns (bool) {
        return _answersDecimals(target);
    }

    function latestPrice(address target) external view returns (bool, uint256, uint256) {
        return _latestPrice(target);
    }

    function setInput(Config calldata config) external {
        _encoded = abi.encode(config);
    }

    function checkDeployment(Deployment calldata deployed, Config calldata config, uint256[] calldata inventoryBefore)
        external
        view
    {
        _checkDeployment(deployed, config, inventoryBefore);
    }

    function setTip20Probe(address probe) external {
        _probe = probe;
    }

    /// @notice The real environment reader, for the one test that sets the environment.
    function readEnvConfig() external view returns (Config memory) {
        return super._readConfig();
    }

    /// @notice The TIP-20 the script probes outside tests.
    function defaultTip20Probe() external view returns (address) {
        return super._tip20Probe();
    }

    function _readConfig() internal view override returns (Config memory) {
        return abi.decode(_encoded, (Config));
    }

    function _tip20Probe() internal view override returns (address) {
        return _probe;
    }
}

/// @dev Has code but no `decimals()`.
contract NoDecimals {
    function name() external pure returns (string memory) {
        return "none";
    }
}

interface IManagedDeploymentTokenFactory {
    function createToken(
        string memory name,
        string memory symbol,
        string memory currency,
        address quoteToken,
        address admin,
        bytes32 salt
    ) external returns (address);
}

/// @dev Deliberately unmarked token-shaped code; metadata alone must never admit it.
contract CounterfeitManagedDeploymentToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function transferFromWithMemo(address, address to, uint256 amount, bytes32) external returns (bool) {
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Existing deployment fixtures use the built-in allow-all token policy; policy regressions use real TIP-20s.
contract ManagedDeploymentMockToken is MockTIP20 {
    constructor(string memory symbol_, uint8 decimals_) MockTIP20(symbol_, decimals_) { }

    function transferPolicyId() external pure returns (uint64) {
        return 1;
    }
}

interface IManagedDeploymentPolicyToken {
    function changeTransferPolicyId(uint64 policy) external;
    function transferPolicyId() external view returns (uint64);
}

/// @dev Exercises hostile metadata at the same raw-call boundary as operator-provided oracles.
contract HostileDeploymentProbe {
    bytes4 internal immutable selector;
    uint256 internal immutable size;
    bool internal immutable burns;
    bool internal immutable reverts;

    constructor(bytes4 selector_, uint256 size_, bool burns_, bool reverts_) {
        selector = selector_;
        size = size_;
        burns = burns_;
        reverts = reverts_;
    }

    fallback() external {
        if (msg.sig != selector) {
            assembly ("memory-safe") {
                mstore(0, 8)
                return(0, 32)
            }
        }
        if (burns) {
            assembly ("memory-safe") {
                for { } 1 { } { }
            }
        }
        uint256 length = size;
        bool fail = reverts;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 6)
            if fail { revert(ptr, length) }
            return(ptr, length)
        }
    }
}

/// @notice `DeployManagedPool`: both owner modes on Moderato and mainnet, every postcondition, and every refusal.
/// @dev Runs on mock tokens; under `forge test --network tempo` the preflight probes the pathUSD precompile itself.
contract DeployManagedPoolTest is Test {
    uint256 internal constant MODERATO = 42_431;
    uint256 internal constant MAINNET = 4217;

    address internal deployer = makeAddr("deployer");
    address internal owner = makeAddr("owner");

    address internal constant TIP20_FACTORY = 0x20Fc000000000000000000000000000000000000;
    bool internal nativeFactory;

    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockTIP20 internal eurx;
    MockOracle internal primeOracle;
    MockOracle internal eurOracle;
    MockOracle internal eurPrimeOracle;
    DeployManagedPoolHarness internal script;

    function setUp() external {
        vm.warp(1_000_000);
        vm.chainId(MODERATO);
        nativeFactory = TIP20_FACTORY.code.length != 0;
        TIP20FactoryMock.install(vm);
        if (TempoMainnet.TIP403_REGISTRY.code.length == 0) {
            vm.etch(TempoMainnet.TIP403_REGISTRY, address(new MockTIP403Registry()).code);
        }
        prime = new ManagedDeploymentMockToken("PRIME", 6);
        pathUsd = new ManagedDeploymentMockToken("pathUSD", 6);
        eurx = new ManagedDeploymentMockToken("EURX", 18);
        primeOracle = new MockOracle(8, 105_000_000, block.timestamp);
        eurOracle = new MockOracle(8, 108_500_000, block.timestamp);
        eurPrimeOracle = new MockOracle(8, 103_333_333, block.timestamp);
        script = new DeployManagedPoolHarness();
        script.setTip20Probe(TempoMainnet.PATH_USD.code.length != 0 ? TempoMainnet.PATH_USD : address(pathUsd));
    }

    function test_probesThePathUsdPrecompileOutsideTests() external view {
        assertEq(script.defaultTip20Probe(), TempoMainnet.PATH_USD);
    }

    /// @dev On Moderato with the owner as the deployer, one broadcast deploys the pool and adds its pairs.
    function test_ownerDeployerSendsThePairs() external {
        DeployManagedPool.Config memory config = _config(deployer);
        script.setInput(config);
        vm.expectCall(
            _nextPool(),
            abi.encodeCall(
                IManagedDirectPropAMM.addPair,
                (address(prime), address(pathUsd), IPriceOracle(address(primeOracle)), 90_000, 50)
            ),
            1
        );
        DeployManagedPool.Deployment memory deployed = script.run();
        assertTrue(deployed.pairsSent);
        ManagedDirectPropAMM pool = deployed.pool;
        assertEq(pool.owner(), deployer);
        _assertDeployed(pool, config);
    }

    /// @dev With another owner, the deployer only deploys: the owner's `addPair` calls run in the simulation and come
    /// back as calldata, and the deployer holds no pool role.
    function test_otherOwnerGetsSafeCalldataAndTheDeployerHoldsNoRole() external {
        vm.chainId(MAINNET);
        DeployManagedPool.Config memory config = _config(owner);
        script.setInput(config);
        DeployManagedPool.Deployment memory deployed = script.run();
        assertFalse(deployed.pairsSent);
        ManagedDirectPropAMM pool = deployed.pool;
        assertEq(pool.owner(), owner);
        _assertDeployed(pool, config);
        assertEq(deployed.ownerCalls.length, 3);
        for (uint256 i; i < 3; ++i) {
            DeployManagedPool.PairConfig memory p = config.pairs[i];
            assertEq(
                deployed.ownerCalls[i],
                abi.encodeCall(
                    IManagedDirectPropAMM.addPair,
                    (p.base, p.quote, IPriceOracle(p.oracle), p.maxOracleAge, p.maxPriceDeviationBps)
                )
            );
        }
        vm.expectRevert(IManagedDirectPropAMM.NotOwner.selector);
        vm.prank(deployer);
        pool.addPair(address(prime), address(eurx), primeOracle, 90_000, 50);
    }

    /// @dev Anyone can donate dust to the next CREATE address before it has code, in either owner mode.
    function test_prefundedPredictedPoolDoesNotBlockDeployment() external {
        address donor = makeAddr("donor");
        for (uint256 i; i < 2; ++i) {
            vm.chainId(i == 0 ? MODERATO : MAINNET);
            DeployManagedPool.Config memory config = _config(i == 0 ? deployer : owner);
            script.setInput(config);
            address predicted = _nextPool();
            assertEq(predicted.code.length, 0);
            prime.mint(donor, 1);
            pathUsd.mint(donor, 1);
            vm.startPrank(donor);
            prime.transferWithMemo(predicted, 1, bytes32(0));
            pathUsd.transferWithMemo(predicted, 1, bytes32(0));
            vm.stopPrank();

            DeployManagedPool.Deployment memory deployed = script.run();
            assertEq(address(deployed.pool), predicted);
            assertEq(deployed.pairsSent, i == 0);
            assertEq(deployed.pool.owner(), config.owner);
            assertEq(deployed.pool.pendingOwner(), address(0));
            _assertDeployed(deployed.pool, config);
            assertEq(prime.balanceOf(predicted), 1);
            assertEq(pathUsd.balanceOf(predicted), 1);
            assertEq(eurx.balanceOf(predicted), 0);
            assertEq(prime.balanceOf(donor), 0);
            assertEq(pathUsd.balanceOf(donor), 0);
            assertEq(prime.balanceOf(deployer), 0);
            assertEq(pathUsd.balanceOf(deployer), 0);
            assertEq(prime.balanceOf(owner), 0);
            assertEq(pathUsd.balanceOf(owner), 0);
        }
    }

    function test_inventoryPostconditionStillRejectsBalanceChanges() external {
        DeployManagedPool.Config memory config = _config(deployer);
        script.setInput(config);
        for (uint256 i; i < 2; ++i) {
            DeployManagedPool.Deployment memory deployed = script.run();
            uint256[] memory inventoryBefore = new uint256[](config.pairs.length * 2);
            script.checkDeployment(deployed, config, inventoryBefore);
            (i == 0 ? prime : pathUsd).mint(address(deployed.pool), 1);
            vm.expectRevert(abi.encodeWithSelector(DeployManagedPool.UnexpectedDeploymentState.selector, "inventory"));
            script.checkDeployment(deployed, config, inventoryBefore);
        }
    }

    /// @dev A stale oracle doesn't block the deployment: only opening the pair needs a fresh price.
    function test_aStaleOracleOnlyWarns() external {
        primeOracle.setPrice(105_000_000, block.timestamp - 90_001);
        script.setInput(_config(deployer));
        ManagedDirectPropAMM pool = script.run().pool;
        assertEq(pool.pairCount(), 3);
        vm.expectRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, 1_000_000 - 90_001, 90_000)
        );
        vm.prank(deployer);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
    }

    function test_refusesOtherChainsAndRoles() external {
        DeployManagedPool.Config memory config = _config(deployer);
        vm.chainId(1);
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(DeployManagedPool.UnexpectedChain.selector, 1));
        script.run();
        vm.chainId(MODERATO);

        address virtualAccount = VirtualAddress.make(0x12345678, 1);
        address[2] memory bad = [address(0), virtualAccount];
        for (uint256 i; i < bad.length; ++i) {
            config = _config(deployer);
            config.deployer = bad[i];
            _reject(config, "DEPLOYER_ADDRESS");
            config = _config(deployer);
            config.owner = bad[i];
            _reject(config, "OWNER_ADDRESS");
        }
        // Forge's default sender has no signer.
        config = _config(deployer);
        config.deployer = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
        config.owner = config.deployer;
        _reject(config, "DEPLOYER_ADDRESS");

        // Moderato permits the deployer as owner; mainnet requires an independent owner.
        config = _config(deployer);
        script.setInput(config);
        script.run();
        vm.chainId(MAINNET);
        _reject(_config(deployer), "deployer must hold no pool role on mainnet");
    }

    function test_refusesBadPairs() external {
        DeployManagedPool.Config memory config = _config(deployer);
        config.pairs = new DeployManagedPool.PairConfig[](0);
        _reject(config, "PAIR_* lists need 1 to 16 pairs");
        config.pairs = new DeployManagedPool.PairConfig[](17);
        _reject(config, "PAIR_* lists need 1 to 16 pairs");

        address noCode = makeAddr("noCode");
        address noDecimals = address(new NoDecimals());
        // A token as the oracle answers `decimals()` but not `latestPrice()`.
        address noPrice = address(eurx);
        _rejectPair(1, _pair(address(0), address(pathUsd), address(eurOracle)), "PAIR_BASES[1]");
        _rejectPair(1, _pair(noCode, address(pathUsd), address(eurOracle)), "PAIR_BASES[1]");
        _rejectPair(1, _pair(address(eurx), address(eurx), address(eurOracle)), "PAIR_QUOTES[1]");
        _rejectPair(1, _pair(address(eurx), noCode, address(eurOracle)), "PAIR_QUOTES[1]");
        _rejectPair(1, _pair(noDecimals, address(pathUsd), address(eurOracle)), "PAIR_BASES[1] has no decimals()");
        _rejectPair(1, _pair(address(eurx), noDecimals, address(eurOracle)), "PAIR_QUOTES[1] has no decimals()");
        _rejectPair(1, _pair(address(eurx), address(pathUsd), noCode), "PAIR_ORACLES[1]");
        _rejectPair(1, _pair(address(eurx), address(pathUsd), noDecimals), "PAIR_ORACLES[1]");
        _rejectPair(1, _pair(address(eurx), address(pathUsd), noPrice), "PAIR_ORACLES[1] has no latestPrice()");

        DeployManagedPool.PairConfig memory p = _pair(address(eurx), address(pathUsd), address(eurOracle));
        p.maxOracleAge = 0;
        _rejectPair(2, p, "PAIR_MAX_ORACLE_AGES[2]");
        p.maxOracleAge = 365 days + 1;
        _rejectPair(2, p, "PAIR_MAX_ORACLE_AGES[2]");
        p.maxOracleAge = 365 days;
        p.maxPriceDeviationBps = 101;
        _rejectPair(2, p, "PAIR_MAX_PRICE_DEVIATION_BPS[2]");

        // One oracle prices one base in one quote: a repeat, the same tokens the other way round (which would trade
        // at the inverse price) and other tokens on an earlier pair's oracle are all refused.
        config = _config(deployer);
        config.pairs[2] = config.pairs[0];
        _reject(config, "pair 2 reuses pair 0's oracle");
        _rejectPair(1, _pair(address(pathUsd), address(prime), address(primeOracle)), "pair 1 reuses pair 0's oracle");
        _rejectPair(2, _pair(address(eurx), address(prime), address(eurOracle)), "pair 2 reuses pair 1's oracle");
    }

    function test_refusesCounterfeitTokensBeforeDeployingOnBothChains() external {
        address counterfeit = address(new CounterfeitManagedDeploymentToken());
        for (uint256 chain; chain < 2; ++chain) {
            vm.chainId(chain == 0 ? MODERATO : MAINNET);
            for (uint256 side; side < 2; ++side) {
                DeployManagedPool.Config memory config = _config(chain == 0 ? deployer : owner);
                if (side == 0) config.pairs[1].base = counterfeit;
                else config.pairs[1].quote = counterfeit;
                uint64 nonce = vm.getNonce(deployer);
                _reject(
                    config,
                    side == 0 ? "PAIR_BASES[1] is not a factory TIP-20" : "PAIR_QUOTES[1] is not a factory TIP-20"
                );
                assertEq(vm.getNonce(deployer), nonce, "preflight must precede deployment");
                assertEq(_nextPool().code.length, 0);
            }
        }
    }

    function test_factoryRepliesFailClosedForEitherToken() external {
        bytes[] memory replies = new bytes[](5);
        replies[0] = ""; // Absent precompile / empty reply.
        replies[1] = hex"01";
        replies[2] = abi.encode(uint256(2)); // Not a canonical ABI true.
        replies[3] = abi.encode(false);
        replies[4] = abi.encode(true, uint256(0)); // Trailing data is not an exact factory reply.
        for (uint256 side; side < 2; ++side) {
            address token = side == 0 ? address(prime) : address(pathUsd);
            bytes memory callData = abi.encodeCall(ITIP20Factory.isTIP20, (token));
            string memory field =
                side == 0 ? "PAIR_BASES[0] is not a factory TIP-20" : "PAIR_QUOTES[0] is not a factory TIP-20";
            for (uint256 i; i < replies.length; ++i) {
                vm.mockCall(TIP20_FACTORY, callData, replies[i]);
                _reject(_config(deployer), field);
            }
            vm.mockCallRevert(TIP20_FACTORY, callData, hex"deadbeef");
            _reject(_config(deployer), field);
            // Restore this fixture token's exact admission on Tempo too (clearMockedCalls would remove it).
            vm.mockCall(TIP20_FACTORY, callData, abi.encode(true));
        }
    }

    function test_nativeFactoryTokensAndPathUsdPassOnBothChains() external {
        if (!nativeFactory) vm.skip(true);
        address token = IManagedDeploymentTokenFactory(TIP20_FACTORY)
            .createToken("Managed preflight", "MPT", "USD", TempoMainnet.PATH_USD, deployer, bytes32(uint256(6699)));
        assertTrue(ITIP20Factory(TIP20_FACTORY).isTIP20(token));
        for (uint256 chain; chain < 2; ++chain) {
            vm.chainId(chain == 0 ? MODERATO : MAINNET);
            DeployManagedPool.Config memory config = _config(chain == 0 ? deployer : owner);
            config.pairs = new DeployManagedPool.PairConfig[](1);
            config.pairs[0] = _pair(token, TempoMainnet.PATH_USD, address(primeOracle));
            script.setInput(config);
            DeployManagedPool.Deployment memory deployed = script.run();
            assertEq(deployed.pool.pair(0).base, token);
            assertEq(deployed.pool.pair(0).quote, TempoMainnet.PATH_USD);
            assertEq(deployed.pairsSent, chain == 0);
        }
    }

    function test_metadataGasBurnersFailClosedWithinBudget() external {
        for (uint256 i; i < 2; ++i) {
            bytes4 selector = i == 0 ? bytes4(keccak256("decimals()")) : IPriceOracle.latestPrice.selector;
            address target = address(new HostileDeploymentProbe(selector, 0, true, false));
            bytes memory data = i == 0
                ? abi.encodeCall(script.answersDecimals, (target))
                : abi.encodeCall(script.latestPrice, (target));
            uint256 before = gasleft();
            (bool ok, bytes memory answer) = address(script).staticcall{ gas: 500_000 }(data);
            assertLt(before - gasleft(), 250_000, "callee gas must be bounded");
            assertTrue(ok, "probe must retain gas to return a named refusal");
            assertEq(answer, i == 0 ? abi.encode(false) : abi.encode(false, uint256(0), uint256(0)));
        }
    }

    function test_hostileOracleProducesNamedPreflightRefusal() external {
        for (uint256 i; i < 2; ++i) {
            bytes4 selector = i == 0 ? bytes4(keccak256("decimals()")) : IPriceOracle.latestPrice.selector;
            address oracle = address(new HostileDeploymentProbe(selector, 0, true, false));
            DeployManagedPool.Config memory config = _config(deployer);
            config.pairs[0].oracle = oracle;
            script.setInput(config);
            uint64 nonce = vm.getNonce(deployer);
            (bool ok, bytes memory reason) = address(script).call{ gas: 1_000_000 }(abi.encodeCall(script.run, ()));
            assertFalse(ok);
            assertEq(
                reason,
                abi.encodeWithSelector(
                    DeployManagedPool.InvalidConfig.selector,
                    i == 0 ? "PAIR_ORACLES[0]" : "PAIR_ORACLES[0] has no latestPrice()"
                )
            );
            assertEq(vm.getNonce(deployer), nonce);
        }
    }

    function test_metadataOversizedRepliesNeverCopyTheWholeAnswer() external {
        for (uint256 i; i < 4; ++i) {
            bool decimals = i % 2 == 0;
            bytes4 selector = decimals ? bytes4(keccak256("decimals()")) : IPriceOracle.latestPrice.selector;
            address target = address(new HostileDeploymentProbe(selector, 262_144, false, i >= 2));
            uint256 before = gasleft();
            if (decimals) {
                assertFalse(script.answersDecimals(target));
            } else {
                (bool ok,,) = script.latestPrice(target);
                assertFalse(ok);
            }
            assertLt(before - gasleft(), 220_000, "callee work is capped; oversized returndata is never copied");
        }
    }

    function test_metadataProbesKeepExactLengthChecks() external {
        uint256[5] memory sizes = [uint256(0), 31, 33, 63, 65];
        for (uint256 i; i < sizes.length; ++i) {
            address target =
                address(new HostileDeploymentProbe(bytes4(keccak256("decimals()")), sizes[i], false, false));
            assertFalse(script.answersDecimals(target));
            target = address(new HostileDeploymentProbe(IPriceOracle.latestPrice.selector, sizes[i], false, false));
            (bool ok,,) = script.latestPrice(target);
            assertFalse(ok);
        }
        address canonical = address(new HostileDeploymentProbe(bytes4(keccak256("decimals()")), 32, false, false));
        assertTrue(script.answersDecimals(canonical));
        canonical = address(new HostileDeploymentProbe(IPriceOracle.latestPrice.selector, 64, false, false));
        (bool success, uint256 price, uint256 updatedAt) = script.latestPrice(canonical);
        assertTrue(success);
        assertEq(price, 6);
        assertEq(updatedAt, 0);
    }

    function test_nativePoliciesAdmitOnlyPoolAndOwnerWithSharedTokens() external {
        if (!nativeFactory) vm.skip(true);
        ITIP403Precompile registry = ITIP403Precompile(0x403c000000000000000000000000000000000000);
        address token = IManagedDeploymentTokenFactory(TIP20_FACTORY)
            .createToken("Shared policy", "SPOL", "USD", TempoMainnet.PATH_USD, address(this), bytes32(uint256(6729)));
        vm.expectCall(token, abi.encodeCall(IManagedDeploymentPolicyToken.transferPolicyId, ()), 2);
        for (uint256 chain; chain < 2; ++chain) {
            vm.chainId(chain == 0 ? MODERATO : MAINNET);
            DeployManagedPool.Config memory config = _config(chain == 0 ? deployer : owner);
            config.pairs = new DeployManagedPool.PairConfig[](2);
            config.pairs[0] = _pair(token, TempoMainnet.PATH_USD, address(primeOracle));
            config.pairs[1] = _pair(TempoMainnet.PATH_USD, token, address(eurOracle));
            uint64 senders = registry.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            uint64 recipients = registry.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            address predicted = _nextPool();
            registry.modifyPolicyWhitelist(senders, predicted, true);
            registry.modifyPolicyWhitelist(recipients, predicted, true);
            registry.modifyPolicyWhitelist(senders, config.owner, true);
            uint64 policy = registry.createCompoundPolicy(senders, recipients, 1);
            IManagedDeploymentPolicyToken(token).changeTransferPolicyId(policy);
            if (chain == 1) assertFalse(registry.isAuthorizedSender(policy, deployer));
            assertFalse(registry.isAuthorizedRecipient(policy, config.owner), "funding needs only sender access");
            script.setInput(config);
            DeployManagedPool.Deployment memory deployed = script.run();
            assertEq(address(deployed.pool), predicted);
            assertEq(deployed.pool.tokenPairCount(token), 2);
            assertEq(deployed.pairsSent, chain == 0);
        }
    }

    function test_nativeTransferPoliciesRefuseBeforeDeployment() external {
        if (!nativeFactory) vm.skip(true);
        ITIP403Precompile registry = ITIP403Precompile(0x403c000000000000000000000000000000000000);
        address token = IManagedDeploymentTokenFactory(TIP20_FACTORY)
            .createToken("Policy", "POL", "USD", TempoMainnet.PATH_USD, address(this), bytes32(uint256(6728)));
        for (uint256 chain; chain < 2; ++chain) {
            vm.chainId(chain == 0 ? MODERATO : MAINNET);
            for (uint256 denied; denied < 3; ++denied) {
                DeployManagedPool.Config memory config = _config(chain == 0 ? deployer : owner);
                config.pairs = new DeployManagedPool.PairConfig[](1);
                config.pairs[0] = _pair(token, TempoMainnet.PATH_USD, address(primeOracle));
                uint64 senders = registry.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
                uint64 recipients = registry.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
                address predicted = _nextPool();
                registry.modifyPolicyWhitelist(senders, predicted, denied != 0);
                registry.modifyPolicyWhitelist(recipients, predicted, denied != 1);
                registry.modifyPolicyWhitelist(senders, config.owner, denied != 2);
                uint64 policy = registry.createCompoundPolicy(senders, recipients, 1);
                IManagedDeploymentPolicyToken(token).changeTransferPolicyId(policy);
                assertEq(registry.isAuthorizedSender(policy, predicted), denied != 0);
                assertEq(registry.isAuthorizedRecipient(policy, predicted), denied != 1);
                assertEq(registry.isAuthorizedSender(policy, config.owner), denied != 2);
                script.setInput(config);
                uint64 nonce = vm.getNonce(deployer);
                vm.expectRevert(
                    abi.encodeWithSignature(
                        "TokenPolicyDenied(address,address,bool)",
                        token,
                        denied == 2 ? config.owner : predicted,
                        denied != 1
                    )
                );
                script.run();
                assertEq(vm.getNonce(deployer), nonce);
                assertEq(predicted.code.length, 0);
            }
        }
    }

    /// @dev What only the pool checks comes back from the simulation with the pool's own error, before any broadcast.
    function test_poolErrorsComeBackFromTheSimulation() external {
        DeployManagedPool.Config memory config = _config(deployer);
        // 18 + 60 - 0 = 78 decimals of price scale, above the 77 `DirectPropAMM` takes.
        MockOracle wide = new MockOracle(60, 1e60, block.timestamp);
        MockTIP20 zeroDecimals = new ManagedDeploymentMockToken("ZERO", 0);
        config.pairs[1] = _pair(address(eurx), address(zeroDecimals), address(wide));
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedDecimals.selector, 18, 0, 60));
        script.run();
    }

    /// @dev Without `--network tempo` the TIP-20 precompiles don't run, so pathUSD answers no `decimals()`: an address
    /// without code, or code without the getter.
    function test_refusesARunWithoutTheTip20Precompiles() external {
        script.setTip20Probe(makeAddr("noCode"));
        _reject(_config(deployer), "pathUSD has no decimals(): run with --network tempo");
        script.setTip20Probe(address(new NoDecimals()));
        _reject(_config(deployer), "pathUSD has no decimals(): run with --network tempo");
    }

    function test_readsTheEnvironment() external {
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("OWNER_ADDRESS", vm.toString(owner));
        vm.setEnv("PAIR_BASES", string.concat(vm.toString(address(prime)), ",", vm.toString(address(eurx))));
        vm.setEnv("PAIR_QUOTES", string.concat(vm.toString(address(pathUsd)), ",", vm.toString(address(pathUsd))));
        vm.setEnv(
            "PAIR_ORACLES", string.concat(vm.toString(address(primeOracle)), ",", vm.toString(address(eurOracle)))
        );
        vm.setEnv("PAIR_MAX_ORACLE_AGES", "90000,3600");
        vm.setEnv("PAIR_MAX_PRICE_DEVIATION_BPS", "50,25");
        DeployManagedPool.Config memory c = script.readEnvConfig();
        assertEq(c.deployer, deployer);
        assertEq(c.owner, owner);
        assertEq(c.pairs.length, 2);
        assertEq(c.pairs[1].base, address(eurx));
        assertEq(c.pairs[1].quote, address(pathUsd));
        assertEq(c.pairs[1].oracle, address(eurOracle));
        assertEq(c.pairs[1].maxOracleAge, 3600);
        assertEq(c.pairs[1].maxPriceDeviationBps, 25);

        vm.setEnv("PAIR_MAX_PRICE_DEVIATION_BPS", "50");
        vm.expectRevert(
            abi.encodeWithSelector(DeployManagedPool.InvalidConfig.selector, "PAIR_* lists need one entry per pair")
        );
        script.readEnvConfig();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Three pairs: PRIME/pathUSD, EURX/pathUSD (sharing pathUSD) and EURX/PRIME with the EUR oracle.
    function _config(address poolOwner) internal view returns (DeployManagedPool.Config memory config) {
        config.deployer = deployer;
        config.owner = poolOwner;
        config.pairs = new DeployManagedPool.PairConfig[](3);
        config.pairs[0] = _pair(address(prime), address(pathUsd), address(primeOracle));
        config.pairs[1] = _pair(address(eurx), address(pathUsd), address(eurOracle));
        config.pairs[2] = _pair(address(eurx), address(prime), address(eurPrimeOracle));
        config.pairs[2].maxOracleAge = 3600;
        config.pairs[2].maxPriceDeviationBps = 0;
    }

    function _pair(address base, address quote, address oracle)
        internal
        pure
        returns (DeployManagedPool.PairConfig memory)
    {
        return DeployManagedPool.PairConfig(base, quote, oracle, 90_000, 50);
    }

    function _assertDeployed(ManagedDirectPropAMM pool, DeployManagedPool.Config memory config) internal view {
        assertTrue(pool.paused());
        assertEq(pool.pairCount(), config.pairs.length);
        for (uint16 i; i < config.pairs.length; ++i) {
            IManagedDirectPropAMM.Pair memory info = pool.pair(i);
            assertEq(info.base, config.pairs[i].base);
            assertEq(info.quote, config.pairs[i].quote);
            assertEq(address(info.oracle), config.pairs[i].oracle);
            assertEq(info.maxOracleAge, config.pairs[i].maxOracleAge);
            assertEq(info.maxPriceDeviationBps, config.pairs[i].maxPriceDeviationBps);
            assertEq(uint8(info.access), uint8(IManagedDirectPropAMM.AccessMode.Closed));
        }
        assertEq(pool.tokenPairCount(address(prime)), 2);
        assertEq(pool.tokenPairCount(address(pathUsd)), 2);
        assertEq(pool.tokenPairCount(address(eurx)), 2);
        assertEq(pool.deniedCount(), 0);
    }

    function _nextPool() internal view returns (address) {
        return vm.computeCreateAddress(deployer, vm.getNonce(deployer));
    }

    function _reject(DeployManagedPool.Config memory config, string memory field) internal {
        script.setInput(config);
        vm.expectRevert(abi.encodeWithSelector(DeployManagedPool.InvalidConfig.selector, field));
        script.run();
    }

    function _rejectPair(uint256 index, DeployManagedPool.PairConfig memory p, string memory field) internal {
        DeployManagedPool.Config memory config = _config(deployer);
        config.pairs[index] = p;
        _reject(config, field);
    }
}
