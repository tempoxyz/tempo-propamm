// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Flags a venue stores next to a pair's hook. A pair with flags 0 never calls its hook.
library VenueHookFlags {
    /// @dev Call `beforeFill` before the output is paid. It may only add inventory.
    uint8 internal constant BEFORE_FILL = 1;
    /// @dev Call `afterFill` after the output is paid.
    uint8 internal constant AFTER_FILL = 2;
    /// @dev Let the hook call `IVenue.hookTake` during `afterFill`, for at most the fill's input. Requires AFTER_FILL.
    uint8 internal constant TAKE_INPUT = 4;
    uint8 internal constant ALL = 7;
}

/// @notice A maker-chosen contract called around fills of one pair. The venue only sees this interface, so the
/// strategy behind it (a lending vault, an Earn vault, monitoring) never matters to the venue.
/// @dev Amounts are final before any callback runs, so a hook can never change a price. `msg.sender` is the venue.
interface IVenueHook {
    /// @dev `taker` is the Settler's caller and receives the output; there is no separate recipient. `sponsorId` is the
    /// sponsor the taker traded under (0: the venue's home list), checked on a `Listed` pair and the taker's unchecked
    /// claim on an `Open` one.
    struct FillContext {
        uint16 pairIndex;
        address taker;
        uint64 sponsorId;
        bytes32 ref;
        address tokenIn;
        address tokenOut;
        uint128 amountIn;
        uint128 amountOut;
        bool exactIn;
        uint96 makerMid;
        /// @dev The hot-word seq in force.
        uint32 seq;
    }

    /// @notice The flags this hook implements. `setPairHook` rejects any flag not listed here.
    function supportedFlags() external view returns (uint8);

    /// @notice A conservative amount of `token` that `beforeFill` can add to the calling venue for the next fill.
    /// @dev Must remain deliverable after the fill's input is credited to the venue and its side's consumption
    /// advances: exact-out `quote` samples this view before either, but `beforeFill` runs after both. Base the
    /// amount on the hook's own withdrawable holdings; exclude liquidity that shrinks with those venue-state
    /// changes (for example a top-up target minus venue input inventory). Never overstate. This view reserves
    /// nothing and guarantees nothing against intervening external changes, such as vault withdrawals or a pause.
    /// Venues call it with a gas cap and treat any failure as 0.
    function availableLiquidity(address token) external view returns (uint256);

    /// @notice Must return `IVenueHook.beforeFill.selector`. The venue must hold at least as much of both fill tokens
    /// afterwards as before the call.
    function beforeFill(FillContext calldata fill) external returns (bytes4);

    /// @notice Must return `IVenueHook.afterFill.selector`. With TAKE_INPUT the hook may call `hookTake(tokenIn, x)`
    /// during this call. Afterwards the venue must hold at least its prior `tokenIn` balance minus what was taken, and
    /// at least its prior `tokenOut` balance.
    function afterFill(FillContext calldata fill) external returns (bytes4);
}
