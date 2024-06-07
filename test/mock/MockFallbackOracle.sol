// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

contract MockFallbackOracle is IPriceOracle {
    function name() external view returns (string memory) {
        return "MOCK";
    }

    function getQuote(uint256 amount, address, address) external view returns (uint256 out) {
        out = amount;
    }

    function getQuotes(uint256 amount, address, address)
        external
        view
        returns (uint256 bidOut, uint256 askOut)
    {
        (bidOut, askOut) = (amount, amount);
    }
}
