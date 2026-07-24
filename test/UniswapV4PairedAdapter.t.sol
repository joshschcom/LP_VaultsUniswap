// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IAllowanceTransfer } from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";

import { UniswapV4PairedAdapter } from "../src/UniswapV4PairedAdapter.sol";
import { IUniswapV4PairedAdapter } from "../src/interfaces/IUniswapV4PairedAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import {
    MockPermit2,
    MockPoolManagerState,
    MockPositionManager,
    MockUniversalRouter
} from "./mocks/MockUniswapComponents.sol";

contract UniswapV4PairedAdapterTest is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant PAIR_ID = keccak256("STOCK/USDG");

    MockERC20 internal stock;
    MockERC20 internal usdg;
    MockPermit2 internal permit2;
    MockPoolManagerState internal poolManager;
    MockPositionManager internal positionManager;
    MockUniversalRouter internal router;
    UniswapV4PairedAdapter internal adapter;
    PoolKey internal key;

    function setUp() external {
        stock = new MockERC20("Stock", "STOCK", 18);
        usdg = new MockERC20("Dollar", "USDG", 18);
        permit2 = new MockPermit2();
        poolManager = new MockPoolManagerState();
        positionManager = new MockPositionManager(permit2);
        router = new MockUniversalRouter(permit2);

        address token0 = address(stock) < address(usdg) ? address(stock) : address(usdg);
        address token1 = address(stock) < address(usdg) ? address(usdg) : address(stock);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        UniswapV4PairedAdapter implementation = new UniswapV4PairedAdapter();
        adapter = UniswapV4PairedAdapter(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        UniswapV4PairedAdapter.initialize,
                        (
                            address(this),
                            IPoolManager(address(poolManager)),
                            IPositionManager(address(positionManager)),
                            IUniversalRouter(address(router)),
                            IAllowanceTransfer(address(permit2))
                        )
                    )
                )
            )
        );
        adapter.registerPair(
            PAIR_ID,
            IUniswapV4PairedAdapter.RegisterPairParams({
                stockToken: address(stock),
                usdg: address(usdg),
                poolKey: key,
                expectedPoolId: PoolId.unwrap(key.toId()),
                removalToleranceBps: 400
            })
        );

        stock.mint(address(this), 1_000e18);
        usdg.mint(address(this), 1_000e18);
        stock.mint(address(router), 1_000e18);
        usdg.mint(address(router), 1_000e18);
        stock.approve(address(adapter), type(uint256).max);
        usdg.approve(address(adapter), type(uint256).max);
    }

    function testDiscoversMintedNftAfterAdvancedGlobalCounterAndReturnsActualLiquidity() external {
        positionManager.setLiquidityHaircuts(7, 0);
        (,, uint128 liquidityAdded) =
            adapter.addLiquidity(PAIR_ID, 100e18, 100e18, block.timestamp + 60);

        IUniswapV4PairedAdapter.PositionState memory position = adapter.positionState(PAIR_ID);
        assertEq(position.tokenId, 41);
        assertEq(positionManager.nextTokenId(), 42);
        assertEq(position.liquidity, liquidityAdded);
        _assertAllowancesZero();
    }

    function testExactPermit2AllowancesAreRevokedAfterSwap() external {
        (uint256 used, uint256 output) =
            adapter.swapExactInput(PAIR_ID, address(stock), 5e18, 4e18, block.timestamp + 60);

        assertEq(used, 5e18);
        assertEq(output, 4e18);
        assertEq(router.lastMinHopPriceX36(), 0.8e36);
        _assertAllowancesZero();
    }

    function testPermit2DeadlineCannotTruncateToUint48() external {
        vm.expectRevert(UniswapV4PairedAdapter.InvalidDeadline.selector);
        adapter.swapExactInput(PAIR_ID, address(stock), 5e18, 4e18, uint256(type(uint48).max) + 1);
    }

    function testRemovalMinimumsUseReferencePriceAndReturnObservedLiquidityDelta() external {
        (,, uint128 added) = adapter.addLiquidity(PAIR_ID, 100e18, 100e18, block.timestamp + 60);
        uint128 requested = added / 2;
        positionManager.setLiquidityHaircuts(0, 1);
        poolManager.setSlot0(TickMath.getSqrtPriceAtTick(-100_000), -100_000);

        (uint256 stockReceived, uint256 usdgReceived, uint128 removed) =
            adapter.decreaseLiquidity(PAIR_ID, requested, uint160(1 << 96), block.timestamp + 60);

        assertGt(stockReceived, 0);
        assertGt(usdgReceived, 0);
        assertEq(removed, requested - 1);
        assertGt(positionManager.lastAmount0Min(), 0);
        assertGt(positionManager.lastAmount1Min(), 0);
    }

    function testRemovalRejectsOutOfBoundsReferencePrice() external {
        (,, uint128 added) = adapter.addLiquidity(PAIR_ID, 100e18, 100e18, block.timestamp + 60);

        vm.expectRevert(UniswapV4PairedAdapter.InvalidReferencePrice.selector);
        adapter.decreaseLiquidity(
            PAIR_ID, added / 2, TickMath.MIN_SQRT_PRICE - 1, block.timestamp + 60
        );
    }

    function testRegistrationRejectsUnsafeRemovalTolerance() external {
        vm.expectRevert(UniswapV4PairedAdapter.InvalidConfiguration.selector);
        adapter.registerPair(
            keccak256("UNSAFE/STOCK"),
            IUniswapV4PairedAdapter.RegisterPairParams({
                stockToken: address(stock),
                usdg: address(usdg),
                poolKey: key,
                expectedPoolId: PoolId.unwrap(key.toId()),
                removalToleranceBps: 2_001
            })
        );
    }

    function testFeeOnTransferFromVaultToAdapterRevertsAtomically() external {
        stock.setTransferFee(100, address(this), address(adapter));
        uint256 stockBefore = stock.balanceOf(address(this));

        vm.expectRevert(UniswapV4PairedAdapter.BalanceDeltaMismatch.selector);
        adapter.addLiquidity(PAIR_ID, 100e18, 100e18, block.timestamp + 60);

        assertEq(stock.balanceOf(address(this)), stockBefore);
        assertEq(adapter.positionState(PAIR_ID).tokenId, 0);
    }

    function testFeeOnTransferFromAdapterToVaultRevertsWithoutLiquidityDrift() external {
        (,, uint128 added) = adapter.addLiquidity(PAIR_ID, 100e18, 100e18, block.timestamp + 60);
        stock.setTransferFee(100, address(adapter), address(this));

        vm.expectRevert(UniswapV4PairedAdapter.BalanceDeltaMismatch.selector);
        adapter.decreaseLiquidity(PAIR_ID, added / 2, uint160(1 << 96), block.timestamp + 60);

        assertEq(adapter.positionState(PAIR_ID).liquidity, added);
    }

    function _assertAllowancesZero() internal view {
        assertEq(stock.allowance(address(adapter), address(permit2)), 0);
        assertEq(usdg.allowance(address(adapter), address(permit2)), 0);
        _assertPermitAllowance(address(stock), address(positionManager));
        _assertPermitAllowance(address(usdg), address(positionManager));
        _assertPermitAllowance(address(stock), address(router));
        _assertPermitAllowance(address(usdg), address(router));
    }

    function _assertPermitAllowance(address token, address spender) internal view {
        (uint160 amount,,) = permit2.allowance(address(adapter), token, spender);
        assertEq(amount, 0);
    }
}
