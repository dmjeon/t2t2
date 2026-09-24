#!/usr/bin/env bash
# =============================================================================
# WAS 계층 설치 — WAS-APP1-500 (DC-500) / WAS-DC2 (DC-400)
#   FastAPI (DB VIP 직결) + 내부 L4 VIP 테스트 페이지 /l4test
#   ./20-was.sh WAS-APP1-500
# =============================================================================
set -euo pipefail
AADC_ROLE_ARG="${1:-}"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_bash
require_role 'WAS-*'
# 이 DC 의 L4 VIP / backup 멤버를 얻는다. /l4test 화면이 "무엇을 때려야 하는가"를
# 띄우는 데 쓴다 (L4_VIP, BACKUP_MEMBER, WAS_LOCAL).
resolve_dc_vars

banner "WAS 계층 (FastAPI)" "WAS tier (FastAPI)"
if [ "${DB_MODE}" = "sqlite" ]; then
  kv "DB backend" "sqlite  (TEMPORARY - local file, not a shared DB)"
  kv "DB target"  "${SQLITE_PATH}"
else
  kv "DB backend" "mariadb"
  kv "DB target"  "${DB_APP_TARGET}:${DB_PORT}"
fi
kv "app version" "${APP_VERSION}"
kv "upstream mode" "${UPSTREAM_MODE}   ($( [ "${UPSTREAM_MODE}" = l4 ] \
                       && echo 'WEB -> L4 VIP -> WAS' || echo 'WEB -> WAS 직결 (L4 우회)' ))"
kv "local L4 VIP"  "${L4_VIP}:${L4_PORT}"
kv "backup member" "${BACKUP_MEMBER}:${APP_PORT}   (이 DC L4 풀의 원격 멤버)"

step "패키지" "Packages"
ensure_pkg python3 python3-pip mariadb
say "python3 python3-pip mariadb"

step "애플리케이션" "Application"
id -u "${APP_USER}" >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d "${APP_DIR}" "${APP_USER}"
install -d -m 0755 -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}" "${APP_DIR}/app"
rsync -a --delete "${ROOT}/app/aadc" "${APP_DIR}/app/"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/app"

# sqlite 모드용 데이터 디렉터리. mariadb 모드에서는 비어 있을 뿐 해가 없다.
install -d -m 0750 -o "${APP_USER}" -g "${APP_USER}" "$(dirname "${SQLITE_PATH}")"

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
# L4 우회(direct) 모드 판정용. 앞 홉이 WEB 이면 L4 를 건너뛴 것이다.
AADC_WEB_PREFIX_DC500=${WEB_PREFIX_DC500}
AADC_WEB_PREFIX_DC400=${WEB_PREFIX_DC400}
# /l4test 화면 표시 전용 — **기대값**이지 관측값이 아니다. 경로 판정은 언제나
# 앞 홉 주소(req.client.host)로만 한다. 둘을 나란히 보여 주는 것이 목적이다:
# "WEB 은 l4 로 설치됐는데 실제로 들어온 앞 홉은 WEB 주소다" 가 한눈에 보인다.
AADC_UPSTREAM_MODE=${UPSTREAM_MODE}
AADC_L4_VIP=${L4_VIP}
AADC_BACKUP_MEMBER=${BACKUP_MEMBER}
AADC_L4_PORT=${L4_PORT}
AADC_APP_PORT=${APP_PORT}
AADC_DB_MODE=${DB_MODE}
AADC_SQLITE_PATH=${SQLITE_PATH}
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
# ★ enable --now 는 이미 떠 있는 유닛에 아무것도 하지 않는다. was.env 는
#   systemd 의 EnvironmentFile 이라 **기동 시점에만** 읽히므로, 재실행에서
#   환경이 바뀌었는데도 반영이 안 되는 일이 생긴다. 2026-09-22 에 실제로
#   그랬다 — config.env 를 mariadb 로 고치고 이 스크립트를 돌렸는데 앱은
#   계속 sqlite 를 보고 있었다. 항상 재시작한다. (30-web.sh 는 이미 그런다)
systemctl enable aadc-was
systemctl restart aadc-was
sleep 3
systemctl is-active --quiet aadc-was && say "aadc-was running" \
  || { warn "aadc-was 기동 실패" "aadc-was failed to start"
       journalctl -u aadc-was -n 15 --no-pager | sed 's/^/   /'; }

