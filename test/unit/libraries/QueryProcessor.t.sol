// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test, console2 } from "forge-std/Test.sol";

import { GenericFactory, IERC20 } from "amm-core/GenericFactory.sol";
import { ConstantProductPair } from "amm-core/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "amm-core/curve/stable/StablePair.sol";
import { Constants } from "amm-core/Constants.sol";
import { FactoryStoreLib } from "amm-core/libraries/FactoryStore.sol";
import { MintableERC20 } from "lib/amm-core/test/__fixtures/MintableERC20.sol";

import {
    Buffer,
    QueryProcessor,
    ReservoirPair,
    OracleNotInitialized,
    OracleAverageQuery,
    Observation,
    Variable
} from "src/libraries/QueryProcessor.sol";

contract QueryProcessorTest is Test {
    using FactoryStoreLib for GenericFactory;
    using QueryProcessor for ReservoirPair;
    using Buffer for uint16;

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
        _tokenB.mint(address(_pair), 10_189e18);
        _pair.mint(address(this));
    }

    function setUp() external {
        // nothing to do here is there?
    }

    function _createPair(address aTokenA, address aTokenB, uint256 aCurveId) internal returns (address rPair) {
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

    modifier randomizeStartTime(uint32 aNewStartTime) {
        vm.assume(aNewStartTime > 1 && aNewStartTime < 2 ** 31 / 2);

        vm.warp(aNewStartTime);
        _;
    }

    function testGetInstantValue() external {
        // arrange
        skip(123);
        _tokenB.mint(address(_pair), 105e18);
        _pair.swap(-105e18, true, address(this), "");

        // act
        uint256 lInstantRawPrice = _pair.getInstantValue(Variable.RAW_PRICE, 0, false);
        uint256 lInstantClampedPrice = _pair.getInstantValue(Variable.CLAMPED_PRICE, 0, false);

        // assert - instant price should be the new price after swap, not the price before swap
        assertApproxEqRel(lInstantRawPrice, 100e18, 0.01e18);
        assertApproxEqRel(lInstantClampedPrice, 100e18, 0.01e18);
    }

    function testGetTimeWeightedAverage() external {
        // arrange - perform some swaps
        (,,, uint16 lLatestIndex) = _pair.getReserves();

        // act
        _pair.getTimeWeightedAverage(OracleAverageQuery(Variable.RAW_PRICE, address(0), address(1), 1, 1), lLatestIndex);

        // assert
    }

    function testGetPastAccumulator_WithoutOffset() external { }

    function testGetPastAccumulator_WithSmallOffset() external { }
    function testGetPastAccumulator_WithLargeOffset() external { }
    function testGetPastAccumulator_WithHighestOffset() external { }

    function testGetPastAccumulator_InterpolatesBetweenPastAccumulator() external { }
    function testGetPastAccumulator_RevertsWithTooOldTimestamp() external { }

    function testFindNearestSample_CanFindExactValue(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aRandomSlot
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 30);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum
        uint256 lRandomSlot = bound(aRandomSlot, 0, lObservationsToWrite.sub(1));

        // arrange - fill up the entire buffer with observations, but not exceed and overwrite it
        for (uint256 i = 0; i < lObservationsToWrite; ++i) {
            skip(lBlockTime);
            _pair.sync();
        }

        // act
        uint256 lLookupTime = _pair.observation(lRandomSlot).timestamp;
        uint16 lOffset = lObservationsToWrite > Buffer.SIZE ? lObservationsToWrite % Buffer.SIZE : 0;
        uint16 lBufferLength = lObservationsToWrite > Buffer.SIZE ? Buffer.SIZE : lObservationsToWrite;
        (Observation memory prev, Observation memory next) =
            _pair.findNearestSample(lLookupTime, lOffset, lBufferLength);

        // assert
        assertEq(prev.timestamp, next.timestamp, "prev.timestamp != next.timestamp");
        assertEq(prev.timestamp, lLookupTime);
    }

    function testFindNearestSample_CanFindIntermediateValue(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aRandomSlot
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 3, 60);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum
        uint256 lRandomSlot = bound(aRandomSlot, 0, lObservationsToWrite.sub(2)); // can't be the latest one as lookupTime will go beyond

        // arrange
        for (uint256 i = 0; i < lObservationsToWrite; ++i) {
            skip(lBlockTime);
            _pair.sync();
        }

        // act
        uint256 lLookupTime = _pair.observation(lRandomSlot).timestamp + lBlockTime / 2;
        uint16 lOffset = lObservationsToWrite > Buffer.SIZE ? lObservationsToWrite % Buffer.SIZE : 0;
        uint16 lBufferLength = lObservationsToWrite > Buffer.SIZE ? Buffer.SIZE : lObservationsToWrite;
        (Observation memory prev, Observation memory next) =
            _pair.findNearestSample(lLookupTime, lOffset, lBufferLength);

        // assert
        assertEq(prev.timestamp + lBlockTime, next.timestamp, "next is not prev + blocktime");
        assertNotEq(prev.timestamp, lLookupTime, "prev eq lookup");
        assertNotEq(next.timestamp, lLookupTime, "next eq lookup");
        assertGt(lLookupTime, prev.timestamp);
        assertLt(lLookupTime, next.timestamp);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                 ERROR CONDITIONS                                          //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function testGetInstantValue_NotInitialized(uint256 aIndex) external {
        // act & assert
        vm.expectRevert(OracleNotInitialized.selector);
        _pair.getInstantValue(Variable.RAW_PRICE, aIndex, false);
    }

    function testGetInstantValue_NotInitialized_BeyondBufferSize() external {
        // fill up buffer size

        // should return not initialized for anything that is outside the bounds of buffer
    }

    function testGetPastAccumulator_BufferEmpty() external { }
    function testGetPastAccumulator_TooLongAgo() external { }
    function testGetPastAccumulator_QueryTooOld() external {
        // expect revert query too old
    }

    function testFindNearestSample_NotInitialized() external { }

    function testGetTimeWeightedAverage_BadSecs() external { }
}
