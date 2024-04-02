// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test, console2, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "lib/amm-core/lib/solady/src/utils/FixedPointMathLib.sol";

import { GenericFactory, IERC20 } from "amm-core/GenericFactory.sol";
import { ConstantProductPair } from "amm-core/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "amm-core/curve/stable/StablePair.sol";
import { Constants } from "amm-core/Constants.sol";
import { FactoryStoreLib } from "amm-core/libraries/FactoryStore.sol";
import { MintableERC20 } from "lib/amm-core/test/__fixtures/MintableERC20.sol";

import { Buffer, OracleNotInitialized, InvalidSeconds, QueryTooOld } from "src/libraries/QueryProcessor.sol";
import {
    QueryProcessorWrapper,
    ReservoirPair,
    OracleAverageQuery,
    Observation,
    Variable
} from "test/wrapper/QueryProcessorWrapper.sol";

contract QueryProcessorTest is Test {
    using FactoryStoreLib for GenericFactory;
    using Buffer for uint16;

    // TODO: test both negative and positive acc values
    // i.e. accumulator value keeps getting more negative and more positive

    GenericFactory private _factory = new GenericFactory();
    ReservoirPair private _pair;

    MintableERC20 internal _tokenA = new MintableERC20("TokenA", "TA", 6);
    MintableERC20 internal _tokenB = new MintableERC20("TokenB", "TB", 18);

    QueryProcessorWrapper internal _queryProcessor = new QueryProcessorWrapper();

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
        _factory.write("Shared::oracleCaller", address(_queryProcessor));

        _pair = ReservoirPair(_createPair(address(_tokenA), address(_tokenB), 0));
        _tokenA.mint(address(_pair), 103e6);
        _tokenB.mint(address(_pair), 10_189e18);
        _pair.mint(address(this));
    }

    function _createPair(address aTokenA, address aTokenB, uint256 aCurveId) internal returns (address rPair) {
        rPair = _factory.createPair(IERC20(aTokenA), IERC20(aTokenB), aCurveId);
    }

    function _fillBuffer(uint256 aBlockTime, uint256 aObservationsToWrite) internal {
        for (uint256 i = 0; i < aObservationsToWrite; ++i) {
            skip(aBlockTime);
            _pair.sync();
        }
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
        uint256 lInstantRawPrice = _queryProcessor.getInstantValue(_pair, Variable.RAW_PRICE, 0, false);
        uint256 lInstantClampedPrice = _queryProcessor.getInstantValue(_pair, Variable.CLAMPED_PRICE, 0, false);

        // assert - instant price should be the new price after swap, not the price before swap
        assertApproxEqRel(lInstantRawPrice, 100e18, 0.01e18);
        assertApproxEqRel(lInstantClampedPrice, 100e18, 0.01e18);
    }

    function testGetTimeWeightedAverage() external {
        // arrange - perform some swaps
        // (,,, uint16 lLatestIndex) = _pair.getReserves();

        // act
        // _pair.getTimeWeightedAverage(OracleAverageQuery(Variable.RAW_PRICE, address(0), address(1), 1, 1), lLatestIndex);

        // assert
    }

    function testGetPastAccumulator_ExactMatch(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint16 aBlocksAgo
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 30);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum
        uint16 lBlocksAgo = uint16(bound(aBlocksAgo, 0, lObservationsToWrite % Buffer.SIZE));

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);
        (,,, uint16 lIndex) = _pair.getReserves();

        // act
        uint256 lAgo = FixedPointMathLib.min(lBlockTime * lBlocksAgo, aStartTime); // so that we don't query beyond the oldest sample
        int256 lAcc = _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, lAgo);

        // assert
        vm.prank(address(_queryProcessor));
        Observation memory lObs = _pair.observation(lIndex.sub(lAgo == aStartTime ? lObservationsToWrite : lBlocksAgo));
        assertEq(lAcc, lObs.logAccRawPrice);
    }

    function testGetPastAccumulator_ExactMatch_LatestAccumulator(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 30);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);
        (,,, uint16 lIndex) = _pair.getReserves();

        // act
        int256 lAcc = _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, 0);

        // assert
        vm.prank(address(_queryProcessor));
        Observation memory lObs = _pair.observation(lIndex);
        assertEq(lAcc, lObs.logAccRawPrice);
    }

    function testGetPastAccumulator_ExactMatch_OldestAccumulator(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 30);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum

        // arrange
        uint256 lStartTime = block.timestamp;
        _fillBuffer(lBlockTime, lObservationsToWrite);
        (,,, uint16 lIndex) = _pair.getReserves();

        // act
        vm.startPrank(address(_queryProcessor));
        uint256 lAgo = lObservationsToWrite > Buffer.SIZE
            ? block.timestamp - _pair.observation(lIndex.next()).timestamp
            : block.timestamp - (lStartTime + lBlockTime);
        int256 lAcc = _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, lAgo);

        // assert
        Observation memory lObs = _pair.observation(lObservationsToWrite > Buffer.SIZE ? lIndex.next() : 0);
        assertEq(lAcc, lObs.logAccRawPrice);
        vm.stopPrank();
    }

    function testGetPastAccumulator_InterpolatesBetweenPastAccumulator() external { }

    function testGetPastAccumulator_ExtrapolatesBeyondLatest() external { }

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

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);

        // act
        vm.prank(address(_queryProcessor));
        uint256 lLookupTime = _pair.observation(lRandomSlot).timestamp;
        uint16 lOffset = lObservationsToWrite > Buffer.SIZE ? lObservationsToWrite % Buffer.SIZE : 0;
        uint16 lBufferLength = lObservationsToWrite > Buffer.SIZE ? Buffer.SIZE : lObservationsToWrite;
        (Observation memory prev, Observation memory next) =
            _queryProcessor.findNearestSample(_pair, lLookupTime, lOffset, lBufferLength);

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
        _fillBuffer(lBlockTime, lObservationsToWrite);

        // act
        vm.prank(address(_queryProcessor));
        uint256 lLookupTime = _pair.observation(lRandomSlot).timestamp + lBlockTime / 2;
        uint16 lOffset = lObservationsToWrite > Buffer.SIZE ? lObservationsToWrite % Buffer.SIZE : 0;
        uint16 lBufferLength = lObservationsToWrite > Buffer.SIZE ? Buffer.SIZE : lObservationsToWrite;
        (Observation memory prev, Observation memory next) =
            _queryProcessor.findNearestSample(_pair, lLookupTime, lOffset, lBufferLength);

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
        _queryProcessor.getInstantValue(_pair, Variable.RAW_PRICE, aIndex, false);
    }

    function testGetInstantValue_NotInitialized_BeyondBufferSize(uint8 aVariable, uint16 aIndex, bool aReciprocal)
        external
    {
        // assume
        Variable lVar = Variable(bound(aVariable, 0, 1));
        uint16 lIndex = uint16(bound(aIndex, Buffer.SIZE, type(uint16).max));

        // arrange - fill up buffer size
        _fillBuffer(5, Buffer.SIZE);

        // act & assert - should revert for all indexes that are beyond the bounds of buffer
        vm.expectRevert(OracleNotInitialized.selector);
        _queryProcessor.getInstantValue(_pair, lVar, lIndex, aReciprocal);
    }

    function testGetPastAccumulator_BufferEmpty(uint8 aVariable) external {
        // assume
        Variable lVar = Variable(bound(aVariable, 0, 1));

        // arrange
        (,,, uint16 lIndex) = _pair.getReserves();

        // act & assert
        vm.expectRevert(OracleNotInitialized.selector);
        _queryProcessor.getPastAccumulator(_pair, lVar, lIndex, 0);
    }

    function testGetPastAccumulator_InvalidAgo(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aAgo
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 3, 60);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum
        uint256 lAgo = bound(aAgo, aStartTime + lBlockTime * lObservationsToWrite + 1, type(uint256).max);

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);
        (,,, uint16 lIndex) = _pair.getReserves();

        // act & assert
        vm.expectRevert(InvalidSeconds.selector);
        _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, lAgo);
    }

    function testGetPastAccumulator_QueryTooOld(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aAgo
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 3, 60);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);
        (,,, uint16 lIndex) = _pair.getReserves();
        uint256 lOldestSample = lObservationsToWrite > Buffer.SIZE ? lIndex.next() : 0;
        vm.prank(address(_queryProcessor));
        uint256 lAgo = bound(
            aAgo,
            block.timestamp - _pair.observation(lOldestSample).timestamp + 1,
            aStartTime + lBlockTime * lObservationsToWrite
        );

        // act & assert
        vm.expectRevert(QueryTooOld.selector);
        _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, lAgo);
    }

    // technically this should never happen in production as getPastAccumulator would have reverted with the
    // `OracleNotInitialized` error if the oracle is not initialized
    function testFindNearestSample_NotInitialized() external {
        // arrange
        uint256 lLookupTime = 123;
        uint16 lOffset = 0;
        uint16 lBufferLength = 0;

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _queryProcessor.findNearestSample(_pair, lLookupTime, lOffset, lBufferLength);
    }

    function testGetTimeWeightedAverage_BadSecs() external { }
}
