// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { PeridotTransparentProxy } from "../src/proxy/PeridotTransparentProxy.sol";

contract ProxyInitializationTarget is Initializable {
    uint256 public value;

    function initialize(uint256 value_) external initializer {
        value = value_;
    }
}

contract PeridotTransparentProxyTest is Test {
    ProxyInitializationTarget internal implementation;

    function setUp() external {
        implementation = new ProxyInitializationTarget();
    }

    function testDeploymentRequiresInitializationCalldata() external {
        vm.expectRevert(PeridotTransparentProxy.InvalidProxyConfiguration.selector);
        new PeridotTransparentProxy(address(implementation), address(this), bytes(""));
    }

    function testDeploymentRequiresNonzeroOwner() external {
        bytes memory data = abi.encodeCall(ProxyInitializationTarget.initialize, (42));
        vm.expectRevert(PeridotTransparentProxy.InvalidProxyConfiguration.selector);
        new PeridotTransparentProxy(address(implementation), address(0), data);
    }

    function testDeploymentRejectsCalldataThatDoesNotInitialize() external {
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("value()")));
        vm.expectRevert(PeridotTransparentProxy.InvalidProxyConfiguration.selector);
        new PeridotTransparentProxy(address(implementation), address(this), data);
    }

    function testDeploymentInitializesAtomically() external {
        bytes memory data = abi.encodeCall(ProxyInitializationTarget.initialize, (42));
        PeridotTransparentProxy proxy =
            new PeridotTransparentProxy(address(implementation), address(this), data);

        assertEq(ProxyInitializationTarget(address(proxy)).value(), 42);
    }
}
