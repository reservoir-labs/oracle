// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC4626 } from "forge-std/interfaces/IERC4626.sol";

import { OracleErrors } from "src/libraries/OracleErrors.sol";
import { OracleAverageQuery } from "src/Structs.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { QueryProcessor, ReservoirPair, PriceType } from "src/libraries/QueryProcessor.sol";
import { Utils } from "src/libraries/Utils.sol";
import { Owned } from "lib/amm-core/lib/solmate/src/auth/Owned.sol";
import { ReentrancyGuardTransient } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { FixedPointMathLib } from "lib/amm-core/lib/solady/src/utils/FixedPointMathLib.sol";
import { LibSort } from "lib/solady/src/utils/LibSort.sol";
import { Constants } from "src/libraries/Constants.sol";
import { RoutesLib } from "src/libraries/RoutesLib.sol";

contract ReservoirPriceOracle is IPriceOracle, Owned(msg.sender), ReentrancyGuardTransient {
    using FixedPointMathLib for uint256;
    using LibSort for address[];
    using RoutesLib for bytes32;
    using Utils for uint256;
    using QueryProcessor for ReservoirPair;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       EVENTS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event DesignatePair(address token0, address token1, ReservoirPair pair);
    event FallbackOracleSet(address fallbackOracle);
    event PriceUpdateRewardThreshold(address token0, address token1, uint256 threshold);
    event RewardGasAmount(uint256 newAmount);
    event Route(address token0, address token1, address[] route);
    event TwapPeriod(uint256 newPeriod);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice The maximum multiplier of the gas reward for a price update.
    uint256 public constant MAX_REWARD_MULTIPLIER = 4;

    /// @notice The type of price queried and stored, possibilities as defined by `PriceType`.
    PriceType public immutable PRICE_TYPE;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // The following 3 storage variables take up 1 storage slot.

    /// @notice The PriceOracle to call if this router is not configured for base/quote.
    /// @dev If `address(0)` then there is no fallback.
    address public fallbackOracle;

    /// @notice This number is multiplied by the base fee to determine the reward for keepers.
    uint64 public rewardGasAmount;

    /// @notice TWAP period (in seconds) for querying the oracle.
    uint16 public twapPeriod;

    /// @notice Designated pairs to serve as price feed for a certain token0 and token1.
    mapping(address token0 => mapping(address token1 => ReservoirPair pair)) public pairs;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR, FALLBACKS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor(uint16 aTwapPeriod, uint64 aMultiplier, PriceType aType) {
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

    /// @inheritdoc IPriceOracle
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

    /// @notice Returns the defined route between a given pair of tokens if there is one.
    /// @param aToken0 Address of the lower token.
    /// @param aToken1 Address of the higher token.
    /// @return rRoute An array containing the tokens that make up the route.
    /// Contains two elements if it is a simple route (A->B),
    /// Contains three elements if it is a 2 hop route (A->B->C) and so on.
    /// Returns an empty array if there is no route, or if the arg tokens are not sorted.
    function route(address aToken0, address aToken1) external view returns (address[] memory rRoute) {
        (rRoute,,,) = _getRouteDecimalDifferencePrice(aToken0, aToken1);
    }

    /// @notice The latest cached geometric TWAP of token0/token1.
    /// Stored in the form of a 18 decimal fixed point number.
    /// Supported price range: 1wei to `Constants.MAX_SUPPORTED_PRICE`.
    /// Only stores prices of simple routes. Does not store prices of composite routes.
    /// @param aToken0 Address of the lower token.
    /// @param aToken1 Address of the higher token.
    /// @return rPrice The cached price of aToken0/aToken1 for simple routes. Returns 0 for prices of composite routes.
    /// @return rDecimalDiff The difference in decimals as defined by aToken1.decimals() - aToken0.decimals(). Only valid for simple routes.
    /// @return rRewardThreshold The number of basis points of difference in price at and beyond which a reward is applicable for a price update.
    function priceCache(address aToken0, address aToken1)
        external
        view
        returns (uint256 rPrice, int256 rDecimalDiff, uint256 rRewardThreshold)
    {
        (rPrice, rDecimalDiff, rRewardThreshold) = _priceCache(aToken0, aToken1);
    }

    /// @notice Updates the TWAP price for all simple routes between `aTokenA` and `aTokenB`. Will also update intermediate routes if the route defined between
    /// `aTokenA` and `aTokenB` is longer than 1 hop
    /// However, if the route between aTokenA and aTokenB is composite route (more than 1 hop), no cache entry is written
    /// for priceCache[aTokenA][aTokenB] but instead the prices of its constituent simple routes will be written.
    /// Reverts if price is 0 or greater than `Constants.MAX_SUPPORTED_PRICE`.
    /// @param aTokenA Address of one of the tokens for the price update. Does not have to be less than address of aTokenB
    /// @param aTokenB Address of one of the tokens for the price update. Does not have to be greater than address of aTokenA
    /// @param aRewardRecipient The beneficiary of the reward. Must be able to receive ether. Set to address(0) if not seeking a reward
    /// @return rTotalReward The total amount of ETH reward if the price was updated in the same call. Mainly used by keepers and MEV bots to simulate offchain if a price update is worth doing.
    /// Does not take into account if there is sufficient ETH for rewards in the contract. Oracle could have insufficient ETH resulting in no rewards even if called.
    function updatePrice(address aTokenA, address aTokenB, address aRewardRecipient)
        external
        nonReentrant
        returns (uint256 rTotalReward)
    {
        (address lToken0, address lToken1) = Utils.sortTokens(aTokenA, aTokenB);

        (address[] memory lRoute,, uint256 lPrevPrice, uint256 lRewardThreshold) =
            _getRouteDecimalDifferencePrice(lToken0, lToken1);
        require(lRoute.length != 0, OracleErrors.NoPath());

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
            if (lRoute.length != 2) {
                (lPrevPrice,, lRewardThreshold) = _priceCache(lToken0, lToken1);
            }

            _writePriceCache(lToken0, lToken1, lNewPrice);
            // SAFETY: This will not overflow even if reward gas amount is set to the block gas limit (30M at time if writing),
            // and hops are limited by `MAX_ROUTE_LENGTH`.
            unchecked {
                rTotalReward += _calculateReward(lPrevPrice, lNewPrice, lRewardThreshold);
            }
        }

        _rewardUpdater(aRewardRecipient, rTotalReward);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 PRIVATE FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _validatePair(ReservoirPair aPair) private pure {
        require(address(aPair) != address(0), OracleErrors.NoDesignatedPair());
    }

    function _validateTokens(address aToken0, address aToken1) private pure {
        require(aToken0 < aToken1, OracleErrors.InvalidTokensProvided());
    }

    function _getTimeWeightedAverageSingle(OracleAverageQuery memory aQuery) private view returns (uint256 rResult) {
        ReservoirPair lPair = pairs[aQuery.base][aQuery.quote];
        _validatePair(lPair);

        (,,, uint16 lIndex) = lPair.getReserves();
        rResult = lPair.getTimeWeightedAverage(aQuery.priceType, aQuery.secs, aQuery.ago, lIndex);
    }

    function _calculateReward(uint256 aPrevPrice, uint256 aNewPrice, uint256 aRewardThreshold)
        private
        view
        returns (uint256 rReward)
    {
        uint256 lPercentDiff = aPrevPrice.calcPercentageDiff(aNewPrice);

        // SAFETY: this mul will not overflow even in extreme cases of `block.basefee`.
        unchecked {
            if (lPercentDiff < aRewardThreshold) {
                return 0;
            }
            // payout max reward
            else if (lPercentDiff >= aRewardThreshold * MAX_REWARD_MULTIPLIER) {
                // N.B. Revisit this whenever deployment on a new chain is needed
                //
                // we use `block.basefee` instead of `ArbGasInfo::getMinimumGasPrice()`
                // on ARB because the latter will always return the demand insensitive
                // base fee, while the former can return higher fees during times of
                // congestion
                rReward = block.basefee * rewardGasAmount * MAX_REWARD_MULTIPLIER;
            } else {
                // denominator is never 0 as checked by `setRoute`
                rReward = block.basefee * rewardGasAmount * lPercentDiff / aRewardThreshold;
            }
        }
    }

    function _rewardUpdater(address aRecipient, uint256 aReward) private {
        if (aRecipient == address(0) || aReward == 0) return;

        // does not revert under any circumstance
        assembly ("memory-safe") {
            pop(call(gas(), aRecipient, aReward, codesize(), 0x00, codesize(), 0x00))
        }
    }

    /// @return rRoute The route to determine the price between aToken0 and aToken1. Returns an empty array if there is no route.
    /// @return rDecimalDiff The result of token1.decimals() - token0.decimals() if it's a simple route. 0 otherwise.
    /// @return rPrice The price of aToken0/aToken1 if it's a simple route (i.e. rRoute.length == 2). 0 otherwise.
    /// @return rRewardThreshold The number of basis points of difference in price at and beyond which a reward is applicable for a price update.
    function _getRouteDecimalDifferencePrice(address aToken0, address aToken1)
        private
        view
        returns (address[] memory rRoute, int256 rDecimalDiff, uint256 rPrice, uint256 rRewardThreshold)
    {
        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

        bytes32 lFirstWord;
        assembly ("memory-safe") {
            lFirstWord := sload(lSlot)
        }

        // simple route
        if (lFirstWord.isSimplePrice()) {
            rRoute = new address[](2);
            rRoute[0] = aToken0;
            rRoute[1] = aToken1;
            rDecimalDiff = lFirstWord.getDecimalDifference();
            rPrice = lFirstWord.getPrice();
            rRewardThreshold = lFirstWord.getRewardThreshold();
        }
        // composite route
        else if (lFirstWord.isCompositeRoute()) {
            address lSecondToken = lFirstWord.getTokenFirstWord();

            if (lFirstWord.is2HopRoute()) {
                rRoute = new address[](3);
                rRoute[2] = aToken1;
            } else {
                assert(lFirstWord.is3HopRoute());
                bytes32 lSecondWord;
                assembly ("memory-safe") {
                    lSecondWord := sload(add(lSlot, 1))
                }
                address lThirdToken = lSecondWord.getThirdToken();

                rRoute = new address[](4);
                rRoute[2] = lThirdToken;
                rRoute[3] = aToken1;
            }

            rRoute[0] = aToken0;
            rRoute[1] = lSecondToken;
        }
        // no route
        else if (lFirstWord.isUninitialized()) {
            rRoute = new address[](0);
        }
    }

    // Calculate the storage slot for this intermediate segment and read it to see if there is an existing
    // route. If there isn't an existing route, we create one as well.
    function _checkAndPopulateIntermediateRoute(address aTokenA, address aTokenB, uint64 aBpMaxReward) private {
        (address lToken0, address lToken1) = Utils.sortTokens(aTokenA, aTokenB);

        bytes32 lSlot = Utils.calculateSlot(lToken0, lToken1);
        bytes32 lData;
        assembly ("memory-safe") {
            lData := sload(lSlot)
        }
        if (lData == bytes32(0)) {
            address[] memory lIntermediateRoute = new address[](2);
            lIntermediateRoute[0] = lToken0;
            lIntermediateRoute[1] = lToken1;
            uint64[] memory lRewardThreshold = new uint64[](1);
            lRewardThreshold[0] = aBpMaxReward;
            setRoute(lToken0, lToken1, lIntermediateRoute, lRewardThreshold);
        }
    }

    // performs an SLOAD to load 1 word which contains the simple price, decimal difference, and the reward threshold
    function _priceCache(address aToken0, address aToken1)
        private
        view
        returns (uint256 rPrice, int256 rDecimalDiff, uint256 rRewardThreshold)
    {
        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

        bytes32 lData;
        assembly ("memory-safe") {
            lData := sload(lSlot)
        }
        if (lData.isSimplePrice()) {
            rPrice = lData.getPrice();
            rDecimalDiff = lData.getDecimalDifference();
            rRewardThreshold = lData.getRewardThreshold();
        }
    }

    function _writePriceCache(address aToken0, address aToken1, uint256 aNewPrice) private {
        require(aNewPrice != 0 && aNewPrice <= Constants.MAX_SUPPORTED_PRICE, OracleErrors.PriceOutOfRange(aNewPrice));

        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);
        bytes32 lData;
        assembly ("memory-safe") {
            lData := sload(lSlot)
        }
        require(lData.isSimplePrice(), OracleErrors.WriteToNonSimpleRoute());

        lData = RoutesLib.packSimplePrice(lData.getDecimalDifference(), aNewPrice, lData.getRewardThreshold());
        assembly ("memory-safe") {
            sstore(lSlot, lData)
        }
    }

    function _getQuotes(uint256 aAmount, address aBase, address aQuote, bool aIsGetQuotes)
        private
        view
        returns (uint256 rBidOut, uint256 rAskOut)
    {
        if (aBase == aQuote) return (aAmount, aAmount);
        require(aAmount <= Constants.MAX_AMOUNT_IN, OracleErrors.AmountInTooLarge());

        (address lToken0, address lToken1) = Utils.sortTokens(aBase, aQuote);
        (address[] memory lRoute, int256 lDecimalDiff, uint256 lPrice,) =
            _getRouteDecimalDifferencePrice(lToken0, lToken1);

        if (lRoute.length == 0) {
            // There are two cases where the behavior is a bit more unexpected, and that is when:
            // (1) `aBase` is an empty contract, and the revert would not be caught at all, causing
            // the entire operation to fail.
            // (2) an error happens when decoding the return data (specifically the return data length)
            // But this is okay, because if `aBase` is not a contract or tries to return different types,
            // trying to use the fallbackOracle would not yield any results anyway.
            // An alternative would be to use a low level `staticcall`.
            try IERC4626(aBase).asset() returns (address rBaseAsset) {
                uint256 lResolvedAmountIn = IERC4626(aBase).convertToAssets(aAmount);
                return _getQuotes(lResolvedAmountIn, rBaseAsset, aQuote, aIsGetQuotes);
            } catch { } // solhint-disable-line no-empty-blocks

            // route does not exist on our oracle, attempt querying the fallback
            return _useFallbackOracle(aAmount, aBase, aQuote, aIsGetQuotes);
        } else if (lRoute.length == 2) {
            require(lPrice != 0, OracleErrors.PriceZero());
            rBidOut = rAskOut = _calcAmtOut(aAmount, lPrice, lDecimalDiff, lRoute[0] != aBase);
        }
        // for composite route, read simple prices to derive composite price
        else {
            uint256 lIntermediateAmount = aAmount;

            // reverse the route so we always perform calculations starting from index 0
            if (lRoute[0] != aBase) lRoute.reverse();
            assert(lRoute[0] == aBase);

            for (uint256 i = 0; i < lRoute.length - 1; ++i) {
                (lToken0, lToken1) = Utils.sortTokens(lRoute[i], lRoute[i + 1]);
                // it is assumed that intermediate routes defined here are simple routes and not composite routes
                (lPrice, lDecimalDiff,) = _priceCache(lToken0, lToken1);

                require(lPrice != 0, OracleErrors.PriceZero());
                lIntermediateAmount = _calcAmtOut(lIntermediateAmount, lPrice, lDecimalDiff, lRoute[i] != lToken0);
            }
            rBidOut = rAskOut = lIntermediateAmount;
        }
    }

    /// @dev aPrice assumed to be > 0, as checked by _getQuote
    function _calcAmtOut(uint256 aAmountIn, uint256 aPrice, int256 aDecimalDiff, bool aInverse)
        private
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
        private
        view
        returns (uint256 rBidOut, uint256 rAskOut)
    {
        require(fallbackOracle != address(0), OracleErrors.NoPath());

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

    function updateTwapPeriod(uint16 aNewPeriod) public onlyOwner {
        require(aNewPeriod != 0 && aNewPeriod <= Constants.MAX_TWAP_PERIOD, OracleErrors.InvalidTwapPeriod());

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
        require(
            aTokenA == address(aPair.token0()) && aTokenB == address(aPair.token1()),
            OracleErrors.IncorrectTokensDesignatePair()
        );

        pairs[aTokenA][aTokenB] = aPair;
        emit DesignatePair(aTokenA, aTokenB, aPair);
    }

    function undesignatePair(address aToken0, address aToken1) external onlyOwner {
        (aToken0, aToken1) = Utils.sortTokens(aToken0, aToken1);

        delete pairs[aToken0][aToken1];
        emit DesignatePair(aToken0, aToken1, ReservoirPair(address(0)));
    }

    /// @notice Sets the price route between aToken0 and aToken1, and also intermediate routes if previously undefined.
    /// @param aToken0 Address of the lower token.
    /// @param aToken1 Address of the higher token.
    /// @param aRoute Path with which the price between aToken0 and aToken1 should be derived.
    /// @param aRewardThresholds Array of basis points at and beyond which a reward is applicable for a price update.
    function setRoute(address aToken0, address aToken1, address[] memory aRoute, uint64[] memory aRewardThresholds)
        public
        onlyOwner
    {
        uint256 lRouteLength = aRoute.length;

        _validateTokens(aToken0, aToken1);
        require(lRouteLength > 1 && lRouteLength <= Constants.MAX_ROUTE_LENGTH, OracleErrors.InvalidRouteLength());
        require(aRoute[0] == aToken0 && aRoute[lRouteLength - 1] == aToken1, OracleErrors.InvalidRoute());
        require(aRewardThresholds.length == lRouteLength - 1, OracleErrors.InvalidRewardThresholdsLength());

        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

        // simple route
        if (lRouteLength == 2) {
            uint256 lToken0Decimals = IERC20(aToken0).decimals();
            uint256 lToken1Decimals = IERC20(aToken1).decimals();
            require(lToken0Decimals <= 18 && lToken1Decimals <= 18, OracleErrors.UnsupportedTokenDecimals());

            int256 lDiff = int256(lToken1Decimals) - int256(lToken0Decimals);

            uint256 lRewardThreshold = aRewardThresholds[0];
            require(
                lRewardThreshold <= Constants.WAD && lRewardThreshold != 0, OracleErrors.InvalidRewardThreshold()
            );

            bytes32 lData = RoutesLib.packSimplePrice(lDiff, 0, lRewardThreshold);
            assembly ("memory-safe") {
                // Write data to storage.
                sstore(lSlot, lData)
            }

            emit PriceUpdateRewardThreshold(aToken0, aToken1, lRewardThreshold);
        }
        // composite route
        else {
            address lSecondToken = aRoute[1];
            address lThirdToken = aRoute[2];

            if (lRouteLength == 3) {
                bytes32 lData = RoutesLib.pack2HopRoute(lSecondToken);
                assembly ("memory-safe") {
                    sstore(lSlot, lData)
                }
            } else if (lRouteLength == 4) {
                (bytes32 lFirstWord, bytes32 lSecondWord) = RoutesLib.pack3HopRoute(lSecondToken, lThirdToken);

                // Write two words to storage.
                assembly ("memory-safe") {
                    sstore(lSlot, lFirstWord)
                    sstore(add(lSlot, 1), lSecondWord)
                }
                _checkAndPopulateIntermediateRoute(lThirdToken, aToken1, aRewardThresholds[2]);
            }
            _checkAndPopulateIntermediateRoute(aToken0, lSecondToken, aRewardThresholds[0]);
            _checkAndPopulateIntermediateRoute(lSecondToken, lThirdToken, aRewardThresholds[1]);
        }
        emit Route(aToken0, aToken1, aRoute);
    }

    /// @notice Clears the defined route and the corresponding storage slots.
    /// @param aToken0 Address of the lower token.
    /// @param aToken1 Address of the higher token.
    function clearRoute(address aToken0, address aToken1) external onlyOwner {
        _validateTokens(aToken0, aToken1);

        (address[] memory lRoute,,,) = _getRouteDecimalDifferencePrice(aToken0, aToken1);

        bytes32 lSlot = Utils.calculateSlot(aToken0, aToken1);

        // clear the storage slot that the route has written to previously
        assembly ("memory-safe") {
            sstore(lSlot, 0)
        }

        // routes with length MAX_ROUTE_LENGTH use one more word of storage
        // `setRoute` enforces the MAX_ROUTE_LENGTH limit.
        if (lRoute.length == Constants.MAX_ROUTE_LENGTH) {
            assembly ("memory-safe") {
                sstore(add(lSlot, 1), 0)
            }
        }
        emit Route(aToken0, aToken1, new address[](0));
    }
}
