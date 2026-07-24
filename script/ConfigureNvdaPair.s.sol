// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { RobinhoodBoostedVault } from "../src/RobinhoodBoostedVault.sol";
import { StockOracleGuard } from "../src/StockOracleGuard.sol";
import { StrategyLossReserve } from "../src/StrategyLossReserve.sol";
import { IUniswapV4PairedAdapter } from "../src/interfaces/IUniswapV4PairedAdapter.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";

interface IUnderlyingToken {
    function underlying() external view returns (address);

    function vaultPaused() external view returns (bool);
}

/// @notice Builds or directly executes the four calls that configure an NVDA pair.
/// @dev Proposal-payload output is the default. Direct EOA broadcasting requires the
///      explicit DIRECT_CONFIG_BROADCAST=true opt-in.
contract ConfigureNvdaPair is Script {
    bytes32 public constant CANARY_PAIR_ID = keccak256("NVDA/USDG/CANARY");
    bytes32 public constant PRODUCTION_PAIR_ID = keccak256("NVDA/USDG");
    bytes32 public constant NVDA_POOL_ID =
        0x3bb34a44f1b2b5f32c034c38a53065a521a47b199700fa9bd19d60985ff24bf1;

    function run() external {
        require(block.chainid == 4663, "WRONG_CHAIN");
        string memory pairLabel = vm.envString("PAIR_LABEL");
        require(bytes(pairLabel).length != 0, "EMPTY_PAIR_LABEL");
        bytes32 pairId = keccak256(bytes(pairLabel));
        require(pairId == CANARY_PAIR_ID || pairId == PRODUCTION_PAIR_ID, "UNAPPROVED_PAIR_LABEL");
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
        StockOracleGuard.FeedConfig memory oracleConfig = _oracleConfig(stock, usdg);
        StrategyLossReserve.ReserveConfig memory reserveConfig = _reserveConfig(stock, usdg);
        RobinhoodBoostedVault.PairConfig memory vaultConfig = _vaultConfig(stock, usdg);
        IUniswapV4PairedAdapter.RegisterPairParams memory adapterConfig =
            _adapterConfig(stock, usdg, key);
        _validateRollout(pairId, vault, vaultConfig);
        uint256 aggregateCap = vm.envOr("AGGREGATE_USDG_DEPOSIT_CAP", uint256(0));

        if (!vm.envOr("DIRECT_CONFIG_BROADCAST", false)) {
            _printPayload(
                "configure oracle",
                address(oracle),
                abi.encodeCall(StockOracleGuard.configurePair, (pairId, oracleConfig))
            );
            _printPayload(
                "configure reserve",
                address(reserve),
                abi.encodeCall(StrategyLossReserve.configurePair, (pairId, reserveConfig))
            );
            _printPayload(
                "set aggregate USDG cap",
                address(vault),
                abi.encodeCall(
                    RobinhoodBoostedVault.setAggregateUsdgDepositCap, (usdg, aggregateCap)
                )
            );
            _printPayload(
                "register vault pair",
                address(vault),
                abi.encodeCall(
                    RobinhoodBoostedVault.registerPair, (pairId, vaultConfig, adapterConfig)
                )
            );
            return;
        }

        uint256 governanceKey = vm.envUint("GOVERNANCE_PRIVATE_KEY");
        vm.startBroadcast(governanceKey);
        oracle.configurePair(pairId, oracleConfig);
        reserve.configurePair(pairId, reserveConfig);
        vault.setAggregateUsdgDepositCap(usdg, aggregateCap);
        vault.registerPair(pairId, vaultConfig, adapterConfig);
        vm.stopBroadcast();
    }

    function _printPayload(string memory label, address target, bytes memory data) internal pure {
        console2.log(label);
        console2.log("target", target);
        console2.log("value", uint256(0));
        console2.log("calldata");
        console2.logBytes(data);
    }

    function _validateRollout(
        bytes32 pairId,
        RobinhoodBoostedVault vault,
        RobinhoodBoostedVault.PairConfig memory config
    ) internal view {
        require(address(vault).code.length != 0, "VAULT_NOT_CONTRACT");
        if (pairId == CANARY_PAIR_ID) {
            require(config.stockAccount.code.length == 0, "CANARY_STOCK_ACCOUNT_NOT_EOA");
            require(config.usdgAccount.code.length == 0, "CANARY_USDG_ACCOUNT_NOT_EOA");
            require(config.maxPairValueUSDG != 0, "CANARY_PAIR_CAP_REQUIRED");
            require(vm.envUint("AGGREGATE_USDG_DEPOSIT_CAP") != 0, "CANARY_AGGREGATE_CAP_REQUIRED");
            return;
        }

        require(config.usdgAccount.code.length != 0, "PRODUCTION_PUSDG_NOT_CONTRACT");
        require(
            IUnderlyingToken(config.usdgAccount).underlying() == config.usdg, "PUSDG_UNDERLYING"
        );
        require(IUnderlyingToken(config.usdgAccount).vaultPaused(), "PUSDG_MUST_START_PAUSED");
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
