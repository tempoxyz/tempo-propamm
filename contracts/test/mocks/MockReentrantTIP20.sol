// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITIP20 } from "../../src/interfaces/ITIP20.sol";

/// @notice A TIP-20 mock whose next transfer, a payout (`transferWithMemo`) or a pull (`transferFromWithMemo`), first
/// calls `reentryTarget` with `reentryData`, before it moves any balance, and records the outcome. A test points it at
/// the contract that is paying or pulling, to try to re-enter it mid-transfer.
/// @dev `MockTIP20.setReentry` fires only on pulls; this one also fires on payouts, such as a pool's `withdraw`. The
/// call is one-shot: `setReentry` arms it and the next transfer clears it, so a re-entry that got through could not
/// recurse. A real TIP-20 makes no such call. No fees, redirects or address resolution.
contract MockReentrantTIP20 is ITIP20 {
    string public override symbol;
    uint8 public immutable override decimals;
    address public reentryTarget;
    bytes public reentryData;
    /// @dev The last re-entry's outcome: whether the call succeeded, and its return or revert data.
    bool public reentrySucceeded;
    bytes public reentryResult;

    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }

    /// @notice Arms the next transfer to call `target` with `data` first.
    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        _reenter();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        _reenter();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function _reenter() internal {
        address target = reentryTarget;
        if (target == address(0)) return;
        reentryTarget = address(0);
        (reentrySucceeded, reentryResult) = target.call(reentryData);
    }
}
