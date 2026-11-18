// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { VirtualAddress } from "../utils/VirtualAddress.sol";
import { ITIP403Precompile } from "./ITIP403Precompile.sol";

/// @notice Models the TIP-403 registry semantics the v1 deploy scripts' transfer-policy preflights rely on, as tempo
/// `tip403_registry` applies them from T6: built-in policies 0 (reject all) and 1 (allow all) with no admin,
/// single-admin simple policies, compound policies over simple sender and recipient policies, `PolicyNotFound` for an
/// unknown id, whitelists that refuse TIP-1022 virtual addresses, a `setPolicyAdmin` that accepts `address(0)` like the
/// precompile does, a ReceivePolicyGuard that every policy authorizes, and the precompile's events, emitted on every
/// edit even when nothing changes.
contract MockTIP403Registry is ITIP403Precompile {
    /// @notice The TIP-1028 ReceivePolicyGuard precompile. From T6 the registry authorizes it as a sender and as a
    /// recipient before it reads the policy id, so policy 0, a whitelist without it, a blacklist that lists it, a
    /// compound and even an unknown id all pass it (tempo `tip403_registry::ALWAYS_AUTHORIZED`).
    address public constant RECEIVE_POLICY_GUARD = 0xB10C000000000000000000000000000000000000;

    error Unauthorized();
    error PolicyNotFound();
    error PolicyNotSimple();
    error IncompatiblePolicyType();
    error VirtualAddressNotAllowed();

    struct Policy {
        PolicyType policyType;
        address admin;
        uint64 senderPolicyId;
        uint64 recipientPolicyId;
    }

    uint64 public policyIdCounter = 2;
    mapping(uint64 policyId => Policy) internal _policies;
    mapping(uint64 policyId => mapping(address account => bool listed)) public listed;

    event PolicyAdminUpdated(uint64 indexed policyId, address indexed updater, address indexed admin);
    event PolicyCreated(uint64 indexed policyId, address indexed updater, PolicyType policyType);
    event WhitelistUpdated(uint64 indexed policyId, address indexed updater, address indexed account, bool allowed);
    event BlacklistUpdated(uint64 indexed policyId, address indexed updater, address indexed account, bool restricted);
    event CompoundPolicyCreated(
        uint64 indexed policyId,
        address indexed creator,
        uint64 senderPolicyId,
        uint64 recipientPolicyId,
        uint64 mintRecipientPolicyId
    );

    function policyExists(uint64 policyId) public view returns (bool) {
        return policyId < policyIdCounter;
    }

    function policyData(uint64 policyId) external view returns (PolicyType policyType, address admin) {
        if (policyId == 0) return (PolicyType.WHITELIST, address(0));
        if (policyId == 1) return (PolicyType.BLACKLIST, address(0));
        if (!policyExists(policyId)) revert PolicyNotFound();
        Policy storage p = _policies[policyId];
        return (p.policyType, p.admin);
    }

    function isAuthorizedSender(uint64 policyId, address user) external view returns (bool) {
        return user == RECEIVE_POLICY_GUARD || _authorized(policyId, user, true);
    }

    function isAuthorizedRecipient(uint64 policyId, address user) external view returns (bool) {
        return user == RECEIVE_POLICY_GUARD || _authorized(policyId, user, false);
    }

    /// @dev Emits `PolicyCreated` then `PolicyAdminUpdated`, both with the caller as `updater`.
    function createPolicy(address admin, PolicyType policyType) external returns (uint64 policyId) {
        if (policyType == PolicyType.COMPOUND) revert IncompatiblePolicyType();
        policyId = policyIdCounter++;
        _policies[policyId] = Policy(policyType, admin, 0, 0);
        emit PolicyCreated(policyId, msg.sender, policyType);
        emit PolicyAdminUpdated(policyId, msg.sender, admin);
    }

    /// @notice Mirrors `createCompoundPolicy`. It checks the sender, recipient and mint parts in that order, and each
    /// must be built-in or an existing simple policy. The mock has no mint authorization, so it checks the mint part
    /// and emits it but doesn't store it.
    function createCompoundPolicy(uint64 senderPolicyId, uint64 recipientPolicyId, uint64 mintRecipientPolicyId)
        public
        returns (uint64 policyId)
    {
        _requireSimple(senderPolicyId);
        _requireSimple(recipientPolicyId);
        _requireSimple(mintRecipientPolicyId);
        policyId = policyIdCounter++;
        _policies[policyId] = Policy(PolicyType.COMPOUND, address(0), senderPolicyId, recipientPolicyId);
        emit CompoundPolicyCreated(policyId, msg.sender, senderPolicyId, recipientPolicyId, mintRecipientPolicyId);
    }

    /// @notice Test helper: `createCompoundPolicy` with mint part 0, which rejects every mint recipient.
    function createCompoundPolicy(uint64 senderPolicyId, uint64 recipientPolicyId) external returns (uint64) {
        return createCompoundPolicy(senderPolicyId, recipientPolicyId, 0);
    }

    /// @dev Policies 0 and 1 exist with admin `address(0)`, so changing them reverts `Unauthorized`.
    function setPolicyAdmin(uint64 policyId, address admin) external {
        if (!policyExists(policyId)) revert PolicyNotFound();
        if (_policies[policyId].admin != msg.sender) revert Unauthorized();
        _policies[policyId].admin = admin;
        emit PolicyAdminUpdated(policyId, msg.sender, admin);
    }

    function modifyPolicyWhitelist(uint64 policyId, address account, bool allowed) external {
        if (VirtualAddress.isVirtual(account)) revert VirtualAddressNotAllowed();
        if (!policyExists(policyId)) revert PolicyNotFound();
        Policy storage p = _policies[policyId];
        if (p.admin != msg.sender) revert Unauthorized();
        if (p.policyType != PolicyType.WHITELIST) revert IncompatiblePolicyType();
        listed[policyId][account] = allowed;
        emit WhitelistUpdated(policyId, msg.sender, account, allowed);
    }

    /// @notice Mirrors `modifyPolicyBlacklist`, which the v2 interface leaves out.
    function modifyPolicyBlacklist(uint64 policyId, address account, bool restricted) external {
        if (VirtualAddress.isVirtual(account)) revert VirtualAddressNotAllowed();
        if (!policyExists(policyId)) revert PolicyNotFound();
        if (_policies[policyId].admin != msg.sender) revert Unauthorized();
        _setBlacklisted(policyId, account, restricted);
    }

    /// @notice Test helper: `modifyPolicyBlacklist` without the existence and admin checks.
    function setBlacklisted(uint64 policyId, address account, bool restricted) external {
        if (VirtualAddress.isVirtual(account)) revert VirtualAddressNotAllowed();
        _setBlacklisted(policyId, account, restricted);
    }

    function _setBlacklisted(uint64 policyId, address account, bool restricted) internal {
        if (_policies[policyId].policyType != PolicyType.BLACKLIST) revert IncompatiblePolicyType();
        listed[policyId][account] = restricted;
        emit BlacklistUpdated(policyId, msg.sender, account, restricted);
    }

    function _authorized(uint64 policyId, address user, bool sender) internal view returns (bool) {
        if (policyId == 0) return false;
        if (policyId == 1) return true;
        if (!policyExists(policyId)) revert PolicyNotFound();
        Policy storage p = _policies[policyId];
        if (p.policyType == PolicyType.WHITELIST) return listed[policyId][user];
        if (p.policyType == PolicyType.BLACKLIST) return !listed[policyId][user];
        return _authorized(sender ? p.senderPolicyId : p.recipientPolicyId, user, sender);
    }

    function _requireSimple(uint64 policyId) internal view {
        if (policyId < 2) return;
        if (!policyExists(policyId)) revert PolicyNotFound();
        if (_policies[policyId].policyType == PolicyType.COMPOUND) revert PolicyNotSimple();
    }
}
