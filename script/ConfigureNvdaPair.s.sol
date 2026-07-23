// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { RobinhoodBoostedVault } from "../src/RobinhoodBoostedVault.sol";
import { StockOracleGuard } from "../src/StockOracleGuard.sol";
import { StrategyLossReserve } from "../src/StrategyLossReserve.sol";
import { IUniswapV4PairedAdapter } from "../src/interfaces/IUniswapV4PairedAdapter.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";

/// @notice Configures the verified NVDA canary. When governance is a contract timelock,
/// use the three encoded calls produced by this script as proposal payloads rather than
/// broadcasting them directly from an EOA.
contract ConfigureNvdaPair is Script {
    bytes32 public constant PAIR_ID = keccak256("NVDA/USDG");
    bytes32 public constant NVDA_POOL_ID =
        0x3bb34a44f1b2b5f32c034c38a53065a521a47b199700fa9bd19d60985ff24bf1;

    function run() external {
        require(block.chainid == 4663, "WRONG_CHAIN");
        uint256 governanceKey = vm.envUint("GOVERNANCE_PRIVATE_KEY");
        RobinhoodBoostedVault vault = RobinhoodBoostedVault(vm.envAddress("VAULT_PROXY"));
        StockOracleGuard oracle = StockOracleGuard(vm.envAddress("ORACLE_PROXY"));
        StrategyLossReserve reserve = StrategyLossReserve(vm.envAddress("RESERVE_PROXY"));
        address stock = vm.envAddress("STOCK_TOKEN");
        address usdg = vm.envAddress("USDG");
        require(usdg < stock, "EXPECTED_USDG_TOKEN0");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdg),
            currency1: Currency.wrap(stock),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.startBroadcast(governanceKey);
        oracle.configurePair(PAIR_ID, _oracleConfig(stock, usdg));
        reserve.configurePair(PAIR_ID, _reserveConfig(stock, usdg));
        vault.setAggregateUsdgDepositCap(usdg, vm.envOr("AGGREGATE_USDG_DEPOSIT_CAP", uint256(0)));
        vault.registerPair(PAIR_ID, _vaultConfig(stock, usdg), _adapterConfig(stock, usdg, key));
        vm.stopBroadcast();
    }

    function _oracleConfig(address stock, address usdg)
        internal
        view
        returns (StockOracleGuard.FeedConfig memory config)
    {
        address sequencer = vm.envOr("SEQUENCER_FEED", address(0));
        config.stockToken = stock;
        config.usdg = usdg;
        config.stockFeed = IAggregatorV3(vm.envAddress("STOCK_PRICE_FEED"));
        config.sequencerFeed = IAggregatorV3(sequencer);
        config.poolId = NVDA_POOL_ID;
        config.maxStaleness = uint64(vm.envUint("TRADING_SESSION_MAX_STALENESS"));
        config.sequencerGracePeriod = uint64(vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(3600)));
        config.maxPriceDeviationBps = uint16(vm.envOr("MAX_PRICE_DEVIATION_BPS", uint256(300)));
        config.stockDecimals = IERC20Metadata(stock).decimals();
        config.usdgDecimals = IERC20Metadata(usdg).decimals();
        config.stockFeedDecimals = config.stockFeed.decimals();
        config.usdgFixedOne = true;
        config.enabled = true;
    }

    function _reserveConfig(address stock, address usdg)
        internal
        view
        returns (StrategyLossReserve.ReserveConfig memory config)
    {
        config.stockToken = stock;
        config.usdg = usdg;
        // Defaults assume an initial governance-funded reserve of at most $100.
        // Revisit both absolute limits through governance as fee funding grows.
        config.maxUsePerTxUSDG = uint128(vm.envOr("MAX_RESERVE_USE_PER_TX_USDG", uint256(10e18)));
        config.dailyCapUSDG = uint128(vm.envOr("MAX_DAILY_RESERVE_USE_USDG", uint256(25e18)));
        config.maxCoverageBps = uint16(vm.envOr("MAX_LOSS_COVERAGE_BPS", uint256(5000)));
        config.exists = true;
    }

    function _vaultConfig(address stock, address usdg)
        internal
        view
        returns (RobinhoodBoostedVault.PairConfig memory config)
    {
        config.stockToken = stock;
        config.usdg = usdg;
        config.stockAccount = vm.envAddress("STOCK_SIDE_ACCOUNT");
        config.usdgAccount = vm.envAddress("USDG_SIDE_ACCOUNT");
        // Zero disables the optional pair-value circuit breaker.
        config.maxPairValueUSDG = uint128(vm.envOr("MAX_PAIR_VALUE_USDG", uint256(0)));
        config.maxSettlementSwapUSDG = uint128(vm.envUint("MAX_SETTLEMENT_SWAP_USDG"));
        config.maxCheckpointAge = uint64(vm.envUint("MAX_CHECKPOINT_AGE"));
        // Retained only to preserve the proxy storage layout; minimum delays are disabled.
        config.deprecatedMinDeadlineDelay = 0;
        config.maxDeadlineDelay = uint32(vm.envOr("MAX_DEADLINE_DELAY", uint256(300)));
        config.reserveFeeBps = uint16(vm.envOr("RESERVE_FEE_BPS", uint256(2000)));
        config.maxSwapSlippageBps = uint16(vm.envOr("MAX_SWAP_SLIPPAGE_BPS", uint256(100)));
        config.withdrawOverUnwindBps = uint16(vm.envOr("WITHDRAW_OVER_UNWIND_BPS", uint256(200)));
        config.stockDecimals = IERC20Metadata(stock).decimals();
        config.usdgDecimals = IERC20Metadata(usdg).decimals();
        config.allocationPaused = true;
        config.swapsPaused = true;
        config.exists = true;
    }

    function _adapterConfig(address stock, address usdg, PoolKey memory key)
        internal
        view
        returns (IUniswapV4PairedAdapter.RegisterPairParams memory)
    {
        return IUniswapV4PairedAdapter.RegisterPairParams({
            stockToken: stock,
            usdg: usdg,
            poolKey: key,
            expectedPoolId: NVDA_POOL_ID,
            removalToleranceBps: uint16(vm.envOr("REMOVAL_TOLERANCE_BPS", uint256(400)))
        });
    }
}
