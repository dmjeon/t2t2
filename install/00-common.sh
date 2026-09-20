#!/usr/bin/env bash
# =============================================================================
# 전 서버 공통 준비 — Rocky Linux 8/9, root 실행
#   ./00-common.sh <역할>
#
# 여기서는 **어느 계층에도 속하지 않는 것만** 한다.
# 알람·검증 도구·심장박동은 나중에 따로 깔 수 있게 빼 뒀다.
#
# ★ 호스트명은 건드리지 않는다. VM 이름과 OS 호스트명이 다른 경우가 있고,
#   여기서 바꾸면 /api/info 의 was_host 와 포털 VM 목록이 어긋나 추적이 꼬인다.
#   바꿔야 한다면 사람이 명시적으로:  hostnamectl set-hostname <이름>
# =============================================================================
set -euo pipefail
AADC_ROLE_ARG="${1:-}"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_bash

banner "공통 준비" "Common setup"

step "기본 패키지" "Base packages"
# 검증 도구(jq, dig, traceroute)는 여기 없다 → 51-verify.sh
dnf -y install curl iproute net-tools chrony rsync tar \
               policycoreutils-python-utils >/dev/null
systemctl enable --now chronyd
say "curl iproute net-tools chrony rsync tar policycoreutils-python-utils"
msg "검증 도구(jq/dig/traceroute)는 51-verify.sh 에서 깐다." \
    "Verification tools (jq/dig/traceroute) come later, in 51-verify.sh."

step "시간 동기" "Time sync"
# 기능 요구사항이다. 서로 다른 DC 의 서로 다른 호스트에서 찍은 타임스탬프를
# 비교해 구간 지연을 잰다. 시계가 어긋나면 측정이 통째로 무의미해진다.
msg "구간 지연을 서로 다른 DC 의 호스트 타임스탬프로 잰다. 시계가 어긋나면 측정이 무의미하다." \
    "Latency is measured across hosts in different DCs. Skewed clocks void every number."
chronyc tracking 2>/dev/null | head -3 | sed 's/^/   /' \
  || say "chronyd starting..."

step "공통 디렉터리" "Directories"
install -d -m 0755 /etc/aadc /opt/aadc
install -m 0640 "${ROOT}/config.env" /opt/aadc/config.env
kv "/etc/aadc" "created"
kv "/opt/aadc/config.env" "installed (0640)"

step "SELinux" "SELinux"
enforce="$(getenforce 2>/dev/null || echo Disabled)"
kv "status" "${enforce}"
if [ "${enforce}" = "Enforcing" ]; then
  msg "필요한 boolean 은 계층별 스크립트가 켠다 (30-web.sh 등)." \
      "Per-tier booleans are set by the tier scripts (e.g. 30-web.sh)."
fi

cat <<NEXT

-------------------------------------------------------------------------------
공통 준비 완료. 호스트명은 바꾸지 않았다 — 현재: $(hostname)
Common setup done. Hostname was NOT changed - still: $(hostname)

핵심 / CORE - run in this order
  DB-MASTER / DB-BACKUP / DB-DR   ./10-db.sh  <role>
  WAS-APP1-500 / WAS-DC2          ./20-was.sh <role>
  WEB-DC1 / WEB-DC2               ./30-web.sh <role>

  DB(10) 를 WAS/WEB(20,30) 보다 먼저 한다. DB 자동 전환이 검증되지 않은
  상태에서 위 계층을 얹으면 장애 원인 분리가 안 된다.
  Do the DB tier first. Stacking upper tiers on an unverified DB failover
  makes it impossible to tell where a fault came from.

나중 / LATER - only after the core is up
  ./50-monitoring.sh <role>   알람 + 복제 심장박동 / alarms + repl heartbeat
  ./51-verify.sh              검증 도구 / verification tools
  ../deploy/deploy-canary.sh  카나리 배포 / canary deploy   (설치 불필요)
  ../dr/                      DR 전환 / DR switchover       (설치 불필요)

역할은 인자로 넘기면 된다. config.env 를 서버마다 고칠 필요가 없다.
Pass the role as an argument - no need to edit config.env on every host.
-------------------------------------------------------------------------------
NEXT
