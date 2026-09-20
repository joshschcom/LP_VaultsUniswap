"""Read-only verification of the completed localhost deployment against compiled artifacts."""
import hashlib
import json
from rpc import ROOT, rpc, call, cast, words, address
from preflight import ADDRESSES

URL = 'http://127.0.0.1:8556'
IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'
PROXIES = {
    'config': 'IsolatedMarginConfigUpgradeable', 'executor': 'IsolatedMarginExecutorUpgradeable',
    'liquidator': 'IsolatedMarginLiquidatorUpgradeable', 'riskEngine': 'IsolatedMarginRiskEngineUpgradeable',
    'marginVault': 'IsolatedMarginVaultUpgradeable', 'insuranceFund': 'MarginInsuranceFundUpgradeable',
    'feeDistributor': 'MarginFeeDistributorUpgradeable',
}
DIRECT = {
    'guardedSource': 'GuardedMarginPriceSource', 'router': 'RobinhoodV4RouterAdapter',
    'oracle': 'RobinhoodMarginPriceOracle', 'flashVault': 'SimpleFlashLoanVault',
    'quoter': 'IsolatedMarginQuoter', 'swapModule': 'IsolatedMarginSwapModule',
    'accountFactory': 'IsolatedMarginAccountFactory',
}


def read(target, signature, *args):
    return words(call(target, signature, *args, url=URL))


def verify_code(target, name):
    path = ROOT/'out-margin-mainnet'/(name+'.sol')/(name+'.json')
    artifact = json.loads(path.read_text())
    runtime = artifact['deployedBytecode']
    expected = bytearray.fromhex(runtime['object'].removeprefix('0x'))
    actual_hex = rpc('eth_getCode', [target, 'latest'], URL)
    actual = bytearray.fromhex(actual_hex[2:])
    assert len(actual) == len(expected) and 0 < len(actual) <= 24576, (name, len(actual), len(expected))
    immutable_ranges = [r for refs in runtime.get('immutableReferences', {}).values() for r in refs]
    for r in immutable_ranges:
        start, length = r['start'], r['length']
        actual[start:start+length] = bytes(length)
        expected[start:start+length] = bytes(length)
    metadata_match = actual == expected
    # Separate compilation units can emit different CBOR source metadata while
    # retaining identical executable code. Never ignore executable differences.
    actual_metadata = int.from_bytes(actual[-2:], 'big') + 2
    expected_metadata = int.from_bytes(expected[-2:], 'big') + 2
    assert 2 < actual_metadata < len(actual) and 2 < expected_metadata < len(expected)
    assert actual[:-actual_metadata] == expected[:-expected_metadata], 'Executable runtime mismatch: '+name
    return {'address': target, 'contract': name, 'runtimeBytes': len(actual),
            'eip170HeadroomBytes': 24576-len(actual), 'runtimeCodeHash': cast('keccak', actual_hex),
            'artifactSha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'artifactMatchExcludingImmutables': metadata_match,
            'executableMatchExcludingImmutablesAndCborMetadata': True,
            'deployedCborMetadata': actual_hex[-actual_metadata*2:],
            'compiledCborMetadata': runtime['object'][-expected_metadata*2:],
            'immutableRanges': immutable_ranges}


def immutable_values(target, name):
    artifact = json.loads((ROOT/'out-margin-mainnet'/(name+'.sol')/(name+'.json')).read_text())
    code = bytes.fromhex(rpc('eth_getCode', [target, 'latest'], URL)[2:])
    return {int.from_bytes(code[r['start']:r['start']+r['length']], 'big')
            for refs in artifact['deployedBytecode'].get('immutableReferences', {}).values() for r in refs}


