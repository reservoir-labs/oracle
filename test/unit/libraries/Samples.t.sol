// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test, console2, stdError } from "forge-std/Test.sol";

import { Samples, Observation, Variable } from "src/libraries/Samples.sol";


contract SamplesTest is Test {
    using Samples for Observation;

    function testInstant() external {
        // arrange
        Observation memory lObs = Observation(-123, -456, 3, 4, 5);

        // act
        int256 lInstantRawPrice = lObs.instant(Variable.RAW_PRICE);
        int256 lInstantClampedPrice = lObs.instant(Variable.CLAMPED_PRICE);

        // assert
        assertEq(lInstantRawPrice, -123);
        assertEq(lInstantClampedPrice, -456);
    }

    function testInstant_BadVariableRequest() external {
        // would like to test the revert behavior when passing an invalid enum
        // but solidity has a check to prevent casting a uint that is out of range of the enum
        vm.expectRevert(stdError.enumConversionError);
        Variable lInvalid = Variable(uint(5));
    }

    function testAccumulator() external {
        // arrange
        Observation memory lObs = Observation(-789, -569, -401, -1238, 5);

        // act
        int256 lAccRawPrice = lObs.accumulator(Variable.RAW_PRICE);
        int256 lAccClampedPrice = lObs.accumulator(Variable.CLAMPED_PRICE);

        // assert
        assertEq(lAccRawPrice, -401);
        assertEq(lAccClampedPrice, -1238);
    }

    function testAccumulator_BadVariableRequest() external {
        // would like to test the revert behavior when passing an invalid enum
        // but solidity has a check to prevent casting a uint that is out of range of the enum
        vm.expectRevert(stdError.enumConversionError);
        Variable lInvalid = Variable(uint(5));
    }
}
