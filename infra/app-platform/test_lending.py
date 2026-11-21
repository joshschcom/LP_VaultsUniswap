"""pSPY-collateral lending liquidation module: planning, journal state machine, isolation from margin, signing policy.

Run: cd infra/app-platform && python3 -m unittest test_lending  (no network, no secrets; psycopg is stubbed)
"""
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.modules.setdefault('psycopg', types.ModuleType('psycopg'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import worker  # noqa: E402
import lending  # noqa: E402
import service  # noqa: E402

LIQ = '0x00000000000000000000000000000000000000aa'
PSPY = '0x00000000000000000000000000000000000000bb'
ALICE = '0x00000000000000000000000000000000000000a1'
CONFIG = {'chainId': 4663, 'controller': '0x6148183676E304dbe63a85C350c208DA3cEAc39C',
          'pUSDG': '0x55aEd0569c8f0D166D71facE57B57C2f2624a563', 'pSPY': PSPY, 'liquidator': LIQ,
          'liquidatorRuntimeHash': '0x' + '11' * 32, 'delegate': '0x' + 'cc' * 20,
          'delegateRuntimeHash': '0x' + '22' * 32, 'fromBlock': 100, 'maxRepayUsdg': 100_000_000,
          'pNVDA': '0xa155ccCB986774AE818b3F10F07d01D1b7A47b26', 'maxRepayNvda': 10**18}


def snap(err=0, shortfall=10, debt=40_000_000, tokens=5 * 10**8, margin=False, nvda=0):
    return {'account': ALICE, 'err': err, 'liquidity': 0, 'shortfall': shortfall, 'margin': margin,
            'pSpy': tokens, 'debt': debt, 'nvdaDebt': nvda, 'block': 1}


class FakeBackend(lending.LendingBackend):
    def __init__(self, snaps, accounts=(ALICE,)):
        self.c, self.sender, self.url = CONFIG, worker.KEEPER, 'x'
        self.identity = {'chainId': 4663, 'liquidator': LIQ, 'pSPY': PSPY, 'sender': worker.KEEPER.lower()}
        self.snaps, self.accounts, self.simulated = list(snaps), list(accounts), []

    def discover(self, state):
        return self.accounts

    def snapshot(self, account):
        return self.snaps.pop(0) if len(self.snaps) > 1 else self.snaps[0]

    def plan(self, s):
        if s['debt']:
            return {'kind': 'usdg', 'repay': 20_000_000, 'debtKey': 'debt'}
        return {'kind': 'nvda', 'maxRepay': 10**17, 'usdgIn': 12_000_000, 'debtKey': 'nvdaDebt'}

    def transaction(self, account, plan):
        v = plan.get('repay') or plan['maxRepay']
        return {'from': self.sender, 'to': LIQ, 'data': '0xabcd%040x%064x' % (int(account, 16), v)}

    def simulate(self, account, plan):
        self.simulated.append((account, plan))
        return dict(self.transaction(account, plan), gas=hex(3_000_000))


class FakeSigner:
    def __init__(self, receipts=None, fail=False):
        self.sent, self.receipts, self.fail = [], receipts or {}, fail

    def nonce(self):
        return 7

    def submit(self, tx, nonce, jid, account, plan):
        if self.fail:
            raise RuntimeError('boom')
        self.sent.append((tx, nonce, jid))
        return '0x' + '%064x' % len(self.sent)

    def receipt(self, h, jid):
        return self.receipts.get(h, {'status': '0x1'})


class LendingTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state = Path(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def test_closed_or_stale_never_sends(self):
        b, s = FakeBackend([snap(err=lending.SNAPSHOT_ERROR)]), FakeSigner()
        r = lending.run(b, s, 1, ALICE, self.state, execute=True)
        self.assertEqual(r['status'], 'spy_closed_or_stale')
        self.assertEqual(s.sent, [])
        self.assertEqual(b.simulated, [])

    def test_healthy_margin_and_empty_accounts_skip(self):
        for sn, status in [(snap(shortfall=0), 'healthy'), (snap(margin=True), 'not_applicable'),
                           (snap(debt=0, nvda=10**17), 'executable_plan'),
                           (snap(tokens=0), 'not_applicable'), (snap(debt=0, shortfall=0), 'healthy'),
                           (snap(debt=0), 'unsupported_debt_shortfall'),
                           (snap(err=4), 'liquidity_error')]:
            r = lending.run(FakeBackend([sn]), FakeSigner(), 1, ALICE, self.state, execute=False)
            self.assertEqual(r['status'], status)

    def test_plan_only_without_execute(self):
        r = lending.run(FakeBackend([snap()]), FakeSigner(), 1, ALICE, self.state, execute=False)
        self.assertEqual(r['status'], 'executable_plan')
        self.assertEqual(r['transaction']['to'], LIQ)

    def test_execute_persists_intent_then_confirms(self):
        b, s = FakeBackend([snap(), snap(debt=20_000_000, shortfall=0)]), FakeSigner()
        r = lending.run(b, s, 1, ALICE, self.state, execute=True)
        self.assertEqual(r['status'], 'healthy')
        j = json.loads(lending.journal_path(self.state, 1).read_text())
        self.assertEqual(j['positionId'], lending.LENDING_ID_BASE + 1)
        self.assertEqual(j['attempts'][0]['state'], 'confirmed')
        self.assertEqual(s.sent[0][2], lending.LENDING_ID_BASE + 1)

    def test_pending_receipt_is_reconciled_first(self):
        s = FakeSigner(receipts={'0x' + '%064x' % 1: None})
        r = lending.run(FakeBackend([snap()]), s, 1, ALICE, self.state, execute=True)
        self.assertEqual(r['status'], 'pending')
        self.assertEqual(lending.unresolved(self.state), [lending.LENDING_ID_BASE + 1])
        s.receipts = {}
        r = lending.run(FakeBackend([snap(debt=20_000_000, shortfall=0)]), s, 1, ALICE, self.state, execute=True)
        self.assertEqual(r['status'], 'healthy')
        self.assertEqual(len(s.sent), 1, 'no second send while the first was unresolved')
        self.assertEqual(lending.unresolved(self.state), [])

    def test_unknown_submission_stops_everything(self):
        b, s = FakeBackend([snap()]), FakeSigner(fail=True)
        r = lending.cycle(b, s, self.state, execute=True)
        self.assertEqual(r['status'], 'operator_attention')
        j = json.loads(lending.journal_path(self.state, 1).read_text())
        self.assertEqual(j['attempts'][-1]['state'], 'unknown_submission')

    def test_no_progress_and_revert_stop(self):
        s = FakeSigner(receipts={'0x' + '%064x' % 1: {'status': '0x0'}})
        self.assertEqual(lending.cycle(FakeBackend([snap()]), s, self.state, True)['status'], 'operator_attention')

    def test_read_failures_are_isolated(self):
        class Broken(FakeBackend):
            def discover(self, state):
                raise OSError('rpc reset')
        self.assertEqual(lending.cycle(Broken([snap()]), FakeSigner(), self.state, True)['status'], 'lending_degraded')

        class BrokenSnap(FakeBackend):
            def snapshot(self, account):
                raise OSError('rpc reset')
        self.assertEqual(lending.cycle(BrokenSnap([snap()]), FakeSigner(), self.state, True)['status'], 'lending_degraded')

    def test_spy_closed_cycle_status(self):
        r = lending.cycle(FakeBackend([snap(err=lending.SNAPSHOT_ERROR)]), FakeSigner(), self.state, True)
        self.assertEqual(r['status'], 'spy_closed')

    def test_unsupported_debt_is_reported_not_sent(self):
        s = FakeSigner()
        r = lending.cycle(FakeBackend([snap(debt=0, nvda=0)]), s, self.state, True)
        self.assertEqual(r['status'], 'lending_unsupported_shortfall')
        self.assertEqual(s.sent, [])

    def test_nvda_debt_executes_and_confirms(self):
        b, s = FakeBackend([snap(debt=0, nvda=4 * 10**17), snap(debt=0, nvda=3 * 10**17, shortfall=0)]), FakeSigner()
        r = lending.run(b, s, 1, ALICE, self.state, execute=True)
        self.assertEqual(r['status'], 'healthy')
        j = json.loads(lending.journal_path(self.state, 1).read_text())
        a = j['attempts'][0]
        self.assertEqual((a['state'], a['plan']['kind'], a['beforeDebt'], a['afterDebt']),
                         ('confirmed', 'nvda', 4 * 10**17, 3 * 10**17))

    def test_margin_ignores_lending_journals(self):
        path = lending.journal_path(self.state, 3)
        path.write_text(json.dumps({'positionId': lending.LENDING_ID_BASE + 3, 'account': ALICE,
                                    'attempts': [{'state': 'submitted', 'hash': '0x1'}]}))
        (self.state / 'position-5.json').write_text(json.dumps({'positionId': 5, 'attempts': [{'state': 'intent'}]}))
        self.assertEqual(service.unresolved(self.state), [5])
        self.assertEqual(lending.unresolved(self.state), [lending.LENDING_ID_BASE + 3])

    def test_journal_identity_is_checked(self):
        lending.journal_path(self.state, 1).write_text(json.dumps(
            {'positionId': lending.LENDING_ID_BASE + 1, 'account': '0xother', 'identity': {}, 'attempts': []}))
        with self.assertRaises(RuntimeError):
            lending.run(FakeBackend([snap()]), FakeSigner(), 1, ALICE, self.state, True)

    def test_repay_amount_bounds(self):
        b = lending.LendingBackend.__new__(lending.LendingBackend)
        b.c = dict(CONFIG, maxRepayUsdg=10**12)
        values = {'closeFactorMantissa()': 5 * 10**17, 'liquidationIncentiveMantissa()': 108 * 10**16,
                  'oracle()': 0x99, 'exchangeRateStored()': 2 * 10**26}
        prices = {PSPY: 716 * 10**18, CONFIG['pUSDG']: 10**30}
        b.word = lambda target, sig, *a: [prices[a[0]]] if sig.startswith('getUnderlyingPrice') else [values[sig]]
        # 0.1 SPY (5e8 pSPY units) at $716: seizable value $71.6 / 1.08 ~ $66.3 -> 1 % margin -> 65.6 USDG
        self.assertEqual(b.repay_amount(snap(debt=200_000_000, tokens=5 * 10**8)), 65_633_333)
        self.assertEqual(b.repay_amount(snap(debt=40_000_000, tokens=5 * 10**8)), 20_000_000)  # close factor
        b.c['maxRepayUsdg'] = 1_000_000
        self.assertEqual(b.repay_amount(snap(debt=40_000_000)), 1_000_000)  # configured ceiling
        # NVDA debt at $128.7: seizable 0.1 SPY ($71.6) / 1.08 / $128.7 * 99 % = 0.51 NVDA; close factor on 0.4 NVDA = 0.2
        prices[CONFIG['pNVDA']] = 1287 * 10**17
        p = b.plan(snap(debt=0, nvda=4 * 10**17))
        self.assertEqual(p['kind'], 'nvda')
        self.assertEqual(p['maxRepay'], 2 * 10**17)
        self.assertEqual(p['usdgIn'], 2 * 10**17 * 1287 * 10**17 // 10**18 // 10**12 * 97 // 100)
        self.assertEqual(b.plan(snap(debt=10, nvda=4 * 10**17))['kind'], 'usdg')  # USDG debt first

    def test_config_requires_every_pin(self):
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
            json.dump({k: v for k, v in CONFIG.items() if k != 'delegateRuntimeHash'}, f)
        with self.assertRaises(ValueError):
            lending.load_config(f.name)
        self.assertIsNone(lending.load_config('/nonexistent/keeper.json'))


class WorkerLendingPolicyTests(unittest.TestCase):
    def signer(self):
        m = Mock()
        m.max_gas, m.gas_price, m.url = 12_000_000, 100_000_000, worker.service.RPC
        m.nonce.return_value = 7
        return worker.CloudLendingSigner(m, FakeBackend([snap()])), m

    def test_policy_rejects_wrong_target_data_value_gas(self):
        s, m = self.signer()
        P5 = {'kind': 'usdg', 'repay': 5, 'debtKey': 'debt'}
        good = dict(s.l.transaction(ALICE, P5), gas=hex(3_000_000))
        for bad in [dict(good, to='0x' + 'ee' * 20), dict(good, data='0xdead'), dict(good, value='0x1'),
                    dict(good, gas=hex(12_000_001)), dict(good, **{'from': '0x' + '01' * 20})]:
            with self.assertRaises(ValueError):
                s.submit(bad, 7, lending.LENDING_ID_BASE + 1, ALICE, P5)
        # the repay amount is part of the bound calldata
        with self.assertRaises(ValueError):
            s.submit(good, 7, lending.LENDING_ID_BASE + 1, ALICE, dict(P5, repay=6))
        m.journal.before_send.assert_not_called()

    def test_nvda_plan_calldata_is_bound(self):
        s, m = self.signer()
        plan = {'kind': 'nvda', 'maxRepay': 10**17, 'usdgIn': 12_000_000, 'debtKey': 'nvdaDebt'}
        real = lending.LendingBackend.__new__(lending.LendingBackend)
        real.c, real.sender = CONFIG, worker.KEEPER
        tx = real.transaction(ALICE, plan)
        self.assertEqual(tx['to'], LIQ)
        self.assertTrue(tx['data'].startswith(lending.cast('sig', 'liquidateNvdaDebt(address,uint256,uint256)')))
        s.l = real
        with self.assertRaises(ValueError):  # usdgIn changed after the intent
            s.submit(dict(tx, gas=hex(3_000_000)), 7, lending.LENDING_ID_BASE + 1, ALICE, dict(plan, usdgIn=13_000_000))

    def test_nonce_change_refuses(self):
        s, m = self.signer()
        m.nonce.return_value = 8
        P5 = {'kind': 'usdg', 'repay': 5, 'debtKey': 'debt'}
        good = dict(s.l.transaction(ALICE, P5), gas=hex(3_000_000))
        with self.assertRaises(RuntimeError):
            s.submit(good, 7, lending.LENDING_ID_BASE + 1, ALICE, P5)

    def test_lending_off_by_default_and_never_raises(self):
        with patch.dict('os.environ', {}, clear=False):
            import os
            os.environ.pop('LENDING_LIQUIDATIONS', None)
            self.assertEqual(worker.lending_setup('x'), (None, 'disabled'))
        with patch.dict('os.environ', {'LENDING_LIQUIDATIONS': 'true'}):
            with patch.object(lending, 'load_config', return_value=None):
                self.assertEqual(worker.lending_setup('x'), (None, 'no_config'))
            with patch.object(lending, 'load_config', side_effect=ValueError('x')):
                self.assertEqual(worker.lending_setup('x'), (None, 'ValueError'))

    def test_worker_gates_margin_sends_on_pending_lending(self):
        source = Path(worker.__file__).read_text()
        self.assertIn('execute and funded and not lending_pending', source)


if __name__ == '__main__':
    unittest.main()
