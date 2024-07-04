// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC4626 } from "forge-std/interfaces/IERC4626.sol";

import { OracleErrors } from "src/libraries/OracleErrors.sol";
import {
    IReservoirPriceOracle,
    OracleAverageQuery,
    OracleLatestQuery
} from "src/interfaces/IReservoirPriceOracle.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { QueryProcessor, ReservoirPair, PriceType } from "src/libraries/QueryProcessor.sol";
import { Utils } from "src/libraries/Utils.sol";
import { Owned } from "lib/amm-core/lib/solmate/src/auth/Owned.sol";
import { ReentrancyGuard } from "lib/amm-core/lib/solmate/src/utils/ReentrancyGuard.sol";
import { FixedPointMathLib } from "lib/amm-core/lib/solady/src/utils/FixedPointMathLib.sol";
import { LibSort } from "lib/solady/src/utils/LibSort.sol";
import { Constants } from "src/libraries/Constants.sol";
import { FlagsLib } from "src/libraries/FlagsLib.sol";

contract ReservoirPriceOracle is IPriceOracle, IReservoirPriceOracle, Owned(msg.sender), ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using LibSort for address[];
    using FlagsLib for *;
    using QueryProcessor for ReservoirPair;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       EVENTS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event DesignatePair(address token0, address token1, ReservoirPair pair);
    event FallbackOracleSet(address fallbackOracle);
    event PriceDeviationThreshold(uint256 newThreshold);
    event RewardGasAmount(uint256 newAmount);
    event Route(address token0, address token1, address[] route);
    event TwapPeriod(uint256 newPeriod);

    /// @notice The type of price queried and stored, possibilities as defined by `PriceType`.
    PriceType public immutable PRICE_TYPE;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice The PriceOracle to call if this router is not configured for base/quote.
    /// @dev If `address(0)` then there is no fallback.
    address public fallbackOracle;

    // The following 3 storage variables take up 1 storage slot.

    /// @notice percentage change greater than which, a price update may result in a reward payout of native tokens,
    /// subject to availability of rewards.
    /// 1e18 == 100%
    uint64 public priceDeviationThreshold;

    /// @notice This number is multiplied by the base fee to determine the reward for keepers
    uint64 public rewardGasAmount;

    /// @notice TWAP period (in seconds) for querying the oracle
    uint64 public twapPeriod;

    /// @notice Designated pairs to serve as price feed for a certain token0 and token1
    mapping(address token0 => mapping(address token1 => ReservoirPair pair)) public pairs;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR, FALLBACKS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor(uint64 aThreshold, uint64 aTwapPeriod, uint64 aMultiplier, PriceType aType) {
        updatePriceDeviationThreshold(aThreshold);
        updateTwapPeriod(aTwapPeriod);
        updateRewardGasAmount(aMultiplier);
        PRICE_TYPE = aType;
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
        (rOut,) = _getQuotes(aAmount, aBase, aQuote, false);
    }

    /// @inheritdoc IPriceOracle
    function getQuotes(uint256 aAmount, address aBase, address aQuote)
        external
        view
        returns (uint256 rBidOut, uint256 rAskOut)
    {
        (rBidOut, rAskOut) = _getQuotes(aAmount, aBase, aQuote, true);
    }

    // price update related functions

    function gasBountyAvailable() external view returns (uint256) {
        return address(this).balance;
    }

    function route(address aToken0, address aToken1) external view returns (address[] memory rRoute) {
        (rRoute,,) = _getRouteDecimalDifferencePrice(aToken0, aToken1);
    }

    /// @notice The latest cached geometric TWAP of token0/token1.
    /// Stored in the form of a 18 decimal fixed point number.
    /// Supported price range: 1wei to `Constants.MAX_SUPPORTED_PRICE`.
    /// Only stores prices of simple routes. Does not store prices of composite routes.
    /// @param aToken0 Address of the lower token.
    /// @param aToken1 Address of the higher token.
    /// @return rPrice The cached price of aToken0/aToken1 for simple routes. Returns 0 for prices of composite routes.
    /// @return rDecimalDiff The difference in decimals as defined by aToken1.decimals() - aToken0.decimals(). Only valid for simple routes.
    function priceCache(address aToken0, address aToken1) external view returns (uint256 rPrice, int256 rDecimalDiff) {
        (rPrice, rDecimalDiff) = _priceCache(aToken0, aToken1);
    }

    /// @notice Updates the TWAP price for all simple routes between `aTokenA` and `aTokenB`. Will also update intermediate routes if the route defined between
    /// `aTokenA` and `aTokenB` is longer than 1 hop
    /// However, if the route between aTokenA and aTokenB is composite route (more than 1 hop), no cache entry is written
    /// for priceCache[aTokenA][aTokenB] but instead the prices of its constituent simple routes will be written.
    /// Reverts if price is 0 or greater than `Constants.MAX_SUPPORTED_PRICE`.
    /// @param aTokenA Address of one of the tokens for the price update. Does not have to be less than address of aTokenB
    /// @param aTokenB Address of one of the tokens for the price update. Does not have to be greater than address of aTokenA
    /// @param aRewardRecipient The beneficiary of the reward. Must be able to receive ether. Set to address(0) if not seeking a reward
    function updatePrice(address aTokenA, address aTokenB, address aRewardRecipient) public nonReentrant {
        (address lToken0, address lToken1) = Utils.sortTokens(aTokenA, aTokenB);

        (address[] memory lRoute,, uint256 lPrevPrice) = _getRouteDecimalDifferencePrice(lToken0, lToken1);
        if (lRoute.length == 0) revert OracleErrors.NoPath();

        for (uint256 i = 0; i < lRoute.length - 1; ++i) {
            (lToken0, lToken1) = Utils.sortTokens(lRoute[i], lRoute[i + 1]);

            uint256 lNewPrice = _getTimeWeightedAverageSingle(
                OracleAverageQuery(
                    PRICE_TYPE,
                    lToken0,
                    lToken1,
                    twapPeriod,
                    0 // now
                )
            );

            // if it's a simple route, we avoid loading the price again from storage
            if (lRoute.length != 2) (lPrevPrice,) = _priceCache(lToken0, lToken1);

            _writePriceCache(lToken0, lToken1, lNewPrice);

            // determine if price has moved beyond the threshold, and pay out reward if so
            if (_calcPercentageDiff(lPrevPrice, lNewPrice) >= priceDeviationThreshold) {
                _rewardUpdater(aRewardRecipient);
            }
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
        for (uint256 i = 0; i < aQueries.length; ++i) {
            rResults[i] = _getTimeWeightedAverageSingle(aQueries[i]);
        }
    }

    /// @inheritdoc IReservoirPriceOracle
    function getLatest(OracleLatestQuery calldata aQuery) external view returns (uint256) {
        ReservoirPair lPair = pairs[aQuery.base][aQuery.quote];
        _validatePair(lPair);

        (,,, uint256 lIndex) = lPair.getReserves();
        uint256 lResult = lPair.getInstantValue(aQuery.priceType, lIndex);
        return lResult;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 INTERNAL FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _validatePair(ReservoirPair aPair) internal pure {
        if (address(aPair) == address(0)) revert OracleErrors.NoDesignatedPair();
    }

    function _getTimeWeightedAverageSingle(OracleAverageQuery memory aQuery) internal view returns (uint256 rResult) {
        ReservoirPair lPair = pairs[aQuery.base][aQuery.quote];
        _validatePair(lPair);

        (,,, uint16 lIndex) = lPair.getReserves();
        rResult = lPair.getTimeWeightedAverage(aQuery.priceType, aQuery.secs, aQuery.ago, lIndex);
    }

    function _calcPercentageDiff(uint256 aOriginal, uint256 aNew) internal pure returns (uint256) {
        unchecked {
            if (aOriginal == 0) return 0;

            // multiplication does not overflow as `aOriginal` and `aNew` is always less than or
            // equal to `Constants.MAX_SUPPORTED_PRICE`, as checked in `_writePriceCache`
            if (aOriginal > aNew) {
                return (aOriginal - aNew) * 1e18 / aOriginal;
            } else {
                return (aNew - aOriginal) * 1e18 / aOriginal;
            }
        }
    }

    function _rewardUpdater(address aRecipient) internal {
        if (aRecipient == address(0)) return;

        // N.B. Revisit this whenever deployment on a new chain is needed
        //
        // we use `block.basefee` instead of `ArbGasInfo::getMinimumGasPrice()`
        // on ARB because the latter will always return the demand insensitive
        // base fee, while the former can return higher fees during times of
        // congestion

        // SAFETY: this mul will not overflow even in extreme cases of `block.basefee`.
        uint256 lPayoutAmt;
        unchecked {
            lPayoutAmt = block.basefee * rewardGasAmount;
        }

        if (lPayoutAmt <= address(this).balance) {
            payable(aRecipient).transfer(lPayoutAmt);
        }
        // do nothing if lPayoutAmt is greater than the balance
    }

    /// @return rRoute The route to determine the price between aToken0 and aToken1
    /// @return rDecimalDiff The result of token1.decimals() - token0.decimals() if it's a simple route. 0 otherwise
    /// @return rPrice The price of aToken0/aToken1 if it's a simple route (i.e. rRoute.length == 2). 0 otherwise
    function _getRouteDecimalDifferencePrice(address aToken0, address aToken1)
        internal
        view
        returns (address[] memory rRoute, int256 rDecimalDiff, uint256 rPrice)
    {
        address[] memory lResults = new address[](Constants.MAX_ROUTE_LENGTH);
        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

        bytes32 lFirstWord;
        uint256 lRouteLength;
        assembly {
            lFirstWord := sload(lSlot)
        }

        // simple route
        if (lFirstWord.isSimplePrice()) {
            lResults[0] = aToken0;
            lResults[1] = aToken1;
            lRouteLength = 2;
            rDecimalDiff = lFirstWord.getDecimalDifference();
            rPrice = lFirstWord.getPrice();
        }
        // composite route
        else if (lFirstWord.isCompositeRoute()) {
            address lSecondToken = lFirstWord.getTokenFirstWord();

            lResults[0] = aToken0;
            lResults[1] = lSecondToken;

            if (lFirstWord.is3HopRoute()) {
                bytes32 lSecondWord;
                assembly {
                    lSecondWord := sload(add(lSlot, 1))
                }
                address lThirdToken = lSecondWord.getThirdToken();

                lResults[2] = lThirdToken;
                lResults[3] = aToken1;
                lRouteLength = 4;
            } else {
                lResults[2] = aToken1;
                lRouteLength = 3;
            }
        }
        // no route
        // solhint-disable-next-line no-empty-blocks
        else if (lFirstWord.isUninitialized()) { }

        rRoute = new address[](lRouteLength);
        for (uint256 i = 0; i < lRouteLength; ++i) {
            rRoute[i] = lResults[i];
        }
    }

    /// Calculate the storage slot for this intermediate segment and read it to see if there is an existing
    /// route. If there isn't an existing route, we write it as well.
    /// @dev assumed that aToken0 and aToken1 are not necessarily sorted
    function _checkAndPopulateIntermediateRoute(address aToken0, address aToken1) internal {
        (address lLowerToken, address lHigherToken) = Utils.sortTokens(aToken0, aToken1);

        bytes32 lSlot = Utils.calculateSlot(lLowerToken, lHigherToken);
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

    // performs an SLOAD to load 1 word which contains the simple price and decimal difference
    function _priceCache(address aToken0, address aToken1)
        internal
        view
        returns (uint256 rPrice, int256 rDecimalDiff)
    {
        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

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
        if (aNewPrice == 0 || aNewPrice > Constants.MAX_SUPPORTED_PRICE) revert OracleErrors.PriceOutOfRange(aNewPrice);

        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);
        bytes32 lData;
        assembly {
            lData := sload(lSlot)
        }
        if (!lData.isSimplePrice()) revert OracleErrors.WriteToNonSimpleRoute();

        int256 lDiff = lData.getDecimalDifference();

        lData = lDiff.packSimplePrice(aNewPrice);
        assembly {
            sstore(lSlot, lData)
        }
    }

    function _getQuotes(uint256 aAmount, address aBase, address aQuote, bool aIsGetQuotes)
        internal
        view
        returns (uint256 rBidOut, uint256 rAskOut)
    {
        if (aBase == aQuote) return (aAmount, aAmount);
        if (aAmount > Constants.MAX_AMOUNT_IN) revert OracleErrors.AmountInTooLarge();

        (address lToken0, address lToken1) = Utils.sortTokens(aBase, aQuote);
        (address[] memory lRoute, int256 lDecimalDiff, uint256 lPrice) =
            _getRouteDecimalDifferencePrice(lToken0, lToken1);

        if (lRoute.length == 0) {
            // REVIEW: Is it possible for `aQuote` to be an IERC4626?
            // There is one case where the behavior is a bit more unexpected, and that is when
            // `aBase` is an empty contract, and the revert would not be caught at all, causing
            // the entire operation to fail. But this is okay, because if `aBase` is not a contract, trying
            // to use the fallbackOracle would not yield any results anyway.
            // An alternative would be to use a low level `staticcall`.
            try IERC4626(aBase).asset() returns (address rBaseAsset) {
                uint256 lResolvedAmountIn = IERC4626(aBase).convertToAssets(aAmount);
                return _getQuotes(lResolvedAmountIn, rBaseAsset, aQuote, aIsGetQuotes);
            } catch { } // solhint-disable-line no-empty-blocks

            // route does not exist on our oracle, attempt querying the fallback
            return _useFallbackOracle(aAmount, aBase, aQuote, aIsGetQuotes);
        } else if (lRoute.length == 2) {
            if (lPrice == 0) revert OracleErrors.PriceZero();
            rBidOut = rAskOut = _calcAmtOut(aAmount, lPrice, lDecimalDiff, lRoute[0] != aBase);
        }
        // for composite route, read simple prices to derive composite price
        else {
            uint256 lIntermediateAmount = aAmount;

            // reverse the route so we always perform calculations starting from index 0
            if (lRoute[0] != aBase) lRoute.reverse();
            assert(lRoute[0] == aBase);

            for (uint256 i = 0; i < lRoute.length - 1; ++i) {
                (address lLowerToken, address lHigherToken) = Utils.sortTokens(lRoute[i], lRoute[i + 1]);
                // it is assumed that intermediate routes defined here are simple routes and not composite routes
                (lPrice, lDecimalDiff) = _priceCache(lLowerToken, lHigherToken);

                if (lPrice == 0) revert OracleErrors.PriceZero();
                lIntermediateAmount = _calcAmtOut(lIntermediateAmount, lPrice, lDecimalDiff, lRoute[i] != lLowerToken);
            }
            rBidOut = rAskOut = lIntermediateAmount;
        }
    }

    /// @dev aPrice assumed to be > 0, as checked by _getQuote
    function _calcAmtOut(uint256 aAmountIn, uint256 aPrice, int256 aDecimalDiff, bool aInverse)
        internal
        pure
        returns (uint256 rOut)
    {
        // formula: baseAmountOut = quoteAmountIn * Constants.WAD * baseDecimalScale / baseQuotePrice / quoteDecimalScale
        if (aInverse) {
            if (aDecimalDiff > 0) {
                rOut = aAmountIn.fullMulDiv(Constants.WAD, aPrice) / 10 ** uint256(aDecimalDiff);
            } else if (aDecimalDiff < 0) {
                rOut = aAmountIn.fullMulDiv(Constants.WAD * 10 ** uint256(-aDecimalDiff), aPrice);
            }
            // equal decimals
            else {
                rOut = aAmountIn.fullMulDiv(Constants.WAD, aPrice);
            }
        } else {
            // formula: quoteAmountOut = baseAmountIn * baseQuotePrice * quoteDecimalScale / baseDecimalScale / Constants.WAD
            if (aDecimalDiff > 0) {
                rOut = aAmountIn.fullMulDiv(aPrice * 10 ** uint256(aDecimalDiff), Constants.WAD);
            } else if (aDecimalDiff < 0) {
                rOut = aAmountIn.fullMulDiv(aPrice, 10 ** uint256(-aDecimalDiff) * Constants.WAD);
            } else {
                rOut = aAmountIn.fullMulDiv(aPrice, Constants.WAD);
            }
        }
    }

    function _useFallbackOracle(uint256 aAmount, address aBase, address aQuote, bool aIsGetQuotes)
        internal
        view
        returns (uint256 rBidOut, uint256 rAskOut)
    {
        if (fallbackOracle == address(0)) revert OracleErrors.NoPath();

        // We do not catch errors here so the fallback oracle will revert if it doesn't support the query.
        if (aIsGetQuotes) (rBidOut, rAskOut) = IPriceOracle(fallbackOracle).getQuotes(aAmount, aBase, aQuote);
        else rBidOut = rAskOut = IPriceOracle(fallbackOracle).getQuote(aAmount, aBase, aQuote);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ADMIN FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function setFallbackOracle(address aFallbackOracle) public onlyOwner {
        fallbackOracle = aFallbackOracle;
        emit FallbackOracleSet(aFallbackOracle);
    }

    function updatePriceDeviationThreshold(uint64 aNewThreshold) public onlyOwner {
        if (aNewThreshold > Constants.MAX_DEVIATION_THRESHOLD) {
            revert OracleErrors.PriceDeviationThresholdTooHigh();
        }

        priceDeviationThreshold = aNewThreshold;
        emit PriceDeviationThreshold(aNewThreshold);
    }

    function updateTwapPeriod(uint64 aNewPeriod) public onlyOwner {
        if (aNewPeriod == 0 || aNewPeriod > Constants.MAX_TWAP_PERIOD) {
            revert OracleErrors.InvalidTwapPeriod();
        }
        twapPeriod = aNewPeriod;
        emit TwapPeriod(aNewPeriod);
    }

    function updateRewardGasAmount(uint64 aNewMultiplier) public onlyOwner {
        rewardGasAmount = aNewMultiplier;
        emit RewardGasAmount(aNewMultiplier);
    }

    /// @notice Sets the pair to serve as price feed for a given route.
    function designatePair(address aTokenA, address aTokenB, ReservoirPair aPair) external onlyOwner {
        (aTokenA, aTokenB) = Utils.sortTokens(aTokenA, aTokenB);
        if (aTokenA != address(aPair.token0()) || aTokenB != address(aPair.token1())) {
            revert OracleErrors.IncorrectTokensDesignatePair();
        }

        pairs[aTokenA][aTokenB] = aPair;
        emit DesignatePair(aTokenA, aTokenB, aPair);
    }

    function undesignatePair(address aToken0, address aToken1) external onlyOwner {
        (aToken0, aToken1) = Utils.sortTokens(aToken0, aToken1);

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
        if (lRouteLength > Constants.MAX_ROUTE_LENGTH || lRouteLength < 2) revert OracleErrors.InvalidRouteLength();
        if (aRoute[0] != aToken0 || aRoute[lRouteLength - 1] != aToken1) revert OracleErrors.InvalidRoute();

        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

        // simple route
        if (lRouteLength == 2) {
            uint256 lToken0Decimals = IERC20(aToken0).decimals();
            uint256 lToken1Decimals = IERC20(aToken1).decimals();
            if (lToken0Decimals > 18 || lToken1Decimals > 18) revert OracleErrors.UnsupportedTokenDecimals();

            int256 lDiff = int256(lToken1Decimals) - int256(lToken0Decimals);

            bytes32 lData = lDiff.packSimplePrice(0);
            assembly {
                // Write data to storage.
                sstore(lSlot, lData)
            }
        }
        // composite route
        else {
            address lSecondToken = aRoute[1];
            address lThirdToken = aRoute[2];

            if (lRouteLength == 3) {
                bytes32 lData = lSecondToken.pack2HopRoute();
                assembly {
                    sstore(lSlot, lData)
                }
            } else if (lRouteLength == 4) {
                (bytes32 lFirstWord, bytes32 lSecondWord) = lSecondToken.pack3HopRoute(lThirdToken);

                // Write two words to storage.
                assembly {
                    sstore(lSlot, lFirstWord)
                    sstore(add(lSlot, 1), lSecondWord)
                }
                _checkAndPopulateIntermediateRoute(lThirdToken, aToken1);
            }
            _checkAndPopulateIntermediateRoute(aToken0, lSecondToken);
            _checkAndPopulateIntermediateRoute(lSecondToken, lThirdToken);
        }
        emit Route(aToken0, aToken1, aRoute);
    }

    function clearRoute(address aToken0, address aToken1) external onlyOwner {
        if (aToken0 == aToken1) revert OracleErrors.SameToken();
        if (aToken1 < aToken0) revert OracleErrors.TokensUnsorted();

        (address[] memory lRoute,,) = _getRouteDecimalDifferencePrice(aToken0, aToken1);

        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

        // clear the storage slot that the route has written to previously
        assembly {
            sstore(lSlot, 0)
        }

        // routes with length MAX_ROUTE_LENGTH use one more word of storage
        // `setRoute` enforces the MAX_ROUTE_LENGTH limit.
        if (lRoute.length == Constants.MAX_ROUTE_LENGTH) {
            assembly {
                sstore(add(lSlot, 1), 0)
            }
        }
        emit Route(aToken0, aToken1, new address[](0));
    }
}
