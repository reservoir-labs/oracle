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

    /// @dev Assumes that `aOriginal` and `aNew` is less than or equal to
    /// `Constants.MAX_SUPPORTED_PRICE`. So multiplication by 1e18 will not overflow.
    function calcPercentageDiff(uint256 aOriginal, uint256 aNew) internal pure returns (uint256) {
        unchecked {
            if (aOriginal == 0) return 0;

            if (aOriginal > aNew) {
                return (aOriginal - aNew) * 1e18 / aOriginal;
            } else {
                return (aNew - aOriginal) * 1e18 / aOriginal;
            }
        }
    }
}
