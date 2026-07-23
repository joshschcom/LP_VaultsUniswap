// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategyLossReserve {
    function deposit(bytes32 pairId, address token, uint256 amount)
        external
        returns (uint256 received);

    function cover(
        bytes32 pairId,
        address token,
        uint256 requested,
        uint256 requestedValueUSDG,
        uint256 realizedDeficitUSDG
    ) external returns (uint256 covered);

    function available(bytes32 pairId, address token) external view returns (uint256);
}
