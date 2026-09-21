"""DB 접근 — MariaDB(본설계) 와 SQLite(임시) 양쪽을 같은 API 로 감싼다.

본설계(mariadb)
    WAS → DB VIP 10.3.31.50 직결. 중간 프록시는 없다.
    VIP 뒤에서 누가 master 인지는 keepalived 가 정하므로 로컬 failover 는
    이 코드가 알 필요가 없다 — 같은 주소로 재연결하면 끝이다.

임시(sqlite)
    DB 서버에 아직 접근할 수 없어 WAS 로컬 파일로 대신한다.
    ★ 이 모드에서는 DB 계층 자체가 존재하지 않는다. 그래서 아래가
      **검증되지 않는다.** 되는 것처럼 보여도 아니다.
        · /health/deep 의 writer 도달 확인   — 로컬 파일은 언제나 도달한다
        · C8  DCI 단절 시 DC-400 자동 이탈   — 위 확인에 의존한다
        · C3~C7 DB 전환 전부
        · semi-sync / RPO / 복제 지연
      게다가 **두 WAS 가 서로 다른 데이터를 본다.** 공유 DB 가 아니다.
"""
import os
import queue
import threading
import time
from contextlib import contextmanager

from .config import settings

BACKEND = settings.db_mode          # 'mariadb' | 'sqlite'

# =============================================================================
# SQLite 스키마
#
# 정본은 db/sql/01-schema.sql (MariaDB) 이다. 여기 있는 것은 임시 모드용
# 사본이므로 둘이 어긋날 수 있다. mariadb 로 돌아가면 정본만 쓴다.
# =============================================================================
_SQLITE_SCHEMA = """
CREATE TABLE IF NOT EXISTS write_log (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  dc         TEXT NOT NULL,
  was_host   TEXT NOT NULL,
  via_l4     TEXT NOT NULL DEFAULT '',
  note       TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);
CREATE INDEX IF NOT EXISTS idx_write_log_created ON write_log (created_at);

CREATE TABLE IF NOT EXISTS access_trace (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  req_id      TEXT, client_ip TEXT, via_l4 TEXT,
  l4_dc       TEXT, was_dc TEXT, was_host TEXT, web_host TEXT, app_version TEXT,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE IF NOT EXISTS health_probe (
  node      TEXT PRIMARY KEY,
  dc        TEXT NOT NULL,
  n         INTEGER NOT NULL DEFAULT 1,
  probed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE IF NOT EXISTS repl_heartbeat (
  id      INTEGER PRIMARY KEY,
  source  TEXT NOT NULL,
  beat_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE IF NOT EXISTS failover_log (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  step       TEXT NOT NULL, actor TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);
"""


# =============================================================================
# MariaDB 백엔드
# =============================================================================
class _MySQLPool:
    def __init__(self, size: int):
        import pymysql                                  # noqa: F401  (지연 import)
        self._pymysql = pymysql
        self._idle: "queue.LifoQueue" = queue.LifoQueue(maxsize=size)
        self._lock = threading.Lock()
        self._created = 0
        self._size = size

    def _connect(self):
        return self._pymysql.connect(
            host=settings.db_host, port=settings.db_port,
            user=settings.db_user, password=settings.db_pass,
            database=settings.db_name,
            connect_timeout=settings.db_connect_timeout,
            read_timeout=settings.db_read_timeout,
            write_timeout=settings.db_read_timeout,
            autocommit=True, charset="utf8mb4",
            cursorclass=self._pymysql.cursors.DictCursor,
        )

    def acquire(self):
        try:
            conn = self._idle.get_nowait()
        except queue.Empty:
            # 슬롯을 먼저 잡고, 락을 놓은 뒤에 접속한다.
            #
            # ★ 접속이 실패하면 잡아 둔 슬롯을 반드시 되돌려야 한다. 되돌리지
            #   않으면 실패가 그대로 누적돼 _created 가 _size 에 닿고, 그 뒤로는
            #   영영 비어 있는 idle 큐만 기다리다 queue.Empty 를 낸다.
            #   **DB 가 복구돼도 프로세스를 재시작할 때까지 못 붙는다.**
            #
            #   2026-09-22 실측(DC-400, 방화벽 13번 미개통 상태에서 헬스체크 반복):
            #       1~6 회   OperationalError: (2003, "Can't connect ... timed out")
            #       7 회~    "Empty: "  로 바뀌어 고정
            #   DB failover 중 몇 초의 단절만으로 같은 상태가 되므로, 고치지
            #   않으면 C3~C7(DB 전환) 이 통째로 무효다 — 넘어간 DC 가 영영
            #   돌아오지 않아 GSLB 가 영구히 빼 버린다.
            reserved = False
            with self._lock:
                if self._created < self._size:
                    self._created += 1
                    reserved = True
            if reserved:
                try:
                    return self._connect()
                except Exception:
                    with self._lock:
                        self._created -= 1
                    raise
            # 풀이 꽉 찼다. 반납을 기다린다 — 락을 쥔 채로 기다리지 않는다.
            conn = self._idle.get(timeout=settings.db_connect_timeout)
        try:
            conn.ping(reconnect=True)
        except Exception:
            try: conn.close()
            except Exception: pass
            # 이 커넥션은 이미 _created 에 계상돼 있다. 재접속이 실패하면
            # 그 몫도 여기서 돌려놔야 같은 고갈이 생기지 않는다.
            try:
                conn = self._connect()
            except Exception:
                with self._lock:
                    self._created -= 1
                raise
        return conn

    def release(self, conn, broken: bool):
        if broken:
            try: conn.close()
            except Exception: pass
            with self._lock:
                self._created -= 1
            return
        try:
            self._idle.put_nowait(conn)
        except queue.Full:
            try: conn.close()
            except Exception: pass
            with self._lock:
                self._created -= 1


