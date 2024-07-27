// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library Constants {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 public constant MAX_DEVIATION_THRESHOLD = 0.1e18; // 10%
    uint256 public constant MAX_TWAP_PERIOD = 1 hours;
    uint256 public constant MAX_ROUTE_LENGTH = 4;
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_SUPPORTED_PRICE = type(uint128).max;
    uint256 public constant MAX_AMOUNT_IN = type(uint128).max;
    uint16 public constant BP_SCALE = 1e4;
}
