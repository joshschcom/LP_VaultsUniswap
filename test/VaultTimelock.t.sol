// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Test } from "forge-std/Test.sol";

import { StockOracleGuard } from "../src/StockOracleGuard.sol";
import { PeridotTransparentProxy } from "../src/proxy/PeridotTransparentProxy.sol";
import { MockPoolManagerState } from "./mocks/MockUniswapComponents.sol";

contract TimelockOwnedTarget {
    error Unauthorized();

    address public immutable owner;
    uint256 public value;

    constructor(address owner_) {
        owner = owner_;
    }

    function setValue(uint256 newValue) external {
        if (msg.sender != owner) revert Unauthorized();
        value = newValue;
    }
}

contract VaultTimelockTest is Test {
    uint256 internal constant DELAY = 1 hours;
    bytes32 internal constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal proposer = makeAddr("proposer");
    address internal executor = makeAddr("executor");
    TimelockController internal timelock;
    TimelockOwnedTarget internal target;

    function setUp() external {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));
        target = new TimelockOwnedTarget(address(timelock));
    }

    function testTopologyHasNoExternalAdminBypass() external view {
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        assertEq(timelock.getMinDelay(), DELAY);
        assertTrue(timelock.hasRole(adminRole, address(timelock)));
        assertFalse(timelock.hasRole(adminRole, proposer));
        assertFalse(timelock.hasRole(adminRole, executor));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor));
    }

    function testSingleEoaCanBeProposerCancellerAndExecutorWithoutAdminBypass() external {
        address actor = makeAddr("single-eoa");
        address[] memory actors = new address[](1);
        actors[0] = actor;
        TimelockController singleActorTimelock =
            new TimelockController(DELAY, actors, actors, address(0));

        assertTrue(singleActorTimelock.hasRole(singleActorTimelock.PROPOSER_ROLE(), actor));
        assertTrue(singleActorTimelock.hasRole(singleActorTimelock.CANCELLER_ROLE(), actor));
        assertTrue(singleActorTimelock.hasRole(singleActorTimelock.EXECUTOR_ROLE(), actor));
        assertFalse(singleActorTimelock.hasRole(singleActorTimelock.DEFAULT_ADMIN_ROLE(), actor));
    }

    function testTimelockOwnsProxyAdminAndImplementationRolesFromGenesis() external {
        MockPoolManagerState poolManager = new MockPoolManagerState();
        StockOracleGuard implementation = new StockOracleGuard();
        bytes memory initialization = abi.encodeCall(
            StockOracleGuard.initialize, (address(timelock), IPoolManager(address(poolManager)))
        );
        PeridotTransparentProxy proxy =
            new PeridotTransparentProxy(address(implementation), address(timelock), initialization);
        StockOracleGuard guard = StockOracleGuard(address(proxy));
        bytes32 configRole = guard.CONFIG_ROLE();

        assertTrue(guard.hasRole(guard.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(guard.hasRole(configRole, address(timelock)));
        assertFalse(guard.hasRole(guard.DEFAULT_ADMIN_ROLE(), proposer));
        assertFalse(guard.hasRole(configRole, proposer));

        bytes32 storedAdmin = vm.load(address(proxy), ERC1967_ADMIN_SLOT);
        address proxyAdmin = address(uint160(uint256(storedAdmin)));
        assertEq(ProxyAdmin(proxyAdmin).owner(), address(timelock));

        address additionalConfigActor = makeAddr("additional-config-actor");
        bytes memory data = abi.encodeWithSignature(
            "grantRole(bytes32,address)", configRole, additionalConfigActor
        );
        bytes32 predecessor;
        bytes32 salt = keccak256("grant-config-role");

        vm.prank(proposer);
        vm.expectRevert();
        guard.grantRole(configRole, additionalConfigActor);

        vm.prank(proposer);
        timelock.schedule(address(guard), 0, data, predecessor, salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(guard), 0, data, predecessor, salt);

        assertTrue(guard.hasRole(configRole, additionalConfigActor));
    }

    function testTargetCallRequiresScheduledDelay() external {
        bytes memory data = abi.encodeCall(TimelockOwnedTarget.setValue, (42));
        bytes32 predecessor;
        bytes32 salt = keccak256("set-value");

        vm.prank(proposer);
        vm.expectRevert(TimelockOwnedTarget.Unauthorized.selector);
        target.setValue(42);

        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, predecessor, salt, DELAY);

        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(target), 0, data, predecessor, salt);

        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(target), 0, data, predecessor, salt);

        assertEq(target.value(), 42);
    }

    function testDelayCanOnlyChangeThroughTimelock() external {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        bytes32 predecessor;
        bytes32 salt = keccak256("increase-delay");

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, proposer)
        );
        timelock.updateDelay(newDelay);

        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, data, predecessor, salt, DELAY);

        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(timelock), 0, data, predecessor, salt);

        assertEq(timelock.getMinDelay(), newDelay);
    }
}
