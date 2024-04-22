// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { BaseTest, FactoryStoreLib, GenericFactory } from "test/__fixtures/BaseTest.t.sol";

import { Buffer, OracleNotInitialized, InvalidSeconds, QueryTooOld, BadSecs } from "src/libraries/QueryProcessor.sol";
import { QueryProcessorWrapper, ReservoirPair, Observation, Variable } from "test/wrapper/QueryProcessorWrapper.sol";

contract QueryProcessorTest is BaseTest {
    using FactoryStoreLib for GenericFactory;
    using Buffer for uint16;

    QueryProcessorWrapper internal _queryProcessor = new QueryProcessorWrapper();

    constructor() {
        _factory.write("Shared::oracleCaller", address(_queryProcessor));
        _pair.updateOracleCaller();
    }

    // TODO: test both negative and positive acc values
    // i.e. accumulator value keeps getting more negative and more positive

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

    function testGetTimeWeightedAverage(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aSecs,
        uint256 aAgo
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 60);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3));
        uint256 lSecs = bound(aSecs, 1, 1 hours);
        uint256 lAgo = bound(aAgo, 0, 1 hours);

        // ensure that the query window is within what is still available in the buffer
        // the fact that we potentially go around the buffer more than one means that maybe the query window's
        // samples have been overwritten. Thus the need for the modulus.
        vm.assume(lSecs + lAgo <= (lBlockTime * (lObservationsToWrite - 1)) % (lBlockTime * Buffer.SIZE));

        // arrange - perform some swaps
        uint256 lSwapAmt = 1e6;
        for (uint256 i = 0; i < lObservationsToWrite; ++i) {
            skip(lBlockTime);
            _tokenA.mint(address(_pair), lSwapAmt);
            _pair.swap(int256(lSwapAmt), true, address(this), "");
        }

        // act
        (,,, uint16 lLatestIndex) = _pair.getReserves();
        uint256 lAveragePrice =
            _queryProcessor.getTimeWeightedAverage(_pair, Variable.RAW_PRICE, lSecs, lAgo, lLatestIndex);

        // assert
        // as it is hard to calc the exact average price given so many fuzz parameters, we just assert that the price should be within a range
        uint lStartingPrice = 98.9223e18;
        uint lEndingPrice = _queryProcessor.getInstantValue(_pair, Variable.RAW_PRICE, lLatestIndex, false);
        assertLt(lAveragePrice, lStartingPrice);
        assertGt(lAveragePrice, lEndingPrice);
    }

    function testGetPastAccumulator_ExactMatch(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint16 aBlocksAgo
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 60);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum
        uint16 lBlocksAgo = uint16(bound(aBlocksAgo, 0, lObservationsToWrite.sub(1)));

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);
        (,,, uint16 lIndex) = _pair.getReserves();

        // act
        uint256 lAgo = lBlockTime * lBlocksAgo;
        int256 lAcc = _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, lAgo);

        // assert
        uint256 lDesiredIndex = lIndex.sub(lBlocksAgo);
        vm.prank(address(_queryProcessor));
        Observation memory lObs = _pair.observation(lDesiredIndex);
        assertEq(lAcc, lObs.logAccRawPrice);
    }

    function testGetPastAccumulator_ExactMatch_LatestAccumulator(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 60);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3));

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

    function testGetPastAccumulator_InterpolatesBetweenPastAccumulators(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aRandomSlot
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 3, 60);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3));
        uint16 lRandomSlot = uint16(bound(aRandomSlot, 0, lObservationsToWrite.sub(2)));

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);
        (,,, uint16 lIndex) = _pair.getReserves();

        // act
        vm.startPrank(address(_queryProcessor));
        Observation memory lPrevObs = _pair.observation(lRandomSlot);
        uint256 lWantedTimestamp = lPrevObs.timestamp + lBlockTime / 2;
        uint256 lAgo = block.timestamp - lWantedTimestamp;
        int256 lAcc = _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, lAgo);

        // assert
        Observation memory lNextObs = _pair.observation(lRandomSlot.next());
        int256 lAccDiff = lNextObs.logAccRawPrice - lPrevObs.logAccRawPrice;
        assertGt(lNextObs.timestamp, lWantedTimestamp);
        assertLt(lPrevObs.timestamp, lWantedTimestamp);
        assertEq(lAcc, lPrevObs.logAccRawPrice + lAccDiff * int256(lBlockTime / 2) / int256(lBlockTime));
        vm.stopPrank();
    }

    function testGetPastAccumulator_ExtrapolatesBeyondLatest(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aTimeBeyondLatest
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 30);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3)); // go around it 3 times maximum
        uint256 lTimeBeyondLatest = bound(aTimeBeyondLatest, 1, 90 days);

        // arrange
        _fillBuffer(lBlockTime, lObservationsToWrite);
        skip(lTimeBeyondLatest);
        (,,, uint16 lIndex) = _pair.getReserves();

        // act
        int256 lAcc = _queryProcessor.getPastAccumulator(_pair, Variable.RAW_PRICE, lIndex, 0);

        // assert
        vm.prank(address(_queryProcessor));
        Observation memory lObs = _pair.observation(lIndex);
        if (lAcc > 0) {
            assertGt(lAcc, lObs.logAccRawPrice);
        } else {
            assertLt(lAcc, lObs.logAccRawPrice);
        }
        assertEq(lAcc, lObs.logAccRawPrice + int256(lTimeBeyondLatest) * lObs.logInstantRawPrice);
    }

    function testFindNearestSample_CanFindExactValue(
        uint32 aStartTime,
        uint256 aBlockTime,
        uint256 aObservationsToWrite,
        uint256 aRandomSlot
    ) external randomizeStartTime(aStartTime) {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 30);
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 2, Buffer.SIZE * 3)); // go around it 3 times maximum
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

    function testFindNearestSample_OneSample(uint256 aBlockTime) external {
        // assume
        uint256 lBlockTime = bound(aBlockTime, 1, 60);

        // arrange
        _fillBuffer(lBlockTime, 1);

        // act
        (Observation memory prev, Observation memory next) =
            _queryProcessor.findNearestSample(_pair, block.timestamp, 0, 1);

        // assert
        assertEq(prev.timestamp, next.timestamp);
        assertGt(prev.logAccRawPrice, 0);
        assertGt(prev.timestamp, 0);
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
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3));
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
        uint16 lObservationsToWrite = uint16(bound(aObservationsToWrite, 3, Buffer.SIZE * 3));

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

    // technically this should never happen in production as `getPastAccumulator` would have reverted with the
    // `OracleNotInitialized` error if the oracle is not initialized
    // so the expected revert is one of running out of gas, having done too many iterations as the subtraction has underflown
    // due to supplying a buffer length of 0
    function testFindNearestSample_NotInitialized() external {
        // arrange
        uint256 lLookupTime = 123;
        uint16 lOffset = 0;
        uint16 lBufferLength = 0;

        // act & assert
        vm.expectRevert();
        _queryProcessor.findNearestSample(_pair, lLookupTime, lOffset, lBufferLength);
    }

    function testGetTimeWeightedAverage_BadSecs() external {
        // act & assert
        vm.expectRevert(BadSecs.selector);
        _queryProcessor.getTimeWeightedAverage(_pair, Variable.RAW_PRICE, 0, 0, 0);
    }
}
