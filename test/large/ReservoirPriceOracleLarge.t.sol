// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {
    ReservoirPriceOracleTest,
    EnumerableSetLib,
    FixedPointMathLib,
    MintableERC20,
    ReservoirPair,
    IERC20,
    Constants
} from "test/unit/ReservoirPriceOracle.t.sol";

contract ReservoirPriceOracleLargeTest is ReservoirPriceOracleTest {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using FixedPointMathLib for uint256;

    function testGetQuote_RandomizeAllParam_3HopRoute(
        uint256 aPrice1,
        uint256 aPrice2,
        uint256 aPrice3,
        uint256 aAmtIn,
        address aTokenAAddress,
        address aTokenBAddress,
        address aTokenCAddress,
        address aTokenDAddress,
        uint8 aTokenADecimal,
        uint8 aTokenBDecimal,
        uint8 aTokenCDecimal,
        uint8 aTokenDDecimal
    ) external {
        // assume
        vm.assume(
            aTokenAAddress.code.length == 0 && aTokenBAddress.code.length == 0 && aTokenCAddress.code.length == 0
                && aTokenCAddress.code.length == 0
        );
        assumeNotPrecompile(aTokenAAddress);
        assumeNotPrecompile(aTokenBAddress);
        assumeNotPrecompile(aTokenCAddress);
        assumeNotPrecompile(aTokenDAddress);
        assumeNotZeroAddress(aTokenAAddress);
        assumeNotZeroAddress(aTokenBAddress);
        assumeNotZeroAddress(aTokenCAddress);
        assumeNotZeroAddress(aTokenDAddress);
        assumeNotForgeAddress(aTokenAAddress);
        assumeNotForgeAddress(aTokenBAddress);
        assumeNotForgeAddress(aTokenCAddress);
        assumeNotForgeAddress(aTokenDAddress);
        vm.assume(
            aTokenAAddress != aTokenBAddress && aTokenAAddress != aTokenCAddress && aTokenAAddress != aTokenDAddress
                && aTokenBAddress != aTokenCAddress && aTokenBAddress != aTokenDAddress && aTokenBAddress != aTokenDAddress
        );
        uint256 lPrice1 = bound(aPrice1, 1e12, 1e24);
        uint256 lPrice2 = bound(aPrice2, 1e12, 1e24);
        uint256 lPrice3 = bound(aPrice3, 1e12, 1e24);
        uint256 lAmtIn = bound(aAmtIn, 0, 1_000_000_000);
        uint256 lTokenADecimal = bound(aTokenADecimal, 0, 18);
        uint256 lTokenBDecimal = bound(aTokenBDecimal, 0, 18);
        uint256 lTokenCDecimal = bound(aTokenCDecimal, 0, 18);
        uint256 lTokenDDecimal = bound(aTokenDDecimal, 0, 18);

        // arrange
        MintableERC20 lTokenA = MintableERC20(aTokenAAddress);
        MintableERC20 lTokenB = MintableERC20(aTokenBAddress);
        MintableERC20 lTokenC = MintableERC20(aTokenCAddress);
        MintableERC20 lTokenD = MintableERC20(aTokenDAddress);
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenADecimal)), aTokenAAddress);
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenBDecimal)), aTokenBAddress);
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenCDecimal)), aTokenCAddress);
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenDDecimal)), aTokenDAddress);

        ReservoirPair lPair1 = ReservoirPair(_factory.createPair(IERC20(aTokenAAddress), IERC20(aTokenBAddress), 0));
        ReservoirPair lPair2 = ReservoirPair(_factory.createPair(IERC20(aTokenBAddress), IERC20(aTokenCAddress), 0));
        ReservoirPair lPair3 = ReservoirPair(_factory.createPair(IERC20(aTokenCAddress), IERC20(aTokenDAddress), 0));

        _oracle.designatePair(aTokenAAddress, aTokenBAddress, lPair1);
        _oracle.designatePair(aTokenBAddress, aTokenCAddress, lPair2);
        _oracle.designatePair(aTokenCAddress, aTokenDAddress, lPair3);

        address[] memory lRoute = new address[](4);
        if (lTokenA < lTokenD) {
            lRoute[0] = aTokenAAddress;
            lRoute[1] = aTokenBAddress;
            lRoute[2] = aTokenCAddress;
            lRoute[3] = aTokenDAddress;
        } else {
            lRoute[0] = aTokenDAddress;
            lRoute[1] = aTokenCAddress;
            lRoute[2] = aTokenBAddress;
            lRoute[3] = aTokenAAddress;
        }

        uint64[] memory lRewardThresholds = new uint64[](3);
        lRewardThresholds[0] = lRewardThresholds[1] = lRewardThresholds[2] = Constants.WAD;

        _oracle.setRoute(lRoute[0], lRoute[3], lRoute, lRewardThresholds);
        _writePriceCache(
            lTokenA < lTokenB ? aTokenAAddress : aTokenBAddress,
            lTokenA < lTokenB ? aTokenBAddress : aTokenAAddress,
            lPrice1
        );
        _writePriceCache(
            lTokenB < lTokenC ? aTokenBAddress : aTokenCAddress,
            lTokenB < lTokenC ? aTokenCAddress : aTokenBAddress,
            lPrice2
        );
        _writePriceCache(
            lTokenC < lTokenD ? aTokenCAddress : aTokenDAddress,
            lTokenC < lTokenD ? aTokenDAddress : aTokenCAddress,
            lPrice3
        );

        // act
        uint256 lAmtDOut = _oracle.getQuote(lAmtIn * 10 ** lTokenADecimal, aTokenAAddress, aTokenDAddress);

        // assert
        uint256 lExpectedAmtBOut = lTokenA < lTokenB
            ? (lAmtIn * 10 ** lTokenADecimal).fullMulDiv(lPrice1 * 10 ** lTokenBDecimal, 10 ** lTokenADecimal * WAD)
            : (lAmtIn * 10 ** lTokenADecimal).fullMulDiv(WAD * 10 ** lTokenBDecimal, lPrice1 * 10 ** lTokenADecimal);
        uint256 lExpectedAmtCOut = lTokenB < lTokenC
            ? lExpectedAmtBOut.fullMulDiv(lPrice2 * 10 ** lTokenCDecimal, 10 ** lTokenBDecimal * WAD)
            : lExpectedAmtBOut.fullMulDiv(WAD * 10 ** lTokenCDecimal, lPrice2 * 10 ** lTokenBDecimal);
        uint256 lExpectedAmtDOut = lTokenC < lTokenD
            ? lExpectedAmtCOut.fullMulDiv(lPrice3 * 10 ** lTokenDDecimal, 10 ** lTokenCDecimal * WAD)
            : lExpectedAmtCOut.fullMulDiv(WAD * 10 ** lTokenDDecimal, lPrice3 * 10 ** lTokenCDecimal);

        assertEq(lAmtDOut, lExpectedAmtDOut);
    }
}
