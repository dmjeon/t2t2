#!/usr/bin/env bash
# =============================================================================
# 모니터링 / 알람 — 나중에 따로 실행하는 단계
#   ./50-monitoring.sh [auto|alarms|heartbeat|senderonly]
#
# 핵심 계층(10/20/30)이 다 붙고 나서 깐다. 이걸 안 깔아도 서비스는 돌아간다.
# 다만 **조용해진다** — 그게 이 설계의 가장 큰 위험이다.
#
#   AADC-POC.md 7-③절: "알람이 없으면 설계가 성립하지 않는다."
#   WAS 장애 시 GSLB 를 옮기지 않기로 한 대가가 이것이다. degraded 상태는
#   서비스가 되고 조금 느릴 뿐이라, 아무도 모르면 몇 주도 간다.
#   자동 전환을 포기한 만큼 탐지를 강하게 만든다.
#
# 역할별로 설치물이 다르다 (인자 없으면 AADC_ROLE 로 자동 판별).
#
#   heartbeat    DB-MASTER / DB-BACKUP
#                복제 심장박동. writer 에서만 박동이 찍힌다.
#   alarms       모니터링 호스트 / 점프서버
#                1분 주기 점검 + 알람 5종 타이머.
#   senderonly   그 외 전 서버 (WEB / WAS / DB-DR)
#                알람 송출기만. keepalived notify 등이 호출한다.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/config.env"

MODE="${1:-auto}"
if [ "${MODE}" = "auto" ]; then
  case "${AADC_ROLE}" in
    DB-MASTER|DB-BACKUP)      MODE="heartbeat" ;;
    WEB-*|WAS-*|DB-DR)        MODE="senderonly" ;;
    *)                        MODE="alarms" ;;   # MONITOR, 점프서버 등
  esac
fi
echo "== 모드: ${MODE}  (역할 ${AADC_ROLE} / ${AADC_DC}) =="

# ----- 공통: 알람 송출기 -----------------------------------------------------
# 어느 모드든 깐다. 이게 있어야 keepalived notify 가 로그가 아니라 알람을 낸다.
echo "== 알람 송출기 =="
install -d -m 0755 /etc/aadc /opt/aadc /var/lib/aadc-monitor
install -m 0755 "${ROOT}/monitoring/bin/aadc-alarm-send.sh" /usr/local/bin/
install -m 0640 "${ROOT}/config.env" /opt/aadc/config.env
[ -f /etc/aadc/monitor.env ] || \
  install -m 0640 "${ROOT}/monitoring/monitor.env.example" /etc/aadc/monitor.env
echo "   /usr/local/bin/aadc-alarm-send.sh"

case "${MODE}" in

heartbeat)
  # --------------------------------------------------------------------------
  # 복제 심장박동 — DB-MASTER / DB-BACKUP
  #
  # Seconds_Behind_Master 는 쓰기가 없는 구간에서 0 으로 보인다. DCI 가 끊겨도
  # 그 순간 쓰기가 없으면 0 이다. 그래서 지연 알람이 침묵한다.
  # writer 만 UPDATE 에 성공하므로, 조건 분기 없이 현재 writer 가 알아서 찍는다.
  # --------------------------------------------------------------------------
  echo "== 복제 심장박동 =="
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
  systemctl is-active --quiet aadc-repl-heartbeat \
    && echo "   기동됨. VIP 를 잡은 노드에서만 실제로 기록된다." \
    || { echo "   ★ 기동 실패:"; journalctl -u aadc-repl-heartbeat -n 10 --no-pager; }
  ;;

alarms)
  # --------------------------------------------------------------------------
  # 1분 주기 점검 + 알람 5종 — 모니터링 호스트 / 점프서버
  # --------------------------------------------------------------------------
  echo "== 패키지 =="
  dnf -y install curl jq bind-utils mariadb >/dev/null

  echo "== 점검 / 알람 스크립트 =="
  install -m 0755 "${ROOT}/monitoring/bin/aadc-probe.sh" /usr/local/bin/
  install -m 0755 "${ROOT}/monitoring/bin/aadc-alarm.sh" /usr/local/bin/

  echo "== 타이머 (1분 주기) =="
  install -m 0644 "${ROOT}/monitoring/systemd/aadc-monitor.service" /etc/systemd/system/
  install -m 0644 "${ROOT}/monitoring/systemd/aadc-monitor.timer"   /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now aadc-monitor.timer

  echo "== 1회 실행 =="
  AADC_CONF=/opt/aadc/config.env /usr/local/bin/aadc-probe.sh || true
  AADC_CONF=/opt/aadc/config.env /usr/local/bin/aadc-alarm.sh || true
  ;;

senderonly)
  echo "   송출기만 설치했다. 이 호스트에는 타이머도 심장박동도 두지 않는다."
  ;;

*)
  echo "사용: $0 [auto|alarms|heartbeat|senderonly]"; exit 2 ;;
esac

cat <<'NEXT'

------------------------------------------------------------------------------
알람 수신처를 설정할 것:  /etc/aadc/monitor.env
  ALARM_WEBHOOK_URL=...
  ALARM_MAIL_TO=...
비워 두면 /var/log/aadc-alarm.log 와 syslog 에만 남는다.

확인
  systemctl list-timers aadc-monitor.timer      (alarms 모드)
  systemctl status aadc-repl-heartbeat          (heartbeat 모드)
  tail -f /var/log/aadc-alarm.log

필수 알람 5종 (7-③절)
  ① /health/local 실패             [즉시]      ← 생명선
  ② L4 backup 멤버 active 지속      [1시간마다]  ← 생명선
  ③ semi-sync → async 강등          [즉시]
  ④ 복제 지연 임계 초과             [즉시]
  ⑤ 점검 전용 VS 실패               [즉시]

①② 를 받는 사람이 정해져 있지 않으면 이 설계는 성립하지 않는다.
------------------------------------------------------------------------------
NEXT
