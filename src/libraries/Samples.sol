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

import { Observation } from "amm-core/ReservoirPair.sol";

import { Variable } from "src/Enums.sol";
import { OracleErrors } from "src/libraries/OracleErrors.sol";

library Samples {
    /**
     * @dev Returns the instant value stored in `sample` for `variable`.
     */
    function instant(Observation memory sample, Variable variable) internal pure returns (int256) {
        if (variable == Variable.RAW_PRICE) {
            return sample.logInstantRawPrice;
        } else if (variable == Variable.CLAMPED_PRICE) {
            return sample.logInstantClampedPrice;
        } else {
            revert OracleErrors.BadVariableRequest();
        }
    }

    /**
     * @dev Returns the accumulator value stored in `sample` for `variable`.
     */
    function accumulator(Observation memory sample, Variable variable) internal pure returns (int256) {
        if (variable == Variable.RAW_PRICE) {
            return sample.logAccRawPrice;
        } else if (variable == Variable.CLAMPED_PRICE) {
            return sample.logAccClampedPrice;
        } else {
            revert OracleErrors.BadVariableRequest();
        }
    }
}
