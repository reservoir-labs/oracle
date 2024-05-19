// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library FlagsLib {
    error DECIMAL_DIFF_OUT_OF_RANGE();

    bytes32 public constant FLAG_UNINITIALIZED = bytes32(uint256(0x0));
    bytes32 public constant FLAG_SIMPLE_PRICE = bytes32(uint256(0x1));
    bytes32 public constant FLAG_COMPOSITE_NEXT = bytes32(uint256(0x2));
    bytes32 public constant FLAG_COMPOSITE_END = bytes32(uint256(0x3));

    function getRouteFlag(bytes32 aData) internal pure returns (bytes32) {
        return aData >> 248;
    }

    function getSecondRouteFlag(bytes32 aData) internal pure returns (bytes32) {
        return aData >> 80 & 0x00000000000000000000000000000000000000000000000000000000000000ff;
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

    function getFourthToken(bytes32 aSecondWord) internal pure returns (address rToken) {
        rToken = address(
            uint160(uint256(aSecondWord & 0x0000000000000000000000ffffffffffffffffffffffffffffffffffffffff00) >> 8)
        );
    }
}
