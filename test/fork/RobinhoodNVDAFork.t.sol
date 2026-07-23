// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IStateView } from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import { IAllowanceTransfer } from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";

import { RobinhoodBoostedVault } from "../../src/RobinhoodBoostedVault.sol";
import { UniswapV4PairedAdapter } from "../../src/UniswapV4PairedAdapter.sol";
import { StockOracleGuard } from "../../src/StockOracleGuard.sol";
import { StrategyLossReserve } from "../../src/StrategyLossReserve.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IStockToken } from "../../src/interfaces/IStockToken.sol";
import { IUniswapV4PairedAdapter } from "../../src/interfaces/IUniswapV4PairedAdapter.sol";

contract RobinhoodNVDAForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // First Robinhood block after the verified NVDA feed round at timestamp 1784790068.
    uint256 internal constant PINNED_BLOCK = 17_091_638;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    bytes32 internal constant PAIR_ID = keccak256("NVDA/USDG");
    bytes32 internal constant NVDA_POOL_ID =
        0x3bb34a44f1b2b5f32c034c38a53065a521a47b199700fa9bd19d60985ff24bf1;

    struct System {
        RobinhoodBoostedVault vault;
        StockOracleGuard oracle;
        StrategyLossReserve reserve;
        UniswapV4PairedAdapter adapter;
    }

    bool internal forkEnabled;

    function setUp() external {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl, PINNED_BLOCK);
        forkEnabled = true;
    }

    function testCanonicalNVDADeploymentAndPoolState() external view {
        if (!forkEnabled) return;
        assertEq(block.chainid, 4663);
        assertGt(POOL_MANAGER.code.length, 0);
        assertGt(POSITION_MANAGER.code.length, 0);
        assertGt(STATE_VIEW.code.length, 0);
        assertGt(UNIVERSAL_ROUTER.code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        assertGt(USDG.code.length, 0);
        assertGt(NVDA.code.length, 0);
        assertGt(NVDA_USD_FEED.code.length, 0);

        PoolId id = _key().toId();
        assertEq(PoolId.unwrap(id), NVDA_POOL_ID);
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(POOL_MANAGER).getSlot0(id);
        uint128 liquidity = IPoolManager(POOL_MANAGER).getLiquidity(id);
        assertGt(sqrtPriceX96, 0);
        assertGt(liquidity, 0);
        assertEq(lpFee, 3000);

        (uint160 viewPrice, int24 viewTick, uint24 viewProtocolFee, uint24 viewLpFee) =
            IStateView(STATE_VIEW).getSlot0(id);
        assertEq(viewPrice, sqrtPriceX96);
        assertEq(viewTick, tick);
        assertEq(viewProtocolFee, protocolFee);
        assertEq(viewLpFee, lpFee);
        assertEq(IStateView(STATE_VIEW).getLiquidity(id), liquidity);
        assertEq(address(IStateView(STATE_VIEW).poolManager()), POOL_MANAGER);
    }

    function testCanonicalTokenAndFeedMetadata() external view {
        if (!forkEnabled) return;
        assertEq(IERC20Metadata(NVDA).name(), unicode"NVIDIA • Robinhood Token");
        assertEq(IERC20Metadata(NVDA).symbol(), "NVDA");
        assertEq(IERC20Metadata(NVDA).decimals(), 18);
        assertFalse(IStockToken(NVDA).oraclePaused());
        assertEq(IStockToken(NVDA).uiMultiplier(), 1e18);
        assertEq(IStockToken(NVDA).newUIMultiplier(), 1e18);
        assertEq(IStockToken(NVDA).effectiveAt(), 0);
        assertEq(IERC20Metadata(USDG).name(), "Global Dollar");
        assertEq(IERC20Metadata(USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(USDG).decimals(), 6);

        IAggregatorV3 feed = IAggregatorV3(NVDA_USD_FEED);
        assertEq(feed.description(), "RHNVDA / USD");
        assertEq(feed.decimals(), 8);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(answer, 21_114_499_999);
        assertGt(updatedAt, 0);
        assertGe(answeredInRound, roundId);
    }

    function testLiveOracleGuardAcceptsCanonicalPool() external {
        if (!forkEnabled) return;
        StockOracleGuard implementation = new StockOracleGuard();
        StockOracleGuard guard = StockOracleGuard(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        StockOracleGuard.initialize, (address(this), IPoolManager(POOL_MANAGER))
                    )
                )
            )
        );
        guard.configurePair(
            PAIR_ID,
            StockOracleGuard.FeedConfig({
                stockToken: NVDA,
                usdg: USDG,
                stockFeed: IAggregatorV3(NVDA_USD_FEED),
                usdgFeed: IAggregatorV3(address(0)),
                sequencerFeed: IAggregatorV3(address(0)),
                poolId: NVDA_POOL_ID,
                maxStaleness: 1 hours,
                sequencerGracePeriod: 0,
                maxPriceDeviationBps: 500,
                stockDecimals: 18,
                usdgDecimals: 6,
                stockFeedDecimals: 8,
                usdgFeedDecimals: 0,
                usdgFixedOne: true,
                enabled: true
            })
        );

        (uint256 stockPrice, uint256 usdgPrice) = guard.pricesUSD18(PAIR_ID);
        assertEq(stockPrice, 211_144_999_990_000_000_000);
        assertEq(usdgPrice, 1e18);
        guard.validatePoolPrice(PAIR_ID, _key());
    }

    function testAdapterRegistersCanonicalPool() external {
        if (!forkEnabled) return;
        UniswapV4PairedAdapter adapter = _deployAdapter();
        _register(adapter);
        assertEq(Currency.unwrap(adapter.poolKey(PAIR_ID).currency0), USDG);
    }

    function testPermit2AndFullPositionLifecycle() external {
        if (!forkEnabled) return;
        UniswapV4PairedAdapter adapter = _deployFundedAdapter();

        (uint256 stockUsed, uint256 usdgUsed, uint128 liquidityAdded) =
            adapter.addLiquidity(PAIR_ID, 1e18, 250e6, block.timestamp + 300);
        assertGt(stockUsed, 0);
        assertGt(usdgUsed, 0);
        assertGt(liquidityAdded, 0);

        IUniswapV4PairedAdapter.PositionState memory position = adapter.positionState(PAIR_ID);
        assertGt(position.tokenId, 0);
        assertEq(position.liquidity, liquidityAdded);
        assertGt(position.stockAmount, 0);
        assertGt(position.usdgAmount, 0);
        assertEq(position.tokenId, IPositionManager(POSITION_MANAGER).nextTokenId() - 1);
        _assertPermit2Revoked(address(adapter));

        adapter.collectFees(PAIR_ID, block.timestamp + 300);
        uint160 referenceSqrtPriceX96 = _referenceSqrtPriceX96();
        uint128 firstSlice = position.liquidity / 2;
        (uint256 firstStock, uint256 firstUsdg,) = adapter.decreaseLiquidity(
            PAIR_ID, firstSlice, referenceSqrtPriceX96, block.timestamp + 300
        );
        assertGt(firstStock, 0);
        assertGt(firstUsdg, 0);

        position = adapter.positionState(PAIR_ID);
        (uint256 finalStock, uint256 finalUsdg,) = adapter.decreaseLiquidity(
            PAIR_ID, position.liquidity, referenceSqrtPriceX96, block.timestamp + 300
        );
        assertGt(finalStock, 0);
        assertGt(finalUsdg, 0);
        adapter.burnEmptyPosition(PAIR_ID, block.timestamp + 300);
        assertEq(adapter.positionState(PAIR_ID).tokenId, 0);
    }

    function testGuardedSwapBothDirections() external {
        if (!forkEnabled) return;
        UniswapV4PairedAdapter adapter = _deployFundedAdapter();

        (uint256 usdgUsed, uint256 stockOut) =
            adapter.swapExactInput(PAIR_ID, USDG, 10e6, 0.04e18, block.timestamp + 300);
        assertEq(usdgUsed, 10e6);
        assertGe(stockOut, 0.04e18);
        _assertPermit2Revoked(address(adapter));

        (uint256 stockUsed, uint256 usdgOut) =
            adapter.swapExactInput(PAIR_ID, NVDA, 0.01e18, 2e6, block.timestamp + 300);
        assertEq(stockUsed, 0.01e18);
        assertGe(usdgOut, 2e6);
        _assertPermit2Revoked(address(adapter));
    }

    function testFullVaultRebalanceCheckpointAndIndependentWithdrawals() external {
        if (!forkEnabled) return;
        address stockSide = address(0xBEEF);
        address usdgSide = address(0xCAFE);
        address receiver = address(0xD00D);
        System memory system = _deploySystem(stockSide, usdgSide);

        deal(NVDA, stockSide, 1e18);
        deal(USDG, usdgSide, 250e6);
        vm.prank(stockSide);
        IERC20(NVDA).approve(address(system.vault), type(uint256).max);
        vm.prank(usdgSide);
        IERC20(USDG).approve(address(system.vault), type(uint256).max);

        vm.prank(stockSide);
        system.vault.depositForPair(PAIR_ID, NVDA, 1e18);
        vm.prank(usdgSide);
        system.vault.depositForPair(PAIR_ID, USDG, 250e6);
        vm.prank(address(0xF00D));
        system.vault.rebalance(PAIR_ID, block.timestamp + 60);
        assertGt(system.adapter.positionState(PAIR_ID).liquidity, 0);

        vm.prank(address(0xF00D));
        system.vault.checkpoint(PAIR_ID, block.timestamp + 60);

        vm.prank(stockSide);
        (uint256 stockReturned,) =
            system.vault.withdrawForSide(PAIR_ID, NVDA, 0.1e18, receiver, block.timestamp + 60);
        assertGt(stockReturned, 0);
        assertEq(IERC20(NVDA).balanceOf(receiver), stockReturned);

        vm.prank(usdgSide);
        (uint256 usdgReturned,) =
            system.vault.withdrawForSide(PAIR_ID, USDG, 20e6, receiver, block.timestamp + 60);
        assertGt(usdgReturned, 0);
        assertEq(IERC20(USDG).balanceOf(receiver), usdgReturned);
    }

    function _deployFundedAdapter() internal returns (UniswapV4PairedAdapter adapter) {
        adapter = _deployAdapter();
        _register(adapter);
        deal(NVDA, address(this), 5e18);
        deal(USDG, address(this), 1_000e6);
        IERC20(NVDA).approve(address(adapter), type(uint256).max);
        IERC20(USDG).approve(address(adapter), type(uint256).max);
    }

    function _deployAdapter() internal returns (UniswapV4PairedAdapter adapter) {
        UniswapV4PairedAdapter implementation = new UniswapV4PairedAdapter();
        adapter = UniswapV4PairedAdapter(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        UniswapV4PairedAdapter.initialize,
                        (
                            address(this),
                            IPoolManager(POOL_MANAGER),
                            IPositionManager(POSITION_MANAGER),
                            IUniversalRouter(UNIVERSAL_ROUTER),
                            IAllowanceTransfer(PERMIT2)
                        )
                    )
                )
            )
        );
    }

    function _deploySystem(address stockSide, address usdgSide)
        internal
        returns (System memory system)
    {
        RobinhoodBoostedVault vaultImplementation = new RobinhoodBoostedVault();
        StockOracleGuard oracleImplementation = new StockOracleGuard();
        StrategyLossReserve reserveImplementation = new StrategyLossReserve();
        UniswapV4PairedAdapter adapterImplementation = new UniswapV4PairedAdapter();

        system.vault = RobinhoodBoostedVault(
            address(new ERC1967Proxy(address(vaultImplementation), bytes("")))
        );
        system.oracle =
            StockOracleGuard(address(new ERC1967Proxy(address(oracleImplementation), bytes(""))));
        system.reserve = StrategyLossReserve(
            address(new ERC1967Proxy(address(reserveImplementation), bytes("")))
        );
        system.adapter = UniswapV4PairedAdapter(
            address(new ERC1967Proxy(address(adapterImplementation), bytes("")))
        );

        system.oracle.initialize(address(this), IPoolManager(POOL_MANAGER));
        system.reserve.initialize(address(this), address(system.vault));
        system.adapter
            .initialize(
                address(system.vault),
                IPoolManager(POOL_MANAGER),
                IPositionManager(POSITION_MANAGER),
                IUniversalRouter(UNIVERSAL_ROUTER),
                IAllowanceTransfer(PERMIT2)
            );
        system.vault
            .initialize(
                address(this),
                address(0xF00D),
                address(0xABCD),
                system.oracle,
                system.reserve,
                system.adapter
            );

        system.oracle.configurePair(PAIR_ID, _feedConfig());
        system.reserve
            .configurePair(
                PAIR_ID,
                StrategyLossReserve.ReserveConfig({
                    stockToken: NVDA,
                    usdg: USDG,
                    maxUsePerTxUSDG: uint128(100e18),
                    dailyCapUSDG: uint128(500e18),
                    maxCoverageBps: 5_000,
                    paused: false,
                    exists: true
                })
            );
        system.vault.setAggregateUsdgDepositCap(USDG, 1_000_000e6);
        system.vault
            .registerPair(
                PAIR_ID,
                RobinhoodBoostedVault.PairConfig({
                    stockToken: NVDA,
                    usdg: USDG,
                    stockAccount: stockSide,
                    usdgAccount: usdgSide,
                    maxPairValueUSDG: uint128(1_000e18),
                    maxSettlementSwapUSDG: uint128(100e18),
                    maxCheckpointAge: 1 hours,
                    deprecatedMinDeadlineDelay: 0,
                    maxDeadlineDelay: 300,
                    reserveFeeBps: 2_000,
                    maxSwapSlippageBps: 100,
                    withdrawOverUnwindBps: 200,
                    stockDecimals: 18,
                    usdgDecimals: 6,
                    allocationPaused: false,
                    swapsPaused: false,
                    emergencyMode: false,
                    exists: true
                }),
                IUniswapV4PairedAdapter.RegisterPairParams({
                    stockToken: NVDA,
                    usdg: USDG,
                    poolKey: _key(),
                    expectedPoolId: NVDA_POOL_ID,
                    removalToleranceBps: 600
                })
            );
    }

    function _feedConfig() internal pure returns (StockOracleGuard.FeedConfig memory) {
        return StockOracleGuard.FeedConfig({
            stockToken: NVDA,
            usdg: USDG,
            stockFeed: IAggregatorV3(NVDA_USD_FEED),
            usdgFeed: IAggregatorV3(address(0)),
            sequencerFeed: IAggregatorV3(address(0)),
            poolId: NVDA_POOL_ID,
            maxStaleness: 1 hours,
            sequencerGracePeriod: 0,
            maxPriceDeviationBps: 500,
            stockDecimals: 18,
            usdgDecimals: 6,
            stockFeedDecimals: 8,
            usdgFeedDecimals: 0,
            usdgFixedOne: true,
            enabled: true
        });
    }

    function _register(UniswapV4PairedAdapter adapter) internal {
        adapter.registerPair(
            PAIR_ID,
            IUniswapV4PairedAdapter.RegisterPairParams({
                stockToken: NVDA,
                usdg: USDG,
                poolKey: _key(),
                expectedPoolId: NVDA_POOL_ID,
                removalToleranceBps: 600
            })
        );
    }

    function _referenceSqrtPriceX96() internal returns (uint160 referenceSqrtPriceX96) {
        StockOracleGuard implementation = new StockOracleGuard();
        StockOracleGuard guard = StockOracleGuard(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        StockOracleGuard.initialize, (address(this), IPoolManager(POOL_MANAGER))
                    )
                )
            )
        );
        guard.configurePair(PAIR_ID, _feedConfig());
        (,, referenceSqrtPriceX96) = guard.validatePoolPrice(PAIR_ID, _key());
    }

    function _assertPermit2Revoked(address adapter) internal view {
        assertEq(IERC20(NVDA).allowance(adapter, PERMIT2), 0);
        assertEq(IERC20(USDG).allowance(adapter, PERMIT2), 0);
        (uint160 nvdaPositionAllowance,,) =
            IAllowanceTransfer(PERMIT2).allowance(adapter, NVDA, POSITION_MANAGER);
        (uint160 usdgPositionAllowance,,) =
            IAllowanceTransfer(PERMIT2).allowance(adapter, USDG, POSITION_MANAGER);
        (uint160 nvdaRouterAllowance,,) =
            IAllowanceTransfer(PERMIT2).allowance(adapter, NVDA, UNIVERSAL_ROUTER);
        (uint160 usdgRouterAllowance,,) =
            IAllowanceTransfer(PERMIT2).allowance(adapter, USDG, UNIVERSAL_ROUTER);
        assertEq(nvdaPositionAllowance, 0);
        assertEq(usdgPositionAllowance, 0);
        assertEq(nvdaRouterAllowance, 0);
        assertEq(usdgRouterAllowance, 0);
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(USDG),
            currency1: Currency.wrap(NVDA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
