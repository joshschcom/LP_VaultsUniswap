// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import { IAggregatorV3 } from "./interfaces/IAggregatorV3.sol";
import { IStockToken } from "./interfaces/IStockToken.sol";
import { IStockOracleGuard } from "./interfaces/IStockOracleGuard.sol";
import { VaultMath } from "./libraries/VaultMath.sol";

contract StockOracleGuard is Initializable, AccessControlUpgradeable, IStockOracleGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    uint256 internal constant BPS = 10_000;

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

    event FeedConfigured(bytes32 indexed pairId, address indexed stockToken, address stockFeed);
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

        _feeds[pairId] = config;
        emit FeedConfigured(pairId, config.stockToken, address(config.stockFeed));
    }

    function setEnabled(bytes32 pairId, bool enabled) external onlyRole(CONFIG_ROLE) {
        if (_feeds[pairId].stockToken == address(0)) revert PairNotEnabled();
        _feeds[pairId].enabled = enabled;
        emit FeedEnabled(pairId, enabled);
    }

    function feedConfig(bytes32 pairId) external view returns (FeedConfig memory) {
        return _feeds[pairId];
    }

    function pricesUSD18(bytes32 pairId)
        public
        view
        override
        returns (uint256 stockPrice, uint256 usdgPrice)
    {
        FeedConfig storage config = _feeds[pairId];
        if (!config.enabled) revert PairNotEnabled();
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
        returns (uint256 oracleStockInUsdg, uint256 poolStockInUsdg)
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
            VaultMath.quoteAtTick(tick, uint128(oneStock), config.stockToken, config.usdg);
        poolStockInUsdg = VaultMath.scaleToWad(quotedUsdg, config.usdgDecimals, Math.Rounding.Floor);
        oracleStockInUsdg = Math.mulDiv(stockPrice, 1e18, usdgPrice);

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
        normalized = VaultMath.scaleToWad(uint256(answer), decimals, Math.Rounding.Floor);
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
