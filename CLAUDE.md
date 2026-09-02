# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Foundry (Solidity 0.8.26, `via_ir`, cancun) contracts for **paired Stock/USDG liquidity
vaults on Robinhood Chain** (chain ID `4663`). The system deploys matched USD value from a
stock-side account and a USDG-side account into a single full-range Uniswap v4 position,
and returns each side's principal in its **native** token. There are no transferable
shares and it is not ERC-4626.

`README.md` is the authoritative operational record (deployed addresses, upgrade history,
canary status, security-review scope). Read it before touching deployment or governance
flows — it is kept in sync with the JSON records in `deployments/`.

## Commands

```bash
forge build
forge build --sizes            # vault is the EIP-170 constraint; check before/after changes
forge fmt                      # or --check
forge test
forge test --match-path test/RobinhoodBoostedVault.t.sol
forge test --match-test testIdleWithdrawalRecognizesSharedLossWhileLiquidityRemains -vvv
forge test --match-path 'test/fork/*'     # requires ROBINHOOD_RPC_URL
```

`ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com` works for the fork suite: the
public endpoint serves archive state at the pinned block. It is rate limited and rejects
requests without a browser/curl `User-Agent`.

`lib/` and `docs/` are gitignored. Dependencies are pinned by exact revision in
`dependencies.lock.json` — install those revisions, do not bump them casually; the fork
tests and the adapter's router encoding depend on the pinned Uniswap versions.

The fork suite (`test/fork/RobinhoodNVDAFork.t.sol`) self-skips when `ROBINHOOD_RPC_URL`
is unset and is pinned to block `17_091_638`. It is the only coverage for real
PositionManager/UniversalRouter/Permit2 encoding, so run it for any adapter change.

## Architecture

Four upgradeable contracts plus one linked library, each initializer-based and deployed
behind `PeridotTransparentProxy` whose `ProxyAdmin` is owned by an OpenZeppelin
`TimelockController`. Everything is keyed by `pairId = keccak256(PAIR_LABEL)`
(e.g. `NVDA/USDG/CANARY`, `NVDA/USDG`).

- **`RobinhoodBoostedVault`** — the only stateful accounting authority. Holds
  `PairConfig` (risk/pause/caps) and `PairLedger` (`stockPrincipal`, `usdgPrincipal`,
  `stockIdle`, `usdgIdle`, `cumulativeLossUSDG`, `lastCheckpoint`) plus custody of all
  tokens. Deposits only from the configured `stockAccount`/`usdgAccount`.
- **`UniswapV4PairedAdapter`** — the *only* component allowed to encode PositionManager
  or Universal Router calls. `onlyVault`. One zero-hook `PoolKey` and one full-range
  position NFT per pair. Permit2 allowances are granted for the exact amount of each
  operation and revoked before returning.
- **`StockOracleGuard`** — normalizes Chainlink prices to USD 1e18, checks the stock
  token's `oraclePaused`, checks any configured sequencer feed + grace period, and
  rejects pool/oracle deviation beyond the bound for the operation (see below). Returns
  the oracle-derived `referenceSqrtPriceX96` used both as the removal slippage reference
  and as the price at which loss accounting values the position.
- **`StrategyLossReserve`** — per-pair in-kind fee reserve with per-event, rolling
  UTC-daily, and coverage-ratio (`maxCoverageBps` of the realized deficit) limits.
- **`SettlementLib`** — the withdrawal deficit waterfall (reserve cover, then the bounded
  oracle-floored settlement swap). A **linked library** reached by `DELEGATECALL`, so
  storage and `address(this)` are the vault's. It exists purely to keep the vault under
  EIP-170. The vault cannot be deployed without it: `forge test`/`forge script` link it
  automatically, a manual deploy needs
  `--libraries src/libraries/SettlementLib.sol:SettlementLib:<address>`.

`VaultMath` does all decimal scaling / USD valuation / tick quoting. `VaultTypes` declares
`PairConfig` and `PairLedger` at file scope so the vault and `SettlementLib` can share
storage pointers — that file *is* the proxy storage layout, so append only.

### Two position valuations, deliberately different

`totalPairAssets` prices the position at the pool's live `sqrtPriceX96` (market view).
Everything that recognizes loss prices it at the oracle-derived `referenceSqrtPriceX96`
through `UniswapV4PairedAdapter.positionStateAt`, so pushing the pool inside the deviation
bound cannot manufacture or mask a shortfall. Do not "simplify" a loss path back onto
`totalPairAssets`.

Likewise the deviation bound is asymmetric: `maxPriceDeviationBps` gates allocation
(`registerPair`, `rebalance`), the wider `maxRemovalDeviationBps` gates every exit
(checkpoint, withdraw, unwind, `emergencyDecrease`, settlement swap, and the
`withdrawableAssets` probe). Value on removal is protected by the adapter's oracle-anchored
amount floors, not by this gate. Zero means "fall back to the allocation bound".

### Accounting model — the part that matters

A two-sided LP cannot guarantee both native principals by accounting alone, so:

