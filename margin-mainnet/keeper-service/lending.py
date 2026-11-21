"""pSPY-collateral lending liquidations: ordinary (non-margin) accounts with pUSDG debt and pSPY collateral.

Off unless deployments/spy-collateral/keeper.json exists AND the worker runs with LENDING_LIQUIDATIONS=true.
Every send is a call to the pinned SpyCollateralLiquidator (flash USDG -> [swap to NVDA] -> liquidateBorrow ->
redeem -> swap -> repay; proceeds to the Ledger): `liquidate` for pUSDG debt, `liquidateNvdaDebt` for pNVDA debt, so the keeper holds no inventory. Journals reuse the margin journal table with ids
>= LENDING_ID_BASE (base + 1-based index in the deterministic MarketEntered discovery order), and follow the same
intent -> submitted -> confirmed state machine: unresolved sends stop new sends, never blind retries.

Read and stale failures are reported, never raised: they must not stop margin liquidation.
"""
import json
from pathlib import Path

import sys
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'margin-mainnet/tools'))
from rpc import call, cast, rpc, words, address  # noqa: E402
import keeper  # noqa: E402  (keeper.persist is looked up per call: the worker routes it to the database)

CONFIG = ROOT / 'deployments/spy-collateral/keeper.json'
LENDING_ID_BASE = 10**12
MARKET_ENTERED = '0x3ab23ab0d51cccc0c3085aec51f99228625aa1a922b3a8ca89a26b0f2027a1a5'  # MarketEntered(address,address)
LOG_CHUNK = 9_999_999
SNAPSHOT_ERROR = 15
LEDGER = '0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD'


def is_lending_id(position_id):
    return int(position_id) >= LENDING_ID_BASE


def load_config(path=CONFIG):
    if not Path(path).exists():
        return None
    config = json.loads(Path(path).read_text())
    for key in ('chainId', 'controller', 'pUSDG', 'pSPY', 'liquidator', 'liquidatorRuntimeHash',
                'delegate', 'delegateRuntimeHash', 'fromBlock', 'maxRepayUsdg', 'pNVDA', 'maxRepayNvda'):
        if key not in config:
            raise ValueError('keeper.json misses ' + key)
    return config


