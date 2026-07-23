# Engineering handoff: boosted Stock/USDG markets on Robinhood Chain

**Audience:** coding LLM / Solidity engineer adapting an existing Compound-v2-style market and the existing stable-pair boosted-market implementation
**Network:** Robinhood Chain mainnet, chain ID `4663`
**Research checkpoint:** 2026-07-22
**Status:** implementation specification, not audited production code

### 2026-07-23 implementation decision

The standalone vault restricts deposits to the configured stock-side and USDG-side
accounts. Its pair-value and aggregate USDG caps are therefore optional governance
circuit breakers rather than mandatory capacity limits: `0` disables a cap and any
nonzero value enables it. Capacity is controlled by the side-account integrations and
the paused allocation rollout.

The initial loss reserve will receive no more than $100 of governance-funded, combined
in-kind value. Initial limits are $10 per event, $25 per UTC day, and 50% of a realized
deficit. Twenty percent of collected LP fees replenish the reserve. Governance must
review the absolute reserve-use limits as fee funding grows.

## 0. Executive implementation brief

Build the stock version as an adapter around the existing boosted-market core. Do not fork or redesign the Comptroller, interest-rate model, liquidation path, or normal pToken user interface.

For each supported Robinhood stock token, pair its boosted market with the existing pUSDG market. Idle underlying from both markets is contributed, in matched USD value, to the **existing canonical Uniswap v4 Stock/USDG pool**. The market keeps a utilization-dependent cash buffer; the remainder can be routed to the paired strategy. Borrow and redeem continue to return the market's native underlying.

The essential design constraint is that a two-sided LP cannot guarantee both native principals by accounting alone. As the stock price moves, Uniswap changes the position's token composition. On withdrawal, the strategy must unwind liquidity, use the resulting counter-asset, and—only when an oracle guard is healthy—perform a bounded swap to restore the requested native asset. LP fees are the first loss absorber, a separate fee-funded reserve is second, and only an uncovered residual loss reaches the two supplier markets. **pUSDG must not be an undocumented junior/insurance tranche.**

The MVP should use:

- existing Uniswap v4 pools, not new pools or hooks;
- one full-range position NFT per Stock/USDG pair;
- no swap when adding liquidity;
- keeper-batched rebalances and harvests;
- cached, conservative strategy accounting in each pToken;
- Chainlink tokenized-equity feeds for accounting/risk, never Uniswap spot alone;
- a reserve-first loss waterfall, without Saffron-style senior/junior user tranches;
- optional circuit-breaker caps and a staged canary rollout.

The product statement is: **LP fees provide a second yield source when borrow utilization is low.** Do not describe this as fixed APY, guaranteed APY, or elimination of impermanent loss.

---

## 1. Repository adaptation pass — do this before writing contracts

The repository was not supplied with this handoff, so names below are intentionally descriptive. Replace every `ADAPT_TO_REPO` marker with the closest existing abstraction.

First inspect the current stable-pair boosted implementation and record:

1. The pToken contract that owns or delegates idle-underlying strategy logic.
2. The existing strategy interface and whether strategy assets are cached or queried live.
3. The exact exchange-rate formula and where external strategy assets are included.
4. The cash-buffer/utilization calculation already used for stable pairs.
5. The hooks invoked after mint, redeem, borrow, repay, liquidation, and reserve operations.
6. Keeper, guardian, timelock, and admin roles.
7. Reentrancy boundaries and whether pTokens use delegatecall, inheritance, or external adapters.
8. Upgrade pattern and storage-gap rules.
9. Existing events, custom errors, pause flags, caps, and deployment scripts.
10. Existing fork-test setup and Robinhood Chain RPC configuration.

Recommended search terms:

```text
Boosted Strategy strategyAssets totalManagedAssets totalAssets
getCashPrior exchangeRateStoredInternal accrueInterest
rebalance harvest ensureLiquidity withdrawToMarket
liquidityBuffer targetCash utilization keeper guardian
```

Reuse the stable-pair implementation for roles, upgrades, pToken hooks, cash accounting, and deployment style. Add only the paired coordinator, Uniswap v4 adapter, oracle guard, and loss reserve required for a volatile Stock/USDG pair.

---

## 2. Non-negotiable accounting invariants

These invariants should be written as Foundry invariant tests before the implementation is considered complete.

### 2.1 Market accounting

For each pToken market `m`:

```text
managedAssets[m]
  = onHandUnderlying[m]
  + accountedStrategyAssets[m]
  + totalBorrows[m]
  - totalReserves[m]
```

Its exchange rate is:

```text
exchangeRate[m] = managedAssets[m] / pTokenSupply[m]
```

`accountedStrategyAssets` is a cached native-underlying amount updated by an atomic strategy checkpoint. It must not call Uniswap, Chainlink, or any arbitrary adapter from a view/exchange-rate path.

Rules:

- Positive strategy PnL is recognized only during a successful `checkpoint/harvest`.
- Realized or reliably measurable negative PnL is recognized immediately during that checkpoint or withdrawal.
- Strategy assets are counted exactly once: never in both pToken cash and strategy claims.
- Tokens held by the coordinator remain strategy assets until returned to the pToken.
- Loss-reserve assets are not pToken assets and must never inflate an exchange rate.
- `totalBorrows` and `totalReserves` keep the existing Compound-v2 semantics.

### 2.2 Paired strategy accounting

For each pair, maintain native-unit principal ledgers:

