#!/usr/bin/env bash
# =============================================================================
# DB-DR (10.7.31.52, dr-db) 초기화 — DC-400 비동기 GTID 복제
#   실행: DB-DR 에서 root 로
#   전제: keepalived 가 이미 떠 있고 VIP(10.3.31.50)가 살아 있을 것
#
# ★ 복제 소스는 개별 노드가 아니라 **VIP** 다 (AADC-POC.md 3-4절).
#   로컬 failover(.51 ↔ .53)가 일어나도 DR 이 재설정 없이 따라간다.
#   .51 과 .53 의 gtid_domain_id 가 같아야 이 성질이 성립한다.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../config.env"
: "${DB_REPL_PASS:?}" "${DB_DUMP_PASS:?}"

DUMP=/var/tmp/aadc-vip-dump.sql

echo "== 0. VIP 도달 확인 =="
ping -c2 -W2 "${DB_VIP}" >/dev/null || { echo "VIP ${DB_VIP} 에 닿지 않는다. keepalived 먼저."; exit 1; }
mysql -h "${DB_VIP}" -u"${DB_DUMP_USER}" -p"${DB_DUMP_PASS}" -e "SELECT @@hostname, @@read_only"

echo "== 1. 설정 파일 배치 =="
install -m 0644 "${HERE}/my.cnf.d/aadc-common.cnf" /etc/my.cnf.d/
install -m 0644 "${HERE}/my.cnf.d/aadc-dr.cnf"     /etc/my.cnf.d/
systemctl enable --now mariadb
systemctl restart mariadb

echo "== 2. VIP 에서 덤프 =="
mysqldump -h "${DB_VIP}" -u"${DB_DUMP_USER}" -p"${DB_DUMP_PASS}" \
  --all-databases --single-transaction --gtid --master-data=2 \
  --routines --triggers --events --flush-privileges > "${DUMP}"

echo "== 3. 적재 =="
mysql < "${DUMP}"

echo "== 4. 복제 연결 =="
mysql <<SQL
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST     = '${DB_VIP}',
  MASTER_PORT     = 3306,
  MASTER_USER     = '${DB_REPL_USER}',
  MASTER_PASSWORD = '${DB_REPL_PASS}',
  MASTER_USE_GTID = slave_pos,
  MASTER_CONNECT_RETRY = 5,
  MASTER_HEARTBEAT_PERIOD = 5;
START SLAVE;
SQL

sleep 3
mysql -e "SHOW SLAVE STATUS\G" | grep -E \
  'Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Using_Gtid'
mysql -e "SELECT @@read_only AS read_only  /* 반드시 1 이어야 한다 */"

cat <<'NOTE'

------------------------------------------------------------------------------
read_only = 1 을 반드시 확인할 것.

  DR 은 사람이 2단계 게이트를 열기 전까지 절대 쓰기를 받지 않는다.
      1단계  WAS 의 AADC_DB_HOST → 10.7.31.52 + 재시작  (dr/dr-failover-step1)
      2단계  DB-DR 에서 read_only=OFF                    (dr/dr-failover-step2)
  1단계만 눌러도 쓰기가 되지 않으므로 데이터가 갈라지지 않는다. 그게 분리한 이유다.

검증: C7 — DB-MASTER 를 내려 VIP 를 .53 으로 옮긴 뒤에도
      여기 Slave_IO_Running 이 Yes 로 유지되는가 (재설정 없이 따라가는가)
------------------------------------------------------------------------------
NOTE
