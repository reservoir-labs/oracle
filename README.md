# Reservoir Price Oracle

The Reservoir Price Oracle is designed to work with
[Euler Vault Kit](https://github.com/euler-xyz/euler-vault-kit) by implementing
the `IPriceOracle` interface.

This oracle provides a geometric mean price between two assets, averaged across
a period. The geometric mean has a useful property whereby we can get the
inverse price by simply taking the reciprocal. Something that arithmetic mean
prices do not provide.

Powered the built-in on-chain price oracle of Reservoir's [AMM](https://github.com/reservoir-labs/amm-core).

## Interfaces

For more information on the `IPriceOracle` interface, refer to Euler's [documentation](https://github.com/euler-xyz/euler-price-oracle?tab=readme-ov-file#ipriceoracle).

For direct usages of the oracle, refer to
[IReservoirPriceOracle.sol](src/interfaces/IReservoirPriceOracle.sol) for
methods to obtain raw data from the AMM pairs.

## EVM Compatibility

Currently the `ReservoirPriceOracle` contract makes use of the transient storage
supported since the Cancun fork via OZ's `ReentrancyGuardTransient` lib.
At the time of writing only ETH mainnet is supported.
If deployment to other chains where transient storage is not yet supported,
we can revert to using solady's `ReentrancyGuard` for the most gas efficient
implementation.

## Usage

### Install

To install Price Oracles in a [Foundry](https://github.com/foundry-rs/foundry) project:

```sh
forge install reservoir-labs/oracle
```

### Development

Clone the repo:

```sh
git clone https://github.com/reservoir-labs/oracle.git && cd oracle
```

Install forge dependencies:

```sh
forge install
```

[Optional] Install Node.js dependencies:

```sh
npm install
```

Compile the contracts:

```sh
forge build
```

### Testing

The repo contains 3 types of tests: unit, large, and integration.

To run all tests:

```sh
npm run test:all
```

### Linting

To run lint on solidity, json, and markdown, run:

```sh
npm run lint
```

Separate `.solhint.json` files exist for `src/` and `test/`.

## Security vulnerability disclosure

Please report suspected security vulnerabilities in private to
[security@reservoir.fi](security@reservoir.fi). Please do NOT create publicly
viewable issues for suspected security vulnerabilities.

## Audits

These contracts have been audited by TBD and TBD auditing firm.

## License

The Euler Price Oracles code is licensed under the [GPL-3.0-or-later](LICENSE) license.
