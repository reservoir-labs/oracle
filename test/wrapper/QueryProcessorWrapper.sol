// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { QueryProcessor, ReservoirPair, Variable, Observation } from "src/libraries/QueryProcessor.sol";

contract QueryProcessorWrapper {
    function getInstantValue(ReservoirPair pair, Variable variable, uint256 index) external view returns (uint256) {
        return QueryProcessor.getInstantValue(pair, variable, index);
    }

    function getTimeWeightedAverage(
        ReservoirPair pair,
        Variable variable,
        uint256 secs,
        uint256 ago,
        uint16 latestIndex
    ) external view returns (uint256) {
        return QueryProcessor.getTimeWeightedAverage(pair, variable, secs, ago, latestIndex);
    }

    function getPastAccumulator(ReservoirPair pair, Variable variable, uint16 latestIndex, uint256 ago)
        external
        view
        returns (int256)
    {
        return QueryProcessor.getPastAccumulator(pair, variable, latestIndex, ago);
    }

    function findNearestSample(ReservoirPair pair, uint256 lookUpDate, uint16 offset, uint16 length)
        external
        view
        returns (Observation memory prev, Observation memory next)
    {
        return QueryProcessor.findNearestSample(pair, lookUpDate, offset, length);
    }
}
