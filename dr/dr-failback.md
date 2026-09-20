# DR 복귀 절차

> **C 훈련(반기 1회)이 비싼 이유가 이것이다.** DR 을 승격해 쓰기를 받으면
> DC-500 과 데이터가 갈라진다. 복귀하려면 역방향 복제를 다시 걸어야 한다.
> 훈련 계획에 이 절차와 **소요 시간 실측**을 반드시 포함한다.

---

## 전제 확인

```bash
# 어느 쪽이 정본인가 — 이 판단이 전부다
mysql -h 10.7.31.52 -e "SELECT MAX(id), MAX(created_at) FROM aadc.write_log"   # DR
mysql -h 10.3.31.50 -e "SELECT MAX(id), MAX(created_at) FROM aadc.write_log"   # DC-500
mysql -h 10.7.31.52 -e "SELECT * FROM aadc.failover_log ORDER BY id DESC LIMIT 5"
```

DR 승격 이후 DC-500 에서도 쓰기가 들어갔다면 **두 데이터가 갈라진 것이다.**
자동으로 병합할 방법은 없다. 사람이 어느 쪽을 버릴지 정해야 한다.

---

## 경로 A — DC-500 을 DR 의 슬레이브로 붙였다가 되돌린다 (권장)

데이터 정본이 DR 쪽인 경우.

```bash
# 1. DC-500 을 DR 의 슬레이브로 (MASTER, BACKUP 각각)
mysql -e "
  SET GLOBAL read_only = ON;
  STOP SLAVE; RESET SLAVE ALL;
  SET GLOBAL gtid_slave_pos = '';
"
# 데이터 차이가 크면 덤프부터. 작으면 GTID 만으로 따라잡는다.
mysqldump -h 10.7.31.52 -urepl -p --all-databases --single-transaction --gtid \
  --master-data=2 --flush-privileges > /var/tmp/dr-dump.sql
mysql < /var/tmp/dr-dump.sql
mysql -e "
  CHANGE MASTER TO MASTER_HOST='10.7.31.52', MASTER_USER='repl', MASTER_PASSWORD='***',
                   MASTER_USE_GTID=slave_pos;
  START SLAVE;
"

# 2. 따라잡을 때까지 대기
watch -n2 "mysql -e \"SELECT TIMESTAMPDIFF(SECOND, beat_at, NOW()) FROM aadc.repl_heartbeat WHERE id=1\""

# 3. 짧은 쓰기 정지 창을 잡는다 (서비스 영향 구간)
#    DR: read_only=ON  →  DC-500 이 완전히 따라잡았는지 확인  →  방향 전환
mysql -h 10.7.31.52 -e "SET GLOBAL read_only = ON"

# 4. DC-500 을 다시 정본으로
#    MASTER 에서
mysql -e "STOP SLAVE; RESET SLAVE ALL;"
systemctl restart keepalived        # VIP 를 다시 잡으면 notify_master 가 read_only 를 푼다
#    BACKUP 에서
/root/dcdc/keepalived/bin/reattach-slave.sh <현재 VIP 보유 노드 IP>

# 5. DR 을 다시 VIP 의 슬레이브로
#    DB-DR 에서
/root/dcdc/db/init-03-dr.sh         # VIP 를 소스로 복제 재구축

# 6. WAS 를 되돌린다 (모든 WAS 에서, 한 대씩)
sed -i -e "s/^AADC_DB_HOST=.*/AADC_DB_HOST=10.3.31.50/" \
       -e "s/^AADC_DB_PORT=.*/AADC_DB_PORT=3306/" /etc/aadc/was.env
systemctl restart aadc-was
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/health/deep   # 200 이어야 한다
```

> 6번은 **한 대씩** 돌린다. 재시작 창 동안 그 WAS 는 503 이고, L4 가 나머지
> 한 대로 흡수한다. 전부 동시에 재시작하면 그 순간 서비스가 끊긴다.

---

## 경로 B — DR 쓰기를 버린다 (훈련에서 흔히 쓰는 방식)

훈련 중 DR 에 들어간 쓰기가 버려도 되는 것이라면 이쪽이 훨씬 빠르다.

```bash
# DB-DR 에서
mysql -e "SET GLOBAL read_only = ON; STOP SLAVE; RESET SLAVE ALL; RESET MASTER;"
/root/dcdc/db/init-03-dr.sh         # VIP 에서 다시 받아온다
# WAS 를 되돌린다 (위 6번과 동일, 한 대씩)
```

---

## 기록할 것

| 항목 | 값 |
|---|---|
| 1단계(was.env 전환) → 2단계(read_only) 사이 판단 시간 | |
| **1단계 재시작 창** — WAS 1대당 503 지속 시간 | |
| 2단계 이후 쓰기가 실제로 열리기까지 | |
| **복귀 총 소요 시간** | |
| 복귀 중 쓰기 정지 창 | |
| 유실된 쓰기 건수 (async RPO) | |

**복귀 총 소요 시간이 C 훈련의 핵심 산출물이다.** 이 숫자가 없으면
"DR 전환은 가능하다"는 말에 근거가 없다.
