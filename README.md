# Robinhood Boosted Vaults

Paired Stock/USDG liquidity vaults for Robinhood Chain. The vault keeps each side's
principal and cached claim separate while deploying matched value into allowlisted
Uniswap v4 pools.

The first deployment target is NVDA/USDG. Contracts are generic, but every pair is
disabled until its token, pool, and oracle configuration passes the deployment
preflight.

## Development

Install the exact revisions in [`dependencies.lock.json`](./dependencies.lock.json), then run:

```bash
forge build
forge build --sizes   # the vault is the EIP-170 constraint; check before and after changes
forge test
```

The vault links `SettlementLib`, so it cannot be deployed without the library. `forge test`
and `forge script` deploy and link it automatically; a manual deployment must deploy the
library first and pass `--libraries src/libraries/SettlementLib.sol:SettlementLib:<address>`.
`DeployVaultSystem` reads the deployer nonce after the implementations rather than assuming
a fixed offset, because the broadcast deploys an unlinked library ahead of the first
contract that needs it.

Set `ROBINHOOD_RPC_URL` to run the opt-in fork suite:

```bash
forge test --match-path 'test/fork/*'
```

The public endpoint `https://rpc.mainnet.chain.robinhood.com` serves archive state at the
pinned block and is sufficient for the fork suite, though it is rate limited and filters
by `User-Agent`. The fork test is skipped when `ROBINHOOD_RPC_URL` is unset. It is pinned
to Robinhood block `17091638` and verifies canonical bytecode, token/feed metadata, PoolManager versus
StateView, NVDA's PoolKey/PoolId, the oracle guard, Permit2 approvals, the complete
position NFT lifecycle, swaps in both directions, and an end-to-end vault
rebalance/checkpoint/withdrawal sequence.

## Contracts

- `RobinhoodBoostedVault` owns pair accounting and token custody. Deposits and claims
  remain native to either the stock side or USDG side; there are no transferable shares.
- `UniswapV4PairedAdapter` is the only component allowed to encode PositionManager or
  Universal Router operations. Each registered pair is bound to one zero-hook PoolKey.
- `StockOracleGuard` normalizes Chainlink prices, checks Robinhood's `oraclePaused`, and
  validates pool/oracle deviation before allocation or settlement. The bound is asymmetric:
  `maxPriceDeviationBps` gates allocation, where refusing to add liquidity costs nothing,
  and the wider `maxRemovalDeviationBps` gates every exit. Value on removal is protected by
  the adapter's oracle-anchored amount floors rather than by this check, and a pool
  deviation `d` moves a full-range position's amounts by only about `d/2`, so applying the
  allocation bound to exits would block withdrawals far tighter than value protection
  requires. A zero `maxRemovalDeviationBps` falls back to the allocation bound.
- `StrategyLossReserve` holds pair-specific in-kind fee reserves and enforces per-event,
  coverage-ratio, and rolling daily limits.
- `SettlementLib` holds the withdrawal deficit waterfall (reserve cover, then the bounded
  oracle-floored settlement swap). It is a linked library reached by `DELEGATECALL`, so
  storage and `address(this)` remain the vault's. It exists to keep the vault under
  EIP-170 and must be deployed and linked before the vault implementation.
- `VaultTypes` declares `PairConfig` and `PairLedger` at file scope so the vault and
  `SettlementLib` can share storage pointers to them. Field order is part of the deployed
  proxy layout: append only, never reorder.

Position value has two deliberately different views. `totalPairAssets` prices the position
at the pool's live `sqrtPriceX96` and is the market view. Everything that recognizes loss
prices it at the oracle-derived `referenceSqrtPriceX96` via
`UniswapV4PairedAdapter.positionStateAt`, so moving the pool inside the deviation bound
cannot manufacture a shortfall that scales both principals down, nor mask a real one.

Deposits are accepted only from the configured stock-side and USDG-side accounts. The
pair-value and aggregate USDG caps are optional governance circuit breakers: `0` disables
the corresponding cap, while any nonzero value enables it. This avoids imposing an
arbitrary protocol capacity ceiling while keeping a timelocked emergency control.

All four stateful contracts use initializer-based storage and are deployed behind
transparent proxies. Keepers can checkpoint and rebalance; guardians can only move the
system toward a paused/emergency state; configuration and proxy ownership belong to the
timelock. Upgrade authority is an intentional governance trust boundary: the timelock
must be controlled by the approved multisig policy, and upgrade/ownership events must be
monitored.

## Security review scope and lines of code

The proposed external-review wording currently combines the Robinhood boosted-vault
system with the separate ERC-4626 V3 LP-vault subsystem in
`peridot-contracts-2-5`. Counted together, that scope contains **3,823 Solidity nSLOC**:

| Component | Solidity nSLOC |
| --- | ---: |
| Robinhood vault, v4 adapter, loss reserve, oracle, local interfaces, and math | 2,045 |
| Robinhood boosted pUSDG delegate and vault interface | 370 |
| Robinhood proxy and access-control helpers | 34 |
| ERC-4626 V3 LP vault, oracle, local interfaces, and math | 1,374 |
| **Combined scope as worded** | **3,823** |

The count excludes blank lines, comment-only lines, tests, deployment scripts, generated
artifacts, vendored OpenZeppelin/Uniswap code, and the explicitly out-of-scope Peridot
lending core. The corresponding raw physical total is 4,510 lines. The reproducible
source snapshots are:

