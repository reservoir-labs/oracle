// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { PriceType } from "src/Enums.sol";
import "forge-std/Script.sol";
import { ReservoirPriceOracle } from "src/ReservoirPriceOracle.sol";

contract DeployScript is Script {
    ReservoirPriceOracle internal _oracle;
    uint16 internal DEFAULT_TWAP_PERIOD = 15 minutes;
    uint64 internal DEFAULT_MULTIPLIER = 200_000;
    PriceType internal DEFAULT_PRICE_TYPE = PriceType.CLAMPED_PRICE;

    function run() external {
        vm.startBroadcast();

        // Deploy ReservoirPriceOracle
        // as we specify a salt, the script will use the canonical `CREATE2_FACTORY` for the respective chain
        _oracle = new ReservoirPriceOracle{salt: bytes32(0)}(DEFAULT_TWAP_PERIOD, DEFAULT_MULTIPLIER, DEFAULT_PRICE_TYPE);

        vm.stopBroadcast();

        require(_oracle.twapPeriod() == DEFAULT_TWAP_PERIOD, "TWAP Period");
        require(_oracle.rewardGasAmount() == DEFAULT_MULTIPLIER, "Multiplier");
        require(_oracle.PRICE_TYPE() == DEFAULT_PRICE_TYPE, "PriceType");
    }
}
