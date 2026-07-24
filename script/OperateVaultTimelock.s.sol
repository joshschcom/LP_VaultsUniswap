// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

/// @notice Schedules, executes, cancels, or inspects one timelock operation.
/// @dev TIMELOCK_SALT is required so every reviewed operation has an explicit unique identifier.
contract OperateVaultTimelock is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external {
        if (block.chainid != ROBINHOOD_CHAIN_ID) revert("WRONG_CHAIN");

        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        require(address(timelock).code.length != 0, "TIMELOCK_NOT_CONTRACT");

        address target = vm.envAddress("TIMELOCK_TARGET");
        uint256 value = vm.envOr("TIMELOCK_VALUE", uint256(0));
        bytes memory data = vm.envBytes("TIMELOCK_CALLDATA");
        bytes32 predecessor = vm.envOr("TIMELOCK_PREDECESSOR", bytes32(0));
        bytes32 salt = vm.envBytes32("TIMELOCK_SALT");
        bytes32 operationId = timelock.hashOperation(target, value, data, predecessor, salt);
        bytes32 action = keccak256(bytes(vm.envString("TIMELOCK_ACTION")));

        require(target != address(0) && data.length >= 4, "INVALID_TIMELOCK_CALL");

        if (action == keccak256("status")) {
            _printStatus(timelock, operationId);
            return;
        }

        uint256 actorKey = vm.envUint("ACTION_PRIVATE_KEY");
        address actor = vm.addr(actorKey);

        if (action == keccak256("schedule")) {
            uint256 delay = vm.envOr("TIMELOCK_DELAY", timelock.getMinDelay());
            require(delay >= timelock.getMinDelay(), "DELAY_BELOW_MINIMUM");
            require(timelock.hasRole(timelock.PROPOSER_ROLE(), actor), "ACTOR_NOT_PROPOSER");

            vm.startBroadcast(actorKey);
            timelock.schedule(target, value, data, predecessor, salt, delay);
            vm.stopBroadcast();
        } else if (action == keccak256("execute")) {
            require(timelock.hasRole(timelock.EXECUTOR_ROLE(), actor), "ACTOR_NOT_EXECUTOR");
            require(timelock.isOperationReady(operationId), "OPERATION_NOT_READY");

            vm.startBroadcast(actorKey);
            timelock.execute{ value: value }(target, value, data, predecessor, salt);
            vm.stopBroadcast();
        } else if (action == keccak256("cancel")) {
            require(timelock.hasRole(timelock.CANCELLER_ROLE(), actor), "ACTOR_NOT_CANCELLER");
            require(timelock.isOperationPending(operationId), "OPERATION_NOT_PENDING");

            vm.startBroadcast(actorKey);
            timelock.cancel(operationId);
            vm.stopBroadcast();
        } else {
            revert("UNKNOWN_TIMELOCK_ACTION");
        }

        _printStatus(timelock, operationId);
    }

    function _printStatus(TimelockController timelock, bytes32 operationId) internal view {
        console2.log("Operation id");
        console2.logBytes32(operationId);
        console2.log("Operation state", uint256(timelock.getOperationState(operationId)));
        console2.log("Ready at", timelock.getTimestamp(operationId));
        console2.log("Current timestamp", block.timestamp);
        console2.log("Minimum delay seconds", timelock.getMinDelay());
    }
}
