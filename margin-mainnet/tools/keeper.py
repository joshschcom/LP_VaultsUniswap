"""Native-RPC liquidation planner; execution is restricted to an unlocked loopback fork.

The execution journal is written before submission. Ambiguous sends, pending receipts,
reverts and no-progress outcomes stop the loop; they are never blindly retried.
"""
import argparse
import fcntl
import json
import os
import time
import urllib.parse
import urllib.request
from pathlib import Path
from rpc import RPC, call, cast, rpc, words, address


def loopback(url):
    parsed = urllib.parse.urlparse(url)
    return parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', '::1') and not parsed.username


def persist(path, value):
    path = Path(path)
    temp = path.with_suffix(path.suffix+'.tmp')
    temp.write_text(json.dumps(value, indent=2)+'\n')
    os.replace(temp, path)


class RpcBackend:
    def __init__(self, url, addresses, sender):
        self.url, self.a, self.sender = url, addresses, sender
        self.identity = {'chainId': 4663, 'rpc': url, 'executor': addresses['executor'].lower(),
                         'liquidator': addresses['liquidator'].lower(), 'sender': sender.lower()}
        assert int(rpc('eth_chainId', [], url), 16) == addresses['chainId'] == 4663
        for key in ['executor', 'liquidator', 'riskEngine', 'oracle']:
            assert rpc('eth_getCode', [addresses[key], 'latest'], url) != '0x', 'Missing '+key
        self.read('executor', 'riskEngine()', expected=addresses['riskEngine'])
        self.read('liquidator', 'executor()', expected=addresses['executor'])
        self.read('liquidator', 'riskEngine()', expected=addresses['riskEngine'])

    def read(self, target, signature, *args, expected=None):
        result = words(call(self.a.get(target, target), signature, *args, url=self.url))
        if expected is not None:
            assert result[0] == int(expected, 16), 'Wiring mismatch'
        return result

    def snapshot(self, position_id):
        p = self.read('executor', 'positions(uint256)', position_id)
        assert p[0] == position_id and len(p) == 12, 'Unknown position'
        account, debt_market = address(p[2]), address(p[5])
        # Current native-node accrual, not the stored debt shown by getMetrics.
        debt = self.read(debt_market, 'borrowBalanceCurrent(address)', account)[0]
        fresh = all(self.read('oracle', 'marketPriceable(address)', address(p[i]))[0] == 1 for i in (3,4,5))
        return {'positionId': position_id, 'status': p[11], 'account': account,
                'debt': debt, 'fresh': fresh, 'block': int(rpc('eth_blockNumber', [], self.url), 16)}

    def transaction(self, position_id):
        data = cast('calldata', 'liquidate((uint256,address,uint256,uint256,bytes,bytes))',
                    f'({position_id},{self.sender},0,0,0x,0x)')
        return {'from': self.sender, 'to': self.a['liquidator'], 'data': data}

    def simulate(self, position_id):
        # Simulate every ACTIVE position even if stored metrics look healthy:
        # interest accrued inside liquidate can cross the maintenance threshold.
        tx = self.transaction(position_id)
        rpc('eth_call', [tx, 'latest'], self.url)
        gas = int(rpc('eth_estimateGas', [tx], self.url), 16)
        tx['gas'] = hex(gas * 3)
        return tx

    def nonce(self):
        latest = int(rpc('eth_getTransactionCount', [self.sender, 'latest'], self.url), 16)
        pending = int(rpc('eth_getTransactionCount', [self.sender, 'pending'], self.url), 16)
        assert latest == pending, 'Pending sender transaction: reconcile first'
        return latest

    def submit(self, transaction, nonce):
        if not loopback(self.url):
            raise ValueError('Execution is supported only on an isolated loopback fork')
        tx = dict(transaction, nonce=hex(nonce))
        request = urllib.request.Request(self.url, json.dumps({'jsonrpc':'2.0','id':1,
                                        'method':'eth_sendTransaction','params':[tx]}).encode(),
                                        headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['result']

    def receipt(self, transaction_hash):
        # Return promptly. A later invocation reconciles the same hash first.
        for _ in range(10):
            receipt = rpc('eth_getTransactionReceipt', [transaction_hash], self.url)
            if receipt:
                return receipt
            time.sleep(0.5)
        return None


def run(backend, position_id, journal_path, execute=False, max_calls=8):
    assert 1 <= max_calls <= 8
    path = Path(journal_path)
    journal = json.loads(path.read_text()) if path.exists() else {'positionId': position_id, 'identity': backend.identity, 'attempts': []}
    assert journal['positionId'] == position_id
    assert journal['identity'] == backend.identity, 'Journal belongs to another deployment or signer'
    attempts = journal['attempts']
    # Persisted unresolved states require receipt reconciliation before another quote/send.
    if attempts and attempts[-1]['state'] != 'confirmed':
        previous = attempts[-1]
        if not previous.get('hash'):
            return {'status': 'reconcile_unknown_submission', 'journal': journal}
        receipt = backend.receipt(previous['hash'])
        if not receipt:
            return {'status': 'pending', 'journal': journal}
        if int(receipt['status'], 16) != 1:
            previous['state'] = 'reverted'
            persist(path, journal)
            return {'status': 'reverted_stop', 'journal': journal}
        after = backend.snapshot(position_id)
        if after['debt'] >= previous['beforeDebt'] and after['debt'] != 0:
            return {'status': 'no_progress_stop', 'journal': journal}
        previous.update(state='confirmed', receipt=receipt, afterDebt=after['debt'])
        persist(path, journal)
    for _ in range(max_calls):
        state = backend.snapshot(position_id)
        if state['status'] in (5,6) or state['debt'] == 0:
            return {'status': 'resolved', 'snapshot': state, 'journal': journal}
        if state['status'] != 2:
            return {'status': 'transition_stop', 'snapshot': state}
        if not state['fresh']:
            return {'status': 'stale_or_unavailable_stop', 'snapshot': state}
        try:
            transaction = backend.simulate(position_id)
        except Exception as error:
            return {'status': 'not_executable_stop', 'reason': str(error), 'snapshot': state, 'journal': journal}
        if not execute:
            return {'status': 'executable_plan', 'transaction': transaction, 'snapshot': state}
        nonce = backend.nonce()
        attempt = {'state': 'intent', 'nonce': nonce, 'beforeDebt': state['debt'], 'transaction': transaction}
        attempts.append(attempt)
        persist(path, journal)
        try:
            attempt['hash'] = backend.submit(transaction, nonce)
            attempt['state'] = 'submitted'
            persist(path, journal)
        except Exception as error:
            attempt.update(state='unknown_submission', error=str(error))
            persist(path, journal)
            return {'status': 'reconcile_unknown_submission', 'journal': journal}
        receipt = backend.receipt(attempt['hash'])
        if not receipt:
            return {'status': 'pending', 'journal': journal}
        attempt['receipt'] = receipt
        if int(receipt['status'], 16) != 1:
            attempt['state'] = 'reverted'
            persist(path, journal)
            return {'status': 'reverted_stop', 'journal': journal}
        after = backend.snapshot(position_id)
        if after['debt'] >= state['debt'] and after['debt'] != 0:
            attempt['state'] = 'no_progress'
            persist(path, journal)
            return {'status': 'no_progress_stop', 'journal': journal}
        attempt.update(state='confirmed', afterDebt=after['debt'])
        persist(path, journal)
        # Re-read, re-simulate and choose the next nonce after the mined receipt.
    return {'status': 'call_budget_stop', 'journal': journal}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc-url', default=RPC)
    parser.add_argument('--addresses', required=True)
    parser.add_argument('--position', required=True, type=int)
    parser.add_argument('--sender', required=True)
    parser.add_argument('--journal', required=True)
    parser.add_argument('--execute-local', action='store_true')
    args = parser.parse_args()
    if args.execute_local and not loopback(args.rpc_url):
        parser.error('--execute-local requires an isolated loopback RPC')
    backend = RpcBackend(args.rpc_url, json.loads(Path(args.addresses).read_text()), args.sender)
    lock = Path(args.journal).parent / ('keeper-'+args.sender.lower()+'.lock')
    with lock.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(json.dumps(run(backend, args.position, args.journal, args.execute_local), indent=2))


if __name__ == '__main__':
    main()
