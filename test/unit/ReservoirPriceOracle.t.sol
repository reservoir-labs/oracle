// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test, console2 } from "forge-std/Test.sol";

import { ReservoirPriceOracle, Buffer } from "src/ReservoirPriceOracle.sol";

contract ReservoirPriceOracleTest is Test {
    ReservoirPriceOracle internal _oracle = new ReservoirPriceOracle();

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
