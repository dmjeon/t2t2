#!/usr/bin/env bash
# =============================================================================
# DB 검증 — AADC-POC.md 11-4절
#   C3  DB-MASTER 프로세스 정지 → VIP 이동      4초 내, 데이터 손실 0
#   C4  DB-MASTER NIC 다운 (고립)                고립 노드가 VIP 를 포기 — 안전장치 ③
#   C5  구 MASTER 재기동                         read_only 유지, VIP 안 되찾음 — ②④
#   C6  DB-BACKUP 정지                           master 정지 안 함, async 강등 + 알람 — ⑤
#   C7  DR 이 VIP 복제 추종                      로컬 failover 후 DR 복제 무중단
#
# 실행: 점프서버 또는 DB 계층에 접근 가능한 호스트.
#       장애 주입은 사람이 한다. 이 스크립트는 관찰과 판정을 맡는다.
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MYSQL="mysql -N -B --connect-timeout=3 -u${DB_MON_USER} -p${DB_MON_PASS}"
phase="${1:-status}"

who_has_vip() { ${MYSQL} -h "${DB_VIP}" -e "SELECT @@hostname" 2>/dev/null; }
ro_of()       { ${MYSQL} -h "$1" -e "SELECT @@read_only" 2>/dev/null; }

show_all() {
  for n in "VIP:${DB_VIP}" "MASTER:${DB_MASTER_IP}" "BACKUP:${DB_BACKUP_IP}" "DR:${DB_DR_IP}"; do
    lbl="${n%%:*}"; ip="${n#*:}"
    h=$(${MYSQL} -h "${ip}" -e "SELECT @@hostname" 2>/dev/null)
    r=$(ro_of "${ip}")
    printf '   %-7s %-14s hostname=%-14s read_only=%s%s\n' \
      "${lbl}" "${ip}" "${h:-UNREACHABLE}" "${r:--}" \
      "$([ "${r}" = "0" ] && echo '   <= WRITER')"
  done
}

case "${phase}" in
status)
  hdr "현재 DB 상태"
  show_all
  n=$(for ip in "${DB_MASTER_IP}" "${DB_BACKUP_IP}" "${DB_DR_IP}"; do ro_of "${ip}"; done | grep -c '^0$')
  if [ "${n}" -eq 1 ]; then ok "VIP" "쓰기 가능 노드가 정확히 1개"
  elif [ "${n}" -eq 0 ]; then ng "VIP" "쓰기 가능 노드가 없다 — VIP 를 잡은 노드가 없거나 notify_master 실패"
  else ng "VIP" "쓰기 가능 노드가 ${n}개 — VIP 이중 보유 의심. 즉시 확인할 것"; fi

  # ----- 안전장치 ③ 의 전제: 증인 게이트웨이가 ICMP 에 응답하는가 -------------
  # 응답하지 않으면 양쪽 노드가 항상 "고립"으로 판정해 증인이 아무것도 구분하지
  # 못한다. 그래도 VIP 는 잡히므로 서비스는 정상으로 보인다 — C4 에서야 드러난다.
  # FortiGate 는 인터페이스별로 ping 을 막아두는 경우가 흔하다 (FW-28).
  if ping -c2 -W2 "${GW_DC_DB}" >/dev/null 2>&1; then
    ok "witness" "증인 게이트웨이 ${GW_DC_DB} 가 ICMP 에 응답한다 (안전장치 ③ 유효)"
  else
    ng "witness" "증인 게이트웨이 ${GW_DC_DB} 가 ICMP 에 응답하지 않는다 — 안전장치 ③ 이 무력화된 상태다. FW-28 을 확인할 것"
  fi

  semi=$(${MYSQL} -h "${DB_VIP}" -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_status'" 2>/dev/null | awk '{print $2}')
  assert_eq "semi" "ON" "${semi:-?}" "semi-sync (RPO 0)"

  io=$(${MYSQL} -h "${DB_DR_IP}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | awk -F': ' '/Slave_IO_Running/{print $2}')
  assert_eq "DR" "Yes" "${io:-?}" "DR 복제 IO 스레드"

  cat <<'NEXT'

장애 주입 후 다시 실행한다.

  [C3]  DB-MASTER 에서:  systemctl stop mariadb
        관찰:            ./04-db-c3-c7.sh watch      (다른 창에서 미리 띄워 둘 것)
  [C4]  DB-MASTER 에서:  ip link set ens192 down     ★ 콘솔 접근 확보 후에
  [C5]  DB-MASTER 재기동 후: ./04-db-c3-c7.sh c5
  [C6]  DB-BACKUP 에서:  systemctl stop mariadb  →  ./04-db-c3-c7.sh c6
  [C7]  C3 직후:         ./04-db-c3-c7.sh c7
NEXT
  ;;

watch)
  hdr "VIP 이동 관찰 — 0.2초 간격. Ctrl-C 로 종료"
  note "C3 판정 기준: 4초 내 전환, 데이터 손실 0"
  prev=""; t0=""
  while true; do
    h=$(who_has_vip)
    now=$(date +%s.%N)
    if [ "${h}" != "${prev}" ]; then
      if [ -n "${prev}" ] && [ -n "${t0}" ]; then
        printf '   %s  %s -> %s   (공백 %.2fs)\n' "$(date -Is)" "${prev:-none}" "${h:-none}" \
          "$(awk "BEGIN{print ${now}-${t0}}")"
      else
        printf '   %s  VIP holder = %s\n' "$(date -Is)" "${h:-none}"
      fi
      t0="${now}"; prev="${h}"
    fi
    sleep 0.2
  done
  ;;

c5)
  hdr "C5 — 구 MASTER 재기동 후 (안전장치 ② nopreempt / ④ read_only)"
  show_all
  ro=$(ro_of "${DB_MASTER_IP}")
  assert_eq "C5-a" "1" "${ro:-?}" "재기동된 구 MASTER 가 read_only 를 유지하는가"
  h=$(who_has_vip)
  if [ "${h}" = "$(${MYSQL} -h "${DB_MASTER_IP}" -e 'SELECT @@hostname' 2>/dev/null)" ]; then
    ng "C5-b" "구 MASTER 가 VIP 를 되찾았다 — nopreempt 가 동작하지 않는다"
  else
    ok "C5-b" "VIP 를 되찾지 않았다 (현재 holder=${h}). 재투입은 계획된 작업으로."
  fi
  note "재투입:  keepalived/bin/reattach-slave.sh <현재 master IP>"
  ;;

