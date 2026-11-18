// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITIP20 } from "../../../src/interfaces/ITIP20.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { IVenueHook } from "../../../src/v2/interfaces/IVenueHook.sol";
import { MockTIP20V2 } from "./MockTIP20V2.sol";

/// @notice Calls `hookTake` from an address that isn't the pair's hook.
contract HookAccomplice {
    function take(IVenue venue, address token, uint256 amount) external {
        venue.hookTake(token, amount);
    }
}

/// @notice A configurable pair hook. It holds its own token balances (standing in for a vault) and can behave
/// honestly (just-in-time top-up and input sweep) or break each rule the venue enforces around its callbacks.
contract MockVenueHook is IVenueHook {
    enum Action {
        None,
        /// @dev Send the venue its `tokenOut` shortfall plus `amount`, capped at this hook's own balance.
        TopUp,
        /// @dev afterFill: `hookTake(tokenIn, amount)`, or the whole input when `amount` is 0.
        Take,
        /// @dev afterFill: `hookTake(tokenIn, amount)` twice.
        TakeTwice,
        /// @dev `hookTake(tokenOut, 1)`.
        TakeWrongToken,
        /// @dev `hookTake(tokenIn, 1)` through `HookAccomplice`.
        TakeViaAccomplice,
        /// @dev Claw `amount` of `tokenIn` back from the venue.
        ReduceIn,
        /// @dev Claw `amount` of `tokenOut` back from the venue.
        ReduceOut,
        /// @dev Take the whole input, then claw `amount` more `tokenIn` back from the venue.
        TakeThenReduceIn,
        /// @dev Send `amount` of both fill tokens to the venue.
        Donate,
        /// @dev Return a selector that isn't the callback's.
        WrongSelector,
        /// @dev Revert with `HookBoom`.
        Revert,
        /// @dev Call `reentryTarget` with `reentryData` and bubble any revert.
        Reenter,
        /// @dev Read `venue.quote` while the venue is locked.
        Observe
    }

    enum Liquidity {
        /// @dev This hook's own balance of the token.
        Balance,
        /// @dev `fixedLiquidity`.
        Fixed,
        Revert,
        /// @dev Spin until out of gas.
        Burn,
        /// @dev Return 16 bytes of 0xff.
        Short,
        /// @dev Return 64 bytes whose first word is `fixedLiquidity`.
        Long
    }

    error HookBoom();

    IVenue public immutable venue;
    HookAccomplice public immutable accomplice;

    uint8 public flags;
    bool public flagsRevert;
    Action public beforeAction;
    Action public afterAction;
    Liquidity public liquidityMode;
    uint256 public fixedLiquidity;
    uint256 public beforeAmount;
    uint256 public afterAmount;
    address public reentryTarget;
    bytes public reentryData;

    uint256 public beforeCalls;
    uint256 public afterCalls;
    FillContext internal _beforeContext;
    FillContext internal _afterContext;
    uint128 public observedQuoteIn;
    uint128 public observedQuoteOut;

    bool public lastCallOk;
    bytes public lastCallData;

    constructor(IVenue venue_, uint8 flags_) {
        venue = venue_;
        flags = flags_;
        accomplice = new HookAccomplice();
    }

    function setFlags(uint8 flags_, bool revert_) external {
        flags = flags_;
        flagsRevert = revert_;
    }

    /// @notice Sets both callbacks' actions, each with `amount_` as its parameter.
    function setActions(Action beforeAction_, Action afterAction_, uint256 amount_) external {
        beforeAction = beforeAction_;
        afterAction = afterAction_;
        beforeAmount = amount_;
        afterAmount = amount_;
    }

    function setAmounts(uint256 beforeAmount_, uint256 afterAmount_) external {
        beforeAmount = beforeAmount_;
        afterAmount = afterAmount_;
    }

    function setLiquidity(Liquidity mode, uint256 fixedLiquidity_) external {
        liquidityMode = mode;
        fixedLiquidity = fixedLiquidity_;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    /// @notice Acts as this contract, for example to accept venue ownership or to call `fill` as the settler.
    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) _bubble(result);
    }

    /// @notice Calls `fill` as the settler, then tries `hookTake` in the same transaction and records the outcome.
    function fillThenTake(bytes calldata fillData, address token, uint256 takeAmount) external {
        (bool ok, bytes memory result) = address(venue).call(fillData);
        if (!ok) _bubble(result);
        (lastCallOk, lastCallData) = address(venue).call(abi.encodeCall(IVenue.hookTake, (token, takeAmount)));
    }

    function beforeContext() external view returns (FillContext memory) {
        return _beforeContext;
    }

    function afterContext() external view returns (FillContext memory) {
        return _afterContext;
    }

    function supportedFlags() external view returns (uint8) {
        if (flagsRevert) revert HookBoom();
        return flags;
    }

    function availableLiquidity(address token) external view returns (uint256) {
        Liquidity mode = liquidityMode;
        if (mode == Liquidity.Balance) return ITIP20(token).balanceOf(address(this));
        if (mode == Liquidity.Fixed) return fixedLiquidity;
        if (mode == Liquidity.Revert) revert HookBoom();
        if (mode == Liquidity.Burn) return _burn();
        uint256 value = fixedLiquidity;
        if (mode == Liquidity.Short) {
            // Half a word of 0xff: a decoder that ignores the length would read a huge number.
            assembly ("memory-safe") {
                mstore(0x00, not(0))
                return(0x00, 16)
            }
        }
        assembly ("memory-safe") {
            mstore(0x00, value)
            mstore(0x20, 0)
            return(0x00, 0x40)
        }
    }

    function beforeFill(FillContext calldata fill) external returns (bytes4) {
        ++beforeCalls;
        _beforeContext = fill;
        return _act(beforeAction, fill, beforeAmount, IVenueHook.beforeFill.selector);
    }

    function afterFill(FillContext calldata fill) external returns (bytes4) {
        ++afterCalls;
        _afterContext = fill;
        return _act(afterAction, fill, afterAmount, IVenueHook.afterFill.selector);
    }

    function _act(Action action, FillContext calldata fill, uint256 amount, bytes4 selector) internal returns (bytes4) {
        if (action == Action.TopUp) {
            uint256 held = ITIP20(fill.tokenOut).balanceOf(address(venue));
            if (held < fill.amountOut) {
                uint256 pull = fill.amountOut - held + amount;
                uint256 own = ITIP20(fill.tokenOut).balanceOf(address(this));
                ITIP20(fill.tokenOut).transferWithMemo(address(venue), pull < own ? pull : own, fill.ref);
            }
        } else if (action == Action.Take) {
            venue.hookTake(fill.tokenIn, amount == 0 ? fill.amountIn : amount);
        } else if (action == Action.TakeTwice) {
            venue.hookTake(fill.tokenIn, amount);
            venue.hookTake(fill.tokenIn, amount);
        } else if (action == Action.TakeWrongToken) {
            venue.hookTake(fill.tokenOut, 1);
        } else if (action == Action.TakeViaAccomplice) {
            accomplice.take(venue, fill.tokenIn, 1);
        } else if (action == Action.ReduceIn) {
            MockTIP20V2(fill.tokenIn).clawback(address(venue), amount);
        } else if (action == Action.ReduceOut) {
            MockTIP20V2(fill.tokenOut).clawback(address(venue), amount);
        } else if (action == Action.TakeThenReduceIn) {
            venue.hookTake(fill.tokenIn, fill.amountIn);
            MockTIP20V2(fill.tokenIn).clawback(address(venue), amount);
        } else if (action == Action.Donate) {
            ITIP20(fill.tokenIn).transferWithMemo(address(venue), amount, fill.ref);
            ITIP20(fill.tokenOut).transferWithMemo(address(venue), amount, fill.ref);
        } else if (action == Action.WrongSelector) {
            return bytes4(0xdeadbeef);
        } else if (action == Action.Revert) {
            revert HookBoom();
        } else if (action == Action.Reenter) {
            (bool ok, bytes memory result) = reentryTarget.call(reentryData);
            if (!ok) _bubble(result);
        } else if (action == Action.Observe) {
            (observedQuoteIn, observedQuoteOut) =
                venue.quote(fill.pairIndex, fill.tokenIn, fill.tokenOut, fill.amountIn, true);
        }
        return selector;
    }

    /// @dev Reads storage until the call runs out of gas.
    function _burn() internal view returns (uint256 sink) {
        while (gasleft() > 0) {
            sink += fixedLiquidity;
        }
    }

    function _bubble(bytes memory result) internal pure {
        assembly ("memory-safe") {
            revert(add(result, 0x20), mload(result))
        }
    }
}
