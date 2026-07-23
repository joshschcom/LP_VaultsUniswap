// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IStockOracleGuard } from "../../src/interfaces/IStockOracleGuard.sol";

contract MockOracleGuard is IStockOracleGuard {
    uint256 public stockPrice = 100e18;
    uint256 public usdgPrice = 1e18;
    bool public shouldRevert;

    function setPrices(uint256 stockPrice_, uint256 usdgPrice_) external {
        stockPrice = stockPrice_;
        usdgPrice = usdgPrice_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function pricesUSD18(bytes32) external view returns (uint256, uint256) {
        require(!shouldRevert, "ORACLE");
        return (stockPrice, usdgPrice);
    }

    function validatePoolPrice(bytes32, PoolKey calldata) external view returns (uint256, uint256) {
        require(!shouldRevert, "ORACLE");
        return (stockPrice * 1e18 / usdgPrice, stockPrice * 1e18 / usdgPrice);
    }
}
