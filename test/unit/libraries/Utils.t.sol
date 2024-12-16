// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Test, console2, stdError } from "forge-std/Test.sol";

import { Utils } from "src/libraries/Utils.sol";
import { Constants } from "src/libraries/Constants.sol";

contract UtilsTest is Test{
    using Utils for uint256;

    function testCalcPercentageDiff_Double(uint256 aOriginal) external pure {
        // assume
        uint256 lOriginal = bound(aOriginal, 1, Constants.MAX_SUPPORTED_PRICE / 2);

        // act
        uint256 lDiff = lOriginal.calcPercentageDiff( lOriginal * 2);

        // assert
        assertEq(lDiff, 1e18);
    }

    function testCalcPercentageDiff_Half(uint256 aOriginal) external pure {
        // assume - when numbers get too small the error becomes too large
        uint256 lOriginal = bound(aOriginal, 1e6, Constants.MAX_SUPPORTED_PRICE);

        // act
        uint256 lDiff = lOriginal.calcPercentageDiff( lOriginal / 2);

        // assert
        assertApproxEqRel(lDiff, 0.5e18, 0.00001e18);
    }

    function testCalcPercentageDiff_NoDiff(uint256 aOriginal) external pure {
        // assume
        uint256 lOriginal = bound(aOriginal, 1, Constants.MAX_SUPPORTED_PRICE);

        // act
        uint256 lDiff = lOriginal.calcPercentageDiff(lOriginal);

        // assert
        assertEq(lDiff, 0);
    }
}
