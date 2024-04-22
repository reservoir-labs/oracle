// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test, console2 } from "forge-std/Test.sol";

contract ReservoirPriceOracleIntegrationTest is Test {
    function setUp() external {
        uint256 lForkId = vm.createFork(getChain("arbitrum_one").rpcUrl);
        vm.selectFork(lForkId);
    }

    function testBlockBaseFee() external {
        // assert
        assertEq(block.basefee, 0.01 gwei);
    }
}
