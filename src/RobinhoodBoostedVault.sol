// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IStockOracleGuard } from "./interfaces/IStockOracleGuard.sol";
import { IStrategyLossReserve } from "./interfaces/IStrategyLossReserve.sol";
import { IUniswapV4PairedAdapter } from "./interfaces/IUniswapV4PairedAdapter.sol";
import { VaultMath } from "./libraries/VaultMath.sol";
import { SettlementLib } from "./libraries/SettlementLib.sol";
import { PairConfig, PairLedger } from "./libraries/VaultTypes.sol";

contract RobinhoodBoostedVault is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 internal constant BPS = 10_000;
    uint256 internal constant REMOVAL_OPERATIONAL_BUFFER_BPS = 100;

    IStockOracleGuard public oracleGuard;
    IStrategyLossReserve public lossReserve;
    IUniswapV4PairedAdapter public liquidityAdapter;

    mapping(bytes32 => PairConfig) private _pairConfig;
    mapping(bytes32 => PairLedger) private _ledger;
    mapping(address => uint256) public aggregateUsdgPrincipal;
    mapping(address => uint256) public aggregateUsdgDepositCap;

    error InvalidConfiguration();
    error UnknownPair();
    error UnsupportedToken();
    error UnauthorizedSide();
    error AllocationPaused();
    error SwapsPaused();
    error EmergencyMode();
    error InvalidDeadline();
    error CheckpointStale();
    error PairCapExceeded();
    error InsufficientPrincipal();
    error InsufficientLiquidity();
    error FeeOnTransferUnsupported();
    error GuardianCannotUnpause();
    error BalanceDeltaMismatch();

    event PairRegistered(
        bytes32 indexed pairId,
        address indexed stockToken,
        address indexed usdg,
        address stockAccount,
        address usdgAccount
    );
    event PairRiskUpdated(bytes32 indexed pairId, PairConfig config);
    event PairPauseUpdated(
        bytes32 indexed pairId, bool allocationPaused, bool swapsPaused, bool emergencyMode
    );
    event AggregateUsdgCapUpdated(address indexed usdg, uint256 previousCap, uint256 newCap);
    event Deposited(
        bytes32 indexed pairId, address indexed token, address indexed account, uint256 amount
    );
    event LiquidityRebalanced(
        bytes32 indexed pairId, uint256 stockUsed, uint256 usdgUsed, uint128 liquidityAdded
    );
    event FeesProcessed(
        bytes32 indexed pairId,
        uint256 stockFees,
        uint256 usdgFees,
        uint256 stockReserved,
        uint256 usdgReserved
    );
    event PairCheckpoint(
        bytes32 indexed pairId,
        uint256 stockAssets,
        uint256 usdgAssets,
        uint256 benchmarkUSDG,
        int256 pnlUSDG,
        uint256 stockAccountedAssets,
        uint256 usdgAccountedAssets
    );
    event Withdrawal(
        bytes32 indexed pairId,
        address indexed token,
        address indexed receiver,
        uint256 requested,
        uint256 returned,
        uint256 realizedLoss
    );
    event SettlementSwap(
        bytes32 indexed pairId, address indexed tokenIn, uint256 amountIn, uint256 amountOut
    );
    event EmergencyLiquidityDecreased(
        bytes32 indexed pairId, uint128 liquidity, uint256 stockReceived, uint256 usdgReceived
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address keeper,
        address guardian,
        IStockOracleGuard oracleGuard_,
        IStrategyLossReserve lossReserve_,
        IUniswapV4PairedAdapter liquidityAdapter_
    ) external initializer {
        if (
            admin == address(0) || keeper == address(0) || guardian == address(0)
                || address(oracleGuard_) == address(0) || address(lossReserve_) == address(0)
                || address(liquidityAdapter_) == address(0)
        ) revert InvalidConfiguration();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(GUARDIAN_ROLE, guardian);
        oracleGuard = oracleGuard_;
        lossReserve = lossReserve_;
        liquidityAdapter = liquidityAdapter_;
    }

    function registerPair(
        bytes32 pairId,
        PairConfig calldata config,
        IUniswapV4PairedAdapter.RegisterPairParams calldata adapterConfig
    ) external onlyRole(CONFIG_ROLE) nonReentrant {
        if (_pairConfig[pairId].exists) revert InvalidConfiguration();
        _validatePairConfig(pairId, config);
        if (adapterConfig.stockToken != config.stockToken || adapterConfig.usdg != config.usdg) {
            revert InvalidConfiguration();
        }

        oracleGuard.pricesUSD18(pairId);
        oracleGuard.validatePoolPrice(pairId, adapterConfig.poolKey);
        if (
            uint256(adapterConfig.removalToleranceBps)
                < uint256(oracleGuard.maxPriceDeviationBps(pairId)) + REMOVAL_OPERATIONAL_BUFFER_BPS
        ) revert InvalidConfiguration();
        liquidityAdapter.registerPair(pairId, adapterConfig);

        _pairConfig[pairId] = config;
        _pairConfig[pairId].exists = true;
        _ledger[pairId].lastCheckpoint = uint64(block.timestamp);

        emit PairRegistered(
            pairId, config.stockToken, config.usdg, config.stockAccount, config.usdgAccount
        );
    }

    function setAggregateUsdgDepositCap(address usdg, uint256 newCap)
        external
        onlyRole(CONFIG_ROLE)
    {
        // A zero cap disables the optional aggregate circuit breaker. This is safe to
        // configure below current principal because it is not interpreted as a zero limit.
        if (usdg == address(0) || (newCap != 0 && newCap < aggregateUsdgPrincipal[usdg])) {
            revert InvalidConfiguration();
        }
        uint256 previous = aggregateUsdgDepositCap[usdg];
        aggregateUsdgDepositCap[usdg] = newCap;
        emit AggregateUsdgCapUpdated(usdg, previous, newCap);
    }

    function updatePairRisk(bytes32 pairId, PairConfig calldata config)
        external
        onlyRole(CONFIG_ROLE)
    {
        PairConfig storage current = _config(pairId);
        _validatePairConfig(pairId, config);
        if (
            config.stockToken != current.stockToken || config.usdg != current.usdg
                || config.stockAccount != current.stockAccount
                || config.usdgAccount != current.usdgAccount
                || config.stockDecimals != current.stockDecimals
                || config.usdgDecimals != current.usdgDecimals
        ) revert InvalidConfiguration();
        _pairConfig[pairId] = config;
        _pairConfig[pairId].exists = true;
        emit PairRiskUpdated(pairId, config);
    }

    function setPairPause(
        bytes32 pairId,
        bool allocationPaused,
        bool swapsPaused,
        bool emergencyMode
    ) external {
        PairConfig storage config = _config(pairId);
        bool isAdmin = hasRole(CONFIG_ROLE, msg.sender);
        if (!isAdmin && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            _checkRole(GUARDIAN_ROLE, msg.sender);
        }
        if (!isAdmin) {
            if (!allocationPaused || !swapsPaused || (config.emergencyMode && !emergencyMode)) {
                revert GuardianCannotUnpause();
            }
        }
        config.allocationPaused = allocationPaused;
        config.swapsPaused = swapsPaused;
        config.emergencyMode = emergencyMode;
        emit PairPauseUpdated(pairId, allocationPaused, swapsPaused, emergencyMode);
    }

    function pairConfig(bytes32 pairId) external view returns (PairConfig memory) {
        return _pairConfig[pairId];
    }

    function ledger(bytes32 pairId) external view returns (PairLedger memory) {
        return _ledger[pairId];
    }

    function accountedAssets(bytes32 pairId, address token) external view returns (uint256) {
        (, uint256 principal) = _sideAmounts(pairId, token);
        return principal;
    }

    /// @dev Shared token dispatch for the per-side views. Reverts on an unsupported token.
    function _sideAmounts(bytes32 pairId, address token)
        private
        view
        returns (uint256 idle, uint256 principal)
    {
        PairConfig storage config = _config(pairId);
        PairLedger storage pairLedger = _ledger[pairId];
        if (token == config.stockToken) return (pairLedger.stockIdle, pairLedger.stockPrincipal);
        if (token == config.usdg) return (pairLedger.usdgIdle, pairLedger.usdgPrincipal);
        revert UnsupportedToken();
    }

    function sideAccount(bytes32 pairId, address token) external view returns (address) {
        PairConfig storage config = _config(pairId);
        if (token == config.stockToken) return config.stockAccount;
        if (token == config.usdg) return config.usdgAccount;
        revert UnsupportedToken();
    }

    function liquidAssets(bytes32 pairId, address token) external view returns (uint256) {
        (uint256 idle,) = _sideAmounts(pairId, token);
        return idle;
    }

    /// @notice Assets for one side that `withdrawForSide` can return in this block.
    /// @dev Idle is unconditionally withdrawable only once the position is closed. While any
    ///      LP liquidity remains, every principal reduction routes through the oracle-guarded
    ///      settle path, so idle counts here only when that path would currently pass.
    ///      Integrating pTokens must use this, not `liquidAssets`, for cash and utilization
    ///      accounting; `liquidAssets` reports custody and overstates what is reachable.
    function withdrawableAssets(bytes32 pairId, address token) external view returns (uint256) {
        (uint256 idle, uint256 principal) = _sideAmounts(pairId, token);
        uint256 available = Math.min(idle, principal);
        if (available == 0) return 0;

        try liquidityAdapter.positionState(pairId) returns (
            IUniswapV4PairedAdapter.PositionState memory position
        ) {
            if (position.liquidity == 0) return available;
        } catch {
            return 0;
        }

        if (_config(pairId).emergencyMode) return 0;
        // The pool key is read inside its own try: evaluated as an argument to the guarded
        // call below, an adapter-side revert would escape and make this view revert rather
        // than report nothing withdrawable.
        PoolKey memory key;
        try liquidityAdapter.poolKey(pairId) returns (PoolKey memory poolKey_) {
            key = poolKey_;
        } catch {
            return 0;
        }
        try oracleGuard.validatePoolPrice(pairId, key) returns (uint256, uint256, uint160) {
            return available;
        } catch {
            return 0;
        }
    }

    function totalPairAssets(bytes32 pairId)
        public
        view
        returns (uint256 stockAssets, uint256 usdgAssets)
    {
        PairConfig storage config = _config(pairId);
        PairLedger storage pairLedger = _ledger[pairId];
        IUniswapV4PairedAdapter.PositionState memory position =
            liquidityAdapter.positionState(pairId);
        stockAssets = pairLedger.stockIdle + position.stockAmount;
        usdgAssets = pairLedger.usdgIdle + position.usdgAmount;
        config;
    }

    /// @dev Pair assets with the position valued at `sqrtPriceX96` instead of the pool's live
    ///      price. Loss accounting uses the oracle-derived reference so that pushing the pool
    ///      cannot manufacture or mask a shortfall. `totalPairAssets` stays pool-priced and is
    ///      the market view.
    function _pairAssetsAt(bytes32 pairId, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 stockAssets, uint256 usdgAssets)
    {
        PairLedger storage pairLedger = _ledger[pairId];
        IUniswapV4PairedAdapter.PositionState memory position =
            liquidityAdapter.positionStateAt(pairId, sqrtPriceX96);
        stockAssets = pairLedger.stockIdle + position.stockAmount;
        usdgAssets = pairLedger.usdgIdle + position.usdgAmount;
    }

    function depositForPair(bytes32 pairId, address token, uint256 amount)
        external
        nonReentrant
        returns (uint256 received)
    {
        PairConfig storage config = _config(pairId);
        if (config.allocationPaused) revert AllocationPaused();
        if (config.emergencyMode) revert EmergencyMode();
        if (amount == 0) return 0;

        PairLedger storage pairLedger = _ledger[pairId];
        if (token == config.stockToken) {
            if (msg.sender != config.stockAccount) revert UnauthorizedSide();
        } else if (token == config.usdg) {
            if (msg.sender != config.usdgAccount) revert UnauthorizedSide();
        } else {
            revert UnsupportedToken();
        }

        IERC20 asset = IERC20(token);
        uint256 senderBalanceBefore = asset.balanceOf(msg.sender);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 senderBalanceAfter = asset.balanceOf(msg.sender);
        uint256 balanceAfter = asset.balanceOf(address(this));
        if (senderBalanceAfter > senderBalanceBefore || balanceAfter < balanceBefore) {
            revert FeeOnTransferUnsupported();
        }
        received = balanceAfter - balanceBefore;
        if (received != amount || senderBalanceBefore - senderBalanceAfter != amount) {
            revert FeeOnTransferUnsupported();
        }

        if (token == config.stockToken) {
            pairLedger.stockIdle += received;
            pairLedger.stockPrincipal += received;
        } else {
            pairLedger.usdgIdle += received;
            pairLedger.usdgPrincipal += received;
            aggregateUsdgPrincipal[config.usdg] += received;
            uint256 aggregateCap = aggregateUsdgDepositCap[config.usdg];
            if (aggregateCap != 0 && aggregateUsdgPrincipal[config.usdg] > aggregateCap) {
                revert PairCapExceeded();
            }
        }
        _enforcePairCap(pairId, config, pairLedger);
        emit Deposited(pairId, token, msg.sender, received);
    }

    function rebalance(bytes32 pairId, uint256 deadline)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        PairConfig storage config = _config(pairId);
        if (config.allocationPaused) revert AllocationPaused();
        if (config.emergencyMode) revert EmergencyMode();
        _requireFresh(config, _ledger[pairId]);
        _checkDeadline(config, deadline);

        PoolKey memory key = liquidityAdapter.poolKey(pairId);
        oracleGuard.validatePoolPrice(pairId, key);
        (uint256 stockPrice, uint256 usdgPrice) = oracleGuard.pricesUSD18(pairId);
        PairLedger storage pairLedger = _ledger[pairId];
        // v4 fee deltas are collected first so INCREASE_LIQUIDITY can safely use SETTLE_PAIR.
        _collectFees(pairId, config, pairLedger, deadline);
        if (_pairCapExceeded(config, pairLedger, stockPrice, usdgPrice)) {
            config.allocationPaused = true;
            emit PairPauseUpdated(pairId, true, config.swapsPaused, config.emergencyMode);
            return;
        }

        uint256 stockValue = VaultMath.valueUSD18(
            pairLedger.stockIdle, config.stockDecimals, stockPrice, Math.Rounding.Floor
        );
        uint256 usdgValue = VaultMath.valueUSD18(
            pairLedger.usdgIdle, config.usdgDecimals, usdgPrice, Math.Rounding.Floor
        );
        uint256 matchedValue = Math.min(stockValue, usdgValue);
        if (matchedValue == 0) revert InsufficientLiquidity();
        uint256 stockToPair = VaultMath.amountFromValueUSD18(
            matchedValue, config.stockDecimals, stockPrice, Math.Rounding.Floor
        );
        uint256 usdgToPair = VaultMath.amountFromValueUSD18(
            matchedValue, config.usdgDecimals, usdgPrice, Math.Rounding.Floor
        );

        uint256 stockBalanceBefore = IERC20(config.stockToken).balanceOf(address(this));
        uint256 usdgBalanceBefore = IERC20(config.usdg).balanceOf(address(this));
        IERC20(config.stockToken).forceApprove(address(liquidityAdapter), stockToPair);
        IERC20(config.usdg).forceApprove(address(liquidityAdapter), usdgToPair);
        (uint256 stockUsed, uint256 usdgUsed, uint128 liquidityAdded) =
            liquidityAdapter.addLiquidity(pairId, stockToPair, usdgToPair, deadline);
        IERC20(config.stockToken).forceApprove(address(liquidityAdapter), 0);
        IERC20(config.usdg).forceApprove(address(liquidityAdapter), 0);
        _requireBalanceDecrease(config.stockToken, stockBalanceBefore, stockUsed);
        _requireBalanceDecrease(config.usdg, usdgBalanceBefore, usdgUsed);
        if (stockUsed > pairLedger.stockIdle || usdgUsed > pairLedger.usdgIdle) {
            revert InsufficientLiquidity();
        }
        pairLedger.stockIdle -= stockUsed;
        pairLedger.usdgIdle -= usdgUsed;
        emit LiquidityRebalanced(pairId, stockUsed, usdgUsed, liquidityAdded);
    }

    function collectFees(bytes32 pairId, uint256 deadline)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 stockFees, uint256 usdgFees)
    {
        PairConfig storage config = _config(pairId);
        _checkDeadline(config, deadline);
        return _collectFees(pairId, config, _ledger[pairId], deadline);
    }

    function checkpoint(bytes32 pairId, uint256 deadline)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (int256 pnlUSDG)
    {
        PairConfig storage config = _config(pairId);
        if (config.emergencyMode) revert EmergencyMode();
        _checkDeadline(config, deadline);
        PairLedger storage pairLedger = _ledger[pairId];
        (pnlUSDG,,,) = _checkpointPair(pairId, config, pairLedger, deadline);
    }

    function withdrawForSide(
        bytes32 pairId,
        address token,
        uint256 requested,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256 returned, uint256 realizedLoss) {
        PairConfig storage config = _config(pairId);
        if (receiver == address(0) || receiver == address(this)) revert InvalidConfiguration();
        bool stockSide = _authorizeSide(config, token);
        PairLedger storage pairLedger = _ledger[pairId];
        uint256 principalBefore = stockSide ? pairLedger.stockPrincipal : pairLedger.usdgPrincipal;
        if (requested > principalBefore) revert InsufficientPrincipal();
        if (requested == 0) return (0, 0);

        uint256 idle = stockSide ? pairLedger.stockIdle : pairLedger.usdgIdle;
        bool hasOpenLiquidity = liquidityAdapter.positionState(pairId).liquidity != 0;
        // Idle is part of the pair's shared benchmark while any LP liquidity remains.
        // Settle current strategy losses before either side can reduce its claim, even
        // when that side's requested token is already available in the vault.
        if (idle < requested || hasOpenLiquidity) {
            if (config.emergencyMode) revert EmergencyMode();
            _checkDeadline(config, deadline);
            uint256 stockPrice;
            uint256 usdgPrice;
            // Derived from oracle prices alone, so it is constant for the whole call and can
            // be reused after the unwind and settlement without revalidating.
            uint160 referenceSqrtPriceX96;
            if (_checkpointIsStale(config, pairLedger)) {
                (, stockPrice, usdgPrice, referenceSqrtPriceX96) =
                    _checkpointPair(pairId, config, pairLedger, deadline);
            } else {
                PoolKey memory key = liquidityAdapter.poolKey(pairId);
                (,, referenceSqrtPriceX96) = oracleGuard.validatePoolPrice(pairId, key);
                (stockPrice, usdgPrice) = oracleGuard.pricesUSD18(pairId);
                _collectFees(pairId, config, pairLedger, deadline);
            }

            _unwindForWithdrawal(pairId, config, pairLedger, stockSide, requested, deadline);
            _settleShortfall(
                pairId, config, pairLedger, stockSide, requested, stockPrice, usdgPrice, deadline
            );
            _recognizeLoss(pairId, config, pairLedger, stockPrice, usdgPrice, referenceSqrtPriceX96);
        }

        uint256 finalIdle = stockSide ? pairLedger.stockIdle : pairLedger.usdgIdle;
        uint256 finalPrincipal = stockSide ? pairLedger.stockPrincipal : pairLedger.usdgPrincipal;
        returned = Math.min(requested, Math.min(finalIdle, finalPrincipal));
        if (stockSide) {
            pairLedger.stockIdle -= returned;
            pairLedger.stockPrincipal -= returned;
        } else {
            pairLedger.usdgIdle -= returned;
            pairLedger.usdgPrincipal -= returned;
            aggregateUsdgPrincipal[config.usdg] -= returned;
        }
        uint256 principalAfter = stockSide ? pairLedger.stockPrincipal : pairLedger.usdgPrincipal;
        // Report every claim reduction realized inside this withdrawal, including a
        // checkpoint loss that also reduces the caller's remaining strategy claim.
        // This lets a future pToken apply returned assets and loss atomically.
        if (principalBefore > principalAfter) {
            uint256 totalClaimReduction = principalBefore - principalAfter;
            if (totalClaimReduction > returned) realizedLoss = totalClaimReduction - returned;
        }
        _pushExact(token, receiver, returned);
        emit Withdrawal(pairId, token, receiver, requested, returned, realizedLoss);
    }

    function emergencyDecrease(bytes32 pairId, uint128 liquidity, uint256 deadline)
        external
        onlyRole(GUARDIAN_ROLE)
        nonReentrant
    {
        PairConfig storage config = _config(pairId);
        _checkDeadline(config, deadline);
        config.allocationPaused = true;
        config.swapsPaused = true;
        config.emergencyMode = true;
        PoolKey memory key = liquidityAdapter.poolKey(pairId);
        (,, uint160 referenceSqrtPriceX96) = oracleGuard.validatePoolPrice(pairId, key);
        (uint256 stockPrice, uint256 usdgPrice) = oracleGuard.pricesUSD18(pairId);
        uint256 stockBalanceBefore = IERC20(config.stockToken).balanceOf(address(this));
        uint256 usdgBalanceBefore = IERC20(config.usdg).balanceOf(address(this));
        (uint256 stockReceived, uint256 usdgReceived, uint128 liquidityRemoved) =
            liquidityAdapter.decreaseLiquidity(pairId, liquidity, referenceSqrtPriceX96, deadline);
        _requireBalanceIncrease(config.stockToken, stockBalanceBefore, stockReceived);
        _requireBalanceIncrease(config.usdg, usdgBalanceBefore, usdgReceived);
        PairLedger storage pairLedger = _ledger[pairId];
        pairLedger.stockIdle += stockReceived;
        pairLedger.usdgIdle += usdgReceived;
        // Allocate any shared LP loss atomically with the guardian exit. If this was
        // only a partial exit, withdrawForSide remains closed while liquidity remains.
        _recognizeLoss(pairId, config, pairLedger, stockPrice, usdgPrice, referenceSqrtPriceX96);
        emit EmergencyLiquidityDecreased(pairId, liquidityRemoved, stockReceived, usdgReceived);
        emit PairPauseUpdated(pairId, true, true, true);
    }

    function burnEmptyPosition(bytes32 pairId, uint256 deadline)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        PairConfig storage config = _config(pairId);
        _checkDeadline(config, deadline);
        uint256 stockBalanceBefore = IERC20(config.stockToken).balanceOf(address(this));
        uint256 usdgBalanceBefore = IERC20(config.usdg).balanceOf(address(this));
        (uint256 stockReceived, uint256 usdgReceived) =
            liquidityAdapter.burnEmptyPosition(pairId, deadline);
        _requireBalanceIncrease(config.stockToken, stockBalanceBefore, stockReceived);
        _requireBalanceIncrease(config.usdg, usdgBalanceBefore, usdgReceived);
        _ledger[pairId].stockIdle += stockReceived;
        _ledger[pairId].usdgIdle += usdgReceived;
    }

    function _collectFees(
        bytes32 pairId,
        PairConfig storage config,
        PairLedger storage pairLedger,
        uint256 deadline
    ) internal returns (uint256 stockFees, uint256 usdgFees) {
        uint256 stockBalanceBefore = IERC20(config.stockToken).balanceOf(address(this));
        uint256 usdgBalanceBefore = IERC20(config.usdg).balanceOf(address(this));
        (stockFees, usdgFees) = liquidityAdapter.collectFees(pairId, deadline);
        _requireBalanceIncrease(config.stockToken, stockBalanceBefore, stockFees);
        _requireBalanceIncrease(config.usdg, usdgBalanceBefore, usdgFees);
        uint256 stockReserve = Math.mulDiv(stockFees, config.reserveFeeBps, BPS);
        uint256 usdgReserve = Math.mulDiv(usdgFees, config.reserveFeeBps, BPS);
        if (stockReserve != 0) {
            uint256 balanceBefore = IERC20(config.stockToken).balanceOf(address(this));
            IERC20(config.stockToken).forceApprove(address(lossReserve), stockReserve);
            uint256 received = lossReserve.deposit(pairId, config.stockToken, stockReserve);
            IERC20(config.stockToken).forceApprove(address(lossReserve), 0);
            _requireBalanceDecrease(config.stockToken, balanceBefore, stockReserve);
            if (received != stockReserve) revert BalanceDeltaMismatch();
        }
        if (usdgReserve != 0) {
            uint256 balanceBefore = IERC20(config.usdg).balanceOf(address(this));
            IERC20(config.usdg).forceApprove(address(lossReserve), usdgReserve);
            uint256 received = lossReserve.deposit(pairId, config.usdg, usdgReserve);
            IERC20(config.usdg).forceApprove(address(lossReserve), 0);
            _requireBalanceDecrease(config.usdg, balanceBefore, usdgReserve);
            if (received != usdgReserve) revert BalanceDeltaMismatch();
        }
        uint256 netStock = stockFees - stockReserve;
        uint256 netUsdg = usdgFees - usdgReserve;
        pairLedger.stockIdle += netStock;
        pairLedger.usdgIdle += netUsdg;
        pairLedger.stockPrincipal += netStock;
        pairLedger.usdgPrincipal += netUsdg;
        aggregateUsdgPrincipal[config.usdg] += netUsdg;
        emit FeesProcessed(pairId, stockFees, usdgFees, stockReserve, usdgReserve);
    }

    function _checkpointPair(
        bytes32 pairId,
        PairConfig storage config,
        PairLedger storage pairLedger,
        uint256 deadline
    )
        internal
        returns (
            int256 pnlUSDG,
            uint256 stockPrice,
            uint256 usdgPrice,
            uint160 referenceSqrtPriceX96
        )
    {
        PoolKey memory key = liquidityAdapter.poolKey(pairId);
        (,, referenceSqrtPriceX96) = oracleGuard.validatePoolPrice(pairId, key);
        (stockPrice, usdgPrice) = oracleGuard.pricesUSD18(pairId);

        _collectFees(pairId, config, pairLedger, deadline);
        (uint256 stockAssets, uint256 usdgAssets) = _pairAssetsAt(pairId, referenceSqrtPriceX96);
        uint256 benchmark = _benchmarkUSDG(config, pairLedger, stockPrice, usdgPrice);
        uint256 gross = _grossUSDG(config, stockAssets, usdgAssets, stockPrice, usdgPrice);

        if (gross < benchmark && benchmark != 0) {
            uint256 loss = benchmark - gross;
            uint256 oldUsdgPrincipal = pairLedger.usdgPrincipal;
            pairLedger.stockPrincipal = Math.mulDiv(pairLedger.stockPrincipal, gross, benchmark);
            pairLedger.usdgPrincipal = Math.mulDiv(pairLedger.usdgPrincipal, gross, benchmark);
            aggregateUsdgPrincipal[config.usdg] -= oldUsdgPrincipal - pairLedger.usdgPrincipal;
            pairLedger.cumulativeLossUSDG += loss;
            pnlUSDG = -loss.toInt256();
        } else if (
            stockAssets >= pairLedger.stockPrincipal && usdgAssets >= pairLedger.usdgPrincipal
        ) {
            uint256 stockGain = stockAssets - pairLedger.stockPrincipal;
            uint256 usdgGain = usdgAssets - pairLedger.usdgPrincipal;
            pairLedger.stockPrincipal += stockGain;
            pairLedger.usdgPrincipal += usdgGain;
            aggregateUsdgPrincipal[config.usdg] += usdgGain;
            uint256 gain = _grossUSDG(config, stockGain, usdgGain, stockPrice, usdgPrice);
            pnlUSDG = gain.toInt256();
        }
        pairLedger.lastCheckpoint = uint64(block.timestamp);

        emit PairCheckpoint(
            pairId,
            stockAssets,
            usdgAssets,
            benchmark,
            pnlUSDG,
            pairLedger.stockPrincipal,
            pairLedger.usdgPrincipal
        );
    }

    function _unwindForWithdrawal(
        bytes32 pairId,
        PairConfig storage config,
        PairLedger storage pairLedger,
        bool stockSide,
        uint256 requested,
        uint256 deadline
    ) internal {
        uint256 idle = stockSide ? pairLedger.stockIdle : pairLedger.usdgIdle;
        if (idle >= requested) return;
        IUniswapV4PairedAdapter.PositionState memory position =
            liquidityAdapter.positionState(pairId);
        if (position.liquidity == 0) return;

        uint256 shortfall = requested - idle;
        uint256 targetInPosition = stockSide ? position.stockAmount : position.usdgAmount;
        if (targetInPosition == 0) {
            targetInPosition = 1;
            shortfall = 1;
        }
        uint256 targetAmount =
            Math.mulDiv(shortfall, BPS + config.withdrawOverUnwindBps, BPS, Math.Rounding.Ceil);
        uint256 liquidityRaw = Math.mulDiv(
            position.liquidity,
            Math.min(targetAmount, targetInPosition),
            targetInPosition,
            Math.Rounding.Ceil
        );
        uint128 liquidityToRemove = uint128(Math.min(liquidityRaw, position.liquidity));
        PoolKey memory key = liquidityAdapter.poolKey(pairId);
        (,, uint160 referenceSqrtPriceX96) = oracleGuard.validatePoolPrice(pairId, key);
        uint256 stockBalanceBefore = IERC20(config.stockToken).balanceOf(address(this));
        uint256 usdgBalanceBefore = IERC20(config.usdg).balanceOf(address(this));
        (uint256 stockReceived, uint256 usdgReceived,) = liquidityAdapter.decreaseLiquidity(
            pairId, liquidityToRemove, referenceSqrtPriceX96, deadline
        );
        _requireBalanceIncrease(config.stockToken, stockBalanceBefore, stockReceived);
        _requireBalanceIncrease(config.usdg, usdgBalanceBefore, usdgReceived);
        pairLedger.stockIdle += stockReceived;
        pairLedger.usdgIdle += usdgReceived;
    }

    function _settleShortfall(
        bytes32 pairId,
        PairConfig storage config,
        PairLedger storage pairLedger,
        bool stockSide,
        uint256 requested,
        uint256 stockPrice,
        uint256 usdgPrice,
        uint256 deadline
    ) internal {
        SettlementLib.settleShortfall(
            config,
            pairLedger,
            SettlementLib.SettleParams({
                pairId: pairId,
                stockSide: stockSide,
                requested: requested,
                stockPrice: stockPrice,
                usdgPrice: usdgPrice,
                deadline: deadline,
                lossReserve: lossReserve,
                oracleGuard: oracleGuard,
                liquidityAdapter: liquidityAdapter
            })
        );
    }

    function _recognizeLoss(
        bytes32 pairId,
        PairConfig storage config,
        PairLedger storage pairLedger,
        uint256 stockPrice,
        uint256 usdgPrice,
        uint160 referenceSqrtPriceX96
    ) internal {
        (uint256 stockAssets, uint256 usdgAssets) = _pairAssetsAt(pairId, referenceSqrtPriceX96);
        uint256 benchmark = _benchmarkUSDG(config, pairLedger, stockPrice, usdgPrice);
        uint256 gross = _grossUSDG(config, stockAssets, usdgAssets, stockPrice, usdgPrice);
        if (gross >= benchmark || benchmark == 0) return;
        uint256 loss = benchmark - gross;
        uint256 oldUsdgPrincipal = pairLedger.usdgPrincipal;
        pairLedger.stockPrincipal = Math.mulDiv(pairLedger.stockPrincipal, gross, benchmark);
        pairLedger.usdgPrincipal = Math.mulDiv(pairLedger.usdgPrincipal, gross, benchmark);
        aggregateUsdgPrincipal[config.usdg] -= oldUsdgPrincipal - pairLedger.usdgPrincipal;
        pairLedger.cumulativeLossUSDG += loss;
        pairLedger.lastCheckpoint = uint64(block.timestamp);
        emit PairCheckpoint(
            pairId,
            stockAssets,
            usdgAssets,
            benchmark,
            -loss.toInt256(),
            pairLedger.stockPrincipal,
            pairLedger.usdgPrincipal
        );
    }

    function _enforcePairCap(
        bytes32 pairId,
        PairConfig storage config,
        PairLedger storage pairLedger
    ) internal view {
        (uint256 stockPrice, uint256 usdgPrice) = oracleGuard.pricesUSD18(pairId);
        if (_pairCapExceeded(config, pairLedger, stockPrice, usdgPrice)) revert PairCapExceeded();
    }

    function _pairCapExceeded(
        PairConfig storage config,
        PairLedger storage pairLedger,
        uint256 stockPrice,
        uint256 usdgPrice
    ) internal view returns (bool) {
        return config.maxPairValueUSDG != 0
            && _benchmarkUSDG(config, pairLedger, stockPrice, usdgPrice) > config.maxPairValueUSDG;
    }

    function _benchmarkUSDG(
        PairConfig storage config,
        PairLedger storage pairLedger,
        uint256 stockPrice,
        uint256 usdgPrice
    ) internal view returns (uint256) {
        return _grossUSDG(
            config, pairLedger.stockPrincipal, pairLedger.usdgPrincipal, stockPrice, usdgPrice
        );
    }

    function _grossUSDG(
        PairConfig storage config,
        uint256 stockAmount,
        uint256 usdgAmount,
        uint256 stockPrice,
        uint256 usdgPrice
    ) internal view returns (uint256) {
        return VaultMath.valueUSD18(
            stockAmount, config.stockDecimals, stockPrice, Math.Rounding.Floor
        ) + VaultMath.valueUSD18(usdgAmount, config.usdgDecimals, usdgPrice, Math.Rounding.Floor);
    }

    function _authorizeSide(PairConfig storage config, address token)
        internal
        view
        returns (bool stockSide)
    {
        if (token == config.stockToken) {
            if (msg.sender != config.stockAccount) revert UnauthorizedSide();
            return true;
        }
        if (token == config.usdg) {
            if (msg.sender != config.usdgAccount) revert UnauthorizedSide();
            return false;
        }
        revert UnsupportedToken();
    }

    function _checkpointIsStale(PairConfig storage config, PairLedger storage pairLedger)
        internal
        view
        returns (bool)
    {
        return pairLedger.lastCheckpoint == 0
            || block.timestamp - pairLedger.lastCheckpoint > config.maxCheckpointAge;
    }

    function _requireFresh(PairConfig storage config, PairLedger storage pairLedger) internal view {
        if (_checkpointIsStale(config, pairLedger)) revert CheckpointStale();
    }

    function _observedBalanceIncrease(address token, uint256 balanceBefore)
        internal
        view
        returns (uint256 observed)
    {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore) revert BalanceDeltaMismatch();
        observed = balanceAfter - balanceBefore;
    }

    function _requireBalanceIncrease(address token, uint256 balanceBefore, uint256 expected)
        internal
        view
    {
        if (_observedBalanceIncrease(token, balanceBefore) != expected) {
            revert BalanceDeltaMismatch();
        }
    }

    function _requireBalanceDecrease(address token, uint256 balanceBefore, uint256 expected)
        internal
        view
    {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != expected) {
            revert BalanceDeltaMismatch();
        }
    }

    function _pushExact(address token, address receiver, uint256 amount) internal {
        IERC20 asset = IERC20(token);
        uint256 senderBefore = asset.balanceOf(address(this));
        uint256 receiverBefore = asset.balanceOf(receiver);
        asset.safeTransfer(receiver, amount);
        uint256 senderAfter = asset.balanceOf(address(this));
        uint256 receiverAfter = asset.balanceOf(receiver);
        if (
            senderAfter > senderBefore || receiverAfter < receiverBefore
                || senderBefore - senderAfter != amount || receiverAfter - receiverBefore != amount
        ) revert BalanceDeltaMismatch();
    }

    function _checkDeadline(PairConfig storage config, uint256 deadline) internal view {
        if (deadline < block.timestamp) revert InvalidDeadline();
        uint256 delay = deadline - block.timestamp;
        if (delay > config.maxDeadlineDelay) revert InvalidDeadline();
    }

    function _config(bytes32 pairId) internal view returns (PairConfig storage config) {
        config = _pairConfig[pairId];
        if (!config.exists) revert UnknownPair();
    }

    function _validatePairConfig(bytes32 pairId, PairConfig calldata config) internal view {
        if (
            pairId == bytes32(0) || config.stockToken == address(0) || config.usdg == address(0)
                || config.stockAccount == address(0) || config.usdgAccount == address(0)
                || config.stockToken == config.usdg || config.maxSettlementSwapUSDG == 0
                || config.maxCheckpointAge == 0 || config.deprecatedMinDeadlineDelay != 0
                || config.maxDeadlineDelay == 0 || config.maxDeadlineDelay > 30 minutes
                || config.reserveFeeBps > 5_000 || config.maxSwapSlippageBps == 0
                || config.maxSwapSlippageBps > 500 || config.withdrawOverUnwindBps > 2_000
                || config.stockDecimals > 36 || config.usdgDecimals > 36
        ) revert InvalidConfiguration();
        if (config.stockDecimals != IERC20Metadata(config.stockToken).decimals()) {
            revert InvalidConfiguration();
        }
        if (config.usdgDecimals != IERC20Metadata(config.usdg).decimals()) {
            revert InvalidConfiguration();
        }
    }

    uint256[42] private __gap;
}
