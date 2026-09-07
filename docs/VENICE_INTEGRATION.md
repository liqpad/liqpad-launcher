# Venice Integration and Protocol-Owned Inference

Only Liqpad's 30% VVV allocation reaches `DiemEngine`. This is protocol-owned Venice capital: VVV becomes sVVV collateral, sVVV is locked to mint DIEM, and DIEM may be staked for inference capacity. Intended uses are the Liqpad agent, launch tooling, support, and optional creator compute boosts—not creator revenue, founder salary, or a user farm.

## Base contracts

| Contract | Address | Role |
| --- | --- | --- |
| VVV | `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` | Protocol allocation input |
| sVVV / StakingV2 | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` | VVV staking and DIEM mint/burn |
| DIEM | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` | Inference-credit asset and staking contract |


## Verified typed calls

```solidity
// sVVV / StakingV2
stake(address recipient, uint256 amount)
initiateUnstake(uint256 amount)
unstake()
getDiemAmountOut(uint256 sVVVAmountToLock)
mintDiem(uint256 sVVVAmountToLock, uint256 minDiemAmountOut)
burnDiem(uint256 diemAmountToBurn)
balanceOf(address account)
balanceOfUnlocked(address account)
cooldownDuration()

// DIEM
stake(uint256 amount)
initiateUnstake(uint256 amount)
unstake()
balanceOf(address account)
cooldownDuration()
stakedInfos(address account)
```

`VeniceAdapter` uses typed calls only—no guessed selectors. It holds sVVV/DIEM because Venice operations apply to the caller's position, binds once to one engine, and exposes no arbitrary-call or owner-withdraw function.

## Lifecycle and trust

Anyone calls harvest/compound. The engine leaves its configured VVV buffer, grants an exact temporary allowance, stakes excess VVV, clears the allowance, and mints DIEM at the live quoted rate once the threshold is met. DIEM remains liquid or is auto-staked.

Unwind is exceptional recovery/migration, not a hot-wallet cash-out workflow. Only the owner can schedule it; Liqpad's timelock and Venice's DIEM/sVVV cooldowns apply, and DIEM is burned before collateral unlock.

The engine is owner-controlled, not trustless. Use a reviewed multisig. The owner cannot pull creator accruals, change immutable fee allocation, withdraw locked LP, or bypass Venice's burn/cooldown sequence. Recheck verified proxy implementation and ABI before authorized mainnet deployment.
