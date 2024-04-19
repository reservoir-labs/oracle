// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { BaseTest, console2, ReservoirPair } from "test/__fixtures/BaseTest.t.sol";

import { Buffer } from "src/ReservoirPriceOracle.sol";

contract ReservoirPriceOracleTest is BaseTest {
    event Route(address token0, address token1, ReservoirPair pair);

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

    function testSetPairForRoute() external {
        // act
        vm.expectEmit(false, false, false, true);
        emit Route(address(_tokenA), address(_tokenB), _pair);
        _oracle.setPairForRoute(address(_tokenA), address(_tokenB), _pair);

        // assert
        assertEq(address(_oracle.pairs(address(_tokenA), address(_tokenB))), address(_pair));
    }

    function testSetPairForRoute_TokenOrderReversed() external {
        // act
        _oracle.setPairForRoute(address(_tokenB), address(_tokenA), _pair);

        // assert
        assertEq(address(_oracle.pairs(address(_tokenA), address(_tokenB))), address(_pair));
        assertEq(address(_oracle.pairs(address(_tokenB), address(_tokenA))), address(0));
    }

    function testClearRoute() external {
        // arrange
        _oracle.setPairForRoute(address(_tokenA), address(_tokenB), _pair);

        // act
        vm.expectEmit(false, false, false, true);
        emit Route(address(_tokenA), address(_tokenB), ReservoirPair(address(0)));
        _oracle.clearRoute(address(_tokenA), address(_tokenB));

        // assert
        assertEq(address(_oracle.pairs(address(_tokenA), address(_tokenB))), address(0));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 ERROR CONDITIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testSetPairForRoute_IncorrectPair() external {
        // act & assert
        vm.expectRevert();
        _oracle.setPairForRoute(address(_tokenA), address(_tokenC), _pair);
    }

    function testSetPairForRoute_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _oracle.setPairForRoute(address(_tokenA), address(_tokenB), _pair);
    }

    function testClearRoute_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _oracle.clearRoute(address(_tokenA), address(_tokenB));
    }
}
