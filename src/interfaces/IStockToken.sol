// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStockToken {
    function oraclePaused() external view returns (bool);
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}
