// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Owned } from "lib/amm-core/lib/solmate/src/auth/Owned.sol";
import { ReentrancyGuard } from "lib/amm-core/lib/solmate/src/utils/ReentrancyGuard.sol";
import { FixedPointMathLib } from "lib/amm-core/lib/solady/src/utils/FixedPointMathLib.sol";

import {
    IReservoirPriceOracle,
    OracleAverageQuery,
    OracleAccumulatorQuery,
    Variable
} from "src/interfaces/IReservoirPriceOracle.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

import { Utils } from "src/libraries/Utils.sol";

contract ReservoirPriceCache is Owned(msg.sender), ReentrancyGuard, IPriceOracle {
    using FixedPointMathLib for uint256;
    using Utils for address;
    using Utils for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 private constant MAX_DEVIATION_THRESHOLD = 0.1e18; // 10%
    uint256 private constant MAX_TWAP_PERIOD = 1 hours;
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_ROUTE_LENGTH = 4;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       EVENTS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event Oracle(address newOracle);
    event TwapPeriod(uint256 newPeriod);
    event PriceDeviationThreshold(uint256 newThreshold);
    event RewardMultiplier(uint256 newMultiplier);
    event Price(address token0, address token1, uint256 price);
    event Route(address token0, address token1, address[] route);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       ERRORS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    error RPC_THRESHOLD_TOO_HIGH();
    error RPC_TWAP_PERIOD_TOO_HIGH();
    error RPC_SAME_TOKEN();
    error RPC_TOKENS_UNSORTED();
    error RPC_INVALID_ROUTE_LENGTH();
    error RPC_INVALID_ROUTE();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    IReservoirPriceOracle public oracle;

    /// @notice percentage change greater than which, a price update with the oracles would succeed
    /// 1e18 == 100%
    uint64 public priceDeviationThreshold;

    /// @notice multiples of the base fee the contract rewards the caller for updating the price when it goes
    /// beyond the `priceDeviationThreshold`
    uint64 public rewardMultiplier;

    /// @notice TWAP period for querying the oracle in seconds
    uint64 public twapPeriod;

    // the latest cached TWAP of token1/token0, where address of token0 is strictly less than address of token1
    // calculate reciprocal to for price of token0/token1
    mapping(address token0 => mapping(address token1 => uint256 price)) public priceCache;

    mapping(address token0 => mapping(address token1 => address[] path)) private _route;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR, FALLBACKS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor(address aOracle, uint64 aThreshold, uint64 aTwapPeriod, uint64 aMultiplier) {
        updateOracle(aOracle);
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

    // admin functions

    function updateOracle(address aOracle) public onlyOwner {
        oracle = IReservoirPriceOracle(aOracle);
        emit Oracle(aOracle);
    }

    function updatePriceDeviationThreshold(uint64 aNewThreshold) public onlyOwner {
        if (aNewThreshold > MAX_DEVIATION_THRESHOLD) {
            revert RPC_THRESHOLD_TOO_HIGH();
        }

        priceDeviationThreshold = aNewThreshold;
        emit PriceDeviationThreshold(aNewThreshold);
    }

    function updateTwapPeriod(uint64 aNewPeriod) public onlyOwner {
        if (aNewPeriod > MAX_TWAP_PERIOD) {
            revert RPC_TWAP_PERIOD_TOO_HIGH();
        }
        twapPeriod = aNewPeriod;
        emit TwapPeriod(aNewPeriod);
    }

    function updateRewardMultiplier(uint64 aNewMultiplier) public onlyOwner {
        rewardMultiplier = aNewMultiplier;
        emit RewardMultiplier(aNewMultiplier);
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
            for (uint i = 0; i < aRoute.length - 1; ++i) {
                (address lLowerToken, address lHigherToken) = aRoute[i].sortTokens(aRoute[i+1]);

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

    // IPriceOracle

    function getQuote(uint256 aAmount, address aBase, address aQuote)
        external
        view
        validateTokens(aBase, aQuote)
        returns (
            // nonReentrant
            uint256 rOut
        )
    {
        rOut = _getQuote(aAmount, aBase, aQuote);
    }

    function getQuotes(uint256 aAmount, address aBase, address aQuote)
        external
        view
        validateTokens(aBase, aQuote)
        returns (
            // nonReentrant
            uint256 rBidOut,
            uint256 rAskOut
        )
    {
        uint256 lResult = _getQuote(aAmount, aBase, aQuote);
        (rBidOut, rAskOut) = (lResult, lResult);
    }

    // price update related functions

    function isPriceUpdateIncentivized() external view returns (bool) {
        return address(this).balance > 0;
    }

    function gasBountyAvailable() external view returns (uint256) {
        return address(this).balance;
    }

    function route(address aToken0, address aToken1) external view returns (address[] memory) {
        return _route[aToken0][aToken1];
    }

    // @param aRewardRecipient The beneficiary of the reward. Must implement the receive function if is a contract address
    function updatePrice(address aTokenA, address aTokenB, address aRewardRecipient)
        external
        validateTokens(aTokenA, aTokenB)
        nonReentrant
    {
        (address lToken0, address lToken1) = aTokenA.sortTokens(aTokenB);

        OracleAverageQuery[] memory lQueries;
        lQueries[0] = OracleAverageQuery(
            Variable.RAW_PRICE,
            lToken0,
            lToken1,
            twapPeriod,
            0 // now
        );

        uint256 lNewPrice = oracle.getTimeWeightedAverage(lQueries)[0];

        // determine if price has moved beyond the threshold, and pay out reward if so
        if (_calcPercentageDiff(priceCache[lToken0][lToken1], lNewPrice) >= priceDeviationThreshold) {
            _rewardUpdater(aRewardRecipient);
        }

        priceCache[lToken0][lToken1] = lNewPrice;
        emit Price(lToken0, lToken1, lNewPrice);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  INTERNAL FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

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

        uint256 lPrice;
        if (lRoute.length == 2) {
            lPrice = lToken0 == aBase ? priceCache[lToken0][lToken1] : priceCache[lToken0][lToken1].invertWad();
        } else if (lRoute.length > 2) {
            lPrice = WAD;
            for (uint i = 0; i < lRoute.length - 1; ++ i) {
                // we need to sort token addresses again since intermediate path addresses are not guaranteed to be sorted
                (address lLowerToken, address lHigherToken) = lRoute[i].sortTokens(lRoute[i+1]);

                // it is assumed that subroutes defined here are simple routes and not composite routes
                // meaning, each segment of the route represents a real price between pair, and not the result of composite routing
                // therefore we do not check _route again to ensure that there is indeed a route
                uint256 lRoutePrice = priceCache[lLowerToken][lHigherToken];
                lPrice *= lLowerToken == lRoute[i] ? lRoutePrice : lRoutePrice.invertWad();
            }
        }

        // idea: can build a cache of decimals to save on making external calls?
        uint256 lBaseDecimals = IERC20(aBase).decimals();
        uint256 lQuoteDecimals = IERC20(aQuote).decimals();

        // quoteAmountOut = baseAmountIn * wadPrice * quoteDecimalScale / baseDecimalScale / WAD
        rOut = (aAmount * lPrice).fullMulDiv(10 ** lQuoteDecimals, (10 ** lBaseDecimals) * WAD);
    }
}
