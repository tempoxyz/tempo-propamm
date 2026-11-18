// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Tempo's TIP-20 factory precompile.
interface ITIP20Factory {
    /// @notice Whether `token` is an initialized Tempo TIP-20.
    /// @dev The precompile checks both the reserved TIP-20 address prefix and the token's initialization counter.
    function isTIP20(address token) external view returns (bool);
}
