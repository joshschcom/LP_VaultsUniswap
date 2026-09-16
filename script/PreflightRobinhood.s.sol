// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IStateView } from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { IStockToken } from "../src/interfaces/IStockToken.sol";
import { VaultMath } from "../src/libraries/VaultMath.sol";

contract PreflightRobinhood is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    struct Inputs {
        address poolManager;
        address positionManager;
        address stateView;
        address universalRouter;
        address permit2;
        address stock;
        address usdg;
        address stockFeed;
        address sequencerFeed;
        bytes32 expectedPoolId;
        bytes32 registrySnapshotSha256;
        bytes32 manifestSha256;
        string expectedStockName;
        string expectedStockSymbol;
        uint256 expectedUiMultiplier;
        uint256 minStockPriceUSD18;
        uint256 maxStockPriceUSD18;
        uint256 maxStockFeedAge;
        uint256 sequencerGracePeriod;
        uint256 maxPriceDeviationBps;
        uint256 removalToleranceBps;
        uint24 fee;
        int24 tickSpacing;
        bool sequencerWaiverApproved;
    }

    function run() external view {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "WRONG_CHAIN");
        Inputs memory input = _loadInputs();
        _validateContractsAndHashes(input);

        require(!IStockToken(input.stock).oraclePaused(), "STOCK_ORACLE_PAUSED");
        require(
            keccak256(bytes(IERC20Metadata(input.stock).name()))
                == keccak256(bytes(input.expectedStockName)),
            "STOCK_NAME_MISMATCH"
        );
        require(
            keccak256(bytes(IERC20Metadata(input.stock).symbol()))
                == keccak256(bytes(input.expectedStockSymbol)),
            "STOCK_SYMBOL_MISMATCH"
        );
        uint256 uiMultiplier = IStockToken(input.stock).uiMultiplier();
        uint256 pendingMultiplier = IStockToken(input.stock).newUIMultiplier();
        uint256 multiplierEffectiveAt = IStockToken(input.stock).effectiveAt();
        require(uiMultiplier == input.expectedUiMultiplier, "UI_MULTIPLIER_MISMATCH");
        require(
            multiplierEffectiveAt == 0 && pendingMultiplier == uiMultiplier,
            "PENDING_MULTIPLIER_CHANGE"
        );
        uint8 stockDecimals = IERC20Metadata(input.stock).decimals();
        uint8 usdgDecimals = IERC20Metadata(input.usdg).decimals();
        require(stockDecimals <= 36 && usdgDecimals <= 36, "TOKEN_DECIMALS");

        address token0 = input.stock < input.usdg ? input.stock : input.usdg;
        address token1 = input.stock < input.usdg ? input.usdg : input.stock;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: input.fee,
            tickSpacing: input.tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();
        require(PoolId.unwrap(id) == input.expectedPoolId, "POOL_ID_MISMATCH");
        IPoolManager manager = IPoolManager(input.poolManager);
        IStateView stateView = IStateView(input.stateView);
        require(address(stateView.poolManager()) == input.poolManager, "STATE_VIEW_MANAGER");

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        require(sqrtPriceX96 != 0, "POOL_UNINITIALIZED");
        (uint160 viewSqrtPriceX96, int24 viewTick, uint24 viewProtocolFee, uint24 viewLpFee) =
            stateView.getSlot0(id);
        require(
            viewSqrtPriceX96 == sqrtPriceX96 && viewTick == tick && viewProtocolFee == protocolFee
                && viewLpFee == lpFee,
            "STATE_VIEW_SLOT0_MISMATCH"
        );
        uint128 liquidity = manager.getLiquidity(id);
        require(stateView.getLiquidity(id) == liquidity, "STATE_VIEW_LIQUIDITY_MISMATCH");

        IAggregatorV3 feed = IAggregatorV3(input.stockFeed);
        require(feed.decimals() <= 36, "FEED_DECIMALS");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        require(answer > 0 && updatedAt != 0 && answeredInRound >= roundId, "INVALID_FEED");
        require(updatedAt <= block.timestamp, "FUTURE_FEED_TIMESTAMP");
        require(block.timestamp - updatedAt <= input.maxStockFeedAge, "STALE_FEED");
        uint256 stockPriceUSD18 =
            VaultMath.scaleToWad(uint256(answer), feed.decimals(), Math.Rounding.Floor);
        require(stockPriceUSD18 != 0, "NORMALIZED_ZERO_PRICE");
        require(
            input.minStockPriceUSD18 <= stockPriceUSD18
                && stockPriceUSD18 <= input.maxStockPriceUSD18,
            "FEED_PRICE_OUT_OF_BOUNDS"
        );
        _validateSequencer(input);

        console2.log("stock", IERC20Metadata(input.stock).symbol());
        console2.log("UI multiplier", uiMultiplier);
        console2.log("stock decimals", stockDecimals);
        console2.log("USDG decimals", usdgDecimals);
        console2.log("feed", feed.description());
        console2.log("feed decimals", feed.decimals());
        console2.log("stock price USD18", stockPriceUSD18);
        console2.log("maximum pool deviation bps", input.maxPriceDeviationBps);
        console2.log("liquidity-removal tolerance bps", input.removalToleranceBps);
        console2.log("pool id");
        console2.logBytes32(input.expectedPoolId);
        console2.log("sqrtPriceX96", uint256(sqrtPriceX96));
        console2.log("tick", int256(tick));
        console2.log("liquidity", uint256(liquidity));
        console2.log("protocol fee", uint256(protocolFee));
        console2.log("lp fee", uint256(lpFee));
        console2.log("registry snapshot SHA-256");
        console2.logBytes32(input.registrySnapshotSha256);
        console2.log("manifest SHA-256");
        console2.logBytes32(input.manifestSha256);
    }

    function _loadInputs() internal view returns (Inputs memory input) {
        input.poolManager = vm.envAddress("POOL_MANAGER");
        input.positionManager = vm.envAddress("POSITION_MANAGER");
        input.stateView = vm.envAddress("STATE_VIEW");
        input.universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        input.permit2 = vm.envAddress("PERMIT2");
        input.stock = vm.envAddress("STOCK_TOKEN");
        input.usdg = vm.envAddress("USDG");
        input.stockFeed = vm.envAddress("STOCK_PRICE_FEED");
        input.sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));
        input.expectedPoolId = vm.envBytes32("POOL_ID");
        input.registrySnapshotSha256 = vm.envBytes32("REGISTRY_SNAPSHOT_SHA256");
        input.manifestSha256 = vm.envBytes32("MANIFEST_SHA256");
        input.expectedStockName = vm.envString("EXPECTED_STOCK_NAME");
        input.expectedStockSymbol = vm.envString("EXPECTED_STOCK_SYMBOL");
        input.expectedUiMultiplier = vm.envUint("EXPECTED_UI_MULTIPLIER");
        input.minStockPriceUSD18 = vm.envUint("MIN_STOCK_PRICE_USD18");
        input.maxStockPriceUSD18 = vm.envUint("MAX_STOCK_PRICE_USD18");
        input.maxStockFeedAge = vm.envUint("MAX_STOCK_FEED_AGE");
        input.sequencerGracePeriod = vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(0));
        input.maxPriceDeviationBps = vm.envOr("MAX_PRICE_DEVIATION_BPS", uint256(300));
        input.removalToleranceBps = vm.envOr("REMOVAL_TOLERANCE_BPS", uint256(400));
        input.fee = uint24(vm.envUint("POOL_FEE"));
        input.tickSpacing = int24(vm.envInt("TICK_SPACING"));
        input.sequencerWaiverApproved = vm.envOr("SEQUENCER_WAIVER_APPROVED", false);
    }

    function _validateContractsAndHashes(Inputs memory input) internal view {
        _requireContract(input.poolManager);
        _requireContract(input.positionManager);
        _requireContract(input.stateView);
        _requireContract(input.universalRouter);
        _requireContract(input.permit2);
        _requireContract(input.stock);
        _requireContract(input.usdg);
        _requireContract(input.stockFeed);
        require(input.registrySnapshotSha256 != bytes32(0), "MISSING_REGISTRY_SNAPSHOT_HASH");
        require(input.manifestSha256 != bytes32(0), "MISSING_MANIFEST_HASH");
        require(bytes(input.expectedStockName).length != 0, "MISSING_STOCK_NAME");
        require(bytes(input.expectedStockSymbol).length != 0, "MISSING_STOCK_SYMBOL");
        require(input.expectedUiMultiplier != 0, "INVALID_UI_MULTIPLIER");
        require(
            input.minStockPriceUSD18 != 0 && input.minStockPriceUSD18 <= input.maxStockPriceUSD18,
            "INVALID_PRICE_BOUNDS"
        );
        require(input.maxStockFeedAge != 0, "INVALID_FEED_AGE");
        require(input.maxPriceDeviationBps <= 1_900, "INVALID_POOL_DEVIATION");
        require(
            input.removalToleranceBps <= 2_000
                && input.removalToleranceBps >= input.maxPriceDeviationBps + 100,
            "INVALID_REMOVAL_TOLERANCE"
        );
    }

    function _validateSequencer(Inputs memory input) internal view {
        if (input.sequencerFeed == address(0)) {
            require(input.sequencerWaiverApproved, "SEQUENCER_FEED_OR_WAIVER_REQUIRED");
            return;
        }
        require(!input.sequencerWaiverApproved, "AMBIGUOUS_SEQUENCER_POLICY");
        require(input.sequencerGracePeriod >= 1 hours, "INVALID_SEQUENCER_GRACE_PERIOD");
        _requireContract(input.sequencerFeed);
        (, int256 answer, uint256 startedAt, uint256 updatedAt,) =
            IAggregatorV3(input.sequencerFeed).latestRoundData();
        require(answer == 0 && startedAt != 0 && updatedAt != 0, "SEQUENCER_UNAVAILABLE");
        require(startedAt <= block.timestamp, "FUTURE_SEQUENCER_TIMESTAMP");
        require(block.timestamp - startedAt > input.sequencerGracePeriod, "SEQUENCER_GRACE_PERIOD");
    }

    function _requireContract(address target) internal view {
        require(target != address(0) && target.code.length != 0, "MISSING_CODE");
    }
}
