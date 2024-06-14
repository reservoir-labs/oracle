// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @dev Collection of all oracle related errors.
library OracleErrors {
    // config errors
    error IncorrectTokensDesignatePair();
    error InvalidRoute();
    error InvalidRouteLength();
    error InvalidTwapPeriod();
    error NoDesignatedPair();
    error PriceDeviationThresholdTooHigh();
    error SameToken();
    error TokensUnsorted();
    error UnsupportedTokenDecimals();

    // query errors
    error AmountInTooLarge();
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
