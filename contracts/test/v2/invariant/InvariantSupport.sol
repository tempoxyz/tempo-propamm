// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { IVenueHook, VenueHookFlags } from "../../../src/v2/interfaces/IVenueHook.sol";
import { LadderMath } from "../../../src/v2/libraries/LadderMath.sol";
import { ShapeWord } from "../../../src/v2/libraries/ShapeWord.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";

/// @notice The invariant suite's ghost pricer: `LadderMath.fill` behind an external call, so the handler can catch
/// `InsufficientDepth` and `ZeroFill` and compare every fill with what the posted ladder allows after the side's
/// consumed depth.
contract LadderPricer {
    /// @param words The pair's four shape words for the active shape, as the handler last set them.
    /// @param consumed The side's consumed base, as the handler's ghost tracks it.
    function price(
        bytes32 hot,
        uint64 sizeUnit,
        bool baseIn,
        uint256[4] calldata words,
        bool exactIn,
        uint256 amount,
        uint256 consumed
    ) external pure returns (uint256 amountIn, uint256 amountOut, uint256 baseFilled) {
        uint256 w0 = baseIn ? words[0] : words[2];
        uint256 w1 = ShapeWord.continues(w0) ? (baseIn ? words[1] : words[3]) : 0;
        return LadderMath.fill(LadderMath.curve(hot, sizeUnit, baseIn), w0, w1, exactIn, amount, consumed);
    }
}

/// @notice The campaign's pair hook. It keeps a reserve of pair tokens itself, standing in for whatever source a
/// maker's own hook draws on. `beforeFill` tops the venue up when it holds less than the fill's output: the shortfall
/// plus `refill`, as far as the reserve goes. `afterFill` takes up to `maxTake` of the input back with `hookTake`, and
/// reports a refusal (a pair without `TAKE_INPUT`) instead of reverting the fill. Each move emits an event the handler
/// attributes to the next `Fill`, then checks against the venue's and the hook's balances. The handler can switch
/// either move off, make `availableLiquidity` read 0 or revert, and move the reserve.
contract ReserveHook is IVenueHook {
    error ViewsDown();

    event Pulled(address indexed token, uint256 amount);
    event Took(address indexed token, uint256 amount);
    event TakeRefused(address indexed token, uint256 amount, bytes4 reason);

    /// @dev `availableLiquidity` reports the reserve, 0, or reverts.
    uint8 internal constant VIEW_RESERVE = 0;
    uint8 internal constant VIEW_ZERO = 1;
    uint8 internal constant VIEW_REVERT = 2;

    IVenue public immutable VENUE;
    uint256 public refill;
    uint256 public maxTake;
    bool public pullOff;
    bool public takeOff;
    uint8 public viewMode;

    constructor(IVenue venue_) {
        VENUE = venue_;
    }

    function configure(uint256 refill_, uint256 maxTake_) external {
        (refill, maxTake) = (refill_, maxTake_);
    }

    function setSwitches(bool pullOff_, bool takeOff_, uint8 viewMode_) external {
        (pullOff, takeOff, viewMode) = (pullOff_, takeOff_, viewMode_);
    }

    function supportedFlags() external pure returns (uint8) {
        return VenueHookFlags.ALL;
    }

    /// @dev Never overstates: 0 while pulls are off.
    function availableLiquidity(address token) external view returns (uint256) {
        if (viewMode == VIEW_REVERT) revert ViewsDown();
        if (viewMode == VIEW_ZERO || pullOff) return 0;
        return MockTIP20V2(token).balanceOf(address(this));
    }

    function beforeFill(FillContext calldata fill) external returns (bytes4) {
        uint256 held = MockTIP20V2(fill.tokenOut).balanceOf(address(VENUE));
        if (!pullOff && held < fill.amountOut) {
            uint256 amount =
                Math.min(fill.amountOut - held + refill, MockTIP20V2(fill.tokenOut).balanceOf(address(this)));
            if (amount != 0) {
                MockTIP20V2(fill.tokenOut).transferWithMemo(address(VENUE), amount, bytes32("pull"));
                emit Pulled(fill.tokenOut, amount);
            }
        }
        return IVenueHook.beforeFill.selector;
    }

    function afterFill(FillContext calldata fill) external returns (bytes4) {
        uint256 amount = Math.min(fill.amountIn, maxTake);
        if (!takeOff && amount != 0) {
            try VENUE.hookTake(fill.tokenIn, amount) {
                emit Took(fill.tokenIn, amount);
            } catch (bytes memory err) {
                emit TakeRefused(fill.tokenIn, amount, bytes4(err));
            }
        }
        return IVenueHook.afterFill.selector;
    }
}
