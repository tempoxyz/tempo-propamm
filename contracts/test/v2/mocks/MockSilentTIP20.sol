// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITIP20 } from "../../../src/interfaces/ITIP20.sol";
import { TIP20TestAdmission } from "../../mocks/TIP20TestAdmission.sol";

/// @notice A TIP-20 whose transfers can be skewed while still succeeding, to prove the venue checks exact balance
/// deltas rather than trusting the call: it can move nothing (`silent`), debit the sender `debitExtra` more than the
/// amount (a sender-paid fee, burned), or credit the recipient `creditExtra` more than the amount.
contract MockSilentTIP20 is ITIP20 {
    string public override symbol;
    uint8 public immutable override decimals;
    bool public silent;
    uint256 public debitExtra;
    uint256 public creditExtra;

    mapping(address account => uint256 balance) public override balanceOf;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
        TIP20TestAdmission.admit(address(this));
    }

    /// @dev Accepted only by the generic-EVM test factory double.
    function testOnlyIsTIP20() external pure returns (bool) {
        return true;
    }

    function setSilent(bool silent_) external {
        silent = silent_;
    }

    function setSkew(uint256 debitExtra_, uint256 creditExtra_) external {
        debitExtra = debitExtra_;
        creditExtra = creditExtra_;
    }

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        _transfer(from, to, amount);
        return true;
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        _transfer(msg.sender, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (silent) return;
        balanceOf[from] -= amount + debitExtra;
        balanceOf[to] += amount + creditExtra;
    }
}
