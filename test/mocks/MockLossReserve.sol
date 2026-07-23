// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStrategyLossReserve } from "../../src/interfaces/IStrategyLossReserve.sol";

contract MockLossReserve is IStrategyLossReserve {
    using SafeERC20 for IERC20;
    mapping(bytes32 => mapping(address => uint256)) public balance;

    function deposit(bytes32 pairId, address token, uint256 amount)
        external
        returns (uint256 received)
    {
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        received = asset.balanceOf(address(this)) - beforeBalance;
        balance[pairId][token] += received;
    }

    function cover(bytes32 pairId, address token, uint256 requested, uint256, uint256)
        external
        returns (uint256 covered)
    {
        covered = Math.min(requested, balance[pairId][token]);
        balance[pairId][token] -= covered;
        IERC20(token).safeTransfer(msg.sender, covered);
    }

    function available(bytes32 pairId, address token) external view returns (uint256) {
        return balance[pairId][token];
    }
}
