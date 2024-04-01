// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { GenericFactory, IERC20 } from "amm-core/GenericFactory.sol";
import { ConstantProductPair } from "amm-core/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "amm-core/curve/stable/StablePair.sol";
import { Constants } from "amm-core/Constants.sol";
import { FactoryStoreLib } from "amm-core/libraries/FactoryStore.sol";
import { MintableERC20 } from "lib/amm-core/test/__fixtures/MintableERC20.sol";

import { QueryProcessor, ReservoirPair, Variable, OracleNotInitialized } from "src/libraries/QueryProcessor.sol";

contract QueryProcessorTest is Test {
    using FactoryStoreLib for GenericFactory;

    // TODO: test both negative and positive acc values
    // i.e. accumulator value keeps getting more negative and more positive

    GenericFactory private _factory = new GenericFactory();
    ReservoirPair private _pair;

    MintableERC20 internal _tokenA = new MintableERC20("TokenA", "TA", 6);
    MintableERC20 internal _tokenB = new MintableERC20("TokenB", "TB", 18);

    constructor() {
        _factory.addCurve(type(ConstantProductPair).creationCode);
        _factory.addCurve(type(StablePair).creationCode);

        _factory.write("CP::swapFee", Constants.DEFAULT_SWAP_FEE_CP);
        _factory.write("SP::swapFee", Constants.DEFAULT_SWAP_FEE_SP);
        _factory.write("SP::amplificationCoefficient", Constants.DEFAULT_AMP_COEFF);
        _factory.write("Shared::platformFee", Constants.DEFAULT_PLATFORM_FEE);
        _factory.write("Shared::platformFeeTo", address(this));
        _factory.write("Shared::recoverer", address(this));
        _factory.write("Shared::maxChangeRate", Constants.DEFAULT_MAX_CHANGE_RATE);
        _factory.write("Shared::oracleCaller", address(this));

        _pair = ReservoirPair(_createPair(address(_tokenA), address(_tokenB), 0));
        _tokenA.mint(address(_pair), 103e6);
        _tokenB.mint(address(_pair), 10189e18);
        _pair.mint(address(this));
    }

    function setUp() external {
        // nothing to do here is there?
    }

    function _createPair(address aTokenA, address aTokenB, uint256 aCurveId) internal returns ( address rPair) {
        rPair = _factory.createPair(IERC20(aTokenA), IERC20(aTokenB), aCurveId);
    }

    uint256 private offset;
    modifier setOffset() {
        _;
    }

    uint256 private currentBufferSize;
    modifier setBufferSize() {
        _;
    }

    modifier setAccumulatorPositive(bool aIsPositive) {
        _;
    }

    function testGetInstantValue() external {}

    function testGetTimeWeightedAverage() external { }

    function testGetPastAccumulator_WithoutOffset() external {}
    function testGetPastAccumulator_WithSmallOffset() external {}
    function testGetPastAccumulator_WithLargeOffset() external {}
    function testGetPastAccumulator_WithHighestOffset() external {}

    function testGetPastAccumulator_InterpolatesBetweenPastAccumulator() external {}
    function testGetPastAccumulator_RevertsWithTooOldTimestamp() external {}

    function testFindNearestSample_ExactValue() external {

    }

    function testFindNearestSample_IntermediateValue() external {}
    function testFindNearestSample_DiffOffsets() external {}

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 ERROR CONDITIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testGetInstantValue_NotInitialized() external {
        // arrange
        (,,, uint16 lIndex) = _pair.getReserves();

        // act & assert
        vm.expectRevert(OracleNotInitialized.selector);
        QueryProcessor.getInstantValue(_pair, Variable.RAW_PRICE, lIndex, false);
    }

    function testGetPastAccumulator_BufferEmpty() external {}
    function testGetPastAccumulator_TooLongAgo() external {}
    function testGetPastAccumulator_QueryTooOld() external {
        // expect revert query too old
    }

    function testFindNearestSample_NotInitialized() external { }

    function testGetTimeWeightedAverage_BadSecs() external { }
}
