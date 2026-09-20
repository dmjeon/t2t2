"""/api/info — 경로 검증의 기준점 (11-2절 R3 / C12 / C13 / R5)."""
import datetime as dt

from fastapi import APIRouter, Request

from .. import db
from ..config import settings
from ..tracing import trace

router = APIRouter(tags=["info"])


@router.get("/api/info")
def info(request: Request, log: bool = False):
    """어느 경로로 들어와 어느 WAS 가 처리했는지를 그대로 되돌려 준다.

      R3   curl <DC500_L4_VIP>:8000/api/info  → was_host = WAS-APP1-500
      C12  동일 요청                           → via_l4  = 10.3.20.x
      C13  curl <DC500_점검VS_VIP>:8000/...    → was_host = WAS-DC2
      R5   curl https://www.example.com/...   → client_ip = 고객 공인 IP
    """
    t = trace(request)
    t["server_time"] = dt.datetime.now(dt.timezone.utc).isoformat()

    if log:
        # 검증 화면에서 남기고 싶을 때만. 평시 헬스체크 트래픽으로 테이블이
        # 불어나지 않도록 기본값은 끈다.
        try:
            db.execute(
                "INSERT INTO access_trace "
                "(req_id, client_ip, via_l4, l4_dc, was_dc, was_host, web_host, app_version) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
                (t["req_id"], t["client_ip"], t["via_l4"], t["l4_dc"],
                 t["was_dc"], t["was_host"], t["web_host"], t["app_version"]),
            )
            t["logged"] = True
        except Exception as exc:                  # noqa: BLE001
            t["logged"] = False
            t["log_error"] = f"{type(exc).__name__}: {exc}"

    return t
