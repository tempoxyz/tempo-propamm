// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The address takers approve. Moves input from the taker directly into one venue, calls its `fill`, and
/// enforces the swap's bound and deadline. Holds no funds, has no admin and does no routing. A taker only swaps for
/// itself: the venue pays the output to the caller.
/// @dev `sponsorId` is the sponsor the caller trades under on the venue: 0 for the venue's home list, or a sponsor the
/// venue registered, enabled and admitted on the pair that has listed the caller there (`Venue.takerAllowed` answers
/// for one id, and `Venue.takerAccess` says why not). A router passes the id of the sponsor the order came through, and
/// the venue records it in `Fill`.
interface ISettler {
    error Reentrancy();
    error DeadlineExpired(uint40 deadline, uint256 timestamp);
    error SameToken();
    error ZeroAddress();
    error ZeroAmount();
    /// @notice The swap's venue isn't one the factory created (the factory's `isVenue`, checked without calling it).
    error UnknownVenue(address venue);
    error TransferFailed(address token);
    error FillMismatch(uint256 expectedIn, uint256 actualIn, uint256 expectedOut, uint256 actualOut);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInput(uint256 amountIn, uint256 maxAmountIn);
    error TakerDeltaMismatch(uint256 expected, uint256 actual);
    /// @notice The pull credited the venue other than exactly the swap's input, so the Settler didn't call `fill`.
    error VenueDeltaMismatch(uint256 expected, uint256 actual);

    /// @notice The factory that creates venues: the implementation's `factory()`. A swap's venue must sit at one of its
    /// CREATE2 addresses (the factory's `isVenue`, checked without calling it).
    function factory() external view returns (address);

    /// @notice The `Venue` implementation every venue clones. The Settler fills only the clones `factory()` created.
    function implementation() external view returns (address);

    /// @notice Pull `amountIn` of `tokenIn` from `msg.sender` into `venue`, require the venue's balance to rise by
    /// exactly that, fill `pairIndex` under `sponsorId`, and require the venue used exactly that input and `msg.sender`
    /// gained at least `minAmountOut` of `tokenOut`.
    function swapExactIn(
        address venue,
        uint16 pairIndex,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint256 minAmountOut,
        uint64 sponsorId,
        uint40 deadline,
        bytes32 ref
    ) external returns (uint256 amountOut);

    /// @notice Quote `amountOut`, enforce `maxAmountIn` before pulling exactly the quoted input, require the venue's
    /// balance to rise by exactly that, fill under `sponsorId`, then require the fill to match the quote and
    /// `msg.sender` to gain the requested output.
    function swapExactOut(
        address venue,
        uint16 pairIndex,
        address tokenIn,
        address tokenOut,
        uint128 amountOut,
        uint256 maxAmountIn,
        uint64 sponsorId,
        uint40 deadline,
        bytes32 ref
    ) external returns (uint256 amountIn);
}
