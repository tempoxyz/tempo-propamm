// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MockTIP20 } from "../../mocks/MockTIP20.sol";

/// @notice v1's TIP-20 mock (fees, redirects, virtual-address resolution, reentry) plus an issuer clawback, used to
/// simulate a balance falling outside the venue's control.
/// @dev `feeBps`, `redirectRecipient`, `returnFalse` and `setReentry` are defensive knobs that break the exact-delta
/// checks on purpose; a real TIP-20 can do none of them. `redirectRecipient` in particular sends every transfer, pulls
/// included, to one address: it is a generic delta-breaker, not TIP-1028. For receive policies as Tempo applies them
/// (only the receiver's own policy blocks, funds park in the ReceivePolicyGuard) use `MockGuardedTIP20`.
contract MockTIP20V2 is MockTIP20 {
    constructor(string memory symbol_, uint8 decimals_) MockTIP20(symbol_, decimals_) { }

    function clawback(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}
