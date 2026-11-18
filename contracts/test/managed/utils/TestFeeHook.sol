// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedPoolHook, ManagedPoolHookFlags } from "../../../src/managed/interfaces/IManagedPoolHook.sol";

/// @dev Test-only rate policy. Fees are deliberately outside pool storage and follow its current owner.
contract TestFeeHook is IManagedPoolHook {
    error NotOwner();
    error NotPool();

    ManagedDirectPropAMM public immutable pool;
    mapping(uint16 => mapping(address => uint16[2])) private rates;

    constructor(ManagedDirectPropAMM pool_) {
        pool = pool_;
    }

    function supportedFlags() external pure returns (uint8) {
        return ManagedPoolHookFlags.QUOTE;
    }

    /// @dev Allows over-cap values so tests can exercise the pool's validation of an untrusted hook response.
    function setFees(uint16 pairIndex, address taker, uint16 sell, uint16 buy) external {
        if (msg.sender != pool.owner()) revert NotOwner();
        rates[pairIndex][taker] = [sell, buy];
    }

    function fees(uint16 pairIndex, address taker) external view returns (uint16 sell, uint16 buy) {
        return (rates[pairIndex][taker][0], rates[pairIndex][taker][1]);
    }

    function quote(QuoteContext calldata context) external view returns (uint16) {
        if (msg.sender != address(pool)) revert NotPool();
        return rates[context.pairIndex][context.taker][context.baseToQuote ? 0 : 1];
    }

    function beforeSwap(SwapContext calldata) external view returns (bytes4) {
        if (msg.sender != address(pool)) revert NotPool();
        return IManagedPoolHook.beforeSwap.selector;
    }

    function afterSwap(SwapContext calldata) external view returns (bytes4) {
        if (msg.sender != address(pool)) revert NotPool();
        return IManagedPoolHook.afterSwap.selector;
    }
}

/// @dev Fixture convenience only: callers close the pair before its first hook installation. Zero-fee fixtures
/// never call this and therefore continue exercising the production no-hook path.
library TestFeeHookLib {
    function configureFees(ManagedDirectPropAMM pool, uint16 pairIndex, address taker, uint16 sell, uint16 buy)
        internal
    {
        (address installed,) = pool.pairHook(pairIndex);
        if (installed == address(0)) {
            installed = address(new TestFeeHook(pool));
            pool.setPairHook(pairIndex, installed, ManagedPoolHookFlags.QUOTE);
        }
        TestFeeHook(installed).setFees(pairIndex, taker, sell, buy);
    }

    function testFees(ManagedDirectPropAMM pool, uint16 pairIndex, address taker)
        internal
        view
        returns (uint16 sell, uint16 buy)
    {
        (address installed,) = pool.pairHook(pairIndex);
        if (installed == address(0)) return (0, 0);
        return TestFeeHook(installed).fees(pairIndex, taker);
    }
}
