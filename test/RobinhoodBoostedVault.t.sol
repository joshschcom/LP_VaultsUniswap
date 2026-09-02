// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import { RobinhoodBoostedVault } from "../src/RobinhoodBoostedVault.sol";
import { PairConfig } from "../src/libraries/VaultTypes.sol";
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
        PairConfig memory config = PairConfig({
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
        _assertVaultAllowancesZero();
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

    function testSkewedPoolCannotManufactureLossAtCheckpoint() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Pool composition says half the position evaporated; the oracle-priced composition
        // says the position is intact. Loss accounting must follow the oracle.
        adapter.setPosition(PAIR_ID, 5e18, 500e6);
        adapter.setReferencePosition(PAIR_ID, 10e18, 1_000e6);

        vm.prank(keeper);
        int256 pnl = vault.checkpoint(PAIR_ID, block.timestamp + 60);

        assertEq(pnl, 0, "pool skew must not manufacture a loss");
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(usdg)), 1_000e6);
        assertEq(vault.ledger(PAIR_ID).cumulativeLossUSDG, 0);

        // totalPairAssets stays the pool-priced market view, deliberately divergent.
        (uint256 stockAssets,) = vault.totalPairAssets(PAIR_ID);
        assertEq(stockAssets, 5e18);
    }

    function testSkewedPoolCannotMaskRealLossAtCheckpoint() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Inverse of the above: the pool is pushed to look healthy while the oracle-priced
        // composition carries a genuine $300 shortfall against the $2,000 benchmark.
        adapter.setPosition(PAIR_ID, 20e18, 2_000e6);
        adapter.setReferencePosition(PAIR_ID, 8e18, 900e6);

        vm.prank(keeper);
        int256 pnl = vault.checkpoint(PAIR_ID, block.timestamp + 60);

        assertEq(pnl, -300e18, "pool skew must not mask a real loss");
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
        _assertVaultAllowancesZero();
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

    function testIdleWithdrawalRecognizesSharedLossWhileLiquidityRemains() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Ten stock remain idle while the matched position moves from
        // 10 stock / 1,000 USDG to 7 stock / 1,400 USDG. At a $200 stock
        // price, gross assets are $4,800 against a $5,000 benchmark.
        oracle.setPrices(200e18, 1e18);
        adapter.setPosition(PAIR_ID, 7e18, 1_400e6);

        vm.prank(stockAccount);
        (uint256 returned, uint256 loss) =
            vault.withdrawForSide(PAIR_ID, address(stock), 10e18, receiver, block.timestamp + 60);

        assertEq(returned, 10e18);
        assertEq(loss, 0.8e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 9.2e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(usdg)), 960e6);
        assertEq(vault.ledger(PAIR_ID).cumulativeLossUSDG, 200e18);
    }

    function testIdleWithdrawalWithOpenLiquidityFailsClosedOnOracleError() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        oracle.setShouldRevert(true);

        vm.prank(stockAccount);
        vm.expectRevert(bytes("ORACLE"));
        vault.withdrawForSide(PAIR_ID, address(stock), 1e18, receiver, block.timestamp + 60);

        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 20e18);
        // Custody still holds ten idle stock, but none of it is reachable while the
        // oracle is down and LP liquidity remains open.
        assertEq(vault.liquidAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(vault.withdrawableAssets(PAIR_ID, address(stock)), 0);
        assertEq(stock.balanceOf(receiver), 0);
    }

    function testWithdrawableAssetsReportsIdleWhenNoLiquidityIsOpen() external {
        _depositPair(10e18, 1_000e6);
        oracle.setShouldRevert(true);

        // No position is open, so the oracle-free idle path stays available.
        assertEq(vault.withdrawableAssets(PAIR_ID, address(stock)), 10e18);
        assertEq(vault.withdrawableAssets(PAIR_ID, address(usdg)), 1_000e6);
    }

    function testWithdrawableAssetsTracksOracleHealthWhileLiquidityIsOpen() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        uint256 idle = vault.liquidAssets(PAIR_ID, address(stock));
        assertGt(idle, 0);
        assertEq(vault.withdrawableAssets(PAIR_ID, address(stock)), idle);

        oracle.setShouldRevert(true);
        assertEq(vault.withdrawableAssets(PAIR_ID, address(stock)), 0);

        oracle.setShouldRevert(false);
        assertEq(vault.withdrawableAssets(PAIR_ID, address(stock)), idle);
    }

    function testWithdrawableAssetsIsZeroInEmergencyModeWithOpenLiquidity() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        vm.prank(guardian);
        vault.setPairPause(PAIR_ID, true, true, true);

        // withdrawForSide reverts EmergencyMode on the guarded path, so no idle is reachable.
        assertEq(vault.withdrawableAssets(PAIR_ID, address(stock)), 0);
    }

    function testWithdrawableAssetsNeverExceedsRemainingPrincipal() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Shared loss scales principal below the idle balance still held in custody.
        oracle.setPrices(200e18, 1e18);
        adapter.setPosition(PAIR_ID, 7e18, 1_400e6);
        vm.prank(keeper);
        vault.checkpoint(PAIR_ID, block.timestamp + 60);

        uint256 principal = vault.accountedAssets(PAIR_ID, address(stock));
        uint256 withdrawable = vault.withdrawableAssets(PAIR_ID, address(stock));
        assertLe(withdrawable, principal);
        assertLe(withdrawable, vault.liquidAssets(PAIR_ID, address(stock)));
    }

    function testWithdrawableAssetsRejectsUnsupportedToken() external {
        _depositPair(10e18, 1_000e6);
        vm.expectRevert(RobinhoodBoostedVault.UnsupportedToken.selector);
        vault.withdrawableAssets(PAIR_ID, address(0xBEEF));
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

    function testSingleSidedPositionCanSettleUsingCounterPrincipal() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Model a full-range position that has migrated entirely into USDG while
        // preserving the pair's oracle value.
        usdg.mint(address(adapter), 1_000e6);
        adapter.setPosition(PAIR_ID, 0, 2_000e6);

        vm.prank(stockAccount);
        (uint256 returned, uint256 loss) =
            vault.withdrawForSide(PAIR_ID, address(stock), 10e18, receiver, block.timestamp + 60);

        assertGt(returned, 9.9e18);
        assertLt(returned, 10e18);
        assertGt(loss, 0);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 0);
        assertEq(stock.balanceOf(receiver), returned);
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

        PairConfig memory config = vault.pairConfig(PAIR_ID);
        assertFalse(config.emergencyMode);
        assertEq(adapter.positionState(PAIR_ID).liquidity, liquidity);
    }

    function testEmergencyDecreaseRecognizesLossBeforeIdleWithdrawal() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Model the position at 20 stock / 500 USDG and a $25 stock price:
        // $1,000 of gross assets against a $1,250 benchmark.
        stock.mint(address(adapter), 10e18);
        adapter.setPosition(PAIR_ID, 20e18, 500e6);
        oracle.setPrices(25e18, 1e18);
        uint128 liquidity = adapter.positionState(PAIR_ID).liquidity;

        vm.prank(guardian);
        vault.emergencyDecrease(PAIR_ID, liquidity, block.timestamp + 60);

        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 8e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(usdg)), 800e6);
        assertEq(vault.ledger(PAIR_ID).cumulativeLossUSDG, 250e18);

        vm.prank(stockAccount);
        vm.expectRevert(RobinhoodBoostedVault.InsufficientPrincipal.selector);
        vault.withdrawForSide(PAIR_ID, address(stock), 10e18, receiver, 0);

        // Once the LP is fully removed and its loss is allocated, the remaining
        // emergency idle claim stays withdrawable even if the oracle later fails.
        oracle.setShouldRevert(true);
        vm.prank(stockAccount);
        (uint256 returned, uint256 loss) =
            vault.withdrawForSide(PAIR_ID, address(stock), 8e18, receiver, 0);
        assertEq(returned, 8e18);
        assertEq(loss, 0);
        assertEq(stock.balanceOf(receiver), 8e18);
        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 0);
    }

    function testPartialEmergencyDecreaseBlocksIdleWithdrawalUntilFullyExited() external {
        _depositPair(10e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);
        uint128 liquidity = adapter.positionState(PAIR_ID).liquidity;

        vm.prank(guardian);
        vault.emergencyDecrease(PAIR_ID, liquidity / 2, block.timestamp + 60);

        assertGt(vault.liquidAssets(PAIR_ID, address(stock)), 1e18);
        assertGt(adapter.positionState(PAIR_ID).liquidity, 0);
        vm.prank(stockAccount);
        vm.expectRevert(RobinhoodBoostedVault.EmergencyMode.selector);
        vault.withdrawForSide(PAIR_ID, address(stock), 1e18, receiver, 0);
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
        PairConfig memory config = vault.pairConfig(PAIR_ID);
        config.deprecatedMinDeadlineDelay = 1;

        vm.expectRevert(RobinhoodBoostedVault.InvalidConfiguration.selector);
        vault.updatePairRisk(PAIR_ID, config);
    }

    function testSettlementSlippageCannotExceedFivePercent() external {
        PairConfig memory config = vault.pairConfig(PAIR_ID);
        config.maxSwapSlippageBps = 501;

        vm.expectRevert(RobinhoodBoostedVault.InvalidConfiguration.selector);
        vault.updatePairRisk(PAIR_ID, config);
    }

    function testRegistrationRequiresRemovalToleranceToCoverHalfTheRemovalDeviation() external {
        // A pool deviation d moves a full-range position's amounts by about d/2, so the
        // amount tolerance must cover half the removal bound plus the operational buffer.
        oracle.setMaxRemovalDeviationBps(600);
        PairConfig memory config = vault.pairConfig(PAIR_ID);

        IUniswapV4PairedAdapter.RegisterPairParams memory tooTight =
            IUniswapV4PairedAdapter.RegisterPairParams({
                stockToken: address(stock),
                usdg: address(usdg),
                poolKey: _poolKey(),
                expectedPoolId: keccak256("pool"),
                removalToleranceBps: 399
            });
        vm.expectRevert(RobinhoodBoostedVault.InvalidConfiguration.selector);
        vault.registerPair(keccak256("SECOND"), config, tooTight);

        // 600 / 2 + 100 = 400 is exactly sufficient.
        IUniswapV4PairedAdapter.RegisterPairParams memory sufficient = tooTight;
        sufficient.removalToleranceBps = 400;
        vault.registerPair(keccak256("SECOND"), config, sufficient);
        assertEq(vault.pairConfig(keccak256("SECOND")).stockToken, address(stock));
    }

    function testRemovalToleranceCheckRoundsTheHalfUp() external {
        // An odd bound needs ceil(601/2) + 100 = 401. Flooring would accept 400, one bp
        // short of the amount deviation the tolerance actually has to absorb.
        oracle.setMaxRemovalDeviationBps(601);
        PairConfig memory config = vault.pairConfig(PAIR_ID);
        IUniswapV4PairedAdapter.RegisterPairParams memory params =
            IUniswapV4PairedAdapter.RegisterPairParams({
                stockToken: address(stock),
                usdg: address(usdg),
                poolKey: _poolKey(),
                expectedPoolId: keccak256("pool"),
                removalToleranceBps: 400
            });

        vm.expectRevert(RobinhoodBoostedVault.InvalidConfiguration.selector);
        vault.registerPair(keccak256("ODD"), config, params);

        params.removalToleranceBps = 401;
        vault.registerPair(keccak256("ODD"), config, params);
        assertEq(vault.pairConfig(keccak256("ODD")).stockToken, address(stock));
    }

    function testExitsToleratePoolDeviationThatBlocksAllocation() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Pool drifts past the allocation bound but stays inside the removal bound: adding
        // liquidity must stop while holders can still get out.
        oracle.setAllocationShouldRevert(true);
        vm.prank(keeper);
        vm.expectRevert(bytes("ORACLE"));
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        vm.prank(stockAccount);
        (uint256 returned,) =
            vault.withdrawForSide(PAIR_ID, address(stock), 5e18, receiver, block.timestamp + 60);
        assertEq(returned, 5e18, "exit must survive an allocation-bound breach");
        assertEq(stock.balanceOf(receiver), 5e18);
    }

    function testExitsStillFailClosedBeyondTheRemovalBound() external {
        _depositPair(20e18, 1_000e6);
        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        // Past the wider removal bound the exit must still fail closed rather than unwind
        // against a pool the oracle cannot vouch for.
        oracle.setRemovalShouldRevert(true);
        vm.prank(stockAccount);
        vm.expectRevert(bytes("ORACLE"));
        vault.withdrawForSide(PAIR_ID, address(stock), 5e18, receiver, block.timestamp + 60);
        assertEq(vault.withdrawableAssets(PAIR_ID, address(stock)), 0);
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
        PairConfig memory config = vault.pairConfig(PAIR_ID);
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
        PairConfig memory config = vault.pairConfig(PAIR_ID);
        config.maxPairValueUSDG = uint128(100e18);
        vault.updatePairRisk(PAIR_ID, config);

        vm.prank(stockAccount);
        vm.expectRevert(RobinhoodBoostedVault.PairCapExceeded.selector);
        vault.depositForPair(PAIR_ID, address(stock), 2e18);

        assertEq(vault.accountedAssets(PAIR_ID, address(stock)), 0);
    }

    function testRebalanceAutoPausesAllocationWhenExistingPairExceedsCap() external {
        _depositPair(1e18, 100e6);
        PairConfig memory config = vault.pairConfig(PAIR_ID);
        config.maxPairValueUSDG = uint128(250e18);
        vault.updatePairRisk(PAIR_ID, config);
        oracle.setPrices(200e18, 1e18);

        vm.prank(keeper);
        vault.rebalance(PAIR_ID, block.timestamp + 60);

        config = vault.pairConfig(PAIR_ID);
        assertTrue(config.allocationPaused);
        assertEq(adapter.positionState(PAIR_ID).liquidity, 0);
        assertEq(vault.liquidAssets(PAIR_ID, address(stock)), 1e18);
        assertEq(vault.liquidAssets(PAIR_ID, address(usdg)), 100e6);
        _assertVaultAllowancesZero();
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

    function _assertVaultAllowancesZero() internal view {
        assertEq(stock.allowance(address(vault), address(adapter)), 0);
        assertEq(usdg.allowance(address(vault), address(adapter)), 0);
        assertEq(stock.allowance(address(vault), address(reserve)), 0);
        assertEq(usdg.allowance(address(vault), address(reserve)), 0);
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
