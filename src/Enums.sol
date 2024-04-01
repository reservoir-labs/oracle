// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// The two values that can be queried:
//
// - RAW_PRICE: the price of the tokens in the Pool, expressed as the price of the second token in units of the
//   first token. For example, if token A is worth $2, and token B is worth $4, the pair price will be 2.0.
//   Note that the price is computed *including* the tokens decimals. This means that the pair price of a Pool with
//   DAI and USDC will be close to 1.0, despite DAI having 18 decimals and USDC 6.
//
// - CLAMPED_PRICE: the clamped price of the tokens in the Pool, in units of the first token. Clamping is necessary as
//   as a countermeasure to oracle manipulation attempts.
//   Refer to `maxChangeRate` and `maxChangePerTrade` in `ReservoirPair` and the `Observation` struct
//   Note that the price is computed *including* the tokens decimals, just like the raw price.
enum Variable {
    RAW_PRICE,
    CLAMPED_PRICE
}
