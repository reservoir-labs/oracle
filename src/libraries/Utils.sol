// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { OracleErrors } from "src/libraries/OracleErrors.sol";

library Utils {
    /// @dev Square of 1e18 (WAD)
    uint256 internal constant WAD_SQUARED = 1e36;

    error OutOfRange(uint256 value);

    // returns the lower address followed by the higher address
    function sortTokens(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @dev aToken0 has to be strictly less than aToken1
    function calculateSlot(address aToken0, address aToken1) internal pure returns (bytes32) {
        return keccak256(abi.encode(aToken0, aToken1));
    }

    function invertWad(uint256 x) internal pure returns (uint256) {
        if (x == 0 || x > WAD_SQUARED) revert OutOfRange(x);

        return WAD_SQUARED / x;
    }
}
