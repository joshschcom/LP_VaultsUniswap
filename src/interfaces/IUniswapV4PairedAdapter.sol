// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IUniswapV4PairedAdapter {
    struct RegisterPairParams {
        address stockToken;
        address usdg;
        PoolKey poolKey;
        bytes32 expectedPoolId;
        uint16 removalToleranceBps;
    }

    struct PositionState {
        uint256 tokenId;
        uint128 liquidity;
        uint256 stockAmount;
        uint256 usdgAmount;
    }

    function registerPair(bytes32 pairId, RegisterPairParams calldata params) external;
    function poolKey(bytes32 pairId) external view returns (PoolKey memory);
    function positionState(bytes32 pairId) external view returns (PositionState memory);

    function addLiquidity(
        bytes32 pairId,
        uint256 stockDesired,
        uint256 usdgDesired,
        uint256 deadline
    ) external returns (uint256 stockUsed, uint256 usdgUsed, uint128 liquidityAdded);

    function decreaseLiquidity(
        bytes32 pairId,
        uint128 liquidity,
        uint160 referenceSqrtPriceX96,
        uint256 deadline
    ) external returns (uint256 stockReceived, uint256 usdgReceived, uint128 liquidityRemoved);

    function collectFees(bytes32 pairId, uint256 deadline)
        external
        returns (uint256 stockFees, uint256 usdgFees);

    function swapExactInput(
        bytes32 pairId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountInUsed, uint256 amountOut);

    function burnEmptyPosition(bytes32 pairId, uint256 deadline)
        external
        returns (uint256 stockReceived, uint256 usdgReceived);
}
