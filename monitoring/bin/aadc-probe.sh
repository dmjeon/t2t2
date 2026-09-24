#!/usr/bin/env bash
# =============================================================================
# 1분 주기 외부 점검 — 모니터링 또는 점프서버에서 실행
# AADC-POC.md 3-1절(검증 FQDN) + backup 멤버 직접 점검
#
# GSLB 1% 만으로는 야간에 DC-400 이 몇 시간씩 검증 공백에 빠진다.
# backup 멤버는 평시 트래픽이 아예 0 이라 장애 순간에야 동작 여부를 알게 된다.
# 이 스크립트가 그 두 구멍을 메운다.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${AADC_CONF:-${HERE}/../../config.env}"
[ -f "${CONF}" ] && . "${CONF}"
SEND=/usr/local/bin/aadc-alarm-send.sh
[ -x "${SEND}" ] || SEND="${HERE}/aadc-alarm-send.sh"

fails=0

check() {                       # check <이름> <URL> <실패 시 의미>
  local name="$1" url="$2" meaning="$3" out rc
  out=$(curl -sf --max-time 5 -w '\n%{http_code} %{time_total}s' "${url}" 2>&1); rc=$?
  if [ ${rc} -eq 0 ]; then
    printf 'OK   %-22s %s\n' "${name}" "$(printf '%s' "${out}" | tail -1)"
  else
    printf 'FAIL %-22s rc=%s\n' "${name}" "${rc}"
    "${SEND}" CRITICAL "${name} 점검 실패 (${url}) — ${meaning}"
    fails=$((fails+1))
  fi
}

# ----- 검증 FQDN : GSLB 가중치와 무관하게 각 DC 를 직접 때린다 ---------------
check "web1 (DC-500)" "https://${WEB1_FQDN}/api/info"  "DC-500 WEB 계층 도달 불가"
check "web2 (DC-400)" "https://${WEB2_FQDN}/api/info"  "DC-400 WEB 계층 도달 불가. 1% 야간 공백 구간"

# ----- backup(교차) 멤버가 살아 있는가 ---------------------------------------
# 여기가 죽으면 "장애 시 넘어갈 곳"이 이미 없는 것이다. 즉시 알람.
# 각 WEB 의 /checkvs/ 를 부른다 — WEB 이 L4 풀의 원격 멤버 주소를 직접 부르므로
# 모니터링 서버가 서버 대역에 닿을 필요가 없고, 실서비스 경로와 같은 곳에서 본다.
# (점검 전용 VS 는 폐기했다 — config.env DC*_BACKUP_MEMBER 주석)
check "DC-500 backup 멤버" "https://${WEB1_FQDN}/checkvs/api/info" \
      "DC-500 L4 의 backup 멤버(${DC500_BACKUP_MEMBER}, WAS-DC2) 무응답. WAS 장애 시 흡수 불가"
check "DC-400 backup 멤버" "https://${WEB2_FQDN}/checkvs/api/info" \
      "DC-400 L4 의 backup 멤버(${DC400_BACKUP_MEMBER}, WAS-APP1-500) 무응답"

# ----- 서비스 FQDN : GSLB 가 IP 를 돌려주는가 (SERVFAIL 아님) ----------------
# 전 멤버 실패 시 fallback 이 동작하지 않으면 SERVFAIL 이 나가는데 502 보다 나쁘다.
if command -v dig >/dev/null 2>&1; then
  ans=$(dig +short +time=3 +tries=2 "${SERVICE_FQDN}" A 2>/dev/null)
  st=$(dig +noall +comments +time=3 "${SERVICE_FQDN}" A 2>/dev/null | grep -o 'status: [A-Z]*' | head -1)
  if [ -z "${ans}" ]; then
    printf 'FAIL %-22s %s (응답 없음)\n' "GSLB ${SERVICE_FQDN}" "${st}"
    "${SEND}" CRITICAL "GSLB 가 ${SERVICE_FQDN} 에 IP 를 돌려주지 않는다 (${st}). fallback 미동작이면 도메인 전체가 죽은 것처럼 보인다"
    fails=$((fails+1))
  else
    printf 'OK   %-22s %s -> %s\n' "GSLB ${SERVICE_FQDN}" "${st}" "$(echo "${ans}" | tr '\n' ' ')"
  fi
fi

exit $(( fails > 0 ? 1 : 0 ))
