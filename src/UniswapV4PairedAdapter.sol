// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { IAllowanceTransfer } from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";

import { IUniswapV4PairedAdapter } from "./interfaces/IUniswapV4PairedAdapter.sol";
import { VaultMath } from "./libraries/VaultMath.sol";

contract UniswapV4PairedAdapter is
    Initializable,
    ReentrancyGuardUpgradeable,
    IUniswapV4PairedAdapter
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;

    struct PairState {
        address stockToken;
        address usdg;
        PoolKey key;
        bytes32 poolId;
        uint256 tokenId;
        uint128 liquidity;
        uint16 maxLiquiditySlippageBps;
        bool registered;
    }

    /// @dev Robinhood's deployed Universal Router uses the newer v4 swap ABI. The
    /// pinned PositionManager dependency predates `minHopPriceX36`, so this local
    /// struct deliberately mirrors the deployed router's exact encoding.
    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    address public vault;
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IUniversalRouter public universalRouter;
    IAllowanceTransfer public permit2;

    mapping(bytes32 => PairState) private _pairs;

    error NotVault();
    error InvalidConfiguration();
    error UnknownPair();
    error PoolMismatch();
    error PoolUninitialized();
    error InvalidDeadline();
    error AmountOverflow();
    error InvalidPosition();
    error UnsupportedToken();
    error InsufficientLiquidity();
    error SlippageExceeded();

    event PairRegistered(
        bytes32 indexed pairId, bytes32 indexed poolId, address stockToken, address usdg
    );
    event LiquidityAdded(
        bytes32 indexed pairId,
        uint256 indexed tokenId,
        uint256 stockUsed,
        uint256 usdgUsed,
        uint128 liquidityAdded
    );
    event LiquidityDecreased(
        bytes32 indexed pairId,
        uint256 indexed tokenId,
        uint128 liquidityRemoved,
        uint256 stockReceived,
        uint256 usdgReceived
    );
    event FeesCollected(bytes32 indexed pairId, uint256 stockFees, uint256 usdgFees);
    event SettlementSwap(
        bytes32 indexed pairId, address indexed tokenIn, uint256 amountIn, uint256 amountOut
    );
    event PositionBurned(bytes32 indexed pairId, uint256 indexed tokenId);
    event ApprovalsRefreshed(bytes32 indexed pairId, uint48 expiration);
    event ApprovalsRevoked(bytes32 indexed pairId);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vault_,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IUniversalRouter universalRouter_,
        IAllowanceTransfer permit2_
    ) external initializer {
        if (
            vault_ == address(0) || address(poolManager_) == address(0)
                || address(positionManager_) == address(0)
                || address(universalRouter_) == address(0) || address(permit2_) == address(0)
        ) revert InvalidConfiguration();
        __ReentrancyGuard_init();
        vault = vault_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        universalRouter = universalRouter_;
        permit2 = permit2_;
    }

    function registerPair(bytes32 pairId, RegisterPairParams calldata params) external onlyVault {
        if (
            pairId == bytes32(0) || _pairs[pairId].registered || params.stockToken == address(0)
                || params.usdg == address(0) || params.stockToken == params.usdg
                || params.expectedPoolId == bytes32(0) || params.maxLiquiditySlippageBps > BPS
                || address(params.poolKey.hooks) != address(0)
        ) revert InvalidConfiguration();

        address currency0 = Currency.unwrap(params.poolKey.currency0);
        address currency1 = Currency.unwrap(params.poolKey.currency1);
        if (currency0 >= currency1) revert InvalidConfiguration();
        if (!((currency0 == params.stockToken && currency1 == params.usdg)
                    || (currency0 == params.usdg && currency1 == params.stockToken))) revert InvalidConfiguration();
        PoolKey memory key = params.poolKey;
        PoolId id = key.toId();
        if (PoolId.unwrap(id) != params.expectedPoolId) revert PoolMismatch();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolUninitialized();

        PairState storage pair = _pairs[pairId];
        pair.stockToken = params.stockToken;
        pair.usdg = params.usdg;
        pair.key = key;
        pair.poolId = params.expectedPoolId;
        pair.maxLiquiditySlippageBps = params.maxLiquiditySlippageBps;
        pair.registered = true;

        emit PairRegistered(pairId, params.expectedPoolId, params.stockToken, params.usdg);
    }

    function poolKey(bytes32 pairId) external view returns (PoolKey memory) {
        PairState storage pair = _pair(pairId);
        return pair.key;
    }

    function positionState(bytes32 pairId) public view returns (PositionState memory state) {
        PairState storage pair = _pair(pairId);
        state.tokenId = pair.tokenId;
        state.liquidity = pair.liquidity;
        if (pair.liquidity == 0) return state;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(pair.poolId));
        if (sqrtPriceX96 == 0) revert PoolUninitialized();
        uint160 sqrtLower =
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(pair.key.tickSpacing));
        uint160 sqrtUpper =
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(pair.key.tickSpacing));
        (uint256 amount0, uint256 amount1) =
            VaultMath.amountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, pair.liquidity);
        (state.stockAmount, state.usdgAmount) = _fromPoolOrder(pair, amount0, amount1);
    }

    function addLiquidity(
        bytes32 pairId,
        uint256 stockDesired,
        uint256 usdgDesired,
        uint256 deadline
    )
        external
        onlyVault
        nonReentrant
        returns (uint256 stockUsed, uint256 usdgUsed, uint128 liquidityAdded)
    {
        _checkDeadline(deadline);
        PairState storage pair = _pair(pairId);
        if (stockDesired == 0 || usdgDesired == 0) revert InvalidConfiguration();

        IERC20(pair.stockToken).safeTransferFrom(vault, address(this), stockDesired);
        IERC20(pair.usdg).safeTransferFrom(vault, address(this), usdgDesired);
        (uint256 amount0Desired, uint256 amount1Desired) =
            _toPoolOrder(pair, stockDesired, usdgDesired);
        _requireUint128(amount0Desired);
        _requireUint128(amount1Desired);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(pair.poolId));
        uint160 sqrtLower =
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(pair.key.tickSpacing));
        uint160 sqrtUpper =
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(pair.key.tickSpacing));
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, amount0Desired, amount1Desired
        );
        if (liquidityAdded == 0) revert InsufficientLiquidity();

        uint256 stockBefore = IERC20(pair.stockToken).balanceOf(address(this));
        uint256 usdgBefore = IERC20(pair.usdg).balanceOf(address(this));
        if (pair.tokenId == 0) {
            uint256 nextTokenId = positionManager.nextTokenId();
            _mint(pair, liquidityAdded, uint128(amount0Desired), uint128(amount1Desired), deadline);
            if (IERC721(address(positionManager)).ownerOf(nextTokenId) != address(this)) {
                revert InvalidPosition();
            }
            pair.tokenId = nextTokenId;
        } else {
            _increase(
                pair, liquidityAdded, uint128(amount0Desired), uint128(amount1Desired), deadline
            );
        }
        uint256 stockAfter = IERC20(pair.stockToken).balanceOf(address(this));
        uint256 usdgAfter = IERC20(pair.usdg).balanceOf(address(this));
        stockUsed = stockBefore - stockAfter;
        usdgUsed = usdgBefore - usdgAfter;
        pair.liquidity = positionManager.getPositionLiquidity(pair.tokenId);

        if (stockAfter != 0) IERC20(pair.stockToken).safeTransfer(vault, stockAfter);
        if (usdgAfter != 0) IERC20(pair.usdg).safeTransfer(vault, usdgAfter);
        emit LiquidityAdded(pairId, pair.tokenId, stockUsed, usdgUsed, liquidityAdded);
    }

    function decreaseLiquidity(bytes32 pairId, uint128 liquidity, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (uint256 stockReceived, uint256 usdgReceived)
    {
        _checkDeadline(deadline);
        PairState storage pair = _pair(pairId);
        if (liquidity == 0 || liquidity > pair.liquidity || pair.tokenId == 0) {
            revert InsufficientLiquidity();
        }
        (uint128 amount0Min, uint128 amount1Min) = _decreaseMinimums(pair, liquidity);
        (stockReceived, usdgReceived) =
            _decreaseAndTransfer(pair, liquidity, amount0Min, amount1Min, deadline);
        pair.liquidity = positionManager.getPositionLiquidity(pair.tokenId);
        emit LiquidityDecreased(pairId, pair.tokenId, liquidity, stockReceived, usdgReceived);
    }

    function collectFees(bytes32 pairId, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (uint256 stockFees, uint256 usdgFees)
    {
        _checkDeadline(deadline);
        PairState storage pair = _pair(pairId);
        if (pair.tokenId == 0) return (0, 0);
        (stockFees, usdgFees) = _decreaseAndTransfer(pair, 0, 0, 0, deadline);
        emit FeesCollected(pairId, stockFees, usdgFees);
    }

    function swapExactInput(
        bytes32 pairId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external onlyVault nonReentrant returns (uint256 amountInUsed, uint256 amountOut) {
        _checkDeadline(deadline);
        PairState storage pair = _pair(pairId);
        if (tokenIn != pair.stockToken && tokenIn != pair.usdg) revert UnsupportedToken();
        if (amountIn == 0 || minAmountOut == 0) revert InvalidConfiguration();
        _requireUint128(amountIn);
        _requireUint128(minAmountOut);

        address tokenOut = tokenIn == pair.stockToken ? pair.usdg : pair.stockToken;
        IERC20(tokenIn).safeTransferFrom(vault, address(this), amountIn);
        uint256 inputBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outputBefore = IERC20(tokenOut).balanceOf(address(this));

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        bool zeroForOne = tokenIn == Currency.unwrap(pair.key.currency0);
        params[0] = abi.encode(
            RouterExactInputSingleParams({
                poolKey: pair.key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minAmountOut),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        Currency inputCurrency = zeroForOne ? pair.key.currency0 : pair.key.currency1;
        Currency outputCurrency = zeroForOne ? pair.key.currency1 : pair.key.currency0;
        // SETTLE_ALL reads the exact open debt and treats this value as a ceiling.
        // Use an unbounded ceiling here; the preceding exact-input action and the
        // adapter's measured `amountIn` cap still strictly bound what Permit2 can pull.
        params[1] = abi.encode(inputCurrency, type(uint256).max);
        params[2] = abi.encode(outputCurrency, minAmountOut);
        inputs[0] = abi.encode(actions, params);

        universalRouter.execute(commands, inputs, deadline);
        uint256 inputAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 outputAfter = IERC20(tokenOut).balanceOf(address(this));
        amountInUsed = inputBefore - inputAfter;
        amountOut = outputAfter - outputBefore;
        if (amountOut < minAmountOut) revert SlippageExceeded();

        if (inputAfter != 0) IERC20(tokenIn).safeTransfer(vault, inputAfter);
        if (outputAfter != 0) IERC20(tokenOut).safeTransfer(vault, outputAfter);
        emit SettlementSwap(pairId, tokenIn, amountInUsed, amountOut);
    }

    function burnEmptyPosition(bytes32 pairId, uint256 deadline)
        external
        onlyVault
        nonReentrant
        returns (uint256 stockReceived, uint256 usdgReceived)
    {
        _checkDeadline(deadline);
        PairState storage pair = _pair(pairId);
        if (pair.tokenId == 0 || pair.liquidity != 0) revert InvalidPosition();
        uint256 tokenId = pair.tokenId;
        uint256 stockBefore = IERC20(pair.stockToken).balanceOf(address(this));
        uint256 usdgBefore = IERC20(pair.usdg).balanceOf(address(this));

        bytes memory actions =
            abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(pair.key.currency0, pair.key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);

        stockReceived = IERC20(pair.stockToken).balanceOf(address(this)) - stockBefore;
        usdgReceived = IERC20(pair.usdg).balanceOf(address(this)) - usdgBefore;
        pair.tokenId = 0;
        if (stockReceived != 0) IERC20(pair.stockToken).safeTransfer(vault, stockReceived);
        if (usdgReceived != 0) IERC20(pair.usdg).safeTransfer(vault, usdgReceived);
        emit PositionBurned(pairId, tokenId);
    }

    function refreshApprovals(bytes32 pairId, uint48 expiration) external onlyVault {
        PairState storage pair = _pair(pairId);
        if (expiration <= block.timestamp) revert InvalidConfiguration();
        _approve(pair.stockToken, expiration);
        _approve(pair.usdg, expiration);
        emit ApprovalsRefreshed(pairId, expiration);
    }

    function revokeApprovals(bytes32 pairId) external onlyVault {
        PairState storage pair = _pair(pairId);
        _revoke(pair.stockToken);
        _revoke(pair.usdg);
        emit ApprovalsRevoked(pairId);
    }

    function _mint(
        PairState storage pair,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            pair.key,
            TickMath.minUsableTick(pair.key.tickSpacing),
            TickMath.maxUsableTick(pair.key.tickSpacing),
            uint256(liquidity),
            amount0Max,
            amount1Max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(pair.key.currency0, pair.key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    function _increase(
        PairState storage pair,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(pair.tokenId, uint256(liquidity), amount0Max, amount1Max, bytes(""));
        params[1] = abi.encode(pair.key.currency0, pair.key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    function _decreaseAndTransfer(
        PairState storage pair,
        uint128 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) internal returns (uint256 stockReceived, uint256 usdgReceived) {
        uint256 stockBefore = IERC20(pair.stockToken).balanceOf(address(this));
        uint256 usdgBefore = IERC20(pair.usdg).balanceOf(address(this));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(pair.tokenId, uint256(liquidity), amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(pair.key.currency0, pair.key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
        stockReceived = IERC20(pair.stockToken).balanceOf(address(this)) - stockBefore;
        usdgReceived = IERC20(pair.usdg).balanceOf(address(this)) - usdgBefore;
        if (stockReceived != 0) IERC20(pair.stockToken).safeTransfer(vault, stockReceived);
        if (usdgReceived != 0) IERC20(pair.usdg).safeTransfer(vault, usdgReceived);
    }

    function _decreaseMinimums(PairState storage pair, uint128 liquidity)
        internal
        view
        returns (uint128 amount0Min, uint128 amount1Min)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(pair.poolId));
        uint160 sqrtLower =
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(pair.key.tickSpacing));
        uint160 sqrtUpper =
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(pair.key.tickSpacing));
        (uint256 expected0, uint256 expected1) =
            VaultMath.amountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
        uint256 multiplier = BPS - pair.maxLiquiditySlippageBps;
        uint256 min0 = Math.mulDiv(expected0, multiplier, BPS);
        uint256 min1 = Math.mulDiv(expected1, multiplier, BPS);
        _requireUint128(min0);
        _requireUint128(min1);
        return (uint128(min0), uint128(min1));
    }

    function _approve(address token, uint48 expiration) internal {
        IERC20(token).forceApprove(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, expiration);
        permit2.approve(token, address(universalRouter), type(uint160).max, expiration);
    }

    function _revoke(address token) internal {
        permit2.approve(token, address(positionManager), 0, 0);
        permit2.approve(token, address(universalRouter), 0, 0);
        IERC20(token).forceApprove(address(permit2), 0);
    }

    function _toPoolOrder(PairState storage pair, uint256 stock, uint256 usdg)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return
            Currency.unwrap(pair.key.currency0) == pair.stockToken ? (stock, usdg) : (usdg, stock);
    }

    function _fromPoolOrder(PairState storage pair, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256 stock, uint256 usdg)
    {
        return Currency.unwrap(pair.key.currency0) == pair.stockToken
            ? (amount0, amount1)
            : (amount1, amount0);
    }

    function _pair(bytes32 pairId) internal view returns (PairState storage pair) {
        pair = _pairs[pairId];
        if (!pair.registered) revert UnknownPair();
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (deadline < block.timestamp) revert InvalidDeadline();
    }

    function _requireUint128(uint256 amount) internal pure {
        if (amount > type(uint128).max) revert AmountOverflow();
    }

    uint256[42] private __gap;
}
