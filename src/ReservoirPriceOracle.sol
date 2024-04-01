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
import { Owned } from "lib/amm-core/lib/solmate/src/auth/Owned.sol";

contract ReservoirPriceOracle is IReservoirPriceOracle, Owned(msg.sender) {
    using QueryProcessor for ReservoirPair;

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
        returns (uint256[] memory rResults)
    {
        rResults = new uint256[](aQueries.length);

        OracleAverageQuery memory lQuery;
        for (uint256 i = 0; i < aQueries.length; ++i) {
            lQuery = aQueries[i];
            (address token0, address token1) = _sortTokens(lQuery.base, lQuery.quote);
            ReservoirPair lPair = pairs[token0][token1];
            _validatePair(lPair);

            (,,, uint16 lIndex) = lPair.getReserves();
            // TODO: factor in potential inversion
            rResults[i] = lPair.getTimeWeightedAverage(lQuery, lIndex);
        }
    }

    function getLatest(OracleLatestQuery calldata aQuery) external view returns (uint256) {
        (address token0, address token1) = _sortTokens(aQuery.base, aQuery.quote);
        ReservoirPair lPair = pairs[token0][token1];
        _validatePair(lPair);

        (,,, uint256 lIndex) = lPair.getReserves();
        uint256 lResult = lPair.getInstantValue(aQuery.variable, lIndex, token0 == aQuery.quote);
        return lResult;
    }

    function getLargestSafeQueryWindow() external view returns (uint256) {
        return Buffer.SIZE;
    }

    function getPastAccumulators(OracleAccumulatorQuery[] memory aQueries)
        external
        view
        returns (int256[] memory rResults)
    {
        rResults = new int256[](aQueries.length);

        OracleAccumulatorQuery memory query;
        for (uint256 i = 0; i < aQueries.length; ++i) {
            query = aQueries[i];
            (address token0, address token1) = _sortTokens(query.base, query.quote);
            ReservoirPair lPair = pairs[token0][token1];
            _validatePair(lPair);

            (,,, uint16 lIndex) = lPair.getReserves();
            // TODO: factor in potential inversion
            rResults[i] = lPair.getPastAccumulator(query.variable, lIndex, query.ago);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 INTERNAL FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _validatePair(ReservoirPair aPair) internal pure {
        if (address(aPair) == address(0)) revert NoPairForRoute();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   ADMIN FUNCTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // sets a specific pair to serve as price feed for a certain route
    function setPairForRoute(address aToken0, address aToken1, ReservoirPair aPair) external onlyOwner {
        (aToken0, aToken1) = _sortTokens(aToken0, aToken1);

        pairs[aToken0][aToken1] = aPair;
        emit Route(aToken0, aToken1, aPair);
    }
}
