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
forge test
```

Set `ROBINHOOD_RPC_URL` to run the opt-in fork suite:

```bash
forge test --match-path 'test/fork/*'
```

The fork test is skipped when `ROBINHOOD_RPC_URL` is unset. It is pinned to Robinhood
block `17091638` and verifies canonical bytecode, token/feed metadata, PoolManager versus
StateView, NVDA's PoolKey/PoolId, the oracle guard, Permit2 approvals, the complete
position NFT lifecycle, swaps in both directions, and an end-to-end vault
rebalance/checkpoint/withdrawal sequence.

## Contracts

- `RobinhoodBoostedVault` owns pair accounting and token custody. Deposits and claims
  remain native to either the stock side or USDG side; there are no transferable shares.
- `UniswapV4PairedAdapter` is the only component allowed to encode PositionManager or
  Universal Router operations. Each registered pair is bound to one zero-hook PoolKey.
- `StockOracleGuard` normalizes Chainlink prices, checks Robinhood's `oraclePaused`, and
  validates pool/oracle deviation before allocation or settlement.
- `StrategyLossReserve` holds pair-specific in-kind fee reserves and enforces per-event,
  coverage-ratio, and rolling daily limits.

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
`peridot-contracts-2-5`. Counted together, that scope contains **3,820 Solidity nSLOC**:

| Component | Solidity nSLOC |
| --- | ---: |
| Robinhood vault, v4 adapter, loss reserve, oracle, local interfaces, and math | 2,042 |
| Robinhood boosted pUSDG delegate and vault interface | 370 |
| Robinhood proxy and access-control helpers | 34 |
| ERC-4626 V3 LP vault, oracle, local interfaces, and math | 1,374 |
| **Combined scope as worded** | **3,820** |

The count excludes blank lines, comment-only lines, tests, deployment scripts, generated
artifacts, vendored OpenZeppelin/Uniswap code, and the explicitly out-of-scope Peridot
lending core. The corresponding raw physical total is 4,502 lines. The reproducible
source snapshots are:

- `LP_VaultsUniswap` commit
  [`c0a75d2bd18841b7995bd163dad032331511caf4`](https://github.com/joshschcom/LP_VaultsUniswap/commit/c0a75d2bd18841b7995bd163dad032331511caf4)
- `peridot-contracts-2-5` commit
  [`592da09a5752774f8834a3f90d768e8d1344e539`](https://github.com/PeridotFinance/peridot-contracts-2-5/commit/592da09a5752774f8834a3f90d768e8d1344e539)

The Robinhood vault itself is not ERC-4626 and does not implement a withdrawal queue.
If the engagement is intended to cover only the Robinhood vault and boosted pUSDG
integration, the correct total is **2,446 Solidity nSLOC**; in that case, references to
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
Almanax scan `403fead9-54d2-4cea-b47c-1b79b03f0836` with zero findings. This README does
not treat that remediation as deployed until the replacement adapter implementation and
timelocked proxy upgrade have been separately verified on-chain. The verified replacement
deployment and exact pending timelock operation are recorded in
[`deployments/robinhood-mainnet.adapter-empty-position-upgrade.json`](./deployments/robinhood-mainnet.adapter-empty-position-upgrade.json),
with its detached digest in
[`deployments/robinhood-mainnet.adapter-empty-position-upgrade.sha256`](./deployments/robinhood-mainnet.adapter-empty-position-upgrade.sha256).

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
past its grace period, and the zero-hook pool remains within the configured deviation.
Guardian emergency mode cannot bypass these checks. The current PoolManager exposes no
native observation/TWAP surface for this zero-hook pool, so deployment operations must
use private order flow and monitor the pool and oracle continuously; see the
[Uniswap v4 core architecture](https://github.com/Uniswap/v4-core). Settlement swaps
also enforce an oracle-derived per-hop execution-price floor and a bounded size, but
public submission retains residual sandwich risk inside the configured tolerance.
Idle-only withdrawals remain available during oracle or pool incidents.

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
accounting, use `liquidAssets` as its conservative immediately available amount, and
validate itself through `sideAccount(pairId, token)`. A withdrawal must apply
`(returned, realizedLoss)` atomically before completing a borrow or redemption. The
generic sibling `IBoostedYieldAdapter` cannot communicate that loss and must not be wired
directly to this vault. The dedicated `RobinhoodBoostedDelegate` in
`../peridot-contracts-2-5/contracts` calls the vault from the pUSDG delegator address,
uses the complete claim for exchange-rate accounting, uses only idle vault assets for
cash checks, and settles realized loss before completing a redemption.

This code has not been independently audited. No production allocation should be
accepted until the adapter remediation is upgraded and verified on-chain, a post-upgrade
canary including guardian emergency removal is completed and drained, the pair is
re-paused after testing, and the external security review is complete.
