# FloorHook

The Uniswap v4 hook behind [floor.top](https://floor.top)'s pools on Robinhood Chain. It takes floor.top's trading fee on pools that pair native ETH with a floor.top coin: $FLOOR's pool from its sale, and each floor.top coin's pool once it graduates from its bonding curve.

| | |
| --- | --- |
| Chain | Robinhood Chain (4663) |
| Hook | [`0x7d309A342f12e7f788CCF992740E5C482D4B6044`](https://robinhoodchain.blockscout.com/address/0x7d309A342f12e7f788CCF992740E5C482D4B6044?tab=contract) |
| Source verified | [Blockscout](https://robinhoodchain.blockscout.com/address/0x7d309A342f12e7f788CCF992740E5C482D4B6044?tab=contract) (full match), [Sourcify](https://repo.sourcify.dev/4663/0x7d309A342f12e7f788CCF992740E5C482D4B6044) (exact match) |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Permissions | `beforeInitialize`, `afterSwap`, `afterSwapReturnsDelta` (address bits `0x2044`) |
| Deployed | tx `0x6cb55ed6f41a0391eb705699d2a1fd6f2c6572d814c2d7e4315e40fe58e27155` through the deterministic CREATE2 deployer |
| Upgradeable | No |

The source is [`src/desk/FloorHook.sol`](src/desk/FloorHook.sol), with the slice of the v4 interfaces it uses in [`src/desk/v4/V4.sol`](src/desk/v4/V4.sol).

## How it works

**Pools.** Each pool pairs native ETH (currency0) with one floor.top coin, at tick spacing 200, with an LP fee of 0 and no dynamic fee. The hook charges the fee instead.

**The fee.** In `afterSwap` the hook takes `feeBps` of the swap's unspecified side (the output of an exact-input swap, the input of an exact-output one) with `PoolManager.take`, and returns it as the hook delta. It is 1% today and can never exceed 2% (`MAX_FEE_BPS`). Quotes from the PoolManager include it, so a swapper receives exactly what it is quoted. Uniswap's protocol fee is computed inside the AMM swap and is untouched. The fee and its split are fixed for each pool when it is registered; the owner cannot change them afterwards.

**Where it goes.** Each pool splits its fee three ways: a platform share to floor.top (0.10% of each trade), then a buyback share that buys the coin in the same pool and burns it, and the rest paid in ETH into the coin's own vault (`DeskLaunch.fundVault`), which holds tokenized stock its holders can redeem against. Fees taken in the coin have their buyback share burned as they stand; the rest is sold in the pool for ETH.

**Sweeps.** The swaps that convert and spend fees are made by the keeper or the owner, or by anyone once neither has swept a pool for 7 days. Each is capped at half the fee's share of the pool's in-range reserves, limited to 3% price movement (it reverts rather than filling part), and to one per pool per block, so sandwiching a sweep costs more in fees than it moves the price. v4 does not call a hook on its own swaps, so sweeps pay no fee.

**Pool creation.** `beforeInitialize` admits only pools registered by the owner or by an approved registrar, and only from their registered initializer. On floor.top those are $FLOOR's sale contract (FloorSeeder) and the desk's graduator, each of which registers its pool, creates it and adds a full-range position it has no function to remove, in one transaction.

**What it does not do.** No liquidity permissions: it never touches LP positions or blocks withdrawals. It ignores `hookData`, so any v4 router can swap through it. It has no upgrade path.

**Roles.** The owner registers pools before they exist, names the keeper and the registrars, and can move a pool's platform wallet. It cannot change a live pool's fee or split, touch its liquidity, or take the fees held for its buyback and vault. If a coin's launch is recovered (its coin frozen), anyone may send that pool's buyback and vault ETH to the launch's successor.

## Build and check against the deployment

```sh
git clone --recursive <this repo> && cd floor-hook
forge build
./script/check-deployment.sh   # rebuilds and compares with the deployment transaction, byte for byte
```

`foundry.toml` carries the deployment's compiler settings (solc 0.8.26, via-IR, 200 optimizer runs, cancun) and its remappings verbatim: they are part of the metadata hashed into the bytecode. OpenZeppelin is pinned at v5.7.0.

## Test pool

**Live on Robinhood Chain** (opened 2026-10-03 with 0.005 ETH against 5M FHTEST):

| | |
| --- | --- |
| Pool id | `0x3e0da69e155a172029e88f4efedc5b7688cea18b7cf8875cf7e43261aa0fc650` |
| Pool key | ETH `0x0000000000000000000000000000000000000000` / FHTEST `0xcfbc42e8AE292d1f83596e90750fD2e6C6c09c5f`, fee 0, tick spacing 200, hook `0x7d309A342f12e7f788CCF992740E5C482D4B6044` |
| HookTestPool | [`0x3BE3C58b0074B29482b1Cc185Ca43b2e4669a65E`](https://robinhoodchain.blockscout.com/address/0x3BE3C58b0074B29482b1Cc185Ca43b2e4669a65E) |
| Transactions | deploy `0x5074753b9f57ad69a8a2c3bebddd8dcd5b102c93b570e69ca884f6f21a2b7c02`, register `0x274c342678c7b946c1896bb0416b6f18a7ced3c049d13a6951da0dc379c20bc9`, open `0xa59a3a2a49af508eace1c6c46f08546c7beda72045d35787fc227fb5955f4ddd` |

[`src/testing/HookTestPool.sol`](src/testing/HookTestPool.sol) opens a pool on the live hook with a worthless test token ("floor.top hook test", FHTEST), standing in for a floor.top launch where the hook needs one. Its owner can remove the position again. [`script/HookTestPool.s.sol`](script/HookTestPool.s.sol) deploys, registers and opens it; [`test/HookTestPool.t.sol`](test/HookTestPool.t.sol) runs the whole thing on a fork of Robinhood Chain:

```sh
forge test --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

## License

MIT
