#!/usr/bin/env bash
# =============================================================================
# 전 서버 공통 준비 — Rocky Linux 8/9, root 실행
#   ./00-common.sh
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
[ -f "${ROOT}/config.env" ] || { echo "config.env 가 없다. cp config.env.example config.env"; exit 1; }
# shellcheck disable=SC1091
. "${ROOT}/config.env"

echo "== 역할: ${AADC_ROLE} (${AADC_DC}) =="

echo "== 1. 기본 패키지 =="
dnf -y install curl jq bind-utils traceroute iproute net-tools \
               chrony rsync tar policycoreutils-python-utils \
               >/dev/null
systemctl enable --now chronyd

echo "== 2. 시간 동기 확인 (로그 상관분석과 복제 지연 측정의 전제) =="
chronyc tracking | head -3 || true

echo "== 3. 공통 디렉터리 =="
install -d -m 0755 /etc/aadc /opt/aadc /var/lib/aadc-monitor
install -m 0640 "${ROOT}/config.env" /opt/aadc/config.env

echo "== 4. 알람 송출기 =="
install -m 0755 "${ROOT}/monitoring/bin/aadc-alarm-send.sh" /usr/local/bin/
[ -f /etc/aadc/monitor.env ] || \
  install -m 0640 "${ROOT}/monitoring/monitor.env.example" /etc/aadc/monitor.env

echo "== 5. SELinux 상태 =="
getenforce || true
echo "   Enforcing 이면 각 설치 스크립트가 필요한 boolean 을 켠다."

echo "== 6. 호스트명 =="
hostnamectl set-hostname "${AADC_ROLE}" || true

echo "완료. 다음: 역할별 스크립트 (10-db.sh / 20-was.sh / 30-web.sh)"
