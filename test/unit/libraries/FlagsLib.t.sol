// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test, console2, stdError } from "forge-std/Test.sol";

import { FlagsLib } from "src/libraries/FlagsLib.sol";

contract FlagsLibTest is Test {
    using FlagsLib for bytes32;
    using FlagsLib for int256;

    function testGetDecimalDifference() external {
        bytes32 lPositive = hex"1f";
        bytes32 lNegative = hex"3f";

        assertEq(lPositive.getDecimalDifference(), 31);
        assertEq(lNegative.getDecimalDifference(), -31);
    }

    function testPackDecimalDifference(int256 aDiff) external {
        // arrange
        int256 lDiff = bound(aDiff, -18, 18);

        // act
        bytes32 lPacked = lDiff.packDecimalDifference();

        // assert
        assertEq(lDiff, lPacked.getDecimalDifference());
    }

    function testPackDecimalDifference_BeyondRange() external {
        // arrange
        int256 lDiff = -20;

        // act & assert
        vm.expectRevert(FlagsLib.DECIMAL_DIFF_OUT_OF_RANGE.selector);
        lDiff.packDecimalDifference();
    }

    function testCombine() external { }
}
