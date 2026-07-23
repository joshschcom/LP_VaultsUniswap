// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStockOracleGuard {
    function pricesUSD18(bytes32 pairId)
        external
        view
        returns (uint256 stockPrice, uint256 usdgPrice);

    function validatePoolPrice(bytes32 pairId, PoolKey calldata key)
        external
        view
        returns (uint256 oracleStockInUsdg, uint256 poolStockInUsdg);
}