1. `checkpoint` validates the oracle and pool, collects fees (a `reserveFeeBps` cut goes
   to the reserve), then compares gross pair value against the benchmark. A shortfall
   scales **both** principals down pro-rata and accrues `cumulativeLossUSDG`.
2. `withdrawForSide` unwinds LP liquidity for the shortfall (over-unwinding by
   `withdrawOverUnwindBps`), then settles remaining deficit from the reserve and, if
   swaps are enabled, a bounded oracle-floored settlement swap. It returns
   `(returned, realizedLoss)` so an integrating pToken can apply both atomically.
3. `withdrawableAssets` reports what a side can actually receive this block; `liquidAssets`
   reports custody and overstates access while liquidity is open. Integrating pTokens must
   use the former for cash and utilization, or borrows and redeems pass the controller's
   cash check and then revert on transfer out.
4. **Idle assets are still LP-exposed while any liquidity is open.** Any principal
   reduction while `positionState().liquidity != 0` must go through the full
   oracle-guarded settle path — this is what prevents one side from exiting ahead of an
   uncheckpointed shared loss. Only pairs with zero open liquidity keep the
   oracle-free idle withdrawal path. Do not "optimize" this branch away.
5. `emergencyDecrease` (guardian) recognizes loss atomically with the exit and blocks
   `withdrawForSide` until the LP is fully removed after a partial decrease.

Loss waterfall: LP fees → `StrategyLossReserve` → pro-rata across both sides.

### Roles and trust boundaries

- `CONFIG_ROLE` / proxy admin ownership → **timelock only**. Configuration cannot be
  applied directly by an EOA in production; scripts print calldata payloads instead.
- `KEEPER_ROLE` → `rebalance`, `collectFees`, `checkpoint`, `burnEmptyPosition`.
- `GUARDIAN_ROLE` → one-way only: can move toward paused/emergency, never unpause
  (`GuardianCannotUnpause`), and cannot bypass oracle/pool validation.

## Deployment and operations scripts

All mutating scripts hard-require `block.chainid == 4663`, take the broadcaster as an
explicit public address env var (`DEPLOYER`, `ACTION_ACTOR`, `GOVERNANCE_ACTOR`) and
bind broadcasts to it. **No plaintext private-key env vars** — use `--account` with an
encrypted keystore or a hardware wallet. Simulate first; `--broadcast` only for a
reviewed execution.

- `DeployVaultTimelock.s.sol` — self-administered `TimelockController`, min delay ≥ 1h.
- `PreflightRobinhood.s.sol` — pinned-fork validation of code, token/feed metadata,
  price plausibility, PoolId, PoolManager vs StateView agreement, and detached SHA-256
  digests of the registry snapshot and manifest.
- `DeployVaultSystem.s.sol` — deploys 4 implementations then 4 proxies in one broadcast,
  precomputing proxy addresses from the deployer nonce so the circular references can be
  encoded into each initializer. Never leaves an uninitialized proxy. Asserts the
  predicted addresses and ProxyAdmin ownership afterwards.
- `ConfigureNvdaPair.s.sol` — prints four ordered timelock payloads by default;
  `DIRECT_CONFIG_BROADCAST=true` is for local/test use only. Only the canary and
  production pair labels are accepted, and each has different rollout assertions.
- `OperateVaultTimelock.s.sol` — `TIMELOCK_ACTION` of `status`/`schedule`/`execute`/
  `cancel` for one operation. `TIMELOCK_SALT` is mandatory so every reviewed operation
  has a unique id.
- `RunNvdaCanary.s.sol` — one explicit `CANARY_ACTION` per invocation, each bounded by a
  `CANARY_MAX_*` env limit and each requiring the specific authorized signer.
  `PAYLOAD_ONLY=true` prints calldata for timelock-owned actions instead of broadcasting.

Every mainnet action is recorded as `deployments/<name>.json` with a detached
`<name>.sha256`. When you add or change one of these records, regenerate the digest
(`shasum -a 256 <file>.json`) and update the corresponding `README.md` section.

## Conventions

- Named-brace imports; custom errors (no revert strings) in `src/`; `require` with short
  SCREAMING_SNAKE messages in `script/`.
- Every external token movement is verified against an observed balance delta
  (`_requireBalanceIncrease` / `_requireBalanceDecrease` / `_pushExact`), which is what
  makes fee-on-transfer tokens revert instead of corrupting the ledger. Keep this
  pattern when adding transfers.
- The contracts are live behind proxies: **preserve storage layout**. `PairConfig` (in
  `VaultTypes.sol`) contains `deprecatedMinDeadlineDelay`, retained only as a layout
  placeholder and required to stay zero. Append new fields, never reorder, and verify with
  `forge inspect <contract> storageLayout` before and after — AST node ids shift between
  builds, so compare slots/offsets/labels, not raw type strings.
- Tests live one file per contract, with `test/fork/` (pinned mainnet) and
  `test/invariant/` (handler-driven) separate. Mocks in `test/mocks/`.
- Changes to `src/` are expected to ship with: full unit suite, the pinned fork suite,
  `forge fmt --check`, `forge build --sizes`, and a security scan — see `README.md` for
  how prior remediations were recorded.
