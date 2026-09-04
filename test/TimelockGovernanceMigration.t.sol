// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Stands in for the incoming governance multisig. Only its having code matters here.
contract MultisigStub {
    function noop() external pure returns (bool) {
        return true;
    }
}

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

/**
 * @notice Proves the two-phase governance migration leaves the timelock controllable by the
 *         multisig and uncontrollable by the outgoing EOA, with no window where it is
 *         controllable by neither.
 */
contract TimelockGovernanceMigrationTest is Test {
    uint256 internal constant DELAY = 1 hours;

    address internal outgoing = makeAddr("outgoingGovernor");
    address internal multisig;
    TimelockController internal timelock;
    TimelockOwnedTarget internal target;

    bytes32 internal PROPOSER;
    bytes32 internal CANCELLER;
    bytes32 internal EXECUTOR;

    function setUp() external {
        multisig = address(new MultisigStub());
        address[] memory proposers = new address[](1);
        proposers[0] = outgoing;
        address[] memory executors = new address[](1);
        executors[0] = outgoing;
        // Mirrors mainnet: one EOA holds every operational role, the timelock administers
        // itself, and there is no external admin.
        timelock = new TimelockController(DELAY, proposers, executors, address(0));
        target = new TimelockOwnedTarget(address(timelock));
        PROPOSER = timelock.PROPOSER_ROLE();
        CANCELLER = timelock.CANCELLER_ROLE();
        EXECUTOR = timelock.EXECUTOR_ROLE();
    }

    function testRolesCanOnlyChangeThroughTheTimelockItself() external {
        vm.prank(outgoing);
        vm.expectRevert();
        timelock.grantRole(PROPOSER, multisig);

        assertFalse(timelock.hasRole(PROPOSER, multisig));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), outgoing));
    }

    function testGrantThenRevokeLeavesOnlyTheMultisigInControl() external {
        _grantPhase();

        // Both governors hold the roles between the phases, so control is never empty.
        assertTrue(timelock.hasRole(PROPOSER, multisig));
        assertTrue(timelock.hasRole(PROPOSER, outgoing));

        _revokePhase();

        assertTrue(timelock.hasRole(PROPOSER, multisig));
        assertTrue(timelock.hasRole(CANCELLER, multisig));
        assertTrue(timelock.hasRole(EXECUTOR, multisig));
        assertFalse(timelock.hasRole(PROPOSER, outgoing));
        assertFalse(timelock.hasRole(CANCELLER, outgoing));
        assertFalse(timelock.hasRole(EXECUTOR, outgoing));

        // The multisig can still drive the system end to end.
        bytes memory call = abi.encodeCall(TimelockOwnedTarget.setValue, (42));
        vm.prank(multisig);
        timelock.schedule(address(target), 0, call, bytes32(0), bytes32("live"), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(multisig);
        timelock.execute(address(target), 0, call, bytes32(0), bytes32("live"));
        assertEq(target.value(), 42);
    }

    function testOutgoingGovernorCannotScheduleAfterMigration() external {
        _grantPhase();
        _revokePhase();

        bytes memory call = abi.encodeCall(TimelockOwnedTarget.setValue, (7));
        vm.prank(outgoing);
        vm.expectRevert();
        timelock.schedule(address(target), 0, call, bytes32(0), bytes32("nope"), DELAY);
    }

    /// @dev The failure the two-phase split exists to prevent: revoking before granting
    ///      leaves no proposer, and every proxy the timelock owns is frozen permanently.
    function testRevokingBeforeGrantingWouldStrandTheTimelock() external {
        _selfCall(abi.encodeCall(IAccessControl.revokeRole, (PROPOSER, outgoing)), "early");
        assertFalse(timelock.hasRole(PROPOSER, outgoing));
        assertFalse(timelock.hasRole(PROPOSER, multisig));

        bytes memory call = abi.encodeCall(TimelockOwnedTarget.setValue, (1));
        vm.prank(outgoing);
        vm.expectRevert();
        timelock.schedule(address(target), 0, call, bytes32(0), bytes32("dead"), DELAY);
        vm.prank(multisig);
        vm.expectRevert();
        timelock.schedule(address(target), 0, call, bytes32(0), bytes32("dead"), DELAY);
    }

    function testDelayIncreaseAppliesToLaterOperationsOnly() external {
        _grantPhase();
        _selfCall(abi.encodeCall(TimelockController.updateDelay, (2 days)), "delay");
        assertEq(timelock.getMinDelay(), 2 days);

        bytes memory call = abi.encodeCall(TimelockOwnedTarget.setValue, (9));
        vm.prank(multisig);
        vm.expectRevert();
        timelock.schedule(address(target), 0, call, bytes32(0), bytes32("short"), DELAY);
    }

    function testOpenExecutorLetsAnyoneExecuteAnAlreadyDelayedOperation() external {
        _grantPhase();
        _selfCall(abi.encodeCall(IAccessControl.grantRole, (EXECUTOR, address(0))), "open");

        bytes memory call = abi.encodeCall(TimelockOwnedTarget.setValue, (5));
        vm.prank(multisig);
        timelock.schedule(address(target), 0, call, bytes32(0), bytes32("open"), DELAY);
        vm.warp(block.timestamp + DELAY);

        // A bystander can execute, so a hostile proposer cannot also withhold execution.
        vm.prank(makeAddr("bystander"));
        timelock.execute(address(target), 0, call, bytes32(0), bytes32("open"));
        assertEq(target.value(), 5);
    }

    function _grantPhase() internal {
        _selfCall(abi.encodeCall(IAccessControl.grantRole, (PROPOSER, multisig)), "g1");
        _selfCall(abi.encodeCall(IAccessControl.grantRole, (CANCELLER, multisig)), "g2");
        _selfCall(abi.encodeCall(IAccessControl.grantRole, (EXECUTOR, multisig)), "g3");
    }

    function _revokePhase() internal {
        _selfCall(abi.encodeCall(IAccessControl.revokeRole, (PROPOSER, outgoing)), "r1");
        _selfCall(abi.encodeCall(IAccessControl.revokeRole, (CANCELLER, outgoing)), "r2");
        _selfCall(abi.encodeCall(IAccessControl.revokeRole, (EXECUTOR, outgoing)), "r3");
    }

    /// @dev Schedules and executes a timelock self-call, the only way role and delay changes
    ///      can happen on a self-administered timelock with no external admin.
    function _selfCall(bytes memory data, bytes32 salt) internal {
        uint256 delay = timelock.getMinDelay();
        vm.prank(timelock.hasRole(PROPOSER, outgoing) ? outgoing : multisig);
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(timelock.hasRole(EXECUTOR, outgoing) ? outgoing : multisig);
        timelock.execute(address(timelock), 0, data, bytes32(0), salt);
    }
}
