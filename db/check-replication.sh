#!/usr/bin/env bash
# =============================================================================
# 복제 상태 한 눈에 보기 — 3 노드 어디서 실행해도 된다.
#   ./check-replication.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../config.env"

# 비밀번호를 명령행에 두지 않는다 (ps 로 보인다).
MYCNF="$(mktemp)"; chmod 0600 "${MYCNF}"
trap 'rm -f "${MYCNF}"' EXIT
printf '[client]\nuser=%s\npassword=%s\nconnect_timeout=3\n' \
       "${DB_MON_USER}" "${DB_MON_PASS}" > "${MYCNF}"
M="mysql --defaults-extra-file=${MYCNF} -N -B"

probe() {
  local label="$1" host="$2"
  echo "----- ${label} (${host}) -----"
  if ! ${M} -h "${host}" -e "SELECT 1" >/dev/null 2>&1; then
    echo "  UNREACHABLE"; return
  fi
  ${M} -h "${host}" -e "
    SELECT CONCAT('  hostname   : ', @@hostname);
    SELECT CONCAT('  server_id  : ', @@server_id);
    SELECT CONCAT('  read_only  : ', @@read_only, IF(@@read_only=0,'   <= WRITER',''));
    SELECT CONCAT('  gtid_pos   : ', @@gtid_binlog_pos);
    SELECT CONCAT('  heartbeat  : ', beat_at, '  (지연 ',
                  ROUND(TIMESTAMPDIFF(MICROSECOND, beat_at, NOW(3))/1000), 'ms, source=', source, ')')
      FROM aadc.repl_heartbeat WHERE id=1;
  " 2>/dev/null
  ${M} -h "${host}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E \
    'Master_Host:|Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind_Master:|Using_Gtid:|Last_IO_Error:|Last_SQL_Error:' \
    | sed 's/^[[:space:]]*/  /'
  ${M} -h "${host}" -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_status'" 2>/dev/null \
    | awk '{printf "  semi_sync  : %s%s\n", $2, ($2=="OFF"?"   <= RPO 깨짐. 알람 대상":"")}'
}

echo "==================== AADC 복제 상태 ===================="
probe "DB-VIP    " "${DB_VIP}"
probe "DB-MASTER " "${DB_MASTER_IP}"
probe "DB-BACKUP " "${DB_BACKUP_IP}"
probe "DB-DR     " "${DB_DR_IP}"
echo "========================================================"
cat <<'NOTE'
판정
  · VIP 를 잡은 노드만 read_only=0 이어야 한다. 두 개면 VIP 이중 보유 = 사고.
  · DC-500 내부(MASTER↔BACKUP) semi_sync = ON  → RPO 0
  · DR 의 heartbeat 지연이 곧 실질 복제 지연이다.
    Seconds_Behind_Master 는 쓰기가 없는 구간에서 0 으로 보이므로 믿지 않는다.
NOTE
