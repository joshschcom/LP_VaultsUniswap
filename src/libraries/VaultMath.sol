// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

library VaultMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    error InvalidDecimals();
    error InvalidPrice();
    error IdenticalTokens();

    function scaleToWad(uint256 amount, uint8 decimals, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        if (decimals > 36) revert InvalidDecimals();
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return Math.mulDiv(amount, 1, 10 ** (decimals - 18), rounding);
    }

    function scaleFromWad(uint256 amount, uint8 decimals, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        if (decimals > 36) revert InvalidDecimals();
        if (decimals == 18) return amount;
        if (decimals < 18) return Math.mulDiv(amount, 1, 10 ** (18 - decimals), rounding);
        return amount * (10 ** (decimals - 18));
    }

    function valueUSD18(uint256 amount, uint8 decimals, uint256 priceUSD18, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        if (priceUSD18 == 0) revert InvalidPrice();
        return Math.mulDiv(scaleToWad(amount, decimals, rounding), priceUSD18, WAD, rounding);
    }

    function amountFromValueUSD18(
        uint256 value,
        uint8 decimals,
        uint256 priceUSD18,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        if (priceUSD18 == 0) revert InvalidPrice();
        uint256 wadAmount = Math.mulDiv(value, WAD, priceUSD18, rounding);
        return scaleFromWad(wadAmount, decimals, rounding);
    }

    /// @notice Quotes `baseAmount` of base token into quote token using a v4 tick.
    /// @dev Ported from Uniswap's OracleLibrary and supports either currency ordering.
    function quoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        if (baseToken == quoteToken) revert IdenticalTokens();
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    function amountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 == 0 || sqrtPriceAX96 == 0 || sqrtPriceBX96 == 0) {
            revert InvalidPrice();
        }
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        }
    }
}
