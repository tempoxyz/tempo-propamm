// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAddressRegistry } from "../../../src/interfaces/IAddressRegistry.sol";
import { ITIP20 } from "../../../src/interfaces/ITIP20.sol";
import { TIP20TestAdmission } from "../../mocks/TIP20TestAdmission.sol";

/// @notice A TIP-20 that applies TIP-1028 receive policies the way the T6 precompile does (tempo
/// `tip20::validate_inbound_or_block`, `tip403_registry::check_receive_policy`, `receive_policy_guard::claim`), unlike
/// `MockTIP20V2`'s blanket `redirectRecipient`:
/// - Only the resolved receiver's own policy can block, and it is checked against `from` (the originator, not a
///   spender): first its token filter, then its sender policy.
/// - A blocked transfer does not revert. The amount moves from `from` to the ReceivePolicyGuard and a receipt is kept.
/// - Only the receipt's recovery authority can claim it: the originator by default (recovery authority 0), else the
///   authority the receiver set (itself, or a third party).
/// @dev Simplified: one token, so the token filter is one flag; the sender policy is a whitelist or blacklist of
/// senders; a claim pays `to` without re-checking policies.
contract MockGuardedTIP20 is ITIP20 {
    /// @notice The ReceivePolicyGuard precompile address.
    address public constant GUARD = 0xB10C000000000000000000000000000000000000;

    error AddressReserved();
    error InvalidReceipt();
    error UnauthorizedClaimer();

    event TransferBlocked(
        uint256 indexed receiptId, address indexed originator, address indexed receiver, uint256 amount, uint8 reason
    );

    /// @dev `TransferBlocked.reason`, as the precompile's `BlockedReason`.
    uint8 public constant TOKEN_FILTER = 1;
    uint8 public constant RECEIVE_POLICY = 2;

    struct ReceivePolicy {
        bool active;
        /// @dev Whether this token passes the receiver's token filter.
        bool tokenAllowed;
        /// @dev True: only listed senders pass. False: every sender passes except listed ones.
        bool senderWhitelist;
        /// @dev 0 = the originator claims; otherwise this address does.
        address recoveryAuthority;
    }

    struct Receipt {
        address originator;
        address receiver;
        address recoveryAuthority;
        uint256 amount;
    }

    string public override symbol;
    uint8 public constant override decimals = 6;
    IAddressRegistry public resolver;

    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    mapping(address receiver => ReceivePolicy) public receivePolicy;
    mapping(address receiver => mapping(address sender => bool)) public senderListed;
    Receipt[] public receipts;

    constructor(string memory symbol_) {
        symbol = symbol_;
        TIP20TestAdmission.admit(address(this));
    }

    /// @dev Accepted only by the generic-EVM test factory double.
    function testOnlyIsTIP20() external pure returns (bool) {
        return true;
    }

    function setResolver(IAddressRegistry resolver_) external {
        resolver = resolver_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[_resolve(to)] += amount;
    }

    /// @notice Sets the caller's receive policy.
    function setReceivePolicy(bool tokenAllowed, bool senderWhitelist, address recoveryAuthority) external {
        receivePolicy[msg.sender] = ReceivePolicy(true, tokenAllowed, senderWhitelist, recoveryAuthority);
    }

    /// @notice Lists or unlists `sender` in the caller's sender policy.
    function setSenderListed(address sender, bool listed) external {
        senderListed[msg.sender][sender] = listed;
    }

    function clearReceivePolicy() external {
        delete receivePolicy[msg.sender];
    }

    function receiptCount() external view returns (uint256) {
        return receipts.length;
    }

    /// @notice Releases a receipt to `to`. Only its recovery authority may call.
    function claim(uint256 receiptId, address to) external {
        Receipt storage r = receipts[receiptId];
        address authority = r.recoveryAuthority == address(0) ? r.originator : r.recoveryAuthority;
        if (msg.sender != authority) revert UnauthorizedClaimer();
        uint256 amount = r.amount;
        if (amount == 0) revert InvalidReceipt();
        r.amount = 0;
        balanceOf[GUARD] -= amount;
        balanceOf[_resolve(to)] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        address target = _resolve(to);
        if (target == GUARD) revert AddressReserved();
        balanceOf[from] -= amount;
        uint8 reason = _blockedReason(from, target);
        if (reason == 0) {
            balanceOf[target] += amount;
            return;
        }
        balanceOf[GUARD] += amount;
        receipts.push(Receipt(from, target, receivePolicy[target].recoveryAuthority, amount));
        emit TransferBlocked(receipts.length - 1, from, target, amount, reason);
    }

    function _blockedReason(address from, address target) internal view returns (uint8) {
        ReceivePolicy storage p = receivePolicy[target];
        if (!p.active) return 0;
        if (!p.tokenAllowed) return TOKEN_FILTER;
        if (senderListed[target][from] != p.senderWhitelist) return RECEIVE_POLICY;
        return 0;
    }

    function _resolve(address account) internal view returns (address) {
        return address(resolver) == address(0) ? account : resolver.resolveRecipient(account);
    }
}
