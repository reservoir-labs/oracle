// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { NoPairForRoute } from "src/Errors.sol";
import {
    IReservoirPriceOracle,
    OracleAverageQuery,
    OracleLatestQuery,
    OracleAccumulatorQuery,
    Variable
} from "src/interfaces/IReservoirPriceOracle.sol";
import { QueryProcessor, ReservoirPair, Buffer } from "src/libraries/QueryProcessor.sol";
import { Utils } from "src/libraries/Utils.sol";
import { Owned } from "lib/amm-core/lib/solmate/src/auth/Owned.sol";
import { ReentrancyGuard } from "lib/amm-core/lib/solmate/src/utils/ReentrancyGuard.sol";

contract ReservoirPriceOracle is IReservoirPriceOracle, Owned(msg.sender), ReentrancyGuard {
    using QueryProcessor for ReservoirPair;
    using Utils for address;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       EVENTS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event Route(address token0, address token1, ReservoirPair pair);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    mapping(address token0 => mapping(address token1 => ReservoirPair pair)) internal pairs;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   PUBLIC FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getTimeWeightedAverage(OracleAverageQuery[] memory aQueries)
        external
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
            // TODO: factor in potential inversion
            rResults[i] = lPair.getTimeWeightedAverage(lQuery.variable, lQuery.secs, lQuery.ago, lIndex);
        }
    }

    function getLatest(OracleLatestQuery calldata aQuery) external view /*nonReentrant*/ returns (uint256) {
        (address lToken0, address lToken1) = aQuery.base.sortTokens(aQuery.quote);
        ReservoirPair lPair = pairs[lToken0][lToken1];
        _validatePair(lPair);

        (,,, uint256 lIndex) = lPair.getReserves();
        uint256 lResult = lPair.getInstantValue(aQuery.variable, lIndex, lToken0 == aQuery.quote);
        return lResult;
    }

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
            // TODO: factor in potential inversion
            rResults[i] = lPair.getPastAccumulator(query.variable, lIndex, query.ago);
        }
    }

    function getLargestSafeQueryWindow() external pure returns (uint256) {
        return Buffer.SIZE;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 INTERNAL FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _validatePair(ReservoirPair aPair) internal pure {
        if (address(aPair) == address(0)) revert NoPairForRoute();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ADMIN FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // sets a specific pair to serve as price feed for a certain route
    // TODO: actually is it necessary to have so many args? Maybe all we need is whitelistPair(ReservoirPair)
    function setPairForRoute(address aToken0, address aToken1, ReservoirPair aPair) external nonReentrant onlyOwner {
        (aToken0, aToken1) = aToken0.sortTokens(aToken1);
        assert(aToken0 == address(aPair.token0()) && aToken1 == address(aPair.token1()));

        pairs[aToken0][aToken1] = aPair;
        emit Route(aToken0, aToken1, aPair);
    }

    function clearRoute(address aToken0, address aToken1) external onlyOwner {
        (aToken0, aToken1) = aToken0.sortTokens(aToken1);

        delete pairs[aToken0][aToken1];
        emit Route(aToken0, aToken1, ReservoirPair(address(0)));
    }
}
