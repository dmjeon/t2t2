#!/usr/bin/env bash
# =============================================================================
# /usr/local/bin/aadc-alarm-send.sh <LEVEL> <MESSAGE>
#   LEVEL: INFO | WARN | CRITICAL
#
# 알람 송출 단일 창구. webhook / mail 이 비어 있으면 syslog 로만 남는다.
# AADC-POC.md 7-③절: "알람이 없으면 설계가 성립하지 않는다."
# degraded 상태는 조용하다. 서비스는 되고 조금 느릴 뿐이다.
# =============================================================================
set -uo pipefail
LEVEL="${1:-INFO}"; shift || true
MSG="${*:-}"
HOST="$(hostname -s)"
STAMP="$(date -Is)"
LINE="[${LEVEL}] ${HOST} ${STAMP} — ${MSG}"

[ -f /etc/aadc/monitor.env ] && . /etc/aadc/monitor.env

logger -t aadc-alarm -p "user.$( [ "${LEVEL}" = CRITICAL ] && echo err || echo warning )" -- "${LINE}"
echo "${LINE}" >> /var/log/aadc-alarm.log

if [ -n "${ALARM_WEBHOOK_URL:-}" ]; then
  payload=$(printf '{"level":"%s","host":"%s","time":"%s","text":"%s"}' \
            "${LEVEL}" "${HOST}" "${STAMP}" "$(printf '%s' "${MSG}" | sed 's/"/\\"/g')")
  curl -sf --max-time 5 -H 'Content-Type: application/json' \
       -d "${payload}" "${ALARM_WEBHOOK_URL}" >/dev/null 2>&1 \
    || logger -t aadc-alarm "webhook 전송 실패"
fi

if [ -n "${ALARM_MAIL_TO:-}" ] && command -v mail >/dev/null 2>&1; then
  printf '%s\n' "${LINE}" | mail -s "[AADC ${LEVEL}] ${HOST}" "${ALARM_MAIL_TO}" \
    || logger -t aadc-alarm "메일 전송 실패"
fi
