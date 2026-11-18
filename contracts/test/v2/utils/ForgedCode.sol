// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Deploys any runtime code over any storage: the constructor writes each `slots[i] = values[i]`, then returns
/// `code` as the contract's runtime. `EXTCODEHASH` and `EXTCODECOPY` see only `code`, so a contract made this way
/// can carry a real venue's exact code over storage nobody initialized, which is how the venue checks are attacked.
contract ForgedCode {
    constructor(bytes32[] memory slots, bytes32[] memory values, bytes memory code) {
        for (uint256 i; i < slots.length; ++i) {
            bytes32 slot = slots[i];
            bytes32 value = values[i];
            assembly ("memory-safe") {
                sstore(slot, value)
            }
        }
        assembly ("memory-safe") {
            return(add(code, 0x20), mload(code))
        }
    }
}

library Forgery {
    /// @dev A contract with `runtime` as its code and no storage.
    function deploy(bytes memory runtime) internal returns (address) {
        return address(new ForgedCode(new bytes32[](0), new bytes32[](0), runtime));
    }

    /// @dev A contract with `runtime` as its code over `slots[i] = values[i]`.
    function deploy(bytes memory runtime, bytes32[] memory slots, bytes32[] memory values) internal returns (address) {
        return address(new ForgedCode(slots, values, runtime));
    }
}
