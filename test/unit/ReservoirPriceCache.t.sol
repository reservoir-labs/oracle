// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ReservoirPriceCache, IReservoirPriceOracle } from "src/ReservoirPriceCache.sol";

contract ReservoirPriceCacheTest is Test {
    ReservoirPriceCache internal _priceCache =
        new ReservoirPriceCache(IReservoirPriceOracle(address(0)), 0.02e18, 15 minutes, 2e18);

    event Oracle(address newOracle);

    function testIsPriceUpdateIncentivized(uint256 aBountyAmount) external {
        // assume
        uint256 lBounty = bound(aBountyAmount, 1, type(uint256).max);

        // arrange
        deal(address(_priceCache), lBounty);

        // act & assert
        assertTrue(_priceCache.isPriceUpdateIncentivized());
    }

    function testIsPriceUpdateIncentivized_Zero() external {
        // sanity
        assertEq(address(_priceCache).balance, 0);

        // act & assert
        assertFalse(_priceCache.isPriceUpdateIncentivized());
    }

    function testGasBountyAvailable() external { }
    function testGasBountyAvailable_Zero() external {
        // sanity
        assertEq(address(_priceCache).balance, 0);

        // act & assert
        assertEq(_priceCache.gasBountyAvailable(), 0);
    }

    function testGetPriceForPair() external { }
    function testGetPriceForPair_Null() external {
        // assert
        assertEq(_priceCache.getPriceForPair(address(123)), 0);
    }

    function testUpdateOracle() external {
        // arrange
        address lNewOracleAddress = address(3);

        // act
        vm.expectEmit(false, false, false, false);
        emit Oracle(lNewOracleAddress);
        _priceCache.updateOracle(lNewOracleAddress);

        // assert
        assertEq(address(_priceCache.oracle()), lNewOracleAddress);
    }

    function testUpdateOracle_OnlyOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _priceCache.updateOracle(address(345));
    }

    function testUpdatePriceDeviationThreshold() external { }
    function testUpdateTwapPeriod() external { }
    function testUpdateRewardMultiplier() external { }

    function testUpdatePrice_BeyondThreshold() external { }
    function testUpdatePrice_WithinThreshold() external { }
}
