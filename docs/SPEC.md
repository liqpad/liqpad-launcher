# Liqpad Protocol Specification

## Product boundary

Liqpad is a permissionless Base launchpad for one launch shape only: native B20 ASSET / VVV. It is not a generic token factory, configurable-pair AMM, or switchable protocol tax.

Each `createLaunch` is atomic:

1. Predict and create the native B20 through Base's B20 factory precompile.
2. Set 18 decimals, `1_000_000_000e18` supply, and cap equal to supply.
3. Apply `contractURI`; record description, logo, website, and social links on-chain.
4. Give the Liqpad hook only `BURN_ROLE`, then renounce the final administrator.
5. Register and initialize the B20/VVV v4 pool with LP fee `0` and tick spacing `200`.
6. Transfer the complete inventory to `LockedPositionVault`, mint single-sided liquidity, and make the vault the position NFT recipient.
7. Record the pool ID/profile and emit `Launch`.

Any failed postcondition reverts the transaction.

## Immutable market rules

- Base chain ID `8453`; native B20 ASSET only; 18 decimals; fixed one-billion supply.
- VVV is the only quote asset.
- Pool LP fee is `0`; Liqpad hook constants assess `100` basis points.
- B20 fees are burned atomically; VVV allocation is 70% creator / 30% protocol.
- Locked positions have no decrease-liquidity or NFT withdrawal path.
- Exact-output swaps are disabled.

Factory configuration is one-shot and burns its authority. Factory, hook, router, and vault are non-upgradeable and expose no fee toggle or market-rule administration.

## Metadata and roles

`Profile` mirrors creator, name, symbol, `contractURI`, description, logo URI, website, X/Twitter, Telegram, Farcaster, Discord, pool ID, and launch time.

After launch, creator and factory have no B20 admin, mint, pause, unpause, freeze, seize, operator, or metadata authority. The hook's burn role permits only destruction of B20 it holds as a fee.

## Fee ownership and engine

The creator's 70% VVV is creator revenue, isolated by token and claimable only through `claim(token)` or `claimAll()`. The protocol's 30% can move only to immutable `DiemEngine`; it funds sVVV, DIEM, and protocol-owned Venice inference rather than routine owner withdrawals.

Anyone may harvest. The engine retains a default 5% liquid buffer (20% hard cap), stakes excess VVV, and mints DIEM when unlocked sVVV reaches the threshold. Its owner controls reserve, threshold, DIEM auto-staking, harvest pause, and timelocked unwind. The adapter is fixed at deployment and bound once; migration requires separately reviewed deployment work.

Because the owner can initiate unwind after Liqpad's timelock and Venice cooldowns, the engine is not trustless. Owner authority does not include creator claims, B20 market rules, LP withdrawal, or arbitrary adapter calls.
