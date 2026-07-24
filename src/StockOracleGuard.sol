// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { IAggregatorV3 } from "./interfaces/IAggregatorV3.sol";
import { IStockToken } from "./interfaces/IStockToken.sol";
import { IStockOracleGuard } from "./interfaces/IStockOracleGuard.sol";
import { VaultMath } from "./libraries/VaultMath.sol";

contract StockOracleGuard is Initializable, AccessControlUpgradeable, IStockOracleGuard {
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    uint256 internal constant BPS = 10_000;
    uint64 public constant MIN_SEQUENCER_GRACE_PERIOD = 1 hours;

    struct FeedConfig {
        address stockToken;
        address usdg;
        IAggregatorV3 stockFeed;
        IAggregatorV3 usdgFeed;
        IAggregatorV3 sequencerFeed;
        bytes32 poolId;
        uint64 maxStaleness;
        uint64 sequencerGracePeriod;
        uint16 maxPriceDeviationBps;
        uint8 stockDecimals;
        uint8 usdgDecimals;
        uint8 stockFeedDecimals;
        uint8 usdgFeedDecimals;
        bool usdgFixedOne;
        bool enabled;
    }

    IPoolManager public poolManager;
    mapping(bytes32 => FeedConfig) private _feeds;

    error InvalidConfiguration();
    error PairNotEnabled();
    error InvalidOracleAnswer(address feed);
    error StaleOracle(address feed, uint256 updatedAt);
    error IncompleteOracleRound(address feed, uint80 roundId, uint80 answeredInRound);
    error StockOraclePaused();
    error SequencerUnavailable();
    error SequencerGracePeriod();
    error PoolMismatch();
    error PoolUninitialized();
    error PriceDeviation(uint256 oraclePrice, uint256 poolPrice);
    error InvalidReferencePrice();

    event FeedConfigured(bytes32 indexed pairId, FeedConfig config);
    event FeedEnabled(bytes32 indexed pairId, bool enabled);

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, IPoolManager poolManager_) external initializer {
        if (admin == address(0) || address(poolManager_) == address(0)) {
            revert InvalidConfiguration();
        }
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        poolManager = poolManager_;
    }

    function configurePair(bytes32 pairId, FeedConfig calldata config)
        external
        onlyRole(CONFIG_ROLE)
    {
        if (
            pairId == bytes32(0) || config.stockToken == address(0) || config.usdg == address(0)
                || address(config.stockFeed) == address(0) || config.poolId == bytes32(0)
                || config.maxStaleness == 0 || config.maxPriceDeviationBps == 0
                || config.maxPriceDeviationBps > BPS || config.stockToken == config.usdg
                || config.stockDecimals > 36 || config.usdgDecimals > 36
                || config.stockFeedDecimals > 36
                || (!config.usdgFixedOne && config.usdgFeedDecimals > 36)
                || (address(config.sequencerFeed) != address(0)
                    && config.sequencerGracePeriod < MIN_SEQUENCER_GRACE_PERIOD)
        ) revert InvalidConfiguration();
        if (!config.usdgFixedOne && address(config.usdgFeed) == address(0)) {
            revert InvalidConfiguration();
        }
        if (config.stockDecimals != IERC20Metadata(config.stockToken).decimals()) {
            revert InvalidConfiguration();
        }
        if (config.usdgDecimals != IERC20Metadata(config.usdg).decimals()) {
            revert InvalidConfiguration();
        }
        if (config.stockFeedDecimals != config.stockFeed.decimals()) revert InvalidConfiguration();
        if (!config.usdgFixedOne && config.usdgFeedDecimals != config.usdgFeed.decimals()) {
            revert InvalidConfiguration();
        }
        try IStockToken(config.stockToken).oraclePaused() returns (bool) { }
        catch {
            revert InvalidConfiguration();
        }

        _feeds[pairId] = config;
        emit FeedConfigured(pairId, config);
    }

    function setEnabled(bytes32 pairId, bool enabled) external onlyRole(CONFIG_ROLE) {
        if (_feeds[pairId].stockToken == address(0)) revert PairNotEnabled();
        _feeds[pairId].enabled = enabled;
        emit FeedEnabled(pairId, enabled);
    }

    function feedConfig(bytes32 pairId) external view returns (FeedConfig memory) {
        return _feeds[pairId];
    }

    function maxPriceDeviationBps(bytes32 pairId) external view override returns (uint16) {
        FeedConfig storage config = _feeds[pairId];
        if (config.stockToken == address(0)) revert PairNotEnabled();
        return config.maxPriceDeviationBps;
    }

    function pricesUSD18(bytes32 pairId)
        public
        view
        override
        returns (uint256 stockPrice, uint256 usdgPrice)
    {
        FeedConfig storage config = _feeds[pairId];
        if (!config.enabled) revert PairNotEnabled();
        // Deliberately fail closed for LP-backed operations. Idle withdrawals do not
        // call the guard, but neither normal nor guardian liquidity removal may bypass
        // a stock-token oracle pause.
        if (IStockToken(config.stockToken).oraclePaused()) revert StockOraclePaused();
        _checkSequencer(config);

        stockPrice = _read(config.stockFeed, config.stockFeedDecimals, config.maxStaleness);
        usdgPrice = config.usdgFixedOne
            ? 1e18
            : _read(config.usdgFeed, config.usdgFeedDecimals, config.maxStaleness);
    }

    function validatePoolPrice(bytes32 pairId, PoolKey calldata key)
        external
        view
        override
        returns (uint256 oracleStockInUsdg, uint256 poolStockInUsdg, uint160 referenceSqrtPriceX96)
    {
        FeedConfig storage config = _feeds[pairId];
        (uint256 stockPrice, uint256 usdgPrice) = pricesUSD18(pairId);

        PoolKey memory keyMemory = key;
        PoolId id = keyMemory.toId();
        if (PoolId.unwrap(id) != config.poolId) revert PoolMismatch();
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (!((currency0 == config.stockToken && currency1 == config.usdg)
                    || (currency0 == config.usdg && currency1 == config.stockToken))) revert PoolMismatch();

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolUninitialized();

        uint256 oneStock = 10 ** config.stockDecimals;
        uint256 quotedUsdg =
            VaultMath.quoteAtTick(tick, oneStock.toUint128(), config.stockToken, config.usdg);
        poolStockInUsdg = VaultMath.scaleToWad(quotedUsdg, config.usdgDecimals, Math.Rounding.Floor);
        oracleStockInUsdg = Math.mulDiv(stockPrice, 1e18, usdgPrice);
        if (oracleStockInUsdg == 0) revert InvalidReferencePrice();
        referenceSqrtPriceX96 = _referenceSqrtPriceX96(config, currency0, oracleStockInUsdg);

        uint256 difference = poolStockInUsdg > oracleStockInUsdg
            ? poolStockInUsdg - oracleStockInUsdg
            : oracleStockInUsdg - poolStockInUsdg;
        if (Math.mulDiv(difference, BPS, oracleStockInUsdg) > config.maxPriceDeviationBps) {
            revert PriceDeviation(oracleStockInUsdg, poolStockInUsdg);
        }
    }

    function _read(IAggregatorV3 feed, uint8 decimals, uint64 maxStaleness)
        internal
        view
        returns (uint256 normalized)
    {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) {
            revert InvalidOracleAnswer(address(feed));
        }
        if (answeredInRound < roundId) {
            revert IncompleteOracleRound(address(feed), roundId, answeredInRound);
        }
        if (block.timestamp - updatedAt > maxStaleness) {
            revert StaleOracle(address(feed), updatedAt);
        }
        normalized = VaultMath.scaleToWad(answer.toUint256(), decimals, Math.Rounding.Floor);
        if (normalized == 0) revert InvalidOracleAnswer(address(feed));
    }

    function _referenceSqrtPriceX96(
        FeedConfig storage config,
        address currency0,
        uint256 oracleStockInUsdg
    ) internal view returns (uint160 referenceSqrtPriceX96) {
        uint256 stockScale = 10 ** config.stockDecimals;
        uint256 usdgScale = 10 ** config.usdgDecimals;
        uint256 rawRatioWad;
        if (currency0 == config.stockToken) {
            rawRatioWad = Math.mulDiv(oracleStockInUsdg, usdgScale, stockScale);
        } else {
            uint256 inversePriceWad = Math.mulDiv(1e18, 1e18, oracleStockInUsdg);
            rawRatioWad = Math.mulDiv(inversePriceWad, stockScale, usdgScale);
        }
        if (rawRatioWad == 0) revert InvalidReferencePrice();

        uint256 maxRawRatioWad = Math.mulDiv(type(uint256).max, 1e18, uint256(1) << 128);
        if (rawRatioWad > maxRawRatioWad) revert InvalidReferencePrice();
        uint256 ratioX128 = Math.mulDiv(rawRatioWad, uint256(1) << 128, 1e18);
        if (ratioX128 == 0) revert InvalidReferencePrice();
        uint256 sqrtPrice = Math.sqrt(ratioX128) << 32;
        if (
            sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE
                || sqrtPrice > type(uint160).max
        ) revert InvalidReferencePrice();
        referenceSqrtPriceX96 = sqrtPrice.toUint160();
    }

    function _checkSequencer(FeedConfig storage config) internal view {
        if (address(config.sequencerFeed) == address(0)) return;
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = config.sequencerFeed.latestRoundData();
        if (answer != 0 || updatedAt == 0 || answeredInRound < roundId) {
            revert SequencerUnavailable();
        }
        uint256 recoveryAt = startedAt > updatedAt ? startedAt : updatedAt;
        if (
            recoveryAt > block.timestamp
                || block.timestamp - recoveryAt <= config.sequencerGracePeriod
        ) {
            revert SequencerGracePeriod();
        }
    }

    uint256[44] private __gap;
}
