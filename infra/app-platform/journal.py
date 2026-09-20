"""PostgreSQL authority for journals and the single Robinhood signer lease.

Use a direct connection, never a transaction-pooling proxy. No reconnects: losing
this session fences the process. Local files are only a cache of committed rows.
"""
import json
import re
import uuid
from pathlib import Path

import psycopg

LOCK = 466394696


class Busy(RuntimeError):
    pass


class Journal:
    def __init__(self, url, expected_id=None, initialize=False):
        self.db = psycopg.connect(url, autocommit=True, connect_timeout=10,
                                 options='-c statement_timeout=15000 -c synchronous_commit=on')
        try:
            if not self.db.execute('SELECT pg_try_advisory_lock(%s)', (LOCK,)).fetchone()[0]:
                raise Busy('Another worker holds the signer lock')
            if initialize:
                with self.db.transaction():
                    self.db.execute('CREATE TABLE IF NOT EXISTS keeper_meta (singleton int PRIMARY KEY CHECK(singleton=1), id uuid NOT NULL)')
                    self.db.execute('CREATE TABLE IF NOT EXISTS keeper_journals (position_id bigint PRIMARY KEY, body jsonb NOT NULL)')
                    self.db.execute('INSERT INTO keeper_meta VALUES (1,%s) ON CONFLICT DO NOTHING', (uuid.uuid4(),))
            self.id = str(self.db.execute('SELECT id FROM keeper_meta WHERE singleton=1').fetchone()[0])
            if expected_id and self.id != expected_id:
                raise RuntimeError('Journal database identity changed; reconcile before rearming')
            if not initialize and not expected_id:
                raise RuntimeError('Execution requires a pinned journal database identity')
        except BaseException:
            self.db.close()
            raise

    def check(self):
        # Recheck the SAME session's lock; do not reacquire or transparently reconnect.
        row = self.db.execute("SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype='advisory' AND pid=pg_backend_pid() AND classid=0 AND objid=%s AND objsubid=1 AND granted), (SELECT id FROM keeper_meta WHERE singleton=1)", (LOCK,)).fetchone()
        if not row[0] or str(row[1]) != self.id:
            raise RuntimeError('Journal session lost its lock or database identity')

    def hydrate(self, state, local_persist):
        self.check()
        state = Path(state)
        # Each process gets its own empty cache; never merge orphan local journals.
        if list(state.glob('position-*.json')):
            raise RuntimeError('Journal cache must be empty on startup')
        for position, body in self.db.execute('SELECT position_id,body FROM keeper_journals ORDER BY position_id'):
            if body['positionId'] != position:
                raise RuntimeError('Journal row identity mismatch')
            local_persist(state / ('position-%s.json' % position), body)

    def persist(self, path, value, local_persist):
        match = re.fullmatch(r'position-([1-9][0-9]*)\.json', Path(path).name)
        if not match or int(match[1]) != value['positionId']:
            raise RuntimeError('Invalid transaction journal path')
        self.check()
        # This autocommit returns only after WAL commit. A failed/ambiguous commit
        # propagates and prevents signing; startup recovers from the database.
        self.db.execute('INSERT INTO keeper_journals VALUES (%s,%s::jsonb) ON CONFLICT(position_id) DO UPDATE SET body=EXCLUDED.body',
                        (value['positionId'], json.dumps(value)))
        local_persist(path, value)

    def before_send(self, position, nonce, transaction):
        self.check()
        row = self.db.execute('SELECT body FROM keeper_journals WHERE position_id=%s', (position,)).fetchone()
        attempt = row[0]['attempts'][-1] if row else {}
        if (attempt.get('state') != 'intent' or attempt.get('nonce') != nonce
                or attempt.get('transaction') != transaction):
            raise RuntimeError('No matching durable intent; refusing to sign')

    def close(self):
        self.db.close()
