# Operational record

Authoritative history of what is deployed on Robinhood Chain mainnet (chain ID `4663`),
kept in sync with the JSON records in this directory. Each mainnet action has a
`<name>.json` and a detached `<name>.sha256`; regenerate the digest with
`shasum -a 256 <file>.json` whenever a record changes.

Verify every digest at once:

```bash
cd deployments && shasum -a 256 -c *.sha256
```

`README.md` in the repository root is the introduction to the system; this file is the
change log and the evidence trail behind it.

## Change history

The Robinhood mainnet vault system was deployed unconfigured and independently verified
on 2026-07-27. The initial deployment record captures the system before pair
registration and confirms that the vault, reserve, and adapter held no NVDA or USDG.
Exact addresses, transactions, source commit, and ownership checks are in
[`deployments/robinhood-mainnet.vault-system.json`](./robinhood-mainnet.vault-system.json).

An `NVDA/USDG/CANARY` pair was subsequently registered with a $100 allocation cap and a
$10 bounded settlement-swap limit. A capped mainnet cycle exercised separate stock and
USDG deposits, full-range LP minting, rebalancing, fee checkpoints, reserve fee
accounting, oracle-guarded liquidity removal, bounded settlement swaps, reserve-backed
loss coverage, empty-position NFT burning, and independent withdrawals. The final
recorded cycle state had zero principal, idle assets, LP liquidity, and reserve balance.

That cycle exposed an adapter edge case: collecting fees after all liquidity had been
removed, but before the empty NFT was burned, caused PositionManager to reject the empty
position update. Commit `c0a75d2bd18841b7995bd163dad032331511caf4` makes fee collection
return zero in that state and adds unit and pinned-fork regression coverage. The commit
passed 72 local tests, seven pinned Robinhood fork tests, contract-size checks, and
Almanax scan `403fead9-54d2-4cea-b47c-1b79b03f0836` with zero findings. The adapter proxy
upgrade was executed and independently verified on-chain on 2026-08-11: the live proxy
uses the reviewed implementation, its runtime code hash matches the tested artifact,
ProxyAdmin ownership remains with the timelock, and its wiring and registered pool key are
unchanged. The combined post-upgrade canary remains pending until the vault upgrade is
active. The replacement deployment, timelock operation, execution receipt, and pinned
post-execution checks are recorded in
[`deployments/robinhood-mainnet.adapter-empty-position-upgrade.json`](./robinhood-mainnet.adapter-empty-position-upgrade.json),
with its detached digest in
[`deployments/robinhood-mainnet.adapter-empty-position-upgrade.sha256`](./robinhood-mainnet.adapter-empty-position-upgrade.sha256).

A subsequent LLM review identified that a side could withdraw unmatched idle assets before
an uncheckpointed shared LP loss was allocated, shifting that loss to the opposite side.
Commit `0bcf8c993906aedd23a59a2c73b88c169d90fe55` makes every principal reduction settle
current loss while LP liquidity remains, recognizes loss atomically during guardian
decreases, and blocks emergency withdrawals after a partial decrease until the LP is fully
removed. Pairs with no open LP liquidity and fully completed guardian exits retain the
oracle-free idle withdrawal path. The remediation passed 76 local unit/fuzz/invariant
tests, seven pinned Robinhood fork tests, formatting and contract-size checks; the vault
runtime is 23,969 bytes, 607 bytes below the EIP-170 limit. Almanax scan
`d2370f15-89d1-4a1f-8c2f-812df7701fdd` has zero active findings. Its only result,
`7b2b8c7c-b34e-45a4-ab6d-a5e098653ffa`, was dismissed as the intentional fail-closed
availability tradeoff: bypassing oracle/pool validation while shared LP exposure remains
would recreate the high-severity cross-side loss evasion. The vault proxy upgrade was
executed and independently verified on-chain on 2026-08-11: the live proxy uses the
reviewed implementation, its runtime code hash matches the tested artifact, governance
roles and dependency wiring are unchanged, and the pair remains paused and fully drained.
The combined post-upgrade vault and adapter canary remains pending. The replacement
deployment, timelock operation, execution receipt, and pinned post-execution checks are
recorded in
[`deployments/robinhood-mainnet.vault-shared-loss-upgrade.json`](./robinhood-mainnet.vault-shared-loss-upgrade.json)
and its detached digest is in
[`deployments/robinhood-mainnet.vault-shared-loss-upgrade.sha256`](./robinhood-mainnet.vault-shared-loss-upgrade.sha256).
The exact capped post-upgrade canary amounts plus the independent enable and recovery-pause
timelock operations are recorded in
[`deployments/robinhood-mainnet.post-upgrade-canary.operations.json`](./robinhood-mainnet.post-upgrade-canary.operations.json),
with its detached digest in
[`deployments/robinhood-mainnet.post-upgrade-canary.operations.sha256`](./robinhood-mainnet.post-upgrade-canary.operations.sha256).

