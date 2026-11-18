// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAddressRegistry } from "../../src/interfaces/IAddressRegistry.sol";

contract MockAddressRegistry is IAddressRegistry {
    mapping(address recipient => address resolved) public resolutions;

    function setResolution(address recipient, address resolved) external {
        resolutions[recipient] = resolved;
    }

    function resolveRecipient(address recipient) external view returns (address) {
        address resolved = resolutions[recipient];
        return resolved == address(0) ? recipient : resolved;
    }
}
