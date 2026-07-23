// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

contract MockPermit2 {
    using SafeERC20 for IERC20;

    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => Allowance))) private _allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        Allowance storage stored = _allowance[msg.sender][token][spender];
        stored.amount = amount;
        stored.expiration = expiration;
    }

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Allowance storage stored = _allowance[owner][token][spender];
        return (stored.amount, stored.expiration, stored.nonce);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage stored = _allowance[from][token][msg.sender];
        require(block.timestamp <= stored.expiration && amount <= stored.amount, "ALLOWANCE");
        stored.amount -= amount;
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}

contract MockPoolManagerState {
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    int24 public tick;

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_) external {
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
    }

    function extsload(bytes32) external view returns (bytes32 value) {
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);
        return bytes32(packed);
    }
}

contract MockPositionManager {
    using SafeERC20 for IERC20;

    struct Position {
        address owner;
        address token0;
        address token1;
        uint128 liquidity;
    }

    MockPermit2 public immutable permit2;
    uint256 public nextTokenId = 41;
    mapping(uint256 => Position) private _positions;

    uint128 public lastAmount0Min;
    uint128 public lastAmount1Min;
    uint128 public liquidityHaircut;
    uint128 public removalHaircut;

    constructor(MockPermit2 permit2_) {
        permit2 = permit2_;
    }

    function setLiquidityHaircuts(uint128 addHaircut, uint128 removeHaircut) external {
        liquidityHaircut = addHaircut;
        removalHaircut = removeHaircut;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _positions[tokenId].owner;
        require(owner != address(0), "NOT_MINTED");
        return owner;
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        uint8 action = uint8(actions[0]);
        if (action == 2) {
            (
                PoolKey memory key,
                int24 tickLower,
                int24 tickUpper,
                uint256 liquidity,
                uint128 amount0Max,
                uint128 amount1Max,
                address owner,
                bytes memory hookData
            ) = abi.decode(
                params[0], (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes)
            );
            tickLower;
            tickUpper;
            hookData;
            uint256 tokenId = nextTokenId++;
            uint128 actualLiquidity = uint128(liquidity) - liquidityHaircut;
            _positions[tokenId] = Position({
                owner: owner,
                token0: Currency.unwrap(key.currency0),
                token1: Currency.unwrap(key.currency1),
                liquidity: actualLiquidity
            });
            _pullPair(key, amount0Max, amount1Max);
            return;
        }
        if (action == 0) {
            (
                uint256 tokenId,
                uint256 liquidity,
                uint128 amount0Max,
                uint128 amount1Max,
                bytes memory hookData
            ) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
            hookData;
            Position storage position = _positions[tokenId];
            position.liquidity += uint128(liquidity) - liquidityHaircut;
            permit2.transferFrom(msg.sender, address(this), amount0Max, position.token0);
            permit2.transferFrom(msg.sender, address(this), amount1Max, position.token1);
            return;
        }
        if (action == 1) {
            (
                uint256 tokenId,
                uint256 liquidity,
                uint128 amount0Min,
                uint128 amount1Min,
                bytes memory hookData
            ) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
            hookData;
            Position storage position = _positions[tokenId];
            uint256 adjustedLiquidity = liquidity > removalHaircut ? liquidity - removalHaircut : 0;
            uint128 removed = uint128(Math.min(adjustedLiquidity, position.liquidity));
            position.liquidity -= removed;
            lastAmount0Min = amount0Min;
            lastAmount1Min = amount1Min;
            if (amount0Min != 0) IERC20(position.token0).safeTransfer(msg.sender, amount0Min);
            if (amount1Min != 0) IERC20(position.token1).safeTransfer(msg.sender, amount1Min);
            return;
        }
        if (action == 3) {
            (uint256 tokenId,,,) = abi.decode(params[0], (uint256, uint128, uint128, bytes));
            require(_positions[tokenId].liquidity == 0, "LIQUIDITY");
            delete _positions[tokenId];
            return;
        }
        revert("ACTION");
    }

    function _pullPair(PoolKey memory key, uint128 amount0, uint128 amount1) internal {
        permit2.transferFrom(msg.sender, address(this), amount0, Currency.unwrap(key.currency0));
        permit2.transferFrom(msg.sender, address(this), amount1, Currency.unwrap(key.currency1));
    }
}

contract MockUniversalRouter {
    using SafeERC20 for IERC20;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    MockPermit2 public immutable permit2;

    constructor(MockPermit2 permit2_) {
        permit2 = permit2_;
    }

    function execute(bytes calldata, bytes[] calldata inputs, uint256) external payable {
        (, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        ExactInputSingleParams memory swap = abi.decode(params[0], (ExactInputSingleParams));
        address tokenIn =
            Currency.unwrap(swap.zeroForOne ? swap.poolKey.currency0 : swap.poolKey.currency1);
        address tokenOut =
            Currency.unwrap(swap.zeroForOne ? swap.poolKey.currency1 : swap.poolKey.currency0);
        permit2.transferFrom(msg.sender, address(this), swap.amountIn, tokenIn);
        IERC20(tokenOut).safeTransfer(msg.sender, swap.amountOutMinimum);
    }
}
