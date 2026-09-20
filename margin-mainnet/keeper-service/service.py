"""Mainnet keeper monitor and bounded, locally keystore-signed liquidations.

Defaults to read-only. --execute enables only the verified liquidator, fixed governor
recipient, zero value, capped gas, and one serialized sender. No key is exported.
"""
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'margin-mainnet/tools'))
from rpc import RPC,rpc,cast
from keeper import RpcBackend,run,persist,loopback
GOVERNOR='0x94696d767e65a75581145646960FA0eC886cE5d2'
LIQUIDATOR='0x1434CDa56d0Aeac4d5abC16F91ca76a8A989083c'
EXECUTOR='0x6A45Ae86bD992d250580d08D340A06A04D478977'


class SignedBackend(RpcBackend):
    def __init__(self,url,addresses,state,password_file=None,local_unlocked=False):
        if url!=RPC and not(local_unlocked and loopback(url)):
            raise ValueError('Execution RPC must be mainnet, or explicit local rehearsal')
        if addresses['liquidator'].lower()!=LIQUIDATOR.lower() or addresses['executor'].lower()!=EXECUTOR.lower():
            raise ValueError('Wrong mainnet deployment')
        super().__init__(url,addresses,GOVERNOR)
        self.state=Path(state);self.password_file=password_file;self.local_unlocked=local_unlocked
        self.max_gas=8_000_000;self.gas_price=100_000_000 # 0.1 gwei; <=0.0008 ETH per call.
        self.position_id=None

    def simulate(self,position_id):
        tx=super().simulate(position_id)
        if int(tx['gas'],16)>self.max_gas: raise RuntimeError('Estimated gas exceeds configured keeper cap')
        tx['value']='0x0'
        return tx

    def submit(self,transaction,nonce):
        expected=self.transaction(self.position_id)
        if (transaction['from'].lower()!=GOVERNOR.lower() or transaction['to'].lower()!=LIQUIDATOR.lower()
                or transaction['data'].lower()!=expected['data'].lower() or int(transaction.get('value','0x0'),16)!=0
                or not 0<int(transaction['gas'],16)<=self.max_gas):
            raise ValueError('Keeper transaction is outside the fixed liquidation policy')
        if self.nonce()!=nonce: raise RuntimeError('Sender nonce changed; reconcile before continuing')
        if self.local_unlocked: return super().submit(transaction,nonce)
        cmd=['cast','send','--rpc-url',self.url,'--account','robinhood-deployer','--from',GOVERNOR,
             '--nonce',str(nonce),'--gas-limit',str(int(transaction['gas'],16)),
             '--gas-price',str(self.gas_price),'--priority-gas-price','0','--async',
             LIQUIDATOR,'--data',transaction['data']]
        if self.password_file: cmd+=['--password-file',self.password_file]
        # Password prompt belongs to Foundry and inherits the operator terminal; never collect it.
        result=subprocess.run(cmd,stdout=subprocess.PIPE,text=True,check=True)
        hashes=re.findall(r'0x[0-9a-fA-F]{64}',result.stdout)
        if len(hashes)!=1: raise RuntimeError('Ambiguous cast output; inspect nonce and journal before retry')
        return hashes[0]

    def receipt(self,tx_hash):
        receipt=super().receipt(tx_hash)
        if receipt is None: return None
        journal=json.loads((self.state/('position-'+str(self.position_id)+'.json')).read_text())
        attempts=[a for a in journal['attempts'] if a.get('hash')==tx_hash]
        if len(attempts)!=1: raise RuntimeError('Receipt is not bound to one persisted attempt')
        attempt=attempts[0];sent=rpc('eth_getTransactionByHash',[tx_hash],self.url)
        planned=attempt['transaction']
        if (not sent or sent['from'].lower()!=GOVERNOR.lower() or sent['to'].lower()!=LIQUIDATOR.lower()
                or sent['input'].lower()!=planned['data'].lower() or int(sent['nonce'],16)!=attempt['nonce']
                or int(sent['value'],16)!=0 or int(sent['chainId'],16)!=4663):
            raise RuntimeError('Receipt transaction identity mismatch')
        block=rpc('eth_getBlockByNumber',[receipt['blockNumber'],False],self.url)
        if block['hash']!=receipt['blockHash']: raise RuntimeError('Receipt block no longer canonical')
        if not self.local_unlocked and int(rpc('eth_blockNumber',[],self.url),16)<int(receipt['blockNumber'],16)+1:
            return None
        return receipt


