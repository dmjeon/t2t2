#!/usr/bin/env bash
# =============================================================================
# WEB 계층 설치 — WEB-DC1 (DC-500) / WEB-DC2 (DC-400)
#   nginx + 검증 화면
#   ./30-web.sh WEB-DC1
# =============================================================================
set -euo pipefail
AADC_ROLE_ARG="${1:-}"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_bash
require_role 'WEB-*'
resolve_dc_vars

banner "WEB 계층 (nginx)" "WEB tier (nginx)"

# ----- 업스트림 모드 ---------------------------------------------------------
case "${UPSTREAM_MODE:-l4}" in
  l4)
    UPSTREAM_TARGET="${L4_VIP}:${L4_PORT}"
    CHECK_TARGET="${CHECK_VS}:${L4_PORT}"
    ;;
  direct)
    # L4 를 건너뛴다. 교차 점검은 반대편 WAS 를 직접 때려 peer-routing 도달성만
    # 확인한다 — L4 backup 동작은 이 모드에서 검증할 수 없다.
    UPSTREAM_TARGET="${WAS_LOCAL}:${APP_PORT}"
    if [ "${AADC_DC}" = "DC-500" ]; then
      CHECK_TARGET="${WAS_DC400_IP}:${APP_PORT}"
    else
      CHECK_TARGET="${WAS_DC500_IP}:${APP_PORT}"
    fi
    ;;
  *) die "UPSTREAM_MODE 는 l4 또는 direct" "UPSTREAM_MODE must be l4 or direct (got '${UPSTREAM_MODE}')" ;;
esac

kv "upstream mode" "${UPSTREAM_MODE}"
kv "upstream target" "${UPSTREAM_TARGET}"
kv "local L4 VIP"  "${L4_VIP}   $( [ "${UPSTREAM_MODE}" = direct ] && echo '(BYPASSED)' )"
kv "local WAS"     "${WAS_LOCAL}   (/health/local direct target)"
kv "check target"  "${CHECK_TARGET}"
kv "peer WEB"      "${PEER_WEB}"
kv "server_name"   "${SERVICE_FQDN} ${WEB_FQDN}"

if [ "${UPSTREAM_MODE}" = "direct" ]; then
  echo
  msg "★ L4 우회 모드다. 본설계가 아니다." \
      "   L4 IS BYPASSED. This is not the real design."
  msg "  이 모드에서 검증되지 않는 것: C12(SNAT) C15(backup 흡수) C18(L4 장애)" \
      "  Not verified in this mode: C12 (SNAT), C15 (backup), C18 (L4 failure)"
  msg "  WAS 1대가 죽으면 흡수 주체가 없다 — 그게 곧 DC 장애가 된다." \
      "  With one WAS down nothing absorbs it; that becomes a DC outage."
fi

# 원본의 치환자 한 줄을 "<지시자> <값>;" 여러 줄로 펼쳐서 설치한다.
# set_real_ip_from 과 allow 가 같은 모양이라 하나로 쓴다.
gen_lines() {                     # gen_lines <지시자> "<값 목록>" <원본> <설치경로> <치환자>
  local directive="$1" items="$2" src="$3" dst="$4" marker="$5" item
  : > "${dst}"
  while IFS= read -r line; do
    if [ "${line}" = "${marker}" ]; then
      for item in ${items}; do echo "${directive} ${item};" >> "${dst}"; done
    else
      echo "${line}" >> "${dst}"
    fi
  done < "${src}"
  chmod 0644 "${dst}"
}

step "nginx 설치" "Install nginx"
# 이미 깔려 있으면 dnf 를 부르지 않는다. PoC 환경은 패키지 저장소 경로가
# 막혀 있어(FW-06/07/15/16) dnf 가 메타데이터를 못 받고 죽는다. set -e 라
# 그 한 줄 때문에 설정 반영 전체가 중단된다 — 재실행이 잦은 스크립트라
# 이 가드가 없으면 아무것도 고칠 수 없다.
ensure_pkg nginx

step "설정 배치" "Configuration"
cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
install -m 0644 "${ROOT}/nginx/nginx.conf"               /etc/nginx/nginx.conf
install -m 0644 "${ROOT}/nginx/conf.d/proxy-headers.inc" /etc/nginx/conf.d/

