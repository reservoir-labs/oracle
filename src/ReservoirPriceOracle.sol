// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { NoDesignatedPair } from "src/Errors.sol";
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

contract ReservoirPriceOracle is IPriceOracle, IReservoirPriceOracle, Owned(msg.sender), ReentrancyGuard {
    using FixedPointMathLib for uint256;
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
    event RewardMultiplier(uint256 newMultiplier);
    event Route(address token0, address token1, address[] route);
    event Price(address token0, address token1, uint256 price);
    event TwapPeriod(uint256 newPeriod);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       ERRORS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    error RPC_THRESHOLD_TOO_HIGH();
    error RPC_INVALID_TWAP_PERIOD();
    error RPC_SAME_TOKEN();
    error RPC_TOKENS_UNSORTED();
    error RPC_INVALID_ROUTE_LENGTH();
    error RPC_INVALID_ROUTE();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice percentage change greater than which, a price update with the oracles would succeed
    /// 1e18 == 100%
    uint64 public priceDeviationThreshold;

    /// @notice multiples of the base fee the contract rewards the caller for updating the price when it goes
    /// beyond the `priceDeviationThreshold`
    uint64 public rewardMultiplier;

    /// @notice TWAP period for querying the oracle in seconds
    uint64 public twapPeriod;

    /// @notice Designated pairs to serve as price feed for a certain token0 and token1
    mapping(address token0 => mapping(address token1 => ReservoirPair pair)) public pairs;

    /// @notice The latest cached geometric TWAP of token1/token0, where the address of token0 is strictly less than the address of token1
    /// Stored in the form of a 18 decimal fixed point number.
    /// Supported price range: 1wei to 1e36, due to the need to support inverting price via `Utils.invertWad`
    /// To obtain the price for token0/token1, calculate the reciprocal using Utils.invertWad()
    mapping(address token0 => mapping(address token1 => uint256 price)) public priceCache;

    /// @notice Defines the route to determine price of token0, where the address of token0 is strictly less than the address of token1
    mapping(address token0 => mapping(address token1 => address[] path)) private _route;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR, FALLBACKS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor(uint64 aThreshold, uint64 aTwapPeriod, uint64 aMultiplier) {
        updatePriceDeviationThreshold(aThreshold);
        updateTwapPeriod(aTwapPeriod);
        updateRewardMultiplier(aMultiplier);
    }

    /// @dev contract will hold native tokens to be distributed as gas bounty for updating the prices
    /// anyone can contribute native tokens to this contract
    receive() external payable { }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       MODIFIERS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    modifier validateTokens(address aTokenA, address aTokenB) {
        if (aTokenA == aTokenB) revert RPC_SAME_TOKEN();
        _;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   PUBLIC FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // IPriceOracle

    /// @inheritdoc IPriceOracle
    function getQuote(uint256 aAmount, address aBase, address aQuote)
        external
        view
        validateTokens(aBase, aQuote)
        returns (uint256 rOut)
    {
        rOut = _getQuote(aAmount, aBase, aQuote);
    }

    /// @inheritdoc IPriceOracle
    function getQuotes(uint256 aAmount, address aBase, address aQuote)
        external
        view
        validateTokens(aBase, aQuote)
        returns (uint256 rBidOut, uint256 rAskOut)
    {
        uint256 lResult = _getQuote(aAmount, aBase, aQuote);
        (rBidOut, rAskOut) = (lResult, lResult);
    }

    // price update related functions

    function gasBountyAvailable() external view returns (uint256) {
        return address(this).balance;
    }

    function route(address aToken0, address aToken1) external view returns (address[] memory) {
        return _route[aToken0][aToken1];
    }

    /// @notice Updates the TWAP price for all simple routes between `aTokenA` and `aTokenB`. Will also update intermediate routes if the route defined between
    /// aTokenA and aTokenB is longer than 1 hop
    /// However, if the route between aTokenA and aTokenB is composite route (more than 1 hop), no cache entry is written
    /// for priceCache[aTokenA][aTokenB] but instead the prices of its constituent simple routes will be written.
    /// @param aTokenA Address of one of the tokens for the price update. Does not have to be less than address of aTokenB
    /// @param aTokenB Address of one of the tokens for the price update. Does not have to be greater than address of aTokenA
    /// @param aRewardRecipient The beneficiary of the reward. Must implement the receive function if is a smart contract address
    function updatePrice(address aTokenA, address aTokenB, address aRewardRecipient)
        external
        validateTokens(aTokenA, aTokenB)
        nonReentrant
    {
        (address lToken0, address lToken1) = aTokenA.sortTokens(aTokenB);

        address[] memory lRoute = _route[lToken0][lToken1];
        if (lRoute.length == 0) revert PO_NoPath();

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

            // determine if price has moved beyond the threshold, and pay out reward if so
            if (_calcPercentageDiff(priceCache[lBase][lQuote], lNewPrice) >= priceDeviationThreshold) {
                _rewardUpdater(aRewardRecipient);
            }

            priceCache[lBase][lQuote] = lNewPrice;
            // TODO: worth the gas cost? who will consume it off chain?
            emit Price(lBase, lQuote, lNewPrice);
        }
    }

    // IReservoirPriceOracle

    /// @inheritdoc IReservoirPriceOracle
    function getTimeWeightedAverage(OracleAverageQuery[] memory aQueries)
        public
        view
        returns (
            // nonReentrant
            uint256[] memory rResults
        )
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
    function getLatest(OracleLatestQuery calldata aQuery) external view /*nonReentrant*/ returns (uint256) {
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
        returns (
            // nonReentrant
            int256[] memory rResults
        )
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
        if (address(aPair) == address(0)) revert NoDesignatedPair();
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

    function _rewardUpdater(address lRecipient) internal {
        // N.B. Revisit this whenever deployment on a new chain is needed
        // we use `block.basefee` instead of `ArbGasInfo::getMinimumGasPrice()` on ARB because the latter will always return
        // the demand insensitive base fee, while the former can return real higher fees during times of congestion
        // safety: this mul will not overflow even in extreme cases of `block.basefee`
        uint256 lPayoutAmt = block.basefee * rewardMultiplier;

        if (lPayoutAmt <= address(this).balance) {
            payable(lRecipient).transfer(lPayoutAmt);
        } else { } // do nothing if lPayoutAmt is greater than the balance
    }

    function _getQuote(uint256 aAmount, address aBase, address aQuote) internal view returns (uint256 rOut) {
        (address lToken0, address lToken1) = aBase.sortTokens(aQuote);

        address[] memory lRoute = _route[lToken0][lToken1];
        if (lRoute.length == 0) revert PO_NoPath();

        uint256 lPrice = WAD;
        for (uint256 i = 0; i < lRoute.length - 1; ++i) {
            // we need to sort token addresses again since intermediate path addresses are not guaranteed to be sorted
            (address lLowerToken, address lHigherToken) = lRoute[i].sortTokens(lRoute[i + 1]);

            // it is assumed that subroutes defined here are simple routes and not composite routes
            // meaning, each segment of the route represents a real price between pair, and not the result of composite routing
            // therefore we do not check `_route` again to ensure that there is indeed a route
            uint256 lRoutePrice = priceCache[lLowerToken][lHigherToken];
            lPrice = lPrice * (lLowerToken == lRoute[i] ? lRoutePrice : lRoutePrice.invertWad()) / WAD;
        }

        // idea: can build a cache of decimals to save on making external calls?
        uint256 lBaseDecimals = IERC20(aBase).decimals();
        uint256 lQuoteDecimals = IERC20(aQuote).decimals();

        lPrice = lToken0 == aBase ? lPrice : lPrice.invertWad();
        // quoteAmountOut = baseAmountIn * wadPrice * quoteDecimalScale / baseDecimalScale / WAD
        rOut = (aAmount * lPrice).fullMulDiv(10 ** lQuoteDecimals, (10 ** lBaseDecimals) * WAD);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ADMIN FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function updatePriceDeviationThreshold(uint64 aNewThreshold) public onlyOwner {
        if (aNewThreshold > MAX_DEVIATION_THRESHOLD) {
            revert RPC_THRESHOLD_TOO_HIGH();
        }

        priceDeviationThreshold = aNewThreshold;
        emit PriceDeviationThreshold(aNewThreshold);
    }

    function updateTwapPeriod(uint64 aNewPeriod) public onlyOwner {
        if (aNewPeriod == 0 || aNewPeriod > MAX_TWAP_PERIOD) {
            revert RPC_INVALID_TWAP_PERIOD();
        }
        twapPeriod = aNewPeriod;
        emit TwapPeriod(aNewPeriod);
    }

    function updateRewardMultiplier(uint64 aNewMultiplier) public onlyOwner {
        rewardMultiplier = aNewMultiplier;
        emit RewardMultiplier(aNewMultiplier);
    }

    // sets a specific pair to serve as price feed for a certain route
    // TODO: actually is it necessary to have so many args? Maybe all we need is whitelistPair(ReservoirPair)
    function designatePair(address aToken0, address aToken1, ReservoirPair aPair) external nonReentrant onlyOwner {
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
    // should we make this recursive, meaning for a route A-B-C-D
    // besides defining A-D, A-B, B-C, and C-D, we also define
    // A-B-C, B-C-D ?
    function setRoute(address aToken0, address aToken1, address[] calldata aRoute) external onlyOwner {
        if (aToken0 == aToken1) revert RPC_SAME_TOKEN();
        if (aToken1 < aToken0) revert RPC_TOKENS_UNSORTED();
        if (aRoute.length > MAX_ROUTE_LENGTH || aRoute.length < 2) revert RPC_INVALID_ROUTE_LENGTH();
        if (aRoute[0] != aToken0 || aRoute[aRoute.length - 1] != aToken1) revert RPC_INVALID_ROUTE();

        _route[aToken0][aToken1] = aRoute;
        emit Route(aToken0, aToken1, aRoute);

        // iteratively define those subroutes if undefined
        if (aRoute.length > 2) {
            for (uint256 i = 0; i < aRoute.length - 1; ++i) {
                (address lLowerToken, address lHigherToken) = aRoute[i].sortTokens(aRoute[i + 1]);

                // if route is undefined
                address[] memory lExisting = _route[lLowerToken][lHigherToken];
                if (lExisting.length == 0) {
                    address[] memory lSubroute = new address[](2);
                    lSubroute[0] = lLowerToken;
                    lSubroute[1] = lHigherToken;

                    _route[lLowerToken][lHigherToken] = lSubroute;
                    emit Route(lLowerToken, lHigherToken, lSubroute);
                }
            }
        }
        // should we update prices right after setting the route?
    }

    function clearRoute(address aToken0, address aToken1) external onlyOwner {
        if (aToken0 == aToken1) revert RPC_SAME_TOKEN();
        if (aToken1 < aToken0) revert RPC_TOKENS_UNSORTED();

        delete _route[aToken0][aToken1];
        emit Route(aToken0, aToken1, new address[](0));
    }
}
