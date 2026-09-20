"""요청 경로 추적 — AADC-POC.md 5-1 / 5-2절.

L4 가 Full NAT(SNAT) 이므로 req.client.host 는 고객도 nginx 도 아닌 **L4 의 주소**다.
이것이 곧 "어느 DC 의 L4 를 경유했는가"를 말해 주므로, 교차 경유(backup 멤버 동작)
여부를 별도 장치 없이 판정할 수 있다.

    고객(1.2.3.4) → DMZ FortiADC → nginx(WEB) → 내부 L4 → WAS
                         ↑                         ↑
                    XFF 삽입 지점           req.client.host = SNAT 된 L4 IP
"""
from fastapi import Request

from .config import settings


def dc_of_l4(via_l4: str) -> str:
    if via_l4.startswith(settings.l4_prefix_dc500):
        return "DC-500"
    if via_l4.startswith(settings.l4_prefix_dc400):
        return "DC-400"
    return "unknown"


def trace(req: Request) -> dict:
    xff = req.headers.get("x-forwarded-for", "")
    via_l4 = req.client.host if req.client else ""
    l4_dc = dc_of_l4(via_l4)
    return {
        # 고객 IP. nginx 가 real_ip 로 복원해 XFF 맨 앞에 실어 보낸다.
        "client_ip": xff.split(",")[0].strip() or via_l4,
        "xff": xff,
        # SNAT 된 L4 주소
        "via_l4": via_l4,
        # 경유한 L4 가 속한 DC
        "l4_dc": l4_dc,
        # 실제로 처리한 WAS 가 속한 DC
        "was_dc": settings.dc,
        # 두 값이 다르면 = L4 backup(교차) 멤버로 넘어가 있다 = degraded (7절)
        "cross_dc": l4_dc != "unknown" and l4_dc != settings.dc,
        # 기존 문서 표기 호환 (11-2절 C12/C13 판정 기준)
        "dc_path": l4_dc,
        "was_host": settings.node,
        "web_host": req.headers.get("x-web-host"),
        "web_addr": req.headers.get("x-web-addr"),
        "req_id": req.headers.get("x-request-id"),
        "app_version": settings.app_version,
    }
