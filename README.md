# Robinhood Boosted Vaults

Paired Stock/USDG liquidity vaults for Robinhood Chain (chain ID `4663`). Matched USD
value from a stock-side account and a USDG-side account is deployed into a single
full-range Uniswap v4 position, and each side's principal is returned in its **native**
token.

This is **not** ERC-4626. There are no transferable shares, no withdrawal queue, and no
public deposit function — deposits are accepted only from the two configured side accounts,
which in production are Peridot pToken markets.

> **This code has not been independently audited, and no production allocation should be
> accepted until the external security review is complete.** The upgrade authority is a
> timelock that is currently controlled by a single EOA; see [Trust model](#trust-model).

## How it works

The first deployment target is NVDA/USDG. Contracts are generic, but every pair stays
disabled until its token, pool, and oracle configuration passes the deployment preflight.

A two-sided LP position cannot guarantee both native principals by accounting alone. As the
stock price moves, Uniswap changes the position's token composition, so on withdrawal the
system must unwind liquidity and, when the oracle guard is healthy, perform a bounded swap
to restore the requested asset. The resulting shortfall is absorbed in this order:

**LP fees → `StrategyLossReserve` → pro-rata across both sides.**

Anything that reaches the third step reduces *both* sides' principals by the same
percentage. **A USDG depositor therefore carries a share of NVDA divergence loss.** That is
the central economic fact about this system and it is deliberate, not incidental. The
product claim is that LP fees provide a second yield source when borrow utilization is low
— never a fixed APY, a guaranteed APY, or elimination of impermanent loss.

## Contracts

- **`RobinhoodBoostedVault`** — the only accounting authority. Holds per-pair configuration
  and ledger state plus custody of all tokens.
- **`UniswapV4PairedAdapter`** — the only component allowed to encode PositionManager or
  Universal Router operations. One zero-hook `PoolKey` and one full-range position NFT per
  pair. Permit2 allowances are granted for the exact amount of each operation and revoked
  before returning.
- **`StockOracleGuard`** — normalizes Chainlink prices, checks the stock token's
  `oraclePaused`, checks any configured sequencer feed, and bounds pool/oracle deviation.
- **`StrategyLossReserve`** — per-pair in-kind fee reserve with per-event, rolling daily,
  and coverage-ratio limits.
- **`SettlementLib`** — the withdrawal deficit waterfall, a linked library reached by
  `DELEGATECALL`. It exists to keep the vault under EIP-170, and the vault cannot be
  deployed without linking it.

All four stateful contracts are initializer-based and sit behind transparent proxies whose
`ProxyAdmin` is owned by an OpenZeppelin `TimelockController`.

### Two deviation bounds, two valuations

Pool deviation is bounded asymmetrically. `maxPriceDeviationBps` gates *allocation*, where
refusing to add liquidity costs nothing. The wider `maxRemovalDeviationBps` gates *exits*,
because value on removal is protected by oracle-anchored amount floors rather than by that
check, and a pool deviation `d` moves a full-range position's amounts by only about `d/2`.
Applying the allocation bound to exits would block withdrawals far tighter than value
protection requires, exactly when holders most need to leave.

Similarly, `totalPairAssets` prices the position at the pool's live price and is the market
view, while everything that recognizes loss prices it at the oracle-derived reference price.
Pushing the pool inside the deviation bound therefore cannot manufacture or mask a
shortfall.

## Availability, and when withdrawals fail closed

LP-backed withdrawals and guardian removals fail closed unless the Chainlink price is fresh,
the stock token oracle is unpaused, any configured sequencer feed is healthy, and the pool
is within the configured removal deviation.

This matters more than it may appear. The RHNVDA/USD feed is deviation-triggered at 0.5%
with no off-hours heartbeat. Over its first nine weeks it was stale beyond the configured
12-hour bound for **25.9% of wall-clock time**, with ~52-hour gaps in ten of ten weekends
and a 76-hour gap over the July 4 holiday. Any pair holding open LP liquidity through those
windows cannot service an LP-backed exit.

Withdrawals from pairs with **no open LP liquidity** remain available throughout, because
that path needs no oracle. Idle tokens held alongside an open position are still
economically LP-exposed and therefore require the same validated accounting before either
side's claim can decrease.

Integrators must read `withdrawableAssets` — not `liquidAssets` — for cash and utilization.
`liquidAssets` reports custody and overstates what is reachable while liquidity is open.

The current PoolManager exposes no native observation/TWAP surface for this zero-hook pool,
so deployment operations must use private order flow and monitor the pool and oracle
continuously. Settlement swaps enforce an oracle-derived execution-price floor and a bounded
size, but public submission retains residual sandwich risk inside the configured tolerance.

## Trust model

- **Configuration and proxy ownership belong to the timelock.** Configuration cannot be
  applied directly by an EOA in production; scripts print calldata payloads instead.
- **Keepers** can rebalance, collect fees, checkpoint, and burn empty positions.
- **Guardians** are one-way only: they can move the system toward paused/emergency, never
  unpause, and cannot bypass oracle or pool validation.
- **Upgrade authority is an intentional governance trust boundary.** The timelock must be
  controlled by the approved multisig policy, and upgrade/ownership events must be
  monitored. At the time of writing the timelock's proposer, canceller, and executor are a
  single EOA with a one-hour delay; migrating those roles to the multisig is a prerequisite
  for accepting material TVL.

## Development

Install the exact revisions in [`dependencies.lock.json`](./dependencies.lock.json), then:

```bash
forge build
forge build --sizes   # the vault is the EIP-170 constraint; check before and after changes
forge test
forge fmt --check
```

The vault links `SettlementLib`. `forge test` and `forge script` deploy and link it
automatically; a manual deployment must deploy the library first and pass
`--libraries src/libraries/SettlementLib.sol:SettlementLib:<address>`.

Set `ROBINHOOD_RPC_URL` to run the opt-in fork suite, which is skipped when unset:

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path 'test/fork/*'
```

That public endpoint serves archive state at the pinned block and is sufficient for the
suite, though it is rate limited and filters by `User-Agent`. The fork test is pinned to
Robinhood block `17091638` and verifies canonical bytecode, token/feed metadata,
PoolManager versus StateView, NVDA's PoolKey/PoolId, the oracle guard, Permit2 approvals,
the complete position NFT lifecycle, swaps in both directions, and an end-to-end
rebalance/checkpoint/withdrawal sequence.

## Deployed addresses and change history

Deployed addresses, upgrade history, canary status, and the verification evidence behind
each on-chain action live in [`deployments/`](./deployments/README.md). Every mainnet action
has a JSON record and a detached SHA-256 digest.

## Security review scope

The Robinhood vault is not ERC-4626 and does not implement a withdrawal queue. A review
scoped to this system plus the boosted pUSDG integration covers **2,449 Solidity nSLOC**:

| Component | Solidity nSLOC |
| --- | ---: |
| Robinhood vault, v4 adapter, loss reserve, oracle, local interfaces, and math | 2,045 |
| Robinhood boosted pUSDG delegate and vault interface | 370 |
| Robinhood proxy and access-control helpers | 34 |

The count excludes blank lines, comment-only lines, tests, deployment scripts, generated
artifacts, and vendored OpenZeppelin/Uniswap code. Counted together with the separate
ERC-4626 V3 LP-vault subsystem in `peridot-contracts-2-5`, the combined scope is 3,823
nSLOC; if the engagement is intended to cover only the Robinhood system, references to
ERC-4626 accounting and withdrawal-queue handling should be removed from the submitted
scope.

A Robinhood-scoped review should cover side-specific deposit/withdrawal accounting, pToken
exchange-rate and loss-aware redemption accounting, Uniswap v4 position lifecycle and
settlement, reserve-backed impermanent-loss coverage, oracle and pool-manipulation
resistance, liquidity-shortfall handling, role separation, upgrades, and emergency controls.

Reproducible source snapshots. These are the commits whose bytecode matches what is live on
mainnet — review these, not the earlier snapshots quoted in older drafts, which predate the
oracle-priced-loss upgrade:

- `LP_VaultsUniswap` commit
  [`b96914e0ff562bbaf64ca94acfbd4eef0643bcdb`](https://github.com/joshschcom/LP_VaultsUniswap/commit/b96914e0ff562bbaf64ca94acfbd4eef0643bcdb)
  — the last change to `src/` before the deployed implementations were built. Reproducing the
  vault requires linking `SettlementLib` at
  `0x813AbFeC0DE50f8674798CbaB72Ed7b5D8CcB9cB`; see
  [`deployments/README.md`](./deployments/README.md) for the runtime code hashes.
- `peridot-contracts-2-5` commit
  [`895dc6f0c101597277c571d43f040ca6f11bfd6e`](https://github.com/PeridotFinance/peridot-contracts-2-5/commit/895dc6f0c101597277c571d43f040ca6f11bfd6e)
  — the boosted pUSDG delegate reading `withdrawableAssets` for cash accounting.

Findings from the post-upgrade canary that a reviewer should weigh are recorded in
[`deployments/robinhood-mainnet.post-upgrade-canary.execution.json`](./deployments/robinhood-mainnet.post-upgrade-canary.execution.json),
in particular the checkpoint branch gap: when gross value is at or above benchmark but one
side sits below its principal, neither the loss nor the gain branch fires, and the shorted
side cannot be drained in its native token without a settlement swap.

## Boosted pUSDG integration

An integrating pToken should read `accountedAssets(pairId, token)` for exchange-rate
accounting, use `withdrawableAssets` as the in-vault cash figure, and validate itself
through `sideAccount(pairId, token)`. Idle is only unconditionally withdrawable when no LP
liquidity remains; active LP exposure makes the withdrawal oracle- and pool-guarded.

A withdrawal must apply `(returned, realizedLoss)` atomically before completing a borrow or
redemption. The generic sibling `IBoostedYieldAdapter` cannot communicate that loss and must
not be wired directly to this vault. The dedicated `RobinhoodBoostedDelegate` in
`peridot-contracts-2-5` calls the vault from the pUSDG delegator address, uses the complete
claim for exchange-rate accounting, uses only reachable vault assets for cash checks, and
settles realized loss before completing a redemption.
