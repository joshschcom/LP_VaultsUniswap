// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import { RobinhoodBoostedVault } from "../src/RobinhoodBoostedVault.sol";
import { IUniswapV4PairedAdapter } from "../src/interfaces/IUniswapV4PairedAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockOracleGuard } from "./mocks/MockOracleGuard.sol";
import { MockLossReserve } from "./mocks/MockLossReserve.sol";
import { MockLiquidityAdapter } from "./mocks/MockLiquidityAdapter.sol";

contract RobinhoodBoostedVaultTest is Test {
    bytes32 internal constant PAIR_ID = keccak256("NVDA/USDG");
    address internal stockAccount = makeAddr("stockAccount");
    address internal usdgAccount = makeAddr("usdgAccount");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal receiver = makeAddr("receiver");

    MockERC20 internal stock;
    MockERC20 internal usdg;
    MockOracleGuard internal oracle;
    MockLossReserve internal reserve;
    MockLiquidityAdapter internal adapter;
    RobinhoodBoostedVault internal vault;

    function setUp() external {
        stock = new MockERC20("NVIDIA", "NVDA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        oracle = new MockOracleGuard();
        reserve = new MockLossReserve();
        adapter = new MockLiquidityAdapter();

        RobinhoodBoostedVault implementation = new RobinhoodBoostedVault();
        bytes memory data = abi.encodeCall(
            RobinhoodBoostedVault.initialize,
            (address(this), keeper, guardian, oracle, reserve, adapter)
        );
        vault = RobinhoodBoostedVault(address(new ERC1967Proxy(address(implementation), data)));
        adapter.setVault(address(vault));

        PoolKey memory key = _poolKey();
        RobinhoodBoostedVault.PairConfig memory config = RobinhoodBoostedVault.PairConfig({
            stockToken: address(stock),
            usdg: address(usdg),
            stockAccount: stockAccount,
            usdgAccount: usdgAccount,
            maxPairValueUSDG: 0,
            maxSettlementSwapUSDG: uint128(25_000e18),
            maxCheckpointAge: 1 days,
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
        });
        IUniswapV4PairedAdapter.RegisterPairParams memory adapterConfig =
            IUniswapV4PairedAdapter.RegisterPairParams({
                stockToken: address(stock),
                usdg: address(usdg),
                poolKey: key,
                expectedPoolId: keccak256("pool"),
                removalToleranceBps: 400
            });
        vault.registerPair(PAIR_ID, config, adapterConfig);

        stock.mint(stockAccount, 100e18);
        usdg.mint(usdgAccount, 100_000e6);
        vm.prank(stockAccount);
        stock.approve(address(vault), type(uint256).max);
        vm.prank(usdgAccount);
        usdg.approve(address(vault), type(uint256).max);
    }

    function testDepositsRemainSeparatelyAttributed() external {
        _depositPair(10e18, 1_000e6);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(usdg)), 1_000e6);
        assertEq(vault.liquidAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(vault.liquidAssets(PAIR_ID, address(usdg)), 1_000e6);
    }

    function testSideAccountLookupSupportsBoostedPTokenValidation() external view {
        assertEq(vault.sideAccount(PAIR_ID, address(stock)), stockAccount);
        assertEq(vault.sideAccount(PAIR_ID, address(usdg)), usdgAccount);
    }

    function testRebalanceDeploysOnlyMatchedOracleValue() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        assertEq(vault.liquidAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(vault.liquidAssets(PAIR_ID, address(usdg)), 0);
        IUniswapV4PairedAdapter.PositionState memory position = adapter.positionState(PAIR_ID);
        assertEq(position.stockAmount, 10e18);
        assertEq(position.usdgAmount, 1_000e6);
    }

    function testCheckpointSharesLossAtEqualPercentage() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        adapter.setPosition(PAIR_ID, 8e18, 900e6);

        vm.prank(keeper);
        int256 pnl = vault.checkpoint(PAIR_ID, block.timestamp + 60);

        assertEq(pnl, -300e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 8.5e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(usdg)), 850e6);
    }

    function testFeesAreSplitInKindBeforeClaimsIncrease() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        adapter.setFees(PAIR_ID, 1e18, 100e6);

        vm.prank(keeper);
        vault.collectFees(PAIR_ID, block.timestamp + 60);

        assertEq(reserve.available(PAIR_ID, address(stock)), 0.2e18);
        assertEq(reserve.available(PAIR_ID, address(usdg)), 20e6);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 10.8e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(usdg)), 1_080e6);
    }

    function testIdleWithdrawalDoesNotNeedOracle() external {
        _depositPair(10e18, 1_000e6);
        oracle.setShouldRevert(true);

        vm.prank(stockAccount);
        (uint256 returned, uint256 loss) =
            vault.withdrawForSide(PAIR_ID, address(stock), 3e18, receiver, 0);

        assertEq(returned, 3e18);
        assertEq(loss, 0);
        assertEq(stock.balanceOf(receiver), 3e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 7e18);
    }

    function testWithdrawalUnwindsOnlyNeededSlice() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        vm.prank(stockAccount);
        (uint256 returned, uint256 loss) =
            vault.withdrawForSide(PAIR_ID, address(stock), 5e18, receiver, block.timestamp + 60);

        assertEq(returned, 5e18);
        assertEq(loss, 0);
        assertEq(stock.balanceOf(receiver), 5e18);
        assertGt(vault.liquidAssets(PAIR_ID, address(stock)), 0);
    }

    function testWithdrawalReportsLossAppliedToRemainingClaim() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        adapter.setPosition(PAIR_ID, 8e18, 900e6);

        vm.prank(stockAccount);
        (uint256 returned, uint256 loss) =
            vault.withdrawForSide(PAIR_ID, address(stock), 5e18, receiver, block.timestamp + 60);

        assertEq(returned, 5e18);
        assertEq(loss, 1.5e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 3.5e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(usdg)), 850e6);
    }

    function testStaleCheckpointIsRefreshedInsideLPWithdrawal() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 deadline = vm.getBlockTimestamp() + 60;

        vm.prank(stockAccount);
        (uint256 returned, uint256 loss) =
            vault.withdrawForSide(PAIR_ID, address(stock), 1e18, receiver, deadline);

        assertEq(returned, 1e18);
        assertEq(loss, 0);
        assertEq(stock.balanceOf(receiver), 1e18);
        assertEq(vault.ledger(PAIR_ID).lastCheckpoint, block.timestamp);
    }

    function testManipulatedLPBackedWithdrawalFailsClosed() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        IUniswapV4PairedAdapter.PositionState memory beforePosition = adapter.positionState(PAIR_ID);
        oracle.setShouldRevert(true);

        vm.prank(stockAccount);
        vm.expectRevert(bytes("ORACLE"));
        vault.withdrawForSide(PAIR_ID, address(stock), 1e18, receiver, block.timestamp + 60);

        assertEq(adapter.positionState(PAIR_ID).liquidity, beforePosition.liquidity);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 10e18);
    }

    function testManipulatedGuardianExitFailsClosedWithoutEnteringEmergencyMode() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        uint128 liquidity = adapter.positionState(PAIR_ID).liquidity;
        oracle.setShouldRevert(true);

        vm.prank(guardian);
        vm.expectRevert(bytes("ORACLE"));
        vault.emergencyDecrease(PAIR_ID, liquidity / 2, block.timestamp + 60);

        RobinhoodBoostedVault.PairConfig memory config = vault.pairConfig(PAIR_ID);
        assertFalse(config.emergencyMode);
        assertEq(adapter.positionState(PAIR_ID).liquidity, liquidity);
    }

    function testCurrentTimestampDeadlineIsAcceptedForLPWithdrawal() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        vm.prank(stockAccount);
        (uint256 returned,) =
            vault.withdrawForSide(PAIR_ID, address(stock), 1e18, receiver, block.timestamp);

        assertEq(returned, 1e18);
    }

    function testDeprecatedMinimumDeadlineSlotMustRemainZero() external {
        RobinhoodBoostedVault.PairConfig memory config = vault.pairConfig(PAIR_ID);
        config.deprecatedMinDeadlineDelay = 1;

        vm.expectRevert(RobinhoodBoostedVault.InvalidConfiguration.selector);
        vault.updatePairRisk(PAIR_ID, config);
    }

    function testFeeOnTransferToWithdrawalReceiverRevertsWithoutLedgerDrift() external {
        vm.prank(stockAccount);
        vault.depositForPair(PAIR_ID, address(stock), 10e18);
        stock.setTransferFee(100, address(vault), receiver);

        vm.prank(stockAccount);
        vm.expectRevert(RobinhoodBoostedVault.BalanceDeltaMismatch.selector);
        vault.withdrawForSide(PAIR_ID, address(stock), 1e18, receiver, 0);

        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(vault.liquidAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(stock.balanceOf(receiver), 0);
    }

    function testFeeOnTransferFromVaultToReserveRevertsWithoutLedgerDrift() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        adapter.setFees(PAIR_ID, 1e18, 0);
        stock.setTransferFee(100, address(vault), address(reserve));

        vm.prank(keeper);
        vm.expectRevert(RobinhoodBoostedVault.BalanceDeltaMismatch.selector);
        vault.collectFees(PAIR_ID, block.timestamp + 60);

        assertEq(reserve.available(PAIR_ID, address(stock)), 0);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 10e18);
    }

    function testReserveReportCannotOvercreditObservedVaultBalance() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        stock.mint(address(this), 1e18);
        stock.approve(address(reserve), 1e18);
        reserve.deposit(PAIR_ID, address(stock), 1e18);
        reserve.setCoverReportBonus(1);
        adapter.setPosition(PAIR_ID, 0, 1_000e6);

        vm.prank(stockAccount);
        vm.expectRevert(RobinhoodBoostedVault.BalanceDeltaMismatch.selector);
        vault.withdrawForSide(PAIR_ID, address(stock), 1e18, receiver, block.timestamp + 60);

        assertEq(reserve.available(PAIR_ID, address(stock)), 1e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 10e18);
    }

    function testCheckpointUsesCheckedSignedPnlConversion() external {
        uint256 sideValue = uint256(type(int256).max) / 2 + 1e18;
        uint256 stockAmount = sideValue / 100 + 1;
        uint256 usdgAmount = sideValue / 1e12 + 1;
        stock.mint(stockAccount, stockAmount);
        usdg.mint(usdgAccount, usdgAmount);
        _depositPair(stockAmount, usdgAmount);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        adapter.setPosition(PAIR_ID, 0, 0);

        vm.prank(keeper);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintToInt.selector);
        vault.checkpoint(PAIR_ID, block.timestamp + 60);
    }

    function testGuardianCanPauseButCannotUnpause() external {
        vm.prank(guardian);
        vault.setPairPause(PAIR_ID, true, true, true);
        RobinhoodBoostedVault.PairConfig memory config = vault.pairConfig(PAIR_ID);
        assertTrue(config.emergencyMode);

        vm.prank(guardian);
        vm.expectRevert(RobinhoodBoostedVault.GuardianCannotUnpause.selector);
        vault.setPairPause(PAIR_ID, false, false, false);
    }

    function testAggregateUsdgCapFailsClosedAcrossDeposits() external {
        vault.setAggregateUsdgDepositCap(address(usdg), 500e6);
        vm.prank(usdgAccount);
        vm.expectRevert(RobinhoodBoostedVault.PairCapExceeded.selector);
        vault.depositForPair(PAIR_ID, address(usdg), 501e6);
        assertEq(vault.aggregateUsdgPrincipal(address(usdg)), 0);
    }

    function testZeroAggregateCapDisablesLimitAfterPrincipalExists() external {
        vault.setAggregateUsdgDepositCap(address(usdg), 100e6);
        vm.prank(usdgAccount);
        vault.depositForPair(PAIR_ID, address(usdg), 100e6);

        vault.setAggregateUsdgDepositCap(address(usdg), 0);
        vm.prank(usdgAccount);
        vault.depositForPair(PAIR_ID, address(usdg), 99_900e6);

        assertEq(vault.aggregateUsdgPrincipal(address(usdg)), 100_000e6);
    }

    function testConfiguredPairValueCapStillFailsClosed() external {
        RobinhoodBoostedVault.PairConfig memory config = vault.pairConfig(PAIR_ID);
        config.maxPairValueUSDG = uint128(100e18);
        vault.updatePairRisk(PAIR_ID, config);

        vm.prank(stockAccount);
        vm.expectRevert(RobinhoodBoostedVault.PairCapExceeded.selector);
        vault.depositForPair(PAIR_ID, address(stock), 2e18);

        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 0);
    }

    function testFuzzRebalanceNeverConsumesUnmatchedStock(uint96 stockRaw, uint64 usdgRaw)
        external
    {
        uint256 stockAmount = bound(uint256(stockRaw), 1e16, 100e18);
        uint256 usdgAmount = bound(uint256(usdgRaw), 1e4, 100_000e6);
        _depositPair(stockAmount, usdgAmount);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        IUniswapV4PairedAdapter.PositionState memory position = adapter.positionState(PAIR_ID);
        assertLe(position.stockAmount, stockAmount);
        assertLe(position.usdgAmount, usdgAmount);
        assertApproxEqAbs(position.stockAmount / 1e12, position.usdgAmount / 100, 2);
    }

    function _depositPair(uint256 stockAmount, uint256 usdgAmount) internal {
        vm.prank(stockAccount);
        vault.depositForPair(PAIR_ID, address(stock), stockAmount);
        vm.prank(usdgAccount);
        vault.depositForPair(PAIR_ID, address(usdg), usdgAmount);
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        address token0 = address(stock) < address(usdg) ? address(stock) : address(usdg);
        address token1 = address(stock) < address(usdg) ? address(usdg) : address(stock);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
