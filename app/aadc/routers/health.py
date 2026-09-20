"""헬스체크 2종 — AADC-POC.md 4절.

용도가 다르므로 절대 하나로 겸하지 않는다.

  /health/deep   GSLB 전용.  WEB(nginx) 이 로컬 L4 VIP:8000 으로 호출하므로
                 실트래픽과 동일 경로를 탄다. backup 멤버로 넘어가 있으면
                 체크도 backup 을 타고, 그래서 "WAS 장애로는 DC 가 넘어가지
                 않는다"는 의도가 별도 로직 없이 성립한다.
                 여기(WAS)에서는 **writer 도달 확인**을 담당한다.
                 DCI 가 끊기면 DC-400 은 쓰기를 못 하므로 스스로 실패해
                 GSLB 에서 빠져야 한다. 이 확인이 그 장치다.

  /health/local  알람 전용. GSLB 는 보지 않는다. WEB 이 로컬 WAS 를 **직접**
                 호출한다(L4 우회). 실패 = "backup 으로 넘어가 있다" 이며
                 사람이 WAS 를 고쳐야 한다는 신호다.
"""
import time

from fastapi import APIRouter, Response

from .. import db
from ..config import settings

router = APIRouter(tags=["health"])

_cache: dict = {}


def _cached(key: str, fn):
    now = time.monotonic()
    hit = _cache.get(key)
    if hit and now - hit[0] < settings.health_cache_ttl:
        return hit[1]
    value = fn()
    _cache[key] = (now, value)
    return value


def _probe_writer() -> dict:
    """지금 접속 대상(AADC_DB_HOST)의 writer 에 실제로 닿는가."""
    t0 = time.perf_counter()
    row = db.query_one(
        "SELECT @@hostname AS hostname, @@server_id AS server_id, "
        "@@global.read_only AS read_only"
    )
    detail = {
        "writer_hostname": row["hostname"],
        "writer_server_id": row["server_id"],
        "writer_read_only": int(row["read_only"]),
    }

    # read_only=1 인 노드가 writer 로 잡혀 있으면 쓰기는 전부 실패한다.
    # 도달만 확인하고 넘어가면 이 상태를 놓친다.
    if int(row["read_only"]) != 0:
        raise RuntimeError("writer is read_only")

    if settings.deep_writer_probe == "write":
        db.execute(
            "INSERT INTO health_probe (node, dc) VALUES (%s, %s) "
            "ON DUPLICATE KEY UPDATE probed_at = CURRENT_TIMESTAMP(3), n = n + 1",
            (settings.node, settings.dc),
        )
        detail["write_probe"] = "ok"

    detail["writer_rtt_ms"] = round((time.perf_counter() - t0) * 1000, 2)
    return detail


@router.get("/health/deep")
def health_deep(response: Response):
    """GSLB 전용. 200 이어야만 이 DC 가 서비스 대상으로 남는다."""
    base = {
        "check": "deep",
        "dc": settings.dc,
        "was_host": settings.node,
        "app_version": settings.app_version,
    }
    try:
        detail = _cached("deep", _probe_writer)
    except Exception as exc:                      # noqa: BLE001
        response.status_code = 503
        return {**base, "status": "fail", "reason": "writer_unreachable",
                "error": f"{type(exc).__name__}: {exc}"}
    return {**base, "status": "ok", **detail}


@router.get("/health/local")
def health_local():
    """알람 전용. 이 WAS 프로세스 자체의 생존만 본다.

    DB 를 보지 않는 것이 의도다. DB 장애까지 여기서 실패시키면
    "backup 으로 넘어가 있다"는 신호가 DB 장애에 묻힌다.
    """
    return {
        "check": "local",
        "status": "ok",
        "dc": settings.dc,
        "was_host": settings.node,
        "app_version": settings.app_version,
        "uptime_s": round(time.time() - _STARTED, 1),
    }


_STARTED = time.time()
