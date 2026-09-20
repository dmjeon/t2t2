# DB 계층

DC-500 active/backup + DC-400 DR 전용. **회사 확정 사항이며 재설계 대상이 아니다.**

```
복제   MASTER 10.3.31.51 ──semi-sync──► BACKUP 10.3.31.53    (DC-500 내부, RPO 0)
       VIP    10.3.31.50 ──async GTID─► DB-DR  10.7.31.52    (DC-400)

접속   WAS → 10.3.31.50 (VIP) 직결      평시
       WAS → 10.7.31.52                DR시 (was.env 수정 + 앱 재시작, 수동)
```

DR 은 개별 노드가 아니라 **VIP 를 복제 소스로 잡는다.** 로컬 failover 가 일어나도
DR 이 재설정 없이 따라간다.

---

## 파일

| 파일 | 대상 | 내용 |
|---|---|---|
| `my.cnf.d/aadc-common.cnf` | 전 노드 | `read_only=ON`, GTID, binlog, InnoDB |
| `my.cnf.d/aadc-master.cnf` | MASTER | `server_id=51`, semi-sync master |
| `my.cnf.d/aadc-backup.cnf` | BACKUP | `server_id=53`, semi-sync slave + master(승격 대비) |
| `my.cnf.d/aadc-dr.cnf` | DR | `server_id=72`, async only |
| `sql/01-schema.sql` | MASTER | 스키마 (복제로 전파) |
| `sql/02-grants.sql` | MASTER | 계정 4종 |
| `init-01~03-*.sh` | 각각 | 설정 배치 + 초기화 + 복제 연결 |
| `check-replication.sh` | 아무 곳 | 4 노드 상태 한 눈에 |

---

## ★ 설계 문서와 다르게 구현한 3가지

AADC-POC.md 3-4절의 코드 조각은 **MySQL 문법**으로 쓰여 있다. MariaDB 로 가면
그대로는 동작하지 않아 아래처럼 바꿨다. 설계 의도는 그대로다.

### ① `super_read_only` — MariaDB 에 없는 변수다

```ini
# 설계 문서 (3-4절 ④)
read_only       = ON
super_read_only = ON        # ← MariaDB 에는 존재하지 않는다. 적으면 기동 실패
```

MariaDB 는 `super_read_only` 를 지원하지 않는다. SUPER 권한 보유자는
`read_only=ON` 이어도 쓸 수 있다는 구멍이 남는다는 뜻이다.

**대체 수단은 권한 설계뿐이다.** `sql/02-grants.sql` 에서 `aadc_app` 에
SUPER 를 주지 않는다. 쓰기 경로에 SUPER 계정이 없으면 구멍이 열리지 않는다.

MySQL 8.0 을 쓴다면 `aadc-common.cnf` 의 해당 줄 주석을 풀면 그만이다.
안전장치 ④ 를 문자 그대로 구현하고 싶다면 그쪽이 낫다 — **선택 사항으로 남겨 둔다.**

### ② `MASTER_AUTO_POSITION=1` → `MASTER_USE_GTID=slave_pos`

앞은 MySQL, 뒤가 MariaDB 다. 기능은 같다. `init-02` / `init-03` 이 후자를 쓴다.

### ③ `gtid_domain_id` 를 전 노드 동일하게 고정

MariaDB GTID 에만 있는 개념이다. `.51` 과 `.53` 의 도메인이 다르면 로컬
failover 후 DR 이 GTID 를 이어받지 못한다. **"DR 이 VIP 를 따라간다"는 설계의
전제가 MariaDB 에서는 이 설정에 걸려 있다.** 전부 `gtid_domain_id=1`.

---

## 안전장치 5개가 어디에 구현돼 있나

| | 내용 | 구현 위치 |
|---|---|---|
| ① | VRRP unicast | `keepalived/keepalived.conf.*` — `unicast_src_ip` / `unicast_peer` |
| ② | `nopreempt` | 같은 파일 |
| ③ | 게이트웨이 증인 | `keepalived/bin/chk_db.sh` |
| ④ | 재기동 시 쓰기 차단 | `my.cnf.d/aadc-common.cnf` + `keepalived/bin/aadc-notify.sh` |
| ⑤ | semi-sync 타임아웃 | `my.cnf.d/aadc-master.cnf` — `rpl_semi_sync_master_timeout=1000` |

④ 는 두 곳에 나뉘어 있다. **설정 파일이 전 노드의 쓰기를 닫아 두고,
VIP 를 잡은 노드만 notify 스크립트가 연다.** 둘 중 하나만으로는 성립하지 않는다.

⑤ 의 강등은 정상 동작이지만 **알람이 필수**다. 조용히 RPO 가 깨진 채로 운영되는
것을 막아야 한다 → `monitoring/bin/aadc-alarm.sh` ③.

---

## 복제 지연을 heartbeat 로 재는 이유

`Seconds_Behind_Master` 는 **쓰기가 없는 구간에서 0 으로 보인다.** DCI 가 끊겨도
그 순간 쓰기가 없으면 0 이다. 야간에 DCI 가 끊겼는데 지연 알람이 침묵하는 일이
실제로 이렇게 일어난다.

`repl_heartbeat` 테이블에 writer 가 5초마다 박동을 찍고(`aadc-repl-heartbeat.sh`),
DR 에서 `NOW() - beat_at` 을 본다. `UPDATE` 는 `read_only=OFF` 인 노드에서만
성공하므로 **조건 분기 없이 현재 writer 가 알아서 찍는다.**

---

## 전환 정책

| 전환 | 방식 | 근거 |
|---|---|---|
| 로컬 (`.51` ↔ `.53`) | **자동** — keepalived + VIP + `read_only` 해제 | 장애 도메인이 DC 내부라 ③ 으로 고립 판별 가능. semi-sync 로 데이터 손실 0 |
| DR (DC-500 → DC-400) | **수동 2단 게이트** | DCI 단절과 DC 장애를 구분할 방법이 없음 |

DR 전환은 [`dr/`](../dr/) 아래 두 스크립트로 나뉘어 있다. 1단계를 실수로 눌러도
쓰기가 되지 않으므로 데이터가 갈라지지 않는다. 그것이 나눈 이유다.
