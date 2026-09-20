"""검증 화면이 실제로 두드릴 데모/계측 엔드포인트.

목적은 기능 시연이 아니라 **AADC-POC.md 11절 검증 항목에 숫자를 채우는 것**이다.
  · C2    요청당 쿼리 수 N        → /api/load?queries=N
  · C2-b  로컬 경유 p50/p95 기준선 → /api/load 반복
  · C9-a  degraded 지속 운영       → 같은 호출을 backup 경유 상태에서 반복 비교
"""
import time

from fastapi import APIRouter, HTTPException, Query, Request

from .. import db
from ..config import settings
from ..tracing import trace

router = APIRouter(prefix="/api", tags=["demo"])


@router.get("/db/status")
def db_status():
    """지금 writer 가 누구인가 + semi-sync 가 살아 있는가.

    semi-sync 가 async 로 강등되면 RPO 가 깨진 상태로 조용히 운영된다
    (AADC-POC.md 3-4절 안전장치 ⑤). 화면에서 바로 보이게 한다.
    """
    row = db.query_one(
        "SELECT @@hostname AS hostname, @@server_id AS server_id, "
        "@@global.read_only AS read_only, @@version AS version"
    )
    status = {}
    try:
        for r in db.query_all(
            "SHOW GLOBAL STATUS WHERE Variable_name IN "
            "('Rpl_semi_sync_master_status','Rpl_semi_sync_master_clients',"
            " 'Rpl_semi_sync_master_no_tx','Rpl_semi_sync_master_yes_tx',"
            " 'Rpl_semi_sync_slave_status')"
        ):
            status[r["Variable_name"]] = r["Value"]
    except Exception as exc:                      # noqa: BLE001
        status["error"] = f"{type(exc).__name__}: {exc}"

    semi = status.get("Rpl_semi_sync_master_status")
    return {
        "writer": {
            "hostname": row["hostname"],
            "server_id": row["server_id"],
            "read_only": int(row["read_only"]),
            "version": row["version"],
        },
        "semi_sync": status,
        # ON 이 아니면 RPO 0 이 아니다
        "rpo_zero": semi == "ON",
        "seen_from": {"dc": settings.dc, "was_host": settings.node},
    }


@router.post("/db/write")
def db_write(request: Request, note: str = Query("", max_length=200)):
    """쓰기 1건. DR 전환 2단계 전에는 실패해야 정상이다."""
    t = trace(request)
    try:
        rowid, ms = db.timed(
            db.execute,
            "INSERT INTO write_log (dc, was_host, via_l4, note) VALUES (%s,%s,%s,%s)",
            (settings.dc, settings.node, t["via_l4"], note),
        )
    except Exception as exc:                      # noqa: BLE001
        raise HTTPException(status_code=503,
                            detail=f"write failed: {type(exc).__name__}: {exc}")
    return {"ok": True, "id": rowid, "elapsed_ms": ms,
            "dc": settings.dc, "was_host": settings.node, "via_l4": t["via_l4"]}


@router.get("/db/read")
def db_read(limit: int = Query(10, ge=1, le=100)):
    rows, ms = db.timed(
        db.query_all,
        "SELECT id, dc, was_host, via_l4, note, created_at "
        "FROM write_log ORDER BY id DESC LIMIT %s",
        (limit,),
    )
    for r in rows:
        r["created_at"] = str(r["created_at"])
    return {"rows": rows, "elapsed_ms": ms,
            "dc": settings.dc, "was_host": settings.node}


@router.get("/load")
def load(queries: int = Query(10, ge=1, le=200), write: bool = False):
    """요청 1건이 쿼리 N 건을 낼 때의 실측 지연.

    7-④절 표(`1+N` 곱셈)가 실제로 몇 ms 인지를 이걸로 채운다.
    degraded(교차) 상태에서 같은 값을 다시 재면 증가폭이 바로 나온다.
    """
    t0 = time.perf_counter()
    per = []
    with db.cursor() as cur:
        for i in range(queries):
            q0 = time.perf_counter()
            if write and i == 0:
                cur.execute(
                    "INSERT INTO write_log (dc, was_host, via_l4, note) "
                    "VALUES (%s,%s,%s,'load')",
                    (settings.dc, settings.node, ""),
                )
            else:
                cur.execute("SELECT id FROM write_log ORDER BY id DESC LIMIT 1")
                cur.fetchall()
            per.append(round((time.perf_counter() - q0) * 1000, 3))
    total = round((time.perf_counter() - t0) * 1000, 2)
    per_sorted = sorted(per)
    return {
        "queries": queries,
        "total_ms": total,
        "per_query_avg_ms": round(sum(per) / len(per), 3),
        "per_query_p95_ms": per_sorted[int(len(per_sorted) * 0.95) - 1],
        "dc": settings.dc,
        "was_host": settings.node,
        # 이 값이 곧 DCI 를 탔는지 여부. 평시 DC-400 WAS 는 DB 가 DC-500 에
        # 있으므로 항상 DCI 를 탄다. DR 전환 후에는 관계가 뒤집히므로
        # 고정값이 아니라 실제 접속 대상(AADC_DB_HOST)에서 판정한다.
        "db_host": settings.db_host,
        "db_is_remote": settings.db_dc != settings.dc,
        "db_dc": settings.db_dc,
    }


@router.get("/version")
def version():
    """카나리 배포 검증용 (8절). DC-400 에 먼저 올리고 1% 로 확인한다."""
    return {"app_version": settings.app_version,
            "dc": settings.dc, "was_host": settings.node}