# Rocky 기본 제공 예제 서버 블록과 충돌하므로 치운다.
if [ -f /etc/nginx/conf.d/default.conf ]; then
  mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
  msg "Rocky 기본 default.conf 를 치웠다 (server_name 충돌)." \
      "Moved the stock default.conf aside (server_name clash)."
fi

sed -e "s/__UPSTREAM_TARGET__/${UPSTREAM_TARGET}/g" \
    -e "s/__CHECK_TARGET__/${CHECK_TARGET}/g" \
    -e "s/__UPSTREAM_MODE__/${UPSTREAM_MODE}/g" \
    -e "s/__WAS_LOCAL_IP__/${WAS_LOCAL}/g" \
    -e "s/__PEER_WEB_IP__/${PEER_WEB}/g" \
    "${ROOT}/nginx/conf.d/10-upstream.conf.template" > /etc/nginx/conf.d/10-upstream.conf

# /health/deep 강제 200 (DEEP_FORCE_OK). 기본은 꺼짐 = 주석 한 줄만 들어간다.
if [ "${DEEP_FORCE_OK:-no}" = "yes" ]; then
  DEEP_FORCE_LINE="default_type application/json; return 200 '{\"check\":\"deep\",\"status\":\"ok\",\"forced\":true,\"note\":\"TEMPORARY - DB NOT verified\"}';"
else
  DEEP_FORCE_LINE="# DEEP_FORCE_OK=no - 앱의 /health/deep 을 그대로 프록시한다 (정상)"
fi
# 치환 구분자는 '|' 다. yes 값에는 '/'(application/json) 가, no 값에는 '#' 이
# 들어 있어서 둘 다 구분자로 쓸 수 없다.

sed -e "s/__SERVICE_FQDN__/${SERVICE_FQDN}/g" \
    -e "s/__WEB_FQDN__/${WEB_FQDN}/g" \
    -e "s/__UPSTREAM_MODE__/${UPSTREAM_MODE}/g" \
    -e "s#__UPSTREAM_TARGET__#${UPSTREAM_TARGET}#g" \
    -e "s|__DEEP_FORCE_OK__|${DEEP_FORCE_LINE}|g" \
    "${ROOT}/nginx/conf.d/20-aadc-web.conf.template" > /etc/nginx/conf.d/20-aadc-web.conf

if [ "${DEEP_FORCE_OK:-no}" = "yes" ]; then
  warn "★ /health/deep 을 강제 200 으로 고정했다. GSLB 는 이 DC 를 늘 정상으로 본다." \
       "/health/deep is FORCED to 200. The GSLB will never see this DC as unhealthy."
  msg  "  failover·DB 관련 시나리오는 이 상태에서 전부 무의미하다. 끝나면 config.env 에서 no." \
       "  All failover/DB scenarios are meaningless while this is on. Set it back to no."
fi

# set_real_ip_from — config.env 의 FortiADC 주소 목록으로 생성한다.
# 장비 한 대가 주소를 여러 개 쓰므로 단일 주소가 아니라 목록/대역이다.
gen_lines "set_real_ip_from" "${DMZ_ADC_DC500} ${DMZ_ADC_DC400}" \
          "${ROOT}/nginx/conf.d/00-realip.conf" \
          /etc/nginx/conf.d/00-realip.conf "__REALIP_LINES__"
say "10-upstream.conf  20-aadc-web.conf  00-realip.conf"

step "접근 제어" "Access control"
# 검증 화면은 DB writer 신원과 semi-sync 상태를 그대로 보여 준다.
# WEB 은 인터넷에 노출되므로 관리 대역으로 한정한다.
gen_acl() {                       # gen_acl "<CIDR 목록>" <원본> <설치경로> <치환자>
  gen_lines "allow" "$1" "$2" "$3" "$4"
}
gen_acl "${ADMIN_ALLOW}"  "${ROOT}/nginx/conf.d/acl-admin.inc" \
        /etc/nginx/conf.d/acl-admin.inc  "__ADMIN_ALLOW_LINES__"
