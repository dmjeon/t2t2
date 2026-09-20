#!/usr/bin/env bash
# =============================================================================
# DB 계층 설치 — DB-MASTER / DB-BACKUP / DB-DR
#   ./10-db.sh          (config.env 의 AADC_ROLE 로 역할을 판단한다)
#
# ★ 14절 진행 순서에서 DB 계층(5번)을 WEB/L4/WAS(6번)보다 먼저 한다.
#   DB 자동 전환이 검증되지 않은 상태에서 위 계층을 얹으면
#   장애 원인 분리가 되지 않는다.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/config.env"

case "${AADC_ROLE}" in
  DB-MASTER|DB-BACKUP|DB-DR) ;;
  *) echo "AADC_ROLE=${AADC_ROLE} 는 DB 역할이 아니다."; exit 1;;
esac

echo "== 1. MariaDB 설치 =="
dnf -y install mariadb-server mariadb >/dev/null
install -d -m 0755 -o mysql -g mysql /var/log/mariadb

echo "== 2. 방화벽 =="
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=3306/tcp >/dev/null
  # VRRP (proto 112) — DC-500 내부 한정. DR 에는 필요 없다.
  if [ "${AADC_ROLE}" != "DB-DR" ]; then
    firewall-cmd --permanent --add-protocol=vrrp >/dev/null 2>&1 || \
      firewall-cmd --permanent --add-rich-rule='rule protocol value="112" accept' >/dev/null
  fi
  firewall-cmd --reload >/dev/null
fi

echo "== 3. 설정 + 초기화 =="
case "${AADC_ROLE}" in
  DB-MASTER) "${ROOT}/db/init-01-master.sh" ;;
  DB-BACKUP) "${ROOT}/db/init-02-backup.sh" ;;
  DB-DR)     "${ROOT}/db/init-03-dr.sh" ;;
esac

if [ "${AADC_ROLE}" = "DB-MASTER" ] || [ "${AADC_ROLE}" = "DB-BACKUP" ]; then
  echo "== 4. keepalived (DC-500 내부 VIP) =="
  dnf -y install keepalived >/dev/null

  install -m 0755 "${ROOT}/keepalived/bin/chk_db.sh"     /usr/local/bin/chk_db.sh
  install -m 0755 "${ROOT}/keepalived/bin/aadc-notify.sh" /usr/local/bin/aadc-notify.sh

  src="${ROOT}/keepalived/keepalived.conf.master"
  [ "${AADC_ROLE}" = "DB-BACKUP" ] && src="${ROOT}/keepalived/keepalived.conf.backup"
  sed -e "s/ens192/${VRRP_IFACE}/g" \
      -e "s/auth_pass CHANGE_ME/auth_pass ${VRRP_AUTH_PASS}/" \
      -e "s/virtual_router_id 51/virtual_router_id ${VRRP_ROUTER_ID}/" \
      "${src}" > /etc/keepalived/keepalived.conf
  chmod 0600 /etc/keepalived/keepalived.conf

  # chk_db.sh 가 볼 증인 게이트웨이.
  # /etc/sysconfig/keepalived 는 systemd EnvironmentFile 이므로 KEY=VALUE 만
  # 파싱된다. '. 파일' 같은 셸 문법은 조용히 무시되므로 직접 대입한다.
  sed -i '/^AADC_DB_GW=/d' /etc/sysconfig/keepalived 2>/dev/null || true
  printf 'AADC_DB_GW=%s\n' "${GW_DC_DB}" >> /etc/sysconfig/keepalived

  systemctl enable --now keepalived
  systemctl restart keepalived
  sleep 3
  ip -4 addr show "${VRRP_IFACE}" | grep -F "${DB_VIP}" && echo "   이 노드가 VIP 를 잡았다" \
                                                        || echo "   이 노드는 VIP 를 잡지 않았다 (정상일 수 있음)"

  echo "== 5. 복제 심장박동 =="
  # ★ SUPER 없는 전용 계정으로 돌린다. root 로 돌리면 read_only=ON 을 우회해
  #   DB-BACKUP 에도 쓰기가 남고 GTID 가 갈라진다 (스크립트 머리말 참조).
  id -u aadc-hb >/dev/null 2>&1 || useradd -r -s /sbin/nologin aadc-hb
  install -m 0755 "${ROOT}/monitoring/bin/aadc-repl-heartbeat.sh" /usr/local/bin/
  install -m 0644 "${ROOT}/monitoring/systemd/aadc-repl-heartbeat.service" /etc/systemd/system/
  cat > /etc/aadc/heartbeat.env <<HBENV
DB_HB_USER=${DB_HB_USER}
DB_HB_PASS=${DB_HB_PASS}
AADC_HEARTBEAT_INTERVAL=5
HBENV
  chmod 0640 /etc/aadc/heartbeat.env
  chown root:aadc-hb /etc/aadc/heartbeat.env
  systemctl daemon-reload
  systemctl enable --now aadc-repl-heartbeat
fi

cat <<'NEXT'

------------------------------------------------------------------------------
확인
  db/check-replication.sh          복제 + VIP + semi-sync 상태
  verify/04-db-c3-c7.sh status     쓰기 가능 노드가 정확히 1개인지

주의
  · read_only=ON 이 기본이다. VIP 를 잡은 노드만 notify_master 가 푼다.
  · VRRP 는 unicast 다. dc-db 가 확장 세그먼트라 multicast 면 DCI 를 타고
    DC-400 까지 흘러간다.
------------------------------------------------------------------------------
NEXT
