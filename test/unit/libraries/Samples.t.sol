// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Test, console2, stdError } from "forge-std/Test.sol";

import { Samples, Observation, PriceType } from "src/libraries/Samples.sol";

contract SamplesTest is Test {
    using Samples for Observation;

    function testInstant() external pure {
        // arrange
        Observation memory lObs = Observation(-123, -456, 3, 4, 5);

        // act
        int256 lInstantRawPrice = lObs.instant(PriceType.RAW_PRICE);
        int256 lInstantClampedPrice = lObs.instant(PriceType.CLAMPED_PRICE);

        // assert
        assertEq(lInstantRawPrice, -123);
        assertEq(lInstantClampedPrice, -456);
    }

    function testAccumulator() external pure {
        // arrange
        Observation memory lObs = Observation(-789, -569, -401, -1238, 5);

        // act
        int256 lAccRawPrice = lObs.accumulator(PriceType.RAW_PRICE);
        int256 lAccClampedPrice = lObs.accumulator(PriceType.CLAMPED_PRICE);

        // assert
        assertEq(lAccRawPrice, -401);
        assertEq(lAccClampedPrice, -1238);
    }
}
