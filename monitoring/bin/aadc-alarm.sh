#!/usr/bin/env bash
# =============================================================================
# 필수 알람 5종 — AADC-POC.md 7-③절
#   실행 주기 1분 (systemd timer). 모니터링 호스트 또는 점프서버.
#
#   ① /health/local 실패            → "backup 으로 넘어감, WAS 수리 필요"  [즉시]
#   ② L4 backup 멤버 active 지속     → 경과 시간과 함께 반복 알림          [1시간마다]
#   ③ semi-sync → async 강등         → "RPO 깨짐"                         [즉시]
#   ④ 복제 지연 임계 초과            → DR RPO 악화                         [즉시]
#   ⑤ 점검 전용 VS 실패              → backup 경로 자체가 죽음              [즉시]  (aadc-probe.sh)
#
# ①②가 이 정책의 생명선이다. 자동 전환을 포기한 대가로 탐지를 강하게 만든다.
# degraded 는 조용하다 — 서비스는 되고 조금 느릴 뿐이라 아무도 모르면 몇 주도 간다.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${AADC_CONF:-${HERE}/../../config.env}"
[ -f "${CONF}" ] && . "${CONF}"
SEND=/usr/local/bin/aadc-alarm-send.sh
[ -x "${SEND}" ] || SEND="${HERE}/aadc-alarm-send.sh"

STATE_DIR=/var/lib/aadc-monitor
mkdir -p "${STATE_DIR}"

# ----- ①② 는 WEB 서버의 내부 IP 를 직접 때린다 -----------------------------
# 공인 FQDN(web1/web2)을 쓰면 인터넷 → DMZ FortiADC → nginx 를 거치므로
#   (a) 점프서버의 아웃바운드가 필요하고(방화벽 대상),
#   (b) "로컬 WAS 가 살아 있나"라는 질문에 FortiADC·인터넷 장애가 섞여 들어와
#       오탐이 난다. ①② 는 내부 계층만 봐야 한다.
# 공인 경로 점검은 aadc-probe.sh 의 web1/web2 가 따로 담당한다. 용도가 다르다.
WEB_DC500_URL="http://${WEB_DC1_IP}"
WEB_DC400_URL="http://${WEB_DC2_IP}"

REPL_LAG_WARN_S="${REPL_LAG_WARN_S:-30}"      # ④ 임계. C1 결과로 조정할 것
DEGRADED_REPEAT_S="${DEGRADED_REPEAT_S:-3600}" # ② 반복 주기 (1시간)

now() { date +%s; }
mark() { echo "$1" > "${STATE_DIR}/$2"; }
read_mark() { cat "${STATE_DIR}/$1" 2>/dev/null || echo ""; }

# 같은 알람을 1분마다 반복하지 않도록, 상태가 "바뀐 순간"에만 보낸다.
edge_alarm() {                  # edge_alarm <키> <현재상태> <레벨> <메시지>
  local key="$1" cur="$2" level="$3" msg="$4"
  local prev; prev="$(read_mark "${key}.state")"
  if [ "${prev}" != "${cur}" ]; then
    "${SEND}" "${level}" "${msg}"
    mark "${cur}" "${key}.state"
    mark "$(now)" "${key}.since"
  fi
}

# --------------------------------------------------------------------------
# ① /health/local  — DC 별로 각각 본다
# --------------------------------------------------------------------------
for pair in "DC-500:${WEB_DC500_URL}:${WEB1_FQDN}" "DC-400:${WEB_DC400_URL}:${WEB2_FQDN}"; do
  dc="${pair%%:*}"; rest="${pair#*:}"; url="${rest%:*}"; fqdn="${rest##*:}"
  if curl -sf --max-time 5 -H "Host: ${fqdn}" "${url}/health/local" >/dev/null 2>&1; then
    edge_alarm "local_${dc}" OK INFO "${dc}: /health/local 복구. 로컬 WAS 정상."
  else
    edge_alarm "local_${dc}" FAIL CRITICAL \
      "${dc}: /health/local 실패 — backup 으로 넘어갔다. WAS 수리 필요. GSLB 는 움직이지 않는다(의도대로)."
  fi
done

