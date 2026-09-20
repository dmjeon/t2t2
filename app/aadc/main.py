"""AADC PoC 트랙 C — WAS (FastAPI).

WAS-APP1-500(10.3.21.51) / WAS-DC2(10.7.21.52) 양쪽에 동일한 코드를 올리고
환경변수(AADC_DC, AADC_NODE, AADC_APP_VERSION)로만 구분한다.
카나리 배포(8절)는 DC-400 에 새 버전을 먼저 올리는 방식으로 이 대칭을 이용한다.
"""
import logging
import time

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .config import settings
from .routers import demo, health, info

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("aadc")

app = FastAPI(
    title="AADC PoC WAS",
    description="트랙 C 확정 설계 검증용 애플리케이션",
    version=settings.app_version,
)

app.include_router(info.router)
app.include_router(health.router)
app.include_router(demo.router)


@app.middleware("http")
async def access_log(request: Request, call_next):
    t0 = time.perf_counter()
    response = await call_next(request)
    ms = round((time.perf_counter() - t0) * 1000, 2)
    # nginx 가 심어 준 X-Request-Id 로 WEB 로그와 WAS 로그를 이어 붙인다.
    rid = request.headers.get("x-request-id", "-")
    client = request.client.host if request.client else "-"
    log.info("rid=%s via_l4=%s %s %s -> %s %sms",
             rid, client, request.method, request.url.path,
             response.status_code, ms)
    response.headers["X-Was-Host"] = settings.node
    response.headers["X-Was-Dc"] = settings.dc
    response.headers["X-App-Version"] = settings.app_version
    response.headers["X-Response-Time-Ms"] = str(ms)
    return response


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    log.exception("unhandled error on %s", request.url.path)
    return JSONResponse(
        status_code=500,
        content={"error": f"{type(exc).__name__}: {exc}",
                 "dc": settings.dc, "was_host": settings.node},
    )


@app.get("/")
def root():
    return {"service": "aadc-was", "dc": settings.dc,
            "was_host": settings.node, "app_version": settings.app_version,
            "endpoints": ["/api/info", "/api/version", "/api/db/status",
                          "/api/db/write", "/api/db/read", "/api/load",
                          "/health/deep", "/health/local"]}