class LendingBackend:
    """Reads, plans and simulates. Submission and receipt identity checks live in the signing backend (worker)."""

    def __init__(self, url, config, sender):
        self.url, self.c, self.sender = url, config, sender
        self.identity = {'chainId': 4663, 'rpc': url, 'liquidator': config['liquidator'].lower(),
                         'pSPY': config['pSPY'].lower(), 'sender': sender.lower()}
        if int(rpc('eth_chainId', [], url), 16) != 4663 or config['chainId'] != 4663:
            raise RuntimeError('Wrong chain for lending liquidations')
        self.verify()

    def word(self, target, signature, *args):
        return words(call(target, signature, *args, url=self.url))

    def verify(self):
        """Pins: liquidator runtime + wiring, pSPY implementation runtime. Raises on any mismatch."""
        code = rpc('eth_getCode', [self.c['liquidator'], 'latest'], self.url)
        if cast('keccak', code).lower() != self.c['liquidatorRuntimeHash'].lower():
            raise RuntimeError('Lending liquidator bytecode changed')
        if address(self.word(self.c['pSPY'], 'implementation()')[0]) != self.c['delegate'].lower():
            raise RuntimeError('pSPY implementation changed')
        code = rpc('eth_getCode', [self.c['delegate'], 'latest'], self.url)
        if cast('keccak', code).lower() != self.c['delegateRuntimeHash'].lower():
            raise RuntimeError('pSPY delegate bytecode changed')
        expected = {'debtMarket()': self.c['pUSDG'], 'collateralMarket()': self.c['pSPY'], 'beneficiary()': LEDGER,
                    'nvdaDebtMarket()': self.c['pNVDA']}
        for signature, value in expected.items():
            if address(self.word(self.c['liquidator'], signature)[0]) != value.lower():
                raise RuntimeError('Lending liquidator wiring mismatch: ' + signature)

    # ------------------------------------------------------------------ discovery

    def discover(self, state):
        """Accounts that ever entered pSPY, in (block, logIndex) order. Cached; extends incrementally."""
        path = Path(state) / 'lending-candidates.json'
        cache = json.loads(path.read_text()) if path.exists() else {'scannedTo': self.c['fromBlock'] - 1, 'accounts': []}
        head = int(rpc('eth_blockNumber', [], self.url), 16)
        start = cache['scannedTo'] + 1
        pspy = self.c['pSPY'].lower()
        while start <= head:
            end = min(head, start + LOG_CHUNK - 1)
            logs = rpc('eth_getLogs', [{'address': self.c['controller'], 'fromBlock': hex(start),
                                        'toBlock': hex(end), 'topics': [MARKET_ENTERED]}], self.url)
            for log in sorted(logs, key=lambda l: (int(l['blockNumber'], 16), int(l['logIndex'], 16))):
                data = log['data'][2:]
                market, account = '0x' + data[24:64], '0x' + data[88:128]
                if market.lower() == pspy and account.lower() not in cache['accounts']:
                    cache['accounts'].append(account.lower())
            cache['scannedTo'] = end
            start = end + 1
        # A cache, not a journal: written locally only (rediscovered from fromBlock after a restart).
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps(cache))
        temp.replace(path)
        return cache['accounts']

    # ------------------------------------------------------------------ reads

    def snapshot(self, account):
        err, liquidity, shortfall = self.word(self.c['controller'], 'getAccountLiquidity(address)', account)
        margin = self.word(self.c['controller'], 'isolatedMarginAccounts(address)', account)[0] == 1
        tokens = self.word(self.c['pSPY'], 'balanceOf(address)', account)[0]
        debt = self.word(self.c['pUSDG'], 'borrowBalanceCurrent(address)', account)[0]
        nvda_debt = self.word(self.c['pNVDA'], 'borrowBalanceCurrent(address)', account)[0]
        return {'account': account, 'err': err, 'liquidity': liquidity, 'shortfall': shortfall, 'margin': margin,
                'pSpy': tokens, 'debt': debt, 'nvdaDebt': nvda_debt,
                'block': int(rpc('eth_blockNumber', [], self.url), 16)}

    def _bound(self, snap, debt, market, cap):
        """min(close factor x debt, the debt whose seizure fits the pSPY balance (1 % margin), configured max), and
        the debt market's controller price."""
        close = self.word(self.c['controller'], 'closeFactorMantissa()')[0]
        incentive = self.word(self.c['controller'], 'liquidationIncentiveMantissa()')[0]
        oracle = '0x' + format(self.word(self.c['controller'], 'oracle()')[0], '040x')
        p_spy = self.word(oracle, 'getUnderlyingPrice(address)', self.c['pSPY'])[0]
        p_debt = self.word(oracle, 'getUnderlyingPrice(address)', market)[0]
        rate = self.word(self.c['pSPY'], 'exchangeRateStored()')[0]
        if p_spy == 0 or p_debt == 0:
            return 0, p_debt
        by_close = debt * close // 10**18
        # seizeTokens = repay * incentive * pDebt / (pSpy * rate)  <=  pSpy balance
        by_collateral = snap['pSpy'] * p_spy * rate // (incentive * p_debt) * 99 // 100
        return max(0, min(by_close, by_collateral, int(cap))), p_debt

    def repay_amount(self, snap):
        return self._bound(snap, snap['debt'], self.c['pUSDG'], self.c['maxRepayUsdg'])[0]

    def plan(self, snap):
        """pUSDG debt first (one fewer swap); then pNVDA debt. None when nothing can be repaid."""
        if snap['debt'] > 0:
            repay = self.repay_amount(snap)
            return {'kind': 'usdg', 'repay': repay, 'debtKey': 'debt'} if repay else None
        if snap.get('nvdaDebt', 0) > 0:
            max_repay, p_nvda = self._bound(snap, snap['nvdaDebt'], self.c['pNVDA'], self.c['maxRepayNvda'])
            # USDG in sized to buy ~97 % of max_repay at the controller price: pool fee and offset keep it below.
            usdg_in = max_repay * p_nvda // 10**18 // 10**12 * 97 // 100
            if not max_repay or not usdg_in:
                return None
            return {'kind': 'nvda', 'maxRepay': max_repay, 'usdgIn': usdg_in, 'debtKey': 'nvdaDebt'}
        return None

    # ------------------------------------------------------------------ transactions

    def transaction(self, account, plan):
        if plan['kind'] == 'usdg':
            data = cast('calldata', 'liquidate(address,uint256)', account, str(plan['repay']))
        elif plan['kind'] == 'nvda':
            data = cast('calldata', 'liquidateNvdaDebt(address,uint256,uint256)', account, str(plan['usdgIn']),
                        str(plan['maxRepay']))
        else:
            raise ValueError('Unknown liquidation plan')
        return {'from': self.sender, 'to': self.c['liquidator'], 'data': data}

    def simulate(self, account, plan):
        tx = self.transaction(account, plan)
        rpc('eth_call', [tx, 'latest'], self.url)
        tx['gas'] = hex(int(rpc('eth_estimateGas', [tx], self.url), 16) * 3)
        return tx


