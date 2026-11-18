// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenue } from "../../../../src/v2/interfaces/IVenue.sol";
import { IVenueHook, VenueHookFlags } from "../../../../src/v2/interfaces/IVenueHook.sol";

/// @notice Runs several calls in one transaction as itself. `foundry.toml` sets `isolate = true`, so every top-level
/// test call is its own transaction; anything that depends on transient state (a lock, the hookTake window)
/// across calls must run inside one `run`.
contract TxBatcher {
    struct Call {
        address target;
        bytes data;
    }

    function run(Call[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = calls[i].target.call(calls[i].data);
            if (!ok) _bubble(result);
            results[i] = result;
        }
    }

    function _bubble(bytes memory result) private pure {
        assembly ("memory-safe") {
            revert(add(result, 0x20), mload(result))
        }
    }
}

/// @notice A maker's quoting bot, installed as a venue updater. `poke` posts a pre-armed `post` batch on the
/// `fireOn`-th poke only, so it can move a quote in the middle of someone else's transaction: tests point a token's
/// transfer reentry at it, which fires inside the Settler's input pull, between a venue's `quote` and its `fill`.
contract MakerBot {
    IVenue public immutable VENUE;
    bytes public pending;
    uint256 public fireOn;
    uint256 public pokes;
    bool public fired;

    constructor(IVenue venue_) {
        VENUE = venue_;
    }

    function arm(bytes calldata packed, uint256 fireOn_) external {
        pending = packed;
        fireOn = fireOn_;
        pokes = 0;
        fired = false;
    }

    function poke() external {
        ++pokes;
        if (pokes != fireOn || pending.length == 0) return;
        fired = true;
        VENUE.post(pending);
    }
}

/// @notice A hook that does nothing and approves everything: the cost of the hook seam itself.
contract NoopHook is IVenueHook {
    function supportedFlags() external pure returns (uint8) {
        return VenueHookFlags.ALL;
    }

    function availableLiquidity(address) external pure returns (uint256) {
        return 0;
    }

    function beforeFill(FillContext calldata) external pure returns (bytes4) {
        return IVenueHook.beforeFill.selector;
    }

    function afterFill(FillContext calldata) external pure returns (bytes4) {
        return IVenueHook.afterFill.selector;
    }
}

/// @notice A scripted hook that makes arbitrary calls from inside `beforeFill` or `afterFill`: a malicious hook
/// trying to reenter the Settler or another venue, or a monitoring hook that halts another venue mid-route. Each
/// action either bubbles its revert (`strict`) or records the outcome and carries on.
contract CallbackHook is IVenueHook {
    enum Phase {
        Before,
        After
    }

    struct Action {
        Phase phase;
        address target;
        bytes data;
        bool strict;
    }

    struct Outcome {
        bool ok;
        bytes4 selector;
    }

    Action[] internal _actions;
    Outcome[] internal _outcomes;

    uint256 public beforeCalls;
    uint256 public afterCalls;

    function addAction(Phase phase, address target, bytes calldata data, bool strict) external {
        _actions.push(Action({ phase: phase, target: target, data: data, strict: strict }));
    }

    function clearActions() external {
        delete _actions;
        delete _outcomes;
    }

    function outcomes() external view returns (Outcome[] memory) {
        return _outcomes;
    }

    /// @notice Acts as this contract, for example to approve the Settler.
    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) _bubble(result);
    }

    function supportedFlags() external pure returns (uint8) {
        return VenueHookFlags.ALL;
    }

    function availableLiquidity(address) external pure returns (uint256) {
        return 0;
    }

    function beforeFill(FillContext calldata) external returns (bytes4) {
        ++beforeCalls;
        _run(Phase.Before);
        return IVenueHook.beforeFill.selector;
    }

    function afterFill(FillContext calldata) external returns (bytes4) {
        ++afterCalls;
        _run(Phase.After);
        return IVenueHook.afterFill.selector;
    }

    function _run(Phase phase) private {
        uint256 length = _actions.length;
        for (uint256 i; i < length; ++i) {
            Action storage action = _actions[i];
            if (action.phase != phase) continue;
            (bool ok, bytes memory result) = action.target.call(action.data);
            if (!ok && action.strict) _bubble(result);
            bytes4 selector;
            if (result.length >= 4) selector = bytes4(result);
            _outcomes.push(Outcome({ ok: ok, selector: ok ? bytes4(0) : selector }));
        }
    }

    function _bubble(bytes memory result) private pure {
        assembly ("memory-safe") {
            revert(add(result, 0x20), mload(result))
        }
    }
}
