// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library FlagsLib {
    error DECIMAL_DIFF_OUT_OF_RANGE();

    bytes32 public constant FLAG_UNINITIALIZED = bytes32(hex"00");
    bytes32 public constant FLAG_SIMPLE_PRICE = bytes32(hex"01");
    bytes32 public constant FLAG_2_HOP_ROUTE = bytes32(hex"02");
    bytes32 public constant FLAG_3_HOP_ROUTE = bytes32(hex"03");

    function isUninitialized(bytes32 aData) internal pure returns (bool) {
        return aData[0] == FLAG_UNINITIALIZED;
    }

    function isSimplePrice(bytes32 aData) internal pure returns (bool) {
        return aData[0] == FLAG_SIMPLE_PRICE;
    }

    function isCompositeRoute(bytes32 aData) internal pure returns (bool) {
        return aData[0] & hex"02" > 0;
    }

    function is3HopRoute(bytes32 aData) internal pure returns (bool) {
        return aData[0] == FLAG_3_HOP_ROUTE;
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
        rCombined = aFlag | lDecimalDifferenceRaw >> 8;
    }

    function getPrice(bytes32 aData) internal pure returns (uint256 rPrice) {
        rPrice = uint256(aData & 0x0000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    }

    function getTokenFirstWord(bytes32 aData) internal pure returns (address rToken) {
        rToken =
            address(uint160(uint256(aData & 0x00ffffffffffffffffffffffffffffffffffffffff0000000000000000000000) >> 88));
    }

    function getThirdToken(bytes32 aFirstWord, bytes32 aSecondWord) internal pure returns (address rToken) {
        bytes32 lFirst10Bytes = (aFirstWord & 0x00000000000000000000000000000000000000000000ffffffffffffffffffff) << 80;
        bytes32 lLast10Bytes = aSecondWord >> 176;
        rToken = address(uint160(uint256(lFirst10Bytes | lLast10Bytes)));
    }
}
