// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Optional stages selected by a managed pool's owner for one pair.
library ManagedPoolHookFlags {
    uint8 internal constant QUOTE = 1;
    uint8 internal constant BEFORE_SWAP = 2;
    uint8 internal constant AFTER_SWAP = 4;
    uint8 internal constant ALL = QUOTE | BEFORE_SWAP | AFTER_SWAP;
}

/// @notice One optional hook per managed pair: fee/policy quoting and stateful swap callbacks.
/// @dev The pool calls supportedFlags and quote statically with at most 200,000 gas, and each swap callback with
/// at most 5,000,000 gas. Each must return exactly one canonical ABI word. Any failure blocks the operation.
/// Hooks receive no token allowance and cannot take pool inventory or reenter any pool mutation. Each callback
/// may add inventory, but must not reduce either pair-token balance. Hooks should authenticate msg.sender as their
/// intended pool. Quote fees are capped by the pool at 1,000 bps and stay in its owner's shared inventory.
interface IManagedPoolHook {
    struct QuoteContext {
        uint16 pairIndex;
        address taker;
        bool baseToQuote;
        bool exactInput;
        uint256 amount;
    }

    struct SwapContext {
        QuoteContext quote;
        uint64 sponsorId;
        bytes32 customerId;
        bytes32 tradeId;
        address caller;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
    }

    function supportedFlags() external view returns (uint8);

    /// @notice Returns the input-token fee in basis points, or reverts to refuse the trade.
    /// @dev Identical selector/context for stateless quotes, route-credit quotes and execution. amount is the
    /// requested gross input or exact output, not a credit-adjusted value. Execution authenticates taker; read-only
    /// quotes accept the named taker without authenticating it, granting access or guaranteeing execution.
    /// Direct swaps and view quotes call this before input arrives. Settler fills (including route legs) call it
    /// after input is prepaid into the pool; the pool's tokenIn balance is therefore higher by that input amount.
    /// This context does not expose a prepaid flag or the prepayment amount. A policy requiring identical fees
    /// across these paths must not derive its fee from raw pool token balances; use context or independent policy
    /// state instead. Other state can also change between quote and execution: bind slippage. Settler exact-output
    /// execution requires the fill's input to equal its prepaid quote, reverting FillMismatch if the fee changed.
    function quote(QuoteContext calldata context) external view returns (uint16 feeBps);

    /// @notice Runs after input settlement and final pricing, before the exact output transfer.
    /// @dev caller is the funding/payout taker (the router when routing), never the Settler. Amounts are final
    /// and gross of fees; callback changes cannot reprice this swap. Return this function's selector.
    function beforeSwap(SwapContext calldata context) external returns (bytes4);

    /// @notice Runs after the exact output transfer. Return this function's selector.
    function afterSwap(SwapContext calldata context) external returns (bytes4);
}
