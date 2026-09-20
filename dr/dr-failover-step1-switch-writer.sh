#!/usr/bin/env bash
# =============================================================================
# DR 전환 1단계 — WAS 의 DB 접속 대상을 DB-DR 로 바꾼다
#   실행: 모든 WAS 에서 root 로 (WAS 마다 1회씩)
#
#   이 단계만으로는 **쓰기가 되지 않는다.** DB-DR 이 read_only=ON 이기 때문이다.
#   그것이 2단으로 나눈 이유다. 1단계를 실수로 눌러도 데이터가 갈라지지 않는다.
#
#   ★ 앱 재시작이 필요하다.
#     커넥션 풀이 기존 주소로 맺은 연결을 물고 있어 환경파일만 고쳐서는 바뀌지
#     않는다. 재시작하는 수 초 동안 이 WAS 는 503 이다. WAS 를 한 대씩 돌리면
#     L4 가 나머지 한 대로 흡수한다 (AADC-POC.md 3-4절).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.env"

ENV_FILE="/etc/aadc/was.env"
[ -f "${ENV_FILE}" ] || { echo "${ENV_FILE} 이 없다. 이 호스트는 WAS 가 아니다."; exit 1; }

echo "== 현재 =="
grep -E '^AADC_DB_(HOST|PORT)=' "${ENV_FILE}"

cat <<WARN

------------------------------------------------------------------------------
DR 전환 1단계
  AADC_DB_HOST:  ${DB_VIP}  ->  ${DB_DR_IP}
  대상 호스트  :  $(hostname)   ← 이 WAS 한 대만 바뀐다. 나머지 WAS 에서도 따로 실행할 것

  이 조작은 자동 전환이 아니다. DCI 단절과 DC 장애를 구분할 방법이 없어서
  사람이 판단하도록 남겨 둔 지점이다 (AADC-POC.md 3-4절).

  누르기 전에 확인할 것:
    1. DC-500 이 정말 죽었는가, DCI 만 끊긴 것은 아닌가
    2. DB-DR 의 복제 지연이 얼마인가  (db/check-replication.sh)
    3. DC-500 에서 아직 쓰기가 들어가고 있지는 않은가

  이 단계는 앱을 재시작한다. 재시작 창 동안 이 WAS 는 503 이다.
------------------------------------------------------------------------------
WARN
read -r -p "1단계를 진행한다. 계속? (yes/no) " ans
[ "${ans}" = "yes" ] || { echo "중단"; exit 1; }

# ----- 재시작 전에 도달성부터 본다 -------------------------------------------
# 이 WAS 에서 DB-DR 로 가는 경로는 **평시에 한 번도 쓰이지 않는다.**
# 방화벽이 막혀 있어도 오늘까지는 아무 증상이 없다가, 하필 DR 전환 순간에
# 드러난다. 먼저 고치고 재시작해야 재시작 창을 헛되이 쓰지 않는다.
#   → 이 경로는 FW-27 (FIREWALL-REQUEST-detail.md §3-5) 이다. 신청은 돼 있고
#     적용 여부는 별개다. 평시 트래픽이 0 인 규칙이라 누락돼도 티가 나지 않는다.
echo "== 사전 확인: 이 WAS 에서 DB-DR 에 닿는가 =="
if ! mysql -h "${DB_DR_IP}" -P 3306 -u"${DB_MON_USER}" -p"${DB_MON_PASS}" \
     --connect-timeout=5 -N -B -e "SELECT @@hostname, @@read_only" 2>/dev/null; then
  cat <<FAIL

  ${DB_DR_IP}:3306 에 닿지 않는다. **전환을 중단한다.**

  확인 순서
    1. 방화벽 — FW-27 ($(hostname) → ${DB_DR_IP} TCP 3306) 이 적용됐는가
       (신청서에는 있다. 평시 트래픽 0 이라 적용 누락이 티가 나지 않는 규칙)
    2. 경로   — ping ${DB_DR_IP} / traceroute -n ${DB_DR_IP}
    3. DB-DR  — systemctl status mariadb, bind_address

  여기서 멈추면 was.env 도 앱도 건드리지 않은 상태 그대로다.
FAIL
  exit 1
fi
echo "   도달 확인. 계속한다."

cp -a "${ENV_FILE}" "${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
sed -i -e "s/^AADC_DB_HOST=.*/AADC_DB_HOST=${DB_DR_IP}/" \
       -e "s/^AADC_DB_PORT=.*/AADC_DB_PORT=3306/" "${ENV_FILE}"

echo "== 전환 후 =="
grep -E '^AADC_DB_(HOST|PORT)=' "${ENV_FILE}"

systemctl restart aadc-was
sleep 3

logger -t aadc-dr "DR failover step1: db host -> ${DB_DR_IP} on $(hostname)"

echo "== 확인 =="
curl -s -o /dev/null -w '  /health/deep  HTTP %{http_code}\n' \
  "http://127.0.0.1:${APP_PORT}/health/deep" || true
curl -sf "http://127.0.0.1:${APP_PORT}/api/db/status" | head -c 300; echo

cat <<'NEXT'

------------------------------------------------------------------------------
1단계 완료. 지금 상태:
  · 읽기  : DB-DR 로 간다 (동작)
  · 쓰기  : 실패한다 (DB-DR 이 read_only)  ← 의도된 상태
  · /health/deep : 503 writer is read_only  ← 이것도 의도된 상태다

  /api/db/write 가 503 을 내는 것이 정상이다.
  쓰기를 열려면 사람이 2단계를 별도로 판단해서 실행한다:
      dr-failover-step2-enable-write.sh        (DB-DR 에서)

  ★ 다른 WAS 에서도 이 스크립트를 실행해야 전환이 끝난다.
------------------------------------------------------------------------------
NEXT
