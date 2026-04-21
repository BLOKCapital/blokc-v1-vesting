# Vesting V1

Cliff-plus-linear token vesting system with DAO oversight, built on OpenZeppelin V5.

## Contracts

- **VestingWalletFactory**: Deploys and registers vesting wallets. Single source of truth for the active DAO address. 2-step DAO rotation.
- **VestingWalletBlokc**: Per-beneficiary vesting wallet. Extends OZ `VestingWallet` + `VestingWalletCliff` with DAO-gated revoke, pausable releases, ownership rescue, and governance delegation.

## Build

```shell
forge build
```

## Test

```shell
forge test
```

## Deploy

add DAO_ADDRESS=0x... in DeployAll.s.sol

```shell
forge script script/DeployAll.s.sol --rpc-url <rpc_url> --broadcast
```
