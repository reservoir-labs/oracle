// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import { PriceType } from "src/Enums.sol";
import { ReservoirPriceOracle } from "src/ReservoirPriceOracle.sol";

contract DeployScript is Script {
    ReservoirPriceOracle internal _oracle;
    uint16 internal DEFAULT_TWAP_PERIOD = 15 minutes;
    uint64 internal DEFAULT_REWARD_GAS_AMOUNT = 100_000;
    PriceType internal DEFAULT_PRICE_TYPE = PriceType.CLAMPED_PRICE;

    function run() external {
        vm.startBroadcast();

        // Deploy ReservoirPriceOracle
        _oracle = new ReservoirPriceOracle(DEFAULT_TWAP_PERIOD, DEFAULT_REWARD_GAS_AMOUNT, DEFAULT_PRICE_TYPE);

        vm.stopBroadcast();

        require(_oracle.twapPeriod() == DEFAULT_TWAP_PERIOD, "TWAP Period");
        require(_oracle.rewardGasAmount() == DEFAULT_REWARD_GAS_AMOUNT, "Multiplier");
        require(_oracle.PRICE_TYPE() == DEFAULT_PRICE_TYPE, "PriceType");
        require(_oracle.owner() == msg.sender, "Owner");
    }
}
