// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;
    bool public oraclePaused;
    uint16 public transferFeeBps;
    address public feeFrom;
    address public feeTo;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setOraclePaused(bool paused) external {
        oraclePaused = paused;
    }

    function setTransferFee(uint16 feeBps, address from, address to) external {
        require(feeBps <= 10_000, "FEE");
        transferFeeBps = feeBps;
        feeFrom = from;
        feeTo = to;
    }

    function _update(address from, address to, uint256 value) internal override {
        bool chargeFee = from != address(0) && to != address(0) && transferFeeBps != 0
            && (feeFrom == address(0) || feeFrom == from) && (feeTo == address(0) || feeTo == to);
        if (!chargeFee) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * transferFeeBps / 10_000;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, address(0), fee);
    }
}
