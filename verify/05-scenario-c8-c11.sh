#!/usr/bin/env bash
# =============================================================================
# 장애 시나리오 — AADC-POC.md 11-5절
#   C8    DCI 단절                      DC-400 이탈 여부, 99% 무영향
#   C9    WAS-APP1 프로세스 정지 (= D 훈련)
#   C9-a  degraded 지속 운영 (최소 30분)  ★ 이 설계의 핵심 검증
#   C10   WEB-DC1 정지                   GSLB 전환 소요 시간 실측
#   C11   DC-500 차단 → DC-400 단독      1% → 100% 점프 (= A 훈련)  ★
#   C19   카나리 배포 절차
#
# C9-a 와 C11 이 핵심이다. 각각 "degraded 를 지속할 수 있는가" 와
# "DC-400 이 100% 를 받을 수 있는가" 에 답한다.
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode="${1:-help}"

gslb_watch() {
  hdr "GSLB 응답 관찰 — Ctrl-C 로 종료"
  prev=""
  while true; do
    a=$(dig +short +time=2 "${SERVICE_FQDN}" A 2>/dev/null | sort | tr '\n' ' ')
    [ "${a}" != "${prev}" ] && { printf '   %s  %s\n' "$(date -Is)" "${a:-<없음>}"; prev="${a}"; }
    sleep 1
  done
}

case "${mode}" in
gslb-watch) gslb_watch ;;

c9a)
  # degraded 지속 운영 측정. 기본 30분.
  DUR="${2:-1800}"
  OUT="${3:-/var/tmp/aadc-c9a-$(date +%Y%m%d-%H%M).csv}"
  hdr "C9-a  degraded 지속 운영 측정 (${DUR}초)"
  note "출력: ${OUT}"
  note "7절 제약 3개를 한 번에 검증한다:"
  note "  ① DCI 대역폭이 하드 제약이 되는가"
  note "  ② WAS 1대가 100% 를 '지속' 처리할 수 있는가"
  note "  ③ 알람이 실제로 울리는가"
  echo "ts,http_code,total_ms,was_host,was_dc,l4_dc,cross" > "${OUT}"
  end=$(( $(date +%s) + DUR ))
  n=0; cross=0
  while [ "$(date +%s)" -lt "${end}" ]; do
    t0=$(date +%s%3N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1000))')
    body=$(curl -s -m 10 -w '\n%{http_code}' "https://${WEB1_FQDN}/api/info" 2>/dev/null)
    t1=$(date +%s%3N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1000))')
    code=$(printf '%s' "${body}" | tail -1); json=$(printf '%s' "${body}" | head -n -1)
    c=$(jqget "${json}" cross_dc)
    [ "${c}" = "true" ] && cross=$((cross+1))
    n=$((n+1))
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date -Is)" "${code}" "$((t1-t0))" \
      "$(jqget "${json}" was_host)" "$(jqget "${json}" was_dc)" "$(jqget "${json}" l4_dc)" "${c:-}" >> "${OUT}"
    sleep 1
  done
  note ""
  note "총 ${n}건, 교차 ${cross}건"
  tail -n +2 "${OUT}" | awk -F, '$2==200{print $3}' | sort -n | awk '
    {a[NR]=$1}
    END{ if(NR==0){print "   200 응답이 없다"; exit}
         printf "   p50 %sms  p95 %sms  p99 %sms  max %sms  (200 응답 %d건)\n",
                a[int(NR*0.50)+(NR>1)], a[int(NR*0.95)], a[int(NR*0.99)], a[NR], NR }'
  note ""
  note "함께 기록할 것 (이 스크립트가 재지 않는다):"
  note "  · DCI 실사용 대역   — FortiGate 인터페이스 통계 또는 iftop"
  note "  · WAS-DC2 자원      — sar / top / ss -s 를 WAS-DC2 에서"
  note "  · 알람 로그         — /var/log/aadc-alarm.log 에 ①② 가 떴는가"
  note "  · 평시 기준선과 비교 — 01-baseline-c1-c2.sh 의 C2-b 값"
  ;;

