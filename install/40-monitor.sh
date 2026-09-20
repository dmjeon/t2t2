#!/usr/bin/env bash
# =============================================================================
# 모니터링/알람 설치 — 점프서버 또는 별도 모니터링 호스트
#   ./40-monitor.sh
#
# AADC-POC.md 7-③절: "알람이 없으면 설계가 성립하지 않는다."
# WAS 장애 시 GSLB 를 옮기지 않기로 한 대가가 이것이다.
# 자동 전환을 포기한 만큼 탐지를 강하게 만든다.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/config.env"

echo "== 1. 패키지 =="
dnf -y install curl jq bind-utils mariadb >/dev/null

echo "== 2. 스크립트 =="
install -d -m 0755 /var/lib/aadc-monitor /etc/aadc /opt/aadc
install -m 0755 "${ROOT}/monitoring/bin/aadc-alarm-send.sh" /usr/local/bin/
install -m 0755 "${ROOT}/monitoring/bin/aadc-probe.sh"      /usr/local/bin/
install -m 0755 "${ROOT}/monitoring/bin/aadc-alarm.sh"      /usr/local/bin/
install -m 0640 "${ROOT}/config.env" /opt/aadc/config.env
[ -f /etc/aadc/monitor.env ] || \
  install -m 0640 "${ROOT}/monitoring/monitor.env.example" /etc/aadc/monitor.env

echo "== 3. 타이머 (1분 주기) =="
install -m 0644 "${ROOT}/monitoring/systemd/aadc-monitor.service" /etc/systemd/system/
install -m 0644 "${ROOT}/monitoring/systemd/aadc-monitor.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now aadc-monitor.timer

echo "== 4. 1회 실행 =="
AADC_CONF=/opt/aadc/config.env /usr/local/bin/aadc-probe.sh || true
AADC_CONF=/opt/aadc/config.env /usr/local/bin/aadc-alarm.sh || true

cat <<'NEXT'

------------------------------------------------------------------------------
알람 수신처를 반드시 설정할 것:  /etc/aadc/monitor.env
  ALARM_WEBHOOK_URL=...
  ALARM_MAIL_TO=...
비워 두면 /var/log/aadc-alarm.log 와 syslog 에만 남는다.

동작 확인
  systemctl list-timers aadc-monitor.timer
  journalctl -u aadc-monitor -f
  tail -f /var/log/aadc-alarm.log

필수 알람 5종 (7-③절)
  ① /health/local 실패             [즉시]     ← 생명선
  ② L4 backup 멤버 active 지속      [1시간마다] ← 생명선
  ③ semi-sync → async 강등          [즉시]
  ④ 복제 지연 임계 초과             [즉시]
  ⑤ 점검 전용 VS 실패               [즉시]
------------------------------------------------------------------------------
NEXT
