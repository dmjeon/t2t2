#!/usr/bin/env bash
# =============================================================================
# /usr/local/bin/chk_db.sh — keepalived track_script
# AADC-POC.md 3-4절 안전장치 ③ (2노드 타이브레이커 — 게이트웨이 증인)
#
# 노드가 2개면 쿼럼이 없다. "상대가 죽었나, 내가 고립됐나"를 구분하려고
# 세그먼트 게이트웨이를 증인으로 쓴다. 고립된 노드는 게이트웨이에 닿지 못해
# 스스로 우선순위를 낮추고 VIP 를 포기한다. VIP 이중 보유를 구조적으로 막는다.
#
# 검증: C4 — DB-MASTER NIC 다운 시 고립 노드가 VIP 를 포기하는가
#
# ★ 실패를 반드시 알람으로 낸다.
#   keepalived 는 track_script 의 weight 가 0 이 아니면 FAULT 상태로 전이하지
#   않는다. 우리는 weight -50 을 쓰므로(VIP 를 통째로 놓는 것보다 안전하다)
#   keepalived.conf 의 notify_fault 는 호출되지 않는다. 즉 이 스크립트가
#   직접 알리지 않으면 **고립도 로컬 DB 다운도 아무도 모른다.**
#
# ★ 게이트웨이가 ICMP 에 응답해야 한다는 전제가 있다.
#   FortiGate 는 인터페이스별로 ping 을 막아두는 경우가 흔하다. 막혀 있으면
#   양쪽 노드가 모두 증인을 잃어 안전장치 ③ 이 조용히 무력화된다
#   (서비스는 계속되므로 티가 나지 않는다). 아래 알람이 그것을 드러낸다.
#   방화벽 신청 항목이기도 하다 — FIREWALL-REQUEST.md #17.
# =============================================================================
GW="${AADC_DB_GW:-10.3.31.254}"
SEND=/usr/local/bin/aadc-alarm-send.sh
STATE_DIR=/run/aadc-chk_db
REPEAT_S=120

# keepalived 의 script timeout(2초) 안에 반드시 끝나야 하므로 알람은 떼어 보낸다.
notify() {                      # notify <키> <레벨> <메시지>
  local key="$1" level="$2" msg="$3" now last
  mkdir -p "${STATE_DIR}" 2>/dev/null
  now=$(date +%s)
  last=$(cat "${STATE_DIR}/${key}" 2>/dev/null || echo 0)
  [ $(( now - last )) -ge ${REPEAT_S} ] || return 0
  echo "${now}" > "${STATE_DIR}/${key}"
  [ -x "${SEND}" ] && ( setsid "${SEND}" "${level}" "${msg}" >/dev/null 2>&1 & )
  logger -t aadc-chk_db -- "${level}: ${msg}"
}

clear_state() { rm -f "${STATE_DIR}/db" "${STATE_DIR}/witness" 2>/dev/null; }

# 1. 로컬 DB 가 살아 있는가
if ! mysqladmin ping -h127.0.0.1 --silent 2>/dev/null; then
  notify db CRITICAL "$(hostname): 로컬 MariaDB 응답 없음. keepalived 우선순위를 낮춘다(VIP 포기)."
  exit 1
fi

# 2. 내가 고립된 것은 아닌가 (증인 도달)
if ! ping -c1 -W1 "${GW}" >/dev/null 2>&1; then
  notify witness CRITICAL \
    "$(hostname): 증인 게이트웨이 ${GW} 에 닿지 않는다. 세그먼트 고립이거나, 게이트웨이가 ICMP 에 응답하지 않는 것이다(후자면 안전장치 ③ 이 무력화된 상태). 즉시 확인할 것."
  exit 1
fi

clear_state
exit 0
