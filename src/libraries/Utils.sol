// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library Utils {
    // returns the lower address followed by the higher address
    function sortTokens(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @dev aToken0 has to be strictly less than aToken1
    function calculateSlot(address aToken0, address aToken1) internal pure returns (bytes32) {
        return keccak256(abi.encode(aToken0, aToken1));
    }
}