def unresolved(state):
    pending=[]
    for path in Path(state).glob('position-*.json'):
        j=json.loads(path.read_text())
        if j['attempts'] and j['attempts'][-1]['state']!='confirmed': pending.append(j['positionId'])
    return sorted(pending)


def cycle(backend,state,execute=False,max_positions=100):
    # Reconcile any unresolved send globally before considering another position/nonce.
    pending=unresolved(state)
    ids=pending if pending else list(range(1,backend.read('executor','nextPositionId()')[0]))
    if len(ids)>max_positions: raise RuntimeError('Position scan budget exceeded: increase explicitly before monitoring more accounts')
    results=[]
    degraded=False
    for position_id in ids:
        backend.position_id=position_id
        result=run(backend,position_id,Path(state)/('position-'+str(position_id)+'.json'),execute,max_calls=8)
        results.append({'positionId':position_id,**result})
        if result['status']=='stale_or_unavailable_stop': degraded=True
        if result['status']=='not_executable_stop':
            account=result['snapshot']['account']
            if backend.read('riskEngine','isLiquidatable(address)',account)[0]:
                return {'status':'operator_attention','positions':results}
        if result['status']=='transition_stop': return {'status':'operator_attention','positions':results}
        if result['status']=='pending': return {'status':'waiting_receipt','positions':results}
        if result['status'] in ('reconcile_unknown_submission','reverted_stop','no_progress_stop','call_budget_stop'):
            return {'status':'operator_attention','positions':results}
    return {'status':'degraded_oracle' if degraded else 'monitoring','positions':results}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--execute',action='store_true')
    p.add_argument('--once',action='store_true')
    p.add_argument('--interval',type=int,default=15)
    p.add_argument('--max-positions',type=int,default=100)
    p.add_argument('--state-dir',default=str(ROOT/'deployments/margin-keeper-live'))
    p.add_argument('--password-file')
    p.add_argument('--rpc-url',default=RPC)
    p.add_argument('--local-unlocked',action='store_true',help=argparse.SUPPRESS)
    args=p.parse_args()
    if args.interval<5: p.error('Minimum poll interval is five seconds')
    state=Path(args.state_dir).resolve();state.mkdir(parents=True,exist_ok=True)
    if args.local_unlocked and (not loopback(args.rpc_url) or state==ROOT/'deployments/margin-keeper-live'):
        p.error('Local rehearsal needs loopback RPC and separate journal directory')
    if args.execute and not(args.password_file or args.local_unlocked or sys.stdin.isatty()):
        p.error('Interactive execution needs a terminal; unattended execution needs a locally configured protected password file')
    if args.password_file:
        path=Path(args.password_file).expanduser().resolve()
        if not path.is_file() or path.stat().st_mode & 0o077: p.error('Password file must be accessible only to its owner (chmod 600)')
        args.password_file=str(path)
    addresses=json.loads((ROOT/'deployments/margin-mainnet-live/addresses.json').read_text())
    sys.path.insert(0,str(ROOT/'margin-mainnet/five-x'))
    from update import verify_code
    verify_code(args.rpc_url)
    backend=SignedBackend(args.rpc_url,addresses,state,args.password_file,args.local_unlocked)
    if args.execute and not args.local_unlocked:
        signer_lock=(ROOT/'deployments/.robinhood-deployer-signing.lock').open('a')
        fcntl.flock(signer_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    with (state/'keeper.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        while True:
            try:
                result=cycle(backend,state,args.execute,args.max_positions)
                result.update(checkedAtUnix=int(time.time()),executionEnabled=args.execute,sender=GOVERNOR)
                persist(state/'health.json',result)
                print(json.dumps(result),flush=True)
                if result['status']=='operator_attention': raise SystemExit(2)
            except Exception as error:
                persist(state/'health.json',{'status':'error','error':str(error),'checkedAtUnix':int(time.time())})
                raise
            if args.once: return
            time.sleep(args.interval)

if __name__=='__main__':main()
