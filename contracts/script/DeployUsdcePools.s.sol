// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { ChainlinkPriceOracleAdapter } from "../src/ChainlinkPriceOracleAdapter.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { OndoUSDYPriceOracleAdapter } from "../src/OndoUSDYPriceOracleAdapter.sol";
import { TempoMainnet } from "../src/TempoMainnet.sol";
import { IAddressRegistry } from "../src/interfaces/IAddressRegistry.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { IOndoUSDYOracleWrapper } from "../src/interfaces/IOndoUSDYOracle.sol";
import { IPriceOracle } from "../src/interfaces/IPriceOracle.sol";
import { ITIP20 } from "../src/interfaces/ITIP20.sol";

/// @notice Deploys paused PRIME/USDC.e and USDY/USDC.e pools with their final owner and guardian.
/// @dev No helpers, funding, approvals, permissions, or activation. Forge only sends transactions with --broadcast.
contract DeployUsdcePools is Script {
    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);
    error UnexpectedToken(address token);
    error UnexpectedPrimeFeed();
    error InvalidObservation(address source, uint256 price, uint256 updatedAt, uint256 maxAge);
    error UnexpectedPoolState(address pool);

    struct Config {
        address deployer;
        address owner;
        address guardian;
        uint256 primeMaxOracleAge;
        uint256 primeMaxPriceDeviationBps;
        uint256 usdyMaxOracleAge;
        uint256 usdyMaxPriceDeviationBps;
    }

    struct Deployment {
        ChainlinkPriceOracleAdapter primeAdapter;
        DirectPropAMM primePool;
        OndoUSDYPriceOracleAdapter usdyAdapter;
        DirectPropAMM usdyPool;
    }

    /// @dev Deployment must preserve unsolicited balances already held by the predicted CREATE address.
    struct Inventory {
        address pool;
        uint256 base;
        uint256 quote;
    }

    function run() external returns (Deployment memory deployed) {
        if (block.chainid != TempoMainnet.CHAIN_ID) revert UnexpectedChain(block.chainid);
        Config memory config = _readConfig();
        _preflight(config);

        // The broadcast creates adapter, pool, adapter, pool; local preflight probes do not consume this nonce.
        uint256 nonce = vm.getNonce(config.deployer);
        Inventory memory primeInventory =
            _inventory(vm.computeCreateAddress(config.deployer, nonce + 1), TempoMainnet.PRIME);
        Inventory memory usdyInventory =
            _inventory(vm.computeCreateAddress(config.deployer, nonce + 3), TempoMainnet.USDY);

        console2.log("Deployer", config.deployer);
        console2.log("Owner of both pools", config.owner);
        console2.log("Guardian of both pools", config.guardian);
        console2.log("PRIME max oracle age / deviation bps", config.primeMaxOracleAge, config.primeMaxPriceDeviationBps);
        console2.log("USDY max oracle age / deviation bps", config.usdyMaxOracleAge, config.usdyMaxPriceDeviationBps);

        // The explicit sender must be the reviewed deployer, even if Forge has other signers available.
        vm.startBroadcast(config.deployer);
        deployed.primeAdapter = new ChainlinkPriceOracleAdapter(IAggregatorV3(TempoMainnet.PRIME_USD_CHAINLINK));
        deployed.primePool = _deployPool(
            TempoMainnet.PRIME,
            deployed.primeAdapter,
            config,
            config.primeMaxOracleAge,
            config.primeMaxPriceDeviationBps
        );
        deployed.usdyAdapter = new OndoUSDYPriceOracleAdapter(IOndoUSDYOracleWrapper(TempoMainnet.USDY_ORACLE_WRAPPER));
        deployed.usdyPool = _deployPool(
            TempoMainnet.USDY, deployed.usdyAdapter, config, config.usdyMaxOracleAge, config.usdyMaxPriceDeviationBps
        );
        vm.stopBroadcast();

        _checkPool(
            deployed.primePool,
            config,
            TempoMainnet.PRIME,
            address(deployed.primeAdapter),
            8,
            config.primeMaxOracleAge,
            config.primeMaxPriceDeviationBps,
            primeInventory
        );
        _checkPool(
            deployed.usdyPool,
            config,
            TempoMainnet.USDY,
            address(deployed.usdyAdapter),
            18,
            config.usdyMaxOracleAge,
            config.usdyMaxPriceDeviationBps,
            usdyInventory
        );
        console2.log("PRIME Chainlink source", TempoMainnet.PRIME_USD_CHAINLINK);
        console2.log("PRIME adapter", address(deployed.primeAdapter));
        console2.log("PRIME/USDC.e pool", address(deployed.primePool));
        console2.log("USDY Ondo wrapper", TempoMainnet.USDY_ORACLE_WRAPPER);
        console2.log("USDY adapter", address(deployed.usdyAdapter));
        console2.log("USDY/USDC.e pool", address(deployed.usdyPool));
        console2.log("Both pools paused; no funding, helpers, or trading permissions configured");
        console2.log(
            "PRIME pool pre-existing base / quote inventory unchanged", primeInventory.base, primeInventory.quote
        );
        console2.log("USDY pool pre-existing base / quote inventory unchanged", usdyInventory.base, usdyInventory.quote);
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory) {
        return Config({
            deployer: vm.envAddress("DEPLOYER_ADDRESS"),
            owner: vm.envAddress("OWNER_ADDRESS"),
            guardian: vm.envAddress("GUARDIAN_ADDRESS"),
            primeMaxOracleAge: vm.envUint("PRIME_MAX_ORACLE_AGE"),
            primeMaxPriceDeviationBps: vm.envUint("PRIME_MAX_PRICE_DEVIATION_BPS"),
            usdyMaxOracleAge: vm.envUint("USDY_MAX_ORACLE_AGE"),
            usdyMaxPriceDeviationBps: vm.envUint("USDY_MAX_PRICE_DEVIATION_BPS")
        });
    }

    function _preflight(Config memory config) internal {
        if (config.deployer == address(0)) revert InvalidConfig("DEPLOYER_ADDRESS");
        if (config.owner == address(0)) revert InvalidConfig("OWNER_ADDRESS");
        if (config.guardian == address(0)) revert InvalidConfig("GUARDIAN_ADDRESS");
        if (config.deployer == config.owner || config.deployer == config.guardian) {
            revert InvalidConfig("deployer must have no pool authority");
        }
        if (config.primeMaxOracleAge == 0 || config.primeMaxOracleAge > type(uint80).max) {
            revert InvalidConfig("PRIME_MAX_ORACLE_AGE");
        }
        if (config.usdyMaxOracleAge < 1 days || config.usdyMaxOracleAge > type(uint80).max) {
            revert InvalidConfig("USDY_MAX_ORACLE_AGE");
        }
        if (config.primeMaxPriceDeviationBps > 10_000) revert InvalidConfig("PRIME_MAX_PRICE_DEVIATION_BPS");
        if (config.usdyMaxPriceDeviationBps > 10_000) revert InvalidConfig("USDY_MAX_PRICE_DEVIATION_BPS");

        IAddressRegistry registry = IAddressRegistry(TempoMainnet.ADDRESS_REGISTRY);
        // Administrative callers must be actual accounts, not virtual payment aliases.
        if (registry.resolveRecipient(config.owner) != config.owner) revert InvalidConfig("OWNER_ADDRESS");
        if (registry.resolveRecipient(config.guardian) != config.guardian) revert InvalidConfig("GUARDIAN_ADDRESS");
        _checkToken(TempoMainnet.PRIME, "PRIME");
        _checkToken(TempoMainnet.USDY, "USDY");
        _checkToken(TempoMainnet.USDCE, "USDC.e");

        IAggregatorV3 feed = IAggregatorV3(TempoMainnet.PRIME_USD_CHAINLINK);
        if (feed.decimals() != 8 || keccak256(bytes(feed.description())) != keccak256("PRIME / USD")) {
            revert UnexpectedPrimeFeed();
        }

        // Local-only probes reuse the adapters' complete validation, including a nonzero Ondo wrapper price.
        // They are created BEFORE startBroadcast and are not included in the four deployment transactions.
        ChainlinkPriceOracleAdapter primeProbe = new ChainlinkPriceOracleAdapter(feed);
        OndoUSDYPriceOracleAdapter usdyProbe =
            new OndoUSDYPriceOracleAdapter(IOndoUSDYOracleWrapper(TempoMainnet.USDY_ORACLE_WRAPPER));
        _checkObservation(primeProbe, TempoMainnet.PRIME_USD_CHAINLINK, config.primeMaxOracleAge);
        _checkObservation(usdyProbe, TempoMainnet.USDY_ORACLE_WRAPPER, config.usdyMaxOracleAge);
    }

    function _checkToken(address token, string memory symbol) internal view {
        // Native TIP-20 functionality is checked through its ABI, not an EVM bytecode assumption.
        if (ITIP20(token).decimals() != 6 || keccak256(bytes(ITIP20(token).symbol())) != keccak256(bytes(symbol))) {
            revert UnexpectedToken(token);
        }
    }

    function _checkObservation(IPriceOracle adapter, address source, uint256 maxAge) internal view {
        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        if (price == 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert InvalidObservation(source, price, updatedAt, maxAge);
        }
        console2.log("Validated oracle source", source);
        console2.log("Price / effective timestamp", price, updatedAt);
    }

    function _deployPool(address base, IPriceOracle adapter, Config memory config, uint256 maxAge, uint256 maxDeviation)
        internal
        returns (DirectPropAMM)
    {
        return new DirectPropAMM(
            ITIP20(base),
            ITIP20(TempoMainnet.USDCE),
            adapter,
            IAddressRegistry(TempoMainnet.ADDRESS_REGISTRY),
            config.owner,
            config.guardian,
            maxAge,
            maxDeviation
        );
    }

    function _inventory(address pool, address base) internal view returns (Inventory memory) {
        return Inventory({
            pool: pool, base: ITIP20(base).balanceOf(pool), quote: ITIP20(TempoMainnet.USDCE).balanceOf(pool)
        });
    }

    function _checkPool(
        DirectPropAMM pool,
        Config memory config,
        address base,
        address adapter,
        uint8 oracleDecimals,
        uint256 maxAge,
        uint256 maxDeviation,
        Inventory memory inventory
    ) internal view {
        if (
            address(pool) != inventory.pool || address(pool.baseToken()) != base
                || address(pool.quoteToken()) != TempoMainnet.USDCE || address(pool.oracle()) != adapter
                || address(pool.addressRegistry()) != TempoMainnet.ADDRESS_REGISTRY || pool.baseDecimals() != 6
                || pool.quoteDecimals() != 6 || pool.oracleDecimals() != oracleDecimals
                || pool.priceScale() != 10 ** uint256(oracleDecimals) || pool.maxOracleAge() != maxAge
                || pool.maxPriceDeviationBps() != maxDeviation
        ) revert UnexpectedPoolState(address(pool));
        if (
            !pool.paused() || pool.owner() != config.owner || pool.guardian() != config.guardian
                || pool.pendingOwner() != address(0) || pool.baseToQuotePriceAnchor() != 0
                || pool.quoteToBasePriceAnchor() != 0 || pool.baseToken().balanceOf(address(pool)) != inventory.base
                || pool.quoteToken().balanceOf(address(pool)) != inventory.quote || pool.takerAllowed(config.deployer)
                || pool.recipientAllowed(config.deployer) || pool.takerAllowed(config.owner)
                || pool.recipientAllowed(config.owner) || pool.takerAllowed(config.guardian)
                || pool.recipientAllowed(config.guardian)
        ) revert UnexpectedPoolState(address(pool));
    }
}
