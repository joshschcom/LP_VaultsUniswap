// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IStockOracleGuard } from "../../src/interfaces/IStockOracleGuard.sol";

contract MockOracleGuard is IStockOracleGuard {
    uint256 public stockPrice = 100e18;
    uint256 public usdgPrice = 1e18;
    uint160 public referenceSqrtPriceX96 = uint160(1 << 96);
    uint16 public deviationBps = 300;
    bool public shouldRevert;

    function setPrices(uint256 stockPrice_, uint256 usdgPrice_) external {
        stockPrice = stockPrice_;
        usdgPrice = usdgPrice_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setReferenceSqrtPriceX96(uint160 value) external {
        referenceSqrtPriceX96 = value;
    }

    function setMaxPriceDeviationBps(uint16 value) external {
        deviationBps = value;
    }

    function maxPriceDeviationBps(bytes32) external view returns (uint16) {
        return deviationBps;
    }

    function pricesUSD18(bytes32) external view returns (uint256, uint256) {
        require(!shouldRevert, "ORACLE");
        return (stockPrice, usdgPrice);
    }

    function validatePoolPrice(bytes32, PoolKey calldata)
        external
        view
        returns (uint256, uint256, uint160)
    {
        require(!shouldRevert, "ORACLE");
        uint256 price = stockPrice * 1e18 / usdgPrice;
        return (price, price, referenceSqrtPriceX96);
    }
}
