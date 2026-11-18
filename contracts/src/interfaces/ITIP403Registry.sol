// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The subset of the TIP-403 policy registry precompile that `contracts/script/DeployParPool.s.sol` calls to
/// preflight the pair tokens' transfer policies (`isAuthorizedSender`, `isAuthorizedRecipient`), plus the calls
/// `MockTIP403Registry` implements and `contracts/test/v2/MockFidelity.t.sol` holds to the precompile. No contract in
/// `contracts/src` calls a TIP-403 registry: `ManagedDirectPropAMM` keeps v2 `Venue`'s access in its own storage, and
/// propAMM v2 calls none either.
/// @dev Policy 0 rejects everyone and policy 1 allows everyone; both always exist. Each other policy has exactly one
/// admin. `isAuthorizedSender` and `isAuthorizedRecipient` (TIP-1015) need hardfork T2 or later.
interface ITIP403Registry {
    enum PolicyType {
        WHITELIST,
        BLACKLIST,
        COMPOUND
    }

    function policyExists(uint64 policyId) external view returns (bool);
    function policyData(uint64 policyId) external view returns (PolicyType policyType, address admin);
    function isAuthorizedSender(uint64 policyId, address user) external view returns (bool);
    function isAuthorizedRecipient(uint64 policyId, address user) external view returns (bool);

    function createPolicy(address admin, PolicyType policyType) external returns (uint64);
    /// @dev The registry accepts `address(0)`, after which the policy can never change again.
    function setPolicyAdmin(uint64 policyId, address admin) external;
    /// @dev Whitelist policies only. Rejects virtual (TIP-1022) addresses from T3.
    function modifyPolicyWhitelist(uint64 policyId, address account, bool allowed) external;
}
