// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import { PriceType } from "src/Enums.sol";
import { ReservoirPriceOracle } from "src/ReservoirPriceOracle.sol";

contract SetRoute is Script {
    ReservoirPriceOracle constant internal _oracle = ReservoirPriceOracle(payable(0x0e20047f33e6b39Ff2c7c9f2aC0388BbCa20B646));
    address constant internal USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant internal USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    uint256 constant internal _threshold = 0.0002e18; // 0.02% or 2bp

    function run() external {
        address[] memory lRoute = new address[](2);
        lRoute[0] = USDC;
        lRoute[1] = USDT;
        uint64[] memory lThreshold = new uint64[](1);
        lThreshold[0] = uint64(_threshold);

        vm.startBroadcast();
        _oracle.setRoute(USDC, USDT, lRoute, lThreshold);
        vm.stopBroadcast();

        // assert
        (uint256 lPrice, int256 lDecimalDiff, uint256 lRewardThreshold) = _oracle.priceCache(USDC, USDT);
        address[] memory lQueriedRoute = _oracle.route(USDC, USDT);
        require(lPrice == 0, "Price should be 0");
        require(lDecimalDiff == 0, "Decimal diff should be 0");
        require(lRewardThreshold == _threshold, "Reward threshold mismatch");
        require(lQueriedRoute.length == 2, "Route length should be 2");
    }
}
