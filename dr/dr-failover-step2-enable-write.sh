#!/usr/bin/env bash
# =============================================================================
# DR 전환 2단계 — DB-DR 의 read_only 를 사람이 해제한다
#   실행: DB-DR (10.7.31.52) 에서 root 로
#
# ★ 되돌리기 비용이 가장 높은 조작이다.
#   여기를 지나면 DC-500 과 데이터가 갈라진다. 복귀하려면 역방향 복제를
#   다시 걸어야 한다 (dr-failback.md).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../config.env"

echo "== DB-DR 현재 상태 =="
mysql -e "SELECT @@hostname, @@server_id, @@read_only\G"
mysql -e "SHOW SLAVE STATUS\G" | grep -E \
  'Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Gtid_IO_Pos|Read_Master_Log_Pos'
mysql -e "SELECT beat_at, source, TIMESTAMPDIFF(SECOND, beat_at, NOW()) AS behind_s
          FROM aadc.repl_heartbeat WHERE id=1\G"

cat <<'WARN'

------------------------------------------------------------------------------
DR 전환 2단계 — read_only 해제

  이 지점을 지나면 DC-500 과 데이터가 갈라진다.
  위 heartbeat behind_s 만큼의 쓰기가 유실될 수 있다 (async 복제, RPO ≠ 0).

  반드시 먼저 확인할 것:
    · DC-500 의 DB 가 정말 쓰기를 받고 있지 않은가
      (DCI 만 끊긴 상태라면 양쪽이 동시에 쓰기를 받아 데이터가 갈라진다)
    · Slave_IO/SQL_Running 이 방금 전까지 Yes 였는가 (= 받을 것은 다 받았는가)
------------------------------------------------------------------------------
WARN
read -r -p "DC-500 이 쓰기를 받고 있지 않음을 확인했다. 진행? (I-CONFIRM) " ans
[ "${ans}" = "I-CONFIRM" ] || { echo "중단"; exit 1; }

mysql <<SQL
STOP SLAVE;
SET GLOBAL read_only = OFF;
INSERT INTO aadc.failover_log (step, actor, detail)
  VALUES ('read_only_off', '$(whoami)@$(hostname)', 'DR promoted to writer');
SQL

mysql -e "SELECT @@hostname, @@read_only  /* 0 이어야 한다 */\G"
logger -t aadc-dr "DR failover step2: read_only=OFF on $(hostname)"

cat <<'NEXT'

------------------------------------------------------------------------------
2단계 완료. DB-DR 이 writer 다.

지금부터 해야 할 것:
  1. 애플리케이션 쓰기 확인:  curl -XPOST 'http://<L4_VIP>:8000/api/db/write?note=dr'
  2. /health/deep 이 200 으로 돌아오는지 확인 (writer read_only=0 이어야 통과)
  3. 복귀 계획 수립 — dr-failback.md. 훈련(C)이라면 소요 시간을 기록할 것.
------------------------------------------------------------------------------
NEXT
