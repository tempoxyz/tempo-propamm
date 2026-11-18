// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ITIP20 } from "../../../src/interfaces/ITIP20.sol";

/// @dev Follows the `IVenue.fill` / `IVenue.quote` contract at a flat rate that worsens by `impactBps` for every earlier
/// fill in the same transaction, to exercise quote/fill consistency under changing test prices.
/// Each pair can add `bonusBps` to the venue's rate, so a fill routed to the wrong pair prices differently.
/// `fill` is settler-only, binds the two tokens to the pair, requires the input to have arrived already (exactly the
/// priced amount, unless the input check is off) and pays the taker directly. `mode` makes it misbehave.
/// @dev Deployed once as an implementation and used through the clones `SettlerMockFactory` creates, as the Settler
/// accepts only venues its implementation's factory deployed, so all per-venue settings live in storage and each
/// clone sets its settler and rate with `initialize`.
contract SettlerMockVenue {
    enum Mode {
        Honest,
        ReportInPlusOne, // fill reports one more input than it priced
        ReportInMinusOne, // fill reports one less input than it priced
        ReportOutPlusOne, // fill reports one more output than it paid
        ReportOutMinusOne, // fill pays and reports one less output than it priced, so the report matches the payment
        Underpay, // fill pays one less than it reports
        Overpay, // fill pays one more than it reports
        PaySettler, // fill pays its caller instead of the taker
        QuoteDrift, // quote prices DRIFT_BPS better than fill
        QuoteWorse, // quote prices DRIFT_BPS worse than fill
        Reenter, // fill calls the settler with `reentryData` and bubbles its revert
        Unreachable, // quote and fill revert with `Reached`
        FillReverts // quote is honest, fill reverts with `Reached`
    }

    struct Pair {
        address base;
        address quote;
        uint256 bonusBps;
    }

    /// @dev One recorded `fill`, with the input the venue had already received when it ran.
    struct FillCall {
        uint16 pairIndex;
        address tokenIn;
        address tokenOut;
        uint128 amount;
        bool exactIn;
        address taker;
        uint64 sponsorId;
        bytes32 ref;
        uint256 received;
    }

    error NotSettler();
    error TokenMismatch(address tokenIn, address tokenOut);
    error InputNotReceived(uint256 expected, uint256 received);
    error InsufficientInventory(uint256 available, uint256 required);
    error Reached();

    uint256 public constant BPS = 10_000;
    uint256 public constant DRIFT_BPS = 25;

    address internal immutable FACTORY;

    address public settler;
    uint256 public rateBps;
    Mode public mode;
    uint256 public impactBps;
    bool public skipInputCheck;
    bytes public reentryData;

    mapping(uint16 pairIndex => Pair pair) public pairs;
    mapping(address token => uint256 amount) public booked;
    FillCall[] internal _calls;

    uint256 internal transient _fills;

    constructor(address factory_) {
        FACTORY = factory_;
    }

    /// @dev What the Settler reads at construction, as it reads `Venue.factory()`.
    function factory() external view returns (address) {
        return FACTORY;
    }

    function initialize(address settler_, uint256 rateBps_) external {
        settler = settler_;
        rateBps = rateBps_;
    }

    function setPair(uint16 pairIndex, address base, address quoteToken) external {
        pairs[pairIndex] = Pair(base, quoteToken, 0);
    }

    function setPairBonusBps(uint16 pairIndex, uint256 bonusBps) external {
        pairs[pairIndex].bonusBps = bonusBps;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setImpactBps(uint256 impactBps_) external {
        impactBps = impactBps_;
    }

    function setCheckInput(bool checkInput_) external {
        skipInputCheck = !checkInput_;
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    /// @dev Books the current balance, so the next `fill` sees only what arrives after this.
    function sync(address token) public {
        booked[token] = ITIP20(token).balanceOf(address(this));
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 index) external view returns (FillCall memory) {
        return _calls[index];
    }

    function quote(uint16 pairIndex, address tokenIn, address tokenOut, uint128 amount, bool exactIn)
        external
        view
        returns (uint128 amountIn, uint128 amountOut)
    {
        if (mode == Mode.Unreachable) revert Reached();
        _checkPair(pairIndex, tokenIn, tokenOut);
        uint256 rate = _rate(pairIndex);
        if (mode == Mode.QuoteDrift) rate += DRIFT_BPS;
        if (mode == Mode.QuoteWorse) rate -= DRIFT_BPS;
        (amountIn, amountOut) = price(exactIn, amount, rate);
        _checkInventory(tokenOut, amountOut);
    }

    function fill(
        uint16 pairIndex,
        address tokenIn,
        address tokenOut,
        uint128 amount,
        bool exactIn,
        address taker,
        uint64 sponsorId,
        bytes32 ref
    ) external returns (uint128 amountIn, uint128 amountOut) {
        if (msg.sender != settler) revert NotSettler();
        if (mode == Mode.Unreachable || mode == Mode.FillReverts) revert Reached();
        _checkPair(pairIndex, tokenIn, tokenOut);
        (amountIn, amountOut) = price(exactIn, amount, _rate(pairIndex));
        _checkInventory(tokenOut, amountOut);
        ++_fills;

        uint256 received = ITIP20(tokenIn).balanceOf(address(this)) - booked[tokenIn];
        if (!skipInputCheck && received != amountIn) revert InputNotReceived(amountIn, received);
        _calls.push(FillCall(pairIndex, tokenIn, tokenOut, amount, exactIn, taker, sponsorId, ref, received));

        if (mode == Mode.Reenter) {
            (bool ok, bytes memory reason) = settler.call(reentryData);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }

        uint256 paid = amountOut;
        if (mode == Mode.Underpay || mode == Mode.ReportOutMinusOne) paid -= 1;
        if (mode == Mode.Overpay) paid += 1;
        ITIP20(tokenOut).transferWithMemo(mode == Mode.PaySettler ? msg.sender : taker, paid, ref);
        sync(tokenIn);
        sync(tokenOut);

        if (mode == Mode.ReportInPlusOne) amountIn += 1;
        if (mode == Mode.ReportInMinusOne) amountIn -= 1;
        if (mode == Mode.ReportOutPlusOne) amountOut += 1;
        if (mode == Mode.ReportOutMinusOne) amountOut -= 1;
    }

    /// @notice `rate` bps of output per unit of input; exact-in output rounds down, exact-out input rounds up.
    function price(bool exactIn, uint128 amount, uint256 rate)
        public
        pure
        returns (uint128 amountIn, uint128 amountOut)
    {
        // Test amounts stay far below 2^120, so the results fit in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (exactIn) return (amount, uint128(uint256(amount) * rate / BPS));
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint128(Math.ceilDiv(uint256(amount) * BPS, rate)), amount);
    }

    function _rate(uint16 pairIndex) internal view returns (uint256) {
        return rateBps + pairs[pairIndex].bonusBps - impactBps * _fills;
    }

    function _checkPair(uint16 pairIndex, address tokenIn, address tokenOut) internal view {
        Pair memory p = pairs[pairIndex];
        bool forward = tokenIn == p.base && tokenOut == p.quote;
        bool backward = tokenIn == p.quote && tokenOut == p.base;
        if (p.base == address(0) || !(forward || backward)) revert TokenMismatch(tokenIn, tokenOut);
    }

    function _checkInventory(address token, uint256 amountOut) internal view {
        uint256 available = ITIP20(token).balanceOf(address(this));
        if (available < amountOut) revert InsufficientInventory(available, amountOut);
    }
}
