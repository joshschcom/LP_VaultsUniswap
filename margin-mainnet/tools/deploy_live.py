"""User-operated Foundry deployment. Password entry belongs exclusively to Foundry.

Default is read-only status. --broadcast advances all immediately available
stages, then exits at governance delays. Re-run the same command later.
An interrupted phase must be reconciled; transactions are never blindly replayed.
"""
import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
from rpc import ROOT, RPC, rpc, call, cast, words, address
from preflight import ADDRESSES as A
import borrower_history
import verify_local

ACTOR = A['actor']
SCRIPT = 'margin-mainnet/script/DeployRobinhoodMainnetMargin.s.sol:DeployRobinhoodMainnetMargin'
STAGES = [('pause', 'pauseBorrowing()', 2), ('migrate', 'migrateMarkets()', 5),
          ('resume-lending', 'resumeBorrowing()', 2), ('deploy', 'deployPaused()', 42),
          ('configure', 'configureAndQueue()', 11), ('activate', 'activate()', 4)]


def number(value):
    return int(value, 16) if isinstance(value, str) and value.startswith('0x') else int(value)


def save(path, data):
    path = Path(path)
    temp = path.with_suffix(path.suffix+'.tmp')
    temp.write_text(json.dumps(data, indent=2)+'\n')
    os.replace(temp, path)
    path.with_suffix('.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n')


def check_receipts(data, fetch, expected_count, nonce):
    txs = data['transactions']
    if len(txs) != expected_count:
        raise RuntimeError('Unexpected transaction count; inspect the complete phase before proceeding')
    receipts = []
    for index, planned in enumerate(txs):
        tx_hash = planned.get('hash')
        if not tx_hash:
            raise RuntimeError('Unsent or ambiguous transaction: do not replay this phase')
        receipt = fetch('eth_getTransactionReceipt', [tx_hash])
        sent = fetch('eth_getTransactionByHash', [tx_hash])
        if not receipt or not sent or number(receipt['status']) != 1:
            raise RuntimeError('Missing/pending/reverted receipt: '+tx_hash)
        expected = planned['transaction']
        if (sent['from'].lower() != ACTOR.lower() or number(sent['nonce']) != nonce+index
                or number(sent['chainId']) != 4663
                or (sent.get('to') or '').lower() != (expected.get('to') or '').lower()
                or sent['input'].lower() != expected.get('input', expected.get('data', '0x')).lower()
                or number(sent['value']) != number(expected.get('value', 0))):
            raise RuntimeError('Receipt transaction differs from the planned sender/nonce/chain/call')
        canonical = fetch('eth_getBlockByNumber', [receipt['blockNumber'], False])
        if canonical['hash'] != receipt['blockHash']:
            raise RuntimeError('Receipt is no longer canonical; reconcile before proceeding')
        if planned.get('contractAddress') and expected.get('to') is None:
            if (receipt.get('contractAddress') or '').lower() != planned['contractAddress'].lower():
                raise RuntimeError('CREATE receipt differs from the simulated contract address')
        receipts.append(receipt)
    return receipts


