"""App Platform entry point. Monitor by default; no secrets logged."""
import base64
import json
import os
import re
import subprocess
from pathlib import Path
import signal
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'margin-mainnet/keeper-service'))
import service
import keeper
from journal import Journal, Busy

STOP = False
KEEPER = '0x16aEC17597E5224998e2043C9c83C4a35dD95A86'


def stop(*_):
    global STOP
    STOP = True


def emit(status, **fields):
    print(json.dumps(dict(status=status, checkedAtUnix=int(time.time()), **fields)), flush=True)


def prepare_signer(directory):
    # Called only inside the cloud container after explicit local provisioning.
    encoded = os.environ.pop('KEYSTORE_JSON_BASE64', '')
    password = os.environ.pop('KEYSTORE_PASSWORD', '')
    if not encoded or not password:
        raise RuntimeError('Cloud signer is not provisioned')
    raw = base64.b64decode(encoded, validate=True)
    data = json.loads(raw)
    if data.get('address', '').lower().removeprefix('0x') != KEEPER[2:].lower():
        raise RuntimeError('Keystore does not belong to the authorized signer')
    if data.get('version') != 3 or not (data.get('crypto') or data.get('Crypto')):
        raise RuntimeError('Expected an encrypted V3 keystore')
    key = Path(directory) / 'robinhood-keeper'
    key.write_bytes(raw)
    key.chmod(0o600)
    secret = Path(directory) / 'password'
    secret.write_text(password)
    secret.chmod(0o600)
    check = subprocess.run(['cast', 'wallet', 'address', '--keystore', str(key),
                            '--password-file', str(secret)], capture_output=True, text=True, timeout=60)
    if check.returncode or check.stdout.strip().lower() != KEEPER.lower():
        raise RuntimeError('Dedicated signer unlock/address verification failed')
    return str(key), str(secret)


