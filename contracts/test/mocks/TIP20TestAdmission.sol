// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITIP20Factory } from "../../src/interfaces/ITIP20Factory.sol";

interface IHevmMockCall {
    function mockCall(address callee, bytes calldata data, bytes calldata returnData) external;
}

/// @dev Each test token explicitly admits only itself. Foundry intercepts this call to its cheatcode address; a native
/// test executor rejects or ignores it, so deployed mock bytecode remains usable on Anvil and its factory runtime does
/// the same marker check.
library TIP20TestAdmission {
    address private constant VM = address(uint160(uint256(keccak256("hevm cheat code"))));
    address private constant PRECOMPILE = 0x20Fc000000000000000000000000000000000000;

    function admit(address token) internal {
        // Deliberately ignore the call's result: hevm records it, while an ordinary EVM has no hevm cheatcode.
        VM.call(
            abi.encodeCall(
                IHevmMockCall.mockCall, (PRECOMPILE, abi.encodeCall(ITIP20Factory.isTIP20, (token)), abi.encode(true))
            )
        );
    }
}
