// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";

/// @notice Adds or removes a taker, a resolved recipient, or both on a DirectPropAMM. Run with the pool-owner signer.
/// @dev Each requested role needs its address and an explicit `true` or `false` permission flag. Omit both inputs to
/// leave a role unchanged. Every input is checked before broadcasting; at least one role must be requested.
/// A ManagedDirectPropAMM admits takers per pair instead, through its home lists and its sponsors' lists
/// (`setMembers(pairIndex, sponsorId, accounts, allowed)`), as a v2 venue does: prepare those calls with
/// `ManagedPoolAccess.s.sol` (`MODE=LIST`).
contract ConfigurePool is Script {
    error InvalidConfig(string field);

    function run() external {
        DirectPropAMM pool = DirectPropAMM(vm.parseAddress(_envString("POOL_ADDRESS")));
        (address taker, bool takerAllowed) = _role("TAKER_ADDRESS", "TAKER_ALLOWED");
        (address recipient, bool recipientAllowed) = _role("RECIPIENT_ADDRESS", "RECIPIENT_ALLOWED");
        if (taker == address(0) && recipient == address(0)) revert InvalidConfig("no role requested");

        vm.startBroadcast();
        if (taker != address(0)) pool.setTakerAllowed(taker, takerAllowed);
        if (recipient != address(0)) pool.setRecipientAllowed(recipient, recipientAllowed);
        vm.stopBroadcast();
    }

    /// @dev Read strings, not defaulted booleans: malformed input must never become an authorization grant.
    function _role(string memory addressKey, string memory allowedKey)
        internal
        view
        returns (address account, bool allowed)
    {
        string memory addressValue = _envString(addressKey);
        string memory allowedValue = _envString(allowedKey);
        if (bytes(addressValue).length == 0 && bytes(allowedValue).length == 0) return (account, allowed);
        if (bytes(addressValue).length == 0) revert InvalidConfig(addressKey);
        if (bytes(allowedValue).length == 0) revert InvalidConfig(allowedKey);
        account = vm.parseAddress(addressValue);
        if (account == address(0)) revert InvalidConfig(addressKey);
        bytes32 flag = keccak256(bytes(allowedValue));
        allowed = flag == keccak256("true");
        if (!allowed && flag != keccak256("false")) revert InvalidConfig(allowedKey);
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel script suites.
    function _envString(string memory key) internal view virtual returns (string memory) {
        return vm.envOr(key, string(""));
    }
}
