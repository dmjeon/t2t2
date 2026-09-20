#!/usr/bin/env bash
# =============================================================================
# 카나리 배포 — AADC-POC.md 8절
#   실행: 배포할 WAS 에서 root 로
#     ./deploy-canary.sh <새_버전>
#
# 설치가 아니라 **배포**다. 20-was.sh 를 다시 돌리지 않는다 —
# 그건 venv 재생성과 환경파일 재작성까지 해서 배포보다 훨씬 무겁고,
# 무엇보다 "무엇이 바뀌었는지"가 흐려진다.
# 여기서는 코드와 버전만 갈아끼우고 재시작한다.
#
# ★ 순서가 절차의 전부다.
#     1. DC-400 에 먼저      ← 실트래픽 1% 가 즉시 검증
#     2. 관찰                ← 영향받는 것은 1% 뿐
#     3. 이상 없으면 DC-500
#     4. 문제 시 DC-400 만 롤백  ← 99% 는 애초에 노출되지 않음
#
#   WAS 전멸은 토폴로지로 막을 수 없는 유일한 케이스이고, 현실에서 그것은
#   배포로 일어난다. 양쪽에 같은 깨진 코드를 올리면 이중화가 무의미하다.
#   GSLB 99:1 이 그대로 카나리가 된다.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/config.env"

NEW_VERSION="${1:-}"
[ -n "${NEW_VERSION}" ] || { echo "사용: $0 <새_버전>   예: $0 1.1.0"; exit 2; }
[ -f /etc/aadc/was.env ] || { echo "/etc/aadc/was.env 가 없다. 이 호스트는 WAS 가 아니다."; exit 1; }

CUR="$(grep -E '^AADC_APP_VERSION=' /etc/aadc/was.env | cut -d= -f2-)"
echo "== ${AADC_ROLE} (${AADC_DC}) =="
echo "   현재 ${CUR}  →  새 버전 ${NEW_VERSION}"

# ----- 순서 경고 -------------------------------------------------------------
if [ "${AADC_DC}" = "DC-500" ]; then
  cat <<'WARN'

------------------------------------------------------------------------------
★ 여기는 DC-500 이다. 트래픽의 99% 를 받는다.

  DC-400 에서 먼저 검증했는가? 게이트를 통과했는가?
      최소 10~30분  또는  요청 500건  중 늦은 쪽

  1% 면 초당 10건 기준 0.1건/s 라, 통계적으로 의미 있는 표본이 쌓이는 데
  시간이 걸린다. "5분 봤는데 괜찮더라" 는 아무것도 보지 않은 것과 같다.
------------------------------------------------------------------------------
WARN
  read -r -p "DC-400 검증을 마쳤다. DC-500 에 배포한다. 계속? (yes/no) " ans
  [ "${ans}" = "yes" ] || { echo "중단"; exit 1; }
fi

# ----- 롤백 지점 -------------------------------------------------------------
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="${APP_DIR}/rollback/${CUR}-${STAMP}"
echo "== 롤백 지점 =="
install -d -m 0755 "${APP_DIR}/rollback"
cp -a "${APP_DIR}/app" "${BACKUP}"
echo "   ${BACKUP}"

# ----- 코드 + 버전 -----------------------------------------------------------
echo "== 코드 교체 =="
rsync -a --delete "${ROOT}/app/aadc" "${APP_DIR}/app/"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/app"

# 의존성이 바뀌었을 수 있다. 바뀐 게 없으면 즉시 끝난다.
"${APP_DIR}/venv/bin/pip" install --quiet -r "${ROOT}/app/requirements.txt"

sed -i "s/^AADC_APP_VERSION=.*/AADC_APP_VERSION=${NEW_VERSION}/" /etc/aadc/was.env

echo "== 재시작 =="
systemctl restart aadc-was
sleep 3

# ----- 확인 ------------------------------------------------------------------
echo "== 확인 =="
ok=1
v="$(curl -sf --max-time 5 "http://127.0.0.1:${APP_PORT}/api/version" 2>/dev/null || echo '')"
echo "   /api/version   ${v:-응답 없음}"
printf '%s' "${v}" | grep -q "\"${NEW_VERSION}\"" || { echo "   ★ 버전이 반영되지 않았다"; ok=0; }

for p in /health/local /health/deep; do
  code="$(curl -so /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:${APP_PORT}${p}")"
  printf '   %-14s %s\n' "${p}" "${code}"
  [ "${code}" = "200" ] || ok=0
done

if [ "${ok}" -ne 1 ]; then
  cat <<ROLLBACK

------------------------------------------------------------------------------
★ 확인 실패. 즉시 롤백할 것:

    rsync -a --delete ${BACKUP}/ ${APP_DIR}/app/
    sed -i 's/^AADC_APP_VERSION=.*/AADC_APP_VERSION=${CUR}/' /etc/aadc/was.env
    systemctl restart aadc-was
------------------------------------------------------------------------------
ROLLBACK
  exit 1
fi

cat <<NEXT

------------------------------------------------------------------------------
${AADC_DC} 배포 완료 — ${CUR} → ${NEW_VERSION}

$( [ "${AADC_DC}" = "DC-400" ] && cat <<'C4'
다음: 게이트를 통과할 때까지 관찰한다.
  최소 10~30분 또는 요청 500건 중 늦은 쪽

  에러율   tail -f /var/log/nginx/aadc.log   (WEB-DC2 에서)
  p95      verify/05-scenario-c8-c11.sh c9a 1800
  버전     curl -s https://web2.niceci.cloud/api/version

  이상 없으면 DC-500 의 WAS 에서 같은 스크립트를 실행한다.
  문제가 있으면 DC-400 만 롤백한다 — 99% 는 애초에 노출되지 않았다.
C4
)
$( [ "${AADC_DC}" = "DC-500" ] && echo "양쪽 배포 완료. 두 DC 의 버전을 대조할 것:
  curl -s https://web1.niceci.cloud/api/version
  curl -s https://web2.niceci.cloud/api/version" )

롤백 지점: ${BACKUP}
------------------------------------------------------------------------------
NEXT