def main(addresses_path=None, pin_path=None, output_path=None, mode='local'):
    assert mode in ('local', 'staged', 'configured', 'active')
    a = json.loads((addresses_path or ROOT/'deployments/robinhood-mainnet.margin-rehearsal-addresses.json').read_text())
    result = {'surface': 'LOCALHOST FORK ONLY; no public-mainnet deployment' if mode == 'local' else 'Read-only deployment verification',
              'rpcURL': URL, 'chainId': 4663, 'mode': mode,
              'pin': json.loads((pin_path or ROOT/'deployments/robinhood-mainnet.margin-pin.json').read_text()),
              'contracts': {}, 'wiring': {}}
    assert int(rpc('eth_chainId', [], URL), 16) == 4663
    for key, name in DIRECT.items():
        result['contracts'][key] = verify_code(a[key], name)
    for key, name in PROXIES.items():
        proxy = a[key]
        implementation = address(int(rpc('eth_getStorageAt', [proxy, IMPL_SLOT, 'latest'], URL), 16))
        admin = address(int(rpc('eth_getStorageAt', [proxy, ADMIN_SLOT, 'latest'], URL), 16))
        owner = address(read(admin, 'owner()')[0])
        assert owner.lower() == a['proxyAdminOwner'].lower()
        assert immutable_values(proxy, 'PeridotTransparentProxy') == {int(admin, 16)}
        result['contracts'][key] = verify_code(proxy, 'PeridotTransparentProxy')
        result['contracts'][key+'Implementation'] = verify_code(implementation, name)
        result['contracts'][key+'Admin'] = dict(verify_code(admin, 'ProxyAdmin'), owner=owner)
    delegate = address(read(a['pUsd'], 'implementation()')[0])
    assert read(a['pStock'], 'implementation()')[0] == int(delegate, 16)
    result['contracts']['replacementDelegate'] = verify_code(delegate, 'RobinhoodBoostedDelegate')
    module_values = immutable_values(delegate, 'RobinhoodBoostedDelegate')
    assert len(module_values) == 1
    module = address(next(iter(module_values)))
    result['contracts']['borrowAccountingModule'] = verify_code(module, 'BorrowAccountingModule')
    assert immutable_values(module, 'BorrowAccountingModule') == {int(module, 16)}
    template = address(read(a['accountFactory'], 'implementation()')[0])
    result['contracts']['accountTemplate'] = verify_code(template, 'IsolatedMarginAccount')
    assert read(template, 'factory()') == [int(a['accountFactory'], 16)]
    assert read(a['guardedSource'], 'pairId()') == [int(cast('keccak', 'NVDA/USDG'), 16)]
    expected = dict(a, **{'owner': a['actor'], 'configurator': a['actor'], 'vault': a['marginVault'],
                         'assetSource': a['guardedSource'], 'lendingSource': a['assetOracle'],
                         'flashLender': a['flashVault'], 'flashLoanProvider': a['flashVault'],
                         'routerAdapter': a['router'], 'treasury': a['actor'],
                         'permit2': ADDRESSES['permit2'], 'manager': a['swapModule'],
                         'implementation': template})
    for key, name in dict(DIRECT, **PROXIES).items():
        artifact = json.loads((ROOT/'out-margin-mainnet'/(name+'.sol')/(name+'.json')).read_text())
        for f in artifact['abi']:
            if f.get('type') != 'function' or f['inputs'] or [o['type'] for o in f['outputs']] != ['address']:
                continue
            getter = f['name']
            want = ADDRESSES['universalRouter'] if key == 'router' and getter == 'router' else expected[getter]
            got = address(read(a[key], getter+'()')[0])
            assert got.lower() == want.lower(), (key, getter, got, want)
            result['wiring'][key+'.'+getter] = got
    for getter in ['isolatedMarginRiskHook()', 'isolatedMarginRegistrar()']:
        assert read(a['controller'], getter)[0] == int(a['riskEngine'], 16)
    risk = [1,200,5000,2500,12500,5000,5000,500,100,100,2*10**18,10**18]
    if mode != 'staged':
        for position, debt in [('pStock','pUsd'), ('pUsd','pStock')]:
            assert read(a['config'], 'getPairRisk(address,address,address)', a['pUsd'],a[position],a[debt]) == risk
    debt_free = True
    for market in ['pUsd', 'pStock']:
        assert read(a[market], 'borrowAccountingEnabled()') == [1]
        debt_free &= read(a[market], 'totalBorrows()') == [0] and read(a[market], 'totalBorrowShares()') == [0]
    paused = mode != 'active'
    assert read(a['config'], 'opensPaused()') == read(a['flashVault'], 'paused()') == [int(paused)]
    margin_free = all(read(a['marginVault'], getter, a['actor'], a['pUsd']) == [0]
                      for getter in ['freeBalance(address,address)', 'lockedBalance(address,address)'])
    if mode == 'local':
        assert debt_free and margin_free
    result.update(status='passed', exactCanaryRiskBothDirections=risk if mode != 'staged' else None,
                  zeroDebtAndBorrowShares=debt_free, zeroFreeAndLockedMargin=margin_free, opensAndFlashPaused=paused)
    path = output_path or ROOT/'deployments/robinhood-mainnet.margin-runtime-verification.json'
    path.write_text(json.dumps(result, indent=2)+'\n')
    print('Verified',len(result['contracts']),'runtimes and',len(result['wiring']),'address getters at',URL)
    return result


if __name__ == '__main__':
    main()
