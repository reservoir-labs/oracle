// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { BaseTest, console2 } from "test/__fixtures/BaseTest.t.sol";

import { Buffer } from "src/ReservoirPriceOracle.sol";

contract ReservoirPriceOracleTest is BaseTest {
    function testGetTimeWeightedAverage() external { }
    function testGetTimeWeightedAverage_Inverted() external { }

    function testGetLatest() external { }
    function testGetLatest_Inverted() external { }

    function testGetPastAccumulator() external { }
    function testGetPastAccumulator_Inverted() external { }

    function testGetLargestSafeQueryWindow() external {
        // assert
        assertEq(_oracle.getLargestSafeQueryWindow(), Buffer.SIZE);
    }

    function testSetPairForRoute() external { }
}
