// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";

contract MockOracle is IPriceOracle {
    uint8 public immutable override decimals;
    uint256 public price;
    uint256 public updatedAt;

    constructor(uint8 decimals_, uint256 price_, uint256 updatedAt_) {
        decimals = decimals_;
        setPrice(price_, updatedAt_);
    }

    function setPrice(uint256 price_, uint256 updatedAt_) public {
        price = price_;
        updatedAt = updatedAt_;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }
}
