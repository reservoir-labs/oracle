// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Test, console2, stdError } from "forge-std/Test.sol";

import { RoutesLib } from "src/libraries/RoutesLib.sol";
import { Constants } from "src/libraries/Constants.sol";

contract RoutesLibTest is Test {
    using RoutesLib for bytes32;
    using RoutesLib for int256;

    function testIsCompositeRoute() external pure {
        // arrange
        bytes32 lUninitialized = RoutesLib.FLAG_UNINITIALIZED;
        bytes32 l1HopRoute = RoutesLib.FLAG_SIMPLE_PRICE;
        bytes32 l2HopRoute = RoutesLib.FLAG_2_HOP_ROUTE;
        bytes32 l3HopRoute = RoutesLib.FLAG_3_HOP_ROUTE;

        // act & assert
        assertTrue(l2HopRoute.isCompositeRoute());
        assertTrue(l3HopRoute.isCompositeRoute());
        assertFalse(lUninitialized.isCompositeRoute());
        assertFalse(l1HopRoute.isCompositeRoute());
    }

    function testGetDecimalDifference() external pure {
        // arrange
        bytes32 lPositive = hex"0012";
        bytes32 lNegative = hex"00ee";
        bytes32 lZero = hex"0000";

        // act & assert
        assertEq(lPositive.getDecimalDifference(), 18);
        assertEq(lNegative.getDecimalDifference(), -18);
        assertEq(lZero.getDecimalDifference(), 0);
    }

    function testPackSimplePrice(int8 aDiff, uint256 aPrice) external pure {
        // assume
        uint256 lPrice = bound(aPrice, 1, Constants.MAX_SUPPORTED_PRICE);

        // act
        bytes32 lResult = int256(aDiff).packSimplePrice(lPrice, Constants.BP_SCALE);

        // assert
        assertEq(lResult[0], RoutesLib.FLAG_SIMPLE_PRICE);
        assertEq(lResult[1], bytes1(uint8(aDiff)));
        assertEq(lResult.getRewardThreshold(), Constants.BP_SCALE);
        assertEq(lResult.getPrice(), lPrice);
    }
}
