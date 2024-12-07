// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { BaseTest, console2, ReservoirPair, MintableERC20 } from "test/__fixtures/BaseTest.t.sol";

import { Utils } from "src/libraries/Utils.sol";
import {
    FixedPointMathLib,
    PriceType,
    OracleErrors,
    OracleAverageQuery,
    ReservoirPriceOracle,
    IERC20,
    IERC4626,
    IPriceOracle,
    RoutesLib
} from "src/ReservoirPriceOracle.sol";
import { Bytes32Lib } from "amm-core/libraries/Bytes32.sol";
import { EnumerableSetLib } from "lib/solady/src/utils/EnumerableSetLib.sol";
import { Constants } from "src/libraries/Constants.sol";
import { MockFallbackOracle } from "test/mock/MockFallbackOracle.sol";
import { StubERC4626 } from "test/mock/StubERC4626.sol";

contract ReservoirPriceOracleTest is BaseTest {
    using Utils for *;
    using RoutesLib for *;
    using Bytes32Lib for *;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using FixedPointMathLib for uint256;

    event DesignatePair(address token0, address token1, ReservoirPair pair);
    event Oracle(address newOracle);
    event RewardGasAmount(uint256 newAmount);
    event Route(address token0, address token1, address[] route);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_STARTING_BALANCE = 10 ether;
    address internal constant ADDRESS_THRESHOLD = address(0x1000);

    // to keep track of addresses to ensure no clash for fuzz tests
    EnumerableSetLib.AddressSet internal _addressSet;

    MockFallbackOracle internal _fallbackOracle = new MockFallbackOracle();

    // writes the cached prices, for easy testing
    function _writePriceCache(address aToken0, address aToken1, uint256 aPrice) internal {
        require(aToken0 < aToken1, "tokens unsorted");
        require(aPrice <= Constants.MAX_SUPPORTED_PRICE, "price too large");

        vm.record();
        (, int256 lDecimalDiff, uint256 lRewardThreshold) = _oracle.priceCache(aToken0, aToken1);
        (bytes32[] memory lAccesses,) = vm.accesses(address(_oracle));
        require(lAccesses.length == 1, "incorrect number of accesses");

        lDecimalDiff = lDecimalDiff == 0
            ? int256(uint256(IERC20(aToken1).decimals())) - int256(uint256(IERC20(aToken0).decimals()))
            : lDecimalDiff;
        bytes32 lData = lDecimalDiff.packSimplePrice(aPrice, lRewardThreshold);
        require(lData.isSimplePrice(), "flag incorrect");
        require(lData.getDecimalDifference() == lDecimalDiff, "decimal diff incorrect");
        require(lData.getRewardThreshold() == lRewardThreshold, "reward threshold incorrect");
        vm.store(address(_oracle), lAccesses[0], lData);
    }

    constructor() {
        // sanity - ensure that base fee is correct, for testing reward payout
        assertEq(block.basefee, 0.01 gwei);

        // make sure ether balance of test contract is 0
        deal(address(this), 0);
        deal(address(_oracle), ORACLE_STARTING_BALANCE);

        _addressSet.add(address(_tokenA));
        _addressSet.add(address(_tokenB));
        _addressSet.add(address(_tokenC));
        _addressSet.add(address(_tokenD));
        _addressSet.add(address(_factory));
        _addressSet.add(address(_oracle));
        _addressSet.add(address(_pair));
        _addressSet.add(address(this));
        _addressSet.add(address(VM_ADDRESS));
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable { } // required to receive reward payout from priceCache

    function setUp() external {
        // define route
        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);
        lRewardThreshold[0] = 200; // 2%

        _oracle.designatePair(address(_tokenB), address(_tokenA), _pair);
        _oracle.designatePair(address(_tokenB), address(_tokenC), _pairBC);
        _oracle.designatePair(address(_tokenD), address(_tokenC), _pairCD);
        _oracle.setRoute(address(_tokenA), address(_tokenB), lRoute, lRewardThreshold);
    }

    function testName() external {
        // act & assert
        assertEq(_oracle.name(), "RESERVOIR PRICE ORACLE");
    }

    function testWritePriceCache(uint256 aPrice) external {
        // arrange
        uint256 lPrice = bound(aPrice, 1, 1e36);

        // act
        _writePriceCache(address(_tokenB), address(_tokenC), lPrice);

        // assert
        (uint256 lQueriedPrice,,) = _oracle.priceCache(address(_tokenB), address(_tokenC));
        assertEq(lQueriedPrice, lPrice);
    }

    function testGetQuote(uint256 aPrice, uint256 aAmountIn) public {
        // assume
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmountIn = bound(aAmountIn, 100, 10_000_000e6);

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPrice);

        // act
        uint256 lAmountOut = _oracle.getQuote(lAmountIn, address(_tokenA), address(_tokenB));

        // assert
        assertEq(lAmountOut, lAmountIn * lPrice * 10 ** _tokenB.decimals() / 10 ** _tokenA.decimals() / 1e18);
    }

    function testGetQuote_Inverse(uint256 aPrice, uint256 aAmountIn) external {
        // assume
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmountIn = bound(aAmountIn, 100, 100_000_000_000e18);

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPrice);
        (uint256 lQueriedPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertEq(lQueriedPrice, lPrice);

        // act
        uint256 lAmountOut = _oracle.getQuote(lAmountIn, address(_tokenB), address(_tokenA));

        // assert
        assertEq(lAmountOut, lAmountIn * WAD * (10 ** _tokenA.decimals()) / lPrice / (10 ** _tokenB.decimals()));
    }

    function testGetQuote_MultipleHops() public {
        // assume
        uint256 lPriceAB = 1e18;
        uint256 lPriceBC = 2e18;
        uint256 lPriceCD = 4e18;

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPriceAB);
        _writePriceCache(address(_tokenB), address(_tokenC), lPriceBC);
        _writePriceCache(address(_tokenC), address(_tokenD), lPriceCD);

        address[] memory lRoute = new address[](4);
        uint64[] memory lRewardThreshold = new uint64[](3);
        lRewardThreshold[0] = lRewardThreshold[1] = lRewardThreshold[2] = Constants.WAD;

        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);
        lRoute[2] = address(_tokenC);
        lRoute[3] = address(_tokenD);
        _oracle.setRoute(address(_tokenA), address(_tokenD), lRoute, lRewardThreshold);

        uint256 lAmountIn = 789e6;

        // act
        uint256 lAmountOut = _oracle.getQuote(lAmountIn, address(_tokenA), address(_tokenD));

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
        uint64[] memory lRewardThreshold = new uint64[](3);
        lRewardThreshold[0] = lRewardThreshold[1] = lRewardThreshold[2] = Constants.WAD;
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);
        lRoute[2] = address(_tokenC);
        lRoute[3] = address(_tokenD);
        _oracle.setRoute(address(_tokenA), address(_tokenD), lRoute, lRewardThreshold);

        uint256 lAmountIn = 789e6;

        // act
        uint256 lAmountOut = _oracle.getQuote(lAmountIn, address(_tokenD), address(_tokenA));

        // assert
        assertEq(lAmountOut, 98.625e6);
    }

    function testGetQuote_ComplicatedDecimals() external {
        // arrange
        MintableERC20 lTokenA = MintableERC20(address(0x1111));
        MintableERC20 lTokenB = MintableERC20(address(0x3333));
        MintableERC20 lTokenC = MintableERC20(address(0x2222));
        uint8 lTokenADecimals = 6;
        uint8 lTokenBDecimals = 8;
        uint8 lTokenCDecimals = 11;

        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", lTokenADecimals), address(lTokenA));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", lTokenBDecimals), address(lTokenB));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", lTokenCDecimals), address(lTokenC));

        ReservoirPair lPairAB =
            ReservoirPair(_factory.createPair(IERC20(address(lTokenA)), IERC20(address(lTokenB)), 0));
        ReservoirPair lPairBC =
            ReservoirPair(_factory.createPair(IERC20(address(lTokenB)), IERC20(address(lTokenC)), 0));
        _oracle.designatePair(address(lTokenA), address(lTokenB), lPairAB);
        _oracle.designatePair(address(lTokenB), address(lTokenC), lPairBC);

        address[] memory lRoute = new address[](3);
        lRoute[0] = address(lTokenA);
        lRoute[1] = address(lTokenB);
        lRoute[2] = address(lTokenC);

        {
            uint64[] memory lRewardThreshold = new uint64[](2);
            lRewardThreshold[0] = lRewardThreshold[1] = Constants.WAD;
            _oracle.setRoute(address(lTokenA), address(lTokenC), lRoute, lRewardThreshold);
            _writePriceCache(address(lTokenA), address(lTokenB), 1e18);
            _writePriceCache(address(lTokenC), address(lTokenB), 1e18);
        }

        // act
        uint256 lAmtCOut = _oracle.getQuote(10 ** lTokenADecimals, address(lTokenA), address(lTokenC));
        uint256 lAmtBOut = _oracle.getQuote(10 ** lTokenADecimals, address(lTokenA), address(lTokenB));
        uint256 lAmtAOut = _oracle.getQuote(10 ** lTokenCDecimals, address(lTokenC), address(lTokenA));

        // assert
        assertEq(lAmtCOut, 10 ** lTokenCDecimals);
        assertEq(lAmtBOut, 10 ** lTokenBDecimals);
        assertEq(lAmtAOut, 10 ** lTokenADecimals);
    }

    function testGetQuote_RandomizeAllParam_1HopRoute(
        uint256 aPrice,
        uint256 aAmtIn,
        address aTokenAAddress,
        address aTokenBAddress,
        uint8 aTokenADecimal,
        uint8 aTokenBDecimal
    ) external {
        // assume
        vm.assume(aTokenAAddress.code.length == 0 && aTokenBAddress.code.length == 0);
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmtIn = bound(aAmtIn, 0, 1_000_000_000);
        uint256 lTokenADecimal = bound(aTokenADecimal, 0, 18);
        uint256 lTokenBDecimal = bound(aTokenBDecimal, 0, 18);

        // arrange
        MintableERC20 lTokenA = MintableERC20(aTokenAAddress);
        MintableERC20 lTokenB = MintableERC20(aTokenBAddress);
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenADecimal)), address(lTokenA));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenBDecimal)), address(lTokenB));

        ReservoirPair lPair = ReservoirPair(_factory.createPair(IERC20(address(lTokenA)), IERC20(address(lTokenB)), 0));
        _oracle.designatePair(address(lTokenA), address(lTokenB), lPair);

        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;
        (lRoute[0], lRoute[1]) =
            lTokenA < lTokenB ? (address(lTokenA), address(lTokenB)) : (address(lTokenB), address(lTokenA));
        _oracle.setRoute(lRoute[0], lRoute[1], lRoute, lRewardThreshold);
        _writePriceCache(lRoute[0], lRoute[1], lPrice); // price written could be tokenB/tokenA or tokenA/tokenB depending on the fuzz addresses

        // act
        uint256 lAmtBOut = _oracle.getQuote(lAmtIn * 10 ** lTokenADecimal, address(lTokenA), address(lTokenB));

        // assert
        uint256 lExpectedAmt = lTokenA < lTokenB
            ? (lAmtIn * 10 ** lTokenADecimal).fullMulDiv(lPrice * 10 ** lTokenBDecimal, 10 ** lTokenADecimal * WAD)
            : (lAmtIn * 10 ** lTokenADecimal).fullMulDiv(WAD * 10 ** lTokenBDecimal, lPrice * 10 ** lTokenADecimal);

        assertEq(lAmtBOut, lExpectedAmt);
    }

    function testGetQuote_RandomizeAllParam_2HopRoute(
        uint256 aPrice1,
        uint256 aPrice2,
        uint256 aAmtIn,
        address aTokenAAddress,
        address aTokenBAddress,
        address aTokenCAddress,
        uint8 aTokenADecimal,
        uint8 aTokenBDecimal,
        uint8 aTokenCDecimal
    ) external {
        // assume
        vm.assume(aTokenAAddress.code.length == 0 && aTokenBAddress.code.length == 0 && aTokenCAddress.code.length == 0);
        uint256 lPrice1 = bound(aPrice1, 1e9, 1e25); // need to bound price within this range as a price below this will go to zero as during the mul and div of prices
        uint256 lPrice2 = bound(aPrice2, 1e9, 1e25);
        uint256 lAmtIn = bound(aAmtIn, 0, 1_000_000_000);
        uint256 lTokenADecimal = bound(aTokenADecimal, 0, 18);
        uint256 lTokenBDecimal = bound(aTokenBDecimal, 0, 18);
        uint256 lTokenCDecimal = bound(aTokenCDecimal, 0, 18);

        // arrange
        MintableERC20 lTokenA = MintableERC20(aTokenAAddress);
        MintableERC20 lTokenB = MintableERC20(aTokenBAddress);
        MintableERC20 lTokenC = MintableERC20(aTokenCAddress);
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenADecimal)), address(lTokenA));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenBDecimal)), address(lTokenB));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenCDecimal)), address(lTokenC));

        ReservoirPair lPair1 = ReservoirPair(_factory.createPair(IERC20(address(lTokenA)), IERC20(address(lTokenB)), 0));
        ReservoirPair lPair2 = ReservoirPair(_factory.createPair(IERC20(address(lTokenB)), IERC20(address(lTokenC)), 0));

        _oracle.designatePair(address(lTokenA), address(lTokenB), lPair1);
        _oracle.designatePair(address(lTokenB), address(lTokenC), lPair2);
        {
            // to avoid stack too deep error
            address[] memory lRoute = new address[](3);
            (lRoute[0], lRoute[2]) =
                lTokenA < lTokenC ? (address(lTokenA), address(lTokenC)) : (address(lTokenC), address(lTokenA));
            lRoute[1] = address(lTokenB);

            uint64[] memory lRewardThreshold = new uint64[](2);
            lRewardThreshold[0] = lRewardThreshold[1] = Constants.WAD;
            _oracle.setRoute(lRoute[0], lRoute[2], lRoute, lRewardThreshold);
            _writePriceCache(
                address(lTokenA) < address(lTokenB) ? address(lTokenA) : address(lTokenB),
                address(lTokenA) < address(lTokenB) ? address(lTokenB) : address(lTokenA),
                lPrice1
            );
            _writePriceCache(
                address(lTokenB) < address(lTokenC) ? address(lTokenB) : address(lTokenC),
                address(lTokenB) < address(lTokenC) ? address(lTokenC) : address(lTokenB),
                lPrice2
            );
        }

        // act
        uint256 lAmtCOut = _oracle.getQuote(lAmtIn * 10 ** lTokenADecimal, address(lTokenA), address(lTokenC));

        // assert
        uint256 lExpectedAmtBOut = lTokenA < lTokenB
            ? (lAmtIn * 10 ** lTokenADecimal).fullMulDiv(lPrice1 * 10 ** lTokenBDecimal, 10 ** lTokenADecimal * WAD)
            : (lAmtIn * 10 ** lTokenADecimal).fullMulDiv(WAD * 10 ** lTokenBDecimal, lPrice1 * 10 ** lTokenADecimal);
        uint256 lExpectedAmtCOut = lTokenB < lTokenC
            ? (lExpectedAmtBOut).fullMulDiv(lPrice2 * 10 ** lTokenCDecimal, 10 ** lTokenBDecimal * WAD)
            : (lExpectedAmtBOut).fullMulDiv(WAD * 10 ** lTokenCDecimal, lPrice2 * 10 ** lTokenBDecimal);

        assertEq(lAmtCOut, lExpectedAmtCOut);
    }

    function testGetQuotes(uint256 aPrice, uint256 aAmountIn) external {
        // assume
        uint256 lPrice = bound(aPrice, 1, 1e36);
        uint256 lAmountIn = bound(aAmountIn, 100, 10_000_000e6);

        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), lPrice);

        // act
        (uint256 lBidOut, uint256 lAskOut) = _oracle.getQuotes(lAmountIn, address(_tokenA), address(_tokenB));

        // assert
        assertEq(lBidOut, lAskOut);
    }

    function testGetQuote_ZeroIn() external {
        // arrange
        testGetQuote(1e18, 1_000_000e6);

        // act
        uint256 lAmountOut = _oracle.getQuote(0, address(_tokenA), address(_tokenB));

        // assert
        assertEq(lAmountOut, 0);
    }

    function testGetQuote_SameBaseQuote(uint256 aAmtIn, address aToken) external view {
        // act
        uint256 lAmtOut = _oracle.getQuote(aAmtIn, aToken, aToken);

        // assert
        assertEq(lAmtOut, aAmtIn);
    }

    function testGetQuote_UseFallback() external {
        // arrange
        _oracle.setFallbackOracle(address(_fallbackOracle));

        // act
        uint256 lAmountOut = _oracle.getQuote(1, address(_tokenC), address(_tokenD));
        (uint256 lBidOut, uint256 lAskOut) = _oracle.getQuotes(1, address(_tokenC), address(_tokenD));

        // assert
        assertGt(lAmountOut, 0);
        assertGt(lBidOut, 0);
        assertGt(lAskOut, 0);
    }

    function testGetQuote_BaseIsVault(uint256 aRate) external {
        // assume
        uint256 lRate = bound(aRate, 1, 1e36);

        // arrange
        uint256 lAmtIn = 5e18;
        StubERC4626 lVault = new StubERC4626(address(_tokenA), lRate);
        _writePriceCache(address(_tokenA), address(_tokenB), 1e18);

        // act
        uint256 lAmtOut = _oracle.getQuote(lAmtIn, address(lVault), address(_tokenB));

        // assert
        assertEq(lAmtOut / 1e12, lAmtIn * lRate / 1e18);
    }

    function testPriceCache_Inverted() external {
        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), 1e18);

        // act
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenB), address(_tokenA));

        // assert
        assertEq(lPrice, 0);
    }

    function testUpdateTwapPeriod(uint256 aNewPeriod) external {
        // assume
        uint16 lNewPeriod = uint16(bound(aNewPeriod, 1, 1 hours));

        // act
        _oracle.updateTwapPeriod(lNewPeriod);

        // assert
        assertEq(_oracle.twapPeriod(), lNewPeriod);
    }

    function testUpdateRewardGasAmount() external {
        // arrange
        uint64 lNewRewardMultiplier = 50;

        // act
        vm.expectEmit(false, false, false, false);
        emit RewardGasAmount(lNewRewardMultiplier);
        _oracle.updateRewardGasAmount(lNewRewardMultiplier);

        // assert
        assertEq(_oracle.rewardGasAmount(), lNewRewardMultiplier);
    }

    function testUpdatePrice_FirstUpdate() public {
        // sanity
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertEq(lPrice, 0);

        // arrange
        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod() * 2);
        _pair.sync();

        // act
        uint256 lReward = _oracle.updatePrice(address(_tokenB), address(_tokenA), address(this));

        // assert
        (lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertEq(lPrice, 98_918_868_099_219_913_512);
        (lPrice,,) = _oracle.priceCache(address(_tokenB), address(_tokenA));
        assertEq(lPrice, 0);
        assertEq(address(this).balance, 0); // there should be no reward for the first price update
        assertEq(lReward, 0);
    }

    function testUpdatePrice_BelowThreshold(uint256 aPercentDiff) external {
        // assume
        (,, uint256 lRewardThreshold) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        uint256 lPercentDiff = bound(aPercentDiff, 0, (lRewardThreshold - 1));

        // arrange - we fuzz test by varying the starting price instead of the new price
        uint256 lCurrentPrice = 98_918_868_099_219_913_512;
        uint256 lStartingPrice = lCurrentPrice * WAD / (WAD + lPercentDiff);
        _writePriceCache(address(_tokenA), address(_tokenB), lStartingPrice);

        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod());
        _pair.sync();

        // act
        uint256 lReward = _oracle.updatePrice(address(_tokenA), address(_tokenB), address(this));

        // assert
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertEq(lPrice, lCurrentPrice);
        assertEq(address(this).balance, 0); // no reward as the price did not move sufficiently
        assertEq(lReward, 0);
    }

    function testUpdatePrice_AboveThresholdBelowMaxReward(uint256 aPercentDiff) external {
        // assume
        (,, uint256 lRewardThreshold) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        uint256 lPercentDiff = bound(aPercentDiff, lRewardThreshold, _oracle.MAX_REWARD_MULTIPLIER() * lRewardThreshold);

        // arrange
        uint256 lCurrentPrice = 98_918_868_099_219_913_512;
        uint256 lStartingPrice = lCurrentPrice * WAD / (WAD + lPercentDiff);
        _writePriceCache(address(_tokenA), address(_tokenB), lStartingPrice);

        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod());
        _pair.sync();

        // act
        uint256 lReward = _oracle.updatePrice(address(_tokenB), address(_tokenA), address(this));

        // assert
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertEq(lPrice, lCurrentPrice);
        uint256 lExpectedRewardReceived = block.basefee * _oracle.rewardGasAmount() * lPercentDiff / lRewardThreshold;
        assertGe(lExpectedRewardReceived, block.basefee * _oracle.rewardGasAmount());
        assertLe(lExpectedRewardReceived, block.basefee * _oracle.rewardGasAmount() * _oracle.MAX_REWARD_MULTIPLIER());
        assertEq(address(this).balance, lExpectedRewardReceived); // some reward received but is less than max possible reward
        assertEq(lExpectedRewardReceived, lReward);
    }

    function testUpdatePrice_BeyondMaxReward(uint256 aPercentDiff) external {
        // assume
        (,, uint256 lRewardThreshold) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        uint256 lPercentDiff = bound(
            aPercentDiff,
            _oracle.MAX_REWARD_MULTIPLIER() * lRewardThreshold,
            WAD // 100%
        );

        // arrange
        uint256 lCurrentPrice = 98_918_868_099_219_913_512;
        uint256 lStartingPrice = lCurrentPrice * WAD / (WAD + lPercentDiff);
        _writePriceCache(address(_tokenA), address(_tokenB), lStartingPrice);

        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod());
        _pair.sync();

        // act
        uint256 lReward = _oracle.updatePrice(address(_tokenB), address(_tokenA), address(this));

        // assert
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertEq(lPrice, lCurrentPrice);
        uint256 lExpectedRewardReceived = block.basefee * _oracle.rewardGasAmount() * _oracle.MAX_REWARD_MULTIPLIER();
        assertEq(address(this).balance, lExpectedRewardReceived);
        assertEq(address(_oracle).balance, ORACLE_STARTING_BALANCE - lExpectedRewardReceived);
        assertEq(lExpectedRewardReceived, lReward);
    }

    function testUpdatePrice_RewardEligible_InsufficientReward(uint256 aRewardAvailable) external {
        // assume
        uint256 lRewardAvailable =
            bound(aRewardAvailable, 1, block.basefee * _oracle.rewardGasAmount() * _oracle.MAX_REWARD_MULTIPLIER() - 1);

        // arrange
        deal(address(_oracle), lRewardAvailable);
        _writePriceCache(address(_tokenA), address(_tokenB), 5e18);

        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod() * 2);
        _tokenA.mint(address(_pair), 2e18);
        _pair.swap(2e18, true, address(this), "");

        // act
        uint256 lReward = _oracle.updatePrice(address(_tokenA), address(_tokenB), address(this));

        // assert - no reward as there's insufficient ether in the contract, but price cache updated nonetheless
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertNotEq(lPrice, 5e18);
        assertEq(address(this).balance, 0);
        assertGt(lReward, 0);
    }

    function testUpdatePrice_RewardEligible_ZeroRecipient() external {
        // arrange
        uint256 lOracleBalanceStart = address(_oracle).balance;
        _writePriceCache(address(_tokenA), address(_tokenB), 5e18);

        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod());
        _pair.sync();

        // act
        uint256 lReward = _oracle.updatePrice(address(_tokenA), address(_tokenB), address(0));

        // assert - no change to balance, but price cache updated nonetheless
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertNotEq(lPrice, 5e18);
        assertEq(address(_oracle).balance, lOracleBalanceStart);
        assertGt(lReward, 0);
    }

    function testUpdatePrice_RewardEligible_ContractNoReceive() external {
        // arrange
        _writePriceCache(address(_tokenA), address(_tokenB), 5e18);

        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod());
        _pair.sync();

        // act
        _oracle.updatePrice(address(_tokenA), address(_tokenB), address(_pair)); // recipient set to any contract that doesn't have a `receive` function

        // assert
        (uint256 lPrice,,) = _oracle.priceCache(address(_tokenA), address(_tokenB));
        assertNotEq(lPrice, 5e18); // price is updated nonetheless
        assertEq(address(_pair).balance, 0);
    }

    function testUpdatePrice_IntermediateRoutes() external {
        // arrange
        address lStart = address(_tokenA);
        address lIntermediate1 = address(_tokenC);
        address lIntermediate2 = address(_tokenD);
        address lEnd = address(_tokenB);
        address[] memory lRoute = new address[](4);
        uint64[] memory lRewardThreshold = new uint64[](3);
        lRewardThreshold[0] = lRewardThreshold[1] = lRewardThreshold[2] = 3; // 3bp
        lRoute[0] = lStart;
        lRoute[1] = lIntermediate1;
        lRoute[2] = lIntermediate2;
        lRoute[3] = lEnd;
        _oracle.setRoute(lStart, lEnd, lRoute, lRewardThreshold);

        ReservoirPair lAC = ReservoirPair(_createPair(address(_tokenA), address(_tokenC), 0));
        ReservoirPair lBD = ReservoirPair(_createPair(address(_tokenB), address(_tokenD), 0));

        _tokenA.mint(address(lAC), 200 * 10 ** _tokenA.decimals());
        _tokenC.mint(address(lAC), 100 * 10 ** _tokenC.decimals());
        lAC.mint(address(this));

        _tokenB.mint(address(lBD), 100 * 10 ** _tokenB.decimals());
        _tokenD.mint(address(lBD), 200 * 10 ** _tokenD.decimals());
        lBD.mint(address(this));

        _oracle.designatePair(lStart, lIntermediate1, lAC);
        _oracle.designatePair(lIntermediate2, lEnd, lBD);

        skip(1);
        _pair.sync();
        lAC.sync();
        _pairCD.sync();
        lBD.sync();
        skip(_oracle.twapPeriod());

        // act
        uint256 lReward = _oracle.updatePrice(address(_tokenA), address(_tokenB), address(this));

        // assert
        (uint256 lPriceAC,,) = _oracle.priceCache(lStart, lIntermediate1);
        (uint256 lPriceCD,,) = _oracle.priceCache(lIntermediate1, lIntermediate2);
        (uint256 lPriceBD,,) = _oracle.priceCache(lEnd, lIntermediate2);
        (uint256 lPriceAB,,) = _oracle.priceCache(lStart, lEnd);
        assertApproxEqRel(lPriceAC, 0.5e18, 0.0001e18);
        assertApproxEqRel(lPriceCD, 2e18, 0.0001e18);
        assertApproxEqRel(lPriceBD, 2e18, 0.0001e18);
        assertEq(lPriceAB, 0); // composite price is not stored in the cache
        assertEq(lReward, 0);

        // arrange
        skip(_oracle.twapPeriod());

        // act
        uint256 lSwapAmt = 1_000_000;
        _tokenA.mint(address(lAC), lSwapAmt * 10 ** _tokenA.decimals());
        lAC.swap(int256(lSwapAmt * 10 ** _tokenA.decimals()), true, address(this), "");

        _tokenC.mint(address(_pairCD), lSwapAmt * 10 ** _tokenC.decimals());
        _pairCD.swap(int256(lSwapAmt * 10 ** _tokenC.decimals()), true, address(this), "");

        _tokenB.mint(address(lBD), lSwapAmt * 10 ** _tokenB.decimals());
        lBD.swap(int256(lSwapAmt * 10 ** _tokenB.decimals()), true, address(this), "");

        skip(_oracle.twapPeriod());

        lReward = _oracle.updatePrice(address(_tokenA), address(_tokenB), address(this));
        assertGt(lReward, _oracle.rewardGasAmount() * 3); // ensure that rewards have been aggregated across routes
    }

    function testSetRoute() public {
        // arrange
        address lToken0 = address(_tokenB);
        address lToken1 = address(_tokenC);
        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;

        // act
        vm.expectEmit(false, false, false, false);
        emit Route(lToken0, lToken1, lRoute);
        _oracle.setRoute(lToken0, lToken1, lRoute, lRewardThreshold);

        // assert
        address[] memory lQueriedRoute = _oracle.route(lToken0, lToken1);
        assertEq(lQueriedRoute, lRoute);
        (, int256 lDecimalDiff,) = _oracle.priceCache(lToken0, lToken1);
        int256 lActualDiff = int256(uint256(IERC20(lToken1).decimals())) - int256(uint256(IERC20(lToken0).decimals()));
        assertEq(lDecimalDiff, lActualDiff);
    }

    function testSetRoute_OverwriteExisting() external {
        // arrange
        testSetRoute();
        address lToken0 = address(_tokenB);
        address lToken1 = address(_tokenC);
        address[] memory lRoute = new address[](4);
        uint64[] memory lRewardThreshold = new uint64[](3);
        lRewardThreshold[0] = lRewardThreshold[1] = lRewardThreshold[2] = Constants.WAD;
        lRoute[0] = lToken0;
        lRoute[1] = address(_tokenA);
        lRoute[2] = address(_tokenD);
        lRoute[3] = lToken1;

        // act
        _oracle.setRoute(lToken0, lToken1, lRoute, lRewardThreshold);

        // assert
        address[] memory lQueriedRoute = _oracle.route(lToken0, lToken1);
        assertEq(lQueriedRoute, lRoute);
        assertEq(lQueriedRoute.length, 4);
    }

    function testSetRoute_MultipleHops() external {
        // arrange
        address lStart = address(_tokenA);
        address lIntermediate1 = address(_tokenC);
        address lIntermediate2 = address(_tokenB);
        address lEnd = address(_tokenD);
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

        uint64[] memory lRewardThreshold = new uint64[](3);
        lRewardThreshold[0] = lRewardThreshold[1] = lRewardThreshold[2] = Constants.WAD;

        // act
        vm.expectEmit(false, false, false, true);
        emit Route(lIntermediate2, lEnd, lIntermediateRoute3);
        vm.expectEmit(false, false, false, true);
        emit Route(lStart, lIntermediate1, lIntermediateRoute1);
        vm.expectEmit(true, true, true, true);
        // note the reverse seq here as well
        emit Route(lIntermediate2, lIntermediate1, lIntermediateRoute2);
        vm.expectEmit(false, false, false, true);
        emit Route(lStart, lEnd, lRoute);

        _oracle.setRoute(lStart, lEnd, lRoute, lRewardThreshold);

        // assert
        assertEq(_oracle.route(lStart, lEnd), lRoute);
        assertEq(_oracle.route(lStart, lIntermediate1), lIntermediateRoute1);
        assertEq(_oracle.route(lIntermediate2, lIntermediate1), lIntermediateRoute2);
        assertEq(_oracle.route(lIntermediate2, lEnd), lIntermediateRoute3);
    }

    function testClearRoute() external {
        // arrange
        address lToken0 = address(_tokenB);
        address lToken1 = address(_tokenC);
        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;
        _oracle.setRoute(lToken0, lToken1, lRoute, lRewardThreshold);
        address[] memory lQueriedRoute = _oracle.route(lToken0, lToken1);
        assertEq(lQueriedRoute, lRoute);
        _writePriceCache(lToken0, lToken1, 1e18);

        // act
        vm.expectEmit(false, false, false, true);
        emit Route(lToken0, lToken1, new address[](0));
        _oracle.clearRoute(lToken0, lToken1);

        // assert
        lQueriedRoute = _oracle.route(lToken0, lToken1);
        assertEq(lQueriedRoute, new address[](0));
        (uint256 lPrice,,) = _oracle.priceCache(lToken0, lToken1);
        assertEq(lPrice, 0);
    }

    function testClearRoute_AllWordsCleared() external {
        // arrange
        address[] memory lRoute = new address[](4);
        uint64[] memory lRewardThreshold = new uint64[](3);
        lRewardThreshold[0] = lRewardThreshold[1] = lRewardThreshold[2] = Constants.WAD;
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenC);
        lRoute[2] = address(_tokenB);
        lRoute[3] = address(_tokenD);
        _oracle.setRoute(address(_tokenA), address(_tokenD), lRoute, lRewardThreshold);
        address[] memory lQueriedRoute = _oracle.route(address(_tokenA), address(_tokenD));
        assertEq(lQueriedRoute, lRoute);
        bytes32 lSlot1 = address(_tokenA).calculateSlot(address(_tokenD));
        bytes32 lSlot2 = bytes32(uint256(lSlot1) + 1);
        bytes32 lData = vm.load(address(_oracle), lSlot2);
        assertNotEq(lData, 0);

        // act
        vm.expectEmit(false, false, false, true);
        emit Route(address(_tokenA), address(_tokenD), new address[](0));
        _oracle.clearRoute(address(_tokenA), address(_tokenD));

        // assert
        lQueriedRoute = _oracle.route(address(_tokenA), address(_tokenD));
        assertEq(lQueriedRoute, new address[](0));
        // intermediate routes should still remain
        lQueriedRoute = _oracle.route(address(_tokenB), address(_tokenC));
        address[] memory lIntermediate1 = new address[](2);
        lIntermediate1[0] = address(_tokenB);
        lIntermediate1[1] = address(_tokenC);
        assertEq(lQueriedRoute, lIntermediate1);
        lQueriedRoute = _oracle.route(address(_tokenB), address(_tokenD));
        address[] memory lIntermediate2 = new address[](2);
        lIntermediate2[0] = address(_tokenB);
        lIntermediate2[1] = address(_tokenD);
        assertEq(lQueriedRoute, lIntermediate2);

        // all used slots should be cleared
        lData = vm.load(address(_oracle), lSlot1);
        assertEq(lData, 0);
        lData = vm.load(address(_oracle), lSlot2);
        assertEq(lData, 0);
    }

    function testDesignatePair() external {
        // act
        vm.expectEmit(false, false, false, true);
        emit DesignatePair(address(_tokenA), address(_tokenB), _pair);
        _oracle.designatePair(address(_tokenA), address(_tokenB), _pair);

        // assert
        assertEq(address(_oracle.pairs(address(_tokenA), address(_tokenB))), address(_pair));
    }

    function testDesignatePair_TokenOrderReversed() external {
        // act
        _oracle.designatePair(address(_tokenB), address(_tokenA), _pair);

        // assert
        assertEq(address(_oracle.pairs(address(_tokenA), address(_tokenB))), address(_pair));
        assertEq(address(_oracle.pairs(address(_tokenB), address(_tokenA))), address(0));
    }

    function testUndesignatePair() external {
        // arrange
        _oracle.designatePair(address(_tokenA), address(_tokenB), _pair);

        // act
        vm.expectEmit(false, false, false, true);
        emit DesignatePair(address(_tokenA), address(_tokenB), ReservoirPair(address(0)));
        _oracle.undesignatePair(address(_tokenA), address(_tokenB));

        // assert
        assertEq(address(_oracle.pairs(address(_tokenA), address(_tokenB))), address(0));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 ERROR CONDITIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testSetFallbackOracle_NotOwner() external {
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _oracle.setFallbackOracle(address(456));
    }

    function testDesignatePair_IncorrectPair() external {
        // act & assert
        vm.expectRevert(OracleErrors.IncorrectTokensDesignatePair.selector);
        _oracle.designatePair(address(_tokenA), address(_tokenC), _pair);
    }

    function testDesignatePair_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _oracle.designatePair(address(_tokenA), address(_tokenB), _pair);
    }

    function testUndesignatePair_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _oracle.undesignatePair(address(_tokenA), address(_tokenB));
    }

    function testUpdateTwapPeriod_InvalidTwapPeriod(uint256 aNewPeriod) external {
        // assume
        uint16 lNewPeriod = uint16(bound(aNewPeriod, 1 hours + 1, type(uint16).max));

        // act & assert
        vm.expectRevert(OracleErrors.InvalidTwapPeriod.selector);
        _oracle.updateTwapPeriod(lNewPeriod);
        vm.expectRevert(OracleErrors.InvalidTwapPeriod.selector);
        _oracle.updateTwapPeriod(0);
    }

    function testUpdatePrice_PriceOutOfRange() external {
        // arrange
        ReservoirPair lPair = ReservoirPair(_factory.createPair(IERC20(address(_tokenB)), IERC20(address(_tokenC)), 0));
        _tokenB.mint(address(lPair), 1);
        _tokenC.mint(address(lPair), type(uint104).max);
        lPair.mint(address(this));

        skip(10);
        lPair.sync();
        skip(_oracle.twapPeriod() * 2);
        lPair.sync();

        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;
        lRoute[0] = address(_tokenB);
        lRoute[1] = address(_tokenC);

        _oracle.designatePair(address(_tokenB), address(_tokenC), lPair);
        _oracle.setRoute(address(_tokenB), address(_tokenC), lRoute, lRewardThreshold);

        // act & assert
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleErrors.PriceOutOfRange.selector,
                2_028_266_268_535_138_201_503_457_042_228_640_366_328_194_935_292_146_200_000
            )
        );
        _oracle.updatePrice(address(_tokenB), address(_tokenC), address(0));
    }

    function testUpdatePrice_WriteToNonSimpleRoute() external {
        // arrange
        uint64[] memory lRewardThresholds = new uint64[](2);
        lRewardThresholds[0] = lRewardThresholds[1] = 1;
        address[] memory lRoute = new address[](3);
        lRoute[0] = address(_tokenA);
        lRoute[1] = address(_tokenB);
        lRoute[2] = address(_tokenC);

        _oracle.setRoute(address(_tokenA), address(_tokenC), lRoute, lRewardThresholds);

        // then we change the original B->C route with B->D->C
        address[] memory lModifiedRoute = new address[](3);
        lModifiedRoute[0] = address(_tokenB);
        lModifiedRoute[1] = address(_tokenD);
        lModifiedRoute[2] = address(_tokenC);
        _oracle.setRoute(address(_tokenB), address(_tokenC), lModifiedRoute, lRewardThresholds);

        skip(10);
        _pair.sync();
        _pairBC.sync();
        _pairCD.sync();
        skip(_oracle.twapPeriod());
        _pair.sync();
        _pairBC.sync();
        _pairCD.sync();

        // act & assert
        vm.expectRevert(OracleErrors.WriteToNonSimpleRoute.selector);
        _oracle.updatePrice(address(_tokenA), address(_tokenC), address(0));
    }

    function testUpdatePrice_NoPath() external {
        vm.expectRevert(OracleErrors.NoPath.selector);
        _oracle.updatePrice(address(_tokenD), address(_tokenC), address(0));
    }

    function testSetRoute_SameToken() external {
        // arrange
        address lToken0 = address(0x1);
        address lToken1 = address(0x1);
        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;

        // act & assert
        vm.expectRevert(OracleErrors.InvalidTokensProvided.selector);
        _oracle.setRoute(lToken0, lToken1, lRoute, lRewardThreshold);
    }

    function testSetRoute_NotSorted() external {
        // arrange
        address lToken0 = address(0x21);
        address lToken1 = address(0x2);
        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;
        lRoute[0] = lToken0;
        lRoute[1] = lToken1;

        // act & assert
        vm.expectRevert(OracleErrors.InvalidTokensProvided.selector);
        _oracle.setRoute(lToken0, lToken1, lRoute, lRewardThreshold);
    }

    function testSetRoute_InvalidRouteLength() external {
        // arrange
        address lToken0 = address(0x1);
        address lToken1 = address(0x2);
        address[] memory lTooLong = new address[](5);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;
        lTooLong[0] = lToken0;
        lTooLong[1] = address(0);
        lTooLong[2] = address(0);
        lTooLong[3] = address(0);
        lTooLong[4] = lToken1;
        address[] memory lTooShort = new address[](1);
        lTooShort[0] = lToken0;

        // act & assert
        vm.expectRevert(OracleErrors.InvalidRouteLength.selector);
        _oracle.setRoute(lToken0, lToken1, lTooLong, lRewardThreshold);

        // act & assert
        vm.expectRevert(OracleErrors.InvalidRouteLength.selector);
        _oracle.setRoute(lToken0, lToken1, lTooShort, lRewardThreshold);
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

        uint64[] memory lRewardThreshold = new uint64[](2);
        lRewardThreshold[0] = lRewardThreshold[1] = Constants.WAD;

        // act & assert
        vm.expectRevert(OracleErrors.InvalidRoute.selector);
        _oracle.setRoute(lToken0, lToken1, lInvalidRoute1, lRewardThreshold);
        vm.expectRevert(OracleErrors.InvalidRoute.selector);
        _oracle.setRoute(lToken0, lToken1, lInvalidRoute2, lRewardThreshold);
    }

    function testSetRoute_InvalidRewardThreshold() external {
        // arrange
        address[] memory lRoute = new address[](2);
        uint64[] memory lInvalidRewardThreshold = new uint64[](1);
        lInvalidRewardThreshold[0] = Constants.WAD + 1;
        lRoute[0] = address(_tokenC);
        lRoute[1] = address(_tokenD);

        // act & assert
        vm.expectRevert(OracleErrors.InvalidRewardThreshold.selector);
        _oracle.setRoute(lRoute[0], lRoute[1], lRoute, lInvalidRewardThreshold);

        lInvalidRewardThreshold[0] = 0;
        vm.expectRevert(OracleErrors.InvalidRewardThreshold.selector);
        _oracle.setRoute(lRoute[0], lRoute[1], lRoute, lInvalidRewardThreshold);
    }

    function testSetRoute_InvalidRewardThresholdLength() external {
        address[] memory lRoute = new address[](2);
        uint64[] memory lRewardThreshold = new uint64[](2);
        lRewardThreshold[0] = Constants.WAD;
        lRoute[0] = address(_tokenC);
        lRoute[1] = address(_tokenD);

        // act & assert
        vm.expectRevert(OracleErrors.InvalidRewardThresholdsLength.selector);
        _oracle.setRoute(address(_tokenC), address(_tokenD), lRoute, lRewardThreshold);
    }

    function testSetRoute_InvalidDecimals() external {
        // arrange
        MintableERC20 lToken = new MintableERC20("AA", "AA", 21);
        address[] memory lRoute = new address[](2);
        lRoute[0] = address(lToken) < address(_tokenA) ? address(lToken) : address(_tokenA);
        lRoute[1] = address(lToken) < address(_tokenA) ? address(_tokenA) : address(lToken);
        uint64[] memory lRewardThreshold = new uint64[](1);
        lRewardThreshold[0] = Constants.WAD;

        // act & assert
        vm.expectRevert(OracleErrors.UnsupportedTokenDecimals.selector);
        _oracle.setRoute(
            address(lToken) < address(_tokenA) ? address(lToken) : address(_tokenA),
            address(lToken) < address(_tokenA) ? address(_tokenA) : address(lToken),
            lRoute,
            lRewardThreshold
        );
    }

    function testUpdateRewardGasAmount_NotOwner() external {
        // act & assert
        vm.prank(address(123));
        vm.expectRevert("UNAUTHORIZED");
        _oracle.updateRewardGasAmount(111);
    }

    function testGetQuote_NoFallbackOracle() external {
        // act & assert
        vm.expectRevert(OracleErrors.NoPath.selector);
        _oracle.getQuote(123, address(_tokenD), address(_tokenA));
    }

    function testGetQuote_PriceZero() external {
        // act & assert
        vm.expectRevert(OracleErrors.PriceZero.selector);
        _oracle.getQuote(32_111, address(_tokenA), address(_tokenB));
    }

    function testGetQuote_MultipleHops_PriceZero() external {
        // arrange
        testGetQuote_MultipleHops();
        _writePriceCache(address(_tokenB), address(_tokenC), 0);

        // act & assert
        vm.expectRevert(OracleErrors.PriceZero.selector);
        _oracle.getQuote(321_321, address(_tokenA), address(_tokenD));
    }

    function testGetQuote_AmountInTooLarge() external {
        // arrange
        uint256 lAmtIn = Constants.MAX_AMOUNT_IN + 1;

        // act & assert
        vm.expectRevert(OracleErrors.AmountInTooLarge.selector);
        _oracle.getQuote(lAmtIn, address(_tokenA), address(_tokenB));
    }

    function testGetQuote_ERC4626AssetFails() external {
        // arrange
        address lTargetContract = address(_tokenA); // just any address that doesn't impl the `asset()` function

        // act & assert - the target should be called but should not fail despite not having the function. It should only fail when attempting to query the fallback
        vm.expectCall(lTargetContract, abi.encodeCall(IERC4626.asset, ()));
        vm.expectRevert(OracleErrors.NoPath.selector);
        _oracle.getQuote(123, lTargetContract, address(_tokenD));
    }

    function testValidatePair_NoDesignatedPair() external {
        // arrange
        skip(1);
        _pair.sync();
        skip(_oracle.twapPeriod());
        _pair.sync();

        _oracle.undesignatePair(address(_tokenA), address(_tokenB));

        // act & assert
        vm.expectRevert(OracleErrors.NoDesignatedPair.selector);
        _oracle.updatePrice(address(_tokenA), address(_tokenB), address(this));
    }
}
