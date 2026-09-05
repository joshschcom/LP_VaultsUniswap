// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStockOracleGuard {
    function maxPriceDeviationBps(bytes32 pairId) external view returns (uint16);

    /// @notice Deviation bound applied to exits; at least `maxPriceDeviationBps`.
    function maxRemovalDeviationBps(bytes32 pairId) external view returns (uint16);

    function pricesUSD18(bytes32 pairId)
        external
        view
        returns (uint256 stockPrice, uint256 usdgPrice);

    function validatePoolPrice(bytes32 pairId, PoolKey calldata key)
        external
        view
        returns (uint256 oracleStockInUsdg, uint256 poolStockInUsdg, uint160 referenceSqrtPriceX96);

    /// @notice Pool validation for exits, using the wider removal deviation bound.
    function validateRemovalPrice(bytes32 pairId, PoolKey calldata key)
        external
        view
        returns (uint256 oracleStockInUsdg, uint256 poolStockInUsdg, uint160 referenceSqrtPriceX96);
}