class CloudBackend(keeper.RpcBackend):
    def __init__(self, url, addresses, state, password_file=None):
        if url != service.RPC:
            raise ValueError('Dedicated cloud keeper requires the fixed mainnet RPC')
        if (addresses['liquidator'].lower() != service.LIQUIDATOR.lower()
                or addresses['executor'].lower() != service.EXECUTOR.lower()):
            raise ValueError('Wrong mainnet deployment')
        super().__init__(url, addresses, KEEPER)
        self.state = Path(state)
        self.password_file = password_file
        self.max_gas = 8_000_000
        self.gas_price = 100_000_000
        self.position_id = None

    def simulate(self, position_id):
        tx = super().simulate(position_id)
        if int(tx['gas'], 16) > self.max_gas:
            raise RuntimeError('Estimated gas exceeds configured keeper cap')
        tx['value'] = '0x0'
        return tx

    def submit(self, transaction, nonce):
        expected = self.transaction(self.position_id)
        if (transaction['from'].lower() != KEEPER.lower()
                or transaction['to'].lower() != service.LIQUIDATOR.lower()
                or transaction['data'].lower() != expected['data'].lower()
                or int(transaction.get('value', '0x0'), 16) != 0
                or not 0 < int(transaction['gas'], 16) <= self.max_gas):
            raise ValueError('Transaction violates the liquidation policy')
        if self.nonce() != nonce:
            raise RuntimeError('Signer nonce changed')
        self.journal.before_send(self.position_id, nonce, transaction)
        result = subprocess.run(['cast', 'send', '--rpc-url', self.url,
                                 '--keystore', self.keystore, '--password-file', self.password_file,
                                 '--from', KEEPER, '--nonce', str(nonce),
                                 '--gas-limit', str(int(transaction['gas'], 16)),
                                 '--gas-price', str(self.gas_price), '--priority-gas-price', '0',
                                 '--async', service.LIQUIDATOR, '--data', transaction['data']],
                                capture_output=True, text=True, timeout=90)
        hashes = re.findall(r'0x[0-9a-fA-F]{64}', result.stdout)
        if result.returncode or len(hashes) != 1:
            raise RuntimeError('Ambiguous cast submission; reconcile the durable intent')
        return hashes[0]

    def receipt(self, tx_hash):
        receipt = super().receipt(tx_hash)
        if receipt is None:
            return None
        journal = json.loads((self.state / ('position-%s.json' % self.position_id)).read_text())
        attempts = [a for a in journal['attempts'] if a.get('hash') == tx_hash]
        if len(attempts) != 1:
            raise RuntimeError('Receipt is not bound to one persisted attempt')
        attempt = attempts[0]
        sent = service.rpc('eth_getTransactionByHash', [tx_hash], self.url)
        planned = attempt['transaction']
        if (not sent or sent['from'].lower() != KEEPER.lower()
                or sent['to'].lower() != service.LIQUIDATOR.lower()
                or sent['input'].lower() != planned['data'].lower()
                or int(sent['nonce'], 16) != attempt['nonce']
                or int(sent['value'], 16) != 0 or int(sent['chainId'], 16) != 4663):
            raise RuntimeError('Receipt transaction identity mismatch')
        block = service.rpc('eth_getBlockByNumber', [receipt['blockNumber'], False], self.url)
        if block['hash'] != receipt['blockHash']:
            raise RuntimeError('Receipt block no longer canonical')
        if int(service.rpc('eth_blockNumber', [], self.url), 16) < int(receipt['blockNumber'], 16) + 1:
            return None
        return receipt


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    execute = os.environ.get('EXECUTE', 'false') == 'true'
    expected_id = os.environ.get('JOURNAL_ID') or None
    database_url = os.environ.get('DATABASE_URL')
    if execute and not (expected_id and database_url):
        raise RuntimeError('Execution requires a durable database and verified JOURNAL_ID')
    sys.path.insert(0, str(ROOT / 'margin-mainnet/five-x'))
    from update import verify_code
    verify_code()
    emit('runtime_verified', executionEnabled=execute, contracts=31, proxySlots=7)
    journal = None
    # Rolling deployments can overlap. The replacement reports standby until
    # the prior worker exits; it must not read stale state before acquiring.
    while database_url and not STOP and journal is None:
        try:
            journal = Journal(database_url, expected_id, initialize=not execute)
        except Busy:
            emit('standby', executionEnabled=False)
            time.sleep(5)
    if STOP:
        return
    local_persist = keeper.persist
    try:
        with tempfile.TemporaryDirectory(prefix='margin-keeper-') as directory:
            state = Path(directory) / 'state'
            state.mkdir()
            if journal:
                journal.hydrate(state, local_persist)
                keeper.persist = lambda path, body: journal.persist(path, body, local_persist)
            keystore, password_file = prepare_signer(directory) if execute else (None, None)
            if execute:
                emit('signer_verified', sender=KEEPER, executionEnabled=True)
            backend = CloudBackend(service.RPC, json.loads((ROOT / 'deployments/margin-mainnet-live/addresses.json').read_text()), state, password_file)
            backend.journal = journal
            backend.keystore = keystore
            journal_id = journal.id if journal else None
            emit('journal_ready' if journal else 'monitor_only_no_database', journalId=journal_id,
                 recoveredJournals=len(list(state.glob('position-*.json'))), executionEnabled=execute)
            while not STOP:
                if journal:
                    journal.check()
                # Keep monitoring while unfunded. This threshold covers one
                # maximum-budget call; a later drain also prevents a new intent.
                balance = int(service.rpc('eth_getBalance', [KEEPER, 'latest']), 16)
                funded = balance >= backend.max_gas * backend.gas_price
                result = service.cycle(backend, state, execute and funded, max_positions=100)
                if execute and not funded and result['status'] not in ('operator_attention', 'waiting_receipt'):
                    result['status'] = 'awaiting_gas'
                # No raw exceptions, connection strings, transaction bodies or
                # credentials in centralized application logs.
                emit(result['status'], executionEnabled=execute, sender=KEEPER,
                     gasBalanceWei=str(balance), gasReady=funded,
                     journalId=journal_id, positions=[{'positionId': p['positionId'], 'status': p['status']} for p in result['positions']])
                if result['status'] == 'operator_attention':
                    raise RuntimeError('Keeper requires journal reconciliation')
                for _ in range(15):
                    if STOP:
                        break
                    time.sleep(1)
    finally:
        keeper.persist = local_persist
        if journal:
            journal.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit('operator_attention', errorType=type(error).__name__, executionEnabled=False)
        sys.exit(2)
