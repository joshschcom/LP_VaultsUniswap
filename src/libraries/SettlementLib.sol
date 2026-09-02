// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IStockOracleGuard } from "../interfaces/IStockOracleGuard.sol";
import { IStrategyLossReserve } from "../interfaces/IStrategyLossReserve.sol";
import { IUniswapV4PairedAdapter } from "../interfaces/IUniswapV4PairedAdapter.sol";
import { PairConfig, PairLedger } from "./VaultTypes.sol";
import { VaultMath } from "./VaultMath.sol";

/**
 * @notice Deficit settlement for `RobinhoodBoostedVault.withdrawForSide`.
 * @dev Deployed once and reached by DELEGATECALL, so `address(this)` and all storage are the
 *      vault's. Extracted purely to keep the vault under EIP-170; the logic is unchanged from
 *      the in-vault version. The vault's dependency addresses are passed in rather than read
 *      from storage so this library holds no layout assumptions beyond the two structs.
 */
library SettlementLib {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    error BalanceDeltaMismatch();

    event SettlementSwap(
        bytes32 indexed pairId, address indexed tokenIn, uint256 amountIn, uint256 amountOut
    );

    struct SettleParams {
        bytes32 pairId;
        bool stockSide;
        uint256 requested;
        uint256 stockPrice;
        uint256 usdgPrice;
        uint256 deadline;
        IStrategyLossReserve lossReserve;
        IStockOracleGuard oracleGuard;
        IUniswapV4PairedAdapter liquidityAdapter;
    }

    /**
     * @notice Covers a withdrawal deficit from the reserve, then from a bounded settlement swap.
     * @dev Loss waterfall step two and three. Returns with the target side's idle balance raised
     *      as far as the reserve and the oracle-floored swap allow; any residual is recognized
     *      as shared loss by the caller before assets leave the vault.
     */
    function settleShortfall(
        PairConfig storage config,
        PairLedger storage pairLedger,
        SettleParams memory p
    ) public {
        uint256 targetIdle = p.stockSide ? pairLedger.stockIdle : pairLedger.usdgIdle;
        if (targetIdle >= p.requested) return;
        uint256 deficit = p.requested - targetIdle;
        uint256 deficitValue = p.stockSide
            ? VaultMath.valueUSD18(deficit, config.stockDecimals, p.stockPrice, Math.Rounding.Ceil)
            : VaultMath.valueUSD18(deficit, config.usdgDecimals, p.usdgPrice, Math.Rounding.Ceil);

        address targetToken = p.stockSide ? config.stockToken : config.usdg;
        uint256 reserveAvailable = p.lossReserve.available(p.pairId, targetToken);
        if (reserveAvailable != 0) {
            uint256 requestedReserve = Math.min(deficit, reserveAvailable);
            uint256 requestedReserveValue = p.stockSide
                ? VaultMath.valueUSD18(
                    requestedReserve, config.stockDecimals, p.stockPrice, Math.Rounding.Ceil
                )
                : VaultMath.valueUSD18(
                    requestedReserve, config.usdgDecimals, p.usdgPrice, Math.Rounding.Ceil
                );
            uint256 balanceBefore = IERC20(targetToken).balanceOf(address(this));
            uint256 reportedCovered = p.lossReserve
                .cover(p.pairId, targetToken, requestedReserve, requestedReserveValue, deficitValue);
            uint256 covered = _observedBalanceIncrease(targetToken, balanceBefore);
            if (reportedCovered != covered) revert BalanceDeltaMismatch();
            if (p.stockSide) pairLedger.stockIdle += covered;
            else pairLedger.usdgIdle += covered;
            targetIdle += covered;
            if (targetIdle >= p.requested) return;
            deficit = p.requested - targetIdle;
        } else if (p.stockSide) {
            // If the stock reserve is empty, USDG reserve may fund one bounded USDG->stock
            // settlement. Only one reserve cover call is made per withdrawal event.
            uint256 usdgNeeded = VaultMath.amountFromValueUSD18(
                deficitValue, config.usdgDecimals, p.usdgPrice, Math.Rounding.Ceil
            );
            uint256 usdgAvailable = p.lossReserve.available(p.pairId, config.usdg);
            uint256 requestedUsdgReserve = Math.min(usdgNeeded, usdgAvailable);
            if (requestedUsdgReserve != 0) {
                uint256 requestedUsdgValue = VaultMath.valueUSD18(
                    requestedUsdgReserve, config.usdgDecimals, p.usdgPrice, Math.Rounding.Ceil
                );
                uint256 balanceBefore = IERC20(config.usdg).balanceOf(address(this));
                uint256 reportedCovered = p.lossReserve
                    .cover(
                        p.pairId,
                        config.usdg,
                        requestedUsdgReserve,
                        requestedUsdgValue,
                        deficitValue
                    );
                uint256 coveredUsdg = _observedBalanceIncrease(config.usdg, balanceBefore);
                if (reportedCovered != coveredUsdg) revert BalanceDeltaMismatch();
                pairLedger.usdgIdle += coveredUsdg;
            }
        }

        _settlementSwap(config, pairLedger, p);
    }

    function _settlementSwap(
        PairConfig storage config,
        PairLedger storage pairLedger,
        SettleParams memory p
    ) private {
        if (config.swapsPaused) return;
        address tokenIn = p.stockSide ? config.usdg : config.stockToken;
        uint256 counterIdle = p.stockSide ? pairLedger.usdgIdle : pairLedger.stockIdle;
        if (counterIdle == 0) return;

        uint256 remainingTargetIdle = p.stockSide ? pairLedger.stockIdle : pairLedger.usdgIdle;
        uint256 remainingDeficit =
            p.requested > remainingTargetIdle ? p.requested - remainingTargetIdle : 0;
        uint256 remainingDeficitValue = p.stockSide
            ? VaultMath.valueUSD18(
                remainingDeficit, config.stockDecimals, p.stockPrice, Math.Rounding.Ceil
            )
            : VaultMath.valueUSD18(
                remainingDeficit, config.usdgDecimals, p.usdgPrice, Math.Rounding.Ceil
            );
        uint256 counterNeeded = p.stockSide
            ? VaultMath.amountFromValueUSD18(
                remainingDeficitValue, config.usdgDecimals, p.usdgPrice, Math.Rounding.Ceil
            )
            : VaultMath.amountFromValueUSD18(
                remainingDeficitValue, config.stockDecimals, p.stockPrice, Math.Rounding.Ceil
            );
        // Gross up for the configured execution tolerance so the oracle-bounded
        // minimum output can satisfy the entire remaining claim. Counter principal
        // may be converted here: post-swap loss recognition proportionally adjusts
        // both side claims before any assets leave the vault.
        counterNeeded =
            Math.mulDiv(counterNeeded, BPS, BPS - config.maxSwapSlippageBps, Math.Rounding.Ceil);
        uint256 amountIn = Math.min(counterIdle, counterNeeded);
        amountIn = _capSwapAmount(config, p.stockSide, amountIn, p.stockPrice, p.usdgPrice);
        if (amountIn == 0) return;

        uint256 expectedOut = p.stockSide
            ? VaultMath.amountFromValueUSD18(
                VaultMath.valueUSD18(
                    amountIn, config.usdgDecimals, p.usdgPrice, Math.Rounding.Floor
                ),
                config.stockDecimals,
                p.stockPrice,
                Math.Rounding.Floor
            )
            : VaultMath.amountFromValueUSD18(
                VaultMath.valueUSD18(
                    amountIn, config.stockDecimals, p.stockPrice, Math.Rounding.Floor
                ),
                config.usdgDecimals,
                p.usdgPrice,
                Math.Rounding.Floor
            );
        uint256 minOut = Math.mulDiv(expectedOut, BPS - config.maxSwapSlippageBps, BPS);
        if (minOut == 0) return;
        uint256 inputBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        address outputToken = p.stockSide ? config.stockToken : config.usdg;
        uint256 outputBalanceBefore = IERC20(outputToken).balanceOf(address(this));
        // Revalidate immediately before the external swap. This catches a pool that
        // was moved outside the oracle deviation bound by any preceding external call.
        p.oracleGuard.validatePoolPrice(p.pairId, p.liquidityAdapter.poolKey(p.pairId));
        IERC20(tokenIn).forceApprove(address(p.liquidityAdapter), amountIn);
        (uint256 used, uint256 output) =
            p.liquidityAdapter.swapExactInput(p.pairId, tokenIn, amountIn, minOut, p.deadline);
        IERC20(tokenIn).forceApprove(address(p.liquidityAdapter), 0);
        _requireBalanceDecrease(tokenIn, inputBalanceBefore, used);
        _requireBalanceIncrease(outputToken, outputBalanceBefore, output);
        if (p.stockSide) {
            pairLedger.usdgIdle -= used;
            pairLedger.stockIdle += output;
        } else {
            pairLedger.stockIdle -= used;
            pairLedger.usdgIdle += output;
        }
        emit SettlementSwap(p.pairId, tokenIn, used, output);
    }

    function _capSwapAmount(
        PairConfig storage config,
        bool stockTarget,
        uint256 amountIn,
        uint256 stockPrice,
        uint256 usdgPrice
    ) private view returns (uint256) {
        uint256 inputValue = stockTarget
            ? VaultMath.valueUSD18(amountIn, config.usdgDecimals, usdgPrice, Math.Rounding.Floor)
            : VaultMath.valueUSD18(amountIn, config.stockDecimals, stockPrice, Math.Rounding.Floor);
        if (inputValue <= config.maxSettlementSwapUSDG) return amountIn;
        return stockTarget
            ? VaultMath.amountFromValueUSD18(
                config.maxSettlementSwapUSDG, config.usdgDecimals, usdgPrice, Math.Rounding.Floor
            )
            : VaultMath.amountFromValueUSD18(
                config.maxSettlementSwapUSDG, config.stockDecimals, stockPrice, Math.Rounding.Floor
            );
    }

    function _observedBalanceIncrease(address token, uint256 balanceBefore)
        private
        view
        returns (uint256 observed)
    {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore) revert BalanceDeltaMismatch();
        observed = balanceAfter - balanceBefore;
    }

    function _requireBalanceIncrease(address token, uint256 balanceBefore, uint256 expected)
        private
        view
    {
        if (_observedBalanceIncrease(token, balanceBefore) != expected) {
            revert BalanceDeltaMismatch();
        }
    }

    function _requireBalanceDecrease(address token, uint256 balanceBefore, uint256 expected)
        private
        view
    {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != expected) {
            revert BalanceDeltaMismatch();
        }
    }
}
