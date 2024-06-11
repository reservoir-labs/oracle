// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { ReservoirPriceOracleTest, EnumerableSetLib, MintableERC20, ReservoirPair, IERC20 } from "test/unit/ReservoirPriceOracle.t.sol";

contract ReservoirPriceOracleLargeTest is ReservoirPriceOracleTest {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

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
            aTokenAAddress > ADDRESS_THRESHOLD && aTokenBAddress > ADDRESS_THRESHOLD
                && aTokenCAddress > ADDRESS_THRESHOLD && aTokenDAddress > ADDRESS_THRESHOLD
        );
        vm.assume(
            _addressSet.add(aTokenAAddress) && _addressSet.add(aTokenBAddress) && _addressSet.add(aTokenCAddress)
                && _addressSet.add(aTokenDAddress)
        );
        uint256 lPrice1 = bound(aPrice1, 1e12, 1e24); // need to bound price within this range as a price below this will go to zero as during the mul and div of prices
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
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenADecimal)), address(lTokenA));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenBDecimal)), address(lTokenB));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenCDecimal)), address(lTokenC));
        deployCodeTo("MintableERC20.sol", abi.encode("T", "T", uint8(lTokenDDecimal)), address(lTokenD));

        ReservoirPair lPair1 = ReservoirPair(_factory.createPair(IERC20(address(lTokenA)), IERC20(address(lTokenB)), 0));
        ReservoirPair lPair2 = ReservoirPair(_factory.createPair(IERC20(address(lTokenB)), IERC20(address(lTokenC)), 0));
        ReservoirPair lPair3 = ReservoirPair(_factory.createPair(IERC20(address(lTokenC)), IERC20(address(lTokenD)), 0));

        _oracle.designatePair(address(lTokenA), address(lTokenB), lPair1);
        _oracle.designatePair(address(lTokenB), address(lTokenC), lPair2);
        _oracle.designatePair(address(lTokenC), address(lTokenD), lPair3);

        address[] memory lRoute = new address[](4);
        (lRoute[0], lRoute[3]) =
            lTokenA < lTokenD ? (address(lTokenA), address(lTokenD)) : (address(lTokenD), address(lTokenA));
        lRoute[1] = address(lTokenB);
        lRoute[2] = address(lTokenC);

        _oracle.setRoute(lRoute[0], lRoute[3], lRoute);
        _writePriceCache(
            lRoute[0] < lRoute[1] ? lRoute[0] : lRoute[1], lRoute[0] < lRoute[1] ? lRoute[1] : lRoute[0], lPrice1
        );
        _writePriceCache(
            address(lTokenB) < address(lTokenC) ? address(lTokenB) : address(lTokenC),
            address(lTokenB) < address(lTokenC) ? address(lTokenC) : address(lTokenB),
            lPrice2
        );
        _writePriceCache(
            lRoute[2] < lRoute[3] ? lRoute[2] : lRoute[3], lRoute[2] < lRoute[3] ? lRoute[3] : lRoute[2], lPrice3
        );

        // act
        uint256 lAmtDOut = _oracle.getQuote(lAmtIn * 10 ** lTokenADecimal, address(lTokenA), address(lTokenD));

        // assert
//        uint256 lPriceStartEnd = (lRoute[0] < lRoute[1] ? lPrice1 : lPrice1.invertWad())
//            * (lRoute[1] < lRoute[2] ? lPrice2 : lPrice2.invertWad()) / WAD
//            * (lRoute[2] < lRoute[3] ? lPrice3 : lPrice3.invertWad()) / WAD;
//        assertEq(
//            lAmtDOut,
//            lAmtIn * (lRoute[0] == address(lTokenA) ? lPriceStartEnd : lPriceStartEnd.invertWad())
//                * (10 ** lTokenDDecimal) / WAD
//        );
    }
}
