"""Read-only JSON-RPC helpers. Signing and transaction submission are deliberately absent."""
import json
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RPC = 'https://rpc.mainnet.chain.robinhood.com'
READ_METHODS = {'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_call',
                'eth_getCode', 'eth_getStorageAt', 'eth_getBalance', 'eth_getTransactionCount',
                'eth_getTransactionReceipt', 'eth_getTransactionByHash', 'eth_estimateGas', 'eth_getLogs'}


def rpc(method, params, url=RPC):
    if method not in READ_METHODS:
        raise ValueError('Read-only RPC helper')
    request = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1,
                                    'method': method, 'params': params}).encode(),
                                    headers={'Content-Type': 'application/json', 'User-Agent': 'curl/8.0'})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
            if 'error' in result:
                raise RuntimeError(result['error'])
            return result['result']
        except (OSError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def cast(*args):
    return subprocess.check_output(['cast', *map(str, args)], text=True).strip()


def call(target, signature, *args, block='latest', url=RPC, sender=None):
    transaction = {'to': target, 'data': cast('calldata', signature, *args)}
    if sender:
        transaction['from'] = sender
    return rpc('eth_call', [transaction, block], url)


def words(value):
    value = value.removeprefix('0x')
    assert len(value) % 64 == 0
    return [int(value[i:i+64], 16) for i in range(0, len(value), 64)]


def address(value):
    return '0x' + format(value, '040x')
