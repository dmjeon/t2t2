#!/usr/bin/env bash
# =============================================================================
# 검증 도구 — 나중에 따로 실행하는 단계
#   ./51-verify.sh
#
# verify/ 스크립트가 쓰는 도구만 깐다. 서비스에는 아무 영향이 없고,
# 검증을 돌릴 호스트에서만 필요하다.
#
#   jq          JSON 판정 (없어도 lib.sh 가 sed 로 대체하지만 부정확하다)
#   dig         GSLB 응답 / SERVFAIL 확인 — C17
#   traceroute  경로 확인 — R2
#   iperf3      DCI 대역폭 실측 — C1.  ★ ping 으로는 대역을 알 수 없다
#   mariadb     DB 상태 조회 — C3~C7
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/config.env"

echo "== 검증 도구 설치 =="
dnf -y install jq bind-utils traceroute mariadb >/dev/null
# iperf3 는 EPEL 에 있는 경우가 있어 실패해도 넘어간다.
dnf -y install iperf3 >/dev/null 2>&1 || \
  echo "   iperf3 설치 실패 — C1 대역폭 측정만 영향. EPEL 확인:  dnf -y install epel-release"

echo "== 실행 권한 =="
chmod +x "${ROOT}"/verify/*.sh "${ROOT}"/db/*.sh "${ROOT}"/dr/*.sh 2>/dev/null || true

echo "== 도구 확인 =="
for t in jq dig traceroute mysql iperf3; do
  printf '   %-12s %s\n' "${t}" "$(command -v "${t}" 2>/dev/null || echo '없음')"
done

cat <<'NEXT'

------------------------------------------------------------------------------
평시에 돌릴 수 있는 것부터
  ../verify/run-all.sh

장애 주입이 필요한 항목은 개별 실행한다. 주입은 사람이 하고
스크립트는 관찰과 판정만 맡는다.

  ../verify/01-baseline-c1-c2.sh          C1 DCI RTT ★ 최우선
  ../verify/02-path-r1-r6.sh              R1~R6, C12, C13
  ../verify/03-health-c15-c18.sh normal   C15~C18
  ../verify/04-db-c3-c7.sh status         C3~C7
  ../verify/05-scenario-c8-c11.sh         C8~C11, C19

C1 을 가장 먼저 한다. DCI RTT 없이는 degraded 허용 시간을 정할 수 없고,
그 값이 7절 제약 전체의 입력이다.
------------------------------------------------------------------------------
NEXT
