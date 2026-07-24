// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

/// @notice Deploys the self-administered timelock that owns the vault proxies and configuration.
/// @dev The optional TimelockController admin is deliberately disabled. Role changes and delay
///      changes must therefore pass through the timelock after deployment.
contract DeployVaultTimelock is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant MIN_INITIAL_DELAY = 1 hours;
    uint256 internal constant MAX_INITIAL_DELAY = 30 days;

    function run() external returns (TimelockController timelock) {
        if (block.chainid != ROBINHOOD_CHAIN_ID) revert("WRONG_CHAIN");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address proposer = vm.envOr("TIMELOCK_PROPOSER", deployer);
        address executor = vm.envOr("TIMELOCK_EXECUTOR", proposer);
        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");

        require(proposer != address(0) && executor != address(0), "ZERO_TIMELOCK_ACTOR");
        require(
            minDelay >= MIN_INITIAL_DELAY && minDelay <= MAX_INITIAL_DELAY, "INVALID_TIMELOCK_DELAY"
        );

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        vm.startBroadcast(deployerKey);
        timelock = new TimelockController(minDelay, proposers, executors, address(0));
        vm.stopBroadcast();

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        require(timelock.getMinDelay() == minDelay, "TIMELOCK_DELAY");
        require(timelock.hasRole(adminRole, address(timelock)), "TIMELOCK_NOT_SELF_ADMIN");
        require(!timelock.hasRole(adminRole, deployer), "DEPLOYER_ADMIN_BYPASS");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer), "MISSING_PROPOSER");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer), "MISSING_CANCELLER");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor), "MISSING_EXECUTOR");

        console2.log("Vault timelock", address(timelock));
        console2.log("Minimum delay seconds", minDelay);
        console2.log("Proposer / canceller", proposer);
        console2.log("Executor", executor);
        console2.log("External admin enabled", false);
    }
}
