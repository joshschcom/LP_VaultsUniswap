// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IStockOracleGuard } from "../../src/interfaces/IStockOracleGuard.sol";

contract MockOracleGuard is IStockOracleGuard {
    uint256 public stockPrice = 100e18;
    uint256 public usdgPrice = 1e18;
    uint160 public referenceSqrtPriceX96 = uint160(1 << 96);
    uint16 public deviationBps = 300;
    uint16 public removalDeviationBps;
    bool public shouldRevert;
    bool public removalShouldRevert;
    /// @dev Pool past the allocation bound but still inside the wider removal bound.
    bool public allocationShouldRevert;

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

    function maxRemovalDeviationBps(bytes32) external view returns (uint16) {
        return removalDeviationBps == 0 ? deviationBps : removalDeviationBps;
    }

    function setMaxRemovalDeviationBps(uint16 value) external {
        removalDeviationBps = value;
    }

    /// @dev Separate toggle so a test can block allocation while exits still succeed.
    function setRemovalShouldRevert(bool value) external {
        removalShouldRevert = value;
    }

    function setAllocationShouldRevert(bool value) external {
        allocationShouldRevert = value;
    }

    function validateRemovalPrice(bytes32, PoolKey calldata)
        external
        view
        returns (uint256, uint256, uint160)
    {
        require(!shouldRevert && !removalShouldRevert, "ORACLE");
        uint256 price = stockPrice * 1e18 / usdgPrice;
        return (price, price, referenceSqrtPriceX96);
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
        require(!shouldRevert && !allocationShouldRevert, "ORACLE");
        uint256 price = stockPrice * 1e18 / usdgPrice;
        return (price, price, referenceSqrtPriceX96);
    }
}
