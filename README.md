# Liqpad

Permissionless B20 launchpad on Base. Every token is a native B20 paired only with `$VVV`. LP is locked. Fees burn supply and fund protocol-owned Venice compute.

## What it does

One transaction:

1. Creates an admin-less B20 (1,000,000,000 supply, 18 decimals).
2. Opens a Uniswap v4 pool against `$VVV` (0 LP fee, tick spacing 200).
3. Sets the start price from a protocol **tick frame** (~10k VVV FDV).
4. Locks the full supply as single-sided B20 liquidity.
5. Stores name, logo, description, website, and socials on-chain.

After launch the creator has no mint, pause, or admin role. The hook may keep only `BURN_ROLE` so it can destroy fee tokens it already holds.

## Fees

Swaps pay **1%** in the hook, not as a pool LP fee.

- The **B20** side of that 1% is burned.
- The **VVV** side is split **70% creator / 30% protocol**.
- Creators claim their 70% from the fee router.
- The 30% is swept to `DiemEngine`, staked through Venice (`VVV` → `sVVV` → `$DIEM`), and used as protocol inference budget.

Harvest is permissionless. Unwinding protocol `$DIEM` back to `$VVV` is owner-gated and timelocked. It is not a hot-wallet cash-out.

## Tick frame

The factory does not start pools at 1:1.

`quotedFrame = 115200` means “B20 per 1 VVV” in Uniswap tick space. The factory flips the sign from token address order so launchers never pick token0/token1. Liquidity is placed on the **B20** side of that price.

## Live contracts (Base)

| Component | Address |
| --- | --- |
| Factory | `0x312107CE4E6A476edb5F243f456cBbf71356713F` |
| Hook | `0x3056518d30315c2D6A55eB6FEB5c8F31Ee6D60cC` |
| Fee router | `0x9e2c6D47Cea0F6BC63E4A6D6870f713adD5B5FFF` |
| LP vault | `0xa7069F829e9a5790a3c030006faEF5d0006729cc` |
| DiemEngine | `0xd44BbD89d490B079ba546e192eb30CB1836F2958` |
| Venice adapter | `0xBEa3A03c4A76fADdBD77458525a4E36eAE64d746` |
| Owner Safe | `0x39F2d898A5C6CdD29ad26180c7b272FBE9E30d83` |

External: VVV `0xacfE6019…21bf`, sVVV `0x321b7ff7…40Ff`, DIEM `0xF4d97F2d…a024`, B20 factory `0xB20f…0000`.

## Repo layout

```text
src/LiqpadFactory.sol          B20 create, pool init, metadata, frame
src/LiqpadLaunchHook.sol       1% fee, B20 burn, VVV split
src/FeeRouter.sol              creator claim + platform sweep
src/LockedPositionVault.sol    locked LP NFT
src/DiemEngine.sol             protocol VVV → Venice
src/adapters/VeniceAdapter.sol Venice stake / mint / unwind
docs/ADDRESSES.md
docs/FEES.md
docs/MISSION.md
docs/SPEC.md
docs/THREAT_MODEL.md
docs/VENICE_INTEGRATION.md
```

## Trust model (short)

Market rules are immutable: VVV-only pair, 1% fee, B20 burn, 70/30, locked LP, burned frame.

The Safe can pause harvest and unwind **protocol** VVV/DIEM. It cannot take creator claims or unlock LP.

## License

MIT