"""DB VIP 직결 커넥션 풀.

접속 대상은 환경변수(`AADC_DB_HOST`)로만 정해진다. 평시에는 DB VIP
`10.3.31.50` 이고, VIP 뒤에서 누가 master 인지는 keepalived 가 정하므로
로컬 failover 는 이 코드가 알 필요가 없다 — 같은 주소로 재연결하면 끝난다.

DR 전환은 사람이 was.env 를 고치고 앱을 재시작하는 절차다 (AADC-POC.md 3-4절,
`dr/README.md`). 중간 프록시를 두지 않으므로 커넥션 타임아웃이 DCI 구간을
방어하는 유일한 장치다 — `AADC_DB_CONNECT_TIMEOUT` / `AADC_DB_READ_TIMEOUT`.
"""
import queue
import threading
import time
from contextlib import contextmanager

import pymysql

from .config import settings


class Pool:
    def __init__(self, size: int):
        self._idle: "queue.LifoQueue" = queue.LifoQueue(maxsize=size)
        self._lock = threading.Lock()
        self._created = 0
        self._size = size

    def _connect(self):
        return pymysql.connect(
            host=settings.db_host,
            port=settings.db_port,
            user=settings.db_user,
            password=settings.db_pass,
            database=settings.db_name,
            connect_timeout=settings.db_connect_timeout,
            read_timeout=settings.db_read_timeout,
            write_timeout=settings.db_read_timeout,
            autocommit=True,
            charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor,
        )

    def _acquire(self):
        try:
            conn = self._idle.get_nowait()
        except queue.Empty:
            with self._lock:
                if self._created >= self._size:
                    conn = self._idle.get(timeout=settings.db_connect_timeout)
                else:
                    self._created += 1
                    conn = None
            if conn is None:
                return self._connect()
        try:
            conn.ping(reconnect=True)
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
            conn = self._connect()
        return conn

    def _release(self, conn, broken: bool):
        if broken:
            try:
                conn.close()
            except Exception:
                pass
            with self._lock:
                self._created -= 1
            return
        try:
            self._idle.put_nowait(conn)
        except queue.Full:
            try:
                conn.close()
            except Exception:
                pass
            with self._lock:
                self._created -= 1


_pool = Pool(settings.db_pool_size)


@contextmanager
def cursor():
    conn = _pool._acquire()
    broken = False
    try:
        with conn.cursor() as cur:
            yield cur
    except Exception:
        broken = True
        raise
    finally:
        _pool._release(conn, broken)


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
