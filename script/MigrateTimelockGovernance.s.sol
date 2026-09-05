// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

/**
 * @notice Prints the timelock self-call payloads that move proposer, canceller and executor
 *         from the bootstrap EOA to the approved multisig.
 * @dev The timelock is self-administered with no external admin, so every role change has to
 *      be scheduled and executed through the timelock itself.
 *
 *      Run in two phases, never as one batch.
 *
 *      `MIGRATION_PHASE=grant` prints the grants (and an optional delay increase). Execute
 *      those, then prove the multisig can schedule and execute something trivial.
 *
 *      `MIGRATION_PHASE=revoke` prints the revocations that remove the EOA. It refuses to
 *      print anything until the multisig already holds all three roles on-chain, so the
 *      sequence cannot be run backwards and leave the timelock with no proposer — which
 *      would permanently freeze every proxy this timelock owns.
 */
interface ISafeQuorum {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

contract MigrateTimelockGovernance is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant MAX_DELAY = 30 days;

    function run() external view {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "WRONG_CHAIN");
        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        require(address(timelock).code.length != 0, "TIMELOCK_NOT_CONTRACT");

        address multisig = vm.envAddress("GOVERNANCE_MULTISIG");
        address outgoing = vm.envAddress("OUTGOING_GOVERNOR");
        require(multisig != address(0) && outgoing != address(0), "ZERO_GOVERNOR");
        require(multisig != outgoing, "MULTISIG_IS_OUTGOING_GOVERNOR");
        // A bootstrap EOA is what this migration exists to remove. Requiring code here stops
        // the migration silently re-creating the same single-key trust assumption. Note that
        // a Safe address is chain-specific: one deployed on another chain has no code here,
        // and granting the roles to it would leave the timelock with a proposer that can
        // never propose.
        require(multisig.code.length != 0, "MULTISIG_NOT_CONTRACT");
        _requireRealQuorum(multisig, outgoing);

        bytes32 proposer = timelock.PROPOSER_ROLE();
        bytes32 canceller = timelock.CANCELLER_ROLE();
        bytes32 executor = timelock.EXECUTOR_ROLE();
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();

        // The payloads below are self-calls, which only work while the timelock administers
        // itself and no external admin can bypass the delay.
        require(timelock.hasRole(admin, address(timelock)), "TIMELOCK_NOT_SELF_ADMIN");
        require(!timelock.hasRole(admin, outgoing), "OUTGOING_HAS_ADMIN_BYPASS");
        require(!timelock.hasRole(admin, multisig), "MULTISIG_HAS_ADMIN_BYPASS");

        bytes32 phase = keccak256(bytes(vm.envString("MIGRATION_PHASE")));
        _printState(timelock, multisig, outgoing, proposer, canceller, executor);

