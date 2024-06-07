// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
pragma solidity ^0.8.0;

import { LogCompression } from "amm-core/libraries/LogCompression.sol";
import { Buffer } from "amm-core/libraries/Buffer.sol";
import { ReservoirPair, Observation } from "amm-core/ReservoirPair.sol";

import { OracleErrors } from "src/libraries/OracleErrors.sol";
import { Samples, PriceType } from "src/libraries/Samples.sol";

/**
 * @dev Auxiliary library for PoolPriceOracle, offloading most of the query code to reduce bytecode size by using this
 * as a linked library. The downside is an extra DELEGATECALL is added (2600 gas as of the Berlin hardfork), but the
 * bytecode size gains are so big (specially of the oracle contract does not use `LogCompression.fromLowResLog`) that
 * it is worth it.
 */
library QueryProcessor {
    using Buffer for uint16;
    using LogCompression for int256;
    using Samples for Observation;

    /**
     * @dev Returns the value for `priceType` at the indexed sample.
     */
    function getInstantValue(ReservoirPair pair, PriceType priceType, uint256 index) internal view returns (uint256) {
        Observation memory sample = pair.observation(index);
        if (sample.timestamp == 0) revert OracleErrors.OracleNotInitialized();

        int256 rawInstantValue = sample.instant(priceType);
        return LogCompression.fromLowResLog(rawInstantValue);
    }

    /**
     * @dev Returns the time average weighted price
     */
    function getTimeWeightedAverage(
        ReservoirPair pair,
        PriceType priceType,
        uint256 secs,
        uint256 ago,
        uint16 latestIndex
    ) internal view returns (uint256) {
        if (secs == 0) revert OracleErrors.BadSecs();

        // SAFETY:
        //
        // `getPastAccumulator` reverts for any `ago`` greater than 32 bits anyway (i.e. greater than the current block.timestamp till year 2106)
        // So if either `ago` or `ago + secs` is larger than 32 bits, it will revert
        // `endAccumulator` and `beginAccumulators` themselves will not overflow/underflow until at least after year 2106. So the subtraction will not underflow as well.
        // Therefore it is safe to use unchecked here
        unchecked {
            int256 beginAccumulator = getPastAccumulator(pair, priceType, latestIndex, ago + secs);
            int256 endAccumulator = getPastAccumulator(pair, priceType, latestIndex, ago);
            return LogCompression.fromLowResLog((endAccumulator - beginAccumulator) / int256(secs));
        }
    }

    /**
     * @dev Returns the value of the accumulator for `priceType` `ago` seconds ago. `latestIndex` must be the index of
     * the latest sample in the buffer.
     *
     * Reverts under the following conditions:
     *  - if the buffer is empty.
     *  - if querying past information and the buffer has not been fully initialized.
     *  - if querying older information than available in the buffer. Note that a full buffer guarantees queries for the
     *    past largest safe query window will not revert.
     *
     * If requesting information for a timestamp later than the latest one, it is extrapolated using the latest
     * available data.
     *
     * When no exact information is available for the requested past timestamp (as usually happens, since at most one
     * timestamp is stored every two minutes), it is estimated by performing linear interpolation using the closest
     * values. This process is guaranteed to complete performing at most 11 storage reads.
     */
    function getPastAccumulator(ReservoirPair pair, PriceType priceType, uint16 latestIndex, uint256 ago)
        internal
        view
        returns (int256)
    {
        // solhint-disable not-rely-on-time
        // `ago` must not be before the epoch.
        if (block.timestamp < ago) revert OracleErrors.InvalidSeconds();
        uint256 lookUpTime;
        // SAFETY:
        //
        // `ago` is guaranteed to be equal to or less than `block.timestamp` as checked above, so subtraction will not underflow.
        unchecked {
            lookUpTime = block.timestamp - ago;
        }

        Observation memory latestSample = pair.observation(latestIndex);
        uint256 latestTimestamp = latestSample.timestamp;

        // The latest sample only has a non-zero timestamp if no data was ever processed and stored in the buffer.
        if (latestTimestamp == 0) revert OracleErrors.OracleNotInitialized();

        if (latestTimestamp <= lookUpTime) {
            // The accumulator at times ahead of the latest one are computed by extrapolating the latest data. This is
            // equivalent to the instant value not changing between the last timestamp and the look up time.

            // SAFETY:
            //
            // `latestTimestamp` is guaranteed to be equal or less than `lookUpTime` as checked above. So this subtraction will not underflow.
            // The accumulator can be represented in 53 bits, timestamps in 31bits, and the instant value in 22 bits. So this addition will not overflow.
            unchecked {
                uint256 elapsed = lookUpTime - latestTimestamp;
                return latestSample.accumulator(priceType) + (latestSample.instant(priceType) * int256(elapsed));
            }
        } else {
            // The look up time is before the latest sample, but we need to make sure that it is not before the oldest
            // sample as well.

            // Since we use a circular buffer, the oldest sample is simply the next one.
            uint16 bufferLength;
            uint16 oldestIndex = latestIndex.next();
            {
                // Local scope used to prevent stack-too-deep errors.
                Observation memory oldestSample = pair.observation(oldestIndex);
                uint256 oldestTimestamp = oldestSample.timestamp;

                if (oldestTimestamp > 0) {
                    // If the oldest timestamp is not zero, it means the buffer was fully initialized.
                    bufferLength = Buffer.SIZE;
                } else {
                    // If the buffer was not fully initialized, we haven't wrapped around it yet,
                    // and can treat it as a regular array where the oldest index is the first one,
                    // and the length the number of samples.
                    bufferLength = oldestIndex; // Equal to latestIndex.next()
                    oldestIndex = 0;
                    oldestTimestamp = pair.observation(0).timestamp;
                }

                // Finally check that the look up time is not previous to the oldest timestamp.
                if (oldestTimestamp > lookUpTime) revert OracleErrors.QueryTooOld();
            }

            // Perform binary search to find nearest samples to the desired timestamp.
            (Observation memory prev, Observation memory next) =
                findNearestSample(pair, lookUpTime, oldestIndex, bufferLength);

            // SAFETY:
            //
            // `next.timestamp` is guaranteed to be larger than `prev.timestamp`, so subtraction will not underflow.
            uint256 samplesTimeDiff;
            unchecked {
                samplesTimeDiff = next.timestamp - prev.timestamp;
            }
            if (samplesTimeDiff > 0) {
                // We estimate the accumulator at the requested look up time by interpolating linearly between the
                // previous and next accumulators.

                // SAFETY:
                //
                // The accumulators can be represented in 53 bits, and timestamps are in 31 bits. So the addition and subtraction will not under/overflow.
                // `lookupTime` is greater than `latestTimestamp` and is thus also greater than `prev.timestamp` so subtraction will not underflow.
                unchecked {
                    int256 samplesAccDiff = next.accumulator(priceType) - prev.accumulator(priceType);
                    uint256 elapsed = lookUpTime - prev.timestamp;
                    return prev.accumulator(priceType) + ((samplesAccDiff * int256(elapsed)) / int256(samplesTimeDiff));
                }
            } else {
                // Rarely, one of the samples will have the exact requested look up time, which is indicated by `prev`
                // and `next` being the same. In this case, we simply return the accumulator at that point in time.
                return prev.accumulator(priceType);
            }
        }
    }

    /**
     * @dev Finds the two samples with timestamps before and after `lookUpDate`. If one of the samples matches exactly,
     * both `prev` and `next` will be it. `offset` is the index of the oldest sample in the buffer. `length` is the size
     * of the samples list.
     *
     * Assumes `lookUpDate` is greater or equal than the timestamp of the oldest sample, and less or equal than the
     * timestamp of the latest sample. Assumes that `length` is at least 1.
     */
    function findNearestSample(ReservoirPair pair, uint256 lookUpDate, uint16 offset, uint16 length)
        internal
        view
        returns (Observation memory prev, Observation memory next)
    {
        // SAFETY:
        //
        // As `length` is at least 1, subtractions will not underflow
        // Additions will also not overflow as the max length is `Buffer.SIZE`
        unchecked {
            // We're going to perform a binary search in the circular buffer, which requires it to be sorted. To achieve
            // this, we offset all buffer accesses by `offset`, making the first element the oldest one.

            // Auxiliary variables in a typical binary search: we will look at some value `mid` between `low` and `high`,
            // periodically increasing `low` or decreasing `high` until we either find a match or determine the element is
            // not in the array.
            uint16 low = 0;
            uint16 high = length - 1;
            uint16 mid;

            // If the search fails and no sample has a timestamp of `lookUpDate` (as is the most common scenario), `sample`
            // will be either the sample with the largest timestamp smaller than `lookUpDate`, or the one with the smallest
            // timestamp larger than `lookUpDate`.
            Observation memory sample;
            uint256 sampleTimestamp;

            while (low <= high) {
                // Mid is the floor of the average.
                // Additions does not overflow as they are Buffer.SIZE max
                uint16 midWithoutOffset = (high + low) / 2;

                // Recall that the buffer is not actually sorted: we need to apply the offset to access it in a sorted way.
                mid = midWithoutOffset.add(offset);
                sample = pair.observation(mid);
                sampleTimestamp = sample.timestamp;

                if (sampleTimestamp < lookUpDate) {
                    // If the mid sample is bellow the look up date, then increase the low index to start from there.
                    low = midWithoutOffset + 1;
                } else if (sampleTimestamp > lookUpDate) {
                    // If the mid sample is above the look up date, then decrease the high index to start from there.

                    // We can skip checked arithmetic: it is impossible for `high` to ever be 0, as a scenario where `low`
                    // equals 0 and `high` equals 1 would result in `low` increasing to 1 in the previous `if` clause.
                    high = midWithoutOffset - 1;
                } else {
                    // sampleTimestamp == lookUpDate
                    // If we have an exact match, return the sample as both `prev` and `next`.
                    return (sample, sample);
                }
            }

            // In case we reach here, it means we didn't find exactly the sample we where looking for.
            return sampleTimestamp < lookUpDate
                ? (sample, pair.observation(mid.next()))
                : (pair.observation(mid.prev()), sample);
        }
    }
}
