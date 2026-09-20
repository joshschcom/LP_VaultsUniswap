"""Enumerate Borrow events and reconcile every historical borrower at the pin."""
import concurrent.futures
import hashlib
import json
from rpc import ROOT, RPC, rpc, call, cast, words, address
from preflight import ADDRESSES


def main(pin_path=None, output_path=None, url=RPC):
    pin = json.loads((pin_path or ROOT/'deployments/robinhood-mainnet.margin-pin.json').read_text())
    assert int(rpc('eth_chainId', [], url), 16) == pin['chainId'] == 4663
    assert rpc('eth_getBlockByNumber', [hex(pin['stateBlock']), False], url)['hash'] == pin['blockHash']
    start, end = 54976765, pin['stateBlock']
    topic = cast('keccak', 'Borrow(address,uint256,uint256,uint256)')
    ranges = [(lo, min(lo+499999, end)) for lo in range(start, end+1, 500000)]
    def logs(bounds):
        lo, hi = bounds
        return rpc('eth_getLogs', [{'fromBlock': hex(lo), 'toBlock': hex(hi),
                   'address': [ADDRESSES['pUsd'], ADDRESSES['pStock']], 'topics': [topic]}], url)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        entries = [entry for batch in pool.map(logs, ranges) for entry in batch]
    borrowers = {}
    for name in ['pUsd', 'pStock']:
        market = ADDRESSES[name]
        accounts = sorted({address(words(log['data'])[0]) for log in entries if log['address'].lower() == market.lower()})
        borrowers[name] = [{'address': account,
                            'debt': words(call(market, 'borrowBalanceStored(address)', account, block=hex(end), url=url))[0]}
                           for account in accounts]
    result = {'chainId': 4663, 'fromBlock': start, 'throughBlock': end, 'blockHash': pin['blockHash'],
              'queriedRanges': ranges, 'borrowEventCount': len(entries), 'borrowers': borrowers,
              'allHistoricalBorrowersDebtFree': all(b['debt'] == 0 for group in borrowers.values() for b in group),
              'postPauseSnapshot': all(words(call(ADDRESSES['controller'], 'borrowGuardianPaused(address)', ADDRESSES[m], block=hex(end), url=url))[0] == 1 for m in ['pUsd', 'pStock']),
              'note': 'Re-enumerate through confirmed pause receipts before any mainnet migration; this is a pinned rehearsal snapshot.'}
    path = output_path or ROOT/'deployments/robinhood-mainnet.margin-borrower-history.json'
    path.write_text(json.dumps(result, indent=2)+'\n')
    path.with_suffix('.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n')
    if output_path is None:
        print(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    main()