A third review pass addressed pool-price dependence and the exit availability window. It was
executed and independently verified on-chain on 2026-09-03. Three changes shipped together as
one upgrade because each needs vault bytecode and the vault had 217 bytes of EIP-170 headroom:

- `7d2c20002f2f7c8c40e63c4cb78b7e115c423685` extracts the withdrawal deficit waterfall into
  the linked `SettlementLib` and lifts `PairConfig`/`PairLedger` to file scope so the
  library can take storage pointers. `forge inspect storageLayout` confirms the top-level
  slots and both struct field layouts are byte-identical to the deployed layout. Vault
  runtime 24,420 -> 22,065 bytes, margin 217 -> 2,511.
- `40f30caaec0e0acfa7ad2a3593cd7cc8c4b76b36` values the LP position at the oracle-derived
  reference price for loss accounting, via `UniswapV4PairedAdapter.positionStateAt`, so a
  pool pushed inside the deviation bound can no longer manufacture or mask a shortfall.
  `totalPairAssets` stays pool-priced as the market view.
- `28104e5bf4d7d7a36da95d7ceb67f547d0ef2a94` splits the deviation bound, adding
  `maxRemovalDeviationBps` for exits while allocation keeps `maxPriceDeviationBps`. The
  field packs into the free bytes of the existing `FeedConfig` slot, so no field shifts and
  deployed pairs read zero, which falls back to the allocation bound. The registration
  invariant becomes `removalToleranceBps >= removalBound / 2 + buffer`, matching the
  observed `d/2` amount response, which lets the canary's immutable 400 bps tolerance carry
  a 600 bps removal bound without changing `removalToleranceBps` (it has no setter after
  `registerPair`).

An earlier commit pair, `10e04a68a36763879e835f40e3b669c1aa961057` and
`966646863d9d4eaec6bbdb92790184d2be2df49a`, adds `withdrawableAssets`, which reports only
the idle a side can actually receive in the current block. `liquidAssets` reports custody
and overstates access while LP liquidity is open, and the pToken counted it as cash. The
consumer side landed separately in `peridot-contracts-2-5` as
`895dc6f0c101597277c571d43f040ca6f11bfd6e`.

`b96914e0ff562bbaf64ca94acfbd4eef0643bcdb` then rounds the registration invariant's half
up, so an odd removal bound cannot accept a tolerance one bp short of the amount deviation
it must absorb, and range-checks the bound before its `uint16` cast so an out-of-range
value cannot truncate into a plausible-looking payload.

`91225bb1800f0cb537be403e4065c2b48de5d3cd` adds `UpgradeVaultSystem.s.sol`, which deploys
the three replacements and prints the four chained timelock payloads. Order is enforced by
review, not by the chain: the new vault calls `positionStateAt` and `validateRemovalPrice`,
so the adapter and guard must be live before it. The removal-bound payload reads the live
feed config and changes only that field. Simulated against mainnet, all three ProxyAdmins
are confirmed timelock-owned and payload four decodes to the live config with only
`maxRemovalDeviationBps` changed from 0 to 600.

Every commit passed the full unit suite (86 tests), the seven pinned fork tests, formatting
and contract-size checks, and Almanax scans `06ad809f-db1c-4d1a-96a7-f3805db58499`,
`6734200d-2f7d-4954-98fa-aad8cab2e87b`, `397694f0-5e67-4c54-9668-482c311c6503`,
`ebfbcb29-a99e-4ac6-86b1-79680943e4e4`, `76630d52-fb9d-4876-9e5a-6b6dd8c6f0db` and
`5e251cec-ab33-40e6-b756-5b1b8822050a` with zero active findings.