step "방화벽" "Firewall"
# L4 가 Full NAT 이면 WAS 에 도착하는 출발지는 WEB 이 아니라 L4 의 SNAT 주소다
# (${L4_PREFIX_DC500} / ${L4_PREFIX_DC400}). 출발지를 좁혀 열면 L4 를 붙이는 순간
# 전부 막히므로, 여기서는 포트만 연다. 세그먼트 통제는 앞단 방화벽이 한다.
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${APP_PORT}"/tcp >/dev/null
  firewall-cmd --reload >/dev/null
  say "tcp/${APP_PORT} opened  (L4 SNAT 출발지 ${L4_PREFIX_DC500}/${L4_PREFIX_DC400} 포함)"
else
  say "firewalld not running - skipped"
fi

step "확인" "Check"
curl -sf "http://127.0.0.1:${APP_PORT}/api/info"     | head -c 400 | sed 's/^/   /'; echo
curl -sf "http://127.0.0.1:${APP_PORT}/health/local" | head -c 200 | sed 's/^/   /'; echo
if curl -sf "http://127.0.0.1:${APP_PORT}/l4test" | grep -q "내부 L4 VIP 테스트"; then
  say "/l4test 200 — 테스트 페이지 준비됨 / test page served"
else
  warn "/l4test 가 뜨지 않는다" "/l4test is not being served"
  say  "앱 코드가 낡았을 수 있다: git pull 후 이 스크립트를 다시 돌릴 것"
fi
if curl -sf "http://127.0.0.1:${APP_PORT}/health/deep" >/dev/null; then
  msg "/health/deep 200 — writer 까지 경로가 뚫렸다." \
      "/health/deep 200 - the path to the writer is open."
else
  warn "/health/deep 실패 — VIP 를 잡은 노드가 read_only=OFF 인지 확인할 것" \
       "/health/deep failed - check that the VIP holder has read_only=OFF"
  say  "mysql -h${DB_VIP} -e 'SELECT @@hostname, @@read_only'"
fi

cat <<L4TEST

-------------------------------------------------------------------------------
네트워크 팀에 넘길 테스트 페이지 / test page for the network team

  이 WAS 직접 (기준선 — 반드시 먼저 이게 떠야 한다)
      http://${WAS_LOCAL}:${APP_PORT}/l4test      -> "VIP 미경유" 로 뜨는 게 정상

  내부 L4 VIP 를 잡은 뒤 / once the internal L4 VIP is up
      http://${L4_VIP}:${L4_PORT}/l4test          -> 이 DC(${AADC_DC}) 의 WAS 가 받아야 정상
      http://${BACKUP_MEMBER}:${APP_PORT}/l4test   -> 반대편 DC 의 WAS 가 받아야 정상 (C13, L4 미경유)

  화면 맨 위 한 줄만 보면 된다 / read only the banner at the top
      초록 "VIP 경유 확인"   앞 홉이 ${L4_PREFIX_DC500}/${L4_PREFIX_DC400} = L4 를 탔다
      주황 "VIP 미경유"      앞 홉이 WEB 주소 = L4 를 건너뛰었다
      빨강 "판정 불가"       앞 홉이 어느 프리픽스도 아니다. 아래 둘을 의심할 것 —
                             · L4 의 SNAT 풀 주소가 ${L4_PREFIX_DC500}/${L4_PREFIX_DC400} 밖이다
                             · Full NAT 이 아니라 DNAT 만 걸려 있다 (응답이 L4 를 우회한다)

  "20회 연속 호출" 버튼은 어느 멤버가 몇 번 받았는지 세어 준다.
  한쪽으로만 몰리면 weight 또는 persistence(세션 고정)를 볼 것.

  ★ 이 페이지는 nginx 를 거치지 않는다(WAS:${APP_PORT} 직결). 그래서 ADMIN_ALLOW /
    basic 인증이 걸리지 않는다. 판정 근거는 /api/info 와 같은 값이므로 curl 로도 같다:
        curl -s http://${L4_VIP}:${L4_PORT}/api/info

  ★ 지금 UPSTREAM_MODE=${UPSTREAM_MODE} 다. WEB 이 실제로 VIP 로 보내려면
    두 WEB 에서 ./30-web.sh 를 다시 돌려야 한다. 이 스크립트만으로는 안 바뀐다.
-------------------------------------------------------------------------------
L4TEST

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

★ DB_MODE=sqlite 인 동안 / while DB_MODE=sqlite
  공유 DB 가 아니다. 두 WAS 가 각자 다른 파일을 본다.
  This is not a shared database - each WAS has its own file.
  /health/deep 의 200 은 DB 계층이 검증됐다는 뜻이 아니다.
  A 200 from /health/deep does NOT mean the DB tier was verified.

나중에 / Later
  ../deploy/deploy-canary.sh <version>   카나리 배포 / canary deploy
     설치 스크립트를 다시 돌리지 않는다. 코드와 버전만 갈아끼운다.
     Do not re-run this installer to deploy; that script swaps code only.
-------------------------------------------------------------------------------
NEXT
