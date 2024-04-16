// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ReservoirPriceCache, IReservoirPriceOracle } from "src/ReservoirPriceCache.sol";

contract ReservoirPriceCacheTest is Test {
    ReservoirPriceCache internal _priceCache = new ReservoirPriceCache(address(0), 0.02e18, 15 minutes, 2e18);

    event Oracle(address newOracle);
    event RewardMultiplier(uint256 newMultiplier);
    event Route(address token0, address token1, address[] route);

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

    function testGetQuote() external { }

    function testGetQuote_Null() external {
        // act & assert
        vm.expectRevert(); // TODO: use specific error
        _priceCache.getQuote(123, address(123), address(456));
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

    function testUpdateOracle_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _priceCache.updateOracle(address(345));
    }

    function testUpdatePriceDeviationThreshold() external { }
    function testUpdateTwapPeriod() external { }

    function testUpdateRewardMultiplier() external {
        // arrange
        uint64 lNewRewardMultiplier = 50;

        // act
        vm.expectEmit(false, false, false, false);
        emit RewardMultiplier(lNewRewardMultiplier);
        _priceCache.updateRewardMultiplier(lNewRewardMultiplier);

        // assert
        assertEq(_priceCache.rewardMultiplier(), lNewRewardMultiplier);
    }

    function testUpdateRewardMultiplier_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _priceCache.updateRewardMultiplier(111);
    }

    function testUpdatePrice_BeyondThreshold() external { }
    function testUpdatePrice_WithinThreshold() external { }

    function testSetRoute() public {
        // arrange
        address lToken0 = address(0x1);
        address lToken1 = address(0x2);
        address[] memory lRoute = new address[](2);
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;

        // act
        vm.expectEmit(false, false, false, false);
        emit Route(lToken0, lToken1, lRoute);
        _priceCache.setRoute(lToken0, lToken1, lRoute);

        // assert
        address[] memory lQueriedRoute = _priceCache.route(lToken0, lToken1);
        assertEq(lQueriedRoute, lRoute);
    }

    function testSetRoute_OverwriteExisting() external {
        // arrange
        testSetRoute();
        address lToken0 = address(0x1);
        address lToken1 = address(0x2);
        address[] memory lRoute = new address[](4);
        lRoute[0] = lToken0;
        lRoute[1] = address(5);
        lRoute[2] = address(6);
        lRoute[3] = lToken1;

        // act
        _priceCache.setRoute(lToken0, lToken1, lRoute);

        // assert
        address[] memory lQueriedRoute = _priceCache.route(lToken0, lToken1);
        assertEq(lQueriedRoute, lRoute);
        assertEq(lQueriedRoute.length, 4);
    }

    function testSetRoute_SameToken() external {
        // arrange
        address lToken0 = address(0x1);
        address lToken1 = address(0x1);
        address[] memory lRoute = new address[](2);
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;

        // act & assert
        vm.expectRevert(ReservoirPriceCache.RPC_SAME_TOKEN.selector);
        _priceCache.setRoute(lToken0, lToken1, lRoute);
    }

    function testSetRoute_NotSorted() external {
        // arrange
        address lToken0 = address(0x21);
        address lToken1 = address(0x2);
        address[] memory lRoute = new address[](2);
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;

        // act & assert
        vm.expectRevert(ReservoirPriceCache.RPC_TOKENS_UNSORTED.selector);
        _priceCache.setRoute(lToken0, lToken1, lRoute);
    }

    function testSetRoute_InvalidRouteLength() external {
        // arrange
        address lToken0 = address(0x1);
        address lToken1 = address(0x2);
        address[] memory lTooLong = new address[](5);
        lTooLong[0] = lToken0;
        lTooLong[1] = address(0);
        lTooLong[2] = address(0);
        lTooLong[3] = address(0);
        lTooLong[4] = lToken1;
        address[] memory lTooShort = new address[](1);
        lTooShort[0] = lToken0;

        // act & assert
        vm.expectRevert(ReservoirPriceCache.RPC_INVALID_ROUTE_LENGTH.selector);
        _priceCache.setRoute(lToken0, lToken1, lTooLong);

        // act & assert
        vm.expectRevert(ReservoirPriceCache.RPC_INVALID_ROUTE_LENGTH.selector);
        _priceCache.setRoute(lToken0, lToken1, lTooShort);
    }

    function testSetRoute_InvalidRoute() external {
        // arrange
        address lToken0 = address(0x1);
        address lToken1 = address(0x2);
        address[] memory lRoute = new address[](3);
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;
        lRoute[2] = address(0);

        // act & assert
        vm.expectRevert(ReservoirPriceCache.RPC_INVALID_ROUTE.selector);
        _priceCache.setRoute(lToken0, lToken1, lRoute);
    }

    function testClearRoute() external {
        // arrange
        address lToken0 = address(0x1);
        address lToken1 = address(0x2);
        address[] memory lRoute = new address[](2);
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;
        _priceCache.setRoute(lToken0, lToken1, lRoute);
        address[] memory lQueriedRoute = _priceCache.route(lToken0, lToken1);
        assertEq(lQueriedRoute, lRoute);

        // act
        vm.expectEmit(false, false, false, false);
        emit Route(lToken0, lToken1, new address[](0));
        _priceCache.clearRoute(lToken0, lToken1);

        // assert
        lQueriedRoute = _priceCache.route(lToken0, lToken1);
        assertEq(lQueriedRoute, new address[](0));
    }
}