def journal_path(state, index):
    return Path(state) / ('position-%d.json' % (LENDING_ID_BASE + index))


def unresolved(state):
    pending = []
    for path in Path(state).glob('position-*.json'):
        j = json.loads(path.read_text())
        if is_lending_id(j['positionId']) and j['attempts'] and j['attempts'][-1]['state'] != 'confirmed':
            pending.append(j['positionId'])
    return sorted(pending)


def run(backend, signer, index, account, state, execute=False, max_calls=4):
    """One account. `signer` provides nonce(), submit(tx, nonce, journal_id), receipt(hash, journal_id)."""
    jid = LENDING_ID_BASE + index
    path = journal_path(state, index)
    journal = json.loads(path.read_text()) if path.exists() else {
        'positionId': jid, 'account': account, 'identity': backend.identity, 'attempts': []}
    if journal['account'] != account or journal['identity'] != backend.identity:
        raise RuntimeError('Lending journal belongs to another account, deployment or signer')
    attempts = journal['attempts']
    if attempts and attempts[-1]['state'] != 'confirmed':
        previous = attempts[-1]
        if not previous.get('hash'):
            return {'status': 'reconcile_unknown_submission'}
        receipt = signer.receipt(previous['hash'], jid)
        if not receipt:
            return {'status': 'pending'}
        if int(receipt['status'], 16) != 1:
            previous['state'] = 'reverted'
            keeper.persist(path, journal)
            return {'status': 'reverted_stop'}
        after = backend.snapshot(account)
        key = previous['plan']['debtKey']
        if after[key] >= previous['beforeDebt'] and after[key] != 0:
            return {'status': 'no_progress_stop'}
        previous.update(state='confirmed', afterDebt=after[key])
        keeper.persist(path, journal)
    for _ in range(max_calls):
        snap = backend.snapshot(account)
        if snap['margin'] or snap['pSpy'] == 0:
            return {'status': 'not_applicable', 'snapshot': snap}
        if snap['err'] == SNAPSHOT_ERROR:
            return {'status': 'spy_closed_or_stale', 'snapshot': snap}
        if snap['err'] != 0:
            return {'status': 'liquidity_error', 'snapshot': snap}
        if snap['shortfall'] == 0:
            return {'status': 'healthy', 'snapshot': snap}
        if snap['debt'] == 0 and snap.get('nvdaDebt', 0) == 0:
            # Shortfall from debt in a market the liquidator does not repay. Reported, never sent.
            return {'status': 'unsupported_debt_shortfall', 'snapshot': snap}
        plan = backend.plan(snap)
        if not plan:
            return {'status': 'not_executable_stop', 'reason': 'zero repay', 'snapshot': snap}
        try:
            tx = backend.simulate(account, plan)
        except Exception as error:
            return {'status': 'not_executable_stop', 'reason': str(error), 'snapshot': snap}
        if not execute:
            return {'status': 'executable_plan', 'transaction': tx, 'plan': plan, 'snapshot': snap}
        nonce = signer.nonce()
        attempt = {'state': 'intent', 'nonce': nonce, 'beforeDebt': snap[plan['debtKey']], 'plan': plan,
                   'transaction': tx}
        attempts.append(attempt)
        keeper.persist(path, journal)
        try:
            attempt['hash'] = signer.submit(tx, nonce, jid, account, plan)
            attempt['state'] = 'submitted'
            keeper.persist(path, journal)
        except Exception as error:
            attempt.update(state='unknown_submission', error=type(error).__name__)
            keeper.persist(path, journal)
            return {'status': 'reconcile_unknown_submission'}
        receipt = signer.receipt(attempt['hash'], jid)
        if not receipt:
            return {'status': 'pending'}
        if int(receipt['status'], 16) != 1:
            attempt['state'] = 'reverted'
            keeper.persist(path, journal)
            return {'status': 'reverted_stop'}
        after = backend.snapshot(account)
        key = plan['debtKey']
        if after[key] >= snap[key] and after[key] != 0:
            attempt['state'] = 'no_progress'
            keeper.persist(path, journal)
            return {'status': 'no_progress_stop'}
        attempt.update(state='confirmed', afterDebt=after[key])
        keeper.persist(path, journal)
    return {'status': 'call_budget_stop'}


