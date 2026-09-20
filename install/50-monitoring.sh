#!/usr/bin/env bash
# =============================================================================
# 모니터링 / 알람 — 나중에 따로 실행하는 단계
#   ./50-monitoring.sh <역할> [모드]
#     예)  ./50-monitoring.sh DB-MASTER
#          ./50-monitoring.sh MONITOR alarms
#
# 핵심 계층(10/20/30)이 다 붙고 나서 깐다. 이걸 안 깔아도 서비스는 돌아간다.
# 다만 **조용해진다** — 그게 이 설계의 가장 큰 위험이다.
#
#   AADC-POC.md 7-③절: "알람이 없으면 설계가 성립하지 않는다."
#   WAS 장애 시 GSLB 를 옮기지 않기로 한 대가가 이것이다. degraded 상태는
#   서비스가 되고 조금 느릴 뿐이라, 아무도 모르면 몇 주도 간다.
#
# 모드는 역할에서 자동으로 정해진다.
#   heartbeat    DB-MASTER / DB-BACKUP      복제 심장박동
#   alarms       MONITOR (점프·모니터링)     1분 점검 + 알람 5종 타이머
#   senderonly   WEB / WAS / DB-DR          알람 송출기만
# =============================================================================
set -euo pipefail
AADC_ROLE_ARG="${1:-}"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_bash

MODE="${2:-auto}"
if [ "${MODE}" = "auto" ]; then
  case "${AADC_ROLE}" in
    DB-MASTER|DB-BACKUP) MODE="heartbeat" ;;
    WEB-*|WAS-*|DB-DR)   MODE="senderonly" ;;
    *)                   MODE="alarms" ;;
  esac
fi

banner "모니터링 / 알람 (mode=${MODE})" "Monitoring and alarms (mode=${MODE})"

# ----- 공통: 알람 송출기 -----------------------------------------------------
# 어느 모드든 깐다. 이게 있어야 keepalived notify 가 로그가 아니라 알람을 낸다.
step "알람 송출기" "Alarm sender"
install -d -m 0755 /etc/aadc /opt/aadc /var/lib/aadc-monitor
install -m 0755 "${ROOT}/monitoring/bin/aadc-alarm-send.sh" /usr/local/bin/
install -m 0640 "${ROOT}/config.env" /opt/aadc/config.env
[ -f /etc/aadc/monitor.env ] || \
  install -m 0640 "${ROOT}/monitoring/monitor.env.example" /etc/aadc/monitor.env
kv "sender" "/usr/local/bin/aadc-alarm-send.sh"
kv "config" "/etc/aadc/monitor.env"

case "${MODE}" in

heartbeat)
  # --------------------------------------------------------------------------
  # 복제 심장박동 — DB-MASTER / DB-BACKUP
  #
  # Seconds_Behind_Master 는 쓰기가 없는 구간에서 0 으로 보인다. DCI 가 끊겨도
  # 그 순간 쓰기가 없으면 0 이다. 그래서 지연 알람이 침묵한다.
  # writer 만 UPDATE 에 성공하므로, 조건 분기 없이 현재 writer 가 알아서 찍는다.
  # --------------------------------------------------------------------------
  step "복제 심장박동" "Replication heartbeat"
  msg "쓰기가 없으면 Seconds_Behind_Master 는 0 으로 보인다. 그래서 박동을 따로 찍는다." \
      "Seconds_Behind_Master reads 0 when idle, so we write our own heartbeat."
  # ★ SUPER 없는 전용 계정으로 돌린다. root 로 돌리면 read_only=ON 을 우회해
  #   DB-BACKUP 에도 쓰기가 남고 GTID 가 갈라진다.
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
  sleep 3
  if systemctl is-active --quiet aadc-repl-heartbeat; then
    msg "기동됨. 실제 기록은 VIP 를 잡은 노드에서만 성공한다 (read_only 때문)." \
        "Running. Only the VIP holder actually writes (the rest are read_only)."
  else
    warn "기동 실패" "failed to start"
    journalctl -u aadc-repl-heartbeat -n 10 --no-pager | sed 's/^/   /'
  fi
  ;;

alarms)
  # --------------------------------------------------------------------------
  # 1분 주기 점검 + 알람 5종 — 모니터링 호스트 / 점프서버
  # --------------------------------------------------------------------------
  step "패키지" "Packages"
  dnf -y install curl jq bind-utils mariadb >/dev/null
  say "curl jq bind-utils mariadb"

  step "점검 / 알람 스크립트" "Probe and alarm scripts"
  install -m 0755 "${ROOT}/monitoring/bin/aadc-probe.sh" /usr/local/bin/
  install -m 0755 "${ROOT}/monitoring/bin/aadc-alarm.sh" /usr/local/bin/
  say "/usr/local/bin/aadc-probe.sh  /usr/local/bin/aadc-alarm.sh"

  step "타이머 (1분 주기)" "Timer (every minute)"
  install -m 0644 "${ROOT}/monitoring/systemd/aadc-monitor.service" /etc/systemd/system/
  install -m 0644 "${ROOT}/monitoring/systemd/aadc-monitor.timer"   /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now aadc-monitor.timer
  say "aadc-monitor.timer enabled"

  step "1회 실행" "One-shot run"
  AADC_CONF=/opt/aadc/config.env /usr/local/bin/aadc-probe.sh || true
  AADC_CONF=/opt/aadc/config.env /usr/local/bin/aadc-alarm.sh || true
  ;;

senderonly)
  step "완료" "Done"
  msg "송출기만 설치했다. 이 호스트에는 타이머도 심장박동도 두지 않는다." \
      "Sender only. No timer and no heartbeat on this host."
  ;;

*)
  die "알 수 없는 모드 '${MODE}'" "unknown mode '${MODE}' (auto|alarms|heartbeat|senderonly)" ;;
esac

cat <<'NEXT'

-------------------------------------------------------------------------------
알람 수신처를 설정할 것 / Set the alarm destination:  /etc/aadc/monitor.env
    ALARM_WEBHOOK_URL=...
    ALARM_MAIL_TO=...
  비워 두면 /var/log/aadc-alarm.log 와 syslog 에만 남는다.
  If empty, alarms only land in /var/log/aadc-alarm.log and syslog.

확인 / Check
  systemctl list-timers aadc-monitor.timer      (alarms mode)
  systemctl status aadc-repl-heartbeat          (heartbeat mode)
  tail -f /var/log/aadc-alarm.log

필수 알람 5종 / The five required alarms (AADC-POC.md 7-3)
  1) /health/local 실패             즉시     / immediate   <= 생명선 / lifeline
  2) L4 backup 멤버 active 지속      1시간마다 / hourly      <= 생명선 / lifeline
  3) semi-sync -> async 강등         즉시     / immediate
  4) 복제 지연 임계 초과             즉시     / immediate
  5) 점검 전용 VS 실패               즉시     / immediate

1) 과 2) 를 받는 사람이 정해져 있지 않으면 이 설계는 성립하지 않는다.
If nobody is on the receiving end of 1) and 2), the design does not hold.
-------------------------------------------------------------------------------
NEXT
