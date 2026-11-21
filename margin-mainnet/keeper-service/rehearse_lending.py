"""Loopback-only rehearsal driver for lending.py (anvil fork with --auto-impersonate). Never signs; never mainnet.

  python3 margin-mainnet/keeper-service/rehearse_lending.py --rpc-url http://127.0.0.1:PORT --config keeper.json \
      --state DIR --sender 0x... [--execute]
"""
import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lending  # noqa: E402
from keeper import loopback  # noqa: E402
from rpc import rpc  # noqa: E402


class LoopbackSigner:
    def __init__(self, url, sender):
        if not loopback(url):
            raise ValueError('Rehearsal signer is loopback only')
        self.url, self.sender = url, sender

    def nonce(self):
        return int(rpc('eth_getTransactionCount', [self.sender, 'latest'], self.url), 16)

    def submit(self, tx, nonce, journal_id, account, plan):
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'eth_sendTransaction',
                           'params': [dict(tx, nonce=hex(nonce), value='0x0')]}).encode()
        req = urllib.request.Request(self.url, body, headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=60) as r:
            result = json.load(r)
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['result']

    def receipt(self, tx_hash, journal_id):
        for _ in range(20):
            receipt = rpc('eth_getTransactionReceipt', [tx_hash], self.url)
            if receipt:
                return receipt
            time.sleep(0.5)
        return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rpc-url', required=True)
    p.add_argument('--config', required=True)
    p.add_argument('--state', required=True)
    p.add_argument('--sender', required=True)
    p.add_argument('--execute', action='store_true')
    a = p.parse_args()
    if not loopback(a.rpc_url):
        p.error('loopback RPC only')
    Path(a.state).mkdir(parents=True, exist_ok=True)
    backend = lending.LendingBackend(a.rpc_url, lending.load_config(a.config), a.sender)
    result = lending.cycle(backend, LoopbackSigner(a.rpc_url, a.sender), a.state, a.execute)
    for path in sorted(Path(a.state).glob('position-*.json')):
        j = json.loads(path.read_text())
        for at in j['attempts']:
            if at.get('hash'):
                r = rpc('eth_getTransactionReceipt', [at['hash']], a.rpc_url)
                at['gasUsed'] = int(r['gasUsed'], 16) if r else None
        result.setdefault('journals', []).append({'positionId': j['positionId'], 'account': j['account'],
                                                  'attempts': [{k: at.get(k) for k in ('state', 'plan', 'beforeDebt', 'afterDebt', 'gasUsed')} for at in j['attempts']]})
    print(json.dumps(result, indent=1, default=str))


if __name__ == '__main__':
    main()