```solidity
struct PairLedger {
    uint256 stockPrincipal;       // stock token units supplied by pStock
    uint256 usdgPrincipal;        // USDG units supplied by pUSDG
    uint256 stockIdle;            // stock owned by strategy but not in LP
    uint256 usdgIdle;             // USDG owned by strategy but not in LP
    uint256 positionTokenId;      // Uniswap v4 PositionManager NFT
    uint128 positionLiquidity;
    uint64  lastCheckpoint;
}
```

At a checkpoint, obtain the conservative amount of each token represented by the LP position plus idle balances, value both using approved oracles, and compare them with the marked native principals:

```text
grossValueUSDG = stockAssets * stockOraclePrice + usdgAssets
benchmarkUSDG  = stockPrincipal * stockOraclePrice + usdgPrincipal
strategyPnL    = grossValueUSDG - benchmarkUSDG
```

The feed already represents the token's total-return value, including Robinhood's multiplier. **Do not multiply by `uiMultiplier()` again.**

When a position is fully or proportionally unwound, use the entire matched slice of LP proceeds to restore both native obligations. A counter-asset surplus is not automatically profit while the other native obligation is short. If a guarded swap is needed, execute it before calculating final PnL.

The loss waterfall is:

1. LP fees already present in the position / freshly collected fees.
2. Pair-specific in-kind reserve balances.
3. Capped USDG reserve coverage and a guarded swap if the missing asset is stock.
4. Uncovered loss shared pro rata by the marked USDG value of both sides.

This equal-seniority rule prevents pUSDG from silently underwriting stock suppliers. If the product later wants senior and junior tranches, implement that as an explicit second product with separate shares, disclosures, and caps—not as hidden pUSDG behavior.

### 2.3 Solvency and custody invariants

- A market can never report a strategy claim larger than its latest conservative accounted claim.
- `stockPrincipal` can only increase after the coordinator has actually received stock; same for USDG.
- Principal decreases only when assets are returned to the corresponding pToken or a loss is atomically recognized.
- One market can never withdraw the other market's native principal.
- Any cross-token conversion must be attributable to a matched LP unwind or explicit reserve coverage.
- The active Uniswap NFT cannot be transferred by a keeper or guardian.
- The allowed pool key is immutable or timelock-controlled and exactly matches its allowlisted pool ID.
- All balance deltas are measured with before/after balances; do not trust return values alone.

---

## 3. Utilization-dependent allocation

Keep the existing boosted-market behavior, but calculate it from total managed assets rather than on-hand cash alone.

For market `m`:

```text
A = onHandCash + accountedStrategyAssets + totalBorrows - totalReserves
B = totalBorrows
U = B / A
targetLiquidCash = max(minAbsoluteCash, A * liquidityBufferBps / 10_000)
targetStrategyAssets = min(strategyCap, max(0, A - B - targetLiquidCash))
```

With a 10% cash buffer and no other cap:

```text
targetStrategyAssets / A = max(0, 90% - utilization)
```

Examples:

| Utilization | Target liquid cash | Maximum strategy allocation |
|---:|---:|---:|
| 0% | 10% | 90% |
| 40% | 10% | 50% |
| 80% | 10% | 10% |
| 90%+ | 10% or all remaining cash | 0% |

Recommended launch values are more conservative:

- pStock liquidity buffer: `10%`;
- pUSDG liquidity buffer: `15%` because it services all stock pairs;
- aggregate pUSDG strategy cap: `30%` of pUSDG managed assets during canary;
- per-stock pair cap: `5–10%` of pUSDG managed assets;
- minimum rebalance deviation: configurable, initially `2%` of market assets or an absolute value threshold;
- no Uniswap transaction on every small deposit or repay.

The coordinator may deploy only the matched amount:

```text
stockDeployable = max(0, stockTargetStrategy - stockAlreadyAllocated)
usdgDeployable  = max(0, usdgTargetForPair - usdgAlreadyAllocated)

pairValueUSDG = min(
    stockDeployable * stockOraclePrice,
    usdgDeployable
)

stockToPair = pairValueUSDG / stockOraclePrice
usdgToPair  = pairValueUSDG
```

The actual full-range liquidity math determines exact token consumption. Any unconsumed amount remains idle and attributed to its original market.

---

## 4. Contract topology

### 4.1 `BoostedMarketStrategyAdapter` — one per pToken

This should conform to the existing boosted strategy interface (`ADAPT_TO_REPO`). Its responsibilities are deliberately narrow:

- accept/return only its market's underlying;
- expose cached accounted assets and immediately withdrawable assets;
- request pairing/unpairing from the coordinator;
- update the pToken's strategy-accounting hook atomically;
- enforce only-market and only-coordinator permissions.

Suggested interface if the repository has no equivalent:

```solidity
interface IBoostedMarketStrategy {
    function underlying() external view returns (address);
    function accountedAssets() external view returns (uint256);
    function liquidAssets() external view returns (uint256);
    function maxWithdraw() external view returns (uint256);

    function depositFromMarket(uint256 assets) external returns (uint256 received);
    function withdrawToMarket(uint256 assets, address receiver)
        external
        returns (uint256 returned, uint256 loss);

    function checkpoint() external returns (int256 pnl);
    function requestRebalance() external;
}
```

Do not promise that `maxWithdraw()` includes unverified insurance coverage. It should include only idle underlying plus a conservative, currently unwindable estimate.

### 4.2 `PairedLiquidityCoordinator`

One coordinator can manage several stock pairs, but each pair has isolated accounting, caps, pause state, NFT, and reserve ledger.

Responsibilities:

