# dcdc — AADC PoC 트랙 C 구현체

[AADC-POC.md](../AADC-POC.md) 트랙 C 확정 설계를 그대로 옮긴 실행 코드다.
문서의 각 절이 어느 파일로 구현됐는지는 아래 대응표를 보면 된다.

- 대상: Viettel IDC Phase 2 PoC (DC-500 / DC-400)
- OS: Rocky Linux 8 / 9
- 스택: nginx · FastAPI · MariaDB · keepalived

---

## 빠른 시작

```bash
cp config.env.example config.env
vi config.env          # AADC_ROLE, AADC_DC, 비밀번호 4개, L4 VIP

./install/00-common.sh         # 전 서버
./install/10-db.sh             # DB-MASTER → DB-BACKUP → (VIP 확인) → DB-DR
./install/20-was.sh            # WAS-APP1-500, WAS-DC2
./install/30-web.sh            # WEB-DC1, WEB-DC2
./install/40-monitor.sh        # 점프서버

./verify/run-all.sh            # 평시 검증
```

자세한 절차와 순서의 근거는 [install/INSTALL.md](install/INSTALL.md).

---

## 구조

```
dcdc/
├── config.env.example     ★ 모든 파라미터의 단일 출처. 여기만 채우면 된다
│
├── app/                   WAS — FastAPI
│   ├── aadc/              config · db · tracing · routers(info/health/demo)
│   └── systemd/           aadc-was.service
│
├── web/                   검증 화면 (nginx 정적 배포)
│   ├── index.html         6개 패널
│   └── assets/            style.css · app.js  (의존성 없음)
│
├── nginx/                 WEB — nginx.conf + conf.d 템플릿
│
├── db/                    MariaDB — my.cnf 3종 · 스키마 · 초기화 3종
│
├── keepalived/            DB VIP — conf 2종 · chk_db · notify · reattach
│
├── dr/                    DR 전환 2단 게이트 · failback 절차
│
├── monitoring/            알람 5종 · 1분 주기 점검 · 복제 심장박동
│
├── verify/                11절 검증 항목 스크립트
│
└── install/               역할별 설치 + INSTALL.md
```

---

## 설계 문서 ↔ 구현 대응

| AADC-POC.md | 구현 |
|---|---|
| 3-1 GSLB | Viettel 설정 항목. [install/INSTALL.md](install/INSTALL.md) §6 에 요청 표 |
| 3-2 WEB (nginx) | [`nginx/`](nginx/) |
| 3-3 L4 C-2 구성 | FortiADC 설정 항목. 점검 VS 는 `nginx /checkvs/` + `monitoring/aadc-probe.sh` 로 검증 |
| 3-4 DB 안전장치 5개 | [`db/`](db/) + [`keepalived/`](keepalived/) |
| 3-4 DR 2단 게이트 | [`dr/`](dr/) |
| 4 헬스체크 2종 | `app/aadc/routers/health.py` + `nginx/conf.d/20-aadc-web.conf.template` |
| 5-1 SNAT / `via_l4` | `app/aadc/tracing.py` |
| 5-2 고객 IP 보존 | `nginx/conf.d/00-realip.conf` |
| 7-③ 필수 알람 5종 | [`monitoring/`](monitoring/) |
| 8 카나리 배포 | `APP_VERSION` + `/api/version` + `verify/05-...sh c19` |
| 11 검증 항목 | [`verify/`](verify/) |
| 15 검증 화면 | [`web/`](web/) |

---

## 이 구현이 붙잡고 있는 원칙

**계층별로 장애 흡수 주체를 분리한다.** 코드가 이 표를 벗어나면 그 코드가 틀린 것이다.

```
DB 장애   → keepalived 가 흡수 (DC-500 내부)   → GSLB 이동 없음
WAS 장애  → L4 backup 멤버가 흡수 (교차)        → GSLB 이동 없음
WEB 장애  → 흡수 주체 없음 (1:1)                → GSLB 이동
DC 장애   → —                                   → GSLB 이동
```

그래서:

- `/health/deep` 은 **로컬 L4 VIP 를 경유한다.** backup 으로 넘어가면 체크도
  backup 을 타므로 WAS 장애가 GSLB 를 움직이지 못한다.
- `/health/local` 은 **L4 를 우회해 로컬 WAS 를 직접 본다.** 반응 주체가
  GSLB 가 아니라 사람이다.
- DB 로컬 전환은 **자동**, DR 전환은 **수동 2단 게이트**. 2 DC 는 쿼럼이 없다.
- 앱은 **DB VIP 에 직접 붙는다.** 중간 프록시를 두지 않는다. writer 가 누구인지는
  keepalived 가 정하고, 앱은 같은 주소로 재연결할 뿐이다. 로컬 failover 에
  앱측 장치가 필요 없으므로 상주 컴포넌트를 WAS 에 올릴 이유가 없다.

---

## ★ 시작하기 전에 알아야 할 것

### 1. 설계 문서의 DB 설정 3곳이 MariaDB 에서 그대로는 동작하지 않는다

문서 3-4절 코드 조각이 MySQL 문법이다. 구현에서 바꿨고, 설계 의도는 유지했다.
근거와 대체 수단은 [db/README.md](db/README.md) 에 정리해 뒀다.

| 문서 | 문제 | 구현 |
|---|---|---|
| `super_read_only = ON` | **MariaDB 에 없는 변수. 적으면 기동 실패** | `read_only=ON` + **DB 에 쓰는 상주 프로세스에 SUPER 를 주지 않는 것** |
| `MASTER_AUTO_POSITION=1` | MySQL 문법 | `MASTER_USE_GTID = slave_pos` |
| (언급 없음) | MariaDB 는 `gtid_domain_id` 가 다르면 DR 이 VIP 를 못 따라간다 | 전 노드 `gtid_domain_id=1` 고정 |

