// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { ITIP20 } from "../interfaces/ITIP20.sol";
import { IManagedDirectPropAMM } from "./interfaces/IManagedDirectPropAMM.sol";
import { ISettler } from "./interfaces/ISettler.sol";

/// @notice Shared approval/execution entry point for single-pool swaps on factory-created Managed pools.
/// @dev Input goes directly from the caller to the pool, and output goes to the caller, so this contract never
/// holds a balance. The caller is always the taker for access, fees and credits, including a router trading as itself.
/// There is no identity forwarding.
/// Proves pool provenance from its CREATE2 address and embedded salt without trusting candidate code or storage.
/// The pool trusts this contract to transfer and verify input before fill. Exact-output fills must equal quotes.
contract Settler is ISettler, ReentrancyGuardTransient {
    uint256 private constant POOL_CODE_LENGTH = 77;
    string private constant SWAP_IN = "SWAP_IN";
    address public immutable override factory;
    address public immutable override implementation;

    constructor(IManagedDirectPropAMM implementation_) {
        if (address(implementation_) == address(0)) revert InvalidAddress();
        address factory_ = implementation_.factory();
        if (factory_ == address(0)) revert InvalidAddress();
        factory = factory_;
        implementation = address(implementation_);
    }

    /// @inheritdoc ISettler
    function swap(address poolAddress, IManagedDirectPropAMM.SwapParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 result)
    {
        if (!_isPool(poolAddress)) revert UnknownPool(poolAddress);
        IManagedDirectPropAMM pool = IManagedDirectPropAMM(poolAddress);
        if (block.timestamp > params.deadline) {
            revert IManagedDirectPropAMM.DeadlineExpired(params.deadline, block.timestamp);
        }
        IManagedDirectPropAMM.Pair memory pair = pool.pair(params.pairIndex);
        if (pair.base == address(0)) revert IManagedDirectPropAMM.UnknownPair(params.pairIndex);
        (address tokenIn, address tokenOut) = params.baseToQuote ? (pair.base, pair.quote) : (pair.quote, pair.base);
        uint256 amountIn = params.amount;
        if (!params.exactInput) {
            (amountIn,,,) = pool.quoteExactOutputFor(
                params.pairIndex, msg.sender, params.customerId, params.baseToQuote, params.amount
            );
            if (amountIn > params.limit) revert IManagedDirectPropAMM.SlippageExceeded(params.limit, amountIn);
        }
        result = _fill(poolAddress, params, tokenIn, tokenOut, amountIn);
    }

    /// @dev Pulls input from the caller directly into the pool, fills, and checks exact balance deltas.
    /// An exact-output fill must take exactly the quoted input. Returns output for exact input, input for exact output.
    function _fill(
        address poolAddress,
        IManagedDirectPropAMM.SwapParams calldata params,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) private returns (uint256 result) {
        uint256 callerIn = ITIP20(tokenIn).balanceOf(msg.sender);
        uint256 callerOut = ITIP20(tokenOut).balanceOf(msg.sender);
        if (amountIn != 0) {
            uint256 poolBefore = ITIP20(tokenIn).balanceOf(poolAddress);
            // The direct path's input memo, so one trade carries the same memo whichever entry point settles it.
            bytes32 memo = keccak256(abi.encode(SWAP_IN, params.customerId, params.tradeId));
            if (!ITIP20(tokenIn).transferFromWithMemo(msg.sender, poolAddress, amountIn, memo)) {
                revert TransferFailed();
            }
            if (
                ITIP20(tokenIn).balanceOf(poolAddress) != poolBefore + amountIn
                    || ITIP20(tokenIn).balanceOf(msg.sender) + amountIn != callerIn
            ) revert BalanceMismatch();
        }
        result = IManagedDirectPropAMM(poolAddress).fill(params, msg.sender);
        if (!params.exactInput && result != amountIn) revert FillMismatch();
        uint256 amountOut = params.exactInput ? result : params.amount;
        if (
            ITIP20(tokenIn).balanceOf(msg.sender) + amountIn != callerIn
                || ITIP20(tokenOut).balanceOf(msg.sender) != callerOut + amountOut
        ) revert BalanceMismatch();
    }

    /// @dev v2's address-only provenance proof. Length guard makes arbitrary candidate addresses safe to inspect.
    function _isPool(address pool) private view returns (bool) {
        if (pool.code.length != POOL_CODE_LENGTH) return false;
        bytes memory args = Clones.fetchCloneArgs(pool);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 salt = bytes32(args);
        return salt != bytes32(0)
            && pool == Clones.predictDeterministicAddressWithImmutableArgs(implementation, args, salt, factory);
    }
}
