#!/usr/bin/env bash
# =============================================================================
# WAS 계층 설치 — WAS-APP1-500 (DC-500) / WAS-DC2 (DC-400)
#   FastAPI (DB VIP 직결)
#   ./20-was.sh WAS-APP1-500
# =============================================================================
set -euo pipefail
AADC_ROLE_ARG="${1:-}"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_bash
require_role 'WAS-*'

banner "WAS 계층 (FastAPI)" "WAS tier (FastAPI)"
kv "DB 접속 / DB target" "${DB_APP_TARGET}:${DB_PORT}"
kv "앱 버전 / version"   "${APP_VERSION}"

step "패키지" "Packages"
dnf -y install python3 python3-pip mariadb >/dev/null
say "python3 python3-pip mariadb"

step "애플리케이션" "Application"
id -u "${APP_USER}" >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d "${APP_DIR}" "${APP_USER}"
install -d -m 0755 -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}" "${APP_DIR}/app"
rsync -a --delete "${ROOT}/app/aadc" "${APP_DIR}/app/"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/app"

python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${APP_DIR}/venv/bin/pip" install --quiet -r "${ROOT}/app/requirements.txt"
kv "code"  "${APP_DIR}/app/aadc"
kv "venv"  "${APP_DIR}/venv"

step "환경 파일" "Environment file"
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
# ※ 늘리면 nginx 의 /health/deep proxy_read_timeout 도 같이 올려야 한다.
AADC_DB_CONNECT_TIMEOUT=${DB_CONNECT_TIMEOUT}
AADC_DB_READ_TIMEOUT=${DB_READ_TIMEOUT}
AADC_DEEP_WRITER_PROBE=select
AADC_HEALTH_CACHE_TTL=1.0
ENV
chmod 0640 /etc/aadc/was.env
chown root:"${APP_USER}" /etc/aadc/was.env
kv "/etc/aadc/was.env" "written (0640)"

step "서비스" "Service"
install -m 0644 "${ROOT}/app/systemd/aadc-was.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now aadc-was
sleep 3
systemctl is-active --quiet aadc-was && say "aadc-was running" \
  || { warn "aadc-was 기동 실패" "aadc-was failed to start"
       journalctl -u aadc-was -n 15 --no-pager | sed 's/^/   /'; }

step "방화벽" "Firewall"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${APP_PORT}"/tcp >/dev/null
  firewall-cmd --reload >/dev/null
  say "tcp/${APP_PORT} opened"
else
  say "firewalld not running - skipped"
fi

step "확인" "Check"
curl -sf "http://127.0.0.1:${APP_PORT}/api/info"     | head -c 400 | sed 's/^/   /'; echo
curl -sf "http://127.0.0.1:${APP_PORT}/health/local" | head -c 200 | sed 's/^/   /'; echo
if curl -sf "http://127.0.0.1:${APP_PORT}/health/deep" >/dev/null; then
  msg "/health/deep 200 — writer 까지 경로가 뚫렸다." \
      "/health/deep 200 - the path to the writer is open."
else
  warn "/health/deep 실패 — VIP 를 잡은 노드가 read_only=OFF 인지 확인할 것" \
       "/health/deep failed - check that the VIP holder has read_only=OFF"
  say  "mysql -h${DB_VIP} -e 'SELECT @@hostname, @@read_only'"
fi

cat <<'NEXT'

-------------------------------------------------------------------------------
주의 / Notes

  · /health/deep 은 "writer 에 닿고 read_only=0" 일 때만 200 이다.
    DC-400 에서는 이 확인이 DCI 단절을 스스로 감지하는 장치가 된다 (C8).
    /health/deep is 200 only when the writer is reachable AND read_only=0.
    On DC-400 this is what makes the DC withdraw itself when the DCI breaks.

  · 앱은 DB VIP 에 직접 붙는다. 로컬 failover 에 앱은 관여하지 않는다 —
    keepalived 가 VIP 를 옮기면 커넥션 풀이 같은 주소로 재연결할 뿐이다.
    The app connects straight to the DB VIP. Local failover needs nothing from
    the app: keepalived moves the VIP, the pool reconnects to the same address.

  · DR 전환은 수동 2단 게이트다. 1단계가 이 호스트의 /etc/aadc/was.env 를
    고치고 앱을 재시작한다. ../dr/README.md 참조.
    DR switchover is a manual two-stage gate; stage 1 edits this host's
    /etc/aadc/was.env and restarts the app. See ../dr/README.md.

나중에 / Later
  ../deploy/deploy-canary.sh <version>   카나리 배포 / canary deploy
     설치 스크립트를 다시 돌리지 않는다. 코드와 버전만 갈아끼운다.
     Do not re-run this installer to deploy; that script swaps code only.
-------------------------------------------------------------------------------
NEXT
