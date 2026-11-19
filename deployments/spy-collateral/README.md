# Lending liquidations for pSPY collateral (lending.py)

Off by default. The worker turns it on only when BOTH of these hold:
1. this folder has `keeper.json` with the pins below;
2. the App Platform env sets `LENDING_LIQUIDATIONS=true`.

If either is missing, or any pin mismatches at startup, the worker logs `lending_off` with a reason and runs margin
liquidation exactly as before.

`keeper.json` (write it after the ceremony from `peridot-contracts-2-5` `deployments/spy-collateral/spy-collateral-mainnet.json`):

```json
{"chainId": 4663, "controller": "0x6148183676E304dbe63a85C350c208DA3cEAc39C",
 "pUSDG": "0x55aEd0569c8f0D166D71facE57B57C2f2624a563", "pSPY": "0xa6660499a9cB9B6691247fE1FAbc248f502E5fB3",
 "liquidator": "<SpyCollateralLiquidator>", "liquidatorRuntimeHash": "<cast keccak $(cast code <liquidator>)>",
 "delegate": "<RobinhoodSpyCollateralDelegate>", "delegateRuntimeHash": "<cast keccak $(cast code <delegate>)>",
 "fromBlock": <the ceremony's pSPY _supportMarket block>, "maxRepayUsdg": 100000000}
```

Pins checked at startup:
- the liquidator runtime hash and its wiring (debt pUSDG, collateral pSPY, beneficiary Ledger);
- `pSPY.implementation() == delegate`;
- the delegate runtime hash.

Any later pSPY implementation change, or a new liquidator, must update this file in the same ceremony (the 11-17 lesson).
Then force-rebuild the app (`doctl apps create-deployment --force-rebuild`).

Behaviour:
- **Discovery:** `MarketEntered(pSPY, account)` logs from `fromBlock`, fetched in 10M-block chunks.
- **Each cycle, after the margin cycle:** read `getAccountLiquidity`.
  - Error 15 (SPY closed or stale): `spy_closed`, nothing is sent.
  - Shortfall with pUSDG debt: `SpyCollateralLiquidator.liquidate(account, repay)` with `repay = min(close factor x debt, seizable pSPY value / 1.08 x 99 %, maxRepayUsdg)`.
- **Gas:** 3x estimate, under the shared 12M cap. The anvil rehearsal used 988,755 gas.
- **Journals:** stored in the same table with ids >= 1e12, using the same intent / submitted / confirmed rules.
- **Shared nonce:** while a lending send is unresolved, margin only monitors.
- **Read failures:** they report `lending_degraded` and never stop margin. Only a failed or ambiguous send raises `operator_attention`.
- **Shortfall without pUSDG debt** (for example NVDA borrowed against pSPY): reported as `lending_unsupported_shortfall`, nothing sent; the liquidator repays pUSDG only.
- **Smoke run 2026-11-19 (mainnet, monitor-only, no database):** `runtime_verified` (31/7), `lending_off` (disabled / no_config), then `monitoring` cycles. `CloudLendingSigner.submit` and `receipt` have never run end to end (unit-tested policy only).
