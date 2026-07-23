// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { StockOracleGuard } from "../src/StockOracleGuard.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockAggregator } from "./mocks/MockAggregator.sol";

contract StockOracleGuardTest is Test {
    bytes32 internal constant PAIR_ID = keccak256("NVDA/USDG");
    StockOracleGuard internal guard;
    MockERC20 internal stock;
    MockERC20 internal usdg;
    MockAggregator internal stockFeed;

    function setUp() external {
        vm.warp(10 days);
        stock = new MockERC20("NVIDIA", "NVDA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        stockFeed = new MockAggregator(8, "NVDA / USD", 123_45000000);
        StockOracleGuard implementation = new StockOracleGuard();
        guard = StockOracleGuard(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        StockOracleGuard.initialize, (address(this), IPoolManager(address(1)))
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

    function _configure(address sequencer) internal {
        guard.configurePair(
            PAIR_ID,
            StockOracleGuard.FeedConfig({
                stockToken: address(stock),
                usdg: address(usdg),
                stockFeed: stockFeed,
                usdgFeed: MockAggregator(address(0)),
                sequencerFeed: MockAggregator(sequencer),
                poolId: keccak256("pool"),
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
}
