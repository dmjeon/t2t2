#!/usr/bin/env bash
# =============================================================================
# 지금 이 호스트가 무엇으로 판정되는가 — 진단 전용. 아무것도 설치하지 않는다.
#   ./whoami.sh            자동 판정 결과
#   ./whoami.sh DB-MASTER  인자를 줬을 때 어떻게 되는지
#
# 설치가 "역할이 안 맞다"로 막힐 때 이걸 먼저 돌린다.
# 원인은 대개 셋 중 하나이고, 아래 출력이 셋을 구분해 준다.
#   1) 인자를 안 줬다            → role source 가 config.env 로 나온다
#   2) git pull 이 안 먹었다     → bundle 이 옛날 커밋을 가리킨다
#   3) IP 가 표에 없다           → detected 가 비어 있다
# =============================================================================
set -uo pipefail
AADC_ROLE_ARG="${1:-}"
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==============================================================="
echo " AADC install — role resolution"
echo "==============================================================="

# ----- 번들이 최신인지 -------------------------------------------------------
echo
echo "[bundle]"
printf '  %-22s %s\n' "path" "$(cd "${HERE_DIR}/.." && pwd)"
if git -C "${HERE_DIR}/.." rev-parse --git-dir >/dev/null 2>&1; then
  printf '  %-22s %s\n' "commit" "$(git -C "${HERE_DIR}/.." log -1 --format='%h %cd %s' --date=short 2>/dev/null)"
  dirty="$(git -C "${HERE_DIR}/.." status --porcelain 2>/dev/null | head -5)"
  if [ -n "${dirty}" ]; then
    echo "  local changes  ↓  ★ 이게 있으면 git pull 이 거부됐을 수 있다"
    printf '%s\n' "${dirty}" | sed 's/^/      /'
    echo "      복구: git -C $(cd "${HERE_DIR}/.." && pwd) stash && git pull"
  else
    printf '  %-22s %s\n' "local changes" "none"
  fi
else
  printf '  %-22s %s\n' "git" "not a git repo (tarball?)"
fi
# lib.sh 에 이번 수정이 들어와 있는지로 최신 여부를 직접 확인한다
if grep -q 'AADC_SKIP_ROLE_CHECK' "${HERE_DIR}/lib.sh" 2>/dev/null; then
  printf '  %-22s %s\n' "lib.sh" "up to date (has AADC_SKIP_ROLE_CHECK)"
else
  printf '  %-22s %s\n' "lib.sh" "★ OLD — pull 이 반영되지 않았다"
fi

# ----- 이 호스트의 주소 ------------------------------------------------------
echo
echo "[addresses on this host]"
ip -4 -o addr show scope global 2>/dev/null \
  | awk '{split($4,a,"/"); printf "  %-22s %s\n", $2, a[1]}' \
  || hostname -I

# ----- 역할 판정 -------------------------------------------------------------
echo
echo "[role resolution]"
printf '  %-22s %s\n' "argument"      "${AADC_ROLE_ARG:-<none>}"
printf '  %-22s %s\n' "env AADC_ROLE" "${AADC_ROLE:-<unset>}"

# shellcheck source=lib.sh
if . "${HERE_DIR}/lib.sh" 2>/tmp/aadc-whoami.err; then
  cfgrole="$(grep -E '^AADC_ROLE=' "$(cd "${HERE_DIR}/.." && pwd)/config.env" | cut -d= -f2- | tr -d '"')"
  printf '  %-22s %s\n' "config.env default" "${cfgrole:-<empty — 의도된 것. 인자로 줘야 한다>}"
  printf '  %-22s %s\n' "detected by IP" "$(detect_role_by_ip 2>/dev/null || echo '<no match>')"
  echo
  printf '  %-22s %s\n' "=> AADC_ROLE"   "${AADC_ROLE}"
  printf '  %-22s %s\n' "=> AADC_DC"     "${AADC_DC}"
  printf '  %-22s %s\n' "=> source"      "${AADC_ROLE_SRC}"
  printf '  %-22s %s\n' "=> expected IP" "${ROLE_EXPECTED_IP:-<n/a>}"
  printf '  %-22s %s\n' "=> temp address" "${TEMP_ADDRESS}"
else
  echo "  ★ lib.sh 로드 실패 / lib.sh failed to load:"
  sed 's/^/      /' /tmp/aadc-whoami.err
  exit 1
fi

echo
echo "[what to run]"
case "${AADC_ROLE}" in
  DB-*)  echo "  ./10-db.sh  ${AADC_ROLE}" ;;
  WAS-*) echo "  ./20-was.sh ${AADC_ROLE}" ;;
  WEB-*) echo "  ./30-web.sh ${AADC_ROLE}" ;;
  *)     echo "  역할이 확정되지 않았다. 인자로 줄 것 / pass it explicitly:"
         echo "      ./10-db.sh DB-MASTER" ;;
esac
echo
echo "  역할이 위와 다르면 인자가 최우선이다 / the argument always wins:"
echo "      ./10-db.sh DB-MASTER"
echo "==============================================================="
