#!/usr/bin/env bash
# =============================================================================
# DB-BACKUP (10.3.31.53) 초기화 — DC-500 내부 semi-sync 복제
#   실행: DB-BACKUP 에서 root 로
#
# 복제 소스는 MASTER 의 **실주소**(10.3.31.51)다. VIP 가 아니다.
#   VIP 를 소스로 잡으면 자기 자신이 VIP 를 잡았을 때 자기를 복제하게 된다.
#   VIP 를 소스로 쓰는 것은 DR(init-03) 뿐이다.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../config.env"
: "${DB_REPL_PASS:?}" "${DB_DUMP_PASS:?}"

DUMP=/var/tmp/aadc-master-dump.sql

echo "== 1. 설정 파일 배치 =="
install -m 0644 "${HERE}/my.cnf.d/aadc-common.cnf" /etc/my.cnf.d/
install -m 0644 "${HERE}/my.cnf.d/aadc-backup.cnf" /etc/my.cnf.d/
systemctl enable --now mariadb
systemctl restart mariadb

echo "== 2. MASTER 덤프 (--gtid 로 gtid_slave_pos 까지 받아온다) =="
mysqldump -h "${DB_MASTER_IP}" -u"${DB_DUMP_USER}" -p"${DB_DUMP_PASS}" \
  --all-databases --single-transaction --gtid --master-data=2 \
  --routines --triggers --events --flush-privileges > "${DUMP}"

echo "== 3. 적재 =="
mysql < "${DUMP}"

echo "== 4. 복제 연결 (MariaDB GTID) =="
# MySQL 의 MASTER_AUTO_POSITION=1 에 해당하는 MariaDB 문법이 MASTER_USE_GTID 다.
mysql <<SQL
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST     = '${DB_MASTER_IP}',
  MASTER_PORT     = 3306,
  MASTER_USER     = '${DB_REPL_USER}',
  MASTER_PASSWORD = '${DB_REPL_PASS}',
  MASTER_USE_GTID = slave_pos,
  MASTER_CONNECT_RETRY = 2,
  MASTER_HEARTBEAT_PERIOD = 1;
START SLAVE;
SQL

sleep 3
echo "== 5. 상태 확인 =="
mysql -e "SHOW SLAVE STATUS\G" | grep -E \
  'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_.*Error|Using_Gtid|Gtid_IO_Pos'
mysql -h "${DB_MASTER_IP}" -u"${DB_MON_USER}" -p"${DB_MON_PASS}" \
  -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_%'" 2>/dev/null || true

cat <<'NOTE'

------------------------------------------------------------------------------
확인할 것:
  · Slave_IO_Running / Slave_SQL_Running  = Yes
  · Using_Gtid                            = Slave_Pos
  · MASTER 쪽 Rpl_semi_sync_master_status = ON   ← 이게 OFF 면 RPO 0 이 아니다
  · MASTER 쪽 Rpl_semi_sync_master_clients = 1

다음: keepalived 구성 (keepalived/README.md) → 그 다음 DB-DR
------------------------------------------------------------------------------
NOTE
