#!/usr/bin/env bash
# =============================================================================
# 복제 심장박동 — DB-MASTER / DB-BACKUP 양쪽에 설치한다.
#
# UPDATE 는 read_only=OFF 인 노드, 즉 **VIP 를 잡은 노드에서만** 성공한다.
# 그래서 별도 조건 분기 없이 "현재 writer 가 알아서 박동을 찍는" 구조가 된다.
#
# ★ 반드시 SUPER 권한이 없는 계정으로 돌려야 한다.
#   read_only=ON 은 SUPER 를 가진 사용자를 막지 못한다. root(unix_socket) 로
#   돌리면 DB-BACKUP 에서도 UPDATE 가 성공해 **복제본에 로컬 쓰기가 남고**,
#   log_slave_updates=ON + gtid_strict_mode=ON 조합에서 GTID 가 갈라진다.
#   MariaDB 에는 super_read_only 가 없으므로(aadc-common.cnf 주석 참조)
#   "권한을 주지 않는 것"이 유일한 방어다.
#   → aadc_hb 계정: aadc.repl_heartbeat 에 대한 SELECT/UPDATE 만 가진다.
#
# 이게 필요한 이유: Seconds_Behind_Master 는 쓰기가 없는 구간에서 0 으로 보인다.
# DCI 가 끊겨도 쓰기가 없으면 0 이다. 그래서 지연 알람(④)이 침묵한다.
# =============================================================================
set -uo pipefail

# /etc/aadc/heartbeat.env — systemd EnvironmentFile (KEY=VALUE 만 쓸 수 있다)
: "${DB_HB_USER:?DB_HB_USER 가 없다. /etc/aadc/heartbeat.env 를 확인할 것}"
: "${DB_HB_PASS:?DB_HB_PASS 가 없다. /etc/aadc/heartbeat.env 를 확인할 것}"
INTERVAL="${AADC_HEARTBEAT_INTERVAL:-5}"

# 비밀번호를 명령행에 노출하지 않는다 (ps 로 보인다).
CNF="$(mktemp)"
trap 'rm -f "${CNF}"' EXIT
chmod 0600 "${CNF}"
cat > "${CNF}" <<CNFEOF
[client]
user=${DB_HB_USER}
password=${DB_HB_PASS}
host=127.0.0.1
connect_timeout=3
CNFEOF

while true; do
  # read_only=ON 인 노드에서는 ER_OPTION_PREVENTS_STATEMENT 로 실패한다. 정상이다.
  mysql --defaults-extra-file="${CNF}" -N -B \
        -e "UPDATE aadc.repl_heartbeat
            SET beat_at = NOW(3), source = @@hostname
            WHERE id = 1" >/dev/null 2>&1
  sleep "${INTERVAL}"
done