STOP_STATES = ('reconcile_unknown_submission', 'reverted_stop', 'no_progress_stop', 'call_budget_stop')


def cycle(backend, signer, state, execute=False, max_accounts=200):
    """Returns {'status': monitoring|spy_closed|waiting_receipt|operator_attention|lending_degraded, 'accounts': [...]}.
    Only an unresolved or failed *send* yields operator_attention (nonce safety); read problems yield lending_degraded."""
    try:
        accounts = backend.discover(state)
    except Exception as error:
        return {'status': 'lending_degraded', 'reason': type(error).__name__, 'accounts': []}
    if len(accounts) > max_accounts:
        return {'status': 'lending_degraded', 'reason': 'account scan budget exceeded', 'accounts': []}
    pending = set(unresolved(state))
    order = sorted(range(1, len(accounts) + 1), key=lambda i: (LENDING_ID_BASE + i) not in pending)
    results, closed, degraded = [], False, False
    for index in order:
        account = accounts[index - 1]
        try:
            result = run(backend, signer, index, account, state, execute)
        except Exception as error:
            if (LENDING_ID_BASE + index) in pending:
                return {'status': 'operator_attention', 'accounts': results + [{'account': account, 'status': 'error'}]}
            degraded = True
            results.append({'account': account, 'status': 'read_error', 'reason': type(error).__name__})
            continue
        results.append({'account': account, 'status': result['status']})
        if result['status'] == 'spy_closed_or_stale':
            closed = True
        if result['status'] == 'pending':
            return {'status': 'waiting_receipt', 'accounts': results}
        if result['status'] in STOP_STATES:
            return {'status': 'operator_attention', 'accounts': results}
    unsupported = any(r['status'] == 'unsupported_debt_shortfall' for r in results)
    status = ('lending_degraded' if degraded else 'lending_unsupported_shortfall' if unsupported
              else 'spy_closed' if closed else 'monitoring')
    return {'status': status, 'accounts': results}
