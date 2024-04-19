// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { BaseTest, console2, ReservoirPair } from "test/__fixtures/BaseTest.t.sol";
import { ReservoirPriceCache, IPriceOracle } from "src/ReservoirPriceCache.sol";

import { Utils } from "src/libraries/Utils.sol";

contract ReservoirPriceCacheTest is BaseTest {
    using Utils for uint256;

    event Oracle(address newOracle);
    event RewardMultiplier(uint256 newMultiplier);
    event Route(address token0, address token1, address[] route);

    // writes the cached prices, for easy testing
    function _writePriceCache(address aToken0, address aToken1, uint256 aPrice) internal {
        require(aToken0 < aToken1, "tokens unsorted");
        vm.record();
        _priceCache.priceCache(aToken0, aToken1);
        (bytes32[] memory lAccesses,) = vm.accesses(address(_priceCache));
        require(lAccesses.length == 1, "incorrect number of accesses");

        vm.store(address(_priceCache), lAccesses[0], bytes32(aPrice));
    }

    constructor() {
        // sanity - ensure that base fee is correct, for testing reward payout
        assertEq(block.basefee, 0.01 gwei);

        // make sure ether balance of test contract is 0
        deal(address(this), 0);
    }

    receive() external payable { } // required to receive reward payout from priceCache

    function setUp() external {
        // define route
        address[] memory lRoute = new address[](2);
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);

        _priceCache.setRoute(address(_tokenA), address(_tokenB), lRoute);
        _oracle.setPairForRoute(address(_tokenB), address(_tokenA), _pair);
    }

    function testGasBountyAvailable(uint256 aBountyAmount) external {
        // assume
        uint256 lBounty = bound(aBountyAmount, 1, type(uint256).max);

        // arrange
        deal(address(_priceCache), lBounty);

        // act & assert
        assertEq(_priceCache.gasBountyAvailable(), lBounty);
    }

    function testGasBountyAvailable_Zero() external {
        // sanity
        assertEq(address(_priceCache).balance, 0);

        // act & assert
        assertEq(_priceCache.gasBountyAvailable(), 0);
    }

    function testGetQuote(uint256 aPrice, uint256 aAmountIn) public {
        // assume
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmountIn = bound(aAmountIn, 100, 10_000_000e6);

        // arrange
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

    function testGetQuotes(uint256 aPrice, uint256 aAmountIn) external {
        // assume
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmountIn = bound(aAmountIn, 100, 10_000_000e6);

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPrice);

        // act
        (uint256 lBidOut, uint256 lAskOut) = _priceCache.getQuotes(lAmountIn, address(_tokenA), address(_tokenB));

        // assert
        assertEq(lBidOut, lAskOut);
    }

    function testGetQuote_ZeroIn() external {
        // arrange
        testGetQuote(1e18, 1_000_000e6);

        // act
        uint256 lAmountOut = _priceCache.getQuote(0, address(_tokenA), address(_tokenB));

        // assert
        assertEq(lAmountOut, 0);
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

    function testUpdatePriceDeviationThreshold(uint256 aNewThreshold) external {
        // assume
        uint64 lNewThreshold = uint64(bound(aNewThreshold, 0, 0.1e18));

        // act
        _priceCache.updatePriceDeviationThreshold(lNewThreshold);

        // assert
        assertEq(_priceCache.priceDeviationThreshold(), lNewThreshold);
    }

    function testUpdateTwapPeriod(uint256 aNewPeriod) external {
        // assume
        uint64 lNewPeriod = uint64(bound(aNewPeriod, 1, 1 hours));

        // act
        _priceCache.updateTwapPeriod(lNewPeriod);

        // assert
        assertEq(_priceCache.twapPeriod(), lNewPeriod);
    }

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

    function testUpdatePrice_FirstUpdate() external {
        // sanity
        assertEq(_priceCache.priceCache(address(_tokenA), address(_tokenB)), 0);

        // arrange
        deal(address(_priceCache), 1 ether);

        skip(1);
        _pair.sync();
        skip(_priceCache.twapPeriod() * 2);
        _tokenA.mint(address(_pair), 2e18);
        _pair.swap(2e18, true, address(this), "");

        // act
        _priceCache.updatePrice(address(_tokenB), address(_tokenA), address(this));

        // assert
        assertEq(_priceCache.priceCache(address(_tokenA), address(_tokenB)), 98_918_868_099_219_913_512);
        assertEq(_priceCache.priceCache(address(_tokenB), address(_tokenA)), 0);
        assertEq(address(this).balance, 0); // there should be no reward for the first price update
    }

    function testUpdatePrice_WithinThreshold() external {
        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), 98.9223e18);
        deal(address(_priceCache), 1 ether);

        skip(1);
        _pair.sync();
        skip(_priceCache.twapPeriod() * 2);
        _tokenA.mint(address(_pair), 2e18);
        _pair.swap(2e18, true, address(this), "");

        // act
        _priceCache.updatePrice(address(_tokenB), address(_tokenA), address(this));

        // assert
        assertEq(_priceCache.priceCache(address(_tokenA), address(_tokenB)), 98_918_868_099_219_913_512);
        assertEq(_priceCache.priceCache(address(_tokenB), address(_tokenA)), 0);
        assertEq(address(this).balance, 0); // no reward since price is within threshold
    }

    function testUpdatePrice_BeyondThreshold(uint256 aRewardAvailable) external {
        // assume
        uint256 lRewardAvailable =
            bound(aRewardAvailable, block.basefee * _priceCache.rewardMultiplier(), type(uint256).max);

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), 5e18);
        deal(address(_priceCache), 1 ether);

        skip(1);
        _pair.sync();
        skip(_priceCache.twapPeriod() * 2);
        _tokenA.mint(address(_pair), 2e18);
        _pair.swap(2e18, true, address(this), "");

        // act
        _priceCache.updatePrice(address(_tokenB), address(_tokenA), address(this));

        // assert
        assertEq(_priceCache.priceCache(address(_tokenA), address(_tokenB)), 98_918_868_099_219_913_512);
        assertEq(_priceCache.priceCache(address(_tokenB), address(_tokenA)), 0);
        assertEq(address(this).balance, block.basefee * _priceCache.rewardMultiplier());
    }

    function testUpdatePrice_BeyondThreshold_InsufficientReward(uint256 aRewardAvailable) external {
        // assume
        uint256 lRewardAvailable = bound(aRewardAvailable, 1, block.basefee * _priceCache.rewardMultiplier() - 1);

        // arrange
        deal(address(_priceCache), lRewardAvailable);
        _writePriceCache(address(_tokenA), address(_tokenB), 5e18);

        skip(1);
        _pair.sync();
        skip(_priceCache.twapPeriod() * 2);
        _tokenA.mint(address(_pair), 2e18);
        _pair.swap(2e18, true, address(this), "");

        // act
        _priceCache.updatePrice(address(_tokenA), address(_tokenB), address(this));

        // assert
        assertEq(address(this).balance, 0); // no reward as there's insufficient ether in the contract
    }

    function testUpdatePrice_IntermediateRoutes() external {
        // arrange
        address lStart = address(_tokenA);
        address lIntermediate1 = address(_tokenC);
        address lIntermediate2 = address(_tokenD);
        address lEnd = address(_tokenB);
        address[] memory lRoute = new address[](4);
        lRoute[0] = lStart;
        lRoute[1] = lIntermediate1;
        lRoute[2] = lIntermediate2;
        lRoute[3] = lEnd;
        _priceCache.setRoute(lStart, lEnd, lRoute);

        ReservoirPair lAC = ReservoirPair(_createPair(address(_tokenA), address(_tokenC), 0));
        ReservoirPair lCD = ReservoirPair(_createPair(address(_tokenC), address(_tokenD), 0));
        ReservoirPair lBD = ReservoirPair(_createPair(address(_tokenB), address(_tokenD), 0));

        _tokenA.mint(address(lAC), 200 * 10 ** _tokenA.decimals());
        _tokenC.mint(address(lAC), 100 * 10 ** _tokenC.decimals());
        lAC.mint(address(this));

        _tokenC.mint(address(lCD), 100 * 10 ** _tokenC.decimals());
        _tokenD.mint(address(lCD), 200 * 10 ** _tokenD.decimals());
        lCD.mint(address(this));

        _tokenB.mint(address(lBD), 100 * 10 ** _tokenB.decimals());
        _tokenD.mint(address(lBD), 200 * 10 ** _tokenD.decimals());
        lBD.mint(address(this));

        _oracle.setPairForRoute(lStart, lIntermediate1, lAC);
        _oracle.setPairForRoute(lIntermediate2, lIntermediate1, lCD);
        _oracle.setPairForRoute(lIntermediate2, lEnd, lBD);

        skip(1);
        _pair.sync();
        lAC.sync();
        lCD.sync();
        lBD.sync();
        skip(_priceCache.twapPeriod() * 2);

        // act
        _priceCache.updatePrice(address(_tokenA), address(_tokenB), address(this));

        // assert
        uint256 lPriceAC = _priceCache.priceCache(lStart, lIntermediate1);
        uint256 lPriceCD = _priceCache.priceCache(lIntermediate1, lIntermediate2);
        uint256 lPriceBD = _priceCache.priceCache(lEnd, lIntermediate2);
        uint256 lPriceAB = _priceCache.priceCache(lStart, lEnd);
        assertApproxEqRel(lPriceAC, 0.5e18, 0.0001e18);
        assertApproxEqRel(lPriceCD, 2e18, 0.0001e18);
        assertApproxEqRel(lPriceBD, 2e18, 0.0001e18);
        assertEq(lPriceAB, 0); // composite price is not stored in the cache
    }

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

    function testSetRoute_MultipleHops() external {
        // arrange
        address lStart = address(0x1);
        address lIntermediate1 = address(0x5);
        address lIntermediate2 = address(0x3);
        address lEnd = address(0x9);
        address[] memory lRoute = new address[](4);
        lRoute[0] = lStart;
        lRoute[1] = lIntermediate1;
        lRoute[2] = lIntermediate2;
        lRoute[3] = lEnd;

        address[] memory lIntermediateRoute1 = new address[](2);
        lIntermediateRoute1[0] = lStart;
        lIntermediateRoute1[1] = lIntermediate1;

        // note that the seq should be reversed cuz lIntermediate2 < lIntermediate1
        address[] memory lIntermediateRoute2 = new address[](2);
        lIntermediateRoute2[0] = lIntermediate2;
        lIntermediateRoute2[1] = lIntermediate1;

        address[] memory lIntermediateRoute3 = new address[](2);
        lIntermediateRoute3[0] = lIntermediate2;
        lIntermediateRoute3[1] = lEnd;

        // act
        vm.expectEmit(false, false, false, true);
        emit Route(lStart, lEnd, lRoute);
        vm.expectEmit(false, false, false, true);
        emit Route(lStart, lIntermediate1, lIntermediateRoute1);
        vm.expectEmit(true, true, true, true);
        // note the reverse seq here as well
        emit Route(lIntermediate2, lIntermediate1, lIntermediateRoute2);
        vm.expectEmit(false, false, false, true);
        emit Route(lIntermediate2, lEnd, lIntermediateRoute3);
        _priceCache.setRoute(lStart, lEnd, lRoute);

        // assert
        assertEq(_priceCache.route(lStart, lEnd), lRoute);
        assertEq(_priceCache.route(lStart, lIntermediate1), lIntermediateRoute1);
        assertEq(_priceCache.route(lIntermediate2, lIntermediate1), lIntermediateRoute2);
        assertEq(_priceCache.route(lIntermediate2, lEnd), lIntermediateRoute3);
    }

    function testSetRoute_EndTokenJustGreaterThanStart() external {
        // arrange
        address lStart = address(0x1);
        address lIntermediate1 = address(0x97);
        address lIntermediate2 = address(0x58);
        address lEnd = address(0x2);
        address[] memory lRoute = new address[](4);
        lRoute[0] = lStart;
        lRoute[1] = lIntermediate1;
        lRoute[2] = lIntermediate2;
        lRoute[3] = lEnd;

        address[] memory lIntermediateRoute1 = new address[](2);
        lIntermediateRoute1[0] = lStart;
        lIntermediateRoute1[1] = lIntermediate1;

        // act
        _priceCache.setRoute(lStart, lEnd, lRoute);

        // assert
        assertEq(_priceCache.route(lStart, lEnd), lRoute);
        assertEq(_priceCache.route(lStart, lIntermediate1), lIntermediateRoute1);
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

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 ERROR CONDITIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testUpdateTwapPeriod_InvalidTwapPeriod(uint256 aNewPeriod) external {
        // assume
        uint64 lNewPeriod = uint64(bound(aNewPeriod, 1 hours + 1, type(uint64).max));

        // act & assert
        vm.expectRevert(ReservoirPriceCache.RPC_INVALID_TWAP_PERIOD.selector);
        _priceCache.updateTwapPeriod(lNewPeriod);
        vm.expectRevert(ReservoirPriceCache.RPC_INVALID_TWAP_PERIOD.selector);
        _priceCache.updateTwapPeriod(0);
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
        address[] memory lInvalidRoute1 = new address[](3);
        lInvalidRoute1[0] = lToken0;
        lInvalidRoute1[1] = lToken1;
        lInvalidRoute1[2] = address(0);

        address[] memory lInvalidRoute2 = new address[](3);
        lInvalidRoute2[0] = address(0);
        lInvalidRoute2[1] = address(54);
        lInvalidRoute2[2] = lToken1;

        // act & assert
        vm.expectRevert(ReservoirPriceCache.RPC_INVALID_ROUTE.selector);
        _priceCache.setRoute(lToken0, lToken1, lInvalidRoute1);
        vm.expectRevert(ReservoirPriceCache.RPC_INVALID_ROUTE.selector);
        _priceCache.setRoute(lToken0, lToken1, lInvalidRoute2);
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
