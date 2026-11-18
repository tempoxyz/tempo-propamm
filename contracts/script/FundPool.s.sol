// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";

/// @notice Funds an independently reviewed immutable pool with its owner signer, paused or not.
/// @dev Expected identity inputs must come from a verified deployment record, never the untrusted target's getters.
contract FundPool is Script {
    using SafeERC20 for IERC20;

    error InvalidConfig(string field);

    struct Config {
        DirectPropAMM pool;
        uint256 chainId;
        address owner;
        address base;
        address quote;
        bytes32 poolCodehash;
        uint256 baseAmount;
        uint256 quoteAmount;
    }

    function run() external {
        Config memory config = _readConfig();
        _preflight(config);

        // Select the reviewed owner explicitly, even when Forge has other signers available.
        vm.startBroadcast(config.owner);
        if (config.baseAmount != 0) {
            _fund(config.pool, config.base, config.baseAmount, keccak256("INITIAL_BASE_INVENTORY"));
        }
        if (config.quoteAmount != 0) {
            _fund(config.pool, config.quote, config.quoteAmount, keccak256("INITIAL_QUOTE_INVENTORY"));
        }
        vm.stopBroadcast();
    }

    /// @dev Test harnesses override this to avoid process-global deployment inputs.
    function _readConfig() internal view virtual returns (Config memory config) {
        config.pool = DirectPropAMM(vm.envAddress("POOL_ADDRESS"));
        config.chainId = vm.envUint("EXPECTED_CHAIN_ID");
        config.owner = vm.envAddress("EXPECTED_OWNER");
        config.base = vm.envAddress("EXPECTED_BASE");
        config.quote = vm.envAddress("EXPECTED_QUOTE");
        config.poolCodehash = vm.envBytes32("EXPECTED_POOL_CODEHASH");
        config.baseAmount = _optionalUint("BASE_AMOUNT");
        config.quoteAmount = _optionalUint("QUOTE_AMOUNT");
    }

    function _preflight(Config memory config) internal view {
        if (config.chainId == 0 || block.chainid != config.chainId) revert InvalidConfig("EXPECTED_CHAIN_ID");
        if (address(config.pool).code.length == 0) revert InvalidConfig("POOL_ADDRESS");
        if (config.owner == address(0)) revert InvalidConfig("EXPECTED_OWNER");
        if (config.base == address(0)) revert InvalidConfig("EXPECTED_BASE");
        if (config.quote == address(0) || config.quote == config.base) revert InvalidConfig("EXPECTED_QUOTE");

        // Pin the independently verified immutable runtime before calling the target.
        // A proxy hash alone proves no implementation identity.
        if (config.poolCodehash == bytes32(0) || address(config.pool).codehash != config.poolCodehash) {
            revert InvalidConfig("EXPECTED_POOL_CODEHASH");
        }
        // These are state checks on the reviewed code, not self-reported evidence of provenance.
        if (config.pool.owner() != config.owner) revert InvalidConfig("EXPECTED_OWNER");
        if (address(config.pool.baseToken()) != config.base) revert InvalidConfig("EXPECTED_BASE");
        if (address(config.pool.quoteToken()) != config.quote) revert InvalidConfig("EXPECTED_QUOTE");
    }

    function _fund(DirectPropAMM pool, address token, uint256 amount, bytes32 memo) internal {
        // Only the independently configured token receives an exact allowance, never a target-selected token.
        IERC20(token).forceApprove(address(pool), amount);
        pool.fund(token, amount, memo);
        // Broadcast transactions are separate: an interrupted send still needs an owner-reviewed allowance revocation.
        IERC20(token).forceApprove(address(pool), 0);
    }

    /// @dev Only absent fields default to zero; malformed values must fail before any broadcast.
    function _optionalUint(string memory field) internal view returns (uint256) {
        return vm.envExists(field) ? vm.envUint(field) : 0;
    }
}
