#!/usr/bin/env bash
# =============================================================================
# 경로 및 구성 검증 — AADC-POC.md 11-2절 (R1~R6, C12, C13)
#   실행: WAS-APP1-500 (DC-500) 에서. R5/R6 만 별도 위치에서.
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hdr "R1  라우팅 도달 (peer-routing)"
if ping -c2 -W2 "${WAS_DC400_IP}" >/dev/null 2>&1; then
  ok "R1" "WAS-APP1 → ${WAS_DC400_IP} 응답"
else
  ng "R1" "${WAS_DC400_IP} 무응답 — 양쪽 FortiGate 교차 경로 라우팅 확인 (회신 7번)"
fi

hdr "R2  경로 확인"
if command -v traceroute >/dev/null 2>&1; then
  out=$(traceroute -n -w 2 -q 1 -m 8 "${WAS_DC400_IP}" 2>&1)
  printf '%s\n' "${out}" | sed 's/^/   /'
  assert_match "R2" "${GW_DC_APP}" "${out}" "첫 홉이 dc-app 게이트웨이인가"
else
  sk "R2" "traceroute 미설치"
fi

if need_l4 "R3"; then
  L4="http://${DC500_L4_VIP}:${L4_PORT}"
  CHK="http://${DC500_CHECK_VS_VIP}:${L4_PORT}"

  hdr "R3  L4 로컬 멤버"
  body=$(get "${L4}/api/info")
  if [ -z "${body}" ]; then
    ng "R3" "${L4}/api/info 호출 실패 — 내부 L4 FortiADC 기동 여부 확인"
  else
    was_host=$(jqget "${body}" was_host)
    assert_match "R3" "WAS-APP1\|WAS-APP-500" "${was_host}" "로컬 WAS 가 처리했는가 (was_host=${was_host})"

    hdr "C12  로컬 SNAT (Full NAT)"
    via=$(jqget "${body}" via_l4)
    assert_match "C12" "^${L4_PREFIX_DC500}" "${via}" "via_l4 가 DC-500 L4 주소인가 (${via})"
    note "via_l4 가 nginx IP(${WEB_DC1_IP})로 보이면 Full NAT 가 아니라 DNAT 만 걸린 것이다."
    note "그 구성에서는 응답이 L4 를 우회해 연결이 끊긴다 (5-1절)."
  fi

  hdr "C13  backup 멤버 점검 VS"
  body=$(get "${CHK}/api/info")
  if [ -z "${body}" ]; then
    ng "C13" "${CHK}/api/info 호출 실패 — 교차 멤버 경로가 죽어 있다. WAS 장애 시 흡수 불가."
  else
    was_host=$(jqget "${body}" was_host)
    was_dc=$(jqget "${body}" was_dc)
    assert_eq "C13" "DC-400" "${was_dc}" "점검 VS 가 교차 멤버(WAS-DC2)에 닿는가 (was_host=${was_host})"
  fi
fi

hdr "R5  고객 IP 보존 (외부에서 실행할 것)"
note "한국 등 외부망에서:"
note "   curl -s https://${SERVICE_FQDN}/api/info | jq '{client_ip, via_l4, dc_path, web_host}'"
note ""
note "client_ip 가 ${DMZ_ADC_DC500} 로 나오면 DMZ FortiADC 의 XFF 삽입 누락이다."
note "서버 쪽에서 고칠 수 없다. Viettel 요청 항목."
body=$(get "https://${SERVICE_FQDN}/api/info" 8)
if [ -n "${body}" ]; then
  cip=$(jqget "${body}" client_ip)
  case "${cip}" in
    "${DMZ_ADC_DC500}"|"${DMZ_ADC_DC400}")
      ng "R5" "client_ip=${cip} — FortiADC 주소다. XFF 삽입 누락." ;;
    "") sk "R5" "응답에서 client_ip 를 읽지 못함" ;;
    *)  ok "R5" "client_ip=${cip} (원본 보존)" ;;
  esac
else
  sk "R5" "${SERVICE_FQDN} 도달 불가 (내부망에서 실행 중이면 정상)"
fi

hdr "R6  nginx 로그"
note "WEB 서버에서:  tail -f /var/log/nginx/aadc.log"
note "   client= 가 고객 IP 여야 한다. FortiADC IP 면 set_real_ip_from 누락 또는 R5 와 같은 원인."

summary