- register the pStock and pUSDG adapters for an allowlisted pair;
- pull matched underlying only after both adapters approve the rebalance;
- maintain `PairLedger` and per-side cached claims;
- mint/increase/decrease/collect/burn the v4 position;
- stage proceeds in pair-specific inventory;
- request bounded reserve coverage;
- perform only allowlisted, oracle-guarded Stock/USDG swaps;
- atomically report native-unit asset/loss changes to both adapters.

Suggested external surface:

```solidity
interface IPairedLiquidityCoordinator {
    function pairConfig(bytes32 pairId) external view returns (PairConfig memory);
    function ledger(bytes32 pairId) external view returns (PairLedger memory);

    function rebalance(bytes32 pairId, uint256 deadline) external;
    function checkpoint(bytes32 pairId, uint256 deadline) external returns (int256 pnlUSDG);
    function withdrawForMarket(
        bytes32 pairId,
        address underlying,
        uint256 requested,
        uint256 deadline
    ) external returns (uint256 returned, uint256 loss);
    function collectFees(bytes32 pairId, uint256 deadline)
        external
        returns (uint256 stockFees, uint256 usdgFees);
    function emergencyDecrease(bytes32 pairId, uint128 liquidity, uint256 deadline) external;
}
```

### 4.3 `UniswapV4PairedAdapter`

Keep raw Uniswap encoding out of the pTokens. The adapter:

- owns or is approved to manage the pair's position NFT;
- validates the exact `PoolKey` and derived `PoolId`;
- wraps `PositionManager.modifyLiquidities`;
- wraps guarded `UniversalRouter.execute` for the rare settlement swap;
- reads pool state using `StateLibrary` on `PoolManager`;
- measures balance deltas.

It must not accept arbitrary pool keys, arbitrary hooks, arbitrary router commands, or arbitrary calldata from a keeper.

### 4.4 `StrategyLossReserve`

The reserve is separate from pUSDG and all pToken exchange-rate accounting.

Maintain pair-specific stock and USDG balances. Initial funding is the reserve cut of collected LP fees plus any explicit governance seed. The reserve can transfer only to the coordinator, only for a recorded settlement deficit, and only up to:

- the pair's available reserve;
- a per-event cap;
- a rolling daily cap;
- optionally a maximum coverage ratio of realized loss.

Every coverage event emits the benchmark, pre-coverage deficit, amount covered, and post-coverage loss. An insurance promise cannot exceed assets actually held by this contract.

### 4.5 `StockOracleGuard`

Store feed addresses per stock under timelock. The guard must validate:

- `answer > 0`;
- `updatedAt != 0`;
- `answeredInRound >= roundId` where the selected interface still exposes it;
- session-aware staleness policy;
- `stockToken.oraclePaused() == false` for new risk;
- L2 sequencer health and grace period if Robinhood exposes an official sequencer feed;
- Uniswap spot versus Chainlink deviation below `maxPriceDeviationBps` for adds and swaps.

Do not hardcode an unverified sequencer or stock-feed address. Both are deployment configuration values and must pass the preflight checks in section 12.

---

## 5. pToken integration points

Adapt these steps to the existing stable boosted-market core.

### 5.1 Exchange rate

Add only the cached value:

```solidity
uint256 cashPlusStrategy = getCashPrior() + strategyAccountedAssets;
uint256 cashPlusBorrowsMinusReserves =
    cashPlusStrategy + totalBorrows - totalReserves;
exchangeRate = cashPlusBorrowsMinusReserves * expScale / totalSupply;
```

Never make `exchangeRateStoredInternal`, `accrueInterest`, or a view method call Uniswap/Chainlink. A manipulable or reverting external read in this path can freeze the market or corrupt mint/redeem math.

### 5.2 Cash assurance

Before a redeem or borrow transfers underlying:

```solidity
function _ensureCash(uint256 required) internal {
    uint256 cash = getCashPrior();
    if (cash >= required) return;

    (uint256 returned, uint256 loss) =
        strategy.withdrawToMarket(required - cash, address(this));

    _applyStrategyWithdrawal(returned, loss); // ADAPT_TO_REPO
    if (getCashPrior() < required) revert InsufficientStrategyLiquidity();
}
```

Do not swallow a material loss and then transfer at the old exchange rate. The withdrawal and loss-accounting update must be atomic before final redemption math.

### 5.3 Operation hooks

- `mint`, `repayBorrow`, liquidation repayment: accrue normally; leave funds on-hand; optionally emit a rebalance request. Do not force an LP action.
- `redeem`, `borrow`: call `_ensureCash` when cash is insufficient.
- keeper `rebalance`: move funds toward the target only after the normal market action has completed.
- `checkpoint/harvest`: accrue interest first, checkpoint both sides atomically, then update cached strategy assets.
- `addReserves/reduceReserves`: preserve existing semantics; the separate IL reserve is not `totalReserves`.

### 5.4 Stale-strategy guard

Introduce `maxCheckpointAge`. If a strategy checkpoint is too old:

- always allow repay, add reserves, liquidation repayment, and a risk-reducing emergency LP decrease;
- allow redeem/borrow only from on-hand cash unless governance explicitly chooses a more permissive policy;
- block minting new strategy-exposed shares or immediately retain them entirely as cash;
- block LP increases and settlement swaps.

Off-hours require a session-aware policy because official Chainlink tokenized-equity feeds may hold the last value without a heartbeat. Do not use a naive 60-minute staleness limit throughout weekends.

---

## 6. Robinhood Chain deployment constants

Verify `eth_getCode` and official deployment pages again immediately before deployment.

### 6.1 Uniswap v4, chain ID 4663

