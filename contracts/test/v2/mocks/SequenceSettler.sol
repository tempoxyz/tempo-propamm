// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITIP20 } from "../../../src/interfaces/ITIP20.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";

/// @notice Runs a sequence of fills and quotes against one venue inside a single external call, so they share one
/// transaction even with `isolate = true`. Installed as the venue's settler, it moves each fill's input from its own
/// balance the way the real settler does (quote first for exact output). Every fill pays `taker`, under `sponsorId`.
contract SequenceSettler {
    struct Op {
        bool quoteOnly;
        uint16 pairIndex;
        address tokenIn;
        address tokenOut;
        uint128 amount;
        bool exactIn;
    }

    struct Result {
        uint128 amountIn;
        uint128 amountOut;
    }

    bytes32 public constant REF = keccak256("sequence");

    error FillMismatch(uint128 quotedIn, uint128 filledIn, uint128 quotedOut, uint128 filledOut);

    IVenue public immutable venue;
    address public immutable taker;
    uint64 public immutable sponsorId;

    constructor(IVenue venue_, address taker_, uint64 sponsorId_) {
        venue = venue_;
        taker = taker_;
        sponsorId = sponsorId_;
    }

    function run(Op[] calldata ops) external returns (Result[] memory results) {
        results = new Result[](ops.length);
        for (uint256 i; i < ops.length; ++i) {
            Op calldata op = ops[i];
            Result memory r = results[i];
            if (op.quoteOnly) {
                (r.amountIn, r.amountOut) = venue.quote(op.pairIndex, op.tokenIn, op.tokenOut, op.amount, op.exactIn);
            } else {
                (r.amountIn, r.amountOut) = _fill(op);
            }
        }
    }

    function _fill(Op calldata op) internal returns (uint128 amountIn, uint128 amountOut) {
        uint128 quotedIn;
        uint128 quotedOut;
        if (op.exactIn) {
            quotedIn = op.amount;
        } else {
            (quotedIn, quotedOut) = venue.quote(op.pairIndex, op.tokenIn, op.tokenOut, op.amount, false);
        }
        ITIP20(op.tokenIn).transferWithMemo(address(venue), quotedIn, bytes32(0));
        (amountIn, amountOut) =
            venue.fill(op.pairIndex, op.tokenIn, op.tokenOut, op.amount, op.exactIn, taker, sponsorId, REF);
        if (amountIn != quotedIn || (!op.exactIn && amountOut != quotedOut)) {
            revert FillMismatch(quotedIn, amountIn, quotedOut, amountOut);
        }
    }
}
