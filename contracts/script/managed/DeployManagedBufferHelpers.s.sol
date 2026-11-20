// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Script, console2 } from "forge-std/Script.sol";

import { DirectPropAMMBufferHelper } from "../../src/DirectPropAMMBufferHelper.sol";
import { IDirectPropAMM } from "../../src/interfaces/IDirectPropAMM.sol";

/// @notice Deploys the `DirectPropAMMBufferHelper`s that connect Veda BoringVaults to one `ManagedDirectPropAMM`, one
/// per entry. A helper holds no tokens and has no authority: the pool's owner still admits each BoringVault on its
/// pair (`ManagedPoolAccess`), and the Veda authority still allows the helper and selects it on the Teller.
/// @dev Inputs: `POOL_ADDRESS`, and comma-separated with one entry per helper: `HELPER_VAULTS` (the BoringVault
/// itself), `HELPER_PAIR_INDEXES`, `HELPER_SPONSOR_IDS` (0 for the pair's home list), `HELPER_CUSTOMER_IDS` (nonzero
/// 32-byte route ids) and `HELPER_SLIPPAGE_BPS`. The helper's constructor refuses an unknown pair, a zero customer id
/// and a slippage above its maximum. Each helper's tokens are logged: compare them with the pair you meant. Forge
/// sends only with `--broadcast`.
contract DeployManagedBufferHelpers is Script {
    using SafeCast for uint256;

    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);

    function run() external returns (address[] memory) {
        return deploy(
            vm.envAddress("POOL_ADDRESS"),
            vm.envAddress("HELPER_VAULTS", ","),
            vm.envUint("HELPER_PAIR_INDEXES", ","),
            vm.envUint("HELPER_SPONSOR_IDS", ","),
            vm.envBytes32("HELPER_CUSTOMER_IDS", ","),
            vm.envUint("HELPER_SLIPPAGE_BPS", ",")
        );
    }

    /// @dev `run`'s body with its inputs passed in, so tests need no process-global environment.
    function deploy(
        address pool,
        address[] memory vaults,
        uint256[] memory pairIndexes,
        uint256[] memory sponsorIds,
        bytes32[] memory customerIds,
        uint256[] memory slippageBps
    ) public returns (address[] memory deployed) {
        if (block.chainid != 4217 && block.chainid != 42431) {
            revert UnexpectedChain(block.chainid);
        }
        uint256 count = vaults.length;
        if (
            count == 0 || pairIndexes.length != count || sponsorIds.length != count || customerIds.length != count
                || slippageBps.length != count
        ) revert InvalidConfig("HELPER_* lists need one entry per helper");

        deployed = new address[](count);
        vm.startBroadcast();
        for (uint256 i; i < count; ++i) {
            deployed[i] = address(
                new DirectPropAMMBufferHelper(
                    IDirectPropAMM(pool),
                    vaults[i],
                    customerIds[i],
                    slippageBps[i].toUint16(),
                    pairIndexes[i].toUint16(),
                    sponsorIds[i].toUint64()
                )
            );
        }
        vm.stopBroadcast();

        for (uint256 i; i < count; ++i) {
            DirectPropAMMBufferHelper helper = DirectPropAMMBufferHelper(deployed[i]);
            // A `DirectPropAMM` takes the helper's single-pair path with pair and sponsor 0.
            if (!helper.managed()) revert InvalidConfig("POOL_ADDRESS is not a ManagedDirectPropAMM");
            console2.log("DirectPropAMMBufferHelper", deployed[i]);
            console2.log("  vault / pair index", vaults[i], pairIndexes[i]);
            console2.log("  base / quote", helper.baseToken(), helper.quoteToken());
        }
    }
}