| Contract | Address |
|---|---|
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| PositionDescriptor | `0x9639443158e8c5efa35bd45287bf2effd3d8dc06` |
| PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` |
| ReservesLens | `0x0000001b173C3bbF3984D417d8614E3eed34865B` |
| Universal Router | `0x8876789976decbfcbbbe364623c63652db8c0904` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

Source: [official Uniswap v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments).

### 6.2 Canonical Robinhood assets

| Asset | Address | Expected decimals |
|---|---|---:|
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | verify on-chain |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | 18 |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | 18 |
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | 18 |
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | 18 |
| MSFT | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | 18 |
| SPCX | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | 18 |

USDG/WETH are listed on [Robinhood's canonical contract page](https://docs.robinhood.com/chain/contracts/). Stock-token entries are generated from Robinhood's live asset registry; deployment scripts must retrieve and verify the current registry/API result instead of treating this table as permanent.

### 6.3 Observed canonical Stock/USDG v4 pools

These were observed through Uniswap's data surface at the research checkpoint. They are deployment inputs, not immutable truths. Reconstruct every `PoolKey`, derive its pool ID locally, and verify initialized state before use.

| Pair | Pool ID | Observed fee | Known configuration |
|---|---|---:|---|
| NVDA/USDG | `0x3bb34a44f1b2b5f32c034c38a53065a521a47b199700fa9bd19d60985ff24bf1` | `3000` (0.30%) | token0 USDG, token1 NVDA, tick spacing 60, zero hook |
| TSLA/USDG | `0x8517f8071ae5b831b738052f12125e8e3d6c158b78728aa44ce3b25e5104d32e` | `3000` | discover and verify tick spacing/hook |
| AAPL/USDG | `0xc748f4671a867db48b552f6b7650bf3255e05f80f00e3f7aad1b17ccb7898fdb` | `3000` | discover and verify tick spacing/hook |
| MSFT/USDG | `0x9194a557b6a6bb2236b49ea7e2bbccec5d3eeb705aef00903be4b3de1d949579` | `3000` | discover and verify tick spacing/hook |
| SPCX/USDG | `0xcb6ffbcc84359535c2cc0a5688c0a76520ea6e0a4820fddd3ac8d7880e576370` | `10000` (1.00%) | discover and verify tick spacing/hook |

Launch NVDA first. Do not infer tick spacing or hook merely from the fee for the other pools. MVP policy should require `hooks == address(0)` unless the hook has been separately reviewed and allowlisted.

---

## 7. Exact Uniswap v4 integration

### 7.1 Dependencies

Use Foundry and pin dependencies in `foundry.lock` / git submodule commits after fork tests:

```bash
forge install uniswap/v4-core
forge install uniswap/v4-periphery
forge install uniswap/permit2
forge install uniswap/universal-router
```

Typical remappings:

```text
@uniswap/v4-core/=lib/v4-core/
@uniswap/v4-periphery/=lib/v4-periphery/
@uniswap/permit2/=lib/permit2/
@uniswap/universal-router/=lib/universal-router/
```

Do not code against unpinned `main` in production.

### 7.2 Pool key and state reads

```solidity
using PoolIdLibrary for PoolKey;
using StateLibrary for IPoolManager;

PoolKey memory key = PoolKey({
    currency0: Currency.wrap(USDG),
    currency1: Currency.wrap(NVDA),
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(address(0))
});

PoolId id = key.toId();
require(PoolId.unwrap(id) == ALLOWLISTED_NVDA_POOL_ID, "POOL_ID");

(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
    poolManager.getSlot0(id);
uint128 activeLiquidity = poolManager.getLiquidity(id);
require(sqrtPriceX96 != 0, "UNINITIALIZED");
```

For on-chain reads use `StateLibrary` against `PoolManager`. `StateView` is useful for deployment scripts, frontends, and monitoring. The v4 Quoter is revert-based, not `view`, and should be called only off-chain with `eth_call`; never invoke it from the strategy contract.

### 7.3 Full-range ticks and liquidity math

```solidity
int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
```

For tick spacing 60 these are `-887220` and `887220`.

Calculate deployable liquidity with official math libraries:

```solidity
uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
    sqrtPriceX96,
    sqrtLower,
    sqrtUpper,
    amount0Desired,
    amount1Desired
);

(uint256 amount0Used, uint256 amount1Used) =
    LiquidityAmounts.getAmountsForLiquidity(
        sqrtPriceX96,
        sqrtLower,
        sqrtUpper,
        liquidity
    );
```

For NVDA/USDG, currency0 is USDG and currency1 is NVDA. Equal oracle value does not imply the exact amounts consumed by a full-range position; compute liquidity first and retain leftovers as attributed idle inventory.

### 7.4 Permit2 approvals

The coordinator/adapter is a contract caller and must set both approval layers:

```solidity
IERC20(token).forceApprove(PERMIT2, type(uint256).max);
IPermit2(PERMIT2).approve(
    token,
    POSITION_MANAGER, // or UNIVERSAL_ROUTER for swaps
    type(uint160).max,
    expiration
);
```

Use separate, narrowly scoped approvals for PositionManager and Universal Router. Provide a timelocked approval-revocation function, and verify the exact spender path in a pinned Robinhood fork test.

### 7.5 Mint a position

The exact PositionManager entry point is:

```solidity
IPositionManager.modifyLiquidities(bytes calldata unlockData, uint256 deadline)
```

Encode mint plus settlement:

```solidity
bytes memory actions = abi.encodePacked(
    uint8(Actions.MINT_POSITION),
    uint8(Actions.SETTLE_PAIR)
);

