// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Script, console2 } from "forge-std/Script.sol";

import { DirectPropAMMBufferHelper } from "../../src/DirectPropAMMBufferHelper.sol";
import { IDirectPropAMM } from "../../src/interfaces/IDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";

/// @dev The immutable bindings every `DirectPropAMMBufferHelper` answers, whichever pool kind it serves: what the
/// script reads from a helper being replaced.
interface IBufferHelperBindings {
    function vault() external view returns (address);
    function baseToken() external view returns (address);
    function quoteToken() external view returns (address);
    function customerId() external view returns (bytes32);
    function slippageBps() external view returns (uint16);
}

/// @notice Deploys the `DirectPropAMMBufferHelper`s that connect Veda BoringVaults to one `ManagedDirectPropAMM`: one
/// helper per vault and pair, and nothing else. A helper holds no tokens and has no authority over the vault or the
/// pool, and its bindings are immutable, so the deployer keeps no power. It lists nobody and selects no hook: the
/// pool's owner still admits each BoringVault on its pair (`ManagedPoolAccess`), and the Veda authority still allows
/// the helper and selects it on the Teller.
/// @dev One broadcast from `DEPLOYER_ADDRESS`: one CREATE per entry, in order. `POOL_ADDRESS` is the managed pool.
/// Inputs, comma-separated with one entry per helper:
/// - `HELPER_VAULTS`: the BoringVault itself, the account that swaps (never a Teller, an Earn engine or a wallet);
/// - `HELPER_PAIR_INDEXES`: the pair whose base the vault holds and whose quote is its asset;
/// - `HELPER_EXPECTED_BASES`, `HELPER_EXPECTED_QUOTES`: the reviewed tokens of that pair. Mined `addPair` order
///   assigns indexes, so an index alone proves nothing: the pair must hold exactly these tokens;
/// - `HELPER_SPONSOR_IDS`: the list that admits the vault on the pair, 0 for the pair's home list;
/// - `HELPER_CUSTOMER_IDS`: the nonzero 32-byte route id the vault's rounding credit accrues under;
/// - `HELPER_SLIPPAGE_BPS`: the helper's quote tolerance, at most its `MAX_SLIPPAGE_BPS` (1,000). Not a fee cap;
/// - `HELPER_REFERENCES`: the helper the vault's Teller uses today, or the zero address for none. A named helper must
///   serve the same vault and the same two tokens, so a replacement can't be bound to another vault or pair by
///   mistake; a different customer id or slippage only warns.
/// The run stops on a pool that doesn't answer as a managed pool, an unknown or removed pair, tokens other than the
/// expected ones, or two helpers for one vault and pair. It warns, without stopping, about what the helper can be
/// deployed ahead of: a vault the pair doesn't admit yet, and a pair hook, whose fee for the vault must be verified
/// zero in both directions before the Teller switches (`docs/veda-integration.md`). Forge sends only with
/// `--broadcast`.
contract DeployManagedBufferHelpers is Script {
    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);
    error UnexpectedDeploymentState(string field);

    struct HelperConfig {
        address vault;
        uint16 pairIndex;
        address expectedBase;
        address expectedQuote;
        uint64 sponsorId;
        bytes32 customerId;
        uint16 slippageBps;
        address replaced;
    }

    struct Config {
        address deployer;
        IManagedDirectPropAMM pool;
        HelperConfig[] helpers;
    }

    uint256 internal constant TEMPO_MAINNET_CHAIN_ID = 4217;
    uint256 internal constant TEMPO_MODERATO_CHAIN_ID = 42431;
    /// @notice The most helpers one run deploys.
    uint256 public constant MAX_HELPERS = 16;
    /// @dev `DirectPropAMMBufferHelper.MAX_SLIPPAGE_BPS`.
    uint256 internal constant MAX_SLIPPAGE_BPS = 1000;
    /// @dev What the pool's `MAX_BATCH` must answer.
    uint256 internal constant POOL_MAX_BATCH = 100;
    /// @dev The gas and answer size a raw probe allows: a target that burns its gas or answers with a huge payload
    /// reads as no answer.
    uint256 internal constant PROBE_GAS = 1_000_000;

    /// @dev What the run leaves for the operator to resolve before a Teller switches. Script-local, never broadcast.
    string[] internal _warnings;

    /// @notice Checks every input, deploys the helpers in order, checks each and logs them with the run's warnings.
    function run() public returns (address[] memory helpers) {
        if (block.chainid != TEMPO_MAINNET_CHAIN_ID && block.chainid != TEMPO_MODERATO_CHAIN_ID) {
            revert UnexpectedChain(block.chainid);
        }
        delete _warnings;
        Config memory config = _readConfig();
        uint256 count = _checkInputs(config);
        _logConfig(config);

        uint64 nonce = vm.getNonce(config.deployer);
        helpers = new address[](count);
        // The explicit sender must be the reviewed deployer, even if Forge has other signers available.
        vm.startBroadcast(config.deployer);
        // One deployment per configured helper is the script's whole job; any failure stops the run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        for (uint256 i; i < count; ++i) {
            HelperConfig memory h = config.helpers[i];
            helpers[i] = address(
                new DirectPropAMMBufferHelper(
                    IDirectPropAMM(address(config.pool)), h.vault, h.customerId, h.slippageBps, h.pairIndex, h.sponsorId
                )
            );
        }
        vm.stopBroadcast();

        for (uint256 i; i < count; ++i) {
            // `i` is below `MAX_HELPERS`.
            // forge-lint: disable-next-line(unsafe-typecast)
            address predicted = vm.computeCreateAddress(config.deployer, nonce + uint64(i));
            _checkDeployment(helpers[i], predicted, config, i);
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
        _logDeployment(helpers, config);
    }

    /// @notice The warnings of the last `run`.
    function warnings() external view returns (string[] memory) {
        return _warnings;
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory config) {
        config.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        config.pool = IManagedDirectPropAMM(vm.envAddress("POOL_ADDRESS"));
        address[] memory vaults = vm.envAddress("HELPER_VAULTS", ",");
        uint256[] memory pairIndexes = vm.envUint("HELPER_PAIR_INDEXES", ",");
        address[] memory bases = vm.envAddress("HELPER_EXPECTED_BASES", ",");
        address[] memory quotes = vm.envAddress("HELPER_EXPECTED_QUOTES", ",");
        uint256[] memory sponsorIds = vm.envUint("HELPER_SPONSOR_IDS", ",");
        bytes32[] memory customerIds = vm.envBytes32("HELPER_CUSTOMER_IDS", ",");
        uint256[] memory slippage = vm.envUint("HELPER_SLIPPAGE_BPS", ",");
        address[] memory references = vm.envAddress("HELPER_REFERENCES", ",");
        uint256 count = vaults.length;
        if (
            pairIndexes.length != count || bases.length != count || quotes.length != count || sponsorIds.length != count
                || customerIds.length != count || slippage.length != count || references.length != count
        ) revert InvalidConfig("HELPER_* lists need one entry per helper");
        config.helpers = new HelperConfig[](count);
        for (uint256 i; i < count; ++i) {
            // A malformed list entry stops the whole run.
            // forge-lint: disable-start(require-revert-in-loop)
            if (pairIndexes[i] > type(uint16).max) revert InvalidConfig(_field("HELPER_PAIR_INDEXES", i));
            if (sponsorIds[i] > type(uint64).max) revert InvalidConfig(_field("HELPER_SPONSOR_IDS", i));
            if (slippage[i] > type(uint16).max) revert InvalidConfig(_field("HELPER_SLIPPAGE_BPS", i));
            // forge-lint: disable-end(require-revert-in-loop)
            config.helpers[i] = HelperConfig({
                vault: vaults[i],
                // All three are checked above.
                // forge-lint: disable-next-line(unsafe-typecast)
                pairIndex: uint16(pairIndexes[i]),
                expectedBase: bases[i],
                expectedQuote: quotes[i],
                // forge-lint: disable-next-line(unsafe-typecast)
                sponsorId: uint64(sponsorIds[i]),
                customerId: customerIds[i],
                // forge-lint: disable-next-line(unsafe-typecast)
                slippageBps: uint16(slippage[i]),
                replaced: references[i]
            });
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Preflight
    // ---------------------------------------------------------------------------------------------------------------

    function _checkInputs(Config memory config) internal returns (uint256 count) {
        address deployer = config.deployer;
        // A real signing account: not zero, not Forge's keyless default sender, not a TIP-1022 virtual address.
        if (deployer == address(0) || deployer == DEFAULT_SENDER || _isVirtual(deployer)) {
            revert InvalidConfig("DEPLOYER_ADDRESS");
        }
        uint16 pairs = _checkPool(config.pool);
        count = config.helpers.length;
        if (count == 0 || count > MAX_HELPERS) revert InvalidConfig("HELPER_* lists need 1 to 16 helpers");
        // A check of operator input before anything runs: any bad entry stops the whole run.
        for (uint256 i; i < count; ++i) {
            HelperConfig memory h = config.helpers[i];
            for (uint256 j; j < i; ++j) {
                if (config.helpers[j].vault == h.vault && config.helpers[j].pairIndex == h.pairIndex) {
                    // forge-lint: disable-next-line(require-revert-in-loop)
                    revert InvalidConfig(string.concat(_field("HELPER_VAULTS", i), " repeats a vault and pair"));
                }
            }
            _checkHelper(config.pool, pairs, h, i);
        }
    }

    /// @dev Rejects incompatible pool view shapes, as `ManagedPoolAccess` does; not a proof of pool code or creation.
    /// A `DirectPropAMM` has no `pairCount`, and a v2 `Venue` answers `pairCount` and `MAX_BATCH` but has no
    /// `tokenPairCount`.
    function _checkPool(IManagedDirectPropAMM pool) internal view returns (uint16) {
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
        // Checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(pairs);
    }

    function _checkHelper(IManagedDirectPropAMM pool, uint16 pairs, HelperConfig memory h, uint256 i) internal {
        // Runs once per configured entry, from a loop: any bad entry stops the whole run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        address vault = h.vault;
        // The BoringVault is a deployed contract and a real account: the pool pays it, and never a virtual address.
        if (vault == address(0) || vault == address(pool) || vault.code.length == 0 || _isVirtual(vault)) {
            revert InvalidConfig(_field("HELPER_VAULTS", i));
        }
        if (h.customerId == bytes32(0)) revert InvalidConfig(_field("HELPER_CUSTOMER_IDS", i));
        if (h.slippageBps > MAX_SLIPPAGE_BPS) revert InvalidConfig(_field("HELPER_SLIPPAGE_BPS", i));
        if (h.expectedBase == address(0)) revert InvalidConfig(_field("HELPER_EXPECTED_BASES", i));
        if (h.expectedQuote == address(0) || h.expectedQuote == h.expectedBase) {
            revert InvalidConfig(_field("HELPER_EXPECTED_QUOTES", i));
        }
        if (h.pairIndex >= pairs) {
            revert InvalidConfig(string.concat(_field("HELPER_PAIR_INDEXES", i), " is not a pair"));
        }
        IManagedDirectPropAMM.Pair memory info = pool.pair(h.pairIndex);
        // A removed pair reads all zero.
        if (info.access == IManagedDirectPropAMM.AccessMode.None) {
            revert InvalidConfig(string.concat(_field("HELPER_PAIR_INDEXES", i), " was removed"));
        }
        if (info.base != h.expectedBase) {
            revert InvalidConfig(string.concat(_field("HELPER_EXPECTED_BASES", i), " is not the pair's base"));
        }
        if (info.quote != h.expectedQuote) {
            revert InvalidConfig(string.concat(_field("HELPER_EXPECTED_QUOTES", i), " is not the pair's quote"));
        }
        if (h.replaced != address(0)) _checkReference(h, i);

        string memory n = string.concat("Helper ", Strings.toString(i), ": ");
        IManagedDirectPropAMM.TakerAccess access = pool.takerAccess(h.pairIndex, vault, h.sponsorId);
        if (access != IManagedDirectPropAMM.TakerAccess.Allowed) {
            _warnings.push(
                string.concat(n, "the pair does not admit the vault now (", _accessName(access), "): its swaps revert")
            );
        }
        // forge-lint: disable-next-line(unused-return)
        (address hook,) = pool.pairHook(h.pairIndex);
        if (hook != address(0)) {
            _warnings.push(
                string.concat(
                    n,
                    "the pair has a hook, ",
                    Strings.toChecksumHexString(hook),
                    ": verify it charges the vault zero in both directions"
                )
            );
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    /// @dev The helper being replaced must serve the same vault and tokens. Raw probes: it is operator input.
    function _checkReference(HelperConfig memory h, uint256 i) internal {
        // Runs once per configured entry, from a loop: any bad entry stops the whole run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        address replaced = h.replaced;
        string memory field = _field("HELPER_REFERENCES", i);
        if (replaced.code.length == 0) revert InvalidConfig(field);
        (bool okVault, uint256 vault) = _probeWord(replaced, abi.encodeCall(IBufferHelperBindings.vault, ()));
        (bool okBase, uint256 base) = _probeWord(replaced, abi.encodeCall(IBufferHelperBindings.baseToken, ()));
        (bool okQuote, uint256 quote) = _probeWord(replaced, abi.encodeCall(IBufferHelperBindings.quoteToken, ()));
        (bool okId, uint256 customerId) = _probeWord(replaced, abi.encodeCall(IBufferHelperBindings.customerId, ()));
        (bool okSlippage, uint256 slippageBps) =
            _probeWord(replaced, abi.encodeCall(IBufferHelperBindings.slippageBps, ()));
        if (!okVault || !okBase || !okQuote || !okId || !okSlippage) {
            revert InvalidConfig(string.concat(field, " is not a buffer helper"));
        }
        if (vault != uint256(uint160(h.vault))) {
            revert InvalidConfig(string.concat(field, " serves another vault"));
        }
        if (base != uint256(uint160(h.expectedBase)) || quote != uint256(uint160(h.expectedQuote))) {
            revert InvalidConfig(string.concat(field, " serves other tokens"));
        }
        string memory n = string.concat("Helper ", Strings.toString(i), ": ");
        if (customerId != uint256(h.customerId)) {
            _warnings.push(string.concat(n, "customer id differs from the helper it replaces"));
        }
        if (slippageBps != h.slippageBps) {
            _warnings.push(
                string.concat(
                    n, "slippage differs from the helper it replaces (", Strings.toString(slippageBps), " bps)"
                )
            );
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    function _accessName(IManagedDirectPropAMM.TakerAccess access) internal pure returns (string memory) {
        if (access == IManagedDirectPropAMM.TakerAccess.UnknownPair) return "unknown pair";
        if (access == IManagedDirectPropAMM.TakerAccess.Closed) return "pair Closed";
        if (access == IManagedDirectPropAMM.TakerAccess.Denied) return "vault denied";
        if (access == IManagedDirectPropAMM.TakerAccess.UnknownSponsor) return "unknown sponsor";
        if (access == IManagedDirectPropAMM.TakerAccess.SponsorDisabled) return "sponsor disabled";
        if (access == IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted) return "sponsor not admitted";
        if (access == IManagedDirectPropAMM.TakerAccess.NotListed) return "vault not listed";
        return "no answer";
    }

    function _isVirtual(address account) internal pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == 0xFDFDFDFDFDFDFDFDFDFD;
    }

    function _field(string memory name, uint256 i) internal pure returns (string memory) {
        return string.concat(name, "[", Strings.toString(i), "]");
    }

    /// @dev A raw call returning exactly one word, so a target that lacks the function or answers oddly reads as
    /// `ok == false` instead of reverting.
    function _probeWord(address target, bytes memory data) internal view returns (bool ok, uint256 word) {
        uint256 gasLimit = PROBE_GAS;
        bool success;
        uint256 size;
        assembly ("memory-safe") {
            success := staticcall(gasLimit, target, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
        }
        if (!success || size != 32) return (false, 0);
        assembly ("memory-safe") {
            returndatacopy(0, 0, 32)
            word := mload(0)
        }
        ok = true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Postconditions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The helper sits at the deployer's next CREATE address, took the managed path and holds every reviewed
    /// binding.
    function _checkDeployment(address helper, address predicted, Config memory config, uint256 i) internal view {
        // Runs once per configured entry, from a loop: any bad entry stops the whole run.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        HelperConfig memory h = config.helpers[i];
        DirectPropAMMBufferHelper deployed = DirectPropAMMBufferHelper(helper);
        string memory n = string.concat("helper ", Strings.toString(i));
        if (helper != predicted || helper.code.length == 0) {
            revert UnexpectedDeploymentState(string.concat(n, " address"));
        }
        if (!deployed.managed() || address(deployed.pool()) != address(config.pool)) {
            revert UnexpectedDeploymentState(string.concat(n, " pool"));
        }
        if (deployed.vault() != h.vault) revert UnexpectedDeploymentState(string.concat(n, " vault"));
        if (deployed.pairIndex() != h.pairIndex || deployed.sponsorId() != h.sponsorId) {
            revert UnexpectedDeploymentState(string.concat(n, " pair"));
        }
        if (deployed.baseToken() != h.expectedBase || deployed.quoteToken() != h.expectedQuote) {
            revert UnexpectedDeploymentState(string.concat(n, " tokens"));
        }
        if (deployed.customerId() != h.customerId || deployed.slippageBps() != h.slippageBps) {
            revert UnexpectedDeploymentState(string.concat(n, " route"));
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Logs
    // ---------------------------------------------------------------------------------------------------------------

    function _logConfig(Config memory config) internal view {
        console2.log("Chain id", block.chainid);
        console2.log("Deployer", config.deployer);
        console2.log("Managed pool", address(config.pool));
        for (uint256 i; i < config.helpers.length; ++i) {
            HelperConfig memory h = config.helpers[i];
            console2.log(string.concat("Helper ", Strings.toString(i), ": vault"), h.vault);
            console2.log("  pair index / sponsor id", h.pairIndex, h.sponsorId);
            console2.log("  base", h.expectedBase);
            console2.log("  quote", h.expectedQuote);
            console2.log("  customer id");
            console2.logBytes32(h.customerId);
            console2.log("  slippage bps", h.slippageBps);
            if (h.replaced != address(0)) console2.log("  replaces", h.replaced);
        }
    }

    function _logDeployment(address[] memory helpers, Config memory config) internal view {
        for (uint256 i; i < helpers.length; ++i) {
            console2.log(string.concat("DirectPropAMMBufferHelper ", Strings.toString(i)), helpers[i]);
            console2.log("  for vault", config.helpers[i].vault);
        }
        for (uint256 i; i < _warnings.length; ++i) {
            console2.log(string.concat("WARNING: ", _warnings[i]));
        }
        console2.log("No vault, Teller or pool state changed: a helper has no authority.");
        console2.log("Next: the pool's owner admits each BoringVault on its pair (ManagedPoolAccess), then the Veda");
        console2.log("authority allows each helper and selects it for the Teller's deposit and withdrawal hooks.");
    }
}
