"""SQLite store for installs/tokens and daily send counters. Only token HASHES
are stored — never plaintext tokens, never provider keys. A single module-level
connection is fine for the relay's modest concurrency (WAL enabled)."""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass


@dataclass
class Install:
    install_id: str
    admin_email: str
    token_hash: str
    verified: int
    revoked: int
    verify_code: str
    verify_expires: int
    version: str
    created_at: int


class Store:
    def __init__(self, path: str) -> None:
        # check_same_thread=False: FastAPI may touch it from a threadpool.
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self._migrate()

    def _migrate(self) -> None:
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS installs (
                install_id    TEXT PRIMARY KEY,
                admin_email   TEXT NOT NULL,
                token_hash    TEXT NOT NULL UNIQUE,
                verified      INTEGER NOT NULL DEFAULT 0,
                revoked       INTEGER NOT NULL DEFAULT 0,
                verify_code   TEXT,
                verify_expires INTEGER NOT NULL DEFAULT 0,
                version       TEXT,
                created_at    INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS daily_counts (
                day        TEXT NOT NULL,
                token_hash TEXT NOT NULL,
                count      INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (day, token_hash)
            );
            """
        )
        self.db.commit()

    # ---- installs --------------------------------------------------------
    def create_install(self, inst: Install) -> None:
        self.db.execute(
            "INSERT INTO installs(install_id, admin_email, token_hash, verified, revoked, "
            "verify_code, verify_expires, version, created_at) VALUES(?,?,?,?,?,?,?,?,?)",
            (inst.install_id, inst.admin_email, inst.token_hash, inst.verified, inst.revoked,
             inst.verify_code, inst.verify_expires, inst.version, inst.created_at),
        )
        self.db.commit()

    def get_by_token_hash(self, token_hash: str) -> Install | None:
        row = self.db.execute("SELECT * FROM installs WHERE token_hash=?", (token_hash,)).fetchone()
        return Install(**row) if row else None

    def get_by_install_id(self, install_id: str) -> Install | None:
        row = self.db.execute("SELECT * FROM installs WHERE install_id=?", (install_id,)).fetchone()
        return Install(**row) if row else None

    def mark_verified(self, install_id: str) -> None:
        self.db.execute("UPDATE installs SET verified=1, verify_code=NULL WHERE install_id=?", (install_id,))
        self.db.commit()

    def revoke(self, install_id: str) -> int:
        cur = self.db.execute("UPDATE installs SET revoked=1 WHERE install_id=?", (install_id,))
        self.db.commit()
        return cur.rowcount

    def list_installs(self) -> list[Install]:
        rows = self.db.execute(
            "SELECT * FROM installs ORDER BY created_at DESC"
        ).fetchall()
        return [Install(**r) for r in rows]

    # ---- counters --------------------------------------------------------
    def incr_daily(self, token_hash: str) -> tuple[int, int]:
        """Increment today's per-token counter; return (token_today, global_today)."""
        day = time.strftime("%Y-%m-%d", time.gmtime())
        self.db.execute(
            "INSERT INTO daily_counts(day, token_hash, count) VALUES(?,?,1) "
            "ON CONFLICT(day, token_hash) DO UPDATE SET count=count+1",
            (day, token_hash),
        )
        self.db.commit()
        tok = self.db.execute(
            "SELECT count FROM daily_counts WHERE day=? AND token_hash=?", (day, token_hash)
        ).fetchone()["count"]
        glob = self.db.execute(
            "SELECT COALESCE(SUM(count),0) AS c FROM daily_counts WHERE day=?", (day,)
        ).fetchone()["c"]
        return tok, glob

    def daily_count(self, token_hash: str) -> int:
        day = time.strftime("%Y-%m-%d", time.gmtime())
        row = self.db.execute(
            "SELECT count FROM daily_counts WHERE day=? AND token_hash=?", (day, token_hash)
        ).fetchone()
        return row["count"] if row else 0
