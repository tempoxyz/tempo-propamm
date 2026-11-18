// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPriceOracle {
    /// @notice Number of decimals used by the returned price.
    function decimals() external view returns (uint8);

    /// @notice Returns quote tokens per base token and the effective timestamp of that price.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
}
