// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Owned } from "lib/amm-core/lib/solmate/src/auth/Owned.sol";
import { ReentrancyGuard } from "lib/amm-core/lib/solmate/src/utils/ReentrancyGuard.sol";
import { FixedPointMathLib } from "lib/amm-core/lib/solmate/src/utils/FixedPointMathLib.sol";

import { ReservoirPair } from "amm-core/ReservoirPair.sol";

import {
    IReservoirPriceOracle,
    OracleAverageQuery,
    OracleAccumulatorQuery,
    Variable
} from "src/interfaces/IReservoirPriceOracle.sol";

contract ReservoirPriceCache is Owned(msg.sender), ReentrancyGuard {
    using FixedPointMathLib for uint256;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    uint256 MAX_DEVIATION_THRESHOLD = 0.2e18; // 20%
    uint256 MAX_TWAP_PERIOD = 1 hours;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       EVENTS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    event Oracle(address newOracle);
    event TwapPeriod(uint256 newPeriod);
    event PriceDeviationThreshold(uint256 newThreshold);
    event RewardMultiplier(uint256 newMultiplier);
    event Price(address indexed pair, uint256 price);

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       ERRORS                                              //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    error RPC_THRESHOLD_TOO_HIGH();
    error RPC_TWAP_PERIOD_TOO_HIGH();

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    IReservoirPriceOracle public oracle;

    /// @notice percentage change greater than which, a price update with the oracles would succeed
    /// 1e18 == 100%
    uint64 public priceDeviationThreshold;

    /// @notice percentage of gas fee the contract rewards the caller for updating the price
    /// 1e18 == 100%
    uint64 public rewardMultiplier;

    /// @notice TWAP period for querying the oracle
    uint64 public twapPeriod;

    // for a certain pair, regardless of the curve id, the latest cached price of token1/token0
    // calculate reciprocal to for price of token0/token1
    mapping(address => uint256) public priceCache;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR, FALLBACKS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor(address aOracle, uint64 aThreshold, uint64 aTwapPeriod, uint64 aMultiplier) {
        updateOracle(aOracle);
        updatePriceDeviationThreshold(aThreshold);
        updateTwapPeriod(aTwapPeriod);
        updateRewardMultiplier(aMultiplier);
    }

    /// @dev contract will hold native tokens to be distributed as gas bounty for updating the prices
    /// anyone can contribute native tokens to this contract
    receive() external payable { }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   PUBLIC FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // admin functions

    function updateOracle(address aOracle) public onlyOwner {
        oracle = IReservoirPriceOracle(aOracle);
        emit Oracle(aOracle);
    }

    function updatePriceDeviationThreshold(uint64 aNewThreshold) public onlyOwner {
        if (aNewThreshold > MAX_DEVIATION_THRESHOLD) {
            revert RPC_THRESHOLD_TOO_HIGH();
        }

        priceDeviationThreshold = aNewThreshold;
        emit PriceDeviationThreshold(aNewThreshold);
    }

    function updateTwapPeriod(uint64 aNewPeriod) public onlyOwner {
        if (aNewPeriod > MAX_TWAP_PERIOD) {
            revert RPC_TWAP_PERIOD_TOO_HIGH();
        }
        twapPeriod = aNewPeriod;
        emit TwapPeriod(aNewPeriod);
    }

    function updateRewardMultiplier(uint64 aNewMultiplier) public onlyOwner {
        rewardMultiplier = aNewMultiplier;
        emit RewardMultiplier(aNewMultiplier);
    }

    // oracle price functions

    function getPriceForPair(address aPair) external view returns (uint256) {
        return priceCache[aPair];
    }

    // price update related functions

    function isPriceUpdateIncentivized() external view returns (bool) {
        return address(this).balance > 0;
    }

    function gasBountyAvailable() external view returns (uint256) {
        return address(this).balance;
    }

    /// @dev we do not allow specifying which address gets the reward, to save on calldata gas
    function updatePrice(address aPair) external nonReentrant {
        ReservoirPair lPair = ReservoirPair(aPair);

        OracleAverageQuery[] memory lQueries;
        lQueries[0] = OracleAverageQuery(
            Variable.RAW_PRICE,
            address(lPair.token0()),
            address(lPair.token1()),
            twapPeriod,
            0 // now
        );

        // reads new price from pair
        uint256 lNewPrice = oracle.getTimeWeightedAverage(lQueries)[0];

        // determine if price has moved beyond the threshold
        // reward caller if so
        if (_calcPercentageDiff(lNewPrice, priceCache[aPair]) >= priceDeviationThreshold) {
            _rewardUpdater(msg.sender);
        }

        priceCache[aPair] = lNewPrice;
        emit Price(aPair, lNewPrice);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  INTERNAL FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // TODO: replace this with safe, audited lib function
    function _calcPercentageDiff(uint256 aOriginal, uint256 aNew) internal pure returns (uint256) {
        if (aOriginal > aNew) {
            return (aOriginal - aNew) * 1e18 / aOriginal;
        } else {
            return (aNew - aOriginal) * 1e18 / aOriginal;
        }
    }

    function _rewardUpdater(address lRecipient) internal {
        // N.B. Revisit this whenever deployment on a new chain is needed
        // we use `block.basefee` instead of `ArbGasInfo::getMinimumGasPrice()` on ARB because the latter will always return
        // the demand insensitive base fee, while the former can return real higher fees during times of congestion
        // safety: can this mul overflow?
        uint256 lPayoutAmt = block.basefee * rewardMultiplier;

        if (lPayoutAmt <= address(this).balance) {
            payable(lRecipient).transfer(lPayoutAmt);
        } else { } // do nothing if lPayoutAmt is greater than the balance
    }
}
