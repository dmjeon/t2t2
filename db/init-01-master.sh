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

echo "== 1. 설정 파일 배치 =="
install -m 0644 "${HERE}/my.cnf.d/aadc-common.cnf" /etc/my.cnf.d/
install -m 0644 "${HERE}/my.cnf.d/aadc-master.cnf" /etc/my.cnf.d/
systemctl enable --now mariadb
systemctl restart mariadb

echo "== 2. 스키마 =="
mysql < "${HERE}/sql/01-schema.sql"

echo "== 3. 계정 =="
sed -e "s/__APP_PASS__/${DB_APP_PASS}/g" \
    -e "s/__REPL_PASS__/${DB_REPL_PASS}/g" \
    -e "s/__MON_PASS__/${DB_MON_PASS}/g" \
    -e "s/__HB_PASS__/${DB_HB_PASS}/g" \
    -e "s/__DUMP_PASS__/${DB_DUMP_PASS}/g" \
    "${HERE}/sql/02-grants.sql" | mysql

echo "== 4. 상태 확인 =="
mysql -e "SELECT @@server_id, @@gtid_domain_id, @@read_only, @@gtid_strict_mode\G"
mysql -e "SHOW GLOBAL VARIABLES LIKE 'rpl_semi_sync_master%'"
mysql -e "SELECT @@gtid_binlog_pos AS gtid_binlog_pos"

cat <<'NOTE'

------------------------------------------------------------------------------
read_only 는 ON 인 채로 둔다. 이것이 정상이다.

  쓰기는 keepalived 가 VIP 를 잡은 노드에서만 열린다.
  (keepalived/bin/notify.sh 의 notify_master 가 read_only=OFF 로 바꾼다)

  keepalived 없이 지금 당장 쓰기를 확인하고 싶다면:
      mysql -e "SET GLOBAL read_only=OFF"
  단, keepalived 구성 전 임시 조치라는 것을 잊지 말 것.

다음: DB-BACKUP 에서 init-02-backup.sh
------------------------------------------------------------------------------
NOTE
