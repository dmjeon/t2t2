#!/usr/bin/env bash
# =============================================================================
# 기준선 측정 (선행) — AADC-POC.md 11-1절
#   C1    DCI RTT + 대역폭     ★ 최우선. 7-①④ 가 여기에 달려 있다
#   C2    요청당 평균 쿼리 수 N
#   C2-b  로컬 L4 경유 응답시간 p50/p95/p99
#
# 실행: WAS-APP1-500 (DC-500) 에서
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hdr "C1  DCI RTT (peer-routing 경유)"
for target in "${WAS_DC400_IP}:WAS-DC2" "${DB_DR_IP}:DB-DR" "${GW_DR_APP}:dr-app GW"; do
  ip="${target%%:*}"; name="${target#*:}"
  out=$(ping -c 20 -i 0.2 -W 2 "${ip}" 2>/dev/null | tail -2)
  if [ -n "${out}" ]; then
    rtt=$(printf '%s' "${out}" | grep -oE '= [0-9.]+/[0-9.]+/[0-9.]+' | head -1)
    ok "C1" "${name} (${ip})  min/avg/max ${rtt#= }"
  else
    ng "C1" "${name} (${ip}) 도달 불가 — peer-routing 확인 필요"
  fi
done

note ""
note "대역폭은 ping 으로 알 수 없다. 둘 중 하나로 실측할 것:"
note "  · Viettel 회신 (회신 대기 1번)"
note "  · iperf3 -s (DC-400) / iperf3 -c <IP> -t 30 -P 4 (DC-500)"
note "    ※ FW-30 (10.3.21.51 <-> 10.7.21.52 TCP 5201) 이 필요하다."
note "      두 WAS 는 평시에 직접 통신하지 않으므로 열린 포트가 없다."
note ""
note "AADC-POC.md 7-④ 판정표"
note "   1~3ms  → degraded 며칠도 운영 가능"
note "   5~10ms → 반나절 정도 수용"
note "   20ms+  → 수 시간 내 복구 필수. SLA 에 명시"

hdr "C1-a  경로 확인 (traceroute)"
if command -v traceroute >/dev/null 2>&1; then
  traceroute -n -w 2 -q 1 -m 8 "${WAS_DC400_IP}" 2>&1 | sed 's/^/   /'
  note "기대 경로: ${GW_DC_APP} → peer-routing → ${GW_DR_APP}"
else
  sk "C1-a" "traceroute 미설치 (dnf install traceroute)"
fi

hdr "C2 / C2-b  요청당 쿼리 수와 로컬 경유 응답시간"
if need_l4 "C2"; then
  URL="http://${DC500_L4_VIP}:${L4_PORT}"
  for N in 1 5 10 20; do
    body=$(get "${URL}/api/load?queries=${N}" 10)
    if [ -z "${body}" ]; then ng "C2" "N=${N} 호출 실패 (${URL})"; continue; fi
    total=$(jqget "${body}" total_ms); per=$(jqget "${body}" per_query_avg_ms)
    ok "C2" "N=${N}  total ${total}ms  쿼리당 ${per}ms"
  done

  note ""
  note "C2-b  로컬 L4 경유 p50/p95/p99 (100회)"
  tmp=$(mktemp)
  for _ in $(seq 100); do
    curl -so /dev/null -w '%{time_total}\n' --max-time 5 "${URL}/api/info" 2>/dev/null >> "${tmp}"
  done
  sort -n "${tmp}" | awk '
    {a[NR]=$1*1000}
    END{printf "   p50 %.1fms  p95 %.1fms  p99 %.1fms  max %.1fms  (n=%d)\n",
        a[int(NR*0.50)], a[int(NR*0.95)], a[int(NR*0.99)], a[NR], NR}'
  rm -f "${tmp}"
  note "이 값이 degraded 비교 기준선이다. D 훈련 중에 같은 측정을 반복할 것."
fi

summary
