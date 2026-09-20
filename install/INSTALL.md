# 설치 절차

대상 OS: **Rocky Linux 8 / 9** (현재 WEB-DC2 가 Rocky 라는 것이 GSLB.md §에서 확인된다)
실행 권한: 전부 `root`

---

## 0. 순서를 지켜야 하는 이유

AADC-POC.md 14절의 순서를 그대로 따른다. 특히 **DB 계층(5번)을 WEB/L4/WAS(6번)보다
먼저** 한다. DB 자동 전환이 검증되지 않은 상태에서 위 계층을 얹으면 장애 원인
분리가 되지 않는다.

```
1.  부록 A — 트랙 B (L2 확장 실험)        ← 현재 VM 배치 그대로. 실데이터 적재 전에 끝낼 것
2.  C1 DCI RTT·대역폭 측정                ← 1과 병행 가능.  verify/01-baseline-c1-c2.sh
3.  회신 2번 확인 → C-2 / C-1 확정
4.  DB-DR → 10.7.31.52 (dr-db) 이전
    DB-BACKUP VM 요청 + 생성
    WAS-DC2 IP 할당 (10.7.21.52)
5.  DB 계층 구축          → install/10-db.sh        → C3 ~ C7
6.  WEB / L4 / WAS 구축   → install/20-was.sh, 30-web.sh → R1~R6, C12, C13
7.  헬스체크 2종 + 알람    → install/40-monitor.sh   → C15 ~ C18
8.  GSLB 99:1 + TTL 20초 + fallback                 → C8, C10, C11
9.  D 훈련 1회 (degraded 지속 30분)                  → C9, C9-a   ★ 핵심 산출물
10. 카나리 배포 절차 리허설                          → C19
11. 운영 기준 확정 (허용 시간, 알람 임계)             ← C1 + C9-a 결과
```

---

## 1. 공통 준비 (전 서버)

```bash
# 배포물을 각 서버로 복사
scp -r dcdc/ root@<서버>:/root/

cd /root/dcdc
cp config.env.example config.env
vi config.env          # ★ AADC_ROLE, AADC_DC, 비밀번호 4개, L4 VIP
./install/00-common.sh
```

`config.env` 에서 **서버마다 반드시 바꿔야 하는 것**은 두 줄이다.

| 서버 | `AADC_ROLE` | `AADC_DC` |
|---|---|---|
| WEB-DC1 | `WEB-DC1` | `DC-500` |
| WEB-DC2 | `WEB-DC2` | `DC-400` |
| WAS-APP1-500 | `WAS-APP1-500` | `DC-500` |
| WAS-DC2 | `WAS-DC2` | `DC-400` |
| DB-MASTER | `DB-MASTER` | `DC-500` |
| DB-BACKUP | `DB-BACKUP` | `DC-500` |
| DB-DR | `DB-DR` | `DC-400` |

비밀번호 4개(`DB_APP_PASS` `DB_REPL_PASS` `DB_MON_PASS` `VRRP_AUTH_PASS`)는
**전 서버에서 같은 값**이어야 한다. `VRRP_AUTH_PASS` 는
VRRP 제약으로 8자 이하다.

---

## 2. DB 계층 (5번)

```bash
# ① DB-MASTER (10.3.31.51)
./install/10-db.sh

# ② DB-BACKUP (10.3.31.53)   ← 신규 VM. MASTER 와 동일 사양(16GB/4vCPU/76GB)
./install/10-db.sh

# ③ 확인 — 쓰기 가능 노드가 정확히 1개여야 한다
./db/check-replication.sh
./verify/04-db-c3-c7.sh status

# ④ DB-DR (10.7.31.52)  ← VIP 가 살아난 뒤에 실행한다 (복제 소스가 VIP 다)
./install/10-db.sh
```

검증: `verify/04-db-c3-c7.sh` (C3~C7). 장애 주입은 사람이 하고 스크립트가 판정한다.

