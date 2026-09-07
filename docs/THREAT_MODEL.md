# Liqpad Threat Model

## Current deployment

| Role | Address | Status |
| --- | --- | --- |
| LiqpadFactory | `0x312107CE4E6A476edb5F243f456cBbf71356713F` | Live. `quotedFrame = 115200`. `configAdmin` burned. |
| LiqpadLaunchHook | `0x3056518d30315c2D6A55eB6FEB5c8F31Ee6D60cC` | Live. CREATE2 salt `0x…8366`. |
| FeeRouter | `0x9e2c6D47Cea0F6BC63E4A6D6870f713adD5B5FFF` | Live. Immutable engine. |
| LockedPositionVault | `0xa7069F829e9a5790a3c030006faEF5d0006729cc` | Live. Factory-only locker. |
| HookDeployer | `0xf8FE8D707f9E555A1DBDDcF9C1bb8d791ecD9Ac5` | Live. |
| DiemEngine | `0xd44BbD89d490B079ba546e192eb30CB1836F2958` | Live. |
| VeniceAdapter | `0xBEa3A03c4A76fADdBD77458525a4E36eAE64d746` | Live. |
| INITIAL_OWNER | `0x39F2d898A5C6CdD29ad26180c7b272FBE9E30d83` | Base Safe. |

Quote asset is only mainnet VVV `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf`. Frame `115200` is B20 per 1 VVV in Uniswap tick space (~10k VVV FDV on 1B supply). `ticksFor` flips sign from token sort and places single-sided B20 on the correct side of the price.

## Scope and security objectives

This model covers B20 creation, Uniswap v4 launch-pool admission and fee accounting, tick-frame initialization, locked LP custody, FeeRouter claims, DiemEngine harvesting, and VeniceAdapter custody. Deployment key compromise, frontend compromise, oracle/value risk, governance of external protocols, and defects in Base, Uniswap, or Venice are external dependencies.

Objectives:

1. A launched B20 has no surviving administrator, mint, or pause authority. The launch hook may retain only `BURN_ROLE`.
2. B20 fees are burned atomically and never become creator or platform inventory.
3. Creator and platform VVV accounting is isolated at 70/30.
4. Only factory-registered B20/VVV pools with zero LP fee and tick spacing 200 can use the launch hook.
5. Starting price is the protocol frame, not tick 0. Factory sends the full 1B inventory through `LockedPositionVault.lock(key, token, amount, tickLower, tickUpper)`. The LP NFT cannot be approved, transferred, decreased, or withdrawn.
6. Harvesting is permissionless but cannot reenter, redirect approvals, replace the adapter, or expose creator accruals.
7. Venice custody exits only through the owner-gated, timelocked unwind state machine.

## Assets and trust boundaries

| Asset | Custodian | Authorized movement |
| --- | --- | --- |
| Launch B20 fees | Hook transiently | Immediate `burn()` only |
| Creator VVV | FeeRouter | `claim(token)` / `claimAll()` by the recorded creator |
| Platform VVV | FeeRouter | Permissionless sweep to immutable DiemEngine `0xd44BbD89…` only |
| Liquid reserve VVV | DiemEngine | Venice staking through immutable adapter |
| sVVV and DIEM | VeniceAdapter | Verified Venice calls; no arbitrary transfer |
| Locked LP NFT | LockedPositionVault | No outbound approval or transfer interface |
| Quoted frame | Factory storage | Set once in `configurePhase3`; admin burned |

Trusted externals: Base B20 precompile, Uniswap v4 PoolManager/PositionManager, Permit2, VVV, Venice StakingV2, DIEM.

The engine is not trustless. Its owner (the Safe) may pause harvest, tune bounded policy, and complete a timelocked unwind of **protocol** capital only. Owner authority never extends to creator revenue, the 1%/burn/70/30 rules, VVV-only pairing, the burned frame, or locked LP.

## Invariants

- `creatorAccrued + platformAccrued` equals each assessed VVV fee.
- Hook and FeeRouter B20 balances are zero after a completed fee callback.
- No creator, factory, or hook holds B20 admin/mint/pause after launch.
- Engine VVV allowance to the adapter is zero after a successful stake.
- `quotedFrame` is immutable after `configurePhase3`.
- `ticksFor` always puts B20 inventory in range at `poolTick`.
- Adapter engine binding is one address for the life of the adapter.
- Unwind cannot start without the owner and cannot finish before the engine timelock / Venice cooldowns.

## Residual risks and ops

- Venice StakingV2 is upgradeable. Recheck implementation before large harvests.
- Uniswap v4 PoolManager / PositionManager remain external trust.
- First live launch must prove: `initialize` at frame tick, vault owns the NFT, `PositionLocked`, nonzero liquidity on the B20 side.
- Unwind is a deliberate trust assumption. Do not market it as trustless.
- Exact-output swaps stay disabled. Routers use exact-input.
- Production quote is pinned VVV only. Do not register ETH/USDC on this factory.
- Private keys, RPC, Basescan verification, Safe threshold, monitoring, and incident response are operational.