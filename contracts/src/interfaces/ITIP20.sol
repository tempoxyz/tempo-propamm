// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ITIP20 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function transferFromWithMemo(address from, address to, uint256 amount, bytes32 memo) external returns (bool);
    function transferWithMemo(address to, uint256 amount, bytes32 memo) external;
}