c6)
  hdr "C6 — DB-BACKUP 정지 (안전장치 ⑤ semi-sync 타임아웃)"
  if ${MYSQL} -h "${DB_VIP}" -e "SELECT 1" >/dev/null 2>&1; then
    ok "C6-a" "master 가 정지하지 않았다 — backup 장애가 master 로 번지지 않았다"
  else
    ng "C6-a" "master 가 응답하지 않는다 — rpl_semi_sync_master_timeout 확인 (1000ms)"
  fi
  semi=$(${MYSQL} -h "${DB_VIP}" -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_status'" 2>/dev/null | awk '{print $2}')
  assert_eq "C6-b" "OFF" "${semi:-?}" "async 로 강등됐는가 (강등 자체는 정상 동작)"
  note "★ 이 상태는 RPO 가 깨진 상태다. 알람이 반드시 떠야 한다:"
  note "   grep 'RPO' /var/log/aadc-alarm.log"
  t=$(${MYSQL} -h "${DB_VIP}" -e "SELECT @@rpl_semi_sync_master_timeout" 2>/dev/null)
  assert_eq "C6-c" "1000" "${t:-?}" "semi-sync 타임아웃 1초"
  ;;

c7)
  hdr "C7 — 로컬 failover 후 DR 이 재설정 없이 따라가는가"
  mh=$(${MYSQL} -h "${DB_DR_IP}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | awk -F': ' '/Master_Host/{print $2}')
  assert_eq "C7-a" "${DB_VIP}" "${mh:-?}" "DR 의 복제 소스가 VIP 인가 (개별 노드가 아니라)"
  io=$(${MYSQL} -h "${DB_DR_IP}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | awk -F': ' '/Slave_IO_Running/{print $2}')
  sq=$(${MYSQL} -h "${DB_DR_IP}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | awk -F': ' '/Slave_SQL_Running/{print $2}')
  assert_eq "C7-b" "Yes" "${io:-?}" "IO 스레드 (failover 를 건너 살아남았는가)"
  assert_eq "C7-c" "Yes" "${sq:-?}" "SQL 스레드"
  lag=$(${MYSQL} -h "${DB_DR_IP}" -e "SELECT TIMESTAMPDIFF(SECOND, beat_at, NOW()) FROM aadc.repl_heartbeat WHERE id=1" 2>/dev/null)
  note "heartbeat 지연 ${lag:-?}초  (Seconds_Behind_Master 는 idle 구간에서 0 으로 보이므로 믿지 않는다)"
  ;;

*) echo "사용: $0 [status|watch|c5|c6|c7]"; exit 2 ;;
esac

summary
