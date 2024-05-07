// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Bytes32Lib } from "amm-core/libraries/Bytes32.sol";

type Flag is bytes1;
//type Data is bytes32;

library FlagsLib {
    using Bytes32Lib for bytes32;

    error DECIMAL_DIFF_OUT_OF_RANGE();

    bytes32 public constant FLAG_UNINITIALIZED = bytes32(uint256(0x0));
    bytes32 public constant FLAG_SIMPLE_PRICE = bytes32(uint256(0x1));
    bytes32 public constant FLAG_COMPOSITE_NEXT = bytes32(uint256(0x2));
    bytes32 public constant FLAG_COMPOSITE_END = bytes32(uint256(0x3));

    function getRouteFlag(bytes32 aData) internal pure returns (bytes32) {
        return aData >> 254;
    }

    function isSimplePrice(bytes32 aData) internal pure returns (bool) {
        return getRouteFlag(aData) == FLAG_SIMPLE_PRICE;
    }

    // Positive value indicates that token1 has a greater number of decimals compared to token2
    // while a negative value indicates otherwise.
    // range of values between -18 and 18
    function getDecimalDifference(bytes32 aData) internal pure returns (int256) {
        bytes1 lFirstByte = aData[0];
        bytes1 lRawData = lFirstByte & 0x3f; // mask out the route flag

        // negative number
        if (lRawData & bytes1(0x20) != bytes1(0)) {
            bytes1 lAbs = lRawData & 0x1f;
            return -int256(uint256(bytes32(lAbs) >> 248));
        }
        // positive number
        else {
            return int256(uint256(bytes32(lRawData) >> 248));
        }
    }

    // Packs the decimal difference into a 6 bit space from bits 3-8, with the leftmost bit used to indicate the sign
    // Assumes that aDecimalDifference is between -18 and 18
    function packDecimalDifference(int256 aDecimalDifference) internal pure returns (bytes32 rPacked) {
        if (aDecimalDifference < -18 || aDecimalDifference > 18) revert DECIMAL_DIFF_OUT_OF_RANGE();

        bytes32 lSignBit;
        if (aDecimalDifference < 0) {
            lSignBit = bytes1(0x20); // 0b00100000
            aDecimalDifference = ~aDecimalDifference + 1;
        }
        rPacked = lSignBit | bytes32(uint256(aDecimalDifference)) << 248;
    }

    function combine(bytes32 aFlag, int256 aDecimalDifference) internal pure returns (bytes32 rCombined) {
        bytes32 lPackedDecimalDiff = packDecimalDifference(aDecimalDifference);
        rCombined = aFlag << 254 | lPackedDecimalDiff;
    }

    function getPrice(bytes32 aData) internal pure returns (uint256 rPrice) {
        rPrice = (aData & 0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff).toUint256();
    }
}
