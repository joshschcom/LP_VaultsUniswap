// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { StockOracleGuard } from "../src/StockOracleGuard.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockAggregator } from "./mocks/MockAggregator.sol";
import { MockPoolManagerState } from "./mocks/MockUniswapComponents.sol";

contract MetadataOnlyToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract StockOracleGuardTest is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant PAIR_ID = keccak256("NVDA/USDG");
    StockOracleGuard internal guard;
    MockERC20 internal stock;
    MockERC20 internal usdg;
    MockAggregator internal stockFeed;
    MockPoolManagerState internal poolManager;

    function setUp() external {
        vm.warp(10 days);
        stock = new MockERC20("NVIDIA", "NVDA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        stockFeed = new MockAggregator(8, "NVDA / USD", 123_45000000);
        poolManager = new MockPoolManagerState();
        StockOracleGuard implementation = new StockOracleGuard();
        guard = StockOracleGuard(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        StockOracleGuard.initialize,
                        (address(this), IPoolManager(address(poolManager)))
                    )
                )
            )
        );
        _configure(address(0));
    }

    function testNormalizesFeedWithoutApplyingMultiplierAgain() external view {
        (uint256 stockPrice, uint256 usdgPrice) = guard.pricesUSD18(PAIR_ID);
        assertEq(stockPrice, 123.45e18);
        assertEq(usdgPrice, 1e18);
    }

    function testStockOraclePauseBlocksRisk() external {
        stock.setOraclePaused(true);
        vm.expectRevert(StockOracleGuard.StockOraclePaused.selector);
        guard.pricesUSD18(PAIR_ID);
    }

    function testConfiguredDeviationIsExposedForRemovalSafetyChecks() external view {
        assertEq(guard.maxPriceDeviationBps(PAIR_ID), 500);
    }

    function testStaleRoundIsRejected() external {
        uint256 staleAt = block.timestamp - 2 hours;
        stockFeed.setRound(123_45000000, staleAt, 3);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockOracleGuard.StaleOracle.selector, address(stockFeed), staleAt
            )
        );
        guard.pricesUSD18(PAIR_ID);
    }

    function testSequencerDownIsRejected() external {
        MockAggregator sequencer = new MockAggregator(0, "Sequencer", 1);
        _configure(address(sequencer));
        vm.expectRevert(StockOracleGuard.SequencerUnavailable.selector);
        guard.pricesUSD18(PAIR_ID);
    }

    function testReturnsChainlinkDerivedReferenceSqrtPriceInPoolOrder() external {
        uint160 expectedReference = _referenceSqrtPriceX96(123.45e18);
        int24 referenceTick = TickMath.getTickAtSqrtPrice(expectedReference);
        poolManager.setSlot0(expectedReference, referenceTick);

        (uint256 oraclePrice, uint256 poolPrice, uint160 referencePrice) =
            guard.validatePoolPrice(PAIR_ID, _poolKey());

        assertEq(oraclePrice, 123.45e18);
        assertApproxEqRel(poolPrice, oraclePrice, 0.0002e18);
        assertEq(referencePrice, expectedReference);
    }

    function testManipulatedPoolPriceIsRejected() external {
        uint160 expectedReference = _referenceSqrtPriceX96(123.45e18);
        int24 manipulatedTick = TickMath.getTickAtSqrtPrice(expectedReference) + 2_000;
        poolManager.setSlot0(TickMath.getSqrtPriceAtTick(manipulatedTick), manipulatedTick);

        vm.expectPartialRevert(StockOracleGuard.PriceDeviation.selector);
        guard.validatePoolPrice(PAIR_ID, _poolKey());
    }

    function testTokenDecimalsAbove36AreRejectedAtConfiguration() external {
        MockERC20 excessiveDecimals = new MockERC20("Bad", "BAD", 37);
        StockOracleGuard.FeedConfig memory config = guard.feedConfig(PAIR_ID);
        config.stockToken = address(excessiveDecimals);
        config.stockDecimals = 37;

        vm.expectRevert(StockOracleGuard.InvalidConfiguration.selector);
        guard.configurePair(PAIR_ID, config);
    }

    function testFeedDecimalsAbove36AreRejectedAtConfiguration() external {
        MockAggregator excessiveDecimals = new MockAggregator(37, "Bad", 1);
        StockOracleGuard.FeedConfig memory config = guard.feedConfig(PAIR_ID);
        config.stockFeed = excessiveDecimals;
        config.stockFeedDecimals = 37;

        vm.expectRevert(StockOracleGuard.InvalidConfiguration.selector);
        guard.configurePair(PAIR_ID, config);
    }

    function testStockTokenMustImplementOraclePauseInterface() external {
        MetadataOnlyToken incompatible = new MetadataOnlyToken();
        StockOracleGuard.FeedConfig memory config = guard.feedConfig(PAIR_ID);
        config.stockToken = address(incompatible);

        vm.expectRevert(StockOracleGuard.InvalidConfiguration.selector);
        guard.configurePair(PAIR_ID, config);
    }

    function testSequencerRequiresMinimumGracePeriod() external {
        MockAggregator sequencer = new MockAggregator(0, "Sequencer", 0);
        StockOracleGuard.FeedConfig memory config = guard.feedConfig(PAIR_ID);
        config.sequencerFeed = sequencer;
        config.sequencerGracePeriod = 1 hours - 1;

        vm.expectRevert(StockOracleGuard.InvalidConfiguration.selector);
        guard.configurePair(PAIR_ID, config);
    }

    function testPositiveAnswerThatNormalizesToZeroIsRejected() external {
        MockAggregator tiny = new MockAggregator(36, "Tiny", 1);
        StockOracleGuard.FeedConfig memory config = guard.feedConfig(PAIR_ID);
        config.stockFeed = tiny;
        config.stockFeedDecimals = 36;
        guard.configurePair(PAIR_ID, config);

        vm.expectRevert(
            abi.encodeWithSelector(StockOracleGuard.InvalidOracleAnswer.selector, address(tiny))
        );
        guard.pricesUSD18(PAIR_ID);
    }

    function testOutOfBoundsChainlinkReferenceSqrtPriceIsRejected() external {
        MockAggregator extreme = new MockAggregator(8, "Extreme", 4e58);
        StockOracleGuard.FeedConfig memory config = guard.feedConfig(PAIR_ID);
        config.stockFeed = extreme;
        guard.configurePair(PAIR_ID, config);

        vm.expectRevert(StockOracleGuard.InvalidReferencePrice.selector);
        guard.validatePoolPrice(PAIR_ID, _poolKey());
    }

    function _configure(address sequencer) internal {
        guard.configurePair(
            PAIR_ID,
            StockOracleGuard.FeedConfig({
                stockToken: address(stock),
                usdg: address(usdg),
                stockFeed: stockFeed,
                usdgFeed: MockAggregator(address(0)),
                sequencerFeed: MockAggregator(sequencer),
                poolId: PoolId.unwrap(_poolKey().toId()),
                maxStaleness: 1 hours,
                sequencerGracePeriod: 1 hours,
                maxPriceDeviationBps: 500,
                stockDecimals: 18,
                usdgDecimals: 6,
                stockFeedDecimals: 8,
                usdgFeedDecimals: 0,
                usdgFixedOne: true,
                enabled: true
            })
        );
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        address token0 = address(stock) < address(usdg) ? address(stock) : address(usdg);
        address token1 = address(stock) < address(usdg) ? address(usdg) : address(stock);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _referenceSqrtPriceX96(uint256 oracleStockInUsdg) internal view returns (uint160) {
        uint256 rawRatioWad;
        if (Currency.unwrap(_poolKey().currency0) == address(stock)) {
            rawRatioWad = Math.mulDiv(oracleStockInUsdg, 1e6, 1e18);
        } else {
            uint256 inversePriceWad = Math.mulDiv(1e18, 1e18, oracleStockInUsdg);
            rawRatioWad = Math.mulDiv(inversePriceWad, 1e18, 1e6);
        }
        uint256 ratioX128 = Math.mulDiv(rawRatioWad, uint256(1) << 128, 1e18);
        return uint160(Math.sqrt(ratioX128) << 32);
    }
}
