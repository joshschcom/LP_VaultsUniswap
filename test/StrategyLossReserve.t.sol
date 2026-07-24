// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StrategyLossReserve } from "../src/StrategyLossReserve.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract StrategyLossReserveTest is Test {
    bytes32 internal constant PAIR_ID = keccak256("NVDA/USDG");
    StrategyLossReserve internal reserve;
    MockERC20 internal stock;
    MockERC20 internal usdg;
    address internal funder = makeAddr("funder");

    function setUp() external {
        stock = new MockERC20("NVIDIA", "NVDA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        StrategyLossReserve implementation = new StrategyLossReserve();
        reserve = StrategyLossReserve(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(StrategyLossReserve.initialize, (address(this), address(this)))
                )
            )
        );
        reserve.configurePair(
            PAIR_ID,
            StrategyLossReserve.ReserveConfig({
                stockToken: address(stock),
                usdg: address(usdg),
                maxUsePerTxUSDG: uint128(40e18),
                dailyCapUSDG: uint128(60e18),
                maxCoverageBps: 5_000,
                paused: false,
                exists: true
            })
        );
        usdg.mint(funder, 1_000e6);
        vm.prank(funder);
        usdg.approve(address(reserve), type(uint256).max);
        vm.prank(funder);
        reserve.deposit(PAIR_ID, address(usdg), 1_000e6);
    }

    function testCoverageEnforcesPerEventAndDailyCaps() external {
        uint256 first = reserve.cover(PAIR_ID, address(usdg), 100e6, 100e18, 100e18);
        assertEq(first, 40e6);

        uint256 second = reserve.cover(PAIR_ID, address(usdg), 100e6, 100e18, 100e18);
        assertEq(second, 20e6);
        assertEq(usdg.balanceOf(address(this)), 60e6);
    }

    function testPausedReserveCannotCoverButCanBeGovernanceWithdrawn() external {
        reserve.setPaused(PAIR_ID, true);
        vm.expectRevert(StrategyLossReserve.ReservePaused.selector);
        reserve.cover(PAIR_ID, address(usdg), 10e6, 10e18, 10e18);

        reserve.withdrawPausedReserve(PAIR_ID, address(usdg), address(this), 10e6);
        assertEq(usdg.balanceOf(address(this)), 10e6);
    }

    function testConfiguredReserveTokensCannotChangeButLimitsCan() external {
        MockERC20 replacement = new MockERC20("Replacement", "R", 18);
        StrategyLossReserve.ReserveConfig memory config = StrategyLossReserve.ReserveConfig({
            stockToken: address(replacement),
            usdg: address(usdg),
            maxUsePerTxUSDG: uint128(40e18),
            dailyCapUSDG: uint128(60e18),
            maxCoverageBps: 5_000,
            paused: false,
            exists: true
        });

        vm.expectRevert(StrategyLossReserve.InvalidConfiguration.selector);
        reserve.configurePair(PAIR_ID, config);

        config.stockToken = address(stock);
        config.maxUsePerTxUSDG = uint128(20e18);
        config.dailyCapUSDG = uint128(30e18);
        config.paused = true;
        reserve.configurePair(PAIR_ID, config);

        (
            address updatedStock,
            address updatedUsdg,
            uint128 updatedPerTx,
            uint128 updatedDaily,
            uint16 updatedCoverage,
            bool updatedPaused,
            bool updatedExists
        ) = reserve.reserveConfig(PAIR_ID);
        assertEq(updatedStock, address(stock));
        assertEq(updatedUsdg, address(usdg));
        assertEq(updatedPerTx, 20e18);
        assertEq(updatedDaily, 30e18);
        assertEq(updatedCoverage, 5_000);
        assertTrue(updatedPaused);
        assertTrue(updatedExists);
        assertEq(reserve.available(PAIR_ID, address(usdg)), 1_000e6);
    }

    function testOnlyUnaccountedSurplusCanBeSwept() external {
        address receiver = makeAddr("surplusReceiver");
        usdg.mint(address(reserve), 50e6);

        assertEq(reserve.accountedBalance(address(usdg)), 1_000e6);
        reserve.sweepSurplus(address(usdg), receiver, 50e6);
        assertEq(usdg.balanceOf(receiver), 50e6);
        assertEq(reserve.accountedBalance(address(usdg)), 1_000e6);

        vm.expectRevert(StrategyLossReserve.InsufficientSurplus.selector);
        reserve.sweepSurplus(address(usdg), receiver, 1);
    }

    function testFeeOnTransferFromReserveToVaultRevertsWithoutAccountingDrift() external {
        usdg.setTransferFee(100, address(reserve), address(this));

        vm.expectRevert(StrategyLossReserve.BalanceDeltaMismatch.selector);
        reserve.cover(PAIR_ID, address(usdg), 10e6, 10e18, 10e18);

        assertEq(reserve.available(PAIR_ID, address(usdg)), 1_000e6);
        assertEq(reserve.accountedBalance(address(usdg)), 1_000e6);
        assertEq(usdg.balanceOf(address(this)), 0);
    }

    function testFeeOnTransferDepositIsRejectedWithoutAccountingDrift() external {
        usdg.mint(funder, 100e6);
        usdg.setTransferFee(100, funder, address(reserve));

        vm.prank(funder);
        vm.expectRevert(StrategyLossReserve.BalanceDeltaMismatch.selector);
        reserve.deposit(PAIR_ID, address(usdg), 100e6);

        assertEq(reserve.available(PAIR_ID, address(usdg)), 1_000e6);
        assertEq(reserve.accountedBalance(address(usdg)), 1_000e6);
    }

    function testDailyUsageRoundsCoverageValueUp() external {
        reserve.configurePair(
            PAIR_ID,
            StrategyLossReserve.ReserveConfig({
                stockToken: address(stock),
                usdg: address(usdg),
                maxUsePerTxUSDG: 1,
                dailyCapUSDG: 1,
                maxCoverageBps: 10_000,
                paused: false,
                exists: true
            })
        );

        assertEq(reserve.cover(PAIR_ID, address(usdg), 3, 2, 2), 1);
        (, uint192 usedUSDG) = reserve.dailyUsage(PAIR_ID);
        assertEq(usedUSDG, 1);
        assertEq(reserve.cover(PAIR_ID, address(usdg), 3, 2, 2), 0);
    }
}