# --------------------------------------------------------------------------
# ② L4 backup 멤버 active 지속 — 경과 시간과 함께 반복 알림
#    이것이 생명선이다. degraded 는 조용해서 잊힌다.
# --------------------------------------------------------------------------
for pair in "DC-500:${WEB_DC500_URL}:${WEB1_FQDN}" "DC-400:${WEB_DC400_URL}:${WEB2_FQDN}"; do
  dc="${pair%%:*}"; rest="${pair#*:}"; url="${rest%:*}"; fqdn="${rest##*:}"
  body=$(curl -sf --max-time 5 -H "Host: ${fqdn}" "${url}/api/info" 2>/dev/null)
  [ -z "${body}" ] && continue

  # 판정을 두 가지로 이중화한다.
  #   (1) cross_dc  — WAS 가 SNAT 된 L4 주소로 스스로 판정한 값
  #   (2) was_dc    — 실제로 처리한 WAS 가 밝힌 자기 DC
  # (1)은 uvicorn 에 --proxy-headers 가 켜지면 조용히 망가진다(req.client.host 가
  # 고객 IP 로 덮이기 때문). 그때도 (2)는 살아 있으므로 생명선이 끊기지 않는다.
  was_dc=$(printf '%s' "${body}" | sed -n 's/.*"was_dc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if printf '%s' "${body}" | grep -q '"cross_dc":[[:space:]]*true' \
     || { [ -n "${was_dc}" ] && [ "${was_dc}" != "${dc}" ]; }; then
    key="degraded_${dc}"
    since="$(read_mark "${key}.since")"
    if [ -z "${since}" ]; then
      mark "$(now)" "${key}.since"; mark 0 "${key}.last"; since="$(now)"
      "${SEND}" CRITICAL "${dc}: L4 backup 멤버로 트래픽이 넘어갔다. degraded 시작."
    fi
    last="$(read_mark "${key}.last")"; last="${last:-0}"
    elapsed=$(( $(now) - since ))
    if [ $(( $(now) - last )) -ge "${DEGRADED_REPEAT_S}" ]; then
      mark "$(now)" "${key}.last"
      "${SEND}" WARN "${dc}: degraded 지속 $(( elapsed / 60 ))분. 전 요청·응답이 DCI 를 건너고 있다. 허용 시간 기준을 확인할 것."
    fi
  else
    if [ -n "$(read_mark "degraded_${dc}.since")" ]; then
      elapsed=$(( $(now) - $(read_mark "degraded_${dc}.since") ))
      "${SEND}" INFO "${dc}: degraded 해제. 총 $(( elapsed / 60 ))분 지속했다."
      rm -f "${STATE_DIR}/degraded_${dc}.since" "${STATE_DIR}/degraded_${dc}.last"
    fi
  fi
done

# --------------------------------------------------------------------------
# ③ semi-sync 강등  (DC-500 내부, RPO 0 이 깨졌는가)
# --------------------------------------------------------------------------
# 비밀번호를 명령행에 두지 않는다 (ps 로 보인다).
MYCNF="$(mktemp)"; chmod 0600 "${MYCNF}"
trap 'rm -f "${MYCNF}"' EXIT
printf '[client]\nuser=%s\npassword=%s\nconnect_timeout=3\n' \
       "${DB_MON_USER}" "${DB_MON_PASS}" > "${MYCNF}"
MYSQL="mysql --defaults-extra-file=${MYCNF} -N -B"
semi=$(${MYSQL} -h "${DB_VIP}" -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_status'" 2>/dev/null | awk '{print $2}')
clients=$(${MYSQL} -h "${DB_VIP}" -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_clients'" 2>/dev/null | awk '{print $2}')

if [ -z "${semi}" ]; then
  edge_alarm semi UNREACHABLE CRITICAL "DB-VIP(${DB_VIP}) 에 닿지 않는다. writer 확인 필요."
elif [ "${semi}" != "ON" ]; then
  edge_alarm semi OFF CRITICAL \
    "semi-sync 가 async 로 강등됐다 (clients=${clients:-0}). RPO 가 깨졌다. DB-BACKUP 을 확인할 것."
else
  edge_alarm semi ON INFO "semi-sync 복구 (clients=${clients}). RPO 0."
fi

# --------------------------------------------------------------------------
# ④ DR 복제 지연
#    Seconds_Behind_Master 는 쓰기가 없는 구간에서 0 으로 보이므로
#    heartbeat 테이블을 기준으로 잰다.
# --------------------------------------------------------------------------
lag=$(${MYSQL} -h "${DB_DR_IP}" -e \
  "SELECT TIMESTAMPDIFF(SECOND, beat_at, NOW()) FROM aadc.repl_heartbeat WHERE id=1" 2>/dev/null)
io=$(${MYSQL} -h "${DB_DR_IP}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | awk -F': ' '/Slave_IO_Running/{print $2}')

if [ -z "${lag}" ]; then
  edge_alarm drlag UNREACHABLE CRITICAL "DB-DR(${DB_DR_IP}) 에 닿지 않는다."
elif [ "${io}" != "Yes" ]; then
  edge_alarm drlag STOPPED CRITICAL "DR 복제가 멈췄다 (Slave_IO_Running=${io}). DCI 단절 여부를 확인할 것."
elif [ "${lag}" -gt "${REPL_LAG_WARN_S}" ]; then
  edge_alarm drlag LAG CRITICAL "DR 복제 지연 ${lag}초 (임계 ${REPL_LAG_WARN_S}초). DR RPO 악화."
else
  edge_alarm drlag OK INFO "DR 복제 정상 (지연 ${lag}초)."
fi

# --------------------------------------------------------------------------
# ⑤ 점검 전용 VS  — aadc-probe.sh 가 담당한다 (같은 타이머로 함께 돈다)
# --------------------------------------------------------------------------
exit 0