        if (phase == keccak256("status")) return;
        if (phase == keccak256("grant")) {
            _printGrants(timelock, multisig, proposer, canceller, executor);
        } else if (phase == keccak256("revoke")) {
            _printRevocations(timelock, multisig, outgoing, proposer, canceller, executor);
        } else {
            revert("UNKNOWN_MIGRATION_PHASE");
        }
    }

    /**
     * @dev A 1-of-1 Safe owned by the outgoing governor is the same key with an extra hop, not
     *      a migration. Where the incoming governor answers the Safe interface, insist on a
     *      real quorum. Non-Safe governors (a DAO executor, a custom module) do not answer
     *      these calls and are allowed through, since this cannot verify their internals.
     */
    function _requireRealQuorum(address multisig, address outgoing) internal view {
        try ISafeQuorum(multisig).getThreshold() returns (uint256 threshold) {
            require(
                threshold >= 2 || vm.envOr("ALLOW_SINGLE_SIGNER", false), "SAFE_THRESHOLD_TOO_LOW"
            );
            try ISafeQuorum(multisig).getOwners() returns (address[] memory owners) {
                require(
                    owners.length >= 2 || vm.envOr("ALLOW_SINGLE_SIGNER", false),
                    "SAFE_TOO_FEW_OWNERS"
                );
                // A Safe whose only owner is the governor being removed changes nothing.
                if (owners.length == 1) require(owners[0] != outgoing, "SAFE_OWNED_BY_OUTGOING");
            } catch { }
        } catch {
            // Not a Safe. Nothing further can be checked from here.
        }
    }

    function _printGrants(
        TimelockController timelock,
        address multisig,
        bytes32 proposer,
        bytes32 canceller,
        bytes32 executor
    ) internal view {
        console2.log("PHASE 1 of 2: grant the multisig its roles.");
        console2.log("Chain each TIMELOCK_PREDECESSOR to the previous operation id.");
        console2.log("");

        uint256 n;
        if (!timelock.hasRole(proposer, multisig)) {
            _payload(
                ++n,
                "grant PROPOSER_ROLE to the multisig",
                address(timelock),
                abi.encodeCall(IAccessControl.grantRole, (proposer, multisig))
            );
        }
        if (!timelock.hasRole(canceller, multisig)) {
            _payload(
                ++n,
                "grant CANCELLER_ROLE to the multisig",
                address(timelock),
                abi.encodeCall(IAccessControl.grantRole, (canceller, multisig))
            );
        }
        if (!timelock.hasRole(executor, multisig)) {
            _payload(
                ++n,
                "grant EXECUTOR_ROLE to the multisig",
                address(timelock),
                abi.encodeCall(IAccessControl.grantRole, (executor, multisig))
            );
        }

        // An open executor lets anyone submit an already-reviewed, already-delayed operation,
        // so a proposer that turns hostile cannot also withhold execution. Opt in explicitly.
        if (vm.envOr("OPEN_EXECUTOR", false) && !timelock.hasRole(executor, address(0))) {
            _payload(
                ++n,
                "grant EXECUTOR_ROLE to address(0), making execution permissionless",
                address(timelock),
                abi.encodeCall(IAccessControl.grantRole, (executor, address(0)))
            );
        }

        uint256 newDelay = vm.envOr("NEW_MIN_DELAY", uint256(0));
        if (newDelay != 0) {
            uint256 current = timelock.getMinDelay();
            require(newDelay > current, "DELAY_NOT_AN_INCREASE");
            require(newDelay <= MAX_DELAY, "DELAY_ABOVE_MAX");
            // Raise the delay only once the multisig can act, or a mistake takes the longer
            // delay to correct.
            _payload(
                ++n,
                "raise the minimum delay",
                address(timelock),
                abi.encodeCall(TimelockController.updateDelay, (newDelay))
            );
        }

        require(n != 0, "NOTHING_TO_GRANT");
        console2.log("After executing these, prove the multisig can schedule AND execute a");
        console2.log("trivial operation before running MIGRATION_PHASE=revoke.");
    }

    function _printRevocations(
        TimelockController timelock,
        address multisig,
        address outgoing,
        bytes32 proposer,
        bytes32 canceller,
        bytes32 executor
    ) internal view {
        // The whole point of the two-phase split. Revoking first would leave the timelock
        // with no proposer and every proxy it owns frozen forever.
        require(
            timelock.hasRole(proposer, multisig) && timelock.hasRole(canceller, multisig)
                && timelock.hasRole(executor, multisig),
            "GRANT_PHASE_NOT_COMPLETE"
        );

        console2.log("PHASE 2 of 2: remove the outgoing governor.");
        console2.log("Only schedule these once the multisig has demonstrably scheduled and");
        console2.log("executed an operation, and no operation proposed by the outgoing");
        console2.log("governor is still pending.");
        console2.log("");

        uint256 n;
        if (timelock.hasRole(proposer, outgoing)) {
            _payload(
                ++n,
                "revoke PROPOSER_ROLE from the outgoing governor",
                address(timelock),
                abi.encodeCall(IAccessControl.revokeRole, (proposer, outgoing))
            );
        }
        if (timelock.hasRole(canceller, outgoing)) {
            _payload(
                ++n,
                "revoke CANCELLER_ROLE from the outgoing governor",
                address(timelock),
                abi.encodeCall(IAccessControl.revokeRole, (canceller, outgoing))
            );
        }
        if (timelock.hasRole(executor, outgoing)) {
            _payload(
                ++n,
                "revoke EXECUTOR_ROLE from the outgoing governor",
                address(timelock),
                abi.encodeCall(IAccessControl.revokeRole, (executor, outgoing))
            );
        }
        require(n != 0, "NOTHING_TO_REVOKE");
    }

    function _printState(
        TimelockController timelock,
        address multisig,
        address outgoing,
        bytes32 proposer,
        bytes32 canceller,
        bytes32 executor
    ) internal view {
        console2.log("timelock", address(timelock));
        console2.log("minimum delay seconds", timelock.getMinDelay());
        console2.log("incoming multisig", multisig);
        console2.log("  proposer / canceller / executor:");
        console2.log("   ", timelock.hasRole(proposer, multisig));
        console2.log("   ", timelock.hasRole(canceller, multisig));
        console2.log("   ", timelock.hasRole(executor, multisig));
        console2.log("outgoing governor", outgoing);
        console2.log("  proposer / canceller / executor:");
        console2.log("   ", timelock.hasRole(proposer, outgoing));
        console2.log("   ", timelock.hasRole(canceller, outgoing));
        console2.log("   ", timelock.hasRole(executor, outgoing));
        console2.log("execution permissionless", timelock.hasRole(executor, address(0)));
        console2.log("");
    }

    function _payload(uint256 index, string memory label, address target, bytes memory data)
        internal
        pure
    {
        console2.log(index, label);
        console2.log("   target", target);
        console2.log("   value", uint256(0));
        console2.log("   calldata");
        console2.logBytes(data);
        console2.log("");
    }
}