class Deployment:
    def __init__(self, args):
        self.args = args
        self.url = args.rpc_url
        self.path = (ROOT/args.state_dir).resolve()
        if not self.path.is_relative_to(ROOT/'deployments'):
            raise ValueError('State directory must be inside this repository\'s deployments directory')
        local = urlparse(self.url).hostname in ('127.0.0.1', '::1') and urlparse(self.url).scheme == 'http'
        if args.local_rehearsal:
            if not local or args.state_dir == 'deployments/margin-mainnet-live':
                raise ValueError('Local rehearsal requires loopback RPC and a separate state directory')
        elif self.url.rstrip('/') != RPC:
            raise ValueError('Live runner is pinned to the Robinhood mainnet RPC')
        self.path.mkdir(parents=True, exist_ok=True)
        self.journal_path = self.path/'progress.json'
        self.record = self.path/'addresses.json'
        self.pin = self.path/'pin.json'
        self.history = self.path/'borrower-history.json'
        self.identity = {'chainId':4663, 'rpc':self.url, 'actor':ACTOR, 'account':args.account,
                         'localRehearsal':args.local_rehearsal}
        self.journal = json.loads(self.journal_path.read_text()) if self.journal_path.exists() else {
            'identity':self.identity, 'completed':[], 'pending':None, 'finalTarget':'ACTIVE_2X',
            'productionKeeperInstalledByRunner':False}
        if self.journal['identity'] != self.identity:
            raise RuntimeError('Journal belongs to a different RPC, signer account or execution surface')

    def fetch(self, method, params):
        return rpc(method, params, self.url)

    def read(self, target, signature, *args, block='latest'):
        return words(call(A.get(target, target), signature, *args, block=block, url=self.url))

    def persist(self):
        save(self.journal_path, self.journal)

    def refresh_pin(self):
        b = self.fetch('eth_getBlockByNumber', ['latest', False])
        if self.args.local_rehearsal:
            native = number(self.fetch('eth_call', [{'to':A['usd'], 'data':'0x'}, 'latest',
                {A['usd']:{'code':'0x4360005260206000f3'}}]))
        else:
            native = number(b['l1BlockNumber'])
        pin = {'chainId':4663,'rpc':self.url,'stateBlock':number(b['number']),
               'nativeEvmBlockNumber':native,'timestamp':number(b['timestamp']),'blockHash':b['hash']}
        save(self.pin, pin)
        return pin

    def check_identity(self):
        if number(self.fetch('eth_chainId', [])) != 4663:
            raise RuntimeError('Wrong chain')
        for target in ['pUsd','pStock','controller']:
            if self.read(target, 'admin()') != [int(ACTOR, 16)]:
                raise RuntimeError('Governor changed: '+target)
        for market, asset in [('pUsd','usd'), ('pStock','stock')]:
            if self.read(market, 'underlying()') != [int(A[asset], 16)]:
                raise RuntimeError('Market identity changed')
        if self.read('controller', 'oracle()') != [int(A['assetOracle'], 16)]:
            raise RuntimeError('Lending oracle changed')

    def funding(self):
        usd = self.read('usd', 'balanceOf(address)', ACTOR)[0]
        stock = self.read('stock', 'balanceOf(address)', ACTOR)[0]
        gas = number(self.fetch('eth_getBalance', [ACTOR, 'latest']))
        print(f'Deployer: {usd/10**6:.6f} USDG, {stock/10**18:.18f} NVDA, {gas/10**18:.8f} ETH')
        if usd < 2*10**6 or stock < 10**16 or gas == 0:
            raise RuntimeError('Fund 2 USDG + 0.01 NVDA and ETH gas before beginning')
        if self.read('pUsd', 'balanceOf(address)', ACTOR)[0] * self.read('pUsd','exchangeRateStored()')[0] <= 10**24:
            raise RuntimeError('Insufficient pUSDG seed shares for $1 insurance plus retained seed')

    def source_digest(self):
        artifact = ROOT/'out-margin-mainnet/DeployRobinhoodMainnetMargin.s.sol/DeployRobinhoodMainnetMargin.json'
        metadata = json.loads(artifact.read_text())['metadata']
        paths = {ROOT/p for p in metadata['sources']}
        paths.update(Path(__file__).parent.glob('*.py'))
        paths.add(ROOT/'foundry.toml')
        return hashlib.sha256(''.join(str(p)+hashlib.sha256(p.read_bytes()).hexdigest()
                                      for p in sorted(paths)).encode()).hexdigest()

    def verify_migration(self):
        implementations = [self.read(m,'implementation()')[0] for m in ['pUsd','pStock']]
        if len(set(implementations)) != 1:
            raise RuntimeError('Markets use different implementations')
        target = address(implementations[0])
        verify_local.URL = self.url
        code = verify_local.verify_code(target, 'RobinhoodBoostedDelegate')
        for m in ['pUsd','pStock']:
            if self.read(m,'borrowAccountingEnabled()') != [1]:
                raise RuntimeError('Borrower accounting migration incomplete')
        return code

    def verify_stack(self, mode):
        verify_local.URL = self.url
        result = verify_local.main(self.record, self.pin, self.path/(mode+'-verification.json'), mode)
        save(self.path/(mode+'-verification.json'), result)
        return result

    def postconditions(self, stage, receipts):
        if stage in ('pause','migrate'):
            for m in ['pUsd','pStock']:
                if self.read('controller','borrowGuardianPaused(address)',A[m]) != [1]:
                    raise RuntimeError('Both borrow gates must remain paused during migration')
                if self.read(m,'totalBorrows()') != [0]:
                    raise RuntimeError('Unexpected market debt')
        if stage == 'migrate':
            self.verify_migration()
        if stage == 'resume-lending':
            self.verify_migration()
            if any(self.read('controller','borrowGuardianPaused(address)',A[m]) != [0] for m in ['pUsd','pStock']):
                raise RuntimeError('Ordinary lending not fully restored')
        if stage in ('deploy','configure','activate'):
            if not self.record.exists():
                raise RuntimeError('Missing address record; reconstruct from creation receipts')
            a = json.loads(self.record.read_text())
            if stage == 'deploy':
                created = {(r.get('contractAddress') or '').lower() for r in receipts}
                if not all(a[k].lower() in created for k in list(verify_local.DIRECT)+list(verify_local.PROXIES)):
                    raise RuntimeError('Address record not backed by this deployment\'s creation receipts')
            self.verify_stack({'deploy':'staged','configure':'configured','activate':'active'}[stage])
            if stage == 'deploy':
                a['status'] = 'RECEIPT_AND_RUNTIME_VERIFIED_LOCAL' if self.args.local_rehearsal else 'RECEIPT_AND_RUNTIME_VERIFIED_MAINNET'
                a['deploymentTransactions'] = [r['transactionHash'] for r in receipts]
                save(self.record, a)
            if stage == 'configure':
                if (self.read('usd','balanceOf(address)',a['flashVault'])[0] < 2*10**6
                    or self.read('stock','balanceOf(address)',a['flashVault'])[0] < 10**16
                    or self.read('pUsd','balanceOf(address)',a['insuranceFund'])[0] == 0):
                    raise RuntimeError('Reserve funding incomplete')
            if stage == 'activate':
                if any(self.read('controller','borrowGuardianPaused(address)',A[m]) != [0] for m in ['pUsd','pStock']):
                    raise RuntimeError('Ordinary lending is paused')

    def reconcile(self):
        pending = self.journal['pending']
        if not pending:
            return
        artifact = Path(pending['broadcastFile'])
        if not artifact.exists():
            raise RuntimeError('No broadcast record. Inspect signer nonce and chain state; do not replay the phase.')
        data = json.loads(artifact.read_text())
        receipts = check_receipts(data, self.fetch, pending['expectedTransactions'], pending['nonce'])
        self.postconditions(pending['stage'], receipts)
        completed = dict(pending, receipts=receipts)
        self.journal['completed'].append(completed)
        self.journal['pending'] = None
        save(self.path/(pending['stage']+'-receipts.json'), {'transactions':data['transactions'], 'receipts':receipts})
        self.persist()

    def ready_at(self, stage):
        a = json.loads(self.record.read_text())
        if stage == 'configure':
            # Both queued risk transactions are mined before the last deploy receipt.
            # Its timestamp + delay is a conservative lower bound for running this phase.
            deploy = next(p for p in self.journal['completed'] if p['stage']=='deploy')
            last = deploy['receipts'][-1]
            b = self.fetch('eth_getBlockByNumber', [last['blockNumber'], False])
            return number(b['timestamp']) + self.read(a['config'],'actionDelay()')[0] + 1
        return self.read(a['config'],'queuedActions(bytes32)',cast('keccak','unpauseOpens'))[0]

    def run_stage(self, stage, signature, count):
        self.check_identity()
        nonce = number(self.fetch('eth_getTransactionCount', [ACTOR,'latest']))
        if number(self.fetch('eth_getTransactionCount',[ACTOR,'pending'])) != nonce:
            raise RuntimeError('Governor has pending transactions; reconcile them first')
        pin = self.refresh_pin()
        if stage == 'pause':
            self.funding()
            history = borrower_history.main(self.pin, self.path/'pre-pause-history.json', self.url)
            if history['borrowEventCount'] != 0:
                raise RuntimeError('Borrow history changed; empty-account migration requires review')
        if stage == 'migrate':
            history = borrower_history.main(self.pin, self.history, self.url)
            if not history['postPauseSnapshot'] or history['borrowEventCount'] != 0:
                raise RuntimeError('Post-pause migration history is not empty and paused')
        if stage == 'configure':
            self.funding()
        broadcast = self.path/('broadcast-'+stage)
        expected_file = broadcast/'DeployRobinhoodMainnetMargin.s.sol/4663'/(signature.split('(')[0]+'-latest.json')
        if expected_file.exists():
            raise RuntimeError('Existing broadcast artifact: reconcile instead of overwriting it')
        env = os.environ.copy()
        env.update(FOUNDRY_PROFILE='margin_mainnet', MARGIN_EVM_BLOCK_NUMBER=str(pin['nativeEvmBlockNumber']),
                   MARGIN_PIN=str(self.pin.relative_to(ROOT)), MARGIN_HISTORY=str(self.history.relative_to(ROOT)),
                   MARGIN_RECORD=str(self.record.relative_to(ROOT)), FOUNDRY_BROADCAST=str(broadcast))
        command = ['forge','script',SCRIPT,'--sig',signature,'--skip','test','--rpc-url',self.url,
                   '--sender',ACTOR,'--broadcast','--slow','--skip-simulation','--gas-estimate-multiplier','300']
        command += ['--unlocked','--non-interactive'] if self.args.local_rehearsal else ['--account',self.args.account]
        self.journal['pending'] = {'stage':stage,'nonce':nonce,'expectedTransactions':count,
                                   'broadcastFile':str(expected_file),'pin':pin,'command':command}
        self.persist()  # Intent on disk before Foundry can submit anything.
        print('\nStage:',stage,'— Foundry will simulate, then request your keystore password.',flush=True)
        subprocess.run(command, cwd=ROOT, env=env, check=True)  # Inherits your terminal; no password capture.
        self.reconcile()

    def export_frontend(self):
        self.verify_stack('active')
        a = json.loads(self.record.read_text())
        path = self.path/'frontend-manifest.json' if self.args.local_rehearsal else ROOT/'frontend/margin-mainnet/manifest.json'
        template = ROOT/'frontend/margin-mainnet/manifest.json'
        manifest = json.loads(template.read_text())
        for key, artifact in manifest['artifacts'].items():
            name = artifact['contract']
            abi = json.loads((ROOT/'out-margin-mainnet'/(name+'.sol')/(name+'.json')).read_text())['abi']
            target = path.parent/artifact['abiFile']
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(abi, indent=2)+'\n')
            artifact['abiSha256'] = hashlib.sha256(target.read_bytes()).hexdigest()
            artifact['buildArtifactSha256'] = hashlib.sha256((ROOT/'out-margin-mainnet'/(name+'.sol')/(name+'.json')).read_bytes()).hexdigest()
        manifest.update(status='LOCAL_REHEARSAL_ACTIVE' if self.args.local_rehearsal else 'MAINNET_ACTIVE_VERIFIED',
                        tradingReady=not self.args.local_rehearsal, productionKeeperInstalledByRunner=False,
                        marginAddresses={k:a[k] for k in manifest['marginAddresses']},
                        note='Active state and runtime verified. This runner installs no keeper service and establishes no legal eligibility.',
                        deploymentRecord=str(self.record.relative_to(ROOT)))
        save(path, manifest)
        print('Verified active deployment. Frontend manifest:',path)

    def run(self):
        self.check_identity()
        completed = [p['stage'] for p in self.journal['completed']]
        expected = [s[0] for s in STAGES]
        if completed != expected[:len(completed)]:
            raise RuntimeError('Journal stage order is inconsistent')
        print('Network:',self.url,'\nSigner:',ACTOR,'\nCompleted:',', '.join(completed) or 'none')
        print('State and receipts:',self.path)
        if not self.args.broadcast and not self.args.reconcile:
            print('Read-only status. Use --broadcast to advance; --reconcile for an interrupted phase.')
            if self.journal['pending']:
                print('Pending reconciliation:',self.journal['pending']['stage'])
            return
        env = dict(os.environ, FOUNDRY_PROFILE='margin_mainnet')
        subprocess.run(['forge','build','--skip','test'], cwd=ROOT,env=env,check=True)
        digest = self.source_digest()
        if self.journal.get('sourceDigest',digest) != digest:
            raise RuntimeError('Deployment source changed since the first stage; review before proceeding')
        self.journal['sourceDigest'] = digest
        self.persist()
        for phase in self.journal['completed']:
            for recorded in phase['receipts']:
                current = self.fetch('eth_getTransactionReceipt',[recorded['transactionHash']])
                if not current or current['blockHash'] != recorded['blockHash'] or number(current['status']) != 1:
                    raise RuntimeError('A previously confirmed transaction changed; stop for reconciliation')
        if self.journal['pending']:
            if not self.args.reconcile:
                raise RuntimeError('Interrupted phase: use --reconcile; no transaction will be resent')
            self.reconcile()
        if not self.args.broadcast:
            return
        for stage, signature, count in STAGES[len(self.journal['completed']):]:
            if stage in ('configure','activate'):
                ready = self.ready_at(stage)
                now = number(self.fetch('eth_getBlockByNumber',['latest',False])['timestamp'])
                if ready == 0:
                    raise RuntimeError('Missing queued activation; inspect on-chain configuration')
                if now < ready:
                    print('Governance delay. Re-run the same --broadcast command after',
                          datetime.fromtimestamp(ready,timezone.utc).isoformat())
                    return
            self.run_stage(stage,signature,count)
        self.export_frontend()
        self.journal['status'] = 'ACTIVE_VERIFIED'
        self.persist()


def main():
    if not __debug__:
        raise RuntimeError('Do not run deployment verification with Python optimization enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--broadcast',action='store_true',help='Sign locally with Foundry and advance available stages')
    parser.add_argument('--reconcile',action='store_true',help='Verify receipts of an interrupted stage; never resend it')
    parser.add_argument('--account',default='robinhood-deployer')
    parser.add_argument('--rpc-url',default=RPC)
    parser.add_argument('--state-dir',default='deployments/margin-mainnet-live')
    parser.add_argument('--local-rehearsal',action='store_true',help=argparse.SUPPRESS)
    args = parser.parse_args()
    deployment = Deployment(args)
    with (deployment.path/'runner.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
        deployment.run()


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print('\nSTOPPED:',error,'\nDo not replay a partial phase. Inspect progress.json and the Foundry receipts.',file=sys.stderr)
        sys.exit(1)
