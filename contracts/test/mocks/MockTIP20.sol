// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAddressRegistry } from "../../src/interfaces/IAddressRegistry.sol";
import { ITIP20 } from "../../src/interfaces/ITIP20.sol";
import { TIP20TestAdmission } from "./TIP20TestAdmission.sol";

contract MockTIP20 is ITIP20 {
    string public override symbol;
    uint8 public immutable override decimals;
    IAddressRegistry public resolver;
    uint16 public feeBps;
    address public redirectRecipient;
    bool public returnFalse;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
        TIP20TestAdmission.admit(address(this));
    }

    /// @dev The test-only canonical factory recognizes this explicit marker. Production admission always calls Tempo's
    /// factory precompile, whose initialized-token counter is authoritative.
    function testOnlyIsTIP20() external pure returns (bool) {
        return true;
    }

    function setResolver(IAddressRegistry resolver_) external {
        resolver = resolver_;
    }

    function setFeeBps(uint16 feeBps_) external {
        feeBps = feeBps_;
    }

    function setRedirectRecipient(address recipient) external {
        redirectRecipient = recipient;
    }

    function setReturnFalse(bool returnFalse_) external {
        returnFalse = returnFalse_;
    }

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
        if (returnFalse) return false;
        if (reentryTarget != address(0)) {
            (reentrySucceeded, reentryResult) = reentryTarget.call(reentryData);
        }
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        _transfer(msg.sender, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        address effective = redirectRecipient == address(0) ? _resolve(to) : redirectRecipient;
        uint256 received = amount - (amount * feeBps / 10_000);
        balanceOf[effective] += received;
    }

    function _resolve(address recipient) internal view returns (address) {
        return address(resolver) == address(0) ? recipient : resolver.resolveRecipient(recipient);
    }
}
