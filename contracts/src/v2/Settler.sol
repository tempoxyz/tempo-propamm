// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ITIP20 } from "../interfaces/ITIP20.sol";
import { ISettler } from "./interfaces/ISettler.sol";
import { IVenue } from "./interfaces/IVenue.sol";

/// @notice The address takers approve for propAMM v2 swaps. Input moves from the caller directly into one venue, which
/// fills under the sponsor the caller names and pays the caller directly: a taker only swaps for itself. The Settler
/// enforces the caller's deadline and amount bound and checks the caller's balance delta. It holds no funds, has no
/// admin and does no routing.
/// @dev Its only state is a transient reentrancy lock shared by both swap functions. It only ever pulls from
/// `msg.sender`, so a leftover allowance can't be spent by anyone else.
///
/// Trust model: a venue is an address the factory deployed a clone of one immutable implementation to, which the
/// Settler proves from the address alone, with no call to the factory or the venue (`_isVenue`): each venue carries its
/// CREATE2 salt in its code, and the swap's venue must sit at the factory's CREATE2 address for the salt its code
/// claims, as OpenZeppelin's `Clones` computes it. Only the factory deploys there, and it initializes each venue in the
/// same call, so no contract whose code or storage anyone else wrote ever fills, whatever code it returned. A venue
/// trusts its settler to have moved the input in before `fill`, and does not re-check it. The Settler makes that pull
/// with `transferFromWithMemo`, requires it to return true, and requires the venue's balance of the input token to rise
/// by exactly the pulled amount before it calls `fill`. A venue admits only initialized Tempo TIP-20s through the
/// canonical factory, and still treats a successful return as insufficient: a token that returns true and moves less,
/// or nothing, reverts the swap (`VenueDeltaMismatch`) instead of releasing the venue's output.
///
/// The caller is the taker and receives the output: there is no recipient parameter. The swap names the sponsor the
/// caller trades under on the venue (`sponsorId`), which the venue checks; the Settler checks no access itself.
///
/// Errors: `ZeroAddress` covers a zero token argument, and in the constructor a zero implementation or one whose
/// `factory()` is zero.
contract Settler is ISettler {
    /// @dev A venue's runtime: the 45-byte EIP-1167 proxy and its 32-byte salt.
    uint256 private constant VENUE_CODE_LENGTH = 77;

    address internal immutable FACTORY;
    address internal immutable IMPLEMENTATION;

    bool private transient _locked;

    modifier nonReentrant() {
        _lock();
        _;
        _unlock();
    }

    /// @param implementation_ The `Venue` implementation every venue clones. The Settler fills only the venues its
    /// `factory()` created.
    constructor(IVenue implementation_) {
        if (address(implementation_) == address(0)) revert ZeroAddress();
        address factory_ = implementation_.factory();
        if (factory_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        IMPLEMENTATION = address(implementation_);
    }

    /// @inheritdoc ISettler
    function factory() external view returns (address) {
        return FACTORY;
    }

    /// @inheritdoc ISettler
    function implementation() external view returns (address) {
        return IMPLEMENTATION;
    }

    /// @inheritdoc ISettler
    /// @dev Reverts with `FillMismatch(amountIn, filledIn, filledOut, filledOut)` when the venue reports using a
    /// different input than it was sent; an exact-in swap has no expected output, so both output fields carry the
    /// venue's reported output.
    function swapExactIn(
        address venueAddress,
        uint16 pairIndex,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint256 minAmountOut,
        uint64 sponsorId,
        uint40 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 amountOut) {
        uint256 takerBefore = _validate(tokenIn, tokenOut, deadline);
        IVenue venue = _venue(venueAddress, amountIn);
        _pull(tokenIn, venueAddress, amountIn, ref);
        (uint128 filledIn, uint128 filledOut) =
            venue.fill(pairIndex, tokenIn, tokenOut, amountIn, true, msg.sender, sponsorId, ref);
        if (filledIn != amountIn) revert FillMismatch(amountIn, filledIn, filledOut, filledOut);
        amountOut = filledOut;
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        _checkTakerDelta(tokenOut, takerBefore, amountOut);
    }

    /// @inheritdoc ISettler
    /// @dev The quoted input is checked against `maxAmountIn` before the pull, so an over-budget swap is never pulled
    /// or filled. Because `fill` must then return exactly the quoted input, it is also the input actually spent.
    function swapExactOut(
        address venueAddress,
        uint16 pairIndex,
        address tokenIn,
        address tokenOut,
        uint128 amountOut,
        uint256 maxAmountIn,
        uint64 sponsorId,
        uint40 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 amountIn) {
        uint256 takerBefore = _validate(tokenIn, tokenOut, deadline);
        IVenue venue = _venue(venueAddress, amountOut);
        (uint128 quotedIn,) = venue.quote(pairIndex, tokenIn, tokenOut, amountOut, false);
        if (quotedIn > maxAmountIn) revert ExcessiveInput(quotedIn, maxAmountIn);
        _pull(tokenIn, venueAddress, quotedIn, ref);
        (uint128 filledIn, uint128 filledOut) =
            venue.fill(pairIndex, tokenIn, tokenOut, amountOut, false, msg.sender, sponsorId, ref);
        if (filledIn != quotedIn || filledOut != amountOut) {
            revert FillMismatch(quotedIn, filledIn, amountOut, filledOut);
        }
        amountIn = filledIn;
        _checkTakerDelta(tokenOut, takerBefore, amountOut);
    }

    /// @dev Checks shared by both swap functions, then snapshots the caller's `tokenOut` balance.
    function _validate(address tokenIn, address tokenOut, uint40 deadline) internal view returns (uint256 takerBefore) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        if (tokenIn == tokenOut) revert SameToken();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        takerBefore = ITIP20(tokenOut).balanceOf(msg.sender);
    }

    function _lock() internal {
        if (_locked) revert Reentrancy();
        _locked = true;
    }

    function _unlock() internal {
        _locked = false;
    }

    function _venue(address venue, uint128 amount) internal view returns (IVenue) {
        if (!_isVenue(venue)) revert UnknownVenue(venue);
        if (amount == 0) revert ZeroAmount();
        return IVenue(venue);
    }

    /// @dev `factory.isVenue`, without the call: `venue` has a venue's 77 bytes of code, the salt
    /// `Clones.fetchCloneArgs` reads from it is nonzero (the factory never uses salt 0, which would need a `keccak256`
    /// preimage of 0), and `venue` is the factory's CREATE2 address for that salt. The length check comes first, so
    /// this never reverts: `fetchCloneArgs` panics on code shorter than the proxy. Its `EXTCODESIZE` also warms the
    /// venue's account, so the copy and the call after it pay the warm rate.
    function _isVenue(address venue) internal view returns (bool) {
        if (venue.code.length != VENUE_CODE_LENGTH) return false;
        bytes memory args = Clones.fetchCloneArgs(venue);
        // `args` is exactly 32 bytes: the code is 77 bytes long.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 salt = bytes32(args);
        return salt != bytes32(0)
            && venue == Clones.predictDeterministicAddressWithImmutableArgs(IMPLEMENTATION, args, salt, FACTORY);
    }

    /// @dev Requires the venue's exact credit, as `Venue` requires on every payout, so `fill` never pays for input that
    /// didn't arrive.
    function _pull(address token, address venue, uint256 amount, bytes32 ref) internal {
        uint256 venueBefore = ITIP20(token).balanceOf(venue);
        if (!ITIP20(token).transferFromWithMemo(msg.sender, venue, amount, ref)) revert TransferFailed(token);
        uint256 venueAfter = ITIP20(token).balanceOf(venue);
        uint256 received = venueAfter > venueBefore ? venueAfter - venueBefore : 0;
        if (received != amount) revert VenueDeltaMismatch(amount, received);
    }

    function _checkTakerDelta(address tokenOut, uint256 takerBefore, uint256 expected) internal view {
        uint256 takerAfter = ITIP20(tokenOut).balanceOf(msg.sender);
        uint256 delta = takerAfter > takerBefore ? takerAfter - takerBefore : 0;
        if (delta < expected) revert TakerDeltaMismatch(expected, delta);
    }
}
