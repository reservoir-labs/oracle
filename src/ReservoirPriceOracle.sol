// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IReservoirPriceOracle, OracleAverageQuery, OracleLatestQuery, OracleAccumulatorQuery, Variable } from "src/interfaces/IReservoirPriceOracle.sol";

contract ReservoirPriceOracle is IReservoirPriceOracle {
    function getTimeWeightedAverage(OracleAverageQuery[] memory aQueries)
        external
        view
        returns (uint256[] memory rResults)
    { }

    function getLatest(OracleLatestQuery calldata aQuery) external view returns (uint256) {
        return 0;
    }

    function getLargestSafeQueryWindow() external view returns (uint256) {
        return 0;
    }

    function getPastAccumulators(OracleAccumulatorQuery[] memory aQueries)
        external
        view
        returns (int256[] memory rResults)
    { }
}
