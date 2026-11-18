// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice TIP-1022 virtual-address layout, as tempo `crates/primitives/src/address.rs` builds and decodes it: a 4-byte
/// master id, ten 0xFD bytes (the magic), then a 6-byte user tag.
library VirtualAddress {
    uint80 internal constant MAGIC = 0xFDFDFDFDFDFDFDFDFDFD;

    function make(uint32 master, uint48 userTag) internal pure returns (address) {
        return address((uint160(master) << 128) | (uint160(MAGIC) << 48) | uint160(userTag));
    }

    /// @dev Whether bytes 4 to 13 of `account` are the magic.
    function isVirtual(address account) internal pure returns (bool) {
        // The truncation keeps exactly bytes 4 to 13.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint80(uint160(account) >> 48) == MAGIC;
    }

    function masterId(address account) internal pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(uint160(account) >> 128);
    }
}