gen_acl "${HEALTH_ALLOW}" "${ROOT}/nginx/conf.d/acl-health.inc" \
        /etc/nginx/conf.d/acl-health.inc "__HEALTH_ALLOW_LINES__"
kv "ADMIN_ALLOW"  "${ADMIN_ALLOW}"
kv "HEALTH_ALLOW" "${HEALTH_ALLOW}"

# basic 인증 — IP 목록과 OR 조건(satisfy any).
# 앞단이 SNAT 를 하면 nginx 는 고객 IP 를 못 보므로 IP 만으로는 들어올 수 없다.
#
# ADMIN_AUTH=off 여도 .htpasswd 는 그대로 만든다. 되돌릴 때 이 파일이 없어서
# nginx 가 기동을 거부하는 상황을 막기 위해서다. 켜고 끄는 것은 include 한 줄이다.
printf '%s:%s\n' "${ADMIN_USER}" "$(openssl passwd -apr1 "${ADMIN_PASS}")" \
  > /etc/nginx/.htpasswd
chmod 0640 /etc/nginx/.htpasswd
chown root:nginx /etc/nginx/.htpasswd

if [ "${ADMIN_AUTH:-on}" = "on" ]; then
  kv "basic auth" "on   (${ADMIN_USER} / /etc/nginx/.htpasswd)"
  msg "IP 가 안 맞아도 이 계정으로 들어올 수 있다 (satisfy any)." \
      "If the source IP does not match, this account still gets you in."
else
  # auth_basic 두 줄만 주석 처리한다. satisfy any / allow / deny 는 그대로 둔다.
  sed -i 's|^auth_basic|#auth_basic|' /etc/nginx/conf.d/acl-admin.inc
  kv "basic auth" "off  (ADMIN_AUTH=off — 암호창 없음)"
  warn "진입 조건이 ADMIN_ALLOW IP 목록 하나만 남았다. 앞단 SNAT 로 주소가 안 맞으면 403 이다." \
       "Only the ADMIN_ALLOW IP list is left. If the front end SNATs, you get 403, not a prompt."
  msg  "지금 나가는 주소는 /health/web 의 client 값이다 (ACL 없음). 되돌리려면 ADMIN_AUTH=on." \
       "Check the client field of /health/web. Set ADMIN_AUTH=on to re-enable."
fi

step "검증 화면" "Verification page"
install -d -m 0755 /usr/share/nginx/html/aadc
rsync -a --delete --exclude README.md "${ROOT}/web/" /usr/share/nginx/html/aadc/
restorecon -R /usr/share/nginx/html/aadc 2>/dev/null || true
say "/usr/share/nginx/html/aadc"

step "SELinux" "SELinux"
# 이것을 빼먹으면 nginx 가 업스트림으로 나가지 못해 전부 502 가 된다.
# "설정은 맞는데 502" 의 대부분이 이 한 줄이다.
if [ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]; then
  setsebool -P httpd_can_network_connect 1
  kv "httpd_can_network_connect" "on"
  msg "이게 없으면 nginx 가 업스트림에 못 나가 전부 502 가 된다." \
      "Without this nginx cannot reach upstreams and everything returns 502."
else
  say "disabled - nothing to do"
fi

step "방화벽" "Firewall"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http  >/dev/null
  firewall-cmd --permanent --add-service=https >/dev/null
  firewall-cmd --reload >/dev/null
  say "http, https opened"
else
  say "firewalld not running - skipped"
fi

step "파일 디스크립터 한도" "File descriptor limit"
# nginx.conf 의 worker_rlimit_nofile 은 systemd 가 준 **하드 리밋**을 넘지
# 못한다. 넘으려 하면 setrlimit 이 조용히 실패하고 1024 에 묶인 채로 돈다.
# 그래서 서비스 단위에서 같이 올린다.
NEED_RESTART="no"
install -d -m 0755 /etc/systemd/system/nginx.service.d
LIMITS=/etc/systemd/system/nginx.service.d/limits.conf
NEW_LIMITS="$(printf '[Service]\nLimitNOFILE=32768\n')"
if [ "$(cat "${LIMITS}" 2>/dev/null)" != "${NEW_LIMITS}" ]; then
  printf '%s\n' "${NEW_LIMITS}" > "${LIMITS}"
  chmod 0644 "${LIMITS}"
  systemctl daemon-reload
  NEED_RESTART="yes"          # LimitNOFILE 은 reload 로는 안 바뀐다
  kv "LimitNOFILE" "32768 (신규/변경 - 재시작 필요)"
