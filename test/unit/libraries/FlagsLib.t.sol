// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test, console2, stdError } from "forge-std/Test.sol";

import { FlagsLib } from "src/libraries/FlagsLib.sol";

contract FlagsLibTest is Test {
    using FlagsLib for bytes32;
    using FlagsLib for int256;

    function testIsCompositeRoute() external {
        // arrange
        bytes32 lUninitialized = FlagsLib.FLAG_UNINITIALIZED;
        bytes32 l1HopRoute = FlagsLib.FLAG_SIMPLE_PRICE;
        bytes32 l2HopRoute = FlagsLib.FLAG_2_HOP_ROUTE;
        bytes32 l3HopRoute = FlagsLib.FLAG_3_HOP_ROUTE;

        // act & assert
        assertTrue(l2HopRoute.isCompositeRoute());
        assertTrue(l3HopRoute.isCompositeRoute());
        assertFalse(lUninitialized.isCompositeRoute());
        assertFalse(l1HopRoute.isCompositeRoute());
    }

    function testGetDecimalDifference() external {
        // arrange
        bytes32 lPositive = hex"0012";
        bytes32 lNegative = hex"00ee";
        bytes32 lZero = hex"0000";

        // act & assert
        assertEq(lPositive.getDecimalDifference(), 18);
        assertEq(lNegative.getDecimalDifference(), -18);
        assertEq(lZero.getDecimalDifference(), 0);
    }

    function testCombine(int8 aDiff) external {
        // act
        bytes32 lResult = FlagsLib.FLAG_SIMPLE_PRICE.combine(aDiff);

        // assert
        assertEq(lResult[0], hex"01");
        assertEq(lResult[1], bytes1(uint8(aDiff)));
    }
}