# =============================================================================
# SQLite 백엔드
#
# 스레드마다 커넥션을 하나씩 둔다 (uvicorn 워커의 스레드풀에서 호출된다).
# WAL 로 열어 읽기와 쓰기가 서로 막지 않게 한다.
# =============================================================================
class _SQLitePool:
    def __init__(self):
        import sqlite3
        self._sqlite3 = sqlite3
        self._local = threading.local()
        os.makedirs(os.path.dirname(settings.sqlite_path), exist_ok=True)
        self._init_schema()

    def _open(self):
        conn = self._sqlite3.connect(
            settings.sqlite_path,
            timeout=settings.db_read_timeout,
            isolation_level=None,          # autocommit
            check_same_thread=False,
        )
        conn.row_factory = self._sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA busy_timeout=3000")
        return conn

    def _init_schema(self):
        conn = self._open()
        try:
            conn.executescript(_SQLITE_SCHEMA)
            conn.execute(
                "INSERT OR IGNORE INTO repl_heartbeat (id, source) VALUES (1, 'sqlite')")
        finally:
            conn.close()

    def acquire(self):
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = self._open()
            self._local.conn = conn
        return conn

    def release(self, conn, broken: bool):
        if broken:
            try: conn.close()
            except Exception: pass
            self._local.conn = None


_pool = _SQLitePool() if BACKEND == "sqlite" else _MySQLPool(settings.db_pool_size)


def _sql(q: str) -> str:
    """플레이스홀더를 백엔드 문법으로. 코드는 항상 %s 로 쓴다."""
    return q.replace("%s", "?") if BACKEND == "sqlite" else q


class _RowCursor:
    """sqlite3.Row 를 dict 로 돌려주어 pymysql DictCursor 와 모양을 맞춘다."""
    def __init__(self, cur): self._c = cur
    def execute(self, q, a=None): return self._c.execute(_sql(q), a or ())
    def fetchone(self):
        r = self._c.fetchone()
        return dict(r) if r is not None else None
    def fetchall(self): return [dict(r) for r in self._c.fetchall()]
    @property
    def lastrowid(self): return self._c.lastrowid


@contextmanager
def cursor():
    conn = _pool.acquire()
    broken = False
    try:
        if BACKEND == "sqlite":
            cur = conn.cursor()
            try:
                yield _RowCursor(cur)
            finally:
                cur.close()
        else:
            with conn.cursor() as cur:
                yield cur
    except Exception:
        broken = True
        raise
    finally:
        _pool.release(conn, broken)


def query_one(sql: str, args=None) -> dict:
    with cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchone()


def query_all(sql: str, args=None) -> list:
    with cursor() as cur:
        cur.execute(sql, args)
        return list(cur.fetchall())


def execute(sql: str, args=None) -> int:
    with cursor() as cur:
        cur.execute(sql, args)
        return cur.lastrowid


def timed(fn, *a, **kw):
    """(결과, 경과 ms). C2/C9-a 의 지연 측정에 쓴다."""
    t0 = time.perf_counter()
    result = fn(*a, **kw)
    return result, round((time.perf_counter() - t0) * 1000, 2)


# =============================================================================
# 방언 차이를 여기에 가둔다. 라우터는 백엔드를 몰라도 되게 한다.
# =============================================================================
def target() -> str:
    return (settings.sqlite_path if BACKEND == "sqlite"
            else f"{settings.db_host}:{settings.db_port}")


def writer_identity() -> dict:
    """지금 쓰기를 받는 곳이 누구인가."""
    if BACKEND == "sqlite":
        # 로컬 파일이다. 언제나 쓰기가 되고, 언제나 자기 자신이다.
        # 그래서 이 값으로는 아무것도 검증되지 않는다 — temporary 를 같이 낸다.
        return {
            "backend": "sqlite", "temporary": True,
            "hostname": settings.node, "server_id": 0,
            "read_only": 0, "version": "sqlite3",
            "note": "local file, not a shared database",
        }
    row = query_one(
        "SELECT @@hostname AS hostname, @@server_id AS server_id, "
        "@@global.read_only AS read_only, @@version AS version")
    return {
        "backend": "mariadb", "temporary": False,
        "hostname": row["hostname"], "server_id": row["server_id"],
        "read_only": int(row["read_only"]), "version": row["version"],
    }


def semi_sync_status() -> dict:
    """semi-sync 가 살아 있는가. sqlite 에는 복제가 없다."""
    if BACKEND == "sqlite":
        return {"unavailable": "sqlite has no replication"}
    try:
        rows = query_all(
            "SHOW GLOBAL STATUS WHERE Variable_name IN "
            "('Rpl_semi_sync_master_status','Rpl_semi_sync_master_clients',"
            " 'Rpl_semi_sync_master_no_tx','Rpl_semi_sync_master_yes_tx',"
            " 'Rpl_semi_sync_slave_status')")
        return {r["Variable_name"]: r["Value"] for r in rows}
    except Exception as exc:                              # noqa: BLE001
        return {"error": f"{type(exc).__name__}: {exc}"}


def upsert_health_probe(node: str, dc: str) -> None:
    if BACKEND == "sqlite":
        execute("INSERT INTO health_probe (node, dc) VALUES (%s, %s) "
                "ON CONFLICT(node) DO UPDATE SET "
                "n = n + 1, probed_at = strftime('%%Y-%%m-%%d %%H:%%M:%%f','now')",
                (node, dc))
    else:
        execute("INSERT INTO health_probe (node, dc) VALUES (%s, %s) "
                "ON DUPLICATE KEY UPDATE probed_at = CURRENT_TIMESTAMP(3), n = n + 1",
                (node, dc))
