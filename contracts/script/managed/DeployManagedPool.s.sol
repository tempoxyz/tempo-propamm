// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script, console2 } from "forge-std/Script.sol";

import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { TempoMainnet } from "../../src/TempoMainnet.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";
import { TIP20Factory } from "../../src/v2/libraries/TIP20Factory.sol";
import { ITIP403Registry } from "../../src/interfaces/ITIP403Registry.sol";
import { ITIP20 } from "../../src/interfaces/ITIP20.sol";

/// @notice The native TIP-20 transfer policy used to preflight funding and payouts.
interface IManagedPoolTransferPolicy {
    function transferPolicyId() external view returns (uint64);
}

/// @notice Deploys a `ManagedDirectPropAMM` on Tempo mainnet or Moderato with its pairs, every pair `Closed` and the
/// pool paused: nobody can trade until the owner registers sponsors or lists takers, funds it and opens each pair.
/// @dev One broadcast from `DEPLOYER_ADDRESS`: `new ManagedDirectPropAMM(OWNER_ADDRESS, address(0))`. The pool
/// holds no address registry: it pays no TIP-1022 virtual address. The pairs need the owner (`addPair`), and the
/// constructor takes none, since Tempo prices code at about 1,030 gas a byte, so the deploy transaction alone measures
/// about 13.0M gas with Solar (`contracts/test/fork/managed/ManagedDirectPropAMMGas.t.sol`) and each `addPair` 0.8M to 1.3M:
/// - when the owner is the deployer (a test pool on Moderato), the same broadcast also sends each `addPair`;
/// - otherwise the script runs each `addPair` as the owner in the simulation, checks the result, and prints it as
///   Safe-ready calldata for the owner to send. The deployer never holds the owner's power, and on mainnet it may hold
///   no role at all, as `DeployV2` requires.
/// Inputs: `DEPLOYER_ADDRESS`, `OWNER_ADDRESS`, and one comma-separated entry per pair, in pair
/// order, in `PAIR_BASES`, `PAIR_QUOTES`, `PAIR_ORACLES`, `PAIR_MAX_ORACLE_AGES` (seconds) and
/// `PAIR_MAX_PRICE_DEVIATION_BPS`. `contracts/script/managed/config/managed-pool.env.example` documents each. Every
/// postcondition gates the broadcast, and Forge sends only with `--broadcast`. Run with `--network tempo`: the pairs'
/// tokens are TIP-20 precompiles, whose `decimals()` `addPair` reads and whose balance deltas the postconditions check, and
/// Forge runs them only there. Both pair tokens must be initialized TIP-20s recognized by the canonical factory;
/// arbitrary token contracts are refused before deployment or preparation of owner calldata.
contract DeployManagedPool is Script {
    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);
    error UnexpectedDeploymentState(string field);
    error TokenPolicyDenied(address token, address account, bool sending);

    struct PairConfig {
        address base;
        address quote;
        address oracle;
        uint256 maxOracleAge;
        uint256 maxPriceDeviationBps;
    }

    struct Config {
        address deployer;
        address owner;
        PairConfig[] pairs;
    }

    struct Deployment {
        ManagedDirectPropAMM pool;
        /// @dev Whether the broadcast sent the `addPair` calls (the owner is the deployer). Otherwise `ownerCalls`
        /// holds them, run only in the simulation, for the owner to send.
        bool pairsSent;
        bytes[] ownerCalls;
    }

    uint256 internal constant TEMPO_MAINNET_CHAIN_ID = 4217;
    uint256 internal constant TEMPO_MODERATO_CHAIN_ID = 42431;
    /// @notice The most pairs one run adds. More can follow from the owner with `addPair`.
    uint256 public constant MAX_PAIRS = 16;
    /// @notice Maximum gas forwarded to each raw token or oracle metadata probe.
    uint256 public constant PROBE_GAS = 200_000;
    /// @notice Script-side limits, tighter than the pool's: a year of oracle age and 100 bps of anchor deviation.
    uint256 public constant MAX_MAX_ORACLE_AGE = 365 days;
    uint256 public constant MAX_MAX_PRICE_DEVIATION_BPS = 100;

    /// @notice Deploys the pool, adds or prepares its pairs, checks every postcondition and logs the next steps.
    function run() public returns (Deployment memory deployed) {
        if (block.chainid != TEMPO_MAINNET_CHAIN_ID && block.chainid != TEMPO_MODERATO_CHAIN_ID) {
            revert UnexpectedChain(block.chainid);
        }
        Config memory config = _readConfig();
        _preflight(config);

        // A predicted CREATE address can already hold unsolicited tokens. Deployment must leave those balances
        // unchanged, rather than requiring zero inventory (which anyone could defeat with a dust donation).
        address predictedPool = vm.computeCreateAddress(config.deployer, vm.getNonce(config.deployer));
        _checkTransferPolicies(config, predictedPool);
        _logConfig(config);
        uint256[] memory inventoryBefore = new uint256[](config.pairs.length * 2);
        for (uint256 i; i < config.pairs.length; ++i) {
            // forge-lint: disable-start(calls-loop)
            inventoryBefore[i * 2] = ITIP20(config.pairs[i].base).balanceOf(predictedPool);
            inventoryBefore[i * 2 + 1] = ITIP20(config.pairs[i].quote).balanceOf(predictedPool);
            // forge-lint: disable-end(calls-loop)
        }

        bool ownerSends = config.owner == config.deployer;
        deployed.ownerCalls = new bytes[](config.pairs.length);
        // The explicit sender must be the reviewed deployer, even if Forge has other signers available.
        vm.startBroadcast(config.deployer);
        deployed.pool = new ManagedDirectPropAMM(config.owner, address(0));
        if (ownerSends) _addPairs(deployed, config);
        vm.stopBroadcast();
        if (!ownerSends) {
            // Simulation only: the owner sends these from its Safe.
            vm.startPrank(config.owner);
            _addPairs(deployed, config);
            vm.stopPrank();
        }
        deployed.pairsSent = ownerSends;

        _checkDeployment(deployed, config, inventoryBefore);
        _logDeployment(deployed, config);
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory config) {
        config.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        config.owner = vm.envAddress("OWNER_ADDRESS");
        address[] memory bases = vm.envAddress("PAIR_BASES", ",");
        address[] memory quotes = vm.envAddress("PAIR_QUOTES", ",");
        address[] memory oracles = vm.envAddress("PAIR_ORACLES", ",");
        uint256[] memory ages = vm.envUint("PAIR_MAX_ORACLE_AGES", ",");
        uint256[] memory deviations = vm.envUint("PAIR_MAX_PRICE_DEVIATION_BPS", ",");
        uint256 count = bases.length;
        if (quotes.length != count || oracles.length != count || ages.length != count || deviations.length != count) {
            revert InvalidConfig("PAIR_* lists need one entry per pair");
        }
        config.pairs = new PairConfig[](count);
        for (uint256 i; i < count; ++i) {
            config.pairs[i] = PairConfig(bases[i], quotes[i], oracles[i], ages[i], deviations[i]);
        }
    }

    /// @dev The TIP-20 the preflight reads `decimals()` from to tell that the run has Tempo's precompiles (`--network
    /// tempo`): pathUSD. Test harnesses override this to run on mock tokens.
    function _tip20Probe() internal view virtual returns (address) {
        return TempoMainnet.PATH_USD;
    }

    function _addPairs(Deployment memory deployed, Config memory config) internal {
        for (uint256 i; i < config.pairs.length; ++i) {
            PairConfig memory p = config.pairs[i];
            bytes memory data = abi.encodeCall(
                IManagedDirectPropAMM.addPair,
                (p.base, p.quote, IPriceOracle(p.oracle), p.maxOracleAge, p.maxPriceDeviationBps)
            );
            deployed.ownerCalls[i] = data;
            // One `addPair` per configured pair, at most `MAX_PAIRS`, each checked below.
            // forge-lint: disable-start(calls-loop, require-revert-in-loop)
            uint16 pairIndex =
                deployed.pool.addPair(p.base, p.quote, IPriceOracle(p.oracle), p.maxOracleAge, p.maxPriceDeviationBps);
            if (pairIndex != i) revert UnexpectedDeploymentState("pair index");
            // forge-lint: disable-end(calls-loop, require-revert-in-loop)
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Preflight
    // ---------------------------------------------------------------------------------------------------------------

    function _preflight(Config memory config) internal view {
        // Forge runs the TIP-20 precompiles only under `--network tempo`; without it no pair token answers.
        if (!_answersDecimals(_tip20Probe())) {
            revert InvalidConfig("pathUSD has no decimals(): run with --network tempo");
        }
        _requireAccount(config.deployer, "DEPLOYER_ADDRESS");
        // Forge's default sender has no signer, so a run from it can't be the reviewed deployer.
        if (config.deployer == DEFAULT_SENDER) revert InvalidConfig("DEPLOYER_ADDRESS");
        _requireAccount(config.owner, "OWNER_ADDRESS");
        bool mainnet = block.chainid == TEMPO_MAINNET_CHAIN_ID;
        if (mainnet && config.deployer == config.owner) {
            revert InvalidConfig("deployer must hold no pool role on mainnet");
        }
        uint256 count = config.pairs.length;
        if (count == 0 || count > MAX_PAIRS) revert InvalidConfig("PAIR_* lists need 1 to 16 pairs");
        // A check of operator input before anything runs: any bad entry stops the whole run.
        for (uint256 i; i < count; ++i) {
            _checkPair(config.pairs[i], i);
            for (uint256 j; j < i; ++j) {
                // An oracle prices one base in one quote, so a second pair on it is mispriced: a repeat is redundant,
                // the same tokens the other way round trade at the inverse price, and other tokens at another
                // pair's price. The pool can't tell, so the script refuses any oracle an earlier pair uses.
                if (config.pairs[j].oracle == config.pairs[i].oracle) {
                    string memory message = string.concat("pair ", Strings.toString(i), " reuses pair ");
                    // forge-lint: disable-next-line(require-revert-in-loop)
                    revert InvalidConfig(string.concat(message, Strings.toString(j), "'s oracle"));
                }
            }
        }
    }

    /// @dev Raw probes, so a token or oracle that doesn't answer, or answers oddly, is refused by name instead of
    /// reverting the run with whatever it returned. The pool runs its own checks (`UnsupportedDecimals` and the
    /// rest) when the simulation adds the pair.
    function _checkPair(PairConfig memory p, uint256 i) internal view {
        // Called once per configured pair: any bad entry stops the whole run.
        // forge-lint: disable-start(require-revert-in-loop)
        string memory n = string.concat("[", Strings.toString(i), "]");
        if (p.base == address(0) || p.base.code.length == 0) revert InvalidConfig(string.concat("PAIR_BASES", n));
        if (p.quote == address(0) || p.quote.code.length == 0 || p.quote == p.base) {
            revert InvalidConfig(string.concat("PAIR_QUOTES", n));
        }
        if (!_answersDecimals(p.base)) revert InvalidConfig(string.concat("PAIR_BASES", n, " has no decimals()"));
        if (!_answersDecimals(p.quote)) revert InvalidConfig(string.concat("PAIR_QUOTES", n, " has no decimals()"));
        // Metadata and balance deltas supplied by arbitrary token code cannot prove payment. Both supported chains
        // use the canonical factory, whose initialized-token check also rejects unused reserved-prefix addresses.
        if (!TIP20Factory.isTIP20(p.base)) {
            revert InvalidConfig(string.concat("PAIR_BASES", n, " is not a factory TIP-20"));
        }
        if (!TIP20Factory.isTIP20(p.quote)) {
            revert InvalidConfig(string.concat("PAIR_QUOTES", n, " is not a factory TIP-20"));
        }
        if (p.oracle == address(0) || p.oracle.code.length == 0 || !_answersDecimals(p.oracle)) {
            revert InvalidConfig(string.concat("PAIR_ORACLES", n));
        }
        if (p.maxOracleAge == 0 || p.maxOracleAge > MAX_MAX_ORACLE_AGE) {
            revert InvalidConfig(string.concat("PAIR_MAX_ORACLE_AGES", n));
        }
        if (p.maxPriceDeviationBps > MAX_MAX_PRICE_DEVIATION_BPS) {
            revert InvalidConfig(string.concat("PAIR_MAX_PRICE_DEVIATION_BPS", n));
        }
        (bool ok, uint256 price, uint256 updatedAt) = _latestPrice(p.oracle);
        if (!ok) revert InvalidConfig(string.concat("PAIR_ORACLES", n, " has no latestPrice()"));
        // `addPair` needs no fresh price; opening the pair (`setPairAccess`) does.
        if (price == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > p.maxOracleAge) {
            console2.log(
                string.concat(
                    "WARNING: pair ", Strings.toString(i), "'s oracle is not fresh now: opening it will revert"
                )
            );
        }
        // forge-lint: disable-end(require-revert-in-loop)
    }

    /// @dev A shared token is checked once. The owner is the funder because `fund` pulls only from its owner caller.
    function _checkTransferPolicies(Config memory config, address predictedPool) internal view {
        ITIP403Registry registry = ITIP403Registry(TempoMainnet.TIP403_REGISTRY);
        address[] memory tokens = new address[](config.pairs.length * 2);
        uint256 count;
        for (uint256 i; i < config.pairs.length * 2; ++i) {
            address token = i % 2 == 0 ? config.pairs[i / 2].base : config.pairs[i / 2].quote;
            bool seen;
            for (uint256 j; j < count; ++j) {
                if (tokens[j] == token) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            tokens[count++] = token;
            // Only factory-authenticated native TIP-20s reach this check, against the canonical policy registry.
            // forge-lint: disable-start(calls-loop, require-revert-in-loop)
            uint64 policyId = IManagedPoolTransferPolicy(token).transferPolicyId();
            if (!registry.isAuthorizedSender(policyId, predictedPool)) {
                revert TokenPolicyDenied(token, predictedPool, true);
            }
            if (!registry.isAuthorizedRecipient(policyId, predictedPool)) {
                revert TokenPolicyDenied(token, predictedPool, false);
            }
            if (!registry.isAuthorizedSender(policyId, config.owner)) {
                revert TokenPolicyDenied(token, config.owner, true);
            }
            // forge-lint: disable-end(calls-loop, require-revert-in-loop)
        }
    }

    /// @dev Signing roles must be actual accounts: not zero, and not a TIP-1022 virtual address (bytes 4 to 13 all
    /// `0xFD`), which can never send a transaction.
    function _requireAccount(address account, string memory field) internal pure {
        if (account == address(0) || _isVirtual(account)) revert InvalidConfig(field);
    }

    function _isVirtual(address account) internal pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == 0xFDFDFDFDFDFDFDFDFDFD;
    }

    function _answersDecimals(address target) internal view returns (bool) {
        (bool ok, bytes memory answer) = _readMetadata(target, abi.encodeWithSelector(ITIP20.decimals.selector), 32);
        return ok && abi.decode(answer, (uint256)) <= type(uint8).max;
    }

    function _latestPrice(address oracle) internal view returns (bool ok, uint256 price, uint256 updatedAt) {
        (bool success, bytes memory answer) = _readMetadata(oracle, abi.encodeCall(IPriceOracle.latestPrice, ()), 64);
        if (!success) return (false, 0, 0);
        (price, updatedAt) = abi.decode(answer, (uint256, uint256));
        ok = true;
    }

    /// @dev Both the callee's gas and the copied answer are bounded; trailing bytes still invalidate the entire reply.
    function _readMetadata(address target, bytes memory data, uint256 size)
        internal
        view
        returns (bool ok, bytes memory answer)
    {
        answer = new bytes(size);
        uint256 gasLimit = PROBE_GAS;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(data, 32), mload(data), add(answer, 32), size)
            ok := and(ok, eq(returndatasize(), size))
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Postconditions
    // ---------------------------------------------------------------------------------------------------------------

    function _checkDeployment(Deployment memory deployed, Config memory config, uint256[] memory inventoryBefore)
        internal
        view
    {
        ManagedDirectPropAMM pool = deployed.pool;
        if (pool.owner() != config.owner || pool.pendingOwner() != address(0)) {
            revert UnexpectedDeploymentState("roles");
        }
        if (!pool.paused()) revert UnexpectedDeploymentState("paused");
        if (pool.deniedCount() != 0) {
            revert UnexpectedDeploymentState("access");
        }
        uint256 count = config.pairs.length;
        if (pool.pairCount() != count) revert UnexpectedDeploymentState("pair count");
        // Read-only checks of the pairs this run added, at most `MAX_PAIRS`.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        for (uint256 i; i < count; ++i) {
            PairConfig memory p = config.pairs[i];
            // `i` is below `MAX_PAIRS`.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16 pairIndex = uint16(i);
            IManagedDirectPropAMM.Pair memory info = pool.pair(pairIndex);
            if (
                info.base != p.base || info.quote != p.quote || address(info.oracle) != p.oracle
                    || info.maxOracleAge != p.maxOracleAge || info.maxPriceDeviationBps != p.maxPriceDeviationBps
                    || info.baseDecimals != ITIP20(p.base).decimals()
                    || info.quoteDecimals != ITIP20(p.quote).decimals()
                    || info.oracleDecimals != IPriceOracle(p.oracle).decimals()
            ) revert UnexpectedDeploymentState(string.concat("pair ", Strings.toString(i)));
            if (info.access != IManagedDirectPropAMM.AccessMode.Closed) {
                revert UnexpectedDeploymentState(string.concat("pair ", Strings.toString(i), " is not Closed"));
            }
            if (pool.priceAnchor(pairIndex, true) != 0 || pool.priceAnchor(pairIndex, false) != 0) {
                revert UnexpectedDeploymentState(string.concat("pair ", Strings.toString(i), " anchors"));
            }
            if (
                pool.tokenPairCount(p.base) != _uses(config, p.base)
                    || pool.tokenPairCount(p.quote) != _uses(config, p.quote)
            ) {
                revert UnexpectedDeploymentState("token pair count");
            }
            if (
                ITIP20(p.base).balanceOf(address(pool)) != inventoryBefore[i * 2]
                    || ITIP20(p.quote).balanceOf(address(pool)) != inventoryBefore[i * 2 + 1]
            ) {
                revert UnexpectedDeploymentState("inventory");
            }
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
        // `count` is at most `MAX_PAIRS`.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (pool.pair(uint16(count)).access != IManagedDirectPropAMM.AccessMode.None) {
            revert UnexpectedDeploymentState("extra pair");
        }
    }

    /// @dev How many configured pairs use `token`, as base or quote.
    function _uses(Config memory config, address token) internal pure returns (uint256 uses) {
        for (uint256 i; i < config.pairs.length; ++i) {
            if (config.pairs[i].base == token || config.pairs[i].quote == token) ++uses;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Logs
    // ---------------------------------------------------------------------------------------------------------------

    function _logConfig(Config memory config) internal view {
        console2.log("Chain id", block.chainid);
        console2.log("Deployer", config.deployer);
        console2.log("Owner", config.owner);
        console2.log("Pair indexes below are provisional: mined PairAdded events assign indexes.");
        console2.log(
            "Before access changes, bind the mined index to reviewed EXPECTED_BASE/EXPECTED_QUOTE/EXPECTED_ORACLE."
        );
        for (uint256 i; i < config.pairs.length; ++i) {
            PairConfig memory p = config.pairs[i];
            console2.log(string.concat("Pair ", Strings.toString(i)));
            console2.log("  base", p.base);
            console2.log("  quote", p.quote);
            console2.log("  oracle", p.oracle);
            console2.log("  max oracle age (s) / deviation (bps)", p.maxOracleAge, p.maxPriceDeviationBps);
        }
    }

    function _logDeployment(Deployment memory deployed, Config memory config) internal view {
        address pool = address(deployed.pool);
        console2.log("ManagedDirectPropAMM", pool);
        console2.log("Paused, every pair Closed, no sponsor, member or denial; no inventory moved");
        if (!deployed.pairsSent) {
            console2.log("REQUIRED: the owner adds the pairs. From OWNER_ADDRESS, send each in order:");
            for (uint256 i; i < deployed.ownerCalls.length; ++i) {
                console2.log(
                    string.concat("Safe transaction ", Strings.toString(i + 1), ": addPair, pair ", Strings.toString(i))
                );
                console2.log("  chain id", block.chainid);
                console2.log("  from", config.owner);
                console2.log("  to", pool);
                console2.log("  value 0");
                console2.log("  data");
                console2.logBytes(deployed.ownerCalls[i]);
            }
        }
        console2.log("Next, as the owner (contracts/script/managed/ManagedPoolAccess.s.sol prints each call):");
        console2.log("  1. register sponsors (ADD_SPONSOR, ADMIT) and list takers (LIST); sponsors list their own");
        console2.log("  2. fund(token, amount, memo) for each token, after approving the pool");
        console2.log("  3. open each pair: setPairAccess(pairIndex, Listed) (PAIR_ACCESS), which sets its anchors");
        console2.log("  4. unpause()");
    }
}