The upgrade replaced three implementations and introduced the linked `SettlementLib` at
`0x813AbFeC0DE50f8674798CbaB72Ed7b5D8CcB9cB`; the vault implementation cannot be reproduced
from source without linking that exact address. It was scheduled as four
predecessor-chained timelock operations so the adapter and guard could not land after the
vault that calls them, and executed in that order. Post-execution verification at block
53313911 confirms all four operations `Done`, each proxy on its reviewed implementation,
the linked library present in the vault runtime, ProxyAdmin ownership still with the
timelock, governance roles and dependency wiring unchanged, and the bounds live at 300 bps
for allocation and 600 bps for exits. The pair carries zero principal and zero idle.

The pair remains allocation- and swap-enabled, carried forward from the
`CANARY_ENABLED_EMPTY_RECOVERY_READY` state staged on 2026-08-11. It is empty, and only the
configured side accounts can deposit into it. The replacement deployments, the four
timelock operations, and the pinned post-execution checks are recorded in
[`deployments/robinhood-mainnet.oracle-priced-loss-upgrade.json`](./robinhood-mainnet.oracle-priced-loss-upgrade.json),
with its detached digest in
[`deployments/robinhood-mainnet.oracle-priced-loss-upgrade.sha256`](./robinhood-mainnet.oracle-priced-loss-upgrade.sha256).
The post-upgrade canary, which still has never exercised guardian emergency removal,
remains outstanding.

## Deployment procedure

The order below is the reviewed rollout for a new pair. Simulate every script first;
`--broadcast` only for an execution that has been reviewed.

1. Deploy the standard OpenZeppelin `TimelockController` with
   `DeployVaultTimelock.s.sol`. The timelock is self-administered and has no external
   admin bypass. For the standalone canary, the deployer EOA may initially be both
   proposer/canceller and executor, but `TIMELOCK_MIN_DELAY` must be at least one hour.
   Before accepting material production TVL, use timelocked self-calls to increase the
   delay and migrate those roles to the approved multisig policy.

   ```bash
   DEPLOYER=0x... \
   TIMELOCK_PROPOSER=0x... \
   TIMELOCK_EXECUTOR=0x... \
   TIMELOCK_MIN_DELAY=3600 \
   forge script \
     script/DeployVaultTimelock.s.sol:DeployVaultTimelock \
     --account "$FOUNDRY_ACCOUNT" \
     --sender "$DEPLOYER" \
     --rpc-url "$ROBINHOOD_RPC_URL"
   ```

   Run this as a simulation first, review the predicted address and role assertions, and
   add `--broadcast` only for the reviewed mainnet execution. Use an encrypted Foundry
   keystore or hardware wallet; deployment and operation scripts do not accept plaintext
   private-key environment variables. Every mutating script also requires the public
   broadcaster address (`DEPLOYER`, `ACTION_ACTOR`, or `GOVERNANCE_ACTOR`) and binds
   generated transactions to that address.
2. Copy and verify
   [`deployments/robinhood-mainnet.nvda.template.json`](./robinhood-mainnet.nvda.template.json).
3. Run `PreflightRobinhood.s.sol` against a pinned Robinhood fork. Supply the detached
   registry-snapshot and manifest SHA-256 digests. It fails on missing code or hashes,
   token/oracle mismatch, stale or implausible prices, missing sequencer policy, a wrong
   PoolId, an uninitialized pool, or disagreement between PoolManager and StateView.
4. Deploy the implementations and proxies with `DeployVaultSystem.s.sol`, using the
   deployed timelock address as `TIMELOCK`.
5. For the standalone mainnet canary, run `ConfigureNvdaPair.s.sol` with
   `PAIR_LABEL=NVDA/USDG/CANARY`, temporary EOA side accounts, and deliberately small
   nonzero pair and aggregate caps. The pair is registered with allocation and swaps
   paused. The script prints four ordered timelock payloads by default. Schedule, inspect,
   and execute each payload with `OperateVaultTimelock.s.sol`; direct EOA configuration
   cannot bypass timelock ownership.
