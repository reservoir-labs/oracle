// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library FlagsLib {
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
    // Assumes that aPrice is between 1 and 1e36
    function packSimplePrice(int256 aDecimalDifference, uint256 aPrice) internal pure returns (bytes32 rPacked) {
        bytes32 lDecimalDifferenceRaw = bytes1(uint8(int8(aDecimalDifference)));
        rPacked = FLAG_SIMPLE_PRICE | lDecimalDifferenceRaw >> 8 | bytes32(aPrice);
    }

    function pack2HopRoute(address aSecondToken) internal pure returns (bytes32 rPacked) {
        // Move aSecondToken to start on the 2nd byte.
        rPacked = FLAG_2_HOP_ROUTE | bytes32(bytes20(aSecondToken)) >> 8;
    }

    function pack3HopRoute(address aSecondToken, address aThirdToken)
        internal
        pure
        returns (bytes32 rFirstWord, bytes32 rSecondWord)
    {
        bytes32 lThirdTokenTop10Bytes = bytes32(bytes20(aThirdToken)) >> 176;
        // Trim away the first 10 bytes since we only want the last 10 bytes.
        bytes32 lThirdTokenBottom10Bytes = bytes32(bytes20(aThirdToken) << 80);

        rFirstWord = FLAG_3_HOP_ROUTE | bytes32(bytes20(aSecondToken)) >> 8 | lThirdTokenTop10Bytes;
        rSecondWord = lThirdTokenBottom10Bytes;
    }

    function getPrice(bytes32 aData) internal pure returns (uint256 rPrice) {
        rPrice = uint256(aData & 0x0000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    }

    function getTokenFirstWord(bytes32 aData) internal pure returns (address rToken) {
        rToken =
            address(uint160(uint256(aData & 0x00ffffffffffffffffffffffffffffffffffffffff0000000000000000000000) >> 88));
    }

    function getThirdToken(bytes32 aFirstWord, bytes32 aSecondWord) internal pure returns (address rToken) {
        bytes32 lTop10Bytes = (aFirstWord & 0x00000000000000000000000000000000000000000000ffffffffffffffffffff) << 80;
        bytes32 lBottom10Bytes = aSecondWord >> 176;
        rToken = address(uint160(uint256(lTop10Bytes | lBottom10Bytes)));
    }
}
