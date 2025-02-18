// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library RoutesLib {
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

    function is2HopRoute(bytes32 aData) internal pure returns (bool) {
        return aData[0] == FLAG_2_HOP_ROUTE;
    }

    function is3HopRoute(bytes32 aData) internal pure returns (bool) {
        return aData[0] == FLAG_3_HOP_ROUTE;
    }

    // Assumes that aDecimalDifference is between -18 and 18
    // Assumes that aPrice is between 1 and `Constants.MAX_SUPPORTED_PRICE`
    // Assumes that aRewardThreshold is between 1 and `Constants.WAD`
    function packSimplePrice(int256 aDecimalDifference, uint256 aPrice, uint256 aRewardThreshold)
        internal
        pure
        returns (bytes32 rPacked)
    {
        bytes32 lDecimalDifferenceRaw = bytes1(uint8(int8(aDecimalDifference)));
        bytes32 lRewardThreshold = bytes8(uint64(aRewardThreshold));
        rPacked = FLAG_SIMPLE_PRICE | lDecimalDifferenceRaw >> 8 | lRewardThreshold >> 16 | bytes32(aPrice);
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
        rFirstWord = FLAG_3_HOP_ROUTE | bytes32(bytes20(aSecondToken)) >> 8;
        rSecondWord = bytes20(aThirdToken);
    }

    // Positive value indicates that token1 has a greater number of decimals compared to token0
    // while a negative value indicates otherwise. Range of values is between -18 and 18
    function getDecimalDifference(bytes32 aData) internal pure returns (int256 rDiff) {
        rDiff = int8(uint8(aData[1]));
    }

    function getPrice(bytes32 aData) internal pure returns (uint256 rPrice) {
        rPrice = uint256(aData & 0x00000000000000000000ffffffffffffffffffffffffffffffffffffffffffff);
    }

    function getRewardThreshold(bytes32 aData) internal pure returns (uint64 rRewardThreshold) {
        rRewardThreshold =
            uint64(uint256((aData & 0x0000ffffffffffffffff00000000000000000000000000000000000000000000) >> 176));
    }

    function getTokenFirstWord(bytes32 aData) internal pure returns (address rToken) {
        rToken =
            address(uint160(uint256(aData & 0x00ffffffffffffffffffffffffffffffffffffffff0000000000000000000000) >> 88));
    }

    function getThirdToken(bytes32 aSecondWord) internal pure returns (address rToken) {
        rToken = address(bytes20(aSecondWord));
    }
}
