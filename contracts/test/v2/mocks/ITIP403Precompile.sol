// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITIP403Registry } from "../../../src/interfaces/ITIP403Registry.sol";

/// @notice The TIP-403 precompile calls tests make beyond the subset in `ITIP403Registry`, with the precompile's
/// signatures. `MockTIP403Registry` implements them, so a test written against this runs on the mock or, under
/// `forge test --network tempo`, on the precompile.
interface ITIP403Precompile is ITIP403Registry {
    function policyIdCounter() external view returns (uint64);
    function createCompoundPolicy(uint64 senderPolicyId, uint64 recipientPolicyId, uint64 mintRecipientPolicyId)
        external
        returns (uint64);
    function modifyPolicyBlacklist(uint64 policyId, address account, bool restricted) external;
}
