// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import { RobinhoodBoostedVault } from "../../src/RobinhoodBoostedVault.sol";
import { IUniswapV4PairedAdapter } from "../../src/interfaces/IUniswapV4PairedAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockOracleGuard } from "../mocks/MockOracleGuard.sol";
import { MockLossReserve } from "../mocks/MockLossReserve.sol";
import { MockLiquidityAdapter } from "../mocks/MockLiquidityAdapter.sol";

contract VaultHandler is Test {
    RobinhoodBoostedVault internal vault;
    MockERC20 internal stock;
    MockERC20 internal usdg;
    bytes32 internal pairId;
    address internal stockAccount;
    address internal usdgAccount;
    address internal keeper;

    constructor(
        RobinhoodBoostedVault vault_,
        MockERC20 stock_,
        MockERC20 usdg_,
        bytes32 pairId_,
        address stockAccount_,
        address usdgAccount_,
        address keeper_
    ) {
        vault = vault_;
        stock = stock_;
        usdg = usdg_;
        pairId = pairId_;
        stockAccount = stockAccount_;
        usdgAccount = usdgAccount_;
        keeper = keeper_;
    }

    function depositStock(uint96 seed) external {
        uint256 amount = bound(uint256(seed), 1, 100e18);
        stock.mint(stockAccount, amount);
        vm.prank(stockAccount);
        try vault.depositForPair(pairId, address(stock), amount) { } catch { }
    }

    function depositUsdg(uint64 seed) external {
        uint256 amount = bound(uint256(seed), 1, 100_000e6);
        usdg.mint(usdgAccount, amount);
        vm.prank(usdgAccount);
        try vault.depositForPair(pairId, address(usdg), amount) { } catch { }
    }

    function rebalance() external {
        vm.prank(keeper);
        try vault.rebalance(pairId, block.timestamp + 60) { } catch { }
    }

    function withdrawStock(uint96 seed) external {
        uint256 idle = vault.liquidAssets(pairId, address(stock));
        if (idle == 0) return;
        uint256 amount = bound(uint256(seed), 1, idle);
        vm.prank(stockAccount);
        try vault.withdrawForSide(pairId, address(stock), amount, stockAccount, 0) { } catch { }
    }

    function withdrawUsdg(uint64 seed) external {
        uint256 idle = vault.liquidAssets(pairId, address(usdg));
        if (idle == 0) return;
        uint256 amount = bound(uint256(seed), 1, idle);
        vm.prank(usdgAccount);
        try vault.withdrawForSide(pairId, address(usdg), amount, usdgAccount, 0) { } catch { }
    }

    function checkpoint() external {
        vm.prank(keeper);
        try vault.checkpoint(pairId, block.timestamp + 60) { } catch { }
    }
}

contract VaultAccountingInvariant is StdInvariant, Test {
    bytes32 internal constant PAIR_ID = keccak256("NVDA/USDG");
    address internal stockAccount = makeAddr("stockAccount");
    address internal usdgAccount = makeAddr("usdgAccount");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");

    RobinhoodBoostedVault internal vault;
    MockERC20 internal stock;
    MockERC20 internal usdg;
    MockLiquidityAdapter internal adapter;

    function setUp() external {
        stock = new MockERC20("NVIDIA", "NVDA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        MockOracleGuard oracle = new MockOracleGuard();
        MockLossReserve reserve = new MockLossReserve();
        adapter = new MockLiquidityAdapter();
        RobinhoodBoostedVault implementation = new RobinhoodBoostedVault();
        vault = RobinhoodBoostedVault(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        RobinhoodBoostedVault.initialize,
                        (address(this), keeper, guardian, oracle, reserve, adapter)
                    )
                )
            )
        );
        adapter.setVault(address(vault));
        vault.setAggregateUsdgDepositCap(address(usdg), type(uint128).max);

        address token0 = address(stock) < address(usdg) ? address(stock) : address(usdg);
        address token1 = address(stock) < address(usdg) ? address(usdg) : address(stock);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.registerPair(
            PAIR_ID,
            RobinhoodBoostedVault.PairConfig({
                stockToken: address(stock),
                usdg: address(usdg),
                stockAccount: stockAccount,
                usdgAccount: usdgAccount,
                maxPairValueUSDG: type(uint128).max,
                maxSettlementSwapUSDG: type(uint128).max,
                maxCheckpointAge: 1 days,
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
                stockToken: address(stock),
                usdg: address(usdg),
                poolKey: key,
                expectedPoolId: keccak256("pool"),
                removalToleranceBps: 400
            })
        );
        vm.prank(stockAccount);
        stock.approve(address(vault), type(uint256).max);
        vm.prank(usdgAccount);
        usdg.approve(address(vault), type(uint256).max);

        VaultHandler handler =
            new VaultHandler(vault, stock, usdg, PAIR_ID, stockAccount, usdgAccount, keeper);
        targetContract(address(handler));
    }

    function invariantCustodyCoversCachedClaims() external view {
        uint256 stockCustody = stock.balanceOf(address(vault)) + stock.balanceOf(address(adapter));
        uint256 usdgCustody = usdg.balanceOf(address(vault)) + usdg.balanceOf(address(adapter));
        assertGe(stockCustody, vault.accountedAssets(PAIR_ID, address(stock)));
        assertGe(usdgCustody, vault.accountedAssets(PAIR_ID, address(usdg)));
    }

    function invariantIdleNeverExceedsVaultCustody() external view {
        assertLe(vault.liquidAssets(PAIR_ID, address(stock)), stock.balanceOf(address(vault)));
        assertLe(vault.liquidAssets(PAIR_ID, address(usdg)), usdg.balanceOf(address(vault)));
    }

    function invariantAggregateUsdgMatchesSinglePairClaim() external view {
        assertEq(
            vault.aggregateUsdgPrincipal(address(usdg)),
            vault.accountedAssets(PAIR_ID, address(usdg))
        );
    }
}
