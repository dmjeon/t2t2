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
kv "local L4 VIP"  "${L4_VIP}"
kv "local WAS"     "${WAS_LOCAL}   (/health/local direct target)"
kv "check VS"      "${CHECK_VS}"
kv "peer WEB"      "${PEER_WEB}"
kv "server_name"              "${SERVICE_FQDN} ${WEB_FQDN}"

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

sed -e "s/__L4_VIP__/${L4_VIP}/g" \
    -e "s/__WAS_LOCAL_IP__/${WAS_LOCAL}/g" \
    -e "s/__CHECK_VS_VIP__/${CHECK_VS}/g" \
    -e "s/__PEER_WEB_IP__/${PEER_WEB}/g" \
    "${ROOT}/nginx/conf.d/10-upstream.conf.template" > /etc/nginx/conf.d/10-upstream.conf

sed -e "s/__SERVICE_FQDN__/${SERVICE_FQDN}/g" \
    -e "s/__WEB_FQDN__/${WEB_FQDN}/g" \
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
msg "검증 화면은 DB writer 신원과 semi-sync 상태를 노출한다. 관리 대역만 허용." \
    "The verification page exposes DB writer identity and semi-sync state."

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
msg "127.0.0.1 은 ADMIN_ALLOW/HEALTH_ALLOW 안에 있다. 403 이 나오면 ACL 이 틀린 것." \
    "127.0.0.1 is inside both allow lists - a 403 here means the ACLs are wrong."

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
