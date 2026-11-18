// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IManagedDirectPropAMM } from "./IManagedDirectPropAMM.sol";

/// @notice Shared approval and execution entry point for single-pool swaps on factory-created Managed pools.
/// @dev Pulls only from the caller and pays the caller. Input moves directly into the pool, never through this contract.
/// The caller is always the taker for access, fees and rounding credits, including a router trading as itself.
/// There is no identity forwarding or router-trust configuration.
interface ISettler {
    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    // Setup and pool provenance.
    error InvalidAddress();
    error UnknownPool(address pool);

    // Settlement.
    error TransferFailed();
    error BalanceMismatch();
    error FillMismatch();

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    function factory() external view returns (address);
    function implementation() external view returns (address);

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Swap using the caller's access, fees and credits, funded by and paid to the caller. Returns output for
    /// exact input, input for exact output; limits remain fee-inclusive.
    /// @dev The pool enforces the deadline, oracle bounds and fee-inclusive amount limit in params.
    function swap(address pool, IManagedDirectPropAMM.SwapParams calldata params) external returns (uint256 result);
}
