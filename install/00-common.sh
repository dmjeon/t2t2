#!/usr/bin/env bash
# =============================================================================
# 전 서버 공통 준비 — Rocky Linux 8/9, root 실행
#   ./00-common.sh
#
# 여기서는 **어느 계층에도 속하지 않는 것만** 한다.
# 알람·검증 도구·심장박동은 나중에 따로 깔 수 있게 빼 뒀다 (아래 "나중" 참조).
#
# ★ 호스트명은 건드리지 않는다. VM 이름과 OS 호스트명이 다른 경우가 있고,
#   여기서 바꾸면 /api/info 의 was_host 와 포털 VM 목록이 어긋나 추적이 꼬인다.
#   바꿔야 한다면 사람이 명시적으로:  hostnamectl set-hostname <이름>
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
[ -f "${ROOT}/config.env" ] || { echo "config.env 가 없다. cp config.env.example config.env"; exit 1; }
# shellcheck disable=SC1091
. "${ROOT}/config.env"

echo "== 역할: ${AADC_ROLE} (${AADC_DC})   호스트명: $(hostname) =="

echo "== 1. 기본 패키지 =="
# 검증 도구(jq, dig, traceroute)는 여기 없다 → 51-verify.sh
dnf -y install curl iproute net-tools chrony rsync tar \
               policycoreutils-python-utils >/dev/null
systemctl enable --now chronyd

echo "== 2. 시간 동기 =="
# 기능 요구사항이다. 이 PoC 는 **서로 다른 DC 의 서로 다른 호스트**에서 찍은
# 타임스탬프를 비교해 구간 지연을 잰다. 시계가 어긋나면 측정값이 전부 무의미해진다.
chronyc tracking 2>/dev/null | head -3 || echo "   (chronyd 기동 대기 중)"

echo "== 3. 공통 디렉터리 =="
install -d -m 0755 /etc/aadc /opt/aadc
install -m 0640 "${ROOT}/config.env" /opt/aadc/config.env

echo "== 4. SELinux =="
enforce="$(getenforce 2>/dev/null || echo Disabled)"
echo "   ${enforce}"
[ "${enforce}" = "Enforcing" ] && echo "   → 필요한 boolean 은 각 계층 스크립트가 켠다 (30-web.sh 등)"

cat <<NEXT

------------------------------------------------------------------------------
공통 준비 완료.  호스트명은 바꾸지 않았다 ($(hostname)).

핵심 — 이 순서대로
  DB-MASTER / DB-BACKUP / DB-DR   ./10-db.sh
  WAS-APP1-500 / WAS-DC2          ./20-was.sh
  WEB-DC1 / WEB-DC2               ./30-web.sh

  ★ DB(10) 를 WAS·WEB(20,30) 보다 먼저 한다. DB 자동 전환이 검증되지 않은
    상태에서 위 계층을 얹으면 장애 원인 분리가 안 된다 (AADC-POC.md 14절).

나중 — 핵심이 다 붙고 나서, 필요할 때 따로
  ./50-monitoring.sh    알람 5종 + 복제 심장박동   (7-③절)
  ./51-verify.sh        검증 도구 (jq / dig / traceroute / iperf3)
  ../deploy/            카나리 배포 절차           (8절)
  ../dr/                DR 전환 2단 게이트         (3-4절)

  뒤 두 개는 설치가 필요 없다. 번들에서 바로 실행한다.
------------------------------------------------------------------------------
NEXT