6. Use `RunNvdaCanary.s.sol` one action at a time: inspect `status`, enable allocation,
   deposit each side within explicit `CANARY_MAX_*_AMOUNT` limits, optionally fund each
   reserve side within separate `CANARY_MAX_RESERVE_*_AMOUNT` limits, rebalance,
   checkpoint, withdraw both sides, optionally burn the empty position NFT, pause and
   withdraw the canary reserve, verify `assert-drained`, and finally pause the vault pair.
   Use the governance, keeper, stock-side, USDG-side, reserve-admin, or funder key only
   for the action authorized to that address. Enable settlement swaps only as a separate,
   deliberate canary action. Set `PAYLOAD_ONLY=true` for vault/reserve governance actions
   owned by the timelock, then schedule and execute the printed call through
   `OperateVaultTimelock.s.sol`.
7. Seed the reserve with at most $100 of combined in-kind value during the smoke test.
   Keep the canary drained and paused after the test.
8. After the Peridot market contracts are ready, deploy the boosted pUSDG delegator,
   register the distinct `PAIR_LABEL=NVDA/USDG` production pair with that delegator as
   `USDG_SIDE_ACCOUNT`, configure the pToken while it remains paused, unpause vault
   allocation through governance, and only then enable the pToken's vault integration.
9. Stage production allocation through the configured side accounts.
   Permit2 allowances are created for the exact amount of each liquidity or swap
   operation and revoked before it returns. Initial reserve defaults allow at most $10
   per event, $25 per UTC day, and 50% of a realized deficit.

LP-backed withdrawals and guardian removals fail closed unless the Chainlink price is
fresh, the stock token oracle is unpaused, any configured sequencer feed is healthy and
past its grace period, and the zero-hook pool remains within the configured removal
deviation. The RHNVDA/USD feed is deviation-triggered at 0.5% with no off-hours heartbeat:
over its first nine weeks it was stale beyond the configured 12h bound for 25.9% of
wall-clock time, with ~52h weekend gaps in ten of ten weekends and a 76h gap over the
July 4 holiday. Any pair holding open LP liquidity through those windows cannot service an
LP-backed exit, so keeper policy, the pToken cash buffer, and collateral factors must be
sized against that, not against the average case.
Guardian emergency mode cannot bypass these checks. The current PoolManager exposes no
native observation/TWAP surface for this zero-hook pool, so deployment operations must
use private order flow and monitor the pool and oracle continuously; see the
[Uniswap v4 core architecture](https://github.com/Uniswap/v4-core). Settlement swaps
also enforce an oracle-derived per-hop execution-price floor and a bounded size, but
public submission retains residual sandwich risk inside the configured tolerance.
Withdrawals from pairs with no open LP liquidity remain available during oracle or pool
incidents. Idle tokens held alongside an open shared LP position are still economically
LP-exposed and therefore require the same validated accounting before either side's claim
can decrease.

The standard NVDA feed, refreshed Robinhood registry snapshot, and reviewed sequencer
waiver are recorded. The finalized canary policy, its detached hash, pinned live
preflight, chained timelock operations, and verified paused execution record are in
[`deployments/robinhood-mainnet.nvda.canary.json`](./robinhood-mainnet.nvda.canary.json),
[`deployments/robinhood-mainnet.nvda.canary.preflight.json`](./robinhood-mainnet.nvda.canary.preflight.json),
[`deployments/robinhood-mainnet.nvda.canary.operations.json`](./robinhood-mainnet.nvda.canary.operations.json),
and
[`deployments/robinhood-mainnet.nvda.canary.execution.json`](./robinhood-mainnet.nvda.canary.execution.json).
The separately reviewed operation that enables only canary allocation while retaining
the settlement-swap pause is in
[`deployments/robinhood-mainnet.nvda.canary.enable-allocation.json`](./robinhood-mainnet.nvda.canary.enable-allocation.json).
The generic template intentionally retains unresolved placeholders and must not be used
as an executable manifest.