// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Test, console2, stdError } from "forge-std/Test.sol";

import { GenericFactory, IERC20 } from "amm-core/GenericFactory.sol";
import { ReservoirPair } from "amm-core/ReservoirPair.sol";
import { ConstantProductPair } from "amm-core/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "amm-core/curve/stable/StablePair.sol";
import { Constants } from "amm-core/Constants.sol";
import { FactoryStoreLib } from "amm-core/libraries/FactoryStore.sol";
import { MintableERC20 } from "lib/amm-core/test/__fixtures/MintableERC20.sol";

import { ReservoirPriceOracle, PriceType, IPriceOracle } from "src/ReservoirPriceOracle.sol";

contract BaseTest is Test {
    using FactoryStoreLib for GenericFactory;

    uint64 internal constant DEFAULT_REWARD_GAS_AMOUNT = 200_000;
    uint64 internal constant DEFAULT_TWAP_PERIOD = 15 minutes;

    GenericFactory internal _factory = new GenericFactory();
    ReservoirPair internal _pair;
    ReservoirPair internal _pairBC;
    ReservoirPair internal _pairCD;

    ReservoirPriceOracle internal _oracle =
        new ReservoirPriceOracle(DEFAULT_TWAP_PERIOD, DEFAULT_REWARD_GAS_AMOUNT, PriceType.CLAMPED_PRICE);

    MintableERC20 internal _tokenA = MintableERC20(address(0x100));
    MintableERC20 internal _tokenB = MintableERC20(address(0x200));
    MintableERC20 internal _tokenC = MintableERC20(address(0x300));
    MintableERC20 internal _tokenD = MintableERC20(address(0x400));

    constructor() {
        // we do this to have certainty that these token addresses are in ascending order, for easy testing
        deployCodeTo("MintableERC20.sol", abi.encode("TokenA", "TA", uint8(6)), address(_tokenA));
        deployCodeTo("MintableERC20.sol", abi.encode("TokenB", "TB", uint8(18)), address(_tokenB));
        deployCodeTo("MintableERC20.sol", abi.encode("TokenC", "TC", uint8(10)), address(_tokenC));
        deployCodeTo("MintableERC20.sol", abi.encode("TokenD", "TD", uint8(6)), address(_tokenD));

        _factory.addCurve(type(ConstantProductPair).creationCode);
        _factory.addCurve(type(StablePair).creationCode);

        _factory.write("CP::swapFee", Constants.DEFAULT_SWAP_FEE_CP);
        _factory.write("SP::swapFee", Constants.DEFAULT_SWAP_FEE_SP);
        _factory.write("SP::amplificationCoefficient", Constants.DEFAULT_AMP_COEFF);
        _factory.write("Shared::platformFee", Constants.DEFAULT_PLATFORM_FEE);
        _factory.write("Shared::platformFeeTo", address(this));
        _factory.write("Shared::recoverer", address(this));
        _factory.write("Shared::maxChangeRate", Constants.DEFAULT_MAX_CHANGE_RATE);
        _factory.write("Shared::oracleCaller", address(_oracle));
        _factory.write("Shared::maxChangePerTrade", Constants.DEFAULT_MAX_CHANGE_PER_TRADE);

        _pair = ReservoirPair(_createPair(address(_tokenA), address(_tokenB), 0));
        _tokenA.mint(address(_pair), 103e6);
        _tokenB.mint(address(_pair), 10_189e18);
        _pair.mint(address(this));

        _pairBC = ReservoirPair(_createPair(address(_tokenB), address(_tokenC), 0));
        _tokenB.mint(address(_pairBC), 102_303e18);
        _tokenC.mint(address(_pairBC), 292e10);
        _pairBC.mint(address(this));

        _pairCD = ReservoirPair(_createPair(address(_tokenC), address(_tokenD), 0));
        _tokenC.mint(address(_pairCD), 991_102_221e10);
        _tokenD.mint(address(_pairCD), 937_991_222e6);
        _pairCD.mint(address(this));
    }

    function _createPair(address aTokenA, address aTokenB, uint256 aCurveId) internal returns (address rPair) {
        rPair = _factory.createPair(IERC20(aTokenA), IERC20(aTokenB), aCurveId);
    }
}
