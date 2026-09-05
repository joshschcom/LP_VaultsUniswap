// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract PeridotTransparentProxy is TransparentUpgradeableProxy {
    // ERC-7201 slot used by OpenZeppelin Initializable v5.
    bytes32 private constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    error InvalidProxyConfiguration();

    constructor(address logic, address initialOwner, bytes memory data)
        TransparentUpgradeableProxy(logic, _validatedOwner(initialOwner, data), data)
    {
        uint256 initialized;
        bytes32 slot = INITIALIZABLE_STORAGE;
        assembly ("memory-safe") {
            initialized := sload(slot)
        }
        if ((initialized & type(uint64).max) == 0) revert InvalidProxyConfiguration();
    }

    function _validatedOwner(address initialOwner, bytes memory data)
        private
        pure
        returns (address)
    {
        if (initialOwner == address(0) || data.length == 0) {
            revert InvalidProxyConfiguration();
        }
        return initialOwner;
    }
}
