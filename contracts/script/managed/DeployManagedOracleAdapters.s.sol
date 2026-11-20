// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script, console2 } from "forge-std/Script.sol";

import { Chainlink18To8PriceOracleAdapter } from "../../src/Chainlink18To8PriceOracleAdapter.sol";
import { ChainlinkPriceOracleAdapter } from "../../src/ChainlinkPriceOracleAdapter.sol";
import { OndoUSDYPriceOracleAdapter } from "../../src/OndoUSDYPriceOracleAdapter.sol";
import { TempoMainnet } from "../../src/TempoMainnet.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IOndoUSDYOracleWrapper } from "../../src/interfaces/IOndoUSDYOracle.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";

/// @dev The immutable source getter of each adapter kind: what `verify` reads from a mined adapter.
interface IPriceAdapterSource {
    function feed() external view returns (address);
    function wrapper() external view returns (address);
}

/// @notice Deploys the price adapters a `ManagedDirectPropAMM`'s pairs read, and nothing else: no pool, no role, no
/// token. Each adapter is immutable and ownerless, so the deployer keeps no power over it. The pool's owner then
/// passes the addresses to `addPair` (`DeployManagedPool`'s `PAIR_ORACLES`, which `verify` prints).
/// @dev `run` is one broadcast from `DEPLOYER_ADDRESS`: one CREATE per entry, in order. `verify` sends nothing: after
/// inclusion it holds the mined adapters in `ORACLE_ADAPTERS` to the same inputs. Inputs, one entry per adapter:
/// - `ORACLE_KINDS`, comma-separated: `CHAINLINK` (`ChainlinkPriceOracleAdapter`: the feed's own decimals),
///   `CHAINLINK_18_TO_8` (`Chainlink18To8PriceOracleAdapter`: an 18-decimal feed read at 8 decimals, rounded down) or
///   `ONDO_USDY` (`OndoUSDYPriceOracleAdapter`: Ondo's USDY oracle wrapper, 18 decimals);
/// - `ORACLE_SOURCES`, comma-separated: the Chainlink AggregatorV3 feed, or Ondo's wrapper (on mainnet only
///   `TempoMainnet.USDY_ORACLE_WRAPPER`);
/// - `ORACLE_SOURCE_DESCRIPTIONS_FILE`: the path of a text file under `deployments/` with one line per adapter, in
///   order: the feed's exact `description()`, reviewed with the feed's operator, or `-` for `ONDO_USDY`, whose
///   wrapper has none. The file is read as data and never by a shell, so a description may hold any character
///   except a line break;
/// - `ORACLE_DECIMALS`, comma-separated: the `decimals()` the adapter must answer. A managed pair fixes its oracle's
///   decimals when it is added (`setOracle` refuses another: `OracleDecimalsChanged`), so this is the pair's price
///   precision for good;
/// - `ORACLE_MAX_AGES`, comma-separated seconds: the `maxOracleAge` planned for the pair. The source must hold a
///   positive observation that fresh now, or the run stops: an adapter over a dead source is never deployed;
/// - `ORACLE_REFERENCES`, comma-separated: an existing `IPriceOracle` the new adapter must agree with now, or the zero
///   address for none. For a pair that replaces a live pool, name that pool's `oracle()`: the two must report the same
///   observation time and the same price at the coarser of their precisions, so the new pair starts on the price the
///   old pool trades at.
/// Several entries may name one source, so that two pairs on one feed get an adapter each: `DeployManagedPool`
/// refuses an oracle address a second pair of its run names. The pool itself does not: before a later `addPair` or
/// `setOracle`, compare the oracle with every live `pair(i).oracle`. Every check gates the broadcast, and Forge sends
/// only with `--broadcast`. Decimals are precision, never a currency conversion: the reviewed description is what says
/// a feed prices the pair's base in its quote.
/// A `CHAINLINK` adapter reads its feed's decimals when its CREATE is mined, after the simulation that checked them,
/// so `run` proves nothing about the mined adapter: `verify` does, and only it prints `PAIR_ORACLES`.
contract DeployManagedOracleAdapters is Script {
    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);
    error InvalidObservation(address source, uint256 price, uint256 updatedAt, uint256 maxOracleAge);
    error ReferenceMismatch(
        address baseline, uint256 price, uint256 updatedAt, uint256 referencePrice, uint256 referenceUpdatedAt
    );
    error UnexpectedDeploymentState(string field);

    /// @dev 0 is unset and never a real kind (the repository's zero convention).
    enum Kind {
        None,
        Chainlink,
        Chainlink18To8,
        OndoUsdy
    }

    struct AdapterConfig {
        Kind kind;
        address source;
        string description;
        uint8 decimals;
        uint256 maxOracleAge;
        address baseline;
    }

    struct Config {
        address deployer;
        AdapterConfig[] adapters;
    }

    uint256 internal constant TEMPO_MAINNET_CHAIN_ID = 4217;
    uint256 internal constant TEMPO_MODERATO_CHAIN_ID = 42431;
    /// @notice The most adapters one run deploys: `DeployManagedPool`'s pair limit.
    uint256 public constant MAX_ADAPTERS = 16;
    /// @notice `DeployManagedPool`'s limit on a pair's oracle age.
    uint256 public constant MAX_MAX_ORACLE_AGE = 365 days;
    /// @dev The descriptions file's line for a source without a description.
    string internal constant NO_DESCRIPTION = "-";

    /// @notice Checks every input, deploys the adapters in order, checks each and logs `verify`'s `ORACLE_ADAPTERS`.
    function run() public returns (address[] memory adapters) {
        if (block.chainid != TEMPO_MAINNET_CHAIN_ID && block.chainid != TEMPO_MODERATO_CHAIN_ID) {
            revert UnexpectedChain(block.chainid);
        }
        Config memory config = _readConfig();
        uint256 count = _checkInputs(config);
        _logConfig(config);

        // Local-only probes run each adapter's own validation against its source before anything is sent. They are
        // created before the broadcast starts, by this script, so they consume none of the deployer's nonces.
        uint256[] memory prices = new uint256[](count);
        uint256[] memory times = new uint256[](count);
        // One deployment per configured adapter is the script's whole job; any failure stops the run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        for (uint256 i; i < count; ++i) {
            AdapterConfig memory a = config.adapters[i];
            (prices[i], times[i]) = _checkObservation(_deploy(a), a, i);
        }

        uint64 nonce = vm.getNonce(config.deployer);
        adapters = new address[](count);
        // The explicit sender must be the reviewed deployer, even if Forge has other signers available.
        vm.startBroadcast(config.deployer);
        for (uint256 i; i < count; ++i) {
            adapters[i] = address(_deploy(config.adapters[i]));
        }
        vm.stopBroadcast();

        for (uint256 i; i < count; ++i) {
            // `i` is below `MAX_ADAPTERS`.
            // forge-lint: disable-next-line(unsafe-typecast)
            address predicted = vm.computeCreateAddress(config.deployer, nonce + uint64(i));
            _checkDeployment(adapters[i], predicted, config.adapters[i], prices[i], times[i], i);
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
        _logDeployment(adapters, config, prices, times);
    }

    /// @notice After inclusion: holds the mined adapters in `ORACLE_ADAPTERS`, in the run's order, to the run's inputs
    /// and logs the pool's `PAIR_ORACLES`. Sends nothing.
    /// @dev Each adapter must read the reviewed source, answer the reviewed decimals and report the observation a
    /// fresh local probe of the same kind reports now. That compares what the adapter answers, not its code or who
    /// deployed it: take the addresses from the deployer's own receipts.
    function verify() public returns (address[] memory adapters) {
        if (block.chainid != TEMPO_MAINNET_CHAIN_ID && block.chainid != TEMPO_MODERATO_CHAIN_ID) {
            revert UnexpectedChain(block.chainid);
        }
        Config memory config = _readConfig();
        uint256 count = _checkInputs(config);
        adapters = _readAdapters();
        if (adapters.length != count) revert InvalidConfig("ORACLE_ADAPTERS needs one entry per adapter");
        // One check per configured adapter is the entry point's whole job; any failure stops the run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        for (uint256 i; i < count; ++i) {
            for (uint256 j; j < i; ++j) {
                if (adapters[j] == adapters[i]) revert InvalidConfig(_field("ORACLE_ADAPTERS", i));
            }
            AdapterConfig memory a = config.adapters[i];
            // The probe is local and never broadcast.
            (uint256 price, uint256 updatedAt) = _checkObservation(_deploy(a), a, i);
            _checkMined(adapters[i], a, price, updatedAt, i);
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
        _logVerified(adapters, config);
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readAdapters() internal view virtual returns (address[] memory) {
        return vm.envAddress("ORACLE_ADAPTERS", ",");
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory config) {
        config.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        string[] memory kinds = vm.envString("ORACLE_KINDS", ",");
        address[] memory sources = vm.envAddress("ORACLE_SOURCES", ",");
        string[] memory descriptions = _readDescriptions(vm.envString("ORACLE_SOURCE_DESCRIPTIONS_FILE"));
        uint256[] memory decimals = vm.envUint("ORACLE_DECIMALS", ",");
        uint256[] memory ages = vm.envUint("ORACLE_MAX_AGES", ",");
        address[] memory references = vm.envAddress("ORACLE_REFERENCES", ",");
        uint256 count = kinds.length;
        if (
            sources.length != count || descriptions.length != count || decimals.length != count || ages.length != count
                || references.length != count
        ) revert InvalidConfig("ORACLE_* lists need one entry per adapter");
        config.adapters = new AdapterConfig[](count);
        for (uint256 i; i < count; ++i) {
            // A malformed list entry stops the whole run.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (decimals[i] > type(uint8).max) revert InvalidConfig(_field("ORACLE_DECIMALS", i));
            config.adapters[i] = AdapterConfig({
                kind: _parseKind(kinds[i], i),
                source: sources[i],
                description: descriptions[i],
                // Checked above.
                // forge-lint: disable-next-line(unsafe-typecast)
                decimals: uint8(decimals[i]),
                maxOracleAge: ages[i],
                baseline: references[i]
            });
        }
    }

    /// @dev One description per line, in adapter order. Forge reads the file as bytes: nothing in it is evaluated,
    /// which a shell does to a value in a sourced env file. A final newline and carriage returns are dropped.
    function _readDescriptions(string memory path) internal view returns (string[] memory lines) {
        string memory text;
        try vm.readFile(path) returns (string memory content) {
            text = content;
        } catch {
            revert InvalidConfig("ORACLE_SOURCE_DESCRIPTIONS_FILE is unreadable: keep it under deployments/");
        }
        string[] memory parts = vm.split(vm.replace(text, "\r", ""), "\n");
        uint256 count = parts.length;
        if (count != 0 && bytes(parts[count - 1]).length == 0) --count;
        lines = new string[](count);
        for (uint256 i; i < count; ++i) {
            lines[i] = parts[i];
        }
    }

    function _parseKind(string memory kind, uint256 i) internal pure returns (Kind) {
        bytes32 hash = keccak256(bytes(kind));
        if (hash == keccak256("CHAINLINK")) return Kind.Chainlink;
        if (hash == keccak256("CHAINLINK_18_TO_8")) return Kind.Chainlink18To8;
        if (hash == keccak256("ONDO_USDY")) return Kind.OndoUsdy;
        // Runs once per configured entry, from a loop: a malformed entry stops the whole run.
        // forge-lint: disable-next-line(require-revert-in-loop)
        revert InvalidConfig(_field("ORACLE_KINDS", i));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Preflight
    // ---------------------------------------------------------------------------------------------------------------

    function _checkInputs(Config memory config) internal view returns (uint256 count) {
        address deployer = config.deployer;
        // A real signing account: not zero, not Forge's keyless default sender, not a TIP-1022 virtual address.
        if (deployer == address(0) || deployer == DEFAULT_SENDER || _isVirtual(deployer)) {
            revert InvalidConfig("DEPLOYER_ADDRESS");
        }
        count = config.adapters.length;
        if (count == 0 || count > MAX_ADAPTERS) revert InvalidConfig("ORACLE_* lists need 1 to 16 adapters");
        // A check of operator input before anything runs: any bad entry stops the whole run.
        for (uint256 i; i < count; ++i) {
            _checkAdapter(config.adapters[i], i);
        }
    }

    function _checkAdapter(AdapterConfig memory a, uint256 i) internal view {
        // Runs once per configured entry, from a loop: any bad entry stops the whole run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        if (a.kind == Kind.None) revert InvalidConfig(_field("ORACLE_KINDS", i));
        if (a.source == address(0) || a.source.code.length == 0) revert InvalidConfig(_field("ORACLE_SOURCES", i));
        if (a.maxOracleAge == 0 || a.maxOracleAge > MAX_MAX_ORACLE_AGE) {
            revert InvalidConfig(_field("ORACLE_MAX_AGES", i));
        }
        if (a.baseline != address(0) && a.baseline.code.length == 0) {
            revert InvalidConfig(_field("ORACLE_REFERENCES", i));
        }
        bool described = keccak256(bytes(a.description)) != keccak256(bytes(NO_DESCRIPTION));
        if (a.kind == Kind.OndoUsdy) {
            if (block.chainid == TEMPO_MAINNET_CHAIN_ID && a.source != TempoMainnet.USDY_ORACLE_WRAPPER) {
                revert InvalidConfig(string.concat(_field("ORACLE_SOURCES", i), " is not Ondo's USDY wrapper"));
            }
            if (described) {
                revert InvalidConfig(string.concat(_field("ORACLE_SOURCE_DESCRIPTIONS_FILE", i), " must be -"));
            }
            if (a.decimals != 18) revert InvalidConfig(string.concat(_field("ORACLE_DECIMALS", i), " must be 18"));
            return;
        }
        if (!described || bytes(a.description).length == 0) {
            revert InvalidConfig(_field("ORACLE_SOURCE_DESCRIPTIONS_FILE", i));
        }
        // The feed is operator input, so a missing or odd answer is refused by name, not with whatever it returned.
        IAggregatorV3 feed = IAggregatorV3(a.source);
        try feed.description() returns (string memory actual) {
            if (keccak256(bytes(actual)) != keccak256(bytes(a.description))) {
                revert InvalidConfig(string.concat(
                        _field("ORACLE_SOURCE_DESCRIPTIONS_FILE", i), ": the feed says \"", actual, "\""
                    ));
            }
        } catch {
            revert InvalidConfig(string.concat(_field("ORACLE_SOURCES", i), " has no description()"));
        }
        uint8 feedDecimals;
        try feed.decimals() returns (uint8 actual) {
            feedDecimals = actual;
        } catch {
            revert InvalidConfig(string.concat(_field("ORACLE_SOURCES", i), " has no decimals()"));
        }
        if (a.kind == Kind.Chainlink18To8) {
            if (feedDecimals != 18) {
                revert InvalidConfig(string.concat(_field("ORACLE_SOURCES", i), " is not an 18-decimal feed"));
            }
            if (a.decimals != 8) revert InvalidConfig(string.concat(_field("ORACLE_DECIMALS", i), " must be 8"));
        } else if (a.decimals != feedDecimals) {
            revert InvalidConfig(string.concat(
                    _field("ORACLE_DECIMALS", i), ": the feed has ", Strings.toString(feedDecimals)
                ));
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    /// @dev The probe's observation must be positive and fresh under the pair's planned age, and agree with the
    /// reference when one is named. Returns it for the postconditions: the broadcast adapter must read the same.
    function _checkObservation(IPriceOracle probe, AdapterConfig memory a, uint256 i)
        internal
        view
        returns (uint256 price, uint256 updatedAt)
    {
        // Runs once per configured entry, from a loop: any bad entry stops the whole run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        if (probe.decimals() != a.decimals) revert InvalidConfig(_field("ORACLE_DECIMALS", i));
        (price, updatedAt) = probe.latestPrice();
        if (price == 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > a.maxOracleAge)
        {
            revert InvalidObservation(a.source, price, updatedAt, a.maxOracleAge);
        }
        if (a.baseline == address(0)) return (price, updatedAt);

        IPriceOracle baseline = IPriceOracle(a.baseline);
        uint8 referenceDecimals;
        try baseline.decimals() returns (uint8 actual) {
            referenceDecimals = actual;
        } catch {
            revert InvalidConfig(string.concat(_field("ORACLE_REFERENCES", i), " has no decimals()"));
        }
        uint256 referencePrice;
        uint256 referenceUpdatedAt;
        try baseline.latestPrice() returns (uint256 p, uint256 t) {
            (referencePrice, referenceUpdatedAt) = (p, t);
        } catch {
            revert InvalidConfig(string.concat(_field("ORACLE_REFERENCES", i), " has no latestPrice()"));
        }
        // Compare at the coarser precision, rounding the finer price down as the 18-to-8 adapter does. Past 77
        // digits of difference the scale itself overflows, and no two real prices compare.
        uint256 gap = a.decimals > referenceDecimals ? a.decimals - referenceDecimals : referenceDecimals - a.decimals;
        if (gap > 77) revert InvalidConfig(_field("ORACLE_REFERENCES", i));
        uint256 scale = 10 ** gap;
        bool same = a.decimals > referenceDecimals ? price / scale == referencePrice : price == referencePrice / scale;
        if (!same || referencePrice == 0 || updatedAt != referenceUpdatedAt) {
            revert ReferenceMismatch(a.baseline, price, updatedAt, referencePrice, referenceUpdatedAt);
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    function _deploy(AdapterConfig memory a) internal returns (IPriceOracle) {
        // One deployment per configured adapter is the script's whole job.
        // forge-lint: disable-start(calls-loop)
        if (a.kind == Kind.Chainlink) return new ChainlinkPriceOracleAdapter(IAggregatorV3(a.source));
        if (a.kind == Kind.Chainlink18To8) return new Chainlink18To8PriceOracleAdapter(IAggregatorV3(a.source));
        return new OndoUSDYPriceOracleAdapter(IOndoUSDYOracleWrapper(a.source));
        // forge-lint: disable-end(calls-loop)
    }

    function _isVirtual(address account) internal pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == 0xFDFDFDFDFDFDFDFDFDFD;
    }

    function _field(string memory name, uint256 i) internal pure returns (string memory) {
        return string.concat(name, "[", Strings.toString(i), "]");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Postconditions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The adapter sits at the deployer's next CREATE address, reads the reviewed source and answers the reviewed
    /// decimals and the probe's observation, in the same block.
    function _checkDeployment(
        address adapter,
        address predicted,
        AdapterConfig memory a,
        uint256 price,
        uint256 updatedAt,
        uint256 i
    ) internal view {
        if (adapter != predicted) {
            // Runs once per configured entry, from a loop: any bad entry stops the whole run.
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert UnexpectedDeploymentState(string.concat("adapter ", Strings.toString(i), " address"));
        }
        _checkMined(adapter, a, price, updatedAt, i);
    }

    /// @dev The adapter reads the reviewed source and answers the reviewed decimals and the probe's observation. In
    /// `verify` the address is operator input, so every read is a raw call: a target without the function, or with
    /// another answer shape, is refused by name. A `CHAINLINK` adapter whose feed has since changed its decimals
    /// fails here on its observation (`FeedDecimalsChanged`).
    function _checkMined(address adapter, AdapterConfig memory a, uint256 price, uint256 updatedAt, uint256 i)
        internal
        view
    {
        // Runs once per configured entry, from a loop: any bad entry stops the whole run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        string memory n = string.concat("adapter ", Strings.toString(i));
        if (adapter.code.length == 0) revert UnexpectedDeploymentState(string.concat(n, " address"));
        (bool ok, bytes memory answer) = adapter.staticcall(
            a.kind == Kind.OndoUsdy
                ? abi.encodeCall(IPriceAdapterSource.wrapper, ())
                : abi.encodeCall(IPriceAdapterSource.feed, ())
        );
        if (!ok || answer.length != 32 || abi.decode(answer, (uint256)) != uint256(uint160(a.source))) {
            revert UnexpectedDeploymentState(string.concat(n, " source"));
        }
        (ok, answer) = adapter.staticcall(abi.encodeCall(IPriceOracle.decimals, ()));
        if (!ok || answer.length != 32 || abi.decode(answer, (uint256)) != a.decimals) {
            revert UnexpectedDeploymentState(string.concat(n, " decimals"));
        }
        (ok, answer) = adapter.staticcall(abi.encodeCall(IPriceOracle.latestPrice, ()));
        if (!ok || answer.length != 64) revert UnexpectedDeploymentState(string.concat(n, " observation"));
        (uint256 actualPrice, uint256 actualUpdatedAt) = abi.decode(answer, (uint256, uint256));
        if (actualPrice != price || actualUpdatedAt != updatedAt) {
            revert UnexpectedDeploymentState(string.concat(n, " observation"));
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Logs
    // ---------------------------------------------------------------------------------------------------------------

    function _kindName(Kind kind) internal pure returns (string memory) {
        if (kind == Kind.Chainlink) return "ChainlinkPriceOracleAdapter";
        if (kind == Kind.Chainlink18To8) return "Chainlink18To8PriceOracleAdapter";
        return "OndoUSDYPriceOracleAdapter";
    }

    function _logConfig(Config memory config) internal view {
        console2.log("Chain id", block.chainid);
        console2.log("Deployer", config.deployer);
        for (uint256 i; i < config.adapters.length; ++i) {
            AdapterConfig memory a = config.adapters[i];
            console2.log(string.concat("Adapter ", Strings.toString(i), ": ", _kindName(a.kind)));
            console2.log("  source", a.source);
            console2.log(string.concat("  source description ", a.description));
            console2.log("  decimals / max oracle age (s)", a.decimals, a.maxOracleAge);
            if (a.baseline != address(0)) console2.log("  must agree with", a.baseline);
        }
    }

    function _logDeployment(
        address[] memory adapters,
        Config memory config,
        uint256[] memory prices,
        uint256[] memory times
    ) internal pure {
        string memory list;
        for (uint256 i; i < adapters.length; ++i) {
            console2.log(string.concat(_kindName(config.adapters[i].kind), " ", Strings.toString(i)), adapters[i]);
            console2.log("  price / observation time", prices[i], times[i]);
            list = string.concat(list, i == 0 ? "" : ",", Strings.toChecksumHexString(adapters[i]));
        }
        console2.log("Immutable and ownerless: no role, pool or token was touched.");
        console2.log("These are simulated addresses and answers. An adapter reads its feed again when it is mined:");
        console2.log("after inclusion, run verify() with the mined addresses before DeployManagedPool, in this order:");
        console2.log(string.concat("ORACLE_ADAPTERS=", list));
    }

    function _logVerified(address[] memory adapters, Config memory config) internal view {
        string memory list;
        for (uint256 i; i < adapters.length; ++i) {
            AdapterConfig memory a = config.adapters[i];
            console2.log(string.concat("Verified ", _kindName(a.kind), " ", Strings.toString(i)), adapters[i]);
            console2.log("  source / decimals", a.source, a.decimals);
            list = string.concat(list, i == 0 ? "" : ",", Strings.toChecksumHexString(adapters[i]));
        }
        console2.log("Each adapter reads its reviewed source at its reviewed decimals, as of block", block.number);
        console2.log("For contracts/script/managed/DeployManagedPool.s.sol, in this order:");
        console2.log(string.concat("PAIR_ORACLES=", list));
    }
}
