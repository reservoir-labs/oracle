// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library Utils {
    /// @dev Square of 1e18 (WAD)
    uint256 internal constant WAD_SQUARED = 1e36;

    error PriceOutOfRange();

    // returns the lower address followed by the higher address
    function sortTokens(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function invertWad(uint256 x) internal pure returns (uint256) {
        if (x > WAD_SQUARED || x == 0) revert PriceOutOfRange();

        return WAD_SQUARED / x;
    }
}
