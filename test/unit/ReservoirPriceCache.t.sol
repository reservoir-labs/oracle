// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { BaseTest, console2 } from "test/__fixtures/BaseTest.t.sol";
import { ReservoirPriceCache, IReservoirPriceOracle, IPriceOracle } from "src/ReservoirPriceCache.sol";

import { Utils } from "src/libraries/Utils.sol";

contract ReservoirPriceCacheTest is BaseTest {
    using Utils for uint256;

    ReservoirPriceCache internal _priceCache = new ReservoirPriceCache(address(0), 0.02e18, 15 minutes, 2e18);

    event Oracle(address newOracle);
    event RewardMultiplier(uint256 newMultiplier);
    event Route(address token0, address token1, address[] route);

    // overwrites the cached prices, for easy testing
    function _writePriceCache(address aToken0, address aToken1, uint256 aPrice) internal {
        require(aToken0 < aToken1, "tokens unsorted");
        vm.record();
        _priceCache.priceCache(aToken0, aToken1);
        (bytes32[] memory lAccesses,) = vm.accesses(address(_priceCache));
        require(lAccesses.length == 1, "incorrect number of accesses");

        vm.store(address(_priceCache), lAccesses[0], bytes32(aPrice));
    }

    function setUp() external {
        // define route
        address[] memory lRoute = new address[](2);
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);

        _priceCache.setRoute(address(_tokenA), address(_tokenB), lRoute);
    }

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

    function testGetQuote(uint256 aPrice, uint256 aAmountIn) external {
        // assume
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmountIn = bound(aAmountIn, 100, 10_000_000e6);

        // arrange - write price to be 1 tokenA == 123 tokenB
        _writePriceCache(address(_tokenA), address(_tokenB), lPrice);

        // act
        uint256 lAmountOut = _priceCache.getQuote(lAmountIn, address(_tokenA), address(_tokenB));

        // assert
        assertEq(lAmountOut, lAmountIn * lPrice * 10 ** _tokenB.decimals() / 10 ** _tokenA.decimals() / 1e18);
    }

    function testGetQuote_Inverse(uint256 aPrice, uint256 aAmountIn) external {
        // assume
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmountIn = bound(aAmountIn, 100, 100_000_000_000e18);

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPrice);
        assertEq(_priceCache.priceCache(address(_tokenA), address(_tokenB)), lPrice);

        // act
        uint256 lAmountOut = _priceCache.getQuote(lAmountIn, address(_tokenB), address(_tokenA));

        // assert
        assertEq(
            lAmountOut, lAmountIn * lPrice.invertWad() * 10 ** _tokenA.decimals() / 10 ** _tokenB.decimals() / 1e18
        );
    }

    function testGetQuote_MultipleHops() external {
        // assume
        uint256 lPriceAB = 1e18;
        uint256 lPriceBC = 2e18;
        uint256 lPriceCD = 4e18;

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPriceAB);
        _writePriceCache(address(_tokenB), address(_tokenC), lPriceBC);
        _writePriceCache(address(_tokenC), address(_tokenD), lPriceCD);

        address[] memory lRoute = new address[](4);
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);
        lRoute[2] = address(_tokenC);
        lRoute[3] = address(_tokenD);
        _priceCache.setRoute(address(_tokenA), address(_tokenD), lRoute);

        uint256 lAmountIn = 789e6;

        // act
        uint256 lAmountOut = _priceCache.getQuote(lAmountIn, address(_tokenA), address(_tokenD));

        // assert
        assertEq(lAmountOut, 6312e6);
    }

    function testGetQuote_MultipleHops_Inverse() external {
        // assume
        uint256 lPriceAB = 1e18;
        uint256 lPriceBC = 2e18;
        uint256 lPriceCD = 4e18;

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPriceAB);
        _writePriceCache(address(_tokenB), address(_tokenC), lPriceBC);
        _writePriceCache(address(_tokenC), address(_tokenD), lPriceCD);

        address[] memory lRoute = new address[](4);
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);
        lRoute[2] = address(_tokenC);
        lRoute[3] = address(_tokenD);
        _priceCache.setRoute(address(_tokenA), address(_tokenD), lRoute);

        uint256 lAmountIn = 789e6;

        // act
        uint256 lAmountOut = _priceCache.getQuote(lAmountIn, address(_tokenD), address(_tokenA));

        // assert
        assertEq(lAmountOut, 98.625e6);
    }

    function testGetQuotes() external { }

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

    function testSetRoute_PopulateIntermediateRoute() external { }

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

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 ERROR CONDITIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

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

    function testUpdateRewardMultiplier_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _priceCache.updateRewardMultiplier(111);
    }

    function testUpdateOracle_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _priceCache.updateOracle(address(345));
    }

    function testGetQuote_NoPath() external {
        // act & assert
        vm.expectRevert(IPriceOracle.PO_NoPath.selector);
        _priceCache.getQuote(123, address(123), address(456));
    }
}
