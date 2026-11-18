// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAddressRegistry } from "../../../src/interfaces/IAddressRegistry.sol";
import { VirtualAddress } from "../utils/VirtualAddress.sol";

/// @notice TIP-1022 resolution as the precompile does it (tempo `address_registry` `resolve_recipient`): only an
/// address with the virtual layout is decoded, and it resolves to the master registered for its 4-byte master id or
/// reverts when none is. Any other address resolves to itself.
contract MockVirtualAddressRegistry is IAddressRegistry {
    error NotVirtual(address account);
    error VirtualAddressUnregistered(address virtualAddress);

    mapping(uint32 masterId => address master) public masterOf;
    /// @dev Makes every resolution return 0, which the precompile never does for a nonzero input.
    bool public returnZero;

    /// @notice Registers `master` behind the master id of `virtualAddress` (every user tag under it); a zero `master`
    /// leaves it unregistered. `virtualAddress` must have the virtual layout.
    function setVirtual(address virtualAddress, address master) external {
        if (!VirtualAddress.isVirtual(virtualAddress)) revert NotVirtual(virtualAddress);
        masterOf[VirtualAddress.masterId(virtualAddress)] = master;
    }

    function setReturnZero(bool returnZero_) external {
        returnZero = returnZero_;
    }

    function resolveRecipient(address recipient) external view returns (address) {
        if (returnZero) return address(0);
        if (!VirtualAddress.isVirtual(recipient)) return recipient;
        address master = masterOf[VirtualAddress.masterId(recipient)];
        if (master == address(0)) revert VirtualAddressUnregistered(recipient);
        return master;
    }
}