c11)
  hdr "C11 / A 훈련 — DC-500 차단, DC-400 단독 (1% → 100%)"
  cat <<'STEP'
   절차
     1. GSLB 가중치를  DC-500 0 : DC-400 100  으로 변경
     2. 30분 ~ 수 시간 운영
     3. 관찰: WAS-DC2 CPU/메모리/커넥션, DB 쿼리 지연(전량 DCI 경유), p95
     4. 복귀: 가중치를 99:1 로 되돌린다  (되돌리기 비용 낮음 — 가중치만)

   ★ 이것이 "DC-400 이 100% 를 받을 수 있는지" 를 실증하는 유일한 수단이다.
     평시 1% 라고 사양을 낮추면 DC-500 장애 순간 100배 부하 점프로 같이 죽는다.
     이 구조에서 가장 흔한 사고 형태다 (9절).

   측정은 c9a 모드를 WEB2_FQDN 으로 돌려서 쓴다:
     WEB1_FQDN=web2.niceci.cloud ./05-scenario-c8-c11.sh c9a 1800
STEP
  ;;

c8)
  hdr "C8 — DCI 단절"
  cat <<'STEP'
   주입:  peer-routing 경로를 FortiGate 정책으로 차단 (양방향)
   기대
     · DC-500  : 정상. 99% 사용자 무영향
     · DC-400  : writer(10.3.31.50) 에 닿지 못해 /health/deep 실패 → GSLB 이탈
     · DR 복제 : 중단
   판정
     이 검증이 4절 "writer 도달 확인" 이 왜 필요한지를 증명한다.
     writer 확인이 없으면 1% 사용자가 계속 DC-400 으로 가서 쓰기만 실패한다.
STEP
  d5=$(curl -so /dev/null -w '%{http_code}' -m 8 "https://${WEB1_FQDN}/health/deep" 2>/dev/null)
  d4=$(curl -so /dev/null -w '%{http_code}' -m 8 "https://${WEB2_FQDN}/health/deep" 2>/dev/null)
  note "현재  DC-500 deep=${d5}   DC-400 deep=${d4}"
  [ "${d5}" = "200" ] && ok "C8-a" "DC-500 deep 200 (99% 무영향)" || ng "C8-a" "DC-500 deep ${d5}"
  [ "${d4}" = "200" ] && sk "C8-b" "DC-400 deep 200 — 아직 단절 전이거나 writer 확인이 동작하지 않음" \
                      || ok "C8-b" "DC-400 deep ${d4} — writer 미도달로 스스로 이탈"
  ;;

c10)
  hdr "C10 — WEB-DC1 정지. 1:1 구조의 최장 노출 구간"
  note "WEB 은 흡수 주체가 없는 유일한 계층이다. GSLB 전환뿐이다."
  note "주입:  WEB-DC1 에서  systemctl stop nginx"
  note "관찰:  ./05-scenario-c8-c11.sh gslb-watch   (다른 창에서 미리)"
  note "기대:  감지 약 6초 (3초 × 2회) + TTL 20초 → 약 26초"
  ;;

c19)
  hdr "C19 — 카나리 배포 절차 (8절)"
  cat <<'STEP'
   WAS 전멸은 토폴로지로 막을 수 없는 유일한 케이스다.
   현실에서 그것은 배포로 일어난다. GSLB 99:1 이 그대로 카나리가 된다.

     1. DC-400 에 먼저 배포              ← 실트래픽 1% 가 즉시 검증
     2. 관찰 (에러율 / p95 / 로그)
        ★ 최소 게이트: 10~30분 또는 요청 500건 중 늦은 쪽
          1% 면 초당 10건 기준 0.1건/s 라 표본이 쌓이는 데 시간이 걸린다
     3. 이상 없으면 DC-500 배포
     4. 문제 발견 시 DC-400 만 롤백      ← 99% 는 애초에 노출되지 않음

   버전 확인:
     curl -s https://web1.niceci.cloud/api/version   # DC-500
     curl -s https://web2.niceci.cloud/api/version   # DC-400
STEP
  v1=$(get "https://${WEB1_FQDN}/api/version"); v2=$(get "https://${WEB2_FQDN}/api/version")
  note "DC-500: $(jqget "${v1}" app_version)   DC-400: $(jqget "${v2}" app_version)"
  ;;

*)
  cat <<'HELP'
사용: 05-scenario-c8-c11.sh <모드>

  gslb-watch          GSLB 응답 IP 변화를 실시간으로 본다
  c8                  DCI 단절
  c9a [초] [출력파일]  degraded 지속 운영 측정 (기본 1800초)   ★ 핵심
  c10                 WEB-DC1 정지
  c11                 DC-500 차단 → DC-400 단독 (A 훈련)      ★ 핵심
  c19                 카나리 배포 절차
HELP
  ;;
esac

summary
