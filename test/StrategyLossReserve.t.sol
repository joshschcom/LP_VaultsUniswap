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
}
