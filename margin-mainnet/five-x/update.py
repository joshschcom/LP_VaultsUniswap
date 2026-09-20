"""User-signed, idempotent 5x risk update. Never accesses keystore secrets itself."""
import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'margin-mainnet/tools'))
from rpc import RPC, rpc, call, words, cast
from deploy_live import ACTOR, check_receipts, save

A = json.loads((ROOT/'deployments/margin-mainnet-live/addresses.json').read_text())
OLD = [1,200,5000,2500,12500,5000,5000,500,100,100,2*10**18,10**18]
NEW = [1,500,2000,1000,12500,5000,5000,500,100,100,2*10**18,10**18]
TUPLE = '(bool,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint128,uint128)'
SCRIPT = 'margin-mainnet/five-x/UpdateMainnetFiveX.s.sol:UpdateMainnetFiveX'
STATE = ROOT/'deployments/margin-mainnet-5x-live'


def broadcast_record(run_dir, stage):
    # Foundry retains dry-run/<function>-latest.json beside the mined record.
    # Select the exact script/chain/function path, never a recursive glob.
    functions = {'queue': 'queue', 'apply': 'applyRisk'}
    if stage not in functions:
        raise ValueError('Unknown update stage: '+str(stage))
    path = Path(run_dir)/'broadcast'/'UpdateMainnetFiveX.s.sol'/'4663'/(functions[stage]+'-latest.json')
    if not path.is_file():
        raise RuntimeError('Missing mined broadcast record: '+str(path)+'. Inspect the recorded nonce before recovery.')
    return json.loads(path.read_text())


def read(target, sig, *args):
    return words(call(A.get(target, target), sig, *args))


def action(short):
    position, debt = (A['pUsd'],A['pStock']) if short else (A['pStock'],A['pUsd'])
    pair = cast('keccak',cast('abi-encode','f(address,address,address)',A['pUsd'],position,debt))
    risk = '(true,'+','.join(map(str,NEW[1:]))+')'
    return cast('keccak',cast('abi-encode','f(string,bytes32,'+TUPLE+')','pairRisk',pair,risk))


def status():
    if int(rpc('eth_chainId',[]),16)!=4663: raise RuntimeError('Wrong chain')
    if read('config','owner()') != [int(ACTOR,16)]: raise RuntimeError('Governor changed')
    result={'chainId':4663,'governor':ACTOR,'directions':{},'block':int(rpc('eth_blockNumber',[]),16)}
    for short,name in [(False,'long'),(True,'short')]:
        position,debt=(A['pUsd'],A['pStock']) if short else (A['pStock'],A['pUsd'])
        risk=read('config','getPairRisk(address,address,address)',A['pUsd'],position,debt)
        if risk not in (OLD,NEW): raise RuntimeError('Unexpected risk configuration: '+name)
        queued=read('config','queuedActions(bytes32)',action(short))[0]
        result['directions'][name]={'applied':risk==NEW,'risk':risk,'queuedUntil':queued}
    result['opensPaused']=bool(read('config','opensPaused()')[0])
    result['flashPaused']=bool(read('flashVault','paused()')[0])
    return result


def verify_code(url=RPC):
    evidence=json.loads((ROOT/'deployments/margin-mainnet-live/active-verification.json').read_text())
    for label,contract in evidence['contracts'].items():
        code=rpc('eth_getCode',[contract['address'],'latest'],url)
        if cast('keccak',code).lower()!=contract['runtimeCodeHash'].lower():
            raise RuntimeError('Deployed bytecode changed: '+label)
    # Proxy targets must still be the implementations independently verified at deployment.
    for label in ('config','executor','riskEngine','liquidator','marginVault','insuranceFund','feeDistributor'):
        target=rpc('eth_getStorageAt',[A[label],'0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc','latest'],url)
        if int(target,16)!=int(evidence['contracts'][label+'Implementation']['address'],16):
            raise RuntimeError('Proxy implementation changed: '+label)


def export_frontend(result):
    if not all(d['applied'] for d in result['directions'].values()): return
    manifest_path=ROOT/'frontend/margin-mainnet/manifest.json'
    manifest=json.loads(manifest_path.read_text())
    if manifest['marginAddresses']['config'].lower()!=A['config'].lower(): raise RuntimeError('Manifest identity changed')
    manifest['requestedFinalState'].update(maxLeverageX100=500,initialMarginBps=2000,maintenanceMarginBps=1000)
    manifest.update(status='MAINNET_5X_RISK_VERIFIED',tradingReady=not(result['opensPaused'] or result['flashPaused']),
                    riskUpdateRecord='deployments/margin-mainnet-5x-live/status.json')
    save(manifest_path,manifest)


