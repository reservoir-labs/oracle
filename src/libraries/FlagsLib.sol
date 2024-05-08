// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Bytes32Lib } from "amm-core/libraries/Bytes32.sol";

type Flag is bytes1;
//type Data is bytes32;

library FlagsLib {
    using Bytes32Lib for *;

    error DECIMAL_DIFF_OUT_OF_RANGE();

    bytes32 public constant FLAG_UNINITIALIZED = bytes32(uint256(0x0));
    bytes32 public constant FLAG_SIMPLE_PRICE = bytes32(uint256(0x1));
    bytes32 public constant FLAG_COMPOSITE_NEXT = bytes32(uint256(0x2));
    bytes32 public constant FLAG_COMPOSITE_END = bytes32(uint256(0x3));

    function getRouteFlag(bytes32 aData) internal pure returns (bytes32) {
        return aData >> 248;
    }

    function isSimplePrice(bytes32 aData) internal pure returns (bool) {
        return getRouteFlag(aData) == FLAG_SIMPLE_PRICE;
    }

    // Positive value indicates that token1 has a greater number of decimals compared to token2
    // while a negative value indicates otherwise.
    // range of values between -18 and 18
    function getDecimalDifference(bytes32 aData) internal pure returns (int256 rDiff) {
        rDiff = int8(uint8(aData[1]));
    }

    // Assumes that aDecimalDifference is between -18 and 18
    function combine(bytes32 aFlag, int256 aDecimalDifference) internal pure returns (bytes32 rCombined) {
        bytes32 lDecimalDifferenceRaw = bytes1(uint8(int8(aDecimalDifference)));
        rCombined = aFlag << 248 | lDecimalDifferenceRaw >> 8;
    }

    function getPrice(bytes32 aData) internal pure returns (uint256 rPrice) {
        rPrice = (aData & 0x0000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff).toUint256();
    }
}
