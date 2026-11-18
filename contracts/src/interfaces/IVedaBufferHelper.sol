// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice ABI-compatible subset of Veda's IBufferHelper.
/// @dev This local interface avoids importing or redistributing Veda's licensed implementation.
interface IVedaBufferHelper {
    function getDepositManageCall(address asset, uint256 amount)
        external
        view
        returns (address[] memory targets, bytes[] memory data, uint256[] memory values);

    function getWithdrawManageCall(address asset, uint256 amount)
        external
        view
        returns (address[] memory targets, bytes[] memory data, uint256[] memory values);
}
