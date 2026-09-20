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

step "nginx 설치" "Install nginx"
dnf -y install nginx >/dev/null

step "설정 배치" "Configuration"
cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
install -m 0644 "${ROOT}/nginx/nginx.conf"               /etc/nginx/nginx.conf
install -m 0644 "${ROOT}/nginx/conf.d/00-realip.conf"    /etc/nginx/conf.d/
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

sed -e "s/__SERVICE_FQDN__/${SERVICE_FQDN}/g" \
    -e "s/__WEB_FQDN__/${WEB_FQDN}/g" \
    -e "s/__UPSTREAM_MODE__/${UPSTREAM_MODE}/g" \
    -e "s#__UPSTREAM_TARGET__#${UPSTREAM_TARGET}#g" \
    "${ROOT}/nginx/conf.d/20-aadc-web.conf.template" > /etc/nginx/conf.d/20-aadc-web.conf

# set_real_ip_from 을 config.env 의 FortiADC 주소로 맞춘다.
sed -i -e "s/^set_real_ip_from  10\.3\.10\.241;/set_real_ip_from  ${DMZ_ADC_DC500};/" \
       -e "s/^set_real_ip_from  10\.7\.10\.241;/set_real_ip_from  ${DMZ_ADC_DC400};/" \
       /etc/nginx/conf.d/00-realip.conf
say "10-upstream.conf  20-aadc-web.conf  00-realip.conf"

step "접근 제어" "Access control"
# 검증 화면은 DB writer 신원과 semi-sync 상태를 그대로 보여 준다.
# WEB 은 인터넷에 노출되므로 관리 대역으로 한정한다.
gen_acl() {                       # gen_acl "<CIDR 목록>" <원본> <설치경로> <치환자>
  local cidrs="$1" src="$2" dst="$3" marker="$4" cidr
  : > "${dst}"
  while IFS= read -r line; do
    if [ "${line}" = "${marker}" ]; then
      for cidr in ${cidrs}; do echo "allow ${cidr};" >> "${dst}"; done
    else
      echo "${line}" >> "${dst}"
    fi
  done < "${src}"
  chmod 0644 "${dst}"
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

step "기동" "Start"
nginx -t
systemctl enable --now nginx
systemctl reload nginx
say "nginx running"

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
