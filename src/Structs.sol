// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { PriceType } from "src/Enums.sol";

/**
 * @dev Information for a Time Weighted Average query.
 *
 * Each query computes the average over a window of duration `secs` seconds that ended `ago` seconds ago. For
 * example, the average over the past 30 minutes is computed by settings secs to 1800 and ago to 0. If secs is 1800
 * and ago is 1800 as well, the average between 60 and 30 minutes ago is computed instead.
 * The address of `base` is strictly less than the address of `quote`
 */
struct OracleAverageQuery {
    PriceType priceType;
    address base;
    address quote;
    uint256 secs;
    uint256 ago;
}

/**
 * @dev Information for a query for the latest priceType
 *
 * Each query computes the latest instantaneous priceType.
 * The address of `base` is strictly less than the address of `quote`
 */
struct OracleLatestQuery {
    PriceType priceType;
    address base;
    address quote;
}

/**
 * @dev Information for an Accumulator query.
 *
 * Each query estimates the accumulator at a time `ago` seconds ago.
 * The address of `base` is strictly less than the address of `quote`
 */
struct OracleAccumulatorQuery {
    PriceType priceType;
    address base;
    address quote;
    uint256 ago;
}
