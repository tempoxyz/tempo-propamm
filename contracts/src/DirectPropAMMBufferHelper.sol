// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IDirectPropAMM } from "./interfaces/IDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "./managed/interfaces/IManagedDirectPropAMM.sol";
import { IVedaBufferHelper } from "./interfaces/IVedaBufferHelper.sol";

/// @notice Builds Veda BoringVault management calls for a quote-token vault invested in the pool's base token.
/// @dev The Veda Teller calls this helper, then executes the returned calls from the BoringVault via `manage`.
///      This contract never holds tokens and has no authority over the vault or pool. It serves either pool kind,
///      detected once at construction: a `DirectPropAMM` swap pays `vault` as its recipient, and a
///      `ManagedDirectPropAMM` swap pays its caller, which is the vault, on the pair `pairIndex` names, under the list
///      `sponsorId` names (0 for the pair's home list, else a sponsor's list the vault is on). Managed quotes use
///      `vault` as the taker, never this helper or its caller. Slippage bounds use those fee-inclusive quotes;
///      this helper does not enforce an independent cap on the vault's configured swap fees.
contract DirectPropAMMBufferHelper is IVedaBufferHelper {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    bytes32 private constant _DEPOSIT = keccak256("DIRECT_PROP_VEDA_DEPOSIT");
    bytes32 private constant _WITHDRAW = keccak256("DIRECT_PROP_VEDA_WITHDRAW");

    error AmountIsZero();
    error CustomerIdIsZero();
    error InvalidAddress();
    error InvalidPair();
    error PairIndexUnsupported(uint16 pairIndex);
    error SlippageTooHigh(uint256 supplied, uint256 maximum);
    error SponsorIdUnsupported(uint64 sponsorId);
    error UnsupportedAsset(address asset);

    IDirectPropAMM public immutable pool;
    address public immutable vault;
    address public immutable baseToken;
    address public immutable quoteToken;
    bytes32 public immutable customerId;
    uint16 public immutable slippageBps;
    /// @notice Whether `pool` is a `ManagedDirectPropAMM`: it answers `pair(pairIndex)`.
    bool public immutable managed;
    /// @notice The pair the vault trades on a `ManagedDirectPropAMM`. Always 0 otherwise.
    uint16 public immutable pairIndex;
    /// @notice The list the vault trades under on a `ManagedDirectPropAMM` (0: the pair's home list). Always 0
    /// otherwise.
    uint64 public immutable sponsorId;

    /// @param pairIndex_ For a `ManagedDirectPropAMM`, the live pair whose base the vault holds and whose quote is its
    ///        asset (`InvalidPair` otherwise). Must be 0 for a `DirectPropAMM` (`PairIndexUnsupported`).
    /// @param sponsorId_ For a `ManagedDirectPropAMM`, the list that admits `vault_` on the pair: 0 for its home list
    ///        or a registered sponsor's. Must be 0 for a `DirectPropAMM` (`SponsorIdUnsupported`).
    constructor(
        IDirectPropAMM pool_,
        address vault_,
        bytes32 customerId_,
        uint16 slippageBps_,
        uint16 pairIndex_,
        uint64 sponsorId_
    ) {
        if (address(pool_) == address(0) || vault_ == address(0)) revert InvalidAddress();
        if (customerId_ == bytes32(0)) revert CustomerIdIsZero();
        if (slippageBps_ > MAX_SLIPPAGE_BPS) {
            revert SlippageTooHigh(slippageBps_, MAX_SLIPPAGE_BPS);
        }

        // A `DirectPropAMM` has neither `pair(uint16)` nor a fallback, so the call reverts and lands in `catch`.
        bool managed_ = false;
        address baseToken_;
        address quoteToken_;
        try IManagedDirectPropAMM(address(pool_)).pair(pairIndex_) returns (IManagedDirectPropAMM.Pair memory info) {
            managed_ = true;
            (baseToken_, quoteToken_) = (info.base, info.quote);
        } catch {
            if (pairIndex_ != 0) revert PairIndexUnsupported(pairIndex_);
            if (sponsorId_ != 0) revert SponsorIdUnsupported(sponsorId_);
            baseToken_ = pool_.baseToken();
            quoteToken_ = pool_.quoteToken();
        }
        // A removed or unknown Managed pair reads all zero.
        if (baseToken_ == address(0) || quoteToken_ == address(0) || baseToken_ == quoteToken_) revert InvalidPair();

        pool = pool_;
        vault = vault_;
        managed = managed_;
        pairIndex = pairIndex_;
        sponsorId = sponsorId_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        customerId = customerId_;
        slippageBps = slippageBps_;
    }

    /// @notice Converts all newly deposited quote token into the pool's base token.
    function getDepositManageCall(address asset, uint256 amount)
        external
        view
        returns (address[] memory targets, bytes[] memory data, uint256[] memory values)
    {
        _validate(asset, amount);

        (uint256 quotedBaseOut, uint256 oraclePrice, uint256 oracleUpdatedAt) = managed
            ? IManagedDirectPropAMM(address(pool)).quoteExactInput(pairIndex, vault, false, amount)
            : pool.quoteExactInput(false, amount);
        uint256 minimumBaseOut = Math.mulDiv(quotedBaseOut, BPS - slippageBps, BPS);

        targets = new address[](4);
        data = new bytes[](4);
        values = new uint256[](4);

        targets[0] = quoteToken;
        data[0] = abi.encodeCall(IERC20.approve, (address(pool), 0));
        targets[1] = quoteToken;
        data[1] = abi.encodeCall(IERC20.approve, (address(pool), amount));
        targets[2] = address(pool);
        data[2] = managed
            ? abi.encodeCall(
                IManagedDirectPropAMM.swapExactInput,
                (
                    pairIndex,
                    false,
                    amount,
                    minimumBaseOut,
                    sponsorId,
                    customerId,
                    _tradeId(_DEPOSIT, amount),
                    block.timestamp,
                    oraclePrice,
                    0,
                    oracleUpdatedAt
                )
            )
            : abi.encodeCall(
                IDirectPropAMM.swapExactInput,
                (
                    false,
                    amount,
                    minimumBaseOut,
                    vault,
                    customerId,
                    _tradeId(_DEPOSIT, amount),
                    block.timestamp,
                    oraclePrice,
                    0,
                    oracleUpdatedAt
                )
            );
        targets[3] = quoteToken;
        data[3] = abi.encodeCall(IERC20.approve, (address(pool), 0));
    }

    /// @notice Sells only enough base token to cover the vault's quote-token redemption shortfall.
    function getWithdrawManageCall(address asset, uint256 amount)
        external
        view
        returns (address[] memory targets, bytes[] memory data, uint256[] memory values)
    {
        _validate(asset, amount);

        uint256 quoteBalance = IERC20(quoteToken).balanceOf(vault);
        if (quoteBalance >= amount) {
            return (new address[](0), new bytes[](0), new uint256[](0));
        }

        uint256 shortfall = amount - quoteBalance;
        (uint256 quotedBaseIn, uint256 oraclePrice, uint256 oracleUpdatedAt) = managed
            ? IManagedDirectPropAMM(address(pool)).quoteExactOutput(pairIndex, vault, true, shortfall)
            : pool.quoteExactOutput(true, shortfall);
        uint256 maximumBaseIn = Math.mulDiv(quotedBaseIn, BPS + slippageBps, BPS, Math.Rounding.Ceil);

        targets = new address[](4);
        data = new bytes[](4);
        values = new uint256[](4);

        targets[0] = baseToken;
        data[0] = abi.encodeCall(IERC20.approve, (address(pool), 0));
        targets[1] = baseToken;
        data[1] = abi.encodeCall(IERC20.approve, (address(pool), maximumBaseIn));
        targets[2] = address(pool);
        data[2] = managed
            ? abi.encodeCall(
                IManagedDirectPropAMM.swapExactOutput,
                (
                    pairIndex,
                    true,
                    shortfall,
                    maximumBaseIn,
                    sponsorId,
                    customerId,
                    _tradeId(_WITHDRAW, shortfall),
                    block.timestamp,
                    oraclePrice,
                    0,
                    oracleUpdatedAt
                )
            )
            : abi.encodeCall(
                IDirectPropAMM.swapExactOutput,
                (
                    true,
                    shortfall,
                    maximumBaseIn,
                    vault,
                    customerId,
                    _tradeId(_WITHDRAW, shortfall),
                    block.timestamp,
                    oraclePrice,
                    0,
                    oracleUpdatedAt
                )
            );
        targets[3] = baseToken;
        data[3] = abi.encodeCall(IERC20.approve, (address(pool), 0));
    }

    function _validate(address asset, uint256 amount) internal view {
        if (asset != quoteToken) revert UnsupportedAsset(asset);
        if (amount == 0) revert AmountIsZero();
    }

    function _tradeId(bytes32 operation, uint256 amount) internal view returns (bytes32) {
        return keccak256(abi.encode(operation, customerId, vault, amount, block.chainid, block.number));
    }
}
