// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { OracleErrors } from "src/libraries/OracleErrors.sol";
import {
    IReservoirPriceOracle,
    OracleAverageQuery,
    OracleLatestQuery,
    OracleAccumulatorQuery,
    Variable
} from "src/interfaces/IReservoirPriceOracle.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { QueryProcessor, ReservoirPair, Buffer } from "src/libraries/QueryProcessor.sol";
import { Utils } from "src/libraries/Utils.sol";
import { Owned } from "lib/amm-core/lib/solmate/src/auth/Owned.sol";
import { ReentrancyGuard } from "lib/amm-core/lib/solmate/src/utils/ReentrancyGuard.sol";
import { FixedPointMathLib } from "lib/amm-core/lib/solady/src/utils/FixedPointMathLib.sol";
import { LibSort } from "lib/solady/src/utils/LibSort.sol";
import { FlagsLib } from "src/libraries/FlagsLib.sol";

contract ReservoirPriceOracle is IPriceOracle, IReservoirPriceOracle, Owned(msg.sender), ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using LibSort for address[];
    using FlagsLib for bytes32;
    using QueryProcessor for ReservoirPair;
    using Utils for *;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 private constant MAX_DEVIATION_THRESHOLD = 0.1e18; // 10%
    uint256 private constant MAX_TWAP_PERIOD = 1 hours;
    uint256 private constant MAX_ROUTE_LENGTH = 4;
    uint256 private constant WAD = 1e18;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       EVENTS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event DesignatePair(address token0, address token1, ReservoirPair pair);
    event PriceDeviationThreshold(uint256 newThreshold);
    event RewardGasAmount(uint256 newAmount);
    event Route(address token0, address token1, address[] route);
    event Price(address token0, address token1, uint256 price);
    event TwapPeriod(uint256 newPeriod);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice percentage change greater than which, a price update may result in a reward payout of native tokens,
    /// subject to availability of rewards.
    /// 1e18 == 100%
    uint64 public priceDeviationThreshold;

    /// @notice multiples of the base fee the contract rewards the caller for updating the price when it goes
    /// beyond the `priceDeviationThreshold`
    uint64 public rewardGasAmount;

    /// @notice TWAP period (in seconds) for querying the oracle
    uint64 public twapPeriod;

    /// @notice Designated pairs to serve as price feed for a certain token0 and token1
    mapping(address token0 => mapping(address token1 => ReservoirPair pair)) public pairs;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR, FALLBACKS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor(uint64 aThreshold, uint64 aTwapPeriod, uint64 aMultiplier) {
        updatePriceDeviationThreshold(aThreshold);
        updateTwapPeriod(aTwapPeriod);
        updateRewardGasAmount(aMultiplier);
    }

    /// @dev contract will hold native tokens to be distributed as gas bounty for updating the prices
    /// anyone can contribute native tokens to this contract
    receive() external payable { }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   PUBLIC FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // IPriceOracle

    function name() external pure returns (string memory) {
        return "RESERVOIR PRICE ORACLE";
    }

    /// @inheritdoc IPriceOracle
    function getQuote(uint256 aAmount, address aBase, address aQuote) external view returns (uint256 rOut) {
        rOut = _getQuote(aAmount, aBase, aQuote);
    }

    /// @inheritdoc IPriceOracle
    function getQuotes(uint256 aAmount, address aBase, address aQuote)
        external
        view
        returns (uint256 rBidOut, uint256 rAskOut)
    {
        uint256 lResult = _getQuote(aAmount, aBase, aQuote);
        (rBidOut, rAskOut) = (lResult, lResult);
    }

    // price update related functions

    function gasBountyAvailable() external view returns (uint256) {
        return address(this).balance;
    }

    function route(address aToken0, address aToken1) external view returns (address[] memory rRoute) {
        (rRoute,,) = _getRouteDecimalDifferencePrice(aToken0, aToken1);
    }

    /// @notice The latest cached geometric TWAP of token1/token0, where the address of token0 is strictly less than the address of token1
    /// Stored in the form of a 18 decimal fixed point number.
    /// Supported price range: 1wei to 1e36, due to the need to support inverting price via `Utils.invertWad`
    /// To obtain the price for token0/token1, calculate the reciprocal using Utils.invertWad()
    /// Only stores prices of simple routes. Does not store prices of composite routes.
    /// Returns 0 for prices of composite routes
    function priceCache(address aToken0, address aToken1) external view returns (uint256 rPrice, int256 rDecimalDiff) {
        (rPrice, rDecimalDiff) = _priceCache(aToken0, aToken1);
    }

    /// @notice Updates the TWAP price for all simple routes between `aTokenA` and `aTokenB`. Will also update intermediate routes if the route defined between
    /// aTokenA and aTokenB is longer than 1 hop
    /// However, if the route between aTokenA and aTokenB is composite route (more than 1 hop), no cache entry is written
    /// for priceCache[aTokenA][aTokenB] but instead the prices of its constituent simple routes will be written.
    /// @param aTokenA Address of one of the tokens for the price update. Does not have to be less than address of aTokenB
    /// @param aTokenB Address of one of the tokens for the price update. Does not have to be greater than address of aTokenA
    /// @param aRewardRecipient The beneficiary of the reward. Must be able to receive ether. Set to address(0) if not seeking a reward
    function updatePrice(address aTokenA, address aTokenB, address aRewardRecipient) public nonReentrant {
        (address lToken0, address lToken1) = aTokenA.sortTokens(aTokenB);

        (address[] memory lRoute,,) = _getRouteDecimalDifferencePrice(lToken0, lToken1);
        if (lRoute.length == 0) revert OracleErrors.NoPath();

        OracleAverageQuery[] memory lQueries = new OracleAverageQuery[](lRoute.length - 1);

        for (uint256 i = 0; i < lRoute.length - 1; ++i) {
            (lToken0, lToken1) = lRoute[i].sortTokens(lRoute[i + 1]);

            lQueries[i] = OracleAverageQuery(
                Variable.RAW_PRICE,
                lToken0,
                lToken1,
                twapPeriod,
                0 // now
            );
        }

        uint256[] memory lNewPrices = getTimeWeightedAverage(lQueries);

        for (uint256 i = 0; i < lNewPrices.length; ++i) {
            address lBase = lQueries[i].base;
            address lQuote = lQueries[i].quote;
            uint256 lNewPrice = lNewPrices[i];

            // assumed to be simple routes and therefore lPrevPrice would only be 0 for the first update
            // consider an optimization here for simple routes: no need to read the price cache again
            // as it has been returned by _getRouteDecimalDifferencePrice in the beginning of the function
            (uint256 lPrevPrice,) = _priceCache(lBase, lQuote);

            // determine if price has moved beyond the threshold, and pay out reward if so
            if (_calcPercentageDiff(lPrevPrice, lNewPrice) >= priceDeviationThreshold) {
                _rewardUpdater(aRewardRecipient);
            }

            _writePriceCache(lBase, lQuote, lNewPrice);
        }
    }

    // IReservoirPriceOracle

    /// @inheritdoc IReservoirPriceOracle
    function getTimeWeightedAverage(OracleAverageQuery[] memory aQueries)
        public
        view
        returns (uint256[] memory rResults)
    {
        rResults = new uint256[](aQueries.length);

        OracleAverageQuery memory lQuery;
        for (uint256 i = 0; i < aQueries.length; ++i) {
            lQuery = aQueries[i];
            (address lToken0, address lToken1) = lQuery.base.sortTokens(lQuery.quote);
            ReservoirPair lPair = pairs[lToken0][lToken1];
            _validatePair(lPair);

            (,,, uint16 lIndex) = lPair.getReserves();
            uint256 lResult = lPair.getTimeWeightedAverage(lQuery.variable, lQuery.secs, lQuery.ago, lIndex);
            rResults[i] = lToken0 == lQuery.base ? lResult : lResult.invertWad();
        }
    }

    /// @inheritdoc IReservoirPriceOracle
    function getLatest(OracleLatestQuery calldata aQuery) external view returns (uint256) {
        (address lToken0, address lToken1) = aQuery.base.sortTokens(aQuery.quote);
        ReservoirPair lPair = pairs[lToken0][lToken1];
        _validatePair(lPair);

        (,,, uint256 lIndex) = lPair.getReserves();
        uint256 lResult = lPair.getInstantValue(aQuery.variable, lIndex, lToken0 == aQuery.quote);
        return lResult;
    }

    /// @inheritdoc IReservoirPriceOracle
    function getPastAccumulators(OracleAccumulatorQuery[] memory aQueries)
        external
        view
        returns (int256[] memory rResults)
    {
        rResults = new int256[](aQueries.length);

        OracleAccumulatorQuery memory query;
        for (uint256 i = 0; i < aQueries.length; ++i) {
            query = aQueries[i];
            (address lToken0, address lToken1) = query.base.sortTokens(query.quote);
            ReservoirPair lPair = pairs[lToken0][lToken1];
            _validatePair(lPair);

            (,,, uint16 lIndex) = lPair.getReserves();
            int256 lAcc = lPair.getPastAccumulator(query.variable, lIndex, query.ago);
            // safety: negation will not overflow as the accumulator's type is int88
            rResults[i] = lToken0 == query.base ? lAcc : -lAcc;
        }
    }

    /// @inheritdoc IReservoirPriceOracle
    function getLargestSafeQueryWindow() external pure returns (uint256) {
        return Buffer.SIZE;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 INTERNAL FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _validatePair(ReservoirPair aPair) internal pure {
        if (address(aPair) == address(0)) revert OracleErrors.NoDesignatedPair();
    }

    // TODO: replace this with safe, audited lib function
    function _calcPercentageDiff(uint256 aOriginal, uint256 aNew) internal pure returns (uint256) {
        if (aOriginal == 0) return 0;

        if (aOriginal > aNew) {
            return (aOriginal - aNew) * 1e18 / aOriginal;
        } else {
            return (aNew - aOriginal) * 1e18 / aOriginal;
        }
    }

    function _rewardUpdater(address aRecipient) internal {
        if (aRecipient == address(0)) return;

        // N.B. Revisit this whenever deployment on a new chain is needed
        // we use `block.basefee` instead of `ArbGasInfo::getMinimumGasPrice()` on ARB because the latter will always return
        // the demand insensitive base fee, while the former can return real higher fees during times of congestion
        // safety: this mul will not overflow even in extreme cases of `block.basefee`
        uint256 lPayoutAmt = block.basefee * rewardGasAmount;

        if (lPayoutAmt <= address(this).balance) {
            payable(aRecipient).transfer(lPayoutAmt);
        } else { } // do nothing if lPayoutAmt is greater than the balance
    }

    /// @return rRoute The route to determine the price between aToken0 and aToken1
    /// @return rDecimalDiff The result of token1.decimals() - token0.decimals() if it's a simple route. 0 otherwise
    /// @return rPrice The price of aToken0/aToken1 if it's a simple route (i.e. rRoute.length == 2). 0 otherwise
    function _getRouteDecimalDifferencePrice(address aToken0, address aToken1)
        internal
        view
        returns (address[] memory rRoute, int256 rDecimalDiff, uint256 rPrice)
    {
        address[] memory lResults = new address[](MAX_ROUTE_LENGTH);
        bytes32 lSlot = aToken0.calculateSlot(aToken1);

        bytes32 lFirstWord;
        uint256 lRouteLength;
        assembly {
            lFirstWord := sload(lSlot)
        }
        bytes32 lFlag = lFirstWord.getRouteFlag();

        // simple route
        if (lFlag == FlagsLib.FLAG_SIMPLE_PRICE) {
            lResults[0] = aToken0;
            lResults[1] = aToken1;
            lRouteLength = 2;
            rDecimalDiff = lFirstWord.getDecimalDifference();
            rPrice = lFirstWord.getPrice();
        }
        // composite route
        else if (lFlag == FlagsLib.FLAG_COMPOSITE_NEXT) {
            bytes32 lSecondWord;
            assembly {
                lSecondWord := sload(add(lSlot, 1))
            }
            address lSecondToken = lFirstWord.getTokenFirstWord();
            address lThirdToken = lFirstWord.getThirdToken(lSecondWord);
            lResults[0] = aToken0;
            lResults[1] = lSecondToken;
            lResults[2] = lThirdToken;
            lRouteLength = 3;

            lFlag = lFirstWord.getSecondRouteFlag();
            if (lFlag == FlagsLib.FLAG_COMPOSITE_NEXT) {
                address lFourthToken = lSecondWord.getFourthToken();
                lResults[3] = lFourthToken;
                lRouteLength += 1;
            } else if (lFlag == FlagsLib.FLAG_COMPOSITE_END) { }
        }
        // no route
        else if (lFlag == FlagsLib.FLAG_UNINITIALIZED) { }

        rRoute = new address[](lRouteLength);
        for (uint256 i = 0; i < lRouteLength; ++i) {
            rRoute[i] = lResults[i];
        }
    }

    /// Calculate the storage slot for this intermediate segment and read it to see if there is an existing
    /// route. If there isn't an existing route, we write it as well.
    /// @dev assumed that aToken0 and aToken1 are not necessarily sorted
    function _checkAndPopulateIntermediateRoute(address aToken0, address aToken1) internal {
        (address lLowerToken, address lHigherToken) = aToken0.sortTokens(aToken1);

        bytes32 lSlot = lLowerToken.calculateSlot(lHigherToken);
        bytes32 lData;
        assembly {
            lData := sload(lSlot)
        }
        if (lData == bytes32(0)) {
            address[] memory lIntermediateRoute = new address[](2);
            lIntermediateRoute[0] = lLowerToken;
            lIntermediateRoute[1] = lHigherToken;
            setRoute(lLowerToken, lHigherToken, lIntermediateRoute);
        }
    }

    // performs an SLOAD to load the simple price
    function _priceCache(address aToken0, address aToken1)
        internal
        view
        returns (uint256 rPrice, int256 rDecimalDiff)
    {
        bytes32 lSlot = aToken0.calculateSlot(aToken1);

        bytes32 lData;
        assembly {
            lData := sload(lSlot)
        }
        if (lData.isSimplePrice()) {
            rPrice = lData.getPrice();
            rDecimalDiff = lData.getDecimalDifference();
        }
    }

    function _writePriceCache(address aToken0, address aToken1, uint256 aNewPrice) internal {
        if (aNewPrice == 0 || aNewPrice > 1e36) revert OracleErrors.PriceOutOfRange(aNewPrice);

        bytes32 lSlot = aToken0.calculateSlot(aToken1);
        bytes32 lData;
        assembly {
            lData := sload(lSlot)
        }
        if (!lData.isSimplePrice()) revert OracleErrors.WriteToNonSimpleRoute();

        int256 lDiff = lData.getDecimalDifference();

        lData = FlagsLib.FLAG_SIMPLE_PRICE.combine(lDiff) | bytes32(aNewPrice);
        assembly {
            sstore(lSlot, lData)
        }
    }

    function _getQuote(uint256 aAmount, address aBase, address aQuote) internal view returns (uint256 rOut) {
        if (aBase == aQuote) return aAmount;
        (address lToken0, address lToken1) = aBase.sortTokens(aQuote);

        (address[] memory lRoute, int256 lDecimalDiff, uint256 lPrice) =
            _getRouteDecimalDifferencePrice(lToken0, lToken1);

        if (lRoute.length == 0) {
            revert OracleErrors.NoPath();
        } else if (lRoute.length == 2) {
            if (lPrice == 0) revert OracleErrors.PriceZero();
            rOut = _calcAmtOut(
                aAmount,
                lRoute[0] == aBase ? lPrice : lPrice.invertWad(),
                lRoute[0] == aBase ? lDecimalDiff : -lDecimalDiff
            );
        }
        // for composite route, read simple prices to derive composite price
        else {
            uint256 lIntermediateAmount = aAmount;

            // reverse the route so we always perform calculations starting from index 0
            if (lRoute[0] != aBase) lRoute.reverse();
            assert(lRoute[0] == aBase);

            for (uint256 i = 0; i < lRoute.length - 1; ++i) {
                (address lLowerToken, address lHigherToken) = lRoute[i].sortTokens(lRoute[i + 1]);
                // it is assumed that intermediate routes defined here are simple routes and not composite routes
                (lPrice, lDecimalDiff) = _priceCache(lLowerToken, lHigherToken);

                if (lPrice == 0) revert OracleErrors.PriceZero();
                if (lLowerToken != lRoute[i]) {
                    lPrice = lPrice.invertWad();
                    lDecimalDiff = -lDecimalDiff;
                }
                lIntermediateAmount = _calcAmtOut(lIntermediateAmount, lPrice, lDecimalDiff);
            }
            rOut = lIntermediateAmount;
        }
    }

    function _calcAmtOut(uint256 aAmountIn, uint256 aPrice, int256 aDecimalDiff) internal pure returns (uint256 rOut) {
        // quoteAmountOut = baseAmountIn * wadPrice * quoteDecimalScale / baseDecimalScale / WAD
        if (aDecimalDiff > 0) {
            rOut = (aAmountIn * aPrice).fullMulDiv(10 ** uint256(aDecimalDiff), WAD);
        } else if (aDecimalDiff < 0) {
            rOut = aAmountIn.fullMulDiv(aPrice, 10 ** uint256(-aDecimalDiff) * WAD);
        }
        // equal decimals
        else {
            rOut = aAmountIn.fullMulDiv(aPrice, WAD);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ADMIN FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function updatePriceDeviationThreshold(uint64 aNewThreshold) public onlyOwner {
        if (aNewThreshold > MAX_DEVIATION_THRESHOLD) {
            revert OracleErrors.PriceDeviationThresholdTooHigh();
        }

        priceDeviationThreshold = aNewThreshold;
        emit PriceDeviationThreshold(aNewThreshold);
    }

    function updateTwapPeriod(uint64 aNewPeriod) public onlyOwner {
        if (aNewPeriod == 0 || aNewPeriod > MAX_TWAP_PERIOD) {
            revert OracleErrors.InvalidTwapPeriod();
        }
        twapPeriod = aNewPeriod;
        emit TwapPeriod(aNewPeriod);
    }

    function updateRewardGasAmount(uint64 aNewMultiplier) public onlyOwner {
        rewardGasAmount = aNewMultiplier;
        emit RewardGasAmount(aNewMultiplier);
    }

    // sets a specific pair to serve as price feed for a certain route
    function designatePair(address aToken0, address aToken1, ReservoirPair aPair) external onlyOwner {
        (aToken0, aToken1) = aToken0.sortTokens(aToken1);
        assert(aToken0 == address(aPair.token0()) && aToken1 == address(aPair.token1()));

        pairs[aToken0][aToken1] = aPair;
        emit DesignatePair(aToken0, aToken1, aPair);
    }

    function undesignatePair(address aToken0, address aToken1) external onlyOwner {
        (aToken0, aToken1) = aToken0.sortTokens(aToken1);

        delete pairs[aToken0][aToken1];
        emit DesignatePair(aToken0, aToken1, ReservoirPair(address(0)));
    }

    /// @notice Sets the price route between aToken0 and aToken1, and also intermediate routes if previously undefined
    /// @param aToken0 Address of the lower token
    /// @param aToken1 Address of the higher token
    /// @param aRoute Path with which the price between aToken0 and aToken1 should be derived
    function setRoute(address aToken0, address aToken1, address[] memory aRoute) public onlyOwner {
        uint256 lRouteLength = aRoute.length;

        if (aToken0 == aToken1) revert OracleErrors.SameToken();
        if (aToken1 < aToken0) revert OracleErrors.TokensUnsorted();
        if (lRouteLength > MAX_ROUTE_LENGTH || lRouteLength < 2) revert OracleErrors.InvalidRouteLength();
        if (aRoute[0] != aToken0 || aRoute[lRouteLength - 1] != aToken1) revert OracleErrors.InvalidRoute();

        bytes32 lSlot = aToken0.calculateSlot(aToken1);

        // simple route
        if (lRouteLength == 2) {
            uint256 lToken0Decimals = IERC20(aToken0).decimals();
            uint256 lToken1Decimals = IERC20(aToken1).decimals();
            if (lToken0Decimals > 18 || lToken1Decimals > 18) revert OracleErrors.UnsupportedTokenDecimals();

            int256 lDiff = int256(lToken1Decimals) - int256(lToken0Decimals);

            bytes32 lData = FlagsLib.FLAG_SIMPLE_PRICE.combine(lDiff);
            assembly {
                // Write data to storage.
                sstore(lSlot, lData)
            }
        }
        // composite route
        else {
            address lSecondToken = aRoute[1];
            address lThirdToken = aRoute[2];
            // Set the uppermost byte of lFirstWord to FLAG_COMPOSITE_NEXT for intermediate hops
            bytes32 lFirstWord = FlagsLib.FLAG_COMPOSITE_NEXT << 248;
            // Move the address to start on the 2nd byte.
            bytes32 lSecondTokenData = bytes32(bytes20(lSecondToken)) >> 8;
            bytes32 lThirdTokenFirst10Bytes = bytes32(bytes20(lThirdToken)) >> 176;

            // Trim away the first 10 bytes since we only want the last 10 bytes.
            bytes32 lThirdTokenSecond10Bytes = bytes32(bytes20(lThirdToken) << 80);
            bytes32 lSecondWord;

            if (lRouteLength == 3) {
                // Set flag before third token to FLAG_COMPOSITE_END
                lFirstWord = lFirstWord | lSecondTokenData | FlagsLib.FLAG_COMPOSITE_END << 80 | lThirdTokenFirst10Bytes;

                lSecondWord = lThirdTokenSecond10Bytes;
            } else if (lRouteLength == 4) {
                // Set flag before third token to FLAG_COMPOSITE_NEXT as there are 4 tokens in total
                lFirstWord =
                    lFirstWord | lSecondTokenData | FlagsLib.FLAG_COMPOSITE_NEXT << 80 | lThirdTokenFirst10Bytes;

                bytes32 lFourthTokenData = bytes32(bytes20(aToken1)) >> 88;
                lSecondWord = lThirdTokenSecond10Bytes | FlagsLib.FLAG_COMPOSITE_END << 168 | lFourthTokenData;

                _checkAndPopulateIntermediateRoute(lThirdToken, aToken1);
            }
            _checkAndPopulateIntermediateRoute(aToken0, lSecondToken);
            _checkAndPopulateIntermediateRoute(lSecondToken, lThirdToken);

            // Write the two words of route into storage.
            assembly {
                sstore(lSlot, lFirstWord)
                sstore(add(lSlot, 1), lSecondWord)
            }
        }
        emit Route(aToken0, aToken1, aRoute);
    }

    function clearRoute(address aToken0, address aToken1) external onlyOwner {
        if (aToken0 == aToken1) revert OracleErrors.SameToken();
        if (aToken1 < aToken0) revert OracleErrors.TokensUnsorted();

        (address[] memory lRoute,,) = _getRouteDecimalDifferencePrice(aToken0, aToken1);

        bytes32 lSlot = aToken0.calculateSlot(aToken1);

        // clear all storage slots that the route has written to previously
        assembly {
            sstore(lSlot, 0)
        }
        // routes with length 3/4 use two words of storage
        if (lRoute.length > 2) {
            assembly {
                sstore(add(lSlot, 1), 0)
            }
        }
        emit Route(aToken0, aToken1, new address[](0));
    }
}
