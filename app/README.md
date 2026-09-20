# WAS (FastAPI)

WAS-APP1-500 / WAS-DC2 에 **동일한 코드**를 올리고 환경변수로만 구분한다.
카나리 배포(8절)가 이 대칭을 이용한다 — DC-400 에 새 버전을 먼저 올린다.

```
aadc/
  config.py     환경변수 (AADC_DC / AADC_NODE / AADC_APP_VERSION / DB)
  db.py         DB VIP 직결 커넥션 풀
  tracing.py    요청 경로 추적 (5-1 / 5-2절)
  main.py       앱 + 미들웨어
  routers/
    info.py     /api/info
    health.py   /health/deep, /health/local
    demo.py     /api/db/*, /api/load, /api/version
```

---

## 엔드포인트

| 경로 | 용도 | 검증 항목 |
|---|---|---|
| `GET /api/info` | 어느 경로로 들어와 누가 처리했는가 | R3, C12, C13, R5 |
| `GET /health/deep` | **GSLB 전용.** writer 도달 + `read_only=0` 확인 | C15, C18, C8 |
| `GET /health/local` | **알람 전용.** 이 WAS 프로세스 생존만 | C16 |
| `GET /api/db/status` | writer 신원 + semi-sync 상태 | C6 |
| `POST /api/db/write` | 쓰기 1건 | DR 게이트 |
| `GET /api/db/read` | 최근 쓰기 조회 | |
| `GET /api/load?queries=N` | N 쿼리 지연 실측 | C2, C2-b, C9-a |
| `GET /api/version` | 배포된 버전 | C19 |

---

## `db.py` 가 DB VIP 에 직접 붙는 이유

접속 대상은 `AADC_DB_HOST` 하나로 정해진다. 평시에는 DB VIP `10.3.31.50` 이다.

**로컬 failover 는 앱이 알 필요가 없다.** DB-MASTER 가 죽으면 keepalived 가
VIP 를 `.53` 으로 옮기고, 커넥션 풀은 같은 주소로 재연결하면 끝난다. 중간에
프록시를 둘 이유가 여기서는 생기지 않는다.

**DR 전환만 앱을 건드린다.** `was.env` 를 고치고 앱을 재시작하는 수동 절차이며,
재시작 창 동안 그 WAS 는 503 이다. WAS 를 한 대씩 돌리면 L4 가 흡수한다.
절차는 [`dr/`](../dr/) 에 있다.

---

## `/health/deep` 이 `read_only` 까지 보는 이유

도달 확인만 하면 "writer 에 닿기는 하는데 그 노드가 `read_only=1`" 인 상태를
놓친다. 읽기는 되고 쓰기만 전부 실패하는데 헬스체크는 초록불인 상태다.

```python
if int(row["read_only"]) != 0:
    raise RuntimeError("writer is read_only")
```

**DC-400 에서 특히 중요하다.** DCI 가 끊기면 DC-400 은 writer 에 닿지 못하므로
스스로 deep check 를 실패시켜 GSLB 에서 빠져야 한다. 이것이 없으면 1% 사용자가
계속 DC-400 으로 가서 쓰기만 실패한다 (C8).

`AADC_DEEP_WRITER_PROBE=write` 로 두면 실제 `INSERT` 까지 수행한다. 더 엄격하지만
3초 주기로 쓰기가 발생하므로 기본값은 `select` 다.

---

## `/health/local` 이 DB 를 보지 않는 이유

DB 장애까지 여기서 실패시키면 **"backup 으로 넘어가 있다"는 신호가 DB 장애에
묻힌다.** 두 알람은 대응이 완전히 다르다 — 하나는 WAS 를 고치는 일이고 다른
하나는 DB 를 보는 일이다. 섞으면 둘 다 늦어진다.

---

## `via_l4` 가 경로를 말해 준다

L4 가 Full NAT(SNAT)이므로 WAS 입장의 클라이언트는 nginx 가 아니라 **L4** 다.
교차를 없앤 설계의 부수 효과로, `req.client.host` 하나가 어느 DC 가 처리했는지를
직접 말해 준다.

```
l4_dc == was_dc   →  로컬 경유 (평시)
l4_dc != was_dc   →  교차 경유 = L4 backup 멤버 동작 중 = degraded
```

`cross_dc` 필드가 이 판정을 그대로 담고 있고, 검증 화면과 알람 ② 가 둘 다
이 값을 본다.

---

## 로컬 실행 (개발/검토용)

```bash
cd app
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
AADC_DC=DC-500 AADC_NODE=dev AADC_DB_HOST=127.0.0.1 AADC_DB_PORT=3306 \
AADC_DB_USER=aadc_app AADC_DB_PASS=... \
  uvicorn aadc.main:app --reload --port 8000
```
