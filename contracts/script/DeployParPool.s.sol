// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { DirectPropAMMRebalanceController } from "../src/DirectPropAMMRebalanceController.sol";
import { PushPriceOracle } from "../src/PushPriceOracle.sol";
import { TempoMainnet } from "../src/TempoMainnet.sol";
import { IAddressRegistry } from "../src/interfaces/IAddressRegistry.sol";
import { IDirectPropAMM } from "../src/interfaces/IDirectPropAMM.sol";
import { ITIP20 } from "../src/interfaces/ITIP20.sol";
import { ITIP403Registry } from "../src/interfaces/ITIP403Registry.sol";

/// @dev Foundry 1.8.1 supports rpcJson; the pinned forge-std Vm interface predates its declaration.
interface VmParPoolRpcJson {
    function rpcJson(string calldata method, string calldata params) external returns (string memory);
}

/// @notice The TIP-20 transfer-policy getter, which the pool itself never reads.
interface ITIP20TransferPolicy {
    function transferPolicyId() external view returns (uint64);
}

/// @notice Deploys a par-priced DirectPropAMM for two TIP-20s of equal decimals, BASE_TOKEN and QUOTE_TOKEN, and hands
/// it to a DirectPropAMMRebalanceController, in two stages or one run.
/// @dev Bridge needs the pool address to create the liquidation addresses that the controller fixes at construction,
/// so the required `STAGE` selects the part to run, each as one broadcast from DEPLOYER_ADDRESS:
/// - `pool`: deploy the par PushPriceOracle and the pool owned by the deployer, optionally fund each side from the
///   deployer, and unpause. No controller; prints POOL_ADDRESS and ORACLE_ADDRESS.
/// - `controller`: validate the existing POOL_ADDRESS (BASE_TOKEN/QUOTE_TOKEN, fresh par oracle, deployer-owned,
///   unpaused at par, with accepted expected oracle roles, canonical creation input and no surviving permissions
///   in its complete event history), deploy the controller and
///   transfer pool ownership to it. The controller accepts in the same run when the deployer is the controller owner;
///   otherwise the script prints the call the controller owner must send.
/// - `all`: both stages in one run, for existing liquidation addresses and an explicitly deployer-owned oracle.
/// Every stage reads both tokens and the symbol each must report, so a mistyped or swapped address fails before
/// anything is sent. No stage admits a taker or recipient, so nothing can trade until the controller owner admits a
/// router. Forge sends transactions only with --broadcast; every postcondition below gates that broadcast.
contract DeployParPool is Script {
    using stdJson for string;

    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);
    error InvalidPool(string check);
    error UnexpectedToken(address token);
    error UnexpectedDeploymentState(string check);

    enum Stage {
        Pool,
        Controller,
        All
    }

    uint256 internal constant LOG_BLOCK_RANGE = 100_000;
    bytes32 internal constant OWNERSHIP_TRANSFERRED = keccak256("OwnershipTransferred(address,address)");
    bytes32 internal constant TAKER_PERMISSION_UPDATED = keccak256("TakerPermissionUpdated(address,bool)");
    bytes32 internal constant RECIPIENT_PERMISSION_UPDATED = keccak256("RecipientPermissionUpdated(address,bool)");
    uint8 internal constant ORACLE_DECIMALS = 8;
    /// @dev Earn's SingleZoneEarnRouter swaps only at exactly `10 ** oracle.decimals()` with zero tolerance.
    uint256 internal constant PAR_PRICE = 10 ** ORACLE_DECIMALS;
    uint256 internal constant DEFAULT_MAX_ORACLE_AGE = 30 days;
    uint256 internal constant MAX_MAX_ORACLE_AGE = 365 days;
    uint256 internal constant DEFAULT_MAX_PRICE_DEVIATION_BPS = 0;
    uint256 internal constant MAX_MAX_PRICE_DEVIATION_BPS = 100;
    /// @dev Whole tokens per side. This script seeds a small live test; add larger inventory later by direct transfer
    /// to the pool.
    uint256 internal constant MAX_INITIAL_TOKENS = 1000;
    bytes32 internal constant BASE_FUND_MEMO = keccak256("INITIAL_BASE_INVENTORY");
    bytes32 internal constant QUOTE_FUND_MEMO = keccak256("INITIAL_QUOTE_INVENTORY");
    ITIP403Registry internal constant TIP403 = ITIP403Registry(TempoMainnet.TIP403_REGISTRY);

    struct Config {
        Stage stage;
        address deployer;
        // All stages: the pair, and the symbol each token must report.
        address baseToken;
        address quoteToken;
        string baseSymbol;
        string quoteSymbol;
        // Pool stage (and `all`).
        address guardian;
        // All stages: controller handoff requires accepted ownership and no pending nomination.
        address oracleOwner;
        address oracleReporter;
        uint256 maxOracleAge;
        uint256 maxPriceDeviationBps;
        uint256 initialBaseAmount;
        uint256 initialQuoteAmount;
        // Controller stage only.
        address pool;
        uint256 poolDeploymentBlock;
        bytes32 poolCreationTx;
        // Optional: the oracle the pool stage printed, checked against the pool's oracle when set.
        address oracle;
        // Controller stage (and `all`).
        address controllerOwner;
        address keeper;
        address baseLiquidationAddress;
        address quoteLiquidationAddress;
        // Optional: check transfer policies and print admission calldata; the script never admits a taker.
        address earnRouter;
    }

    struct Deployment {
        PushPriceOracle oracle;
        DirectPropAMM pool;
        // Zero after the pool stage.
        DirectPropAMMRebalanceController controller;
        bool ownershipAccepted;
    }

    /// @dev What the postconditions require of the pool: from the config, or from an existing pool's prior state.
    struct Expected {
        // Both tokens' decimals, which `_checkTokens` requires to be equal.
        uint8 tokenDecimals;
        address guardian;
        uint256 maxOracleAge;
        uint256 maxPriceDeviationBps;
        uint256 baseInventory;
        uint256 quoteInventory;
        uint256 oracleUpdatedAt;
    }

    function run() external returns (Deployment memory deployed) {
        if (block.chainid != TempoMainnet.CHAIN_ID) revert UnexpectedChain(block.chainid);
        Config memory config = _readConfig();
        bool deploysPool = config.stage != Stage.Controller;
        bool deploysController = config.stage != Stage.Pool;

        _requireAccount(config.deployer, "DEPLOYER_ADDRESS");
        uint8 tokenDecimals = _checkTokens(config);
        _requireAccount(config.oracleOwner, "ORACLE_OWNER_ADDRESS");
        _requireAccount(config.oracleReporter, "ORACLE_REPORTER_ADDRESS");
        if (config.stage == Stage.All && config.oracleOwner != config.deployer) {
            revert InvalidConfig("external oracle owner requires STAGE=pool then acceptance");
        }

        Expected memory expected;
        if (deploysPool) {
            if (config.pool != address(0)) revert InvalidConfig("POOL_ADDRESS is only for STAGE=controller");
            _preflightPool(config, tokenDecimals);
            expected = Expected({
                tokenDecimals: tokenDecimals,
                guardian: config.guardian,
                maxOracleAge: config.maxOracleAge,
                maxPriceDeviationBps: config.maxPriceDeviationBps,
                baseInventory: config.initialBaseAmount,
                quoteInventory: config.initialQuoteAmount,
                oracleUpdatedAt: block.timestamp
            });
        } else {
            expected = _checkExistingPool(config, tokenDecimals);
            deployed.pool = DirectPropAMM(config.pool);
            deployed.oracle = PushPriceOracle(address(deployed.pool.oracle()));
        }
        if (deploysController) _preflightController(config);
        _logConfig(config);

        // The explicit sender must be the reviewed deployer, even if Forge has other signers available.
        vm.startBroadcast(config.deployer);
        if (deploysPool) {
            deployed.oracle = new PushPriceOracle(
                ORACLE_DECIMALS, config.deployer, config.deployer, PAR_PRICE, expected.oracleUpdatedAt
            );
            deployed.pool = new DirectPropAMM(
                ITIP20(config.baseToken),
                ITIP20(config.quoteToken),
                deployed.oracle,
                IAddressRegistry(TempoMainnet.ADDRESS_REGISTRY),
                config.deployer,
                config.guardian,
                config.maxOracleAge,
                config.maxPriceDeviationBps
            );
            // The deployer funds while it owns the pool; `fund` pulls from the owner only.
            if (config.initialBaseAmount != 0) {
                IERC20(config.baseToken).approve(address(deployed.pool), config.initialBaseAmount);
                deployed.pool.fund(config.baseToken, config.initialBaseAmount, BASE_FUND_MEMO);
            }
            if (config.initialQuoteAmount != 0) {
                IERC20(config.quoteToken).approve(address(deployed.pool), config.initialQuoteAmount);
                deployed.pool.fund(config.quoteToken, config.initialQuoteAmount, QUOTE_FUND_MEMO);
            }
            // Initializes both directional anchors at par. No taker is admitted, so nothing can trade.
            // Sequential broadcasts must not expose the seed to either production role before capture.
            _initializeAnchors(deployed.pool);
            if (config.oracleReporter != config.deployer) deployed.oracle.setReporter(config.oracleReporter);
            if (config.oracleOwner != config.deployer) deployed.oracle.transferOwnership(config.oracleOwner);
        }
        if (deploysController) {
            address[] memory tokens = new address[](2);
            (tokens[0], tokens[1]) = (config.baseToken, config.quoteToken);
            address[] memory liquidationAddresses = new address[](2);
            (liquidationAddresses[0], liquidationAddresses[1]) =
            (config.baseLiquidationAddress, config.quoteLiquidationAddress);
            deployed.controller = new DirectPropAMMRebalanceController(
                IDirectPropAMM(address(deployed.pool)),
                config.controllerOwner,
                config.keeper,
                tokens,
                liquidationAddresses
            );
            deployed.pool.transferOwnership(address(deployed.controller));
            if (config.controllerOwner == config.deployer) {
                deployed.controller.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));
                deployed.ownershipAccepted = true;
            }
        }
        vm.stopBroadcast();

        _checkPool(deployed, config, expected, deploysPool);
        if (deploysController) _checkController(deployed, config);
        _logDeployment(deployed, config, expected);
        if (deploysPool && config.oracleOwner != config.deployer) {
            console2.log("REQUIRED: from ORACLE_OWNER_ADDRESS accept oracle ownership", config.oracleOwner);
            console2.log("  Oracle target", address(deployed.oracle));
            console2.log(
                "  acceptOwnership() calldata", vm.toString(abi.encodeCall(PushPriceOracle.acceptOwnership, ()))
            );
            console2.log("Until acceptance the deployer retains oracle owner authority, including setReporter");
        }
        if (deploysController) _logRemainingCalls(deployed, config);
        else _logNextStage(deployed);
    }

    /// @dev Narrow test seam at the last transaction boundary before initial anchor capture.
    function _initializeAnchors(DirectPropAMM pool) internal virtual {
        pool.unpause();
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory config) {
        string memory stage = vm.envString("STAGE");
        if (_eq(stage, "pool")) config.stage = Stage.Pool;
        else if (_eq(stage, "controller")) config.stage = Stage.Controller;
        else if (_eq(stage, "all")) config.stage = Stage.All;
        else revert InvalidConfig("STAGE");

        config.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        config.baseToken = vm.envAddress("BASE_TOKEN");
        config.quoteToken = vm.envAddress("QUOTE_TOKEN");
        // Blank reads as missing, which `_checkToken` rejects by name.
        config.baseSymbol = vm.envOr("BASE_TOKEN_SYMBOL", string(""));
        config.quoteSymbol = vm.envOr("QUOTE_TOKEN_SYMBOL", string(""));
        config.pool = _envAddressOr("POOL_ADDRESS");
        config.oracleOwner = vm.envAddress("ORACLE_OWNER_ADDRESS");
        config.oracleReporter = vm.envAddress("ORACLE_REPORTER_ADDRESS");
        if (config.stage != Stage.Controller) {
            config.guardian = vm.envAddress("GUARDIAN_ADDRESS");
            config.maxOracleAge = _envUintOr("MAX_ORACLE_AGE", DEFAULT_MAX_ORACLE_AGE);
            config.maxPriceDeviationBps = _envUintOr("MAX_PRICE_DEVIATION_BPS", DEFAULT_MAX_PRICE_DEVIATION_BPS);
            config.initialBaseAmount = _envUintOr("INITIAL_BASE_AMOUNT", 0);
            config.initialQuoteAmount = _envUintOr("INITIAL_QUOTE_AMOUNT", 0);
        }
        if (config.stage == Stage.Controller) {
            config.poolDeploymentBlock = vm.envUint("POOL_DEPLOYMENT_BLOCK");
            config.poolCreationTx = vm.envBytes32("POOL_CREATION_TX");
        }
        if (config.stage != Stage.Pool) {
            config.oracle = _envAddressOr("ORACLE_ADDRESS");
            config.controllerOwner = vm.envAddress("CONTROLLER_OWNER_ADDRESS");
            config.keeper = vm.envAddress("KEEPER_ADDRESS");
            config.baseLiquidationAddress = vm.envAddress("BASE_LIQUIDATION_ADDRESS");
            config.quoteLiquidationAddress = vm.envAddress("QUOTE_LIQUIDATION_ADDRESS");
            config.earnRouter = _envAddressOr("EARN_ROUTER_ADDRESS");
        }
    }

    /// @dev Unset and blank both mean "not provided", so a sourced env file may leave optional entries empty.
    function _envAddressOr(string memory name) internal view returns (address) {
        string memory value = vm.envOr(name, string(""));
        return bytes(value).length == 0 ? address(0) : vm.parseAddress(value);
    }

    function _envUintOr(string memory name, uint256 defaultValue) internal view returns (uint256) {
        string memory value = vm.envOr(name, string(""));
        return bytes(value).length == 0 ? defaultValue : vm.parseUint(value);
    }

    /// @dev The operator names each token and the symbol it reviewed for it, so a mistyped or swapped address fails
    /// here. Returns the tokens' decimals: par swaps equal raw amounts each way, so the router's exact 1:1 conversion
    /// needs equal units, and the pool's price scale is then exactly `PAR_PRICE`.
    function _checkTokens(Config memory config) internal view returns (uint8 tokenDecimals) {
        _checkToken(config.baseToken, config.baseSymbol, "BASE_TOKEN");
        if (config.quoteToken == config.baseToken) revert InvalidConfig("BASE_TOKEN and QUOTE_TOKEN must differ");
        _checkToken(config.quoteToken, config.quoteSymbol, "QUOTE_TOKEN");
        tokenDecimals = ITIP20(config.baseToken).decimals();
        if (ITIP20(config.quoteToken).decimals() != tokenDecimals) revert UnexpectedToken(config.quoteToken);
    }

    function _checkToken(address token, string memory symbol, string memory field) internal view {
        if (token == address(0)) revert InvalidConfig(field);
        if (bytes(symbol).length == 0) revert InvalidConfig(string.concat(field, "_SYMBOL"));
        // Native TIP-20 functionality is checked through its ABI, not an EVM bytecode assumption.
        if (!_eq(ITIP20(token).symbol(), symbol)) revert UnexpectedToken(token);
    }

    function _preflightPool(Config memory config, uint8 tokenDecimals) internal view {
        _requireAccount(config.guardian, "GUARDIAN_ADDRESS");
        if (config.maxOracleAge == 0 || config.maxOracleAge > MAX_MAX_ORACLE_AGE) {
            revert InvalidConfig("MAX_ORACLE_AGE");
        }
        if (config.maxPriceDeviationBps > MAX_MAX_PRICE_DEVIATION_BPS) revert InvalidConfig("MAX_PRICE_DEVIATION_BPS");
        uint256 maxInitialAmount = MAX_INITIAL_TOKENS * 10 ** tokenDecimals;
        if (config.initialBaseAmount > maxInitialAmount) revert InvalidConfig("INITIAL_BASE_AMOUNT");
        if (config.initialQuoteAmount > maxInitialAmount) revert InvalidConfig("INITIAL_QUOTE_AMOUNT");
        if (config.initialBaseAmount != 0) _checkFunding(config.baseToken, config, config.initialBaseAmount);
        if (config.initialQuoteAmount != 0) _checkFunding(config.quoteToken, config, config.initialQuoteAmount);
    }

    /// @dev The controller stage takes over a pool only in the state the pool stage leaves it in.
    function _checkExistingPool(Config memory config, uint8 tokenDecimals) internal returns (Expected memory expected) {
        if (config.pool == address(0)) revert InvalidConfig("POOL_ADDRESS");
        if (config.pool.code.length == 0) revert InvalidPool("no code");
        DirectPropAMM pool = DirectPropAMM(config.pool);
        if (address(pool.baseToken()) != config.baseToken || address(pool.quoteToken()) != config.quoteToken) {
            revert InvalidPool("tokens");
        }
        if (
            address(pool.addressRegistry()) != TempoMainnet.ADDRESS_REGISTRY || pool.oracleDecimals() != ORACLE_DECIMALS
                || pool.priceScale() != PAR_PRICE
        ) revert InvalidPool("registry or decimals");
        if (config.oracle != address(0) && address(pool.oracle()) != config.oracle) revert InvalidPool("oracle");
        if (pool.maxOracleAge() > MAX_MAX_ORACLE_AGE || pool.maxPriceDeviationBps() > MAX_MAX_PRICE_DEVIATION_BPS) {
            revert InvalidPool("risk limits");
        }
        if (pool.owner() != config.deployer) revert InvalidPool("owner");
        // Unpausing would override a guardian pause, so this stage leaves that decision to the operator.
        if (pool.paused()) revert InvalidPool("paused");

        PushPriceOracle oracle = PushPriceOracle(address(pool.oracle()));
        if (!_oracleRolesAccepted(oracle, config)) revert InvalidPool("oracle roles");
        (uint256 price, uint256 updatedAt) = oracle.latestPrice();
        if (oracle.decimals() != ORACLE_DECIMALS || price != PAR_PRICE) revert InvalidPool("oracle not at par");
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > pool.maxOracleAge()) {
            revert InvalidPool("oracle stale");
        }
        if (pool.baseToQuotePriceAnchor() != PAR_PRICE || pool.quoteToBasePriceAnchor() != PAR_PRICE) {
            revert InvalidPool("price anchors");
        }
        if (pool.pendingOwner() != address(0)) {
            console2.log("WARNING: replacing the pool's pending owner", pool.pendingOwner());
        }

        _checkPoolCreation(config, pool);
        _checkPermissionHistory(pool, config.poolDeploymentBlock);

        expected = Expected({
            tokenDecimals: tokenDecimals,
            guardian: pool.guardian(),
            maxOracleAge: pool.maxOracleAge(),
            maxPriceDeviationBps: pool.maxPriceDeviationBps(),
            baseInventory: IERC20(config.baseToken).balanceOf(config.pool),
            quoteInventory: IERC20(config.quoteToken).balanceOf(config.pool),
            oracleUpdatedAt: updatedAt
        });
    }

    /// @dev A constructor can silently seed permission mappings and return genuine runtime. Bind the pool to
    /// one mined canonical CREATE before using its logs to enumerate grants. Evidence comes only from the active
    /// fork's RPC. Exact input includes metadata and all constructor arguments, so use the stage-1 build and leave
    /// its guardian, oracle and risk settings unchanged between stages. Missing RPC evidence fails closed.
    function _checkPoolCreation(Config memory config, DirectPropAMM pool) internal {
        if (config.poolCreationTx == bytes32(0)) revert InvalidConfig("POOL_CREATION_TX");
        if (config.poolDeploymentBlock > block.number) revert InvalidConfig("POOL_DEPLOYMENT_BLOCK");
        string memory params = string.concat('["', vm.toString(config.poolCreationTx), '"]');
        string memory transaction = _rpc("eth_getTransactionByHash", params);
        string memory receipt = _rpc("eth_getTransactionReceipt", params);
        uint256 txType = vm.parseUint(transaction.readString(".type"));
        string memory callPath = "";
        if (txType == 0x76) {
            // Tempo's unbatched CREATE uses calls[0]. Match the pool stage's protocol-nonce broadcast only.
            if (
                vm.parseUint(transaction.readString(".nonceKey")) != 0 || !vm.keyExistsJson(transaction, ".calls[0]")
                    || vm.keyExistsJson(transaction, ".calls[1]")
            ) revert InvalidPool("creation transaction");
            callPath = ".calls[0]";
        } else if (txType > 2) {
            revert InvalidPool("creation transaction");
        }
        if (
            transaction.readBytes32(".hash") != config.poolCreationTx
                || transaction.readAddress(".from") != config.deployer
                || vm.parseUint(transaction.readString(".chainId")) != block.chainid
                || vm.computeCreateAddress(config.deployer, vm.parseUint(transaction.readString(".nonce")))
                    != config.pool
                || keccak256(vm.parseJson(transaction, string.concat(callPath, ".to")))
                    != keccak256(abi.encode(bytes32(0)))
                || vm.parseUint(transaction.readString(string.concat(callPath, ".value"))) != 0
        ) revert InvalidPool("creation transaction");
        if (
            receipt.readBytes32(".transactionHash") != config.poolCreationTx
                || receipt.readAddress(".contractAddress") != config.pool
                || receipt.readAddress(".from") != config.deployer
                || keccak256(vm.parseJson(receipt, ".to")) != keccak256(abi.encode(bytes32(0)))
                || vm.parseUint(receipt.readString(".status")) != 1
        ) revert InvalidPool("creation receipt");
        bytes32 blockHash = receipt.readBytes32(".blockHash");
        if (
            blockHash == bytes32(0) || vm.parseUint(receipt.readString(".blockNumber")) != config.poolDeploymentBlock
                || transaction.readBytes32(".blockHash") != blockHash
                || vm.parseUint(transaction.readString(".blockNumber")) != config.poolDeploymentBlock
        ) revert InvalidPool("creation block");
        string memory canonical =
            _rpc("eth_getBlockByNumber", string.concat('["', receipt.readString(".blockNumber"), '",false]'));
        if (canonical.readBytes32(".hash") != blockHash) revert InvalidPool("creation block");
        _checkCreationAncestry(config.poolDeploymentBlock, blockHash);
        bytes memory expected = bytes.concat(
            type(DirectPropAMM).creationCode,
            abi.encode(
                config.baseToken,
                config.quoteToken,
                address(pool.oracle()),
                TempoMainnet.ADDRESS_REGISTRY,
                config.deployer,
                pool.guardian(),
                uint256(pool.maxOracleAge()),
                uint256(pool.maxPriceDeviationBps())
            )
        );
        if (keccak256(transaction.readBytes(string.concat(callPath, ".input"))) != keccak256(expected)) {
            revert InvalidPool("creation input");
        }
    }

    /// @dev Anchor to the inspected EVM history, not a second, potentially divergent numbered RPC view.
    /// Recent blocks use EIP-2935 state. Older blocks walk authenticated raw headers from its oldest entry.
    /// A missing anchor/header, unsupported header format or more than 1,000,000 links fails closed.
    function _checkCreationAncestry(uint256 height, bytes32 expected) internal {
        if (height >= block.number) revert InvalidPool("creation ancestry");
        if (block.number - height <= 8191) {
            bytes32 canonical = _historyHash(height);
            if (canonical == bytes32(0) || canonical != expected) revert InvalidPool("creation ancestry");
            return;
        }
        uint256 cursor = block.number - 8191;
        if (cursor - height > 1_000_000) revert InvalidPool("creation ancestry limit");
        bytes32 hash = _historyHash(cursor);
        if (hash == bytes32(0)) revert InvalidPool("creation ancestry");
        while (cursor > height) {
            uint256 scratch;
            assembly ("memory-safe") {
                scratch := mload(0x40)
            }
            {
                string memory response = _rpc("debug_getRawHeader", string.concat('["', vm.toString(hash), '"]'));
                bytes memory raw = abi.decode(vm.parseJson(response), (bytes));
                if (keccak256(raw) != hash) revert InvalidPool("creation header hash");
                hash = _headerParent(raw);
            }
            // Only the scalar parent hash survives: response, raw, RPC arguments and decoder temporaries
            // are dead. Keep pre-loop allocations (and optimizer spill slots below scratch) intact.
            assembly ("memory-safe") {
                mstore(0x40, scratch)
            }
            --cursor;
        }
        if (hash != expected) revert InvalidPool("creation ancestry");
    }

    /// @dev Foundry's BLOCKHASH may re-query the RPC's numbered view. The history contract is instead read
    /// from the same fork state as the pool. No opcode or RPC fallback is safe when this state is unavailable.
    function _historyHash(uint256 height) internal view returns (bytes32 hash) {
        (bool ok, bytes memory result) =
            address(0x0000F90827F1C53a10cb7A02335B175320002935).staticcall(abi.encode(height));
        if (!ok || result.length != 32) revert InvalidPool("creation ancestry");
        hash = abi.decode(result, (bytes32));
        if (hash == bytes32(0)) revert InvalidPool("creation ancestry");
    }

    /// @dev Ethereum starts with parentHash; Tempo wraps that header after three scalar fields.
    /// Hash authentication above makes these bytes immutable; RLP bounds still fail closed before indexing.
    function _headerParent(bytes memory raw) internal pure returns (bytes32 parent) {
        (uint256 start, uint256 end, bool list) = _rlpItem(raw, 0);
        if (!list || end != raw.length) revert InvalidPool("creation header");
        (uint256 value, uint256 next, bool nested) = _rlpItem(raw, start);
        if (nested || next - value != 32) {
            for (uint256 i; i < 3; ++i) {
                (, start, nested) = _rlpItem(raw, start);
                if (nested) revert InvalidPool("creation header");
            }
            (start, end, list) = _rlpItem(raw, start);
            if (!list) revert InvalidPool("creation header");
            (value, next, nested) = _rlpItem(raw, start);
        }
        if (nested || next - value != 32 || next > end) revert InvalidPool("creation header");
        assembly ("memory-safe") {
            parent := mload(add(add(raw, 32), value))
        }
        if (parent == bytes32(0)) revert InvalidPool("creation header");
    }

    function _rlpItem(bytes memory raw, uint256 offset)
        internal
        pure
        returns (uint256 payload, uint256 end, bool list)
    {
        if (offset >= raw.length) {
            revert InvalidPool("creation header");
        }
        uint256 prefix = uint8(raw[offset]);
        if (prefix < 0x80) return (offset, offset + 1, false);
        list = prefix >= 0xc0;
        uint256 base = list ? 0xc0 : 0x80;
        uint256 length = prefix - base;
        payload = offset + 1;
        if (length > 55) {
            uint256 count = length - 55;
            if (payload + count > raw.length) revert InvalidPool("creation header");
            length = 0;
            for (uint256 i; i < count; ++i) {
                length = (length << 8) | uint8(raw[payload++]);
            }
        }
        end = payload + length;
        if (end > raw.length) revert InvalidPool("creation header");
    }

    /// @dev Transport seam for tests. Production always uses the selected fork's RPC, not operator-supplied JSON.
    function _rpc(string memory method, string memory params) internal virtual returns (string memory) {
        return VmParPoolRpcJson(address(vm)).rpcJson(method, params);
    }

    /// @dev Permission mappings are not enumerable. Discover every edited account from the pool's logs,
    /// after proving canonical creation, require its constructor event, then read current permissions.
    /// This relies on a complete RPC history at the simulation block, not a fixed list of deployment roles.
    function _checkPermissionHistory(DirectPropAMM pool, uint256 fromBlock) internal view {
        if (fromBlock > block.number) revert InvalidConfig("POOL_DEPLOYMENT_BLOCK");
        bool sawDeployment;
        while (true) {
            uint256 toBlock = fromBlock
                + (block.number - fromBlock < LOG_BLOCK_RANGE ? block.number - fromBlock : LOG_BLOCK_RANGE - 1);
            Vm.EthGetLogs[] memory logs = _getLogs(fromBlock, toBlock, address(pool));
            for (uint256 i; i < logs.length; ++i) {
                if (_checkPermissionLog(pool, logs[i])) sawDeployment = true;
            }
            if (toBlock == block.number) break;
            fromBlock = toBlock + 1;
        }
        if (!sawDeployment) revert InvalidPool("incomplete permission history");
    }

    function _checkPermissionLog(DirectPropAMM pool, Vm.EthGetLogs memory entry) internal view returns (bool) {
        if (entry.removed || entry.emitter != address(pool) || entry.topics.length == 0) return false;
        bytes32 topic = entry.topics[0];
        if (topic == OWNERSHIP_TRANSFERRED && entry.topics.length == 3 && entry.topics[1] == bytes32(0)) {
            return true;
        }
        if ((topic == TAKER_PERMISSION_UPDATED || topic == RECIPIENT_PERMISSION_UPDATED) && entry.topics.length == 2) {
            // The pool emits canonical address topics; both permission maps are checked even on a revoke.
            // forge-lint: disable-next-line(unsafe-typecast)
            address account = address(uint160(uint256(entry.topics[1])));
            // forge-lint: disable-next-line(calls-loop)
            if (pool.takerAllowed(account) || pool.recipientAllowed(account)) {
                revert InvalidPool("existing permissions");
            }
        }
        return false;
    }

    /// @dev Tests replay recorded events; RPC failures deliberately propagate before any broadcast begins.
    function _getLogs(uint256 fromBlock, uint256 toBlock, address emitter)
        internal
        view
        virtual
        returns (Vm.EthGetLogs[] memory)
    {
        // forge-lint: disable-next-line(calls-loop)
        return vm.eth_getLogs(fromBlock, toBlock, emitter, new bytes32[](0));
    }

    function _preflightController(Config memory config) internal view {
        _requireAccount(config.controllerOwner, "CONTROLLER_OWNER_ADDRESS");
        _requireAccount(config.keeper, "KEEPER_ADDRESS");
        // Each liquidation address receives only its own token, from the pool; Bridge pays the other token back.
        if (config.baseLiquidationAddress == address(0)) revert InvalidConfig("BASE_LIQUIDATION_ADDRESS");
        if (config.quoteLiquidationAddress == address(0)) revert InvalidConfig("QUOTE_LIQUIDATION_ADDRESS");
        if (config.baseLiquidationAddress == config.quoteLiquidationAddress) {
            revert InvalidConfig("liquidation addresses must differ");
        }
        if (!_canReceive(config.baseToken, config.baseLiquidationAddress)) {
            revert InvalidConfig("BASE_LIQUIDATION_ADDRESS");
        }
        if (!_canReceive(config.quoteToken, config.quoteLiquidationAddress)) {
            revert InvalidConfig("QUOTE_LIQUIDATION_ADDRESS");
        }
        if (config.earnRouter != address(0)) {
            if (_resolve(config.earnRouter) != config.earnRouter) revert InvalidConfig("EARN_ROUTER_ADDRESS");
            // The router funds and receives either token; policy allowance does not authenticate its identity.
            if (
                !_canSendAndReceive(config.baseToken, config.earnRouter)
                    || !_canSendAndReceive(config.quoteToken, config.earnRouter)
            ) revert InvalidConfig("EARN_ROUTER_ADDRESS transfer policy");
        }
    }

    /// @dev Signing roles must be actual accounts, not zero or virtual payment aliases.
    function _requireAccount(address account, string memory field) internal view {
        if (account == address(0) || _resolve(account) != account) revert InvalidConfig(field);
    }

    function _checkFunding(address token, Config memory config, uint256 amount) internal view {
        if (IERC20(token).balanceOf(config.deployer) < amount) revert InvalidConfig("deployer balance");
        if (!TIP403.isAuthorizedSender(_policyId(token), config.deployer)) {
            revert InvalidConfig("deployer transfer policy");
        }
    }

    function _canReceive(address token, address recipient) internal view returns (bool) {
        address resolved = _resolve(recipient);
        return resolved != address(0) && TIP403.isAuthorizedRecipient(_policyId(token), resolved);
    }

    function _canSendAndReceive(address token, address account) internal view returns (bool) {
        uint64 policyId = _policyId(token);
        return TIP403.isAuthorizedSender(policyId, account) && TIP403.isAuthorizedRecipient(policyId, account);
    }

    /// @dev Each token's own TIP-403 policy, whatever it is: the script expects no particular policy id.
    function _policyId(address token) internal view returns (uint64) {
        return ITIP20TransferPolicy(token).transferPolicyId();
    }

    function _resolve(address account) internal view returns (address) {
        return IAddressRegistry(TempoMainnet.ADDRESS_REGISTRY).resolveRecipient(account);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev A nomination is not a handoff: the current owner can replace it and the reporter.
    function _oracleRolesAccepted(PushPriceOracle oracle, Config memory config) internal view returns (bool) {
        return oracle.owner() == config.oracleOwner && oracle.pendingOwner() == address(0)
            && oracle.reporter() == config.oracleReporter;
    }

    function _checkPool(Deployment memory deployed, Config memory config, Expected memory expected, bool newPool)
        internal
        view
    {
        PushPriceOracle oracle = deployed.oracle;
        DirectPropAMM pool = deployed.pool;

        (uint256 price, uint256 updatedAt) = oracle.latestPrice();
        if (oracle.decimals() != ORACLE_DECIMALS || price != PAR_PRICE || updatedAt != expected.oracleUpdatedAt) {
            revert UnexpectedDeploymentState("oracle");
        }
        if (
            newPool
                && (oracle.owner() != config.deployer
                    || oracle.pendingOwner()
                        != (config.oracleOwner == config.deployer ? address(0) : config.oracleOwner)
                    || oracle.reporter() != config.oracleReporter)
        ) revert UnexpectedDeploymentState("oracle roles");
        if (config.stage != Stage.Pool && !_oracleRolesAccepted(oracle, config)) {
            revert UnexpectedDeploymentState("oracle roles");
        }

        if (
            address(pool.baseToken()) != config.baseToken || address(pool.quoteToken()) != config.quoteToken
                || address(pool.oracle()) != address(oracle)
                || address(pool.addressRegistry()) != TempoMainnet.ADDRESS_REGISTRY
                || pool.baseDecimals() != expected.tokenDecimals || pool.quoteDecimals() != expected.tokenDecimals
                || pool.oracleDecimals() != ORACLE_DECIMALS || pool.priceScale() != PAR_PRICE
                || pool.maxOracleAge() != expected.maxOracleAge
                || pool.maxPriceDeviationBps() != expected.maxPriceDeviationBps || pool.guardian() != expected.guardian
        ) revert UnexpectedDeploymentState("pool configuration");
        if (pool.paused()) revert UnexpectedDeploymentState("pool paused");
        if (pool.baseToQuotePriceAnchor() != PAR_PRICE || pool.quoteToBasePriceAnchor() != PAR_PRICE) {
            revert UnexpectedDeploymentState("price anchors");
        }

        address controller = address(deployed.controller);
        if (controller == address(0)) {
            if (pool.owner() != config.deployer || pool.pendingOwner() != address(0)) {
                revert UnexpectedDeploymentState("pool owner");
            }
        } else if (deployed.ownershipAccepted) {
            if (pool.owner() != controller || pool.pendingOwner() != address(0)) {
                revert UnexpectedDeploymentState("pool owner");
            }
        } else if (pool.owner() != config.deployer || pool.pendingOwner() != controller) {
            revert UnexpectedDeploymentState("pool pending owner");
        }

        if (
            IERC20(config.baseToken).balanceOf(address(pool)) != expected.baseInventory
                || IERC20(config.quoteToken).balanceOf(address(pool)) != expected.quoteInventory
        ) revert UnexpectedDeploymentState("inventory");
        if (
            newPool
                && (IERC20(config.baseToken).allowance(config.deployer, address(pool)) != 0
                    || IERC20(config.quoteToken).allowance(config.deployer, address(pool)) != 0)
        ) revert UnexpectedDeploymentState("leftover allowance");
        // Swaps and rebalances move both tokens in and out of the pool.
        if (
            !_canSendAndReceive(config.baseToken, address(pool))
                || !_canSendAndReceive(config.quoteToken, address(pool))
        ) {
            revert UnexpectedDeploymentState("pool transfer policy");
        }
        address[5] memory accounts =
            [config.deployer, expected.guardian, config.controllerOwner, config.keeper, controller];
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] != address(0) && (pool.takerAllowed(accounts[i]) || pool.recipientAllowed(accounts[i]))) {
                revert UnexpectedDeploymentState("pool permissions");
            }
        }
    }

    function _checkController(Deployment memory deployed, Config memory config) internal view {
        DirectPropAMMRebalanceController controller = deployed.controller;
        address[] memory tokens = controller.tokens();
        if (
            address(controller.pool()) != address(deployed.pool) || controller.owner() != config.controllerOwner
                || controller.pendingOwner() != address(0) || controller.keeper() != config.keeper || tokens.length != 2
                || tokens[0] != config.baseToken || tokens[1] != config.quoteToken
                || controller.liquidationAddress(config.baseToken) != config.baseLiquidationAddress
                || controller.liquidationAddress(config.quoteToken) != config.quoteLiquidationAddress
        ) revert UnexpectedDeploymentState("controller");
    }

    function _logConfig(Config memory config) internal pure {
        string[3] memory stages = ["pool", "controller", "all"];
        console2.log("Stage", stages[uint256(config.stage)]);
        console2.log("Deployer (pool owner until the controller accepts)", config.deployer);
        _logTokens(config);
        console2.log("Expected oracle owner", config.oracleOwner);
        console2.log("Expected oracle reporter", config.oracleReporter);
        if (config.stage != Stage.Controller) {
            console2.log("Guardian", config.guardian);
            console2.log("Oracle owner after acceptance (deployer owns until then)", config.oracleOwner);
            console2.log("Oracle reporter", config.oracleReporter);
            console2.log("Max oracle age (s) / deviation (bps)", config.maxOracleAge, config.maxPriceDeviationBps);
            console2.log("Initial base / quote inventory", config.initialBaseAmount, config.initialQuoteAmount);
        } else {
            console2.log("Existing pool", config.pool);
        }
        if (config.stage != Stage.Pool) {
            console2.log("Controller owner", config.controllerOwner);
            console2.log("Keeper", config.keeper);
            console2.log(
                string.concat("Base (", config.baseSymbol, ") liquidation address"), config.baseLiquidationAddress
            );
            console2.log(
                string.concat("Quote (", config.quoteSymbol, ") liquidation address"), config.quoteLiquidationAddress
            );
        }
    }

    function _logTokens(Config memory config) internal pure {
        console2.log(string.concat("Base token (", config.baseSymbol, ")"), config.baseToken);
        console2.log(string.concat("Quote token (", config.quoteSymbol, ")"), config.quoteToken);
    }

    function _logDeployment(Deployment memory deployed, Config memory config, Expected memory expected) internal pure {
        _logTokens(config);
        console2.log("Token decimals", uint256(expected.tokenDecimals));
        console2.log("Address registry", TempoMainnet.ADDRESS_REGISTRY);
        console2.log("PushPriceOracle", address(deployed.oracle));
        console2.log("DirectPropAMM", address(deployed.pool));
        if (address(deployed.controller) != address(0)) {
            console2.log("DirectPropAMMRebalanceController", address(deployed.controller));
            console2.log("Pool owner accepted by controller", deployed.ownershipAccepted);
        }
        console2.log("Guardian", expected.guardian);
        console2.log("Oracle price / updatedAt", PAR_PRICE, expected.oracleUpdatedAt);
        console2.log("Oracle goes stale after", expected.oracleUpdatedAt + expected.maxOracleAge);
        console2.log("Pool unpaused; price anchors at par", PAR_PRICE);
        console2.log("Pool base / quote inventory", expected.baseInventory, expected.quoteInventory);
        console2.log("No taker or recipient admitted at the simulation block");
        console2.log("Keep the oracle fresh: before it goes stale, from the oracle reporter call on the oracle");
        console2.log(
            "  pushPrice(100000000, <now>) with a strictly later timestamp each time", address(deployed.oracle)
        );
    }

    function _logNextStage(Deployment memory deployed) internal pure {
        console2.log("Next: create both Bridge liquidation addresses with this pool as their destination, then run");
        console2.log("STAGE=controller with:");
        console2.log(string.concat("POOL_ADDRESS=", vm.toString(address(deployed.pool))));
        console2.log(string.concat("ORACLE_ADDRESS=", vm.toString(address(deployed.oracle))));
        console2.log("POOL_DEPLOYMENT_BLOCK=<pool creation block from the mined stage-1 receipt>");
        console2.log("POOL_CREATION_TX=<pool creation transaction hash from the mined stage-1 receipt>");
    }

    function _logRemainingCalls(Deployment memory deployed, Config memory config) internal view {
        address controller = address(deployed.controller);
        if (!deployed.ownershipAccepted) {
            console2.log("REQUIRED: the pool is owned by the deployer until the controller owner accepts.");
            console2.log("Recheck permission history before accepting: the deployer can still admit accounts.");
            console2.log("From CONTROLLER_OWNER_ADDRESS, send to the controller", controller);
            console2.log(
                "  execute(acceptOwnership()) calldata",
                vm.toString(_execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ())))
            );
        }

        console2.log("To admit an Earn router, from CONTROLLER_OWNER_ADDRESS send to the controller", controller);
        if (config.earnRouter == address(0)) {
            console2.log(
                "No router was checked; review its identity and both tokens' send/receive policies before admission."
            );
            console2.log("  execute(setTakerAllowed(router, true)) and execute(setRecipientAllowed(router, true))");
            console2.log("  Set EARN_ROUTER_ADDRESS to print the exact calldata.");
        } else {
            console2.log(
                "WARNING: review the router address, chain, implementation and upgrade authority before admission."
            );
            console2.log(
                "TIP-403 checks are point-in-time only; recheck before signing. They do not prove router identity."
            );
            if (config.earnRouter.code.length == 0) {
                console2.log("WARNING: EARN_ROUTER_ADDRESS has no code; verify the intended router before signing.");
            }
            console2.log("  Earn router", config.earnRouter);
            console2.log(
                "  execute(setTakerAllowed(router, true)) calldata",
                vm.toString(_execute(abi.encodeCall(DirectPropAMM.setTakerAllowed, (config.earnRouter, true))))
            );
            console2.log(
                "  execute(setRecipientAllowed(router, true)) calldata",
                vm.toString(_execute(abi.encodeCall(DirectPropAMM.setRecipientAllowed, (config.earnRouter, true))))
            );
        }
    }

    function _execute(bytes memory poolCall) internal pure returns (bytes memory) {
        return abi.encodeCall(DirectPropAMMRebalanceController.execute, (poolCall));
    }
}
