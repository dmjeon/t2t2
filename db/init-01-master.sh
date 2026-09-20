#!/usr/bin/env bash
# =============================================================================
# DB-MASTER (10.3.31.51) 초기화
#   실행: DB-MASTER 에서 root 로
#   전제: MariaDB 설치 완료 (install/10-db.sh)
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../config.env"

: "${DB_APP_PASS:?}" "${DB_REPL_PASS:?}" "${DB_MON_PASS:?}" "${DB_HB_PASS:?}" "${DB_DUMP_PASS:?}"

echo "== 1. 설정 파일 배치 | Install my.cnf =="
install -m 0644 "${HERE}/my.cnf.d/aadc-common.cnf" /etc/my.cnf.d/
install -m 0644 "${HERE}/my.cnf.d/aadc-master.cnf" /etc/my.cnf.d/
systemctl enable --now mariadb
systemctl restart mariadb

echo "== 2. 스키마 | Schema =="
mysql < "${HERE}/sql/01-schema.sql"

echo "== 3. 계정 | Accounts =="
sed -e "s/__APP_PASS__/${DB_APP_PASS}/g" \
    -e "s/__REPL_PASS__/${DB_REPL_PASS}/g" \
    -e "s/__MON_PASS__/${DB_MON_PASS}/g" \
    -e "s/__HB_PASS__/${DB_HB_PASS}/g" \
    -e "s/__DUMP_PASS__/${DB_DUMP_PASS}/g" \
    "${HERE}/sql/02-grants.sql" | mysql

echo "== 4. 상태 확인 | Status =="
mysql -e "SELECT @@server_id, @@gtid_domain_id, @@read_only, @@gtid_strict_mode\G"
mysql -e "SHOW GLOBAL VARIABLES LIKE 'rpl_semi_sync_master%'"
mysql -e "SELECT @@gtid_binlog_pos AS gtid_binlog_pos"

cat <<'NOTE'

-------------------------------------------------------------------------------
read_only 는 ON 인 채로 둔다. 이것이 정상이다.
read_only stays ON. That is correct, not a failure.

  쓰기는 keepalived 가 VIP 를 잡은 노드에서만 열린다.
  Writes are opened only on the node that holds the VIP, by notify_master
  (keepalived/bin/aadc-notify.sh).

  keepalived 전에 쓰기를 확인하고 싶다면 (임시 조치임을 잊지 말 것):
  To test writes before keepalived is up (remember this is temporary):
      mysql -e "SET GLOBAL read_only=OFF"

다음 / Next:  DB-BACKUP ->  ../install/10-db.sh DB-BACKUP
-------------------------------------------------------------------------------
NOTE
