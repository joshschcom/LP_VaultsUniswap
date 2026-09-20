"""Capture live dependencies at one pinned mainnet block; never changes chain state."""
import concurrent.futures
import hashlib
import json
from rpc import ROOT, rpc, call, cast, words, address

ADDRESSES = {
    'actor': '0x94696d767e65a75581145646960FA0eC886cE5d2',
    'usd': '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
    'stock': '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',
    'pUsd': '0x55aed0569c8f0d166d71face57b57c2f2624a563',
    'pStock': '0xa155cccb986774ae818b3f10f07d01d1b7a47b26',
    'controller': '0x6148183676e304dbe63a85c350c208da3ceac39c',
    'assetOracle': '0x266f014d1325774f1190f963df4369e07dda1d33',
    'feed': '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15',
    'boostedVault': '0x280825b2d856706Ff7E0d6351CcB2e935E1a9A2f',
    'pairedAdapter': '0xadA73211711e4790bc83B5d6B39f47fE04D276f3',
    'guard': '0xaE4D4DdB8dD646951d54fE9B13BE23DcB61C6741',
    'timelock': '0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498',
    'poolManager': '0x8366a39CC670B4001A1121B8F6A443A643e40951',
    'universalRouter': '0x8876789976dEcBfCbBbe364623C63652db8C0904',
    'permit2': '0x000000000022D473030F116dDEE9F6B43aC78BA3',
}


def main():
    pin = json.loads((ROOT/'deployments/robinhood-mainnet.margin-pin.json').read_text())
    assert int(rpc('eth_chainId', []), 16) == pin['chainId'] == 4663
    block = hex(pin['stateBlock'])
    header = rpc('eth_getBlockByNumber', [block, False])
    assert header['hash'] == pin['blockHash']
    pair = cast('keccak', 'NVDA/USDG')
    jobs = {}
    for market in ['pUsd', 'pStock']:
        for method in ['underlying', 'implementation', 'admin', 'getCash', 'totalBorrows',
                       'totalBorrowShares', 'borrowAccountingEnabled', 'accrualBlockNumber',
                       'exchangeRateStored', 'totalSupply', 'vaultAccountedAssets', 'robinhoodVault']:
            jobs[market+'.'+method] = (market, method+'()', [])
        jobs[market+'.actorShares'] = (market, 'balanceOf(address)', [ADDRESSES['actor']])
        jobs[market+'.borrowPaused'] = ('controller', 'borrowGuardianPaused(address)', [ADDRESSES[market]])
        jobs[market+'.borrowCap'] = ('controller', 'borrowCaps(address)', [ADDRESSES[market]])
    for method in ['admin', 'peridottrollerImplementation', 'isolatedMarginRiskHook', 'isolatedMarginRegistrar', 'oracle']:
        jobs['controller.'+method] = ('controller', method+'()', [])
    for method in ['stockChainlinkPriceStaleThreshold', 'chainlinkPriceStaleThreshold']:
        jobs['assetOracle.'+method] = ('assetOracle', method+'()', [])
    for token in ['stock', 'usd']:
        for method in ['assetPrices', 'lastValidChainlinkPrice', 'isPriceStale', 'assetToAggregator']:
            jobs['assetOracle.'+token+'.'+method] = ('assetOracle', method+'(address)', [ADDRESSES[token]])
        jobs[token+'.actorBalance'] = (token, 'balanceOf(address)', [ADDRESSES['actor']])
    jobs.update({
        'stock.oraclePaused': ('stock', 'oraclePaused()', []),
        'feed.round': ('feed', 'latestRoundData()', []),
        'feed.decimals': ('feed', 'decimals()', []),
        'guard.prices': ('guard', 'pricesUSD18(bytes32)', [pair]),
        'guard.config': ('guard', 'feedConfig(bytes32)', [pair]),
        'boostedVault.ledger': ('boostedVault', 'ledger(bytes32)', [pair]),
        'boostedVault.config': ('boostedVault', 'pairConfig(bytes32)', [pair]),
        'pairedAdapter.position': ('pairedAdapter', 'positionState(bytes32)', [pair]),
        'pairedAdapter.poolKey': ('pairedAdapter', 'poolKey(bytes32)', [pair]),
    })
    def read(job):
        key, (target, signature, args) = job
        try:
            result = words(call(ADDRESSES[target], signature, *args, block=block))
            return key, {'values': result}
        except Exception as error:
            return key, {'error': str(error)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        reads = dict(pool.map(read, jobs.items()))
    contracts = {}
    for name, target in ADDRESSES.items():
        if name == 'actor':
            continue
        code = rpc('eth_getCode', [target, block])
        contracts[name] = {'address': target, 'codeHash': cast('keccak', code), 'runtimeBytes': (len(code)-2)//2}
        assert code != '0x', name
    for name, read_key in [('marketImplementation', 'pUsd.implementation'),
                           ('controllerImplementation', 'controller.peridottrollerImplementation')]:
        target = address(reads[read_key]['values'][0])
        code = rpc('eth_getCode', [target, block])
        contracts[name] = {'address': target, 'codeHash': cast('keccak', code), 'runtimeBytes': (len(code)-2)//2}
    pool_id = reads['guard.config']['values'][5]
    slot = cast('keccak', '0x'+format(pool_id, '064x')+format(6, '064x'))
    slot0 = words(call(ADDRESSES['poolManager'], 'extsload(bytes32)', slot, block=block))[0]
    sqrt_price = slot0 & ((1 << 160)-1)
    usd_per_stock = (1 << 192)*10**12 / sqrt_price**2
    gates = {}
    for market in ['pUsd', 'pStock']:
        gates[market+'.borrowAccountingEnabled'] = reads[market+'.borrowAccountingEnabled'].get('values') == [1]
        gates[market+'.nativeClock'] = reads[market+'.accrualBlockNumber'].get('values', [2**256])[0] <= pin['nativeEvmBlockNumber']
    result = {**pin, 'surface': 'read-only public-mainnet snapshot', 'addresses': ADDRESSES,
              'pairId': pair, 'contracts': contracts, 'reads': reads, 'gates': gates,
              'pool': {'sqrtPriceX96': sqrt_price, 'usdPerStock': usd_per_stock},
              'actorNonce': int(rpc('eth_getTransactionCount', [ADDRESSES['actor'], block]), 16)}
    path = ROOT/'deployments/robinhood-mainnet.margin-preflight.json'
    path.write_text(json.dumps(result, indent=2)+'\n')
    path.with_suffix('.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n')
    print(json.dumps({'pin': pin, 'reads': reads}, indent=2))


if __name__ == '__main__':
    main()
