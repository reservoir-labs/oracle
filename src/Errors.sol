// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// oracle related errors
error NoDesignatedPair();
error BadVariableRequest();
error OracleNotInitialized();
error InvalidSeconds();
error QueryTooOld();
error BadSecs();
error PriceOutOfRange(uint256 aPrice);