bytes[] memory params = new bytes[](2);
params[0] = abi.encode(
    key,
    tickLower,
    tickUpper,
    liquidity,
    amount0Max,
    amount1Max,
    address(this),
    bytes("")
);
params[1] = abi.encode(key.currency0, key.currency1);

positionManager.modifyLiquidities(
    abi.encode(actions, params),
    deadline
);
```

The adapter must discover/record the minted `tokenId` safely. Prefer the PositionManager's documented next-token-id/event behavior verified against the pinned deployed implementation; do not assume an ERC-721 enumerable interface.

### 7.6 Increase liquidity

```solidity
bytes memory actions = abi.encodePacked(
    uint8(Actions.INCREASE_LIQUIDITY),
    uint8(Actions.SETTLE_PAIR)
);

bytes[] memory params = new bytes[](2);
params[0] = abi.encode(
    tokenId,
    uint256(liquidityToAdd),
    uint128(amount0Max),
    uint128(amount1Max),
    bytes("")
);
params[1] = abi.encode(key.currency0, key.currency1);

positionManager.modifyLiquidities(
    abi.encode(actions, params),
    deadline
);
```

If accrued fees may pay for some/all of the increase, use `CLOSE_CURRENCY` for both currencies instead of blindly using `SETTLE_PAIR`; otherwise fee deltas may not resolve as expected. The first MVP can collect fees separately before increasing, which is simpler to account and audit.

### 7.7 Decrease liquidity and receive both tokens

```solidity
bytes memory actions = abi.encodePacked(
    uint8(Actions.DECREASE_LIQUIDITY),
    uint8(Actions.TAKE_PAIR)
);

bytes[] memory params = new bytes[](2);
params[0] = abi.encode(
    tokenId,
    uint256(liquidityToRemove),
    uint128(amount0Min),
    uint128(amount1Min),
    bytes("")
);
params[1] = abi.encode(key.currency0, key.currency1, address(this));

positionManager.modifyLiquidities(
    abi.encode(actions, params),
    deadline
);
```

Measure both balance deltas around the call. `amount0Min/amount1Min` and deadline are mandatory slippage/MEV controls, not optional UI parameters.

### 7.8 Collect fees without removing liquidity

There is no separate v4 `COLLECT` action. Use `DECREASE_LIQUIDITY` with zero liquidity, followed by `TAKE_PAIR`:

```solidity
bytes memory actions = abi.encodePacked(
    uint8(Actions.DECREASE_LIQUIDITY),
    uint8(Actions.TAKE_PAIR)
);

bytes[] memory params = new bytes[](2);
params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
params[1] = abi.encode(key.currency0, key.currency1, address(this));

positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
```

Use before/after balances to determine actual collected fees.

### 7.9 Burn an empty position

```solidity
bytes memory actions = abi.encodePacked(
    uint8(Actions.BURN_POSITION),
    uint8(Actions.TAKE_PAIR)
);

bytes[] memory params = new bytes[](2);
params[0] = abi.encode(
    tokenId,
    uint128(amount0Min),
    uint128(amount1Min),
    bytes("")
);
params[1] = abi.encode(key.currency0, key.currency1, address(this));

positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
```

Only burn after position liquidity is zero and all proceeds/fees are accounted.

### 7.10 Guarded exact-input swap through Universal Router

Use swaps only to restore native obligations after an LP unwind or to rebalance reserve inventory. New LP allocation itself uses both contributed tokens and does not swap.

The Universal Router entry point is:

```solidity
IUniversalRouter.execute(bytes commands, bytes[] inputs, uint256 deadline)
```

Exact-input single-pool encoding:

```solidity
bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
bytes[] memory inputs = new bytes[](1);

bytes memory actions = abi.encodePacked(
    uint8(Actions.SWAP_EXACT_IN_SINGLE),
    uint8(Actions.SETTLE_ALL),
    uint8(Actions.TAKE_ALL)
);

bytes[] memory params = new bytes[](3);
params[0] = abi.encode(
    IV4Router.ExactInputSingleParams({
        poolKey: key,
        zeroForOne: zeroForOne,
        amountIn: uint128(amountIn),
        amountOutMinimum: uint128(minAmountOut),
        hookData: bytes("")
    })
);

Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
params[1] = abi.encode(inputCurrency, amountIn);
params[2] = abi.encode(outputCurrency, minAmountOut);

