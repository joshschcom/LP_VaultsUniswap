// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { RobinhoodBoostedVault } from "../src/RobinhoodBoostedVault.sol";
import { StrategyLossReserve } from "../src/StrategyLossReserve.sol";
import { IUniswapV4PairedAdapter } from "../src/interfaces/IUniswapV4PairedAdapter.sol";

/**
 * @notice Runs one deliberately explicit action against the standalone NVDA/USDG canary.
 * @dev Use a different ACTION_PRIVATE_KEY for governance, keeper, and each side account.
 *      `status` and `assert-drained` are read-only and do not load a private key.
 */
contract RunNvdaCanary is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    bytes32 public constant PAIR_ID = keccak256("NVDA/USDG/CANARY");
    address public constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "WRONG_CHAIN");
        RobinhoodBoostedVault vault = RobinhoodBoostedVault(vm.envAddress("VAULT_PROXY"));
        require(address(vault).code.length != 0, "VAULT_NOT_CONTRACT");
        RobinhoodBoostedVault.PairConfig memory config = _validateCanary(vault);
        bytes32 action = keccak256(bytes(vm.envString("CANARY_ACTION")));

        if (action == keccak256("status")) {
            _printStatus(vault, config);
            return;
        }
        if (action == keccak256("assert-drained")) {
            _assertDrained(vault);
            return;
        }
        if (vm.envOr("PAYLOAD_ONLY", false)) {
            _printGovernancePayload(vault, action);
            return;
        }

        uint256 actionKey = vm.envUint("ACTION_PRIVATE_KEY");
        address actor = vm.addr(actionKey);

        if (action == keccak256("enable-allocation")) {
            vm.startBroadcast(actionKey);
            vault.setPairPause(PAIR_ID, false, true, false);
            vm.stopBroadcast();
        } else if (action == keccak256("enable-swaps")) {
            vm.startBroadcast(actionKey);
            vault.setPairPause(PAIR_ID, false, false, false);
            vm.stopBroadcast();
        } else if (action == keccak256("pause")) {
            vm.startBroadcast(actionKey);
            vault.setPairPause(PAIR_ID, true, true, false);
            vm.stopBroadcast();
        } else if (action == keccak256("deposit-stock")) {
            _deposit(vault, actionKey, actor, config.stockAccount, NVDA, "CANARY_MAX_STOCK_AMOUNT");
        } else if (action == keccak256("deposit-usdg")) {
            _deposit(vault, actionKey, actor, config.usdgAccount, USDG, "CANARY_MAX_USDG_AMOUNT");
        } else if (action == keccak256("fund-reserve-stock")) {
            _fundReserve(vault, actionKey, actor, NVDA, "CANARY_MAX_RESERVE_STOCK_AMOUNT");
        } else if (action == keccak256("fund-reserve-usdg")) {
            _fundReserve(vault, actionKey, actor, USDG, "CANARY_MAX_RESERVE_USDG_AMOUNT");
        } else if (action == keccak256("rebalance")) {
            vm.startBroadcast(actionKey);
            vault.rebalance(PAIR_ID, _deadline(config));
            vm.stopBroadcast();
        } else if (action == keccak256("checkpoint")) {
            vm.startBroadcast(actionKey);
            vault.checkpoint(PAIR_ID, _deadline(config));
            vm.stopBroadcast();
        } else if (action == keccak256("withdraw-stock")) {
            _withdraw(
                vault,
                actionKey,
                actor,
                config.stockAccount,
                NVDA,
                "CANARY_MAX_STOCK_AMOUNT",
                config
            );
        } else if (action == keccak256("withdraw-usdg")) {
            _withdraw(
                vault, actionKey, actor, config.usdgAccount, USDG, "CANARY_MAX_USDG_AMOUNT", config
            );
        } else if (action == keccak256("burn-position")) {
            vm.startBroadcast(actionKey);
            vault.burnEmptyPosition(PAIR_ID, _deadline(config));
            vm.stopBroadcast();
        } else if (action == keccak256("pause-reserve")) {
            vm.startBroadcast(actionKey);
            StrategyLossReserve(address(vault.lossReserve())).setPaused(PAIR_ID, true);
            vm.stopBroadcast();
        } else if (action == keccak256("withdraw-reserve-stock")) {
            _withdrawReserve(vault, actionKey, actor, NVDA, "CANARY_MAX_RESERVE_STOCK_AMOUNT");
        } else if (action == keccak256("withdraw-reserve-usdg")) {
            _withdrawReserve(vault, actionKey, actor, USDG, "CANARY_MAX_RESERVE_USDG_AMOUNT");
        } else {
            revert("UNKNOWN_CANARY_ACTION");
        }

        _printStatus(vault, vault.pairConfig(PAIR_ID));
    }

    function _deposit(
        RobinhoodBoostedVault vault,
        uint256 actionKey,
        address actor,
        address expectedActor,
        address token,
        string memory maxAmountEnv
    ) internal {
        require(actor == expectedActor, "WRONG_SIDE_KEY");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 maxAmount = vm.envUint(maxAmountEnv);
        require(amount != 0 && maxAmount != 0 && amount <= maxAmount, "CANARY_AMOUNT_LIMIT");
        require(IERC20(token).balanceOf(actor) >= amount, "INSUFFICIENT_SIDE_BALANCE");

        vm.startBroadcast(actionKey);
        IERC20(token).forceApprove(address(vault), amount);
        uint256 deposited = vault.depositForPair(PAIR_ID, token, amount);
        IERC20(token).forceApprove(address(vault), 0);
        vm.stopBroadcast();

        require(deposited == amount, "DEPOSIT_AMOUNT_MISMATCH");
    }

    function _fundReserve(
        RobinhoodBoostedVault vault,
        uint256 actionKey,
        address actor,
        address token,
        string memory maxAmountEnv
    ) internal {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 maxAmount = vm.envUint(maxAmountEnv);
        require(amount != 0 && maxAmount != 0 && amount <= maxAmount, "CANARY_AMOUNT_LIMIT");
        require(IERC20(token).balanceOf(actor) >= amount, "INSUFFICIENT_FUNDER_BALANCE");
        StrategyLossReserve reserve = StrategyLossReserve(address(vault.lossReserve()));

        vm.startBroadcast(actionKey);
        IERC20(token).forceApprove(address(reserve), amount);
        uint256 deposited = reserve.deposit(PAIR_ID, token, amount);
        IERC20(token).forceApprove(address(reserve), 0);
        vm.stopBroadcast();

        require(deposited == amount, "RESERVE_DEPOSIT_MISMATCH");
    }

    function _withdraw(
        RobinhoodBoostedVault vault,
        uint256 actionKey,
        address actor,
        address expectedActor,
        address token,
        string memory maxAmountEnv,
        RobinhoodBoostedVault.PairConfig memory config
    ) internal {
        require(actor == expectedActor, "WRONG_SIDE_KEY");
        uint256 accounted = vault.accountedAssets(PAIR_ID, token);
        uint256 amount = vm.envOr("AMOUNT", accounted);
        uint256 maxAmount = vm.envUint(maxAmountEnv);
        require(amount != 0 && amount <= accounted && amount <= maxAmount, "CANARY_AMOUNT_LIMIT");
        address receiver = vm.envOr("RECEIVER", actor);
        require(receiver != address(0), "RECEIVER_ZERO");

        vm.startBroadcast(actionKey);
        (uint256 returned, uint256 realizedLoss) =
            vault.withdrawForSide(PAIR_ID, token, amount, receiver, _deadline(config));
        vm.stopBroadcast();

        console2.log("withdraw requested", amount);
        console2.log("withdraw returned", returned);
        console2.log("withdraw realized loss", realizedLoss);
    }

    function _withdrawReserve(
        RobinhoodBoostedVault vault,
        uint256 actionKey,
        address actor,
        address token,
        string memory maxAmountEnv
    ) internal {
        StrategyLossReserve reserve = StrategyLossReserve(address(vault.lossReserve()));
        uint256 available = reserve.available(PAIR_ID, token);
        uint256 amount = vm.envOr("AMOUNT", available);
        uint256 maxAmount = vm.envUint(maxAmountEnv);
        require(amount != 0 && amount <= available && amount <= maxAmount, "CANARY_AMOUNT_LIMIT");
        address receiver = vm.envOr("RECEIVER", actor);
        require(receiver != address(0), "RECEIVER_ZERO");

        vm.startBroadcast(actionKey);
        reserve.withdrawPausedReserve(PAIR_ID, token, receiver, amount);
        vm.stopBroadcast();
    }

    function _validateCanary(RobinhoodBoostedVault vault)
        internal
        view
        returns (RobinhoodBoostedVault.PairConfig memory config)
    {
        config = vault.pairConfig(PAIR_ID);
        require(config.exists, "CANARY_NOT_REGISTERED");
        require(config.stockToken == NVDA && config.usdg == USDG, "CANARY_TOKEN_MISMATCH");
        require(config.stockAccount.code.length == 0, "STOCK_SIDE_NOT_EOA");
        require(config.usdgAccount.code.length == 0, "USDG_SIDE_NOT_EOA");
        require(config.maxPairValueUSDG != 0, "CANARY_PAIR_CAP_DISABLED");
        require(vault.aggregateUsdgDepositCap(USDG) != 0, "CANARY_AGGREGATE_CAP_DISABLED");
    }

    function _printGovernancePayload(RobinhoodBoostedVault vault, bytes32 action) internal view {
        address target;
        bytes memory data;
        if (action == keccak256("enable-allocation")) {
            target = address(vault);
            data = abi.encodeCall(RobinhoodBoostedVault.setPairPause, (PAIR_ID, false, true, false));
        } else if (action == keccak256("enable-swaps")) {
            target = address(vault);
            data =
                abi.encodeCall(RobinhoodBoostedVault.setPairPause, (PAIR_ID, false, false, false));
        } else if (action == keccak256("pause")) {
            target = address(vault);
            data = abi.encodeCall(RobinhoodBoostedVault.setPairPause, (PAIR_ID, true, true, false));
        } else if (action == keccak256("pause-reserve")) {
            target = address(vault.lossReserve());
            data = abi.encodeCall(StrategyLossReserve.setPaused, (PAIR_ID, true));
        } else if (
            action == keccak256("withdraw-reserve-stock")
                || action == keccak256("withdraw-reserve-usdg")
        ) {
            StrategyLossReserve reserve = StrategyLossReserve(address(vault.lossReserve()));
            address token = action == keccak256("withdraw-reserve-stock") ? NVDA : USDG;
            string memory maxAmountEnv = action == keccak256("withdraw-reserve-stock")
                ? "CANARY_MAX_RESERVE_STOCK_AMOUNT"
                : "CANARY_MAX_RESERVE_USDG_AMOUNT";
            uint256 available = reserve.available(PAIR_ID, token);
            uint256 amount = vm.envOr("AMOUNT", available);
            uint256 maxAmount = vm.envUint(maxAmountEnv);
            address receiver = vm.envAddress("RECEIVER");
            require(
                receiver != address(0) && amount != 0 && amount <= available && amount <= maxAmount,
                "CANARY_AMOUNT_LIMIT"
            );
            target = address(reserve);
            data = abi.encodeCall(
                StrategyLossReserve.withdrawPausedReserve, (PAIR_ID, token, receiver, amount)
            );
        } else {
            revert("ACTION_NOT_GOVERNANCE_PAYLOAD");
        }

        console2.log("target", target);
        console2.log("value", uint256(0));
        console2.log("calldata");
        console2.logBytes(data);
    }

    function _deadline(RobinhoodBoostedVault.PairConfig memory config)
        internal
        view
        returns (uint256)
    {
        uint256 window = vm.envOr("DEADLINE_WINDOW", uint256(120));
        require(window != 0 && window <= config.maxDeadlineDelay, "INVALID_DEADLINE_WINDOW");
        return block.timestamp + window;
    }

    function _assertDrained(RobinhoodBoostedVault vault) internal view {
        IUniswapV4PairedAdapter.PositionState memory position =
            vault.liquidityAdapter().positionState(PAIR_ID);
        require(vault.accountedAssets(PAIR_ID, NVDA) == 0, "STOCK_NOT_DRAINED");
        require(vault.accountedAssets(PAIR_ID, USDG) == 0, "USDG_NOT_DRAINED");
        require(position.liquidity == 0, "POSITION_NOT_DRAINED");
        require(vault.lossReserve().available(PAIR_ID, NVDA) == 0, "STOCK_RESERVE_NOT_DRAINED");
        require(vault.lossReserve().available(PAIR_ID, USDG) == 0, "USDG_RESERVE_NOT_DRAINED");
        console2.log("canary drained", true);
    }

    function _printStatus(
        RobinhoodBoostedVault vault,
        RobinhoodBoostedVault.PairConfig memory config
    ) internal view {
        RobinhoodBoostedVault.PairLedger memory pairLedger = vault.ledger(PAIR_ID);
        IUniswapV4PairedAdapter.PositionState memory position =
            vault.liquidityAdapter().positionState(PAIR_ID);
        console2.log("pair id");
        console2.logBytes32(PAIR_ID);
        console2.log("stock side", config.stockAccount);
        console2.log("USDG side", config.usdgAccount);
        console2.log("allocation paused", config.allocationPaused);
        console2.log("swaps paused", config.swapsPaused);
        console2.log("emergency mode", config.emergencyMode);
        console2.log("stock principal", pairLedger.stockPrincipal);
        console2.log("USDG principal", pairLedger.usdgPrincipal);
        console2.log("stock idle", pairLedger.stockIdle);
        console2.log("USDG idle", pairLedger.usdgIdle);
        console2.log("position liquidity", uint256(position.liquidity));
        console2.log("stock reserve", vault.lossReserve().available(PAIR_ID, NVDA));
        console2.log("USDG reserve", vault.lossReserve().available(PAIR_ID, USDG));
    }
}
