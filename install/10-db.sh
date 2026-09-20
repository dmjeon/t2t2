#!/usr/bin/env bash
# =============================================================================
# DB 계층 설치 — DB-MASTER / DB-BACKUP / DB-DR
#   ./10-db.sh DB-MASTER
#
# ★ 14절 진행 순서에서 DB 계층(5번)을 WEB/L4/WAS(6번)보다 먼저 한다.
#   DB 자동 전환이 검증되지 않은 상태에서 위 계층을 얹으면
#   장애 원인 분리가 되지 않는다.
# =============================================================================
set -euo pipefail
AADC_ROLE_ARG="${1:-}"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_bash
require_role 'DB-MASTER' 'DB-BACKUP' 'DB-DR'

banner "DB 계층 (MariaDB)" "DB tier (MariaDB)"

step "MariaDB 설치" "Install MariaDB"
dnf -y install mariadb-server mariadb >/dev/null
install -d -m 0755 -o mysql -g mysql /var/log/mariadb
say "mariadb-server mariadb"

step "방화벽" "Firewall"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=3306/tcp >/dev/null
  say "tcp/3306 opened"
  # VRRP (proto 112) — DC-500 내부 한정. DR 에는 필요 없다.
  if [ "${AADC_ROLE}" != "DB-DR" ]; then
    firewall-cmd --permanent --add-protocol=vrrp >/dev/null 2>&1 || \
      firewall-cmd --permanent --add-rich-rule='rule protocol value="112" accept' >/dev/null
    say "VRRP (ip proto 112) opened - DC-500 internal only"
  fi
  firewall-cmd --reload >/dev/null
else
  say "firewalld not running - skipped"
fi

step "설정 + 초기화" "Configure and initialise"
case "${AADC_ROLE}" in
  DB-MASTER) "${ROOT}/db/init-01-master.sh" ;;
  DB-BACKUP) "${ROOT}/db/init-02-backup.sh" ;;
  DB-DR)     "${ROOT}/db/init-03-dr.sh" ;;
esac

if [ "${AADC_ROLE}" = "DB-MASTER" ] || [ "${AADC_ROLE}" = "DB-BACKUP" ]; then
  step "keepalived (DC-500 내부 VIP)" "keepalived (VIP inside DC-500)"
  dnf -y install keepalived >/dev/null

  install -m 0755 "${ROOT}/keepalived/bin/chk_db.sh"      /usr/local/bin/chk_db.sh
  install -m 0755 "${ROOT}/keepalived/bin/aadc-notify.sh" /usr/local/bin/aadc-notify.sh

  src="${ROOT}/keepalived/keepalived.conf.master"
  [ "${AADC_ROLE}" = "DB-BACKUP" ] && src="${ROOT}/keepalived/keepalived.conf.backup"
  sed -e "s/ens192/${VRRP_IFACE}/g" \
      -e "s/auth_pass CHANGE_ME/auth_pass ${VRRP_AUTH_PASS}/" \
      -e "s/virtual_router_id 51/virtual_router_id ${VRRP_ROUTER_ID}/" \
      "${src}" > /etc/keepalived/keepalived.conf
  chmod 0600 /etc/keepalived/keepalived.conf
  kv "config" "$(basename "${src}") -> /etc/keepalived/keepalived.conf"

  # chk_db.sh 가 볼 증인 게이트웨이.
  # /etc/sysconfig/keepalived 는 systemd EnvironmentFile 이므로 KEY=VALUE 만
  # 파싱된다. '. 파일' 같은 셸 문법은 조용히 무시되므로 직접 대입한다.
  sed -i '/^AADC_DB_GW=/d' /etc/sysconfig/keepalived 2>/dev/null || true
  printf 'AADC_DB_GW=%s\n' "${GW_DC_DB}" >> /etc/sysconfig/keepalived
  kv "witness gateway" "${GW_DC_DB}"

  systemctl enable --now keepalived
  systemctl restart keepalived
  sleep 3
  if ip -4 addr show "${VRRP_IFACE}" | grep -qF "${DB_VIP}"; then
    msg "이 노드가 VIP ${DB_VIP} 를 잡았다." \
        "This node holds the VIP ${DB_VIP}."
  else
    msg "이 노드는 VIP 를 잡지 않았다. 정상일 수 있다 (상대 노드가 잡았다면)." \
        "This node does NOT hold the VIP - normal if the peer holds it."
  fi

  # 복제 심장박동과 알람은 여기서 깔지 않는다 → 50-monitoring.sh
  # keepalived 의 notify 스크립트는 알람 송출기가 없으면 로그로만 남긴다.
  # 즉 DB 계층은 모니터링 없이도 정상 동작한다. 다만 조용할 뿐이다.
fi

cat <<'NEXT'

-------------------------------------------------------------------------------
확인 / Check
  ../db/check-replication.sh        복제·VIP·semi-sync / replication, VIP, semi-sync
  ../verify/04-db-c3-c7.sh status   쓰기 가능 노드가 1개인지 / exactly one writable node

주의 / Notes
  · read_only=ON 이 기본이다. VIP 를 잡은 노드만 notify_master 가 푼다.
    read_only=ON everywhere; only the VIP holder has it cleared by notify_master.
  · VRRP 는 unicast 다. dc-db 가 확장 세그먼트라 multicast 면 광고가 DCI 를
    타고 DC-400 까지 흘러간다.
    VRRP is unicast: dc-db is a stretched segment, so multicast would leak
    the advertisements across the DCI into DC-400.

나중에 / Later (지금 안 해도 DB 는 정상 동작한다 / the DB works without this)
  ./50-monitoring.sh <role>
      복제 심장박동 + semi-sync 강등 알람 + DR 지연 알람
      replication heartbeat, semi-sync demotion alarm, DR lag alarm
      ★ 이걸 안 깔면 RPO 가 깨져도 조용하다. 오래 미루지 말 것.
      ★ Without it, a broken RPO is silent. Do not put this off.
  ../dr/
      DR 전환 2단 게이트. 설치 불필요, 번들에서 바로 실행.
      DR switchover, two-stage gate. No install needed.
-------------------------------------------------------------------------------
NEXT
