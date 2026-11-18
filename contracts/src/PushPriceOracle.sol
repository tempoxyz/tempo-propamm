// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

/// @notice Reporter-fed price oracle with monotonic source timestamps and two-step ownership.
/// @dev The pool independently enforces freshness through DirectPropAMM.maxOracleAge().
contract PushPriceOracle is IPriceOracle {
    error FutureTimestamp(uint256 supplied, uint256 currentTime);
    error InvalidAddress();
    error InvalidDecimals();
    error InvalidPrice();
    error NotOwner();
    error NotPendingOwner();
    error NotReporter();
    error TimestampNotIncreasing(uint256 supplied, uint256 current);

    event OwnershipTransferStarted(address indexed oldOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    /// @notice A price observation attributed to the configured reporter, including the constructor seed.
    event PricePushed(uint256 price, uint256 sourceUpdatedAt, address indexed reporter);
    event ReporterUpdated(address indexed oldReporter, address indexed newReporter);

    uint8 public immutable override decimals;

    address public owner;
    address public pendingOwner;
    address public reporter;
    uint256 public price;
    uint256 public updatedAt;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint8 decimals_, address owner_, address reporter_, uint256 initialPrice, uint256 initialUpdatedAt) {
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals();
        if (owner_ == address(0) || reporter_ == address(0)) revert InvalidAddress();

        decimals = decimals_;
        owner = owner_;
        reporter = reporter_;

        emit OwnershipTransferred(address(0), owner_);
        emit ReporterUpdated(address(0), reporter_);
        _push(initialPrice, initialUpdatedAt, reporter_);
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function pushPrice(uint256 newPrice, uint256 sourceUpdatedAt) external {
        if (msg.sender != reporter) revert NotReporter();
        _push(newPrice, sourceUpdatedAt, msg.sender);
    }

    function setReporter(address newReporter) external onlyOwner {
        if (newReporter == address(0)) revert InvalidAddress();
        address oldReporter = reporter;
        reporter = newReporter;
        emit ReporterUpdated(oldReporter, newReporter);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    function _push(uint256 newPrice, uint256 sourceUpdatedAt, address observationReporter) internal {
        if (newPrice == 0) revert InvalidPrice();
        if (sourceUpdatedAt > block.timestamp) revert FutureTimestamp(sourceUpdatedAt, block.timestamp);
        if (sourceUpdatedAt <= updatedAt) revert TimestampNotIncreasing(sourceUpdatedAt, updatedAt);

        price = newPrice;
        updatedAt = sourceUpdatedAt;
        emit PricePushed(newPrice, sourceUpdatedAt, observationReporter);
    }
}
