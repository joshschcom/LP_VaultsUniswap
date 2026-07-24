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

## Deployment

1. Copy and verify
   [`deployments/robinhood-mainnet.nvda.template.json`](./deployments/robinhood-mainnet.nvda.template.json).
2. Run `PreflightRobinhood.s.sol` against a pinned Robinhood fork. Supply the detached
   registry-snapshot and manifest SHA-256 digests. It fails on missing code or hashes,
   token/oracle mismatch, stale or implausible prices, missing sequencer policy, a wrong
   PoolId, an uninitialized pool, or disagreement between PoolManager and StateView.
3. Deploy the implementations and proxies with `DeployVaultSystem.s.sol`.
4. For the standalone mainnet canary, run `ConfigureNvdaPair.s.sol` with
   `PAIR_LABEL=NVDA/USDG/CANARY`, temporary EOA side accounts, and deliberately small
   nonzero pair and aggregate caps. The pair is registered with allocation and swaps
   paused. The script prints four ordered timelock payloads by default; direct EOA
   execution is disabled unless `DIRECT_CONFIG_BROADCAST=true` is explicitly set.
5. Use `RunNvdaCanary.s.sol` one action at a time: inspect `status`, enable allocation,
   deposit each side within explicit `CANARY_MAX_*_AMOUNT` limits, optionally fund each
   reserve side within separate `CANARY_MAX_RESERVE_*_AMOUNT` limits, rebalance,
   checkpoint, withdraw both sides, optionally burn the empty position NFT, pause and
   withdraw the canary reserve, verify `assert-drained`, and finally pause the vault pair.
   Use the governance, keeper, stock-side, USDG-side, reserve-admin, or funder key only
   for the action authorized to that address. Enable settlement swaps only as a separate,
   deliberate canary action. Set `PAYLOAD_ONLY=true` for vault/reserve governance actions
   owned by the timelock.
6. Seed the reserve with at most $100 of combined in-kind value during the smoke test.
   Keep the canary drained and paused after the test.
7. After the Peridot market contracts are ready, deploy the boosted pUSDG delegator,
   register the distinct `PAIR_LABEL=NVDA/USDG` production pair with that delegator as
   `USDG_SIDE_ACCOUNT`, configure the pToken while it remains paused, unpause vault
   allocation through governance, and only then enable the pToken's vault integration.
8. Stage production allocation through the configured side accounts.
   Permit2 allowances are created for the exact amount of each liquidity or swap
   operation and revoked before it returns. Initial reserve defaults allow at most $10
   per event, $25 per UTC day, and 50% of a realized deficit.

LP-backed withdrawals and guardian removals fail closed unless the Chainlink price is
fresh and the zero-hook pool remains within the configured deviation. The current
PoolManager exposes no native observation/TWAP surface for this zero-hook pool, so
deployment operations must use private order flow and monitor the pool and oracle
continuously; see the [Uniswap v4 core architecture](https://github.com/Uniswap/v4-core).
Idle-only withdrawals remain available during oracle or pool incidents.

The standard NVDA feed, Robinhood registry snapshot, and reviewed sequencer waiver are
recorded. The template still leaves price bounds, feed staleness, settlement-swap size,
and the final manifest hash unresolved; those are governance inputs and must not be
inferred from this repository.

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

This code has not been independently audited and must remain paused for new allocation
until Robinhood fork tests and an external security review are complete.
