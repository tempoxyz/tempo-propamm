// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MockGuardedTIP20 } from "./MockGuardedTIP20.sol";

/// @dev Stands in for a contract originator (a venue, a vault) that sends tokens and may or may not be able to claim.
contract Sender {
    function send(MockGuardedTIP20 token, address to, uint256 amount) external {
        token.transferWithMemo(to, amount, bytes32(0));
    }
}