---

## 3. WAS 계층 (6번)

```bash
# WAS-APP1-500 / WAS-DC2 양쪽에서
./install/20-was.sh
```

FastAPI 가 올라가고 DB VIP 에 직접 붙는다. `/health/deep` 이 200 이면
writer 까지 경로가 뚫린 것이다.

> **DC-400 의 `AADC_APP_VERSION` 을 DC-500 보다 먼저 올리는 것이 카나리 배포다**(8절).
> `config.env` 의 `APP_VERSION` 만 바꾸고 `20-was.sh` 를 다시 돌리면 된다.

---

## 4. WEB 계층 (6번)

```bash
# WEB-DC1 / WEB-DC2 양쪽에서
./install/30-web.sh
```

`config.env` 의 `DC500_L4_VIP` / `DC400_L4_VIP` 가 `<<TBD>>` 기본값이면
전부 502 가 난다. **회신 4번(내부 L4 VS VIP 주소)이 선행 조건**이다.

---

## 5. 모니터링 / 알람 (7번)

```bash
# 점프서버 또는 모니터링 호스트에서
./install/40-monitor.sh
vi /etc/aadc/monitor.env      # ★ 알람 수신처
```

---

## 6. GSLB (8번) — Viettel 설정 항목

서버에서 할 일이 아니다. DMZ FortiADC 에 아래를 요청·설정한다.

| 항목 | 값 |
|---|---|
| `www.example.com` | DC-500 **99** : DC-400 **1** |
| 헬스체크 | `GET /health/deep`, HTTP 200 판정 |
| 체크 주기 / 재시도 | 3초 / 2회 (감지 약 6초) |
| TTL | **20초** |
| **전 멤버 실패 시** | **DC-500 정적 반환 (fallback)** ← SERVFAIL 방지 |
| 검증 FQDN | `web1.example.com` → WEB-DC1 고정<br>`web2.example.com` → WEB-DC2 고정 |
| **DMZ FortiADC** | **X-Forwarded-For 삽입** (또는 transparent 모드) |

fallback 이 없으면 WAS 전멸이 SERVFAIL 로 둔갑한다. 502 보다 나쁘다 — 사용자에게는
"사이트에 연결할 수 없음"으로, 모니터링에는 DNS 장애로 보이고, 네거티브 캐싱까지 탄다.

---

## 7. 설치 후 점검

```bash
./verify/run-all.sh              # 평시에 돌릴 수 있는 것 전부
```

| 증상 | 원인 |
|---|---|
| 전부 502 | 내부 L4 미기동 / L4 VIP 오기입 / SELinux `httpd_can_network_connect` |
| `via_l4` 가 nginx IP | L4 가 Full NAT 가 아니라 DNAT 만 걸려 있다 (5-1절) |
| `client_ip` 가 `10.3.10.241` | DMZ FortiADC XFF 삽입 누락. **서버에서 못 고친다** |
| `/health/deep` 503 `writer_unreachable` | VIP 를 잡은 노드가 없거나 `read_only=1` |
| `/health/deep` 503 `writer is read_only` | DR 전환 1단계만 실행된 상태 (의도된 상태). 2단계 전까지는 정상 |
| C13 실패 | FortiADC backup server 미지원 (회신 2번) 또는 점검 VS 미구성 |

---

## 8. 오프라인 설치

PoC 망에서 인터넷이 막혀 있으면(FW-06 미적용) 아래를 미리 내려받아 반입한다.

```bash
# 인터넷 되는 곳에서
dnf download --resolve --destdir=./rpms nginx mariadb-server mariadb keepalived python3 python3-pip
pip3 download -d ./wheels -r dcdc/app/requirements.txt

# PoC 망에서
dnf -y install ./rpms/*.rpm
/opt/aadc/venv/bin/pip install --no-index --find-links=./wheels -r requirements.txt
```
