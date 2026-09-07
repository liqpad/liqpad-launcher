# Liqpad Fee, Burn, and Allocation Mission

## Fixed rules

- Pool LP fee is `0`; no LP-fee layer is added to Liqpad's hook.
- Liqpad's hook constants use `100` basis points.
- Every collected B20 amount is burned immediately, before VVV allocation.
- B20 never enters `FeeRouter` or becomes creator/protocol inventory.
- Collected VVV is allocated 70% creator / 30% DiemEngine.
- There is no owner-controlled recipient, percentage switch, or EOA sweep.

## Directions

On a VVV → B20 buy, the hook assesses 1% of exact VVV input. Seventy percent accrues to the creator and thirty percent to DiemEngine; the rest enters the swap.

On a B20 → VVV sell, accepted v1 behavior burns 1% of exact B20 input and skims 1% of gross VVV output for the 70/30 allocation. The remainder goes to the seller. This two-currency sell behavior is explicit and covered by accepted Phase 3 tests. “Charged once” means the pool LP fee is zero and there is one Liqpad hook; it must not conceal that the sell path has two currency-side assessments.

Changing this directional behavior would change accepted economics and requires separate approval. Exact-output swaps remain disabled.

## Ownership and purpose

The 70% creator share is creator revenue. The 30% protocol share is Venice capital whose path is FeeRouter → DiemEngine → VVV staking → sVVV locking → DIEM minting/optional staking. It supports Liqpad inference, tooling, support, and optional creator compute boosts—not founder compensation or a user farm.

Rounding is deterministic: `fee = floor(amount × 100 / 10_000)`, creator share is `floor(vvvFee × 7_000 / 10_000)`, and protocol receives the remainder.

Required invariants: hook/router B20 balances finish at zero; creator plus protocol equals each VVV assessment; neither side can claim the other's VVV; protocol VVV can move only to DiemEngine; and only registered B20/VVV pools can settle fees.
