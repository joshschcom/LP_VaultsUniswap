// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { VaultMath } from "../src/libraries/VaultMath.sol";

contract VaultMathHarness {
    function value(uint256 tokenAmount, uint8 decimals, uint256 price)
        external
        pure
        returns (uint256)
    {
        return VaultMath.valueUSD18(tokenAmount, decimals, price, Math.Rounding.Floor);
    }

    function amount(uint256 valueUSD18, uint8 decimals, uint256 price)
        external
        pure
        returns (uint256)
    {
        return VaultMath.amountFromValueUSD18(valueUSD18, decimals, price, Math.Rounding.Floor);
    }

    function quote(int24 tick, uint128 baseAmount, address base, address quoteToken)
        external
        pure
        returns (uint256)
    {
        return VaultMath.quoteAtTick(tick, baseAmount, base, quoteToken);
    }

    function amountsForLiquidity(uint160 price, uint160 lower, uint160 upper, uint128 liquidity)
        external
        pure
        returns (uint256, uint256)
    {
        return VaultMath.amountsForLiquidity(price, lower, upper, liquidity);
    }
}

contract VaultMathTest is Test {
    VaultMathHarness internal harness = new VaultMathHarness();

    function testValueRejectsZeroPrice() external {
        vm.expectRevert(VaultMath.InvalidPrice.selector);
        harness.value(1e18, 18, 0);
    }

    function testAmountRejectsZeroPrice() external {
        vm.expectRevert(VaultMath.InvalidPrice.selector);
        harness.amount(1e18, 18, 0);
    }

    function testQuoteRejectsIdenticalTokens() external {
        address token = makeAddr("token");
        vm.expectRevert(VaultMath.IdenticalTokens.selector);
        harness.quote(0, 1e18, token, token);
    }

    function testLiquidityAmountsRejectZeroSqrtPrice() external {
        vm.expectRevert(VaultMath.InvalidPrice.selector);
        harness.amountsForLiquidity(0, 1, 2, 1);
    }

    function testValueAvoidsIntermediateScalingOverflow() external view {
        uint256 amount = type(uint256).max / 1e18 + 1;
        assertEq(harness.value(amount, 0, 1), amount);
    }
}
