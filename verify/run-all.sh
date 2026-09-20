#!/usr/bin/env bash
# 평시 상태에서 돌릴 수 있는 검증만 순서대로 실행한다.
# 장애 주입이 필요한 항목(C3~C11, C15~C19)은 각 스크립트를 개별 실행할 것.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for s in 01-baseline-c1-c2.sh 02-path-r1-r6.sh 04-db-c3-c7.sh; do
  printf '\n\033[1;44m  %s  \033[0m\n' "${s}"
  "${HERE}/${s}" || rc=1
done
printf '\n\033[1;44m  03-health-c15-c18.sh normal  \033[0m\n'
"${HERE}/03-health-c15-c18.sh" normal || rc=1
exit "${rc}"
