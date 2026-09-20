#!/usr/bin/env bash
# =============================================================================
# 헬스체크 검증 — AADC-POC.md 11-3절
#   설계 의도가 반대로 동작하지 않는지 확인한다.
#
#   C15  로컬 WAS 정지 후 /health/deep   → 성공 (backup 경유) → GSLB 이동 없음
#   C16  로컬 WAS 정지 후 /health/local  → 실패 → 알람
#   C17  WAS 전멸 후 www 조회            → SERVFAIL 아님. IP 반환 → 502 도달
#   C18  L4 장비 정지 (WAS 는 정상)       → deep 실패 → GSLB 이동
#
#   ★ C15 와 C16 은 한 쌍이다. 둘 다 통과해야
#     "WAS 는 L4 가 흡수, DC 는 GSLB 가 흡수" 라는 분리가 실제로 성립한다.
#
# 실행: 점프서버 또는 모니터링 호스트. 장애 주입은 사람이 한다.
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WEB1="https://${WEB1_FQDN}"

phase="${1:-normal}"

case "${phase}" in
normal)
  hdr "사전 상태 (장애 주입 전)"
  d=$(get "${WEB1}/health/deep");  [ -n "${d}" ] && ok "deep " "정상 200" || ng "deep " "이미 실패 중이다. 먼저 고칠 것."
  l=$(get "${WEB1}/health/local"); [ -n "${l}" ] && ok "local" "정상 200" || ng "local" "이미 실패 중이다."
  i=$(get "${WEB1}/api/info")
  cross=$(jqget "${i}" cross_dc)
  assert_eq "cross" "false" "${cross:-false}" "평시에는 교차 경유가 없어야 한다"
  cat <<'NEXT'

다음 단계 — 장애를 주입하고 다시 실행한다.

  [C15/C16]  WAS-APP1-500 에서:   systemctl stop aadc-was
             그리고:              ./03-health-c15-c18.sh was-down
  [C17]      양쪽 WAS 모두 정지 후: ./03-health-c15-c18.sh was-all-down
  [C18]      DC-500 내부 L4 장비 정지 후: ./03-health-c15-c18.sh l4-down
NEXT
  ;;

was-down)
  hdr "C15 / C16 — 로컬 WAS 정지 상태"
  sleep 5
  if get "${WEB1}/health/deep" >/dev/null; then
    ok "C15" "deep 성공 — backup 경유. GSLB 는 움직이지 않는다 (의도대로)"
  else
    ng "C15" "deep 실패 — backup 멤버가 흡수하지 못했다. FortiADC backup server 설정을 확인할 것 (회신 2번)"
  fi
  if get "${WEB1}/health/local" >/dev/null; then
    ng "C16" "local 성공 — 로컬 WAS 가 죽었는데 성공하면 안 된다. upstream 이 L4 를 보고 있지 않은지 확인"
  else
    ok "C16" "local 실패 — 알람이 떠야 한다"
  fi
  i=$(get "${WEB1}/api/info")
  if [ -n "${i}" ]; then
    assert_eq "C15-a" "true" "$(jqget "${i}" cross_dc)" "실트래픽이 교차 경유로 넘어갔는가"
    note "was_host=$(jqget "${i}" was_host)  l4_dc=$(jqget "${i}" l4_dc)  was_dc=$(jqget "${i}" was_dc)"
  fi
  note ""
  note "알람 확인:  tail -f /var/log/aadc-alarm.log"
  note "  ① /health/local 실패     [즉시]"
  note "  ② degraded 시작          [즉시] → 이후 1시간마다 반복"
  ;;

was-all-down)
  hdr "C17 — WAS 전멸. 전환이 아니라 fallback 이 답이다"
  st=$(dig +noall +comments +time=3 "${SERVICE_FQDN}" A 2>/dev/null | grep -o 'status: [A-Z]*' | head -1)
  ans=$(dig +short +time=3 "${SERVICE_FQDN}" A 2>/dev/null | tr '\n' ' ')
  note "DNS status: ${st}   answer: ${ans}"
  if printf '%s' "${st}" | grep -q SERVFAIL; then
    ng "C17" "SERVFAIL — 502 보다 나쁘다. 도메인 전체가 죽은 것처럼 보이고 네거티브 캐싱까지 탄다. GSLB fallback 설정 필요 (회신 3번)"
  elif [ -n "${ans}" ]; then
    ok "C17" "IP 를 반환한다 (${ans}) — fallback 동작"
    code=$(curl -so /dev/null -w '%{http_code}' --max-time 8 "https://${SERVICE_FQDN}/api/info" 2>/dev/null)
    assert_eq "C17-a" "502" "${code}" "502 가 도달해야 원인 계층이 바로 특정된다"
  else
    ng "C17" "IP 응답 없음 (${st})"
  fi
  ;;

l4-down)
  hdr "C18 — L4 장비 정지 (WAS 는 정상). deep check 를 두는 단독 근거"
  sleep 5
  if get "${WEB1}/health/deep" >/dev/null; then
    ng "C18" "deep 이 아직 성공한다. deep 이 L4 VIP 를 경유하고 있지 않다는 뜻이다 — nginx upstream 확인"
  else
    ok "C18" "deep 실패 — GSLB 가 DC-500 을 빼야 한다"
  fi
  note "nginx 는 멀쩡히 살아서 502 만 반환한다. shallow check 로는 절대 잡히지 않는 장애다."
  note "GSLB 전환 확인:  watch -n2 \"dig +short ${SERVICE_FQDN} A\""
  note "감지 6초 + TTL 20초 → 약 26초 내에 DC-400 주소로 바뀌어야 한다."
  ;;

*)
  echo "사용: $0 [normal|was-down|was-all-down|l4-down]"; exit 2 ;;
esac

summary
