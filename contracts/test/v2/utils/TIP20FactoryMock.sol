// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

interface ITestTIP20 {
    function testOnlyIsTIP20() external pure returns (bool);
}

/// @dev A test double for Tempo's canonical factory. It accepts only the repository's explicitly marked TIP-20 mocks,
/// rather than treating every contract with ERC-20-shaped views as a token.
contract TestTIP20Factory {
    function isTIP20(address token) external view returns (bool) {
        (bool success, bytes memory result) = token.staticcall(abi.encodeCall(ITestTIP20.testOnlyIsTIP20, ()));
        return success && result.length == 32 && abi.decode(result, (uint256)) == 1;
    }
}

/// @dev Installs the faithful test double on generic EVMs. Tempo's executor reserves the canonical address, where
/// each explicitly constructed mock registered its own exact reply with `TIP20TestAdmission`.
library TIP20FactoryMock {
    address internal constant PRECOMPILE = 0x20Fc000000000000000000000000000000000000;

    function install(Vm vm) internal {
        if (PRECOMPILE.code.length == 0) vm.etch(PRECOMPILE, type(TestTIP20Factory).runtimeCode);
    }
}
