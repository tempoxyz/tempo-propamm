// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITIP20Factory } from "../../interfaces/ITIP20Factory.sol";

/// @notice Read-only admission checks for Tempo's canonical TIP-20 factory.
library TIP20Factory {
    /// @dev Tempo's fixed TIP-20 factory precompile address.
    address internal constant PRECOMPILE = 0x20Fc000000000000000000000000000000000000;

    /// @dev Fails closed for an absent, reverting or malformed precompile reply. An address's `0x20C0` prefix alone does
    /// not prove its precompile instance was initialized, and testing token movement would be unsafe here.
    function isTIP20(address token) internal view returns (bool) {
        (bool success, bytes memory result) = PRECOMPILE.staticcall(abi.encodeCall(ITIP20Factory.isTIP20, (token)));
        return success && result.length == 32 && abi.decode(result, (uint256)) == 1;
    }
}
