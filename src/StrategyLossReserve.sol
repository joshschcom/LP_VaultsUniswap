// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IStrategyLossReserve } from "./interfaces/IStrategyLossReserve.sol";

contract StrategyLossReserve is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IStrategyLossReserve
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    uint256 internal constant BPS = 10_000;

    struct ReserveConfig {
        address stockToken;
        address usdg;
        uint128 maxUsePerTxUSDG;
        uint128 dailyCapUSDG;
        uint16 maxCoverageBps;
        bool paused;
        bool exists;
    }

    struct DailyUsage {
        uint64 day;
        uint192 usedUSDG;
    }

    mapping(bytes32 => ReserveConfig) public reserveConfig;
    mapping(bytes32 => mapping(address => uint256)) private _available;
    mapping(bytes32 => DailyUsage) public dailyUsage;
    mapping(address => uint256) public accountedBalance;

    error InvalidConfiguration();
    error UnknownPair();
    error UnsupportedToken();
    error ReservePaused();
    error CoverageCapExceeded();
    error PairMustBePaused();
    error BalanceDeltaMismatch();
    error InsufficientSurplus();

    event ReserveConfigured(bytes32 indexed pairId, address stockToken, address usdg);
    event ReserveFunded(
        bytes32 indexed pairId, address indexed token, address indexed funder, uint256 amount
    );
    event ReserveCovered(
        bytes32 indexed pairId,
        address indexed token,
        uint256 requested,
        uint256 covered,
        uint256 coveredValueUSDG,
        uint256 postCoverageDeficitUSDG
    );
    event ReservePauseUpdated(bytes32 indexed pairId, bool paused);
    event ReserveWithdrawn(
        bytes32 indexed pairId, address indexed token, address indexed to, uint256 amount
    );
    event SurplusSwept(address indexed token, address indexed to, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address vault) external initializer {
        if (admin == address(0) || vault == address(0)) revert InvalidConfiguration();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(VAULT_ROLE, vault);
    }

    function configurePair(bytes32 pairId, ReserveConfig calldata config)
        external
        onlyRole(CONFIG_ROLE)
    {
        if (
            pairId == bytes32(0) || config.stockToken == address(0) || config.usdg == address(0)
                || config.stockToken == config.usdg || config.maxCoverageBps > BPS
                || config.maxUsePerTxUSDG == 0 || config.dailyCapUSDG < config.maxUsePerTxUSDG
        ) revert InvalidConfiguration();
        ReserveConfig storage current = reserveConfig[pairId];
        if (
            current.exists
                && (config.stockToken != current.stockToken || config.usdg != current.usdg)
        ) revert InvalidConfiguration();
        reserveConfig[pairId] = config;
        reserveConfig[pairId].exists = true;
        emit ReserveConfigured(pairId, config.stockToken, config.usdg);
    }

    function setPaused(bytes32 pairId, bool paused) external onlyRole(CONFIG_ROLE) {
        if (!reserveConfig[pairId].exists) revert UnknownPair();
        reserveConfig[pairId].paused = paused;
        emit ReservePauseUpdated(pairId, paused);
    }

    function deposit(bytes32 pairId, address token, uint256 amount)
        external
        nonReentrant
        returns (uint256 received)
    {
        ReserveConfig storage config = reserveConfig[pairId];
        _validateToken(config, token);
        if (amount == 0) return 0;
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        received = asset.balanceOf(address(this)) - beforeBalance;
        _available[pairId][token] += received;
        accountedBalance[token] += received;
        emit ReserveFunded(pairId, token, msg.sender, received);
    }

    function cover(
        bytes32 pairId,
        address token,
        uint256 requested,
        uint256 requestedValueUSDG,
        uint256 realizedDeficitUSDG
    ) external onlyRole(VAULT_ROLE) nonReentrant returns (uint256 covered) {
        // Values and deficit attestations come only from the configured vault. The
        // reserve intentionally treats that access-controlled caller as its accounting
        // trust boundary and independently enforces the configured coverage limits.
        ReserveConfig storage config = reserveConfig[pairId];
        _validateToken(config, token);
        if (config.paused) revert ReservePaused();
        if (requested == 0 || requestedValueUSDG == 0 || realizedDeficitUSDG == 0) return 0;

        uint256 maxByRatio = Math.mulDiv(realizedDeficitUSDG, config.maxCoverageBps, BPS);
        uint64 day = uint64(block.timestamp / 1 days);
        DailyUsage storage usage = dailyUsage[pairId];
        uint256 usedToday = usage.day == day ? usage.usedUSDG : 0;
        uint256 dailyRemaining =
            config.dailyCapUSDG > usedToday ? config.dailyCapUSDG - usedToday : 0;
        uint256 maxValue = Math.min(Math.min(config.maxUsePerTxUSDG, dailyRemaining), maxByRatio);
        if (maxValue == 0) return 0;

        uint256 maxTokensByValue = Math.mulDiv(requested, maxValue, requestedValueUSDG);
        covered = Math.min(Math.min(requested, maxTokensByValue), _available[pairId][token]);
        if (covered == 0) return 0;
        uint256 coveredValueUSDG = Math.mulDiv(requestedValueUSDG, covered, requested);
        if (coveredValueUSDG > maxValue) revert CoverageCapExceeded();

        if (usage.day != day) {
            usage.day = day;
            usage.usedUSDG = 0;
        }
        usage.usedUSDG += coveredValueUSDG.toUint192();
        _available[pairId][token] -= covered;
        accountedBalance[token] -= covered;
        _pushExact(token, msg.sender, covered);

        emit ReserveCovered(
            pairId,
            token,
            requested,
            covered,
            coveredValueUSDG,
            realizedDeficitUSDG > coveredValueUSDG ? realizedDeficitUSDG - coveredValueUSDG : 0
        );
    }

    function available(bytes32 pairId, address token) external view returns (uint256) {
        return _available[pairId][token];
    }

    function withdrawPausedReserve(bytes32 pairId, address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        ReserveConfig storage config = reserveConfig[pairId];
        _validateToken(config, token);
        if (!config.paused) revert PairMustBePaused();
        if (to == address(0) || amount > _available[pairId][token]) revert InvalidConfiguration();
        _available[pairId][token] -= amount;
        accountedBalance[token] -= amount;
        _pushExact(token, to, amount);
        emit ReserveWithdrawn(pairId, token, to, amount);
    }

    function sweepSurplus(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0) || to == address(0) || to == address(this)) {
            revert InvalidConfiguration();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 accounted = accountedBalance[token];
        uint256 surplus = balance > accounted ? balance - accounted : 0;
        if (amount > surplus) revert InsufficientSurplus();
        _pushExact(token, to, amount);
        emit SurplusSwept(token, to, amount);
    }

    function _pushExact(address token, address to, uint256 amount) internal {
        IERC20 asset = IERC20(token);
        uint256 senderBefore = asset.balanceOf(address(this));
        uint256 receiverBefore = asset.balanceOf(to);
        asset.safeTransfer(to, amount);
        uint256 senderAfter = asset.balanceOf(address(this));
        uint256 receiverAfter = asset.balanceOf(to);
        if (
            senderAfter > senderBefore || receiverAfter < receiverBefore
                || senderBefore - senderAfter != amount || receiverAfter - receiverBefore != amount
        ) revert BalanceDeltaMismatch();
    }

    function _validateToken(ReserveConfig storage config, address token) internal view {
        if (!config.exists) revert UnknownPair();
        if (token != config.stockToken && token != config.usdg) revert UnsupportedToken();
    }

    uint256[44] private __gap;
}
