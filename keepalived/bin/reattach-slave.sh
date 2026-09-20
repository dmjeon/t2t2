#!/usr/bin/env bash
# =============================================================================
# 구 master 를 새 master 의 슬레이브로 재투입한다.
#   사용: ./reattach-slave.sh <새_MASTER_IP>
#   실행: 재투입할 노드(구 master)에서 root 로
#
# nopreempt 때문에 VIP 는 되돌아오지 않는다. 그래서 복귀는 **계획된 작업**이며
# 이 스크립트가 그 작업이다. B 훈련(분기 1회)에서도 이 절차를 쓴다.
#
# 전제: GTID 가 갈라지지 않았을 것. semi-sync(RPO 0) 구간에서 내려간
#       노드라면 보통 갈라지지 않는다. 갈라졌다면 재구축이 답이다.
# =============================================================================
set -euo pipefail
NEW_MASTER="${1:?사용: reattach-slave.sh <새_MASTER_IP>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../../config.env"

echo "== 현재 노드 상태 =="
mysql -e "SELECT @@hostname, @@server_id, @@read_only, @@gtid_binlog_pos\G"
echo "== 새 master (${NEW_MASTER}) 상태 =="
mysql -h "${NEW_MASTER}" -u"${DB_MON_USER}" -p"${DB_MON_PASS}" \
  -e "SELECT @@hostname, @@server_id, @@read_only, @@gtid_binlog_pos\G"

# ----- GTID 가 갈라지지 않았는지 먼저 본다 -----------------------------------
# semi-sync(AFTER_SYNC) 에서도 "master 가 로컬 커밋 후 ack 전에 죽는" 창이 있다.
# 그때 구 master 에만 남은 트랜잭션이 생기고, gtid_strict_mode=ON 이므로
# START SLAVE 가 out-of-order sequence 오류로 거부된다.
# 그냥 실행하면 오류 메시지를 사람이 알아채야 하는데, 이 조작은 되돌리기가
# 비싸므로 붙이기 **전에** 막는다.
seq_of() {   # 도메인 1 의 seq_no 만 꺼낸다 (gtid_domain_id 는 전 노드 1 로 고정)
  printf '%s' "${1:-}" | tr ',' '\n' | awk -F- '$1=="1"{print $3}' | head -1
}
MINE=$(mysql -N -B -e "SELECT @@gtid_binlog_pos")
THEIRS=$(mysql -h "${NEW_MASTER}" -N -B -u"${DB_MON_USER}" -p"${DB_MON_PASS}" \
         -e "SELECT @@gtid_binlog_pos")
ms=$(seq_of "${MINE}"); ts=$(seq_of "${THEIRS}")
echo "== GTID 비교 (domain 1) =="
printf '   이 노드   : %s  (seq=%s)\n' "${MINE:-<없음>}"   "${ms:-0}"
printf '   새 master : %s  (seq=%s)\n' "${THEIRS:-<없음>}" "${ts:-0}"

if [ -n "${ms}" ] && [ -n "${ts}" ] && [ "${ms}" -gt "${ts}" ]; then
  cat <<DIVERGED

  ★ 이 노드가 새 master 보다 앞서 있다 (${ms} > ${ts}).

  새 master 에 없는 트랜잭션이 이 노드에만 남아 있다는 뜻이다.
  gtid_strict_mode=ON 이므로 이대로 붙이면 START SLAVE 가 거부된다.
  억지로 맞추면 그 트랜잭션은 조용히 사라진다.

  선택지
    1. 이 노드를 버리고 재구축한다          → db/init-02-backup.sh (권장)
    2. 차이분을 먼저 확인하고 판단한다
         mysqlbinlog --start-position=... 로 ${ts} 이후 이벤트를 살펴볼 것

  여기서 멈추면 아무것도 건드리지 않은 상태 그대로다.
DIVERGED
  exit 1
fi

read -r -p "이 노드를 ${NEW_MASTER} 의 슬레이브로 붙인다. 계속? (yes/no) " ans
[ "${ans}" = "yes" ] || { echo "중단"; exit 1; }

mysql <<SQL
SET GLOBAL read_only = ON;
STOP SLAVE;
RESET SLAVE;
SET GLOBAL gtid_slave_pos = @@gtid_binlog_pos;
CHANGE MASTER TO
  MASTER_HOST     = '${NEW_MASTER}',
  MASTER_PORT     = 3306,
  MASTER_USER     = '${DB_REPL_USER}',
  MASTER_PASSWORD = '${DB_REPL_PASS}',
  MASTER_USE_GTID = slave_pos,
  MASTER_CONNECT_RETRY = 2,
  MASTER_HEARTBEAT_PERIOD = 1;
SET GLOBAL rpl_semi_sync_master_enabled = OFF;
SET GLOBAL rpl_semi_sync_slave_enabled  = ON;
START SLAVE;
SQL

sleep 3
mysql -e "SHOW SLAVE STATUS\G" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Using_Gtid|Last_.*Error'
echo
echo "새 master 쪽에서 Rpl_semi_sync_master_clients 가 1 로 올라오는지 확인할 것."
echo "  mysql -h ${NEW_MASTER} -e \"SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_%'\""