- `LP_VaultsUniswap` commit
  [`0bcf8c993906aedd23a59a2c73b88c169d90fe55`](https://github.com/joshschcom/LP_VaultsUniswap/commit/0bcf8c993906aedd23a59a2c73b88c169d90fe55)
- `peridot-contracts-2-5` commit
  [`592da09a5752774f8834a3f90d768e8d1344e539`](https://github.com/PeridotFinance/peridot-contracts-2-5/commit/592da09a5752774f8834a3f90d768e8d1344e539)

The Robinhood vault itself is not ERC-4626 and does not implement a withdrawal queue.
If the engagement is intended to cover only the Robinhood vault and boosted pUSDG
integration, the correct total is **2,449 Solidity nSLOC**; in that case, references to
ERC-4626 accounting and withdrawal-queue handling should be removed from the submitted
scope. The Robinhood-only review should instead cover side-specific deposit/withdrawal
accounting, pToken exchange-rate and loss-aware redemption accounting, Uniswap v4
position lifecycle and settlement, reserve-backed impermanent-loss coverage, oracle and
pool-manipulation resistance, liquidity-shortfall handling, role separation, upgrades,
and emergency controls.

## Deployment

The Robinhood mainnet vault system was deployed unconfigured and independently verified
on 2026-07-27. The initial deployment record captures the system before pair
registration and confirms that the vault, reserve, and adapter held no NVDA or USDG.
Exact addresses, transactions, source commit, and ownership checks are in
[`deployments/robinhood-mainnet.vault-system.json`](./deployments/robinhood-mainnet.vault-system.json).

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
[`deployments/robinhood-mainnet.adapter-empty-position-upgrade.json`](./deployments/robinhood-mainnet.adapter-empty-position-upgrade.json),
with its detached digest in
[`deployments/robinhood-mainnet.adapter-empty-position-upgrade.sha256`](./deployments/robinhood-mainnet.adapter-empty-position-upgrade.sha256).

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
[`deployments/robinhood-mainnet.vault-shared-loss-upgrade.json`](./deployments/robinhood-mainnet.vault-shared-loss-upgrade.json)
and its detached digest is in
[`deployments/robinhood-mainnet.vault-shared-loss-upgrade.sha256`](./deployments/robinhood-mainnet.vault-shared-loss-upgrade.sha256).
The exact capped post-upgrade canary amounts plus the independent enable and recovery-pause
timelock operations are recorded in
[`deployments/robinhood-mainnet.post-upgrade-canary.operations.json`](./deployments/robinhood-mainnet.post-upgrade-canary.operations.json),
with its detached digest in
[`deployments/robinhood-mainnet.post-upgrade-canary.operations.sha256`](./deployments/robinhood-mainnet.post-upgrade-canary.operations.sha256).

A third review pass addressed pool-price dependence and the exit availability window, and
is **written and scanned but not yet deployed**. Three changes ship together as one upgrade
because each needs vault bytecode and the vault had 217 bytes of EIP-170 headroom:

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
`5e251cec-ab33-40e6-b756-5b1b8822050a` with zero active findings. The upgrade requires
three new implementations plus the library and has not been scheduled; the post-upgrade
canary, which still has never exercised guardian emergency removal, remains outstanding.

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
   [`deployments/robinhood-mainnet.nvda.template.json`](./deployments/robinhood-mainnet.nvda.template.json).
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
[`deployments/robinhood-mainnet.nvda.canary.json`](./deployments/robinhood-mainnet.nvda.canary.json),
[`deployments/robinhood-mainnet.nvda.canary.preflight.json`](./deployments/robinhood-mainnet.nvda.canary.preflight.json),
[`deployments/robinhood-mainnet.nvda.canary.operations.json`](./deployments/robinhood-mainnet.nvda.canary.operations.json),
and
[`deployments/robinhood-mainnet.nvda.canary.execution.json`](./deployments/robinhood-mainnet.nvda.canary.execution.json).
The separately reviewed operation that enables only canary allocation while retaining
the settlement-swap pause is in
[`deployments/robinhood-mainnet.nvda.canary.enable-allocation.json`](./deployments/robinhood-mainnet.nvda.canary.enable-allocation.json).
The generic template intentionally retains unresolved placeholders and must not be used
as an executable manifest.

## Boosted pUSDG integration

The pToken integration should read only `accountedAssets(pairId, token)` in exchange-rate
accounting, use `liquidAssets` as the in-vault idle amount, and validate itself through
`sideAccount(pairId, token)`. Idle is only unconditionally withdrawable when no LP
liquidity remains; active LP exposure makes the withdrawal oracle- and pool-guarded. A
withdrawal must apply
`(returned, realizedLoss)` atomically before completing a borrow or redemption. The
generic sibling `IBoostedYieldAdapter` cannot communicate that loss and must not be wired
directly to this vault. The dedicated `RobinhoodBoostedDelegate` in
`../peridot-contracts-2-5/contracts` calls the vault from the pUSDG delegator address,
uses the complete claim for exchange-rate accounting, uses only idle vault assets for
cash checks, and settles realized loss before completing a redemption.

This code has not been independently audited. No production allocation should be
accepted until both the adapter and vault remediations are upgraded and verified on-chain,
a post-upgrade canary including guardian emergency removal is completed and drained, the
pair is re-paused after testing, and the external security review is complete.