inputs[0] = abi.encode(actions, params);
universalRouter.execute(commands, inputs, deadline);
```

Compute `minAmountOut` from a fresh Chainlink price and `maxSwapSlippageBps`; compare the live Uniswap sqrt price with Chainlink before the call; enforce `amountIn <= maxSettlementSwap`; and verify the received balance delta after the call. The keeper supplies a short deadline, but cannot choose an arbitrary pool or arbitrary command bytes.

Official references for these encodings are listed in section 15.

---

## 8. Rebalance, withdrawal, and settlement algorithms

### 8.1 Add liquidity

1. Accrue both markets.
2. Require both strategy checkpoints fresh and oracle guard healthy.
3. Calculate each market's target strategy assets, applying pUSDG aggregate/per-pair caps.
4. Calculate matched oracle value.
5. Pull no more than the matched native amounts into the coordinator.
6. Read `sqrtPriceX96` from PoolManager and verify Chainlink deviation.
7. Compute full-range liquidity and expected token usage.
8. Mint or increase the allowlisted NFT.
9. Measure actual token deltas and retain leftovers as idle pair inventory.
10. Increase native principals only by amounts actually received from each market.
11. Update both cached pToken strategy claims in the same transaction.

If either side is unavailable, leave the other side in its pToken cash buffer. Do not park unmatched pUSDG in a stock pair coordinator.

### 8.2 A single market requests withdrawal

Example: pNVDA needs `x` NVDA while pUSDG has no withdrawal.

1. Use pNVDA on-hand cash first.
2. Use NVDA idle inventory attributed to pNVDA next.
3. Determine the smallest pro-rata LP slice likely to restore the remaining NVDA obligation, with a bounded over-unwind margin.
4. Decrease that LP slice and receive both NVDA and USDG.
5. Reduce the matching portion of both native principal ledgers. This is a joint LP unwind even though only one market requested cash.
6. Return the USDG side's restored amount to pUSDG as on-hand cash (or attributed idle inventory if the existing architecture requires it).
7. If NVDA remains short, use USDG proceeds above the restored pUSDG obligation and then approved reserve coverage for a guarded USDG→NVDA swap.
8. Return NVDA to pNVDA.
9. Recognize any uncovered loss across both side ledgers pro rata by marked USDG benchmark; update both cached strategy claims atomically.

The converse applies when pUSDG needs USDG. This may reduce the stock market's strategy allocation temporarily; the next keeper rebalance can pair it again.

### 8.3 Fee collection and attribution

For the swap-free MVP fee policy:

1. Collect fees in both tokens using zero-liquidity decrease.
2. Send `reserveFeeBps` of stock fees to the pair's stock reserve balance.
3. Send `reserveFeeBps` of USDG fees to the pair's USDG reserve balance.
4. Credit remaining stock fees to pStock's strategy claim.
5. Credit remaining USDG fees to pUSDG's strategy claim.

Recommended initial `reserveFeeBps`: `2_000` (20%). This in-kind approach avoids cross-token fee swaps and is simpler than an arbitrary 40/40/20 USD split. Governance can change the cut under timelock within an audited maximum.

### 8.4 Checkpoint / mark-to-market

At each keeper checkpoint:

1. Accrue both pTokens.
2. Collect fees or estimate them conservatively from PositionManager state.
3. Derive LP token amounts using current pool state and official liquidity math.
4. Require a valid Chainlink stock price and USDG price policy.
5. Calculate gross value and benchmark.
6. Apply only reserve coverage that has actually been transferred; do not count a theoretical reserve promise.
7. Convert the resulting equal-seniority PnL allocation into native-unit cached claims.
8. Limit positive gain recognition per checkpoint if desired; never cap loss recognition.
9. Update both markets and pair ledger atomically; emit a detailed event.

Suggested event:

```solidity
event PairCheckpoint(
    bytes32 indexed pairId,
    uint256 stockAssets,
    uint256 usdgAssets,
    uint256 benchmarkUSDG,
    int256 pnlUSDG,
    uint256 reserveUsedUSDG,
    uint256 stockAccountedAssets,
    uint256 usdgAccountedAssets
);
```

Do not use Uniswap spot as the mark. It is a manipulation check and LP-math input, not the accounting oracle.

---

## 9. Oracle and corporate-action policy

Robinhood stock tokens are 18-decimal, non-rebasing ERC-20 assets that expose Robinhood's multiplier/oracle-pause behavior. Chainlink's Robinhood tokenized-equity feed returns total-return token value:

```text
token price = underlying equity price × Robinhood uiMultiplier
```

Therefore:

- Use the Chainlink proxy's `latestRoundData()` value directly after decimal normalization.
- Do not apply `uiMultiplier()` a second time.
- Check `stockToken.oraclePaused()` independently.
- Validate each configured feed on deployment with `description()`, `decimals()`, and `latestRoundData()`.
- Feed addresses are timelock-managed configuration; do not invent or copy an unverified address.

Operation matrix:

| Condition | Add/increase LP | Swap | Collect fees | Decrease LP | Borrow/redeem from strategy |
|---|---:|---:|---:|---:|---:|
| Healthy | yes | bounded | yes | yes | yes |
| Chainlink stale during expected live session | no | no | collect but defer valuation | yes, risk-reducing | on-hand only; otherwise pause/revert |
| Expected market closed/off-hours | no by default | no by default | yes, defer valuation | yes | on-hand first; governed session policy |
| `oraclePaused() == true` | no | no | yes, defer valuation | emergency/risk-reducing only | on-hand only |
| Sequencer down / grace period | no | no | no valuation | emergency/risk-reducing only | on-hand only |
| Uniswap/Chainlink deviation too high | no | no | yes | yes with conservative minima | on-hand; emergency path only |

Emergency decrease must return both assets to custody without claiming that native principals were restored. Settlement and pToken loss recognition happen when a trustworthy price returns, unless governance executes a separately audited manual-loss process.

---

## 10. Security requirements

- Use `ReentrancyGuard` at pToken→strategy and coordinator external entry points; follow checks-effects-interactions.
- Allowlist the exact pToken adapters, underlying tokens, pool key, pool ID, PositionManager, PoolManager, Universal Router, and Permit2.
- MVP permits zero-hook pools only.
- Keeper can call bounded operations but cannot change configuration, recipients, pool keys, token IDs, calldata, or fee splits.
- Timelock controls feeds, caps, buffers, reserve cut, max slippage, max deviation, and adapter upgrades.
- Guardian can pause new allocation/swaps and invoke a bounded emergency decrease; it cannot seize assets.
- Deadlines should normally be 60–300 seconds and must be checked against both lower and upper allowed bounds.
- All amount conversions use `mulDiv` with explicit decimal normalization and rounding direction.
- Round deposits down; round liabilities/required outputs up.
- Protect against fee-on-transfer/rebasing behavior by rejecting such tokens in preflight; Robinhood stock tokens are expected non-rebasing, but measure deltas anyway.
- Reject uninitialized pools and unexpected dynamic fees/hooks.
- Never expose a general-purpose Universal Router executor.
- Never let an oracle price directly determine unrestricted swap size.
- Support optional per-pair TVL and aggregate USDG circuit breakers. Always bound reserve
  use, settlement swaps, and daily reserve loss.
- Positive donation/balance surplus must not be claimable by the next caller; reconcile it at checkpoint.
- An active position NFT cannot be rescued/transferred except through a timelocked, paused, full-accounting migration.
- Run independent audits focused on paired accounting, exchange-rate integration, and settlement—not only the Uniswap adapter.

---

## 11. Suggested configuration structs

```solidity
struct PairConfig {
    address stockToken;
    address usdg;
    address pStockAdapter;
    address pUsdgAdapter;
    address stockPriceFeed;
    address sequencerFeed;       // zero only if confirmed unnecessary
    bytes32 poolId;
    PoolKey poolKey;

