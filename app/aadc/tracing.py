"""요청 경로 추적 — AADC-POC.md 5-1 / 5-2절.

L4 가 Full NAT(SNAT) 이므로 req.client.host 는 고객도 nginx 도 아닌 **L4 의 주소**다.
이것이 곧 "어느 DC 의 L4 를 경유했는가"를 말해 주므로, 교차 경유(backup 멤버 동작)
여부를 별도 장치 없이 판정할 수 있다.

    고객(1.2.3.4) → DMZ FortiADC → nginx(WEB) → 내부 L4 → WAS
                         ↑                         ↑
                    XFF 삽입 지점           req.client.host = SNAT 된 L4 IP

단, 내부 L4 가 꺼져 있어 WEB 이 WAS 를 직접 호출하는 동안(UPSTREAM_MODE=direct)
클라이언트는 L4 가 아니라 WEB 자신이다. 그 상태를 "unknown" 으로 뭉뚱그리면
"경로를 모르겠다"와 "L4 를 일부러 건너뛰었다"가 구분되지 않는다. 구분한다.
"""
from fastapi import Request

from .config import settings


def classify_hop(via: str) -> tuple:
    """(path_mode, dc) — 바로 앞 홉이 무엇이고 어느 DC 인가."""
    if via.startswith(settings.l4_prefix_dc500):
        return "l4", "DC-500"
    if via.startswith(settings.l4_prefix_dc400):
        return "l4", "DC-400"
    # L4 우회: WEB 이 직접 붙었다
    if via.startswith(settings.web_prefix_dc500):
        return "direct", "DC-500"
    if via.startswith(settings.web_prefix_dc400):
        return "direct", "DC-400"
    return "unknown", "unknown"


def dc_of_l4(via_l4: str) -> str:
    """구 표기 호환. 경유 DC 만 돌려준다."""
    return classify_hop(via_l4)[1]


def trace(req: Request) -> dict:
    xff = req.headers.get("x-forwarded-for", "")
    via = req.client.host if req.client else ""
    path_mode, hop_dc = classify_hop(via)

    return {
        # 고객 IP. nginx 가 real_ip 로 복원해 XFF 맨 앞에 실어 보낸다.
        "client_ip": xff.split(",")[0].strip() or via,
        "xff": xff,
        # 바로 앞 홉의 주소 (L4 모드면 SNAT 된 L4, direct 모드면 WEB)
        "via_l4": via,
        # l4 | direct | unknown  — direct 면 L4 를 건너뛴 임시 구성이다
        "path_mode": path_mode,
        "l4_bypassed": path_mode == "direct",
        # 앞 홉이 속한 DC
        "l4_dc": hop_dc,
        # 실제로 처리한 WAS 가 속한 DC
        "was_dc": settings.dc,
        # 두 값이 다르면 = 교차로 넘어가 있다 = degraded (7절)
        # ★ direct 모드에서는 L4 backup 이 없으므로 이 값이 true 가 될 일이 없다.
        #   "교차가 안 일어난다"가 아니라 "일어날 수단이 없다"는 뜻이다.
        "cross_dc": hop_dc not in ("unknown",) and hop_dc != settings.dc,
        # 기존 문서 표기 호환 (11-2절 C12/C13 판정 기준)
        "dc_path": hop_dc,
        "was_host": settings.node,
        "web_host": req.headers.get("x-web-host"),
        "web_addr": req.headers.get("x-web-addr"),
        "req_id": req.headers.get("x-request-id"),
        "app_version": settings.app_version,
    }
