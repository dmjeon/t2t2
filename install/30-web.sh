#!/usr/bin/env bash
# =============================================================================
# WEB 계층 설치 — WEB-DC1 (DC-500) / WEB-DC2 (DC-400)
#   nginx + 검증 화면
#   ./30-web.sh
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/config.env"

case "${AADC_ROLE}" in WEB-*) ;; *) echo "AADC_ROLE=${AADC_ROLE} 는 WEB 역할이 아니다."; exit 1;; esac

# 이 DC 기준의 로컬/교차 값 결정
if [ "${AADC_DC}" = "DC-500" ]; then
  L4_VIP="${DC500_L4_VIP}";  CHECK_VS="${DC500_CHECK_VS_VIP}"
  WAS_LOCAL="${WAS_DC500_IP}"; PEER_WEB="${WEB_DC2_IP}"; WEB_FQDN="${WEB1_FQDN}"
else
  L4_VIP="${DC400_L4_VIP}";  CHECK_VS="${DC400_CHECK_VS_VIP}"
  WAS_LOCAL="${WAS_DC400_IP}"; PEER_WEB="${WEB_DC1_IP}"; WEB_FQDN="${WEB2_FQDN}"
fi
echo "== ${AADC_ROLE} (${AADC_DC}) =="
echo "   로컬 L4 VIP : ${L4_VIP}"
echo "   로컬 WAS    : ${WAS_LOCAL}   (/health/local 직접 호출용)"
echo "   점검 VS     : ${CHECK_VS}"
echo "   반대편 WEB  : ${PEER_WEB}"

echo "== 1. nginx =="
dnf -y install nginx >/dev/null

echo "== 2. 설정 =="
cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
install -m 0644 "${ROOT}/nginx/nginx.conf"           /etc/nginx/nginx.conf
install -m 0644 "${ROOT}/nginx/conf.d/00-realip.conf" /etc/nginx/conf.d/
install -m 0644 "${ROOT}/nginx/conf.d/proxy-headers.inc" /etc/nginx/conf.d/

# Rocky 기본 제공 예제 서버 블록과 충돌하므로 치운다.
[ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled

sed -e "s/__L4_VIP__/${L4_VIP}/g" \
    -e "s/__WAS_LOCAL_IP__/${WAS_LOCAL}/g" \
    -e "s/__CHECK_VS_VIP__/${CHECK_VS}/g" \
    -e "s/__PEER_WEB_IP__/${PEER_WEB}/g" \
    "${ROOT}/nginx/conf.d/10-upstream.conf.template" > /etc/nginx/conf.d/10-upstream.conf

sed -e "s/__SERVICE_FQDN__/${SERVICE_FQDN}/g" \
    -e "s/__WEB_FQDN__/${WEB_FQDN}/g" \
    "${ROOT}/nginx/conf.d/20-aadc-web.conf.template" > /etc/nginx/conf.d/20-aadc-web.conf

# 접근 제어 — config.env 의 ADMIN_ALLOW / HEALTH_ALLOW 로 allow 줄을 만든다.
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
echo "   ADMIN_ALLOW : ${ADMIN_ALLOW}"
echo "   HEALTH_ALLOW: ${HEALTH_ALLOW}"

# set_real_ip_from 을 config.env 의 FortiADC 주소로 맞춘다.
sed -i -e "s/^set_real_ip_from  10\.3\.10\.241;/set_real_ip_from  ${DMZ_ADC_DC500};/" \
       -e "s/^set_real_ip_from  10\.7\.10\.241;/set_real_ip_from  ${DMZ_ADC_DC400};/" \
       /etc/nginx/conf.d/00-realip.conf

echo "== 3. 검증 화면 =="
install -d -m 0755 /usr/share/nginx/html/aadc
rsync -a --delete --exclude README.md "${ROOT}/web/" /usr/share/nginx/html/aadc/
restorecon -R /usr/share/nginx/html/aadc 2>/dev/null || true

echo "== 4. SELinux =="
# 이것을 빼먹으면 nginx 가 업스트림으로 나가지 못해 전부 502 가 된다.
# "설정은 맞는데 502" 의 대부분이 이 한 줄이다.
if [ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]; then
  setsebool -P httpd_can_network_connect 1
  echo "   httpd_can_network_connect=on"
fi

echo "== 5. 방화벽 =="
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http  >/dev/null
  firewall-cmd --permanent --add-service=https >/dev/null
  firewall-cmd --reload >/dev/null
fi

echo "== 6. 기동 =="
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "== 7. 확인 =="
curl -sf http://127.0.0.1/health/web; echo
for p in /api/info /health/deep /health/local /api/db/status /; do
  code=$(curl -so /dev/null -w '%{http_code}' -m 6 "http://127.0.0.1${p}")
  printf '   %-16s %s\n' "${p}" "${code}"
done
echo "   (127.0.0.1 은 ADMIN_ALLOW / HEALTH_ALLOW 에 들어 있어 전부 403 이 아니어야 한다)"
echo
echo "   ★ GSLB 에서 /health/deep 이 200 인지 반드시 확인할 것."
echo "     403 이면 GSLB 가 이 DC 를 빼 버린다 — HEALTH_ALLOW 에 DMZ FortiADC 주소가 있는가:"
echo "       ${HEALTH_ALLOW}"

cat <<NEXT

------------------------------------------------------------------------------
검증 화면:  http://${WEB_FQDN}/    (또는 http://$(hostname -I | awk '{print $1}')/ )

전부 502 라면 순서대로 확인
  1. 내부 L4 FortiADC 가 기동했는가 (현재 전원 꺼짐 상태 — Viettel 처리 중)
  2. L4 VIP 주소가 맞는가 (config.env 의 <<TBD>> 를 채웠는가)
  3. SELinux httpd_can_network_connect (위 4번에서 처리)
  4. L4 가 Full NAT(SNAT) 인가 — DNAT 만이면 응답이 L4 를 우회해 끊긴다
------------------------------------------------------------------------------
NEXT