    uint16 reserveFeeBps;
    uint16 maxPriceDeviationBps;
    uint16 maxSwapSlippageBps;
    uint16 maxLossCoverageBps;
    uint16 maxPairShareOfUsdgBps;

    uint128 maxPairValueUSDG;
    uint128 maxSettlementSwapUSDG;
    uint128 maxReserveUsePerTxUSDG;
    uint64 maxCheckpointAge;
    uint64 tradingSessionMaxStaleness;
    uint64 sequencerGracePeriod;

    bool allocationPaused;
    bool swapsPaused;
    bool emergencyMode;
}
```

Use repository-compatible packed storage and upgrade gaps if contracts are upgradeable. Store pool key fields separately if Solidity cannot safely persist the imported struct in the current upgrade layout.

---

## 12. Deployment preflight and deployment order

### 12.1 Preflight script must fail closed

For every address/config:

1. Assert `block.chainid == 4663`.
2. Assert non-empty bytecode for Uniswap and token contracts.
3. Fetch Robinhood's current asset registry/API and compare canonical stock addresses.
4. Read `name`, `symbol`, `decimals`, `oraclePaused`, and multiplier-related methods from each stock.
5. Read USDG decimals and confirm stablecoin pricing policy.
6. Build the sorted `PoolKey`; derive `PoolIdLibrary.toId(key)` and compare with allowlisted pool ID.
7. Read `StateView.getSlot0(poolId)` and `PoolManager.getSlot0(poolId)`; require initialized and equal core state.
8. Confirm zero hook for MVP.
9. Query the official Chainlink feed list immediately before deployment.
10. For every feed, verify `description`, `decimals`, positive `answer`, plausible normalized price, and nonzero `updatedAt`.
11. If a sequencer feed exists, verify its official address and semantics; otherwise record an explicit reviewed waiver.
12. Simulate Permit2 approval, mint, collect, decrease, swap, and burn on a pinned fork.

Save the resulting JSON manifest in the repository and hash it in the deployment proposal. Do not let the script silently substitute a different pool or token.

### 12.2 Deployment order

1. Deploy or configure `StockOracleGuard`.
2. Deploy `StrategyLossReserve` behind the existing timelock/guardian model.
3. Deploy `UniswapV4PairedAdapter` with immutable official Uniswap addresses.
4. Deploy `PairedLiquidityCoordinator`.
5. Deploy/configure the pStock and pUSDG strategy adapters.
6. Register NVDA/USDG pair in paused mode.
7. Set Permit2 approvals with expirations and exact spenders.
8. Connect adapters to existing pTokens under timelock.
9. Seed reserve explicitly and record source/ownership.
10. Run zero-value and minimal-value smoke tests.
11. Enable checkpointing and withdrawals before enabling allocation.
12. Stage a small NVDA allocation through the allowlisted side accounts; optionally set
    nonzero circuit-breaker caps and monitor through live and closed equity sessions.
13. Add TSLA/AAPL/MSFT/SPCX only after pool-key/oracle verification and canary acceptance.

---

## 13. Test plan

### 13.1 Unit tests

- target strategy allocation at 0%, 10%, 40%, 80%, 90%, and >90% utilization;
- disabled and enabled pUSDG aggregate/per-pair circuit-breaker semantics;
- matched-pair min calculation and decimals;
- full-range tick derivation for every spacing;
- oracle normalization and multiplier-not-double-counted;
- loss waterfall and equal-seniority allocation;
- reserve caps and daily use;
- cached exchange rate before/after profit and loss;
- every pause-matrix branch;
- deadline, slippage, deviation, and stale-checkpoint bounds.

### 13.2 Robinhood fork tests

Pin a block and run against chain ID 4663:

- bytecode/address assertions;
- NVDA PoolKey→PoolId equality;
- `getSlot0` and liquidity reads;
- Permit2 approvals from a contract caller;
- mint full-range position;
- increase position;
- collect fees with zero-liquidity decrease;
- partial decrease and both-token balance deltas;
- guarded exact-input swap in both directions;
- full decrease and burn;
- pNVDA withdrawal while pUSDG has no withdrawal;
- pUSDG withdrawal while pNVDA has no withdrawal;
- sequential simultaneous withdrawals;
- checkpoint after large stock move;
- oracle pause and stale/off-hours behavior.

### 13.3 Invariant/fuzz tests

- total credited pToken strategy claims plus reserve claims never exceed conservatively accounted assets;
- no double counting between coordinator, adapters, pToken cash, and reserve;
- a caller cannot withdraw another pair's or market's principal;
- arbitrary keeper sequences cannot transfer the NFT or change pool;
- exchange rate cannot increase solely due to moving assets between pToken and strategy;
- uncovered loss never causes arithmetic underflow or a false positive PnL;
- positive fee recognition cannot occur twice;
- partial unwinds followed by re-pairing preserve ledgers within rounding tolerance;
- donations cannot be captured by mint/redeem ordering;
- reentrancy from token/Uniswap callbacks cannot corrupt principal;
- all caps hold under extreme oracle values and decimals.

### 13.4 Economic scenarios

Model at least:

- stock flat with high trading fees;
- stock +10%, +50%, +200%;
- stock -10%, -50%, -90%;
- rapid V-shaped price move;
- fees below, equal to, and above impermanent loss;
- exhausted reserve;
- low pUSDG liquidity with many stock pairs;
- pool price manipulated at checkpoint;
- stock split/corporate-action pause;
- weekend withdrawal with no feed heartbeat;
- sequencer outage.

---

## 14. Implementation phases and acceptance criteria

### Phase A — repository mapping

Deliver a short mapping from every abstraction in this document to concrete repository contracts/functions. No Solidity changes until exchange-rate and cash-assurance hooks are identified.

### Phase B — isolated Uniswap adapter

Implement PoolKey allowlisting, state reads, Permit2 approvals, NFT lifecycle, and guarded swap. Acceptance: all direct-call fork tests pass for NVDA/USDG.

### Phase C — paired accounting and reserve

Implement ledgers, fee collection, checkpoint valuation, loss waterfall, and reserve caps. Acceptance: unit/invariant tests prove no double counting and no silent pUSDG juniorization.

### Phase D — existing boosted core integration

Integrate adapters into pNVDA/pUSDG with cached strategy assets and `_ensureCash`. Acceptance: ordinary Compound-v2 mint/redeem/borrow/repay/liquidation tests continue to pass plus strategy withdrawal cases.

### Phase E — deployment tooling and canary

Implement the fail-closed manifest, fork simulation, timelock proposal, monitoring, and emergency runbook. Acceptance: NVDA canary can be fully unwound and both markets reconciled from a single scripted operation.

### Definition of done

- No user-facing change to ordinary pToken deposit/borrow/redeem UX.
- A 0%-utilization market can route only matched idle assets authorized by its configured
  side account to LP.
- A high-utilization market automatically targets lower LP allocation.
- Borrow/redeem can source native underlying through a controlled unwind.
- Every Uniswap call uses the canonical allowlisted address/pool and exact documented encoding.
- No live external protocol/oracle read exists inside exchange-rate/accrual views.
- LP fees, reserve assets, principal, and losses are separately and audibly accounted.
- pUSDG has equal seniority unless a future explicit tranche product says otherwise.
- Stale oracle, corporate action, sequencer outage, and price deviation fail safely.
- Fork, invariant, economic, upgrade/storage, and legacy regression tests pass.
- Independent security review completed before production-scale allocation.

---

## 15. Primary technical sources

Uniswap:

- [v4 deployments, including Robinhood Chain](https://developers.uniswap.org/docs/protocols/v4/deployments)
- [v4 liquidity-management setup](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/getting-started)
- [PositionManager overview](https://developers.uniswap.org/docs/protocols/v4/guides/position-manager)
- [Mint position](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/mint-position)
- [Increase liquidity](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/increase-liquidity)
- [Decrease liquidity](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/decrease-liquidity)
- [Collect fees](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/collect-fees)
- [Burn position](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/burn-liquidity)
- [Read PoolManager state](https://developers.uniswap.org/docs/protocols/v4/guides/read-pool-state)
- [StateView](https://developers.uniswap.org/docs/protocols/v4/guides/state-view)
- [Universal Router v4 swap routing](https://developers.uniswap.org/docs/protocols/v4/guides/swapping/routing)
- [v4 TickMath source](https://github.com/Uniswap/v4-core/blob/main/src/libraries/TickMath.sol)
- [v4 Quoter source](https://github.com/Uniswap/v4-periphery/blob/main/src/lens/V4Quoter.sol)

Robinhood / Chainlink:

- [Robinhood canonical token contracts](https://docs.robinhood.com/chain/contracts/)
- [Building with Robinhood stock tokens](https://docs.robinhood.com/chain/building-with-stock-tokens/)
- [Robinhood stock-token APIs](https://docs.robinhood.com/chain/stock-token-apis/)
- [Robinhood oracles and price feeds](https://docs.robinhood.com/chain/oracles-and-price-feeds/)
- [Chainlink Robinhood tokenized-equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)

---

## 16. Instructions to the coding LLM

Use this handoff as a constraint document, not as permission to invent missing repository details.

1. Begin with the repository mapping in section 1 and report the concrete file/function mapping.
2. Preserve current stable boosted-market semantics unless this handoff explicitly requires a volatile-pair difference.
3. Mark unavoidable unknowns as `TODO(DEPLOYMENT_VERIFY)`; do not invent feed addresses, hooks, tick spacing, spenders, or upgrade storage slots.
4. Implement in phases with tests in the same commit as each behavior.
5. Prefer small adapters over invasive pToken changes.
6. Keep all keeper inputs bounded and reconstruct protocol calldata internally.
7. Use fork evidence for every Robinhood/Uniswap integration assumption.
8. Stop and request a product/security decision if the existing core requires pUSDG to absorb stock losses, if a live oracle is unavailable, or if native-principal restoration would require an unbounded swap.
9. Produce a final deployment manifest and a risk/assumption diff against this document.
