// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @dev Collection of all oracle related errors.
library OracleErrors {
    // config errors
    error InvalidRoute();
    error InvalidRouteLength();
    error InvalidTwapPeriod();
    error NoDesignatedPair();
    error PriceDeviationThresholdTooHigh();
    error SameToken();
    error TokensUnsorted();
    error UnsupportedTokenDecimals();

    // query errors
    error BadSecs();
    error BadVariableRequest();
    error InvalidSeconds();
    error NoPath();
    error OracleNotInitialized();
    error PriceZero();
    error QueryTooOld();

    // price update and calculation errors
    error PriceOutOfRange(uint256 aPrice);
    error WriteToNonSimpleRoute();
}