else
  kv "LimitNOFILE" "32768 (변경 없음)"
fi

step "기동" "Start"
nginx -t
systemctl enable --now nginx
if [ "${NEED_RESTART}" = "yes" ]; then
  systemctl restart nginx
  say "nginx restarted (파일 디스크립터 한도 반영 / fd limit applied)"
else
  systemctl reload nginx
  say "nginx reloaded"
fi

# 실제로 올라갔는지 확인한다. 설정만 넣고 안 올라간 경우를 잡는다.
NGX_PID="$(cat /run/nginx.pid 2>/dev/null || true)"
if [ -n "${NGX_PID}" ] && [ -r "/proc/${NGX_PID}/limits" ]; then
  kv "실제 적용값 / effective" \
     "$(awk '/Max open files/{print $4" (soft) / "$5" (hard)"}' "/proc/${NGX_PID}/limits")"
fi
if grep -q "worker_connections exceed open file resource limit" \
     /var/log/nginx/error.log 2>/dev/null; then
  warn "error.log 에 fd 한도 경고가 남아 있다 (과거 기록일 수 있다)." \
       "The fd-limit warning is present in error.log (may be an older entry)."
  say  "재시작 이후 시각의 경고인지 확인할 것 / check the timestamp"
fi

step "확인" "Check"
curl -sf http://127.0.0.1/health/web | sed 's/^/   /' || warn "/health/web 실패" "/health/web failed"
echo
for p in /api/info /health/deep /health/local /api/db/status /; do
  code=$(curl -so /dev/null -w '%{http_code}' -m 6 "http://127.0.0.1${p}")
  printf '   %-20s %s\n' "${p}" "${code}"
done
msg "127.0.0.1 은 ADMIN_ALLOW/HEALTH_ALLOW 안에 있다. 403 이면 ACL 이 틀린 것." \
    "127.0.0.1 is inside both allow lists - a 403 here means the ACLs are wrong."
say ""
msg "밖에서 403 이 나오면 앞단 SNAT 때문이다. nginx 가 본 주소를 확인할 것:" \
    "A 403 from outside means front-end SNAT. Check what nginx actually saw:"
say "curl -s http://<이 서버의 공인 IP>/health/web"
say "  raw=앞단 장비 주소 + xff 비어 있음  ->  IP ACL 로는 통과 불가"
say "  그 경우 basic 인증으로 들어간다 / then use basic auth:"
if [ "${ADMIN_AUTH:-on}" = "on" ]; then
  say "  curl -u ${ADMIN_USER} http://<공인 IP>/"
else
  say "  curl http://<공인 IP>/        # ADMIN_AUTH=off — 암호 없음"
fi

IP4="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<NEXT

-------------------------------------------------------------------------------
검증 화면 / Verification page
  http://${WEB_FQDN}/        (or http://${IP4}/ )

★ 반드시 확인 / MUST CHECK
  GSLB 가 보는 /health/deep 이 200 이어야 한다. 403 이면 GSLB 가 이 DC 를 뺀다.
  /health/deep must return 200 *as seen by the GSLB*, or it drops this DC.
  HEALTH_ALLOW 에 DMZ FortiADC 주소가 들어 있는가 / must contain the DMZ FortiADC:
      ${HEALTH_ALLOW}

전부 502 라면 순서대로 / If everything returns 502, check in order
  1. 내부 L4 FortiADC 가 기동했는가 / is the internal L4 FortiADC powered on?
  2. L4 VIP 가 맞는가 / is the L4 VIP correct?   ${L4_VIP}
  3. SELinux httpd_can_network_connect          (위에서 처리 / handled above)
  4. L4 가 Full NAT(SNAT) 인가 / is the L4 doing Full NAT?
     DNAT 만이면 응답이 L4 를 우회해 역변환되지 않고 연결이 끊긴다.
     With DNAT only the reply bypasses the L4 and the connection dies.
-------------------------------------------------------------------------------
NEXT
