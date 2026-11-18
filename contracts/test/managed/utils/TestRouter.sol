// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISettler } from "../../../src/managed/interfaces/ISettler.sol";
import { IManagedDirectPropAMM as IM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";

/// @dev This test router is itself the taker, as in v2. It funds/receives the leg, then pays the actual caller.
contract TestRouter {
    ISettler public immutable settler;

    constructor(ISettler settler_) {
        settler = settler_;
    }

    function swap(address pool, IM.SwapParams calldata s) external returns (uint256 result) {
        IM.Pair memory pair = IM(pool).pair(s.pairIndex);
        MockTIP20 input = MockTIP20(s.baseToQuote ? pair.base : pair.quote);
        MockTIP20 output = MockTIP20(s.baseToQuote ? pair.quote : pair.base);
        uint256 amountIn = s.amount;
        if (!s.exactInput) {
            (amountIn,,,) =
                IM(pool).quoteExactOutputFor(s.pairIndex, address(this), s.customerId, s.baseToQuote, s.amount);
        }
        if (amountIn != 0) require(input.transferFromWithMemo(msg.sender, address(this), amountIn, s.tradeId));
        input.approve(address(settler), amountIn);
        result = settler.swap(pool, s);
        input.approve(address(settler), 0);
        output.transferWithMemo(msg.sender, s.exactInput ? result : s.amount, s.tradeId);
    }
}