def verify_validation():
    path=ROOT/'deployments/robinhood-mainnet.margin-5x-validation.json'
    validation=json.loads(path.read_text())
    if validation['status']!='passed': raise RuntimeError('5x validation is not complete')
    for name,digest in validation['sourceHashes'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest:
            raise RuntimeError('Validated source changed: '+name)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',nargs='?',choices=['status','queue','apply'],default='status')
    parser.add_argument('--broadcast',action='store_true')
    parser.add_argument('--reconcile',action='store_true',help='Verify a completed interrupted invocation without submitting transactions')
    args=parser.parse_args()
    os.chdir(ROOT)
    STATE.mkdir(exist_ok=True)
    lock=(STATE/'update.lock').open('a')
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if args.broadcast:
        signer_lock=(ROOT/'deployments/.robinhood-deployer-signing.lock').open('a')
        fcntl.flock(signer_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if args.reconcile:
        unresolved=list(p for p in STATE.glob('*/intent.json') if not p.with_name('verified.json').exists())
        for path in unresolved:
            intent=json.loads(path.read_text())
            receipts=check_receipts(broadcast_record(path.parent,intent['stage']),rpc,intent['count'],intent['nonce'])
            current=status()
            if intent['stage']=='apply' and not all(d['applied'] for d in current['directions'].values()):
                raise RuntimeError('Applied state is incomplete')
            if intent['stage']=='queue' and any(not(d['applied'] or d['queuedUntil']) for d in current['directions'].values()):
                raise RuntimeError('Queued state is incomplete')
            save(path.with_name('verified.json'),{'receipts':receipts,'state':current})
            save(STATE/'status.json',current)
            if intent['stage']=='apply': export_frontend(current)
        print('Reconciled',len(unresolved),'invocations; no transaction submitted.');return
    s=status()
    print(json.dumps(s,indent=2))
    if args.stage=='status': return
    verify_validation()
    verify_code()
    remaining=[d for d in s['directions'].values() if not d['applied'] and (args.stage=='apply' or not d['queuedUntil'])]
    if args.stage=='apply':
        ready=max((d['queuedUntil'] for d in remaining),default=0)
        now=int(rpc('eth_getBlockByNumber',['latest',False])['timestamp'],16)
        if any(not d['queuedUntil'] for d in remaining): raise RuntimeError('Queue both directions first')
        if now<ready:
            print('Apply after',datetime.fromtimestamp(ready,timezone.utc).isoformat());return
    if not remaining:
        print('No remaining transactions for this stage.')
        if args.broadcast and args.stage=='apply':
            STATE.mkdir(exist_ok=True);save(STATE/'status.json',s);export_frontend(s)
        return
    latest=int(rpc('eth_getTransactionCount',[ACTOR,'latest']),16)
    if latest!=int(rpc('eth_getTransactionCount',[ACTOR,'pending']),16): raise RuntimeError('Pending governor transaction; wait/reconcile before rerunning')
    STATE.mkdir(exist_ok=True)
    run_dir=STATE/(args.stage+'-'+str(latest));run_dir.mkdir(exist_ok=True)
    intent=run_dir/'intent.json'
    # No blind replay if a prior invocation may have sent a transaction whose receipt is unknown.
    for old in STATE.glob('*/intent.json'):
        if not old.with_name('verified.json').exists():
            raise RuntimeError('Unresolved invocation '+str(old)+'. Inspect its broadcast receipts; do not delete or replay it.')
    env=dict(os.environ,FOUNDRY_PROFILE='margin_mainnet',FOUNDRY_BROADCAST=str(run_dir/'broadcast'))
    cmd=['forge','script',SCRIPT,'--sig','queue()' if args.stage=='queue' else 'applyRisk()',
         '--skip','test','--rpc-url',RPC,'--sender',ACTOR,'--slow','--skip-simulation','--gas-estimate-multiplier','300']
    if args.broadcast:
        save(intent,{'stage':args.stage,'nonce':latest,'count':len(remaining),'chainId':4663,'sender':ACTOR})
        cmd+=['--broadcast','--account','robinhood-deployer']
    subprocess.run(cmd,env=env,check=True)
    if not args.broadcast:
        print('Simulation only. Add --broadcast to sign in your terminal.');return
    receipts=check_receipts(broadcast_record(run_dir,args.stage),rpc,len(remaining),latest)
    s=status()
    if args.stage=='apply' and not all(d['applied'] for d in s['directions'].values()): raise RuntimeError('Incomplete applied risk')
    if args.stage=='queue' and any(not(d['applied'] or d['queuedUntil']) for d in s['directions'].values()): raise RuntimeError('Incomplete queue')
    save(run_dir/'verified.json',{'receipts':receipts,'state':s})
    save(STATE/'status.json',s)
    if args.stage=='apply': export_frontend(s)
    else:
        ready=max(d['queuedUntil'] for d in s['directions'].values())
        print('Run apply --broadcast after',datetime.fromtimestamp(ready,timezone.utc).isoformat())
    print('Verified',len(receipts),'mainnet transactions.')

if __name__=='__main__': main()
