// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Narrow `DirectPropAMM` interface used by Veda-compatible integrations and the rebalance controller.
/// @dev `ManagedDirectPropAMM` shares only `paused`, `pause`, `unpause`, `withdraw` and `roundingCredit`: it holds many
/// pairs, so its quotes, swaps and `roundingRouteKey` take a `pairIndex`, and its swaps pay their caller and name a
/// `sponsorId` instead of a recipient (see `IManagedDirectPropAMM`).
interface IDirectPropAMM {
    function baseToken() external view returns (address);
    function quoteToken() external view returns (address);
    function paused() external view returns (bool);

    function pause() external;
    function unpause() external;
    function withdraw(address token, address recipient, uint256 amount, bytes32 memo) external;

    function quoteExactInput(bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt);

    function quoteExactOutput(bool baseToQuote, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint256 price, uint256 updatedAt);

    function quoteExactInputFor(
        address taker,
        address recipient,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 price, uint256 updatedAt, uint256 creditAfter);

    function quoteExactOutputFor(
        address taker,
        address recipient,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 price, uint256 updatedAt, uint256 creditAfter);

    function roundingRouteKey(address taker, address recipient, bytes32 customerId) external view returns (bytes32);

    function roundingCredit(bytes32 routeKey) external view returns (uint256);

    /// @notice Swaps an exact input within the caller's quoted-price tolerance using a non-older observation.
    function swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountOut);

    /// @notice Swaps for an exact output within the caller's quoted-price tolerance using a non-older observation.
    function swapExactOutput(
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountIn);
}
