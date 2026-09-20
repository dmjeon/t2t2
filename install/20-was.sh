#!/usr/bin/env bash
# =============================================================================
# WAS 계층 설치 — WAS-APP1-500 (DC-500) / WAS-DC2 (DC-400)
#   FastAPI (DB VIP 직결)
#   ./20-was.sh
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/config.env"

case "${AADC_ROLE}" in WAS-*) ;; *) echo "AADC_ROLE=${AADC_ROLE} 는 WAS 역할이 아니다."; exit 1;; esac

echo "== 1. 패키지 =="
dnf -y install python3 python3-pip mariadb >/dev/null

echo "== 2. 애플리케이션 =="
id -u "${APP_USER}" >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d "${APP_DIR}" "${APP_USER}"
install -d -m 0755 -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}" "${APP_DIR}/app"
rsync -a --delete "${ROOT}/app/aadc" "${APP_DIR}/app/"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/app"

python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${APP_DIR}/venv/bin/pip" install --quiet -r "${ROOT}/app/requirements.txt"

echo "== 3. 환경 파일 =="
cat > /etc/aadc/was.env <<ENV
AADC_DC=${AADC_DC}
AADC_NODE=${AADC_ROLE}
AADC_APP_VERSION=${APP_VERSION}
AADC_L4_PREFIX_DC500=${L4_PREFIX_DC500}
AADC_L4_PREFIX_DC400=${L4_PREFIX_DC400}
AADC_DB_HOST=${DB_APP_TARGET}
AADC_DB_PORT=${DB_PORT}
AADC_DB_USER=${DB_APP_USER}
AADC_DB_PASS=${DB_APP_PASS}
AADC_DB_NAME=${DB_NAME}
# 중간 프록시가 없으므로 이 두 값이 DCI 구간을 방어하는 유일한 장치다
# (AADC-POC.md 3-4절). 회신 1번(RTT) 후 재조정할 것.
# ※ 늘리면 nginx 의 /health/deep proxy_read_timeout(6s) 도 같이 올려야 한다.
AADC_DB_CONNECT_TIMEOUT=${DB_CONNECT_TIMEOUT}
AADC_DB_READ_TIMEOUT=${DB_READ_TIMEOUT}
AADC_DEEP_WRITER_PROBE=select
AADC_HEALTH_CACHE_TTL=1.0
ENV
chmod 0640 /etc/aadc/was.env
chown root:"${APP_USER}" /etc/aadc/was.env

echo "== 4. 서비스 =="
install -m 0644 "${ROOT}/app/systemd/aadc-was.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now aadc-was
sleep 3

echo "== 5. 방화벽 =="
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${APP_PORT}"/tcp >/dev/null
  firewall-cmd --reload >/dev/null
fi

echo "== 6. 확인 =="
curl -sf "http://127.0.0.1:${APP_PORT}/api/info"    | head -c 400; echo
curl -sf "http://127.0.0.1:${APP_PORT}/health/local" | head -c 200; echo
if curl -sf "http://127.0.0.1:${APP_PORT}/health/deep" >/dev/null; then
  echo "   /health/deep 200 — writer 도달 확인됨"
else
  echo "   /health/deep 실패 — DB VIP 를 잡은 노드가 read_only=OFF 인지 확인할 것"
  echo "     mysql -h${DB_VIP} -e 'SELECT @@hostname, @@read_only'"
fi

cat <<'NEXT'

------------------------------------------------------------------------------
주의
  · /health/deep 은 "writer 에 닿고 read_only=0" 일 때만 200 이다.
    DC-400 에서는 이 확인이 DCI 단절을 스스로 감지하는 장치가 된다(C8).
  · 앱은 DB VIP 에 직접 붙는다. 로컬 failover 는 앱이 관여하지 않는다 —
    keepalived 가 VIP 를 옮기면 커넥션 풀이 같은 주소로 재연결한다.
  · DR 전환은 수동 2단 게이트다. dr/README.md 참조.
    1단계는 이 호스트의 /etc/aadc/was.env 를 고치고 앱을 재시작한다.
------------------------------------------------------------------------------
NEXT
