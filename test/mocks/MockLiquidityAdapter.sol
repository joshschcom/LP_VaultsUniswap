// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IUniswapV4PairedAdapter } from "../../src/interfaces/IUniswapV4PairedAdapter.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockLiquidityAdapter is IUniswapV4PairedAdapter {
    using SafeERC20 for IERC20;

    struct Pair {
        address stock;
        address usdg;
        PoolKey key;
        PositionState position;
        uint256 stockFees;
        uint256 usdgFees;
    }

    address public vault;
    mapping(bytes32 => Pair) private _pairs;

    function setVault(address vault_) external {
        require(vault == address(0), "SET");
        vault = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "VAULT");
        _;
    }

    function registerPair(bytes32 pairId, RegisterPairParams calldata params) external onlyVault {
        Pair storage pair = _pairs[pairId];
        pair.stock = params.stockToken;
        pair.usdg = params.usdg;
        pair.key = params.poolKey;
    }

    function poolKey(bytes32 pairId) external view returns (PoolKey memory) {
        return _pairs[pairId].key;
    }

    function positionState(bytes32 pairId) external view returns (PositionState memory) {
        return _pairs[pairId].position;
    }

    function setPosition(bytes32 pairId, uint256 stockAmount, uint256 usdgAmount) external {
        Pair storage pair = _pairs[pairId];
        pair.position.stockAmount = stockAmount;
        pair.position.usdgAmount = usdgAmount;
    }

    function setFees(bytes32 pairId, uint256 stockFees, uint256 usdgFees) external {
        _pairs[pairId].stockFees = stockFees;
        _pairs[pairId].usdgFees = usdgFees;
    }

    function addLiquidity(bytes32 pairId, uint256 stockDesired, uint256 usdgDesired, uint256)
        external
        onlyVault
        returns (uint256 stockUsed, uint256 usdgUsed, uint128 liquidityAdded)
    {
        Pair storage pair = _pairs[pairId];
        IERC20(pair.stock).safeTransferFrom(vault, address(this), stockDesired);
        IERC20(pair.usdg).safeTransferFrom(vault, address(this), usdgDesired);
        stockUsed = stockDesired;
        usdgUsed = usdgDesired;
        liquidityAdded = uint128(Math.min(stockDesired, type(uint128).max));
        pair.position.tokenId = 1;
        pair.position.liquidity += liquidityAdded;
        pair.position.stockAmount += stockUsed;
        pair.position.usdgAmount += usdgUsed;
    }

    function decreaseLiquidity(bytes32 pairId, uint128 liquidity, uint160, uint256)
        external
        onlyVault
        returns (uint256 stockReceived, uint256 usdgReceived, uint128 liquidityRemoved)
    {
        Pair storage pair = _pairs[pairId];
        uint128 total = pair.position.liquidity;
        stockReceived = Math.mulDiv(pair.position.stockAmount, liquidity, total);
        usdgReceived = Math.mulDiv(pair.position.usdgAmount, liquidity, total);
        pair.position.stockAmount -= stockReceived;
        pair.position.usdgAmount -= usdgReceived;
        pair.position.liquidity -= liquidity;
        liquidityRemoved = total - pair.position.liquidity;
        IERC20(pair.stock).safeTransfer(vault, stockReceived);
        IERC20(pair.usdg).safeTransfer(vault, usdgReceived);
    }

    function collectFees(bytes32 pairId, uint256)
        external
        onlyVault
        returns (uint256 stockFees, uint256 usdgFees)
    {
        Pair storage pair = _pairs[pairId];
        stockFees = pair.stockFees;
        usdgFees = pair.usdgFees;
        pair.stockFees = 0;
        pair.usdgFees = 0;
        if (stockFees != 0) {
            MockERC20(pair.stock).mint(vault, stockFees);
        }
        if (usdgFees != 0) {
            MockERC20(pair.usdg).mint(vault, usdgFees);
        }
    }

    function swapExactInput(
        bytes32 pairId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256
    ) external onlyVault returns (uint256 amountInUsed, uint256 amountOut) {
        Pair storage pair = _pairs[pairId];
        address tokenOut = tokenIn == pair.stock ? pair.usdg : pair.stock;
        IERC20(tokenIn).safeTransferFrom(vault, address(this), amountIn);
        amountInUsed = amountIn;
        amountOut = minAmountOut;
        MockERC20(tokenOut).mint(vault, amountOut);
    }

    function burnEmptyPosition(bytes32 pairId, uint256)
        external
        onlyVault
        returns (uint256, uint256)
    {
        require(_pairs[pairId].position.liquidity == 0, "LIQ");
        _pairs[pairId].position.tokenId = 0;
        return (0, 0);
    }
}
