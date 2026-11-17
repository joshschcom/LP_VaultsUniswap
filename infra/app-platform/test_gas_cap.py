"""Gas-cap policy for the cloud keeper: 3x eth_estimateGas must fit a SPY long liquidation and still be capped.

Run: cd infra/app-platform && python3 -m unittest test_gas_cap  (no network, no secrets; psycopg is stubbed)
"""
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.modules.setdefault('psycopg', types.ModuleType('psycopg'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import worker  # noqa: E402

SPY_ESTIMATE = 2_824_983  # fork 2026-11-17, SPY long liquidation via the live liquidator (gasUsed 2,221,845)
NVDA_ESTIMATE = 2_456_452  # fork 2026-11-17, NVDA long liquidation


def backend():
    b = worker.CloudBackend.__new__(worker.CloudBackend)
    b.max_gas, b.gas_price, b.url = 12_000_000, 100_000_000, worker.service.RPC
    b.position_id, b.journal, b.nonce = 7, Mock(), (lambda: 3)
    b.transaction = lambda _: {'from': worker.KEEPER, 'to': worker.service.LIQUIDATOR, 'data': '0x1234'}
    return b


class GasCapTests(unittest.TestCase):
    def test_constructor_cap_is_twelve_million(self):
        source = Path(worker.__file__).read_text()
        self.assertIn('self.max_gas = 12_000_000', source)

    def _simulate(self, estimate):
        tx = {'from': worker.KEEPER, 'to': worker.service.LIQUIDATOR, 'data': '0x1234', 'gas': hex(estimate * 3)}
        with patch.object(worker.keeper.RpcBackend, 'simulate', return_value=dict(tx)):
            return worker.CloudBackend.simulate(backend(), 7)

    def test_spy_and_nvda_liquidations_fit(self):
        for estimate in (SPY_ESTIMATE, NVDA_ESTIMATE):
            self.assertEqual(int(self._simulate(estimate)['gas'], 16), estimate * 3)

    def test_estimate_above_four_million_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'exceeds configured keeper cap'):
            self._simulate(4_000_001)

    def test_submit_refuses_limit_above_cap(self):
        b = backend()
        tx = dict(b.transaction(7), value='0x0', gas=hex(12_000_001))
        with self.assertRaisesRegex(ValueError, 'liquidation policy'):
            b.submit(tx, 3)
        b.journal.before_send.assert_not_called()

    def test_funding_threshold_is_one_capped_call(self):
        self.assertEqual(backend().max_gas * backend().gas_price, 1_200_000_000_000_000)  # 0.0012 ETH


if __name__ == '__main__':
    unittest.main()