> 2026-09-20: 설계 문서(AADC-POC.md 3-4절 ④)도 이 내용으로 갱신됐다.
> 문서와 구현이 더 이상 어긋나지 않는다.

첫 번째는 **안전장치 ④ 가 MariaDB 에서 반쪽이 된다는 뜻**이다. `read_only=ON`
은 SUPER 를 가진 접속을 막지 못하므로, 권한 설계가 유일한 방어가 된다.

| 계정 | 권한 | 용도 |
|---|---|---|
| `aadc_app` | `aadc.*` CRUD, **SUPER 없음** | 애플리케이션 |
| `aadc_hb` | `aadc.repl_heartbeat` SELECT/UPDATE, **SUPER 없음** | 복제 심장박동 |
| `monitor` | `REPLICATION CLIENT`, **SUPER 없음** | 알람 |
| `root` (unix_socket) | 전권 | `notify_master` 의 `read_only` 해제 **전용** |

**이 구분은 형식이 아니다.** 복제 심장박동을 root 로 돌리면 `read_only=ON` 인
DB-BACKUP 에서도 UPDATE 가 성공해 복제본에 로컬 쓰기가 남고,
`log_slave_updates=ON` + `gtid_strict_mode=ON` 조합에서 GTID 가 갈라진다.
문자 그대로 구현하려면 MySQL 8.0 을 택해야 한다. 판단이 필요한 항목으로 남겨 둔다.

### 2. Viettel 회신 없이는 확정되지 않는 부분

`config.env` 에서 `<<TBD>>` 로 표시했다. 회신 1~3번이 **설계 성립 조건**이며,
회신 전에는 해당 절을 확정으로 취급하지 않는다.

| # | 항목 | 이 구현에서 막히는 것 |
|---|---|---|
| **1** | `peer-routing` RTT + 대역폭 | degraded 허용 시간을 정할 수 없다 (`REPL_LAG_WARN_S` 포함) |
| **2** | FortiADC backup server 지원 여부 | 미지원이면 C-1 로 후퇴. `/checkvs/`·C13·알람 ②⑤ 가 전부 무의미해진다 |
| **3** | GSLB 전 멤버 실패 시 fallback | 없으면 WAS 전멸이 SERVFAIL 로 둔갑. C17 이 이걸 잡는다 |
| 4 | L4 가상 서버 VIP 주소 | `nginx upstream` 이 확정되지 않아 **WEB 계층이 전부 502** |
| 5 | GSLB TTL 최소값 | 20초 설정 가능 여부 |

### 3. 트랙 B(부록 A)를 먼저 끝낸다

이 디렉터리는 **트랙 C 전용**이다. 트랙 B 는 현재 VM 배치(DB-DR 이 `dc-db`
`10.3.31.52` 에 있는 상태)를 그대로 쓰는 실험이므로, 여기 있는 `10.7.31.52`
기준 설정을 적용하면 트랙 B 를 수행할 수 없게 된다.

```
★ 트랙 B 는 DB 에 실데이터를 넣기 전에 끝낸다 (A-0 절).
```

---

## 보안 관련

### 공개 저장소에 두어도 되는 상태로 유지한다

- `config.env` 에는 비밀번호가 들어간다. **커밋하지 않는다** (`.gitignore`).
  관리 대상은 `config.env.example` 뿐이고 거기에는 `CHANGE_ME_*` 자리표시자만 둔다.
- **실제 도메인과 공인 IP 를 넣지 않는다.** `SERVICE_FQDN` 등은
  `www.example.com` 자리표시자이며, 실제 값은 `config.env` 에서 온다.
  사설 대역(10.3.x / 10.7.x)만으로는 대상이 특정되지 않지만, 실도메인이
  함께 있으면 "이 조직의 내부 구조 + 미해결 항목 목록"이 한 곳에 묶인다.
- 커밋 전 확인:
  ```bash
  git ls-files -z | xargs -0 grep -nE '<실도메인>|171\.244\.|CHANGE_ME_[a-z]+[^ ]' 
  ```

### 진단 화면은 인터넷에 열지 않는다

검증 화면과 `/api/db/`, `/checkvs/`, `/peer/` 는 현재 DB writer 호스트명,
semi-sync 상태(= RPO 가 깨졌는지), degraded 여부를 그대로 보여 준다.
WEB 은 `www` 로 인터넷에 노출되므로 관리 대역으로 한정한다.

| 경로 | 제어 | 근거 |
|---|---|---|
| `/`, `/api/db/`, `/checkvs/`, `/peer/` | `ADMIN_ALLOW` | 내부 상태 노출 |
| `/health/deep`, `/health/local` | `HEALTH_ALLOW` | 응답에 writer 호스트명 포함 |
| `/api/info` | **열어 둠** | R5(고객 IP 보존)를 외부에서 검증해야 한다 |
| `/health/web` | 열어 둠 | nginx 생존만. 내부 정보 없음 |

> **`HEALTH_ALLOW` 에 DMZ FortiADC 주소(`10.3.10.241`, `10.7.10.241`)를
> 반드시 포함할 것.** 빠뜨리면 GSLB 헬스체크가 403 을 받고 그 DC 를 빼 버린다.
> 배포 직후 `/health/deep` 이 GSLB 쪽에서 200 인지 확인한다.

### 그 밖에

- 파일 권한: `/etc/aadc/was.env` 0640, `/etc/keepalived/keepalived.conf` 0600
- `VRRP_AUTH_PASS` 는 VRRP 제약으로 **8자 이하**
- 운영 전환 시 기본값이 남아 있지 않은지:
  `grep -r CHANGE_ME /etc/aadc /etc/keepalived`
