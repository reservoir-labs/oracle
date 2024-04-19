// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { BaseTest, console2, ReservoirPair } from "test/__fixtures/BaseTest.t.sol";

import { Buffer, Variable, OracleLatestQuery, OracleAccumulatorQuery } from "src/ReservoirPriceOracle.sol";

contract ReservoirPriceOracleTest is BaseTest {
    event Route(address token0, address token1, ReservoirPair pair);

    function testGetTimeWeightedAverage() external { }
    function testGetTimeWeightedAverage_Inverted() external { }

    function testGetLatest(uint32 aFastForward) public {
        // assume - latest price should always be the same no matter how much time has elapsed
        uint32 lFastForward = uint32(bound(aFastForward, 1, 2 ** 31 - 2));

        // arrange
        skip(lFastForward);
        _pair.sync();
        _oracle.setPairForRoute(address(_tokenA), address(_tokenB), _pair);

        // act
        uint256 lLatestPrice =
            _oracle.getLatest(OracleLatestQuery(Variable.RAW_PRICE, address(_tokenA), address(_tokenB)));

        // assert
        assertEq(lLatestPrice, 98_918_868_099_219_913_512);
    }

    function testGetLatest_Inverted(uint32 aFastForward) external {
        // arrange
        testGetLatest(aFastForward);

        // act
        uint256 lLatestPrice =
            _oracle.getLatest(OracleLatestQuery(Variable.RAW_PRICE, address(_tokenB), address(_tokenA)));

        // assert
        assertEq(lLatestPrice, 0.010109294811147218e18);
    }

    function testGetPastAccumulators() external {
        // arrange
        skip(1 hours);
        _pair.sync();
        skip(1 hours);
        _pair.sync();
        skip(1 hours);
        _pair.sync();
        _oracle.setPairForRoute(address(_tokenA), address(_tokenB), _pair);
        OracleAccumulatorQuery[] memory lQueries = new OracleAccumulatorQuery[](3);
        lQueries[0] = OracleAccumulatorQuery(Variable.RAW_PRICE, address(_tokenA), address(_tokenB), 0);
        lQueries[1] = OracleAccumulatorQuery(Variable.RAW_PRICE, address(_tokenA), address(_tokenB), 1 hours);
        lQueries[2] = OracleAccumulatorQuery(Variable.RAW_PRICE, address(_tokenA), address(_tokenB), 2 hours);

        // act
        int256[] memory lResults = _oracle.getPastAccumulators(lQueries);

        // assert
        assertEq(lResults.length, lQueries.length);
        vm.startPrank(address(_oracle));
        assertEq(lResults[0], _pair.observation(2).logAccRawPrice);
        assertEq(lResults[1], _pair.observation(1).logAccRawPrice);
        assertEq(lResults[2], _pair.observation(0).logAccRawPrice);
        vm.stopPrank();
    }

    function testGetPastAccumulators_Inverted() external {
        // arrange
        skip(1 hours);
        _pair.sync();
        skip(1 hours);
        _pair.sync();
        skip(1 hours);
        _pair.sync();
        _oracle.setPairForRoute(address(_tokenA), address(_tokenB), _pair);
        OracleAccumulatorQuery[] memory lQueries = new OracleAccumulatorQuery[](3);
        lQueries[0] = OracleAccumulatorQuery(Variable.RAW_PRICE, address(_tokenB), address(_tokenA), 0);
        lQueries[1] = OracleAccumulatorQuery(Variable.RAW_PRICE, address(_tokenB), address(_tokenA), 1 hours);
        lQueries[2] = OracleAccumulatorQuery(Variable.RAW_PRICE, address(_tokenB), address(_tokenA), 2 hours);

        // act
        int256[] memory lResults = _oracle.getPastAccumulators(lQueries);

        // assert
        assertEq(lResults.length, lQueries.length);
        vm.startPrank(address(_oracle));
        assertEq(lResults[0], -_pair.observation(2).logAccRawPrice);
        assertEq(lResults[1], -_pair.observation(1).logAccRawPrice);
        assertEq(lResults[2], -_pair.observation(0).logAccRawPrice);
        vm.stopPrank();
    }

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
