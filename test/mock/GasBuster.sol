// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract GasBuster {
    // Allow the contract to receive ETH
    receive() external payable {
        while (true) {
            // This loop will continue until all gas is consumed
        }
    }
}
