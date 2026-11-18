// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAddressRegistry {
    function resolveRecipient(address recipient) external view returns (address);
}
